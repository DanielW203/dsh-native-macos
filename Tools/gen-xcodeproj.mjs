#!/usr/bin/env node
// Generate `NativeHarness.xcodeproj` from the source tree.
//
// Why a generator instead of a hand-maintained project file:
//
//  1. A `.pbxproj` lists every file twice (file reference + build file) with opaque
//     24-hex UUIDs. Hand-maintaining one across a project this size guarantees drift
//     and unreviewable diffs; generating it means the project is a pure function of
//     the tree.
//  2. The obvious alternative — let Xcode resolve the local SwiftPM package
//     (`XCLocalSwiftPackageReference`) — routes every build through Xcode's embedded
//     SwiftPM. That path is unusable in this workspace: Xcode runs manifest loading
//     inside its own `sandbox-exec` profile, which cannot be nested inside the DSH
//     file sandbox, and its caches live outside the workspace. The Xcode project is
//     therefore self-contained: it compiles the same sources directly.
//
// Layout produced: one static framework per module (so `import HarnessKit` works and
// nothing has to be codesigned or embedded at runtime), the two app targets, a
// `harnessctl` command-line tool, and the two XCTest bundles.
//
// Usage: node Tools/gen-xcodeproj.mjs
// Re-run after adding or removing source files.

import { readdirSync, statSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join, relative, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// `new URL(...).pathname` percent-encodes non-ASCII characters, and this checkout
// lives under a path containing such characters — `fileURLToPath` is the only correct
// way to turn the module URL back into a filesystem path here.
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const PROJECT_NAME = 'NativeHarness';
const PROJECT_DIR = join(ROOT, `${PROJECT_NAME}.xcodeproj`);

// MARK: - Deterministic UUIDs

/** Stable 24-hex-character identifier derived from a key, so diffs stay readable. */
function uid(key) {
  let hash = 0xcbf29ce484222325n;
  const prime = 0x100000001b3n;
  for (const byte of Buffer.from(key, 'utf8')) {
    hash ^= BigInt(byte);
    hash = (hash * prime) & 0xffffffffffffffffn;
  }
  let out = '';
  let value = hash;
  for (let i = 0; i < 6; i++) {
    out += (value & 0xffffn).toString(16).padStart(4, '0').toUpperCase();
    value >>= 16n;
    if (value === 0n) value = hash ^ BigInt(i + 1);
  }
  return out.slice(0, 24);
}

// MARK: - Source discovery

function walk(dir, extensions) {
  const out = [];
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.name === '.build' || entry.name.startsWith('.')) continue;
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full, extensions));
    else if (extensions.some((ext) => entry.name.endsWith(ext))) out.push(full);
  }
  return out;
}

const swiftSources = (dir) => walk(dir, ['.swift']);
const cSources = (dir) => walk(dir, ['.c', '.m', '.mm']);

// MARK: - Project model

/**
 * Each framework target is a static framework: it produces a `.framework` that the
 * linker folds into the consumer, so there is no dylib to embed, no `@rpath` to fix,
 * and `import <Module>` still resolves through the generated module map.
 */
const modules = [
  {
    name: 'CZstd',
    kind: 'cframework',
    sources: cSources(join(ROOT, 'Sources/CZstd')),
    // The umbrella header comes first: Xcode derives the framework's module map from
    // the public header named after the product, and without it `import CZstd` fails.
    headers: [
      join(ROOT, 'Sources/CZstd/include/CZstd.h'),
      join(ROOT, 'Sources/CZstd/include/czstd_shim.h'),
    ],
    dependencies: [],
    settings: {
      HEADER_SEARCH_PATHS: ['$(SRCROOT)/Vendor/zstd/include'],
      GCC_PREPROCESSOR_DEFINITIONS: ['ZSTD_STATIC_LINKING_ONLY=1', '$(inherited)'],
    },
  },
  {
    name: 'HarnessKit',
    kind: 'framework',
    sources: swiftSources(join(ROOT, 'Sources/HarnessKit')),
    dependencies: ['CZstd'],
  },
  {
    name: 'HarnessCore',
    kind: 'framework',
    sources: swiftSources(join(ROOT, 'Sources/HarnessCore')),
    dependencies: ['HarnessKit', 'CZstd'],
  },
  {
    name: 'HarnessRuntime',
    kind: 'framework',
    sources: swiftSources(join(ROOT, 'Sources/HarnessRuntime')),
    dependencies: ['HarnessKit'],
  },
  {
    name: 'HarnessUI',
    kind: 'framework',
    sources: swiftSources(join(ROOT, 'Sources/HarnessUI')),
    dependencies: ['HarnessKit', 'HarnessRuntime', 'HarnessIM'],
  },
  {
    // The runtime/plugin console surface. Deliberately its own module rather than a
    // pane of HarnessUI: it manages the runtime (install, update, plugin work) and
    // needs nothing from the transcript UI. DSHNative opens it twice from its Harness
    // menu — as the console window and as the plugin window — over one shared model.
    name: 'HarnessConsoleUI',
    kind: 'framework',
    sources: swiftSources(join(ROOT, 'Sources/HarnessConsoleUI')),
    dependencies: ['HarnessRuntime', 'HarnessKit'],
  },
  {
    // The app-owned IM channel: provider protocol + batching + a client for a *running*
    // harness's local API. Depends on HarnessKit alone on purpose, so nothing it does can
    // reach into the harness home it talks to.
    name: 'HarnessIM',
    kind: 'framework',
    sources: swiftSources(join(ROOT, 'Sources/HarnessIM')),
    dependencies: ['HarnessKit'],
  },
];

const apps = [
  {
    name: 'DSHNative',
    bundleID: 'ai.deepseek.nativeharness.DSHNative',
    sources: swiftSources(join(ROOT, 'Apps/DSHNative')),
    dependencies: ['HarnessUI', 'HarnessConsoleUI', 'HarnessIM', 'HarnessRuntime', 'HarnessKit', 'CZstd'],
    // The app icon is a real build resource rather than a file dropped into the built
    // bundle by hand: a hand-dropped file is lost on the next rebuild and the app falls
    // back to the blank default document icon. It goes through an asset catalog because
    // that is the only icon route Xcode's Info.plist generation honours — the
    // `INFOPLIST_KEY_CFBundleIconFile` build setting is silently ignored by
    // `GENERATE_INFOPLIST_FILE=YES`, so setting it produces an app whose icon file is
    // present but unnamed in the plist (measured; see CONTRACT.md §5).
    resources: [join(ROOT, 'Apps/DSHNative/Resources/Assets.xcassets')],
    iconName: 'AppIcon',
    displayName: 'DSH Native',
    subtitle: 'Embedded engine',
  },
];

const tool = {
  name: 'harnessctl',
  sources: swiftSources(join(ROOT, 'Sources/harnessctl')),
  dependencies: ['HarnessCore', 'HarnessRuntime', 'HarnessIM', 'HarnessKit', 'CZstd'],
};

const testBundles = [
  {
    name: 'HarnessKitTests',
    sources: swiftSources(join(ROOT, 'Tests/HarnessKitTests')),
    dependencies: ['HarnessKit'],
    resources: [join(ROOT, 'Tests/HarnessKitTests/Fixtures')],
  },
  {
    name: 'HarnessIMTests',
    sources: swiftSources(join(ROOT, 'Tests/HarnessIMTests')),
    dependencies: ['HarnessIM'],
    resources: [join(ROOT, 'Tests/HarnessIMTests/Fixtures')],
  },
  {
    name: 'ConformanceTests',
    sources: swiftSources(join(ROOT, 'Tests/ConformanceTests')),
    dependencies: ['HarnessCore', 'HarnessKit', 'CZstd'],
    resources: [],
  },
];

// Extra linker input shared by every target that ends up needing zstd symbols.
const ZSTD_LIB_DIR = '$(SRCROOT)/Vendor/zstd/lib';

// MARK: - pbxproj assembly

const objects = [];
const push = (text) => objects.push(text);
/**
 * OpenStep plist quoting. Only bare identifiers are left unquoted; everything else —
 * including `$(TARGET_NAME)` and anything with dots — is quoted, because Xcode's
 * parser rejects some unquoted token shapes (a single missing semicolon aborts the
 * whole project with "the project is damaged").
 */
const quoted = (value) =>
  /^[A-Za-z_][A-Za-z0-9_]*$/.test(value) ? value : `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;

const groups = [];      // { uuid, name, path, children: [uuid], isRoot }
const fileRefs = [];    // { uuid, path, name, type, sourceTree }
const buildFiles = [];  // { uuid, fileRef, target }
const targets = [];     // { uuid, name, kind, ... }

/** Register (or reuse) a file reference for an absolute path. */
const fileRefCache = new Map();
function fileRefFor(absPath, nameOverride) {
  const key = absPath;
  if (fileRefCache.has(key)) return fileRefCache.get(key);
  const rel = relative(ROOT, absPath);
  const ext = rel.split('.').pop();
  const typeMap = {
    swift: 'sourcecode.swift',
    c: 'sourcecode.c.c',
    h: 'sourcecode.c.h',
    plist: 'text.plist.xml',
    json: 'text.json',
    md: 'net.daringfireball.markdown',
    a: 'archive.ar',
    framework: 'wrapper.framework',
    xcconfig: 'text.xcconfig',
    // App icon. Xcode does honour the `image.icns` UTI; the fallback is `text`, which
    // also gets copied into Resources, so the explicit mapping is belt-and-braces.
    icns: 'image.icns',
  };
  let fileType = typeMap[ext];
  if (absPath.endsWith('.framework')) fileType = 'wrapper.framework';
  // An asset catalog is a directory, but not the generic `folder` reference the next
  // branch assigns: `folder.assetcatalog` is what makes the Resources phase hand it to
  // `actool` (compiling Assets.car and adding the Info.plist icon keys) rather than
  // copying the directory into the bundle verbatim.
  if (absPath.endsWith('.xcassets')) fileType = 'folder.assetcatalog';
  let isDirectory = false;
  try {
    isDirectory = statSync(absPath).isDirectory();
  } catch {}
  if (isDirectory && !absPath.endsWith('.framework') && !absPath.endsWith('.xcassets')) fileType = 'folder';

  // The file's §path§ is relative to its containing group, and the group chain already
  // contributes the directories. Emitting the root-relative path here doubles every
  // directory segment — which is invisible until the PBXBuildFile section is populated,
  // because Xcode only validates the paths of files a build phase actually references.
  const basename = rel.split('/').pop();
  const uuid = uid(`fileref:${rel}`);
  fileRefs.push({
    uuid,
    name: nameOverride ?? basename,
    path: basename,
    type: fileType ?? 'text',
  });
  fileRefCache.set(key, uuid);
  return uuid;
}

/**
 * Build a nested `PBXGroup` hierarchy mirroring the directories, so the Xcode
 * navigator shows the same tree as the filesystem.
 */
const groupCache = new Map();
function groupFor(relDir) {
  if (groupCache.has(relDir)) return groupCache.get(relDir);
  const name = relDir === '' ? PROJECT_NAME : relDir.split('/').pop();
  const uuid = uid(`group:${relDir}`);
  groupCache.set(relDir, uuid);
  groups.push({ uuid, name, path: relDir, children: [] });
  return uuid;
}

function addFileToGroup(absPath) {
  const rel = relative(ROOT, absPath);
  const dir = rel.includes('/') ? rel.slice(0, rel.lastIndexOf('/')) : '';
  const groupUUID = groupFor(dir);
  const ref = fileRefFor(absPath);
  const group = groups.find((g) => g.uuid === groupUUID);
  if (group && !group.children.includes(ref)) group.children.push(ref);

  // Link the *whole* ancestor chain, not just the immediate parent.
  //
  // A directory that holds only subdirectories — Sources/HarnessUI, for instance, whose
  // files all live in Shell, Conversation, Tools and so on — has no file of its own to
  // trigger its linking. Left unlinked it is unreachable from the project root, so Xcode
  // resolves its children against the project directory and every source path comes out
  // flat: <root>/HarnessConsoleView.swift instead of Sources/HarnessUI/Shell/…
  // A source at the repository root would land in a group that is not the project's
  // root group (that object is emitted separately), which produces a project Xcode
  // reports as malformed. Failing here is better than emitting one.
  if (dir === '') {
    throw new Error(
      `gen-xcodeproj: ${rel} sits at the repository root; move it under a directory`
    );
  }

  // Walk up to — but not including — the root group. Top-level groups are attached to
  // the real root by the emission step, which owns that object; linking them here as
  // well put the same group in two parents.
  let childDir = dir;
  while (childDir.includes('/')) {
    const parentDir = childDir.slice(0, childDir.lastIndexOf('/'));
    const childUUID = groupFor(childDir);
    const parent = groups.find((g) => g.uuid === groupFor(parentDir));
    if (parent && !parent.children.includes(childUUID)) parent.children.push(childUUID);
    childDir = parentDir;
  }
  return ref;
}

const linkBuildFiles = new Map();
/**
 * Build-file UUID for linking a target's product into a consumer's Frameworks phase.
 *
 * Pre-registered before emission: the `PBXBuildFile` section is written in one pass,
 * so a build file created while walking later phases would silently miss it.
 */
function linkBuildFile(targetName, dependency) {
  const key = `${targetName}->${dependency}`;
  if (!linkBuildFiles.has(key)) linkBuildFiles.set(key, uid(`link:${key}`));
  return linkBuildFiles.get(key);
}

/** Build files that must be installed into the framework's Headers directory. */
const publicHeaderBuildFiles = new Set();

/**
 * Build file for a public header.
 *
 * A header added to a Headers phase defaults to the Project role, which means Xcode
 * compiles against it but never copies it into the framework. Without a Public umbrella
 * header the framework has no module map and every consumer fails with "Unable to find
 * module dependency" — which is exactly how the C module here behaved.
 */
function headerBuildFileFor(absPath, targetName) {
  const uuid = buildFileFor(absPath, targetName);
  publicHeaderBuildFiles.add(uuid);
  return uuid;
}

const buildFileCache = new Map();
function buildFileFor(absPath, targetName) {
  const key = `${targetName}:${absPath}`;
  if (buildFileCache.has(key)) return buildFileCache.get(key);
  const ref = addFileToGroup(absPath);
  const uuid = uid(`buildfile:${key}`);
  buildFiles.push({ uuid, fileRef: ref, target: targetName });
  buildFileCache.set(key, uuid);
  return uuid;
}

/** Register every source file of a target and return the ordered build-file UUIDs. */
function sourceBuildFiles(paths, targetName) {
  return paths.map((p) => buildFileFor(p, targetName));
}

// MARK: - Emit

function emitProject() {
  const lines = [];
  lines.push('// !$*UTF8*$!');
  lines.push('{');
  lines.push('\tarchiveVersion = 1;');
  lines.push('\tclasses = {');
  lines.push('\t};');
  lines.push('\tobjectVersion = 56;');
  lines.push('\tobjects = {');

  // PBXBuildFile
  lines.push('');
  lines.push('/* Begin PBXBuildFile section */');
  for (const bf of buildFiles) {
    const ref = fileRefs.find((f) => f.uuid === bf.fileRef);
    // The Public role is what makes Xcode install the header into the framework and
    // derive the module map from it. The string closes the settings dictionary, the
    // PBXBuildFile object, and the assignment.
    const attributes = publicHeaderBuildFiles.has(bf.uuid)
      ? ' settings = {ATTRIBUTES = (Public, ); }; };'
      : ' };';
    lines.push(
      `\t\t${bf.uuid} /* ${ref.name} in ${bf.target} */ = {isa = PBXBuildFile; fileRef = ${bf.fileRef} /* ${ref.name} */;${attributes}`
    );
  }
  for (const [key, uuid] of linkBuildFiles) {
    const [targetName, dependency] = key.split('->');
    lines.push(
      `\t\t${uuid} /* ${dependency}.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = ${productUUIDFor(dependency)} /* ${dependency}.framework */; };`
    );
  }
  lines.push('/* End PBXBuildFile section */');

  // PBXFileReference
  lines.push('');
  lines.push('/* Begin PBXFileReference section */');
  for (const ref of fileRefs) {
    lines.push(
      `\t\t${ref.uuid} /* ${ref.name} */ = {isa = PBXFileReference; lastKnownFileType = ${ref.type}; name = ${quoted(ref.name)}; path = ${quoted(ref.path)}; sourceTree = "<group>"; };`
    );
  }
  // Products
  for (const product of products()) {
    lines.push(
      `\t\t${product.uuid} /* ${product.name} */ = {isa = PBXFileReference; explicitFileType = ${product.explicitType}; includeInIndex = 0; path = ${quoted(product.path)}; sourceTree = BUILT_PRODUCTS_DIR; };`
    );
  }
  lines.push('/* End PBXFileReference section */');

  // PBXGroup
  lines.push('');
  lines.push('/* Begin PBXGroup section */');
  const rootUUID = uid('group:__root__');
  const productsUUID = uid('group:__products__');
  const rootChildren = [];
  const seenRootChildren = new Set();
  const addRootChild = (uuid) => {
    if (!uuid || seenRootChildren.has(uuid)) return;
    seenRootChildren.add(uuid);
    rootChildren.push(uuid);
  };
  for (const group of groups) {
    if (group.path === '' || group.path.includes('/')) continue;
    addRootChild(group.uuid);
  }
  // Only files the published tree contains: the internal development documents are kept
  // out of the exported copy, so listing them here would make the regenerated project
  // differ between the two trees.
  for (const extra of ['Apps', 'Sources', 'Tests', 'Vendor', 'Bridge', 'Spec', 'Tools', 'CONTRACT.md', 'README.md', 'Package.swift']) {
    if (extra.includes('.')) {
      const abs = join(ROOT, extra);
      try {
        statSync(abs);
        addRootChild(fileRefFor(abs));
      } catch {}
    } else if (groups.some((g) => g.path === extra)) {
      addRootChild(groupFor(extra));
    }
  }
  addRootChild(productsUUID);
  lines.push(`\t\t${rootUUID} = {`);
  lines.push('\t\t\tisa = PBXGroup;');
  lines.push('\t\t\tchildren = (');
  for (const child of rootChildren) lines.push(`\t\t\t\t${child},`);
  lines.push('\t\t\t);');
  lines.push('\t\t\tsourceTree = "<group>";');
  lines.push('\t\t};');
  for (const group of groups) {
    if (group.uuid === rootUUID) continue;
    lines.push(`\t\t${group.uuid} /* ${group.name} */ = {`);
    lines.push('\t\t\tisa = PBXGroup;');
    lines.push('\t\t\tchildren = (');
    for (const child of group.children) lines.push(`\t\t\t\t${child},`);
    lines.push('\t\t\t);');
    lines.push('\t\t\tname = ' + quoted(group.name) + ';');
    lines.push('\t\t\tpath = ' + quoted(group.name) + ';');
    lines.push('\t\t\tsourceTree = "<group>";');
    lines.push('\t\t};');
  }
  lines.push(`\t\t${productsUUID} /* Products */ = {`);
  lines.push('\t\t\tisa = PBXGroup;');
  lines.push('\t\t\tchildren = (');
  for (const product of products()) lines.push(`\t\t\t\t${product.uuid} /* ${product.name} */,`);
  lines.push('\t\t\t);');
  lines.push('\t\t\tname = Products;');
  lines.push('\t\t\tsourceTree = "<group>";');
  lines.push('\t\t};');
  lines.push('/* End PBXGroup section */');

  // PBXHeadersBuildPhase (frameworks expose their public headers)
  lines.push('');
  lines.push('/* Begin PBXHeadersBuildPhase section */');
  for (const target of allTargets()) {
    if (!target.headers?.length) continue;
    const phaseUUID = uid(`headers:${target.name}`);
    target.headersPhase = phaseUUID;
    lines.push(`\t\t${phaseUUID} /* Headers */ = {`);
    lines.push('\t\t\tisa = PBXHeadersBuildPhase;');
    lines.push('\t\t\tbuildActionMask = 2147483647;');
    lines.push('\t\t\tfiles = (');
    for (const header of target.headers) {
      lines.push(`\t\t\t\t${headerBuildFileFor(header, target.name)} /* ${header.split('/').pop()} in Headers */,`);
    }
    lines.push('\t\t\t);');
    lines.push('\t\t\trunOnlyForDeploymentPostprocessing = 0;');
    lines.push('\t\t};');
  }
  lines.push('/* End PBXHeadersBuildPhase section */');

  // PBXSourcesBuildPhase
  lines.push('');
  lines.push('/* Begin PBXSourcesBuildPhase section */');
  for (const target of allTargets()) {
    const phaseUUID = uid(`sources:${target.name}`);
    target.sourcesPhase = phaseUUID;
    lines.push(`\t\t${phaseUUID} /* Sources */ = {`);
    lines.push('\t\t\tisa = PBXSourcesBuildPhase;');
    lines.push('\t\t\tbuildActionMask = 2147483647;');
    lines.push('\t\t\tfiles = (');
    for (const uuid of sourceBuildFiles(target.sources, target.name)) {
      const ref = fileRefs.find((f) => f.uuid === buildFiles.find((b) => b.uuid === uuid).fileRef);
      lines.push(`\t\t\t\t${uuid} /* ${ref.name} in Sources */,`);
    }
    lines.push('\t\t\t);');
    lines.push('\t\t\trunOnlyForDeploymentPostprocessing = 0;');
    lines.push('\t\t};');
  }
  lines.push('/* End PBXSourcesBuildPhase section */');

  // PBXResourcesBuildPhase
  lines.push('');
  lines.push('/* Begin PBXResourcesBuildPhase section */');
  for (const target of allTargets()) {
    const resources = target.resources ?? [];
    const phaseUUID = uid(`resources:${target.name}`);
    target.resourcesPhase = phaseUUID;
    lines.push(`\t\t${phaseUUID} /* Resources */ = {`);
    lines.push('\t\t\tisa = PBXResourcesBuildPhase;');
    lines.push('\t\t\tbuildActionMask = 2147483647;');
    lines.push('\t\t\tfiles = (');
    for (const resource of resources) {
      // Directory resources are added as folder references so the tree is preserved.
      // The call has to stay for its side effect even though its return value is not
      // needed here: it is what registers the PBXFileReference the build file points at.
      fileRefFor(resource, resource.split('/').pop());
      lines.push(`\t\t\t\t${buildFileFor(resource, target.name)} /* ${resource.split('/').pop()} in Resources */,`);
    }
    lines.push('\t\t\t);');
    lines.push('\t\t\trunOnlyForDeploymentPostprocessing = 0;');
    lines.push('\t\t};');
  }
  lines.push('/* End PBXResourcesBuildPhase section */');

  // PBXFrameworksBuildPhase
  lines.push('');
  lines.push('/* Begin PBXFrameworksBuildPhase section */');
  for (const target of allTargets()) {
    const phaseUUID = uid(`frameworks:${target.name}`);
    target.frameworksPhase = phaseUUID;
    lines.push(`\t\t${phaseUUID} /* Frameworks */ = {`);
    lines.push('\t\t\tisa = PBXFrameworksBuildPhase;');
    lines.push('\t\t\tbuildActionMask = 2147483647;');
    lines.push('\t\t\tfiles = (');
    for (const dependency of target.dependencies) {
      const productUUID = productUUIDFor(dependency);
      if (productUUID) {
        const uuid = linkBuildFile(target.name, dependency);
        lines.push(`\t\t\t\t${uuid} /* ${dependency}.framework in Frameworks */,`);
      }
    }
    lines.push('\t\t\t);');
    lines.push('\t\t\trunOnlyForDeploymentPostprocessing = 0;');
    lines.push('\t\t};');
  }
  lines.push('/* End PBXFrameworksBuildPhase section */');

  // PBXContainerItemProxy + PBXTargetDependency
  lines.push('');
  lines.push('/* Begin PBXContainerItemProxy section */');
  for (const target of allTargets()) {
    for (const dependency of target.dependencies) {
      const depTarget = allTargets().find((t) => t.name === dependency);
      if (!depTarget) continue;
      lines.push(`\t\t${uid(`proxy:${target.name}:${dependency}`)} /* PBXContainerItemProxy */ = {`);
      lines.push('\t\t\tisa = PBXContainerItemProxy;');
      lines.push(`\t\t\tcontainerPortal = ${uid('project')} /* Project object */;`);
      lines.push('\t\t\tproxyType = 1;');
      lines.push(`\t\t\tremoteGlobalIDString = ${uid(`target:${dependency}`)};`);
      lines.push(`\t\t\tremoteInfo = ${dependency};`);
      lines.push('\t\t};');
    }
  }
  lines.push('/* End PBXContainerItemProxy section */');
  lines.push('');
  lines.push('/* Begin PBXTargetDependency section */');
  for (const target of allTargets()) {
    for (const dependency of target.dependencies) {
      if (!allTargets().some((t) => t.name === dependency)) continue;
      lines.push(`\t\t${uid(`dependency:${target.name}:${dependency}`)} /* PBXTargetDependency */ = {`);
      lines.push('\t\t\tisa = PBXTargetDependency;');
      lines.push(`\t\t\ttarget = ${uid(`target:${dependency}`)} /* ${dependency} */;`);
      lines.push(`\t\t\ttargetProxy = ${uid(`proxy:${target.name}:${dependency}`)} /* PBXContainerItemProxy */;`);
      lines.push('\t\t};');
    }
  }
  lines.push('/* End PBXTargetDependency section */');

  // PBXNativeTarget
  lines.push('');
  lines.push('/* Begin PBXNativeTarget section */');
  for (const target of allTargets()) {
    lines.push(`\t\t${uid(`target:${target.name}`)} /* ${target.name} */ = {`);
    lines.push('\t\t\tisa = PBXNativeTarget;');
    lines.push(`\t\t\tbuildConfigurationList = ${uid(`configlist:${target.name}`)} /* Build configuration list for PBXNativeTarget "${target.name}" */;`);
    lines.push('\t\t\tbuildPhases = (');
    lines.push(`\t\t\t\t${target.sourcesPhase} /* Sources */,`);
    lines.push(`\t\t\t\t${target.frameworksPhase} /* Frameworks */,`);
    lines.push(`\t\t\t\t${target.resourcesPhase} /* Resources */,`);
    if (target.headersPhase) lines.push(`\t\t\t\t${target.headersPhase} /* Headers */,`);
    lines.push('\t\t\t);');
    lines.push('\t\t\tbuildRules = (');
    lines.push('\t\t\t);');
    lines.push('\t\t\tdependencies = (');
    for (const dependency of target.dependencies) {
      if (!allTargets().some((t) => t.name === dependency)) continue;
      lines.push(`\t\t\t\t${uid(`dependency:${target.name}:${dependency}`)} /* PBXTargetDependency */,`);
    }
    lines.push('\t\t\t);');
    lines.push(`\t\t\tname = ${target.name};`);
    lines.push(`\t\t\tproductName = ${target.name};`);
    lines.push(`\t\t\tproductReference = ${productUUIDFor(target.name)};`);
    lines.push(`\t\t\tproductType = ${quoted(productTypeFor(target.kind))};`);
    lines.push('\t\t};');
  }
  lines.push('/* End PBXNativeTarget section */');

  // PBXProject
  lines.push('');
  lines.push('/* Begin PBXProject section */');
  lines.push(`\t\t${uid('project')} /* Project object */ = {`);
  lines.push('\t\t\tisa = PBXProject;');
  lines.push('\t\t\tattributes = {');
  lines.push('\t\t\t\tBuildIndependentTargetsInParallel = 1;');
  lines.push('\t\t\t\tLastSwiftUpdateCheck = 2600;');
  lines.push('\t\t\t\tLastUpgradeCheck = 2600;');
  lines.push('\t\t\t\tTargetAttributes = {');
  for (const target of allTargets()) {
    lines.push(`\t\t\t\t\t${uid(`target:${target.name}`)} = {`);
    lines.push('\t\t\t\t\t\tCreatedOnToolsVersion = 26.0;');
    lines.push('\t\t\t\t\t};');
  }
  lines.push('\t\t\t\t};');
  lines.push('\t\t\t};');
  lines.push(`\t\t\tbuildConfigurationList = ${uid('configlist:project')} /* Build configuration list for PBXProject "${PROJECT_NAME}" */;`);
  lines.push('\t\t\tcompatibilityVersion = "Xcode 14.0";');
  lines.push('\t\t\tdevelopmentRegion = en;');
  lines.push('\t\t\thasScannedForEncodings = 0;');
  lines.push('\t\t\tknownRegions = (');
  lines.push('\t\t\t\ten,');
  lines.push('\t\t\t\tBase,');
  lines.push('\t\t\t);');
  lines.push('\t\t\tmainGroup = ' + rootUUID + ';');
  lines.push(`\t\t\tproductRefGroup = ${productsUUID} /* Products */;`);
  lines.push('\t\t\tprojectDirPath = "";');
  lines.push('\t\t\tprojectRoot = "";');
  lines.push('\t\t\ttargets = (');
  for (const target of allTargets()) lines.push(`\t\t\t\t${uid(`target:${target.name}`)} /* ${target.name} */,`);
  lines.push('\t\t\t);');
  lines.push('\t\t};');
  lines.push('/* End PBXProject section */');

  // XCBuildConfiguration
  lines.push('');
  lines.push('/* Begin XCBuildConfiguration section */');
  for (const target of allTargets()) {
    for (const config of ['Debug', 'Release']) {
      const settings = buildSettingsFor(target, config);
      lines.push(`\t\t${uid(`config:${target.name}:${config}`)} /* ${config} */ = {`);
      lines.push('\t\t\tisa = XCBuildConfiguration;');
      lines.push('\t\t\tbuildSettings = {');
      for (const [key, value] of Object.entries(settings)) {
        if (Array.isArray(value)) {
          lines.push(`\t\t\t\t${key} = (`);
          for (const item of value) lines.push(`\t\t\t\t\t${quoted(item)},`);
          lines.push('\t\t\t\t);');
        } else {
          lines.push(`\t\t\t\t${key} = ${quoted(String(value))};`);
        }
      }
      lines.push('\t\t\t};');
      lines.push(`\t\t\tname = ${config};`);
      lines.push('\t\t};');
    }
  }
  for (const config of ['Debug', 'Release']) {
    lines.push(`\t\t${uid(`config:project:${config}`)} /* ${config} */ = {`);
    lines.push('\t\t\tisa = XCBuildConfiguration;');
    lines.push('\t\t\tbuildSettings = {');
    const projectSettings = {
      ALWAYS_SEARCH_USER_PATHS: 'NO',
      CLANG_ENABLE_MODULES: 'YES',
      CLANG_ENABLE_OBJC_ARC: 'YES',
      COPY_PHASE_STRIP: 'NO',
      ENABLE_STRICT_OBJC_MSGSEND: 'YES',
      GCC_C_LANGUAGE_STANDARD: 'gnu17',
      GCC_NO_COMMON_BLOCKS: 'YES',
      MACOSX_DEPLOYMENT_TARGET: '15.0',
      SDKROOT: 'macosx',
      SWIFT_VERSION: '5.0',
      SWIFT_STRICT_CONCURRENCY: 'minimal',
      ONLY_ACTIVE_ARCH: config === 'Debug' ? 'YES' : 'NO',
      // Pin the build to this machine's architecture. The vendored `Vendor/zstd/lib/
      // libzstd.a` has an **arm64-only** slice, so the default Release build — which
      // does NOT set ONLY_ACTIVE_ARCH and therefore targets `arm64 x86_64` — fails in
      // the x86_64 link pass with "Undefined symbols: _ZSTD_isError …" and leaves an
      // `DSHNative.app` that contains nothing but an Info.plist, because xcodebuild
      // still assembles and ad-hoc signs the bundle after the executable fails to
      // link. That empty bundle is unusable: double-clicking it does nothing.
      // Making the arm64-only constraint explicit here is what turns Release into a
      // build that produces a launchable app. To build for Intel as well, the vendored
      // library first has to become a fat archive.
      ARCHS: '$(NATIVE_ARCH_ACTUAL)',
      // Debug injects the Xcode previews "debug dylib": `DSHNative` becomes a stub that
      // loads `DSHNative.debug.dylib`, which only resolves when Xcode launches the app.
      // Release must be one self-contained executable so the installed bundle can be
      // started by Launchpad/Finder with no Xcode involved.
      ENABLE_DEBUG_DYLIB: config === 'Debug' ? 'YES' : 'NO',
      DEBUG_INFORMATION_FORMAT: config === 'Debug' ? 'dwarf' : 'dwarf-with-dsym',
      SWIFT_OPTIMIZATION_LEVEL: config === 'Debug' ? '-Onone' : '-O',
      SWIFT_ACTIVE_COMPILATION_CONDITIONS: config === 'Debug' ? ['DEBUG', 'HARNESS_NATIVE', '$(inherited)'] : ['HARNESS_NATIVE', '$(inherited)'],
      SWIFT_COMPILATION_MODE: config === 'Debug' ? 'singlefile' : 'wholemodule',
      GCC_OPTIMIZATION_LEVEL: config === 'Debug' ? '0' : 's',
      ENABLE_TESTABILITY: config === 'Debug' ? 'YES' : 'NO',
      CODE_SIGN_STYLE: 'Automatic',
      // The embedded engine spawns node and writes outside the app container, so it
      // must never be sandboxed the App Store way.
      ENABLE_APP_SANDBOX: 'NO',
      ENABLE_HARDENED_RUNTIME: 'NO',
      DEAD_CODE_STRIPPING: config === 'Release' ? 'YES' : 'NO',
    };
    for (const [key, value] of Object.entries(projectSettings)) {
      if (Array.isArray(value)) {
        lines.push(`\t\t\t\t${key} = (`);
        for (const item of value) lines.push(`\t\t\t\t\t${quoted(item)},`);
        lines.push('\t\t\t\t);');
      } else {
        lines.push(`\t\t\t\t${key} = ${quoted(value)};`);
      }
    }
    lines.push('\t\t\t};');
    lines.push(`\t\t\tname = ${config};`);
    lines.push('\t\t};');
  }
  lines.push('/* End XCBuildConfiguration section */');

  // XCConfigurationList
  lines.push('');
  lines.push('/* Begin XCConfigurationList section */');
  lines.push(`\t\t${uid('configlist:project')} /* Build configuration list for PBXProject "${PROJECT_NAME}" */ = {`);
  lines.push('\t\t\tisa = XCConfigurationList;');
  lines.push('\t\t\tbuildConfigurations = (');
  for (const config of ['Debug', 'Release']) lines.push(`\t\t\t\t${uid(`config:project:${config}`)} /* ${config} */,`);
  lines.push('\t\t\t);');
  lines.push('\t\t\tdefaultConfigurationIsVisible = 0;');
  lines.push('\t\t\tdefaultConfigurationName = Release;');
  lines.push('\t\t};');
  for (const target of allTargets()) {
    lines.push(`\t\t${uid(`configlist:${target.name}`)} /* Build configuration list for PBXNativeTarget "${target.name}" */ = {`);
    lines.push('\t\t\tisa = XCConfigurationList;');
    lines.push('\t\t\tbuildConfigurations = (');
    for (const config of ['Debug', 'Release']) lines.push(`\t\t\t\t${uid(`config:${target.name}:${config}`)} /* ${config} */,`);
    lines.push('\t\t\t);');
    lines.push('\t\t\tdefaultConfigurationIsVisible = 0;');
    lines.push('\t\t\tdefaultConfigurationName = Release;');
    lines.push('\t\t};');
  }
  lines.push('/* End XCConfigurationList section */');

  lines.push('\t};');
  lines.push(`\trootObject = ${uid('project')} /* Project object */;`);
  lines.push('}');
  return lines.join('\n') + '\n';
}

// MARK: - Target metadata

function allTargets() {
  return [...modules, ...apps, tool, ...testBundles];
}

function productTypeFor(kind) {
  switch (kind) {
    case 'cframework':
    case 'framework':
      return 'com.apple.product-type.framework';
    case 'app':
      return 'com.apple.product-type.application';
    case 'tool':
      return 'com.apple.product-type.tool';
    case 'test':
      return 'com.apple.product-type.bundle.unit-test';
    default:
      return 'com.apple.product-type.framework';
  }
}

function productUUIDFor(name) {
  const product = products().find((p) => p.name === name || p.targetName === name);
  return product?.uuid;
}

function products() {
  const list = [];
  for (const module of modules) {
    list.push({
      uuid: uid(`product:${module.name}`),
      name: `${module.name}.framework`,
      targetName: module.name,
      path: `${module.name}.framework`,
      explicitType: 'wrapper.framework',
    });
  }
  for (const app of apps) {
    list.push({
      uuid: uid(`product:${app.name}`),
      name: `${app.name}.app`,
      targetName: app.name,
      path: `${app.name}.app`,
      explicitType: 'wrapper.application',
    });
  }
  list.push({
    uuid: uid(`product:${tool.name}`),
    name: tool.name,
    targetName: tool.name,
    path: tool.name,
    explicitType: 'compiled.mach-o.executable',
  });
  for (const bundle of testBundles) {
    list.push({
      uuid: uid(`product:${bundle.name}`),
      name: `${bundle.name}.xctest`,
      targetName: bundle.name,
      path: `${bundle.name}.xctest`,
      explicitType: 'wrapper.cfbundle',
    });
  }
  return list;
}

function buildSettingsFor(target, config) {
  const base = {
    PRODUCT_NAME: `$(TARGET_NAME)`,
    CURRENT_PROJECT_VERSION: '1',
    MARKETING_VERSION: '0.1.0',
    SWIFT_EMIT_LOC_STRINGS: 'NO',
    CODE_SIGN_STYLE: 'Manual',
    CODE_SIGN_IDENTITY: '-',
    DEVELOPMENT_TEAM: '',
    ...(target.settings ?? {}),
  };

  switch (target.kind) {
    case 'cframework':
      return {
        ...base,
        PRODUCT_BUNDLE_IDENTIFIER: `ai.deepseek.nativeharness.${target.name}`,
        DEFINES_MODULE: 'YES',
        PRODUCT_MODULE_NAME: target.name,
        MACH_O_TYPE: 'staticlib',
        SKIP_INSTALL: 'YES',
        DYLIB_INSTALL_NAME_BASE: '',
        INSTALL_PATH: '',
        // Public headers live in `include/`; Swift's `import CZstd` resolves through
        // the generated module map.
        PUBLIC_HEADERS_FOLDER_PATH: 'Headers',
        CLANG_ENABLE_MODULES: 'YES',
        // Frameworks are signed as well, and signing needs an Info.plist.
        GENERATE_INFOPLIST_FILE: 'YES',
      };
    case 'framework':
      return {
        ...base,
        PRODUCT_BUNDLE_IDENTIFIER: `ai.deepseek.nativeharness.${target.name}`,
        DEFINES_MODULE: 'YES',
        PRODUCT_MODULE_NAME: target.name,
        MACH_O_TYPE: 'staticlib',
        SKIP_INSTALL: 'YES',
        DYLIB_INSTALL_NAME_BASE: '',
        INSTALL_PATH: '',
        BUILD_LIBRARY_FOR_DISTRIBUTION: 'NO',
        // Same reason as the C framework: a signed target needs an Info.plist.
        GENERATE_INFOPLIST_FILE: 'YES',
      };
    case 'app': {
      const app = apps.find((a) => a.name === target.name);
      return {
        ...base,
        PRODUCT_BUNDLE_IDENTIFIER: app.bundleID,
        PRODUCT_NAME: target.name,
        GENERATE_INFOPLIST_FILE: 'YES',
        INFOPLIST_KEY_CFBundleDisplayName: app.displayName,
        // Compiles `Assets.xcassets/AppIcon.appiconset` into Assets.car and adds
        // `CFBundleIconName`/`CFBundleIconFile` to the generated Info.plist. This — not
        // `INFOPLIST_KEY_CFBundleIconFile`, which Xcode ignores — is what makes Finder
        // and Launchpad draw the app's own icon.
        ASSETCATALOG_COMPILER_APPICON_NAME: app.iconName,
        INFOPLIST_KEY_LSApplicationCategoryType: 'public.app-category.developer-tools',
        INFOPLIST_KEY_NSHumanReadableCopyright: '',
        INFOPLIST_KEY_NSPrincipalClass: 'NSApplication',
        INFOPLIST_KEY_LSMinimumSystemVersion: '15.0',
        ENABLE_HARDENED_RUNTIME: 'NO',
        // The app links the vendored zstd static library directly.
        LIBRARY_SEARCH_PATHS: ['$(inherited)', ZSTD_LIB_DIR],
        OTHER_LDFLAGS: ['-lzstd'],
        LD_RUNPATH_SEARCH_PATHS: ['$(inherited)', '@executable_path/../Frameworks'],
      };
    }
    case 'tool':
      return {
        ...base,
        PRODUCT_BUNDLE_IDENTIFIER: `ai.deepseek.nativeharness.${target.name}`,
        LIBRARY_SEARCH_PATHS: ['$(inherited)', ZSTD_LIB_DIR],
        OTHER_LDFLAGS: ['-lzstd'],
      };
    case 'test':
      return {
        ...base,
        PRODUCT_BUNDLE_IDENTIFIER: `ai.deepseek.nativeharness.${target.name}`,
        GENERATE_INFOPLIST_FILE: 'YES',
        LIBRARY_SEARCH_PATHS: ['$(inherited)', ZSTD_LIB_DIR],
        OTHER_LDFLAGS: ['-lzstd'],
        // Unit tests run without a host application.
        TEST_HOST: '',
        BUNDLE_LOADER: '',
      };
    default:
      return base;
  }
}

// Assign kinds for the emit pass.
for (const module of modules) {
  if (module.kind === 'cframework') module.kind = 'cframework';
}
for (const app of apps) app.kind = 'app';
tool.kind = 'tool';
for (const bundle of testBundles) bundle.kind = 'test';

// MARK: - Schemes

function simpleScheme(name, entries) {
  const buildEntries = entries
    .map(
      (entry) => `         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "${uid(`target:${entry.target}`)}"
               BuildableName = "${entry.productName}"
               BlueprintName = "${entry.target}"
               ReferencedContainer = "container:${PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>`
    )
    .join('\n');

  return `<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
${buildEntries}
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "${uid('target:HarnessKitTests')}"
               BuildableName = "HarnessKitTests.xctest"
               BlueprintName = "HarnessKitTests"
               ReferencedContainer = "container:${PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </TestableReference>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "${uid('target:ConformanceTests')}"
               BuildableName = "ConformanceTests.xctest"
               BlueprintName = "ConformanceTests"
               ReferencedContainer = "container:${PROJECT_NAME}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "${uid(`target:${entries[0].target}`)}"
            BuildableName = "${entries[0].productName}"
            BlueprintName = "${entries[0].target}"
            ReferencedContainer = "container:${PROJECT_NAME}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
`;
}

// MARK: - Write

function main() {
  // Everything the project file refers to must be registered before emission, because
  // the PBXBuildFile section is written in a single pass at the top of the file.
  //
  // Registering only the *groups* here was the original defect: the build files were
  // created later, while the Sources/Frameworks/Resources phases were being rendered —
  // by which point the PBXBuildFile section had already been written out empty. Xcode
  // silently ignored the phases' file lists, compiled zero sources, and reported
  // "BUILD SUCCEEDED" for an app bundle containing nothing but an Info.plist.
  for (const target of allTargets()) {
    for (const source of target.sources) addFileToGroup(source);
    for (const header of target.headers ?? []) addFileToGroup(header);
    for (const resource of target.resources ?? []) addFileToGroup(resource);

    // Must mirror exactly what the phase emitters call below.
    sourceBuildFiles(target.sources, target.name);
    for (const header of target.headers ?? []) headerBuildFileFor(header, target.name);
    for (const resource of target.resources ?? []) buildFileFor(resource, target.name);
    for (const dependency of target.dependencies) linkBuildFile(target.name, dependency);
  }

  const pbxproj = emitProject();

  rmSync(PROJECT_DIR, { recursive: true, force: true });
  mkdirSync(join(PROJECT_DIR, 'xcshareddata/xcschemes'), { recursive: true });
  writeFileSync(join(PROJECT_DIR, 'project.pbxproj'), pbxproj);

  const schemeEntries = {
    DSHNative: [{ target: 'DSHNative', productName: 'DSHNative.app' }],
    harnessctl: [{ target: 'harnessctl', productName: 'harnessctl' }],
  };
  for (const [name, entries] of Object.entries(schemeEntries)) {
    writeFileSync(join(PROJECT_DIR, `xcshareddata/xcschemes/${name}.xcscheme`), simpleScheme(name, entries));
  }

  const counts = allTargets()
    .map((t) => `${t.name}: ${t.sources.length} sources`)
    .join(', ');
  console.log(`wrote ${relative(ROOT, join(PROJECT_DIR, 'project.pbxproj'))}`);
  console.log(counts);
}

main();
