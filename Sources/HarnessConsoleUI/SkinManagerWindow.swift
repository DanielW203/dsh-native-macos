import AppKit
import HarnessRuntime
import SwiftUI

/// The skin manager: every skin installed in the selected profile, one click to switch.
///
/// A window opened from the Harness menu rather than a page of the Web UI, because the Web
/// UI is exactly what a skin changes: a control surface that only exists once the current
/// skin renders it correctly is the wrong place to fix a skin that does not. What it does
/// is the same thing the plugin it replaces did — rewrite the profile's
/// `cordis.patch.yml` so exactly one skin is composed — which the running harness picks up
/// through its patch watcher, no restart involved.
public struct SkinManagerWindow: View {
  @ObservedObject var model: SkinManagerModel

  public init(model: SkinManagerModel) {
    self.model = model
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      list
      Divider()
      footer
    }
    .frame(minWidth: 780, minHeight: 580)
    // Opening the window before anything else must leave a fully loaded surface behind it.
    .task { model.startIfNeeded() }
  }

  // MARK: - Chrome

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("皮肤管理器").font(.headline)
        Text("profile \(model.selectedProfile) · DSH_HOME \(model.dshHome)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      Spacer()
      if model.isBusy {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(model.busyLabel ?? "处理中…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      // Only worth a picker when there is a choice to make; on a single-profile install it
      // would be a control that cannot do anything.
      if model.profiles.count > 1 {
        Picker("profile", selection: Binding(
          get: { model.selectedProfile },
          set: { model.selectProfile($0) }
        )) {
          ForEach(model.profiles, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .frame(width: 130)
      }
      Button {
        model.refresh()
      } label: {
        Label("刷新", systemImage: "arrow.clockwise")
      }
      .disabled(model.isBusy)
      .help("重新扫描这个 profile 的 node_modules 与 cordis.patch.yml")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var list: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        OfficialSkinCard(
          isActive: model.activeSkinID == nil,
          isBusy: model.isBusy,
          apply: { model.apply(nil) }
        )

        if !model.skins.isEmpty {
          Text("已安装皮肤（\(model.skins.count)）")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }

        ForEach(model.skins) { skin in
          SkinCard(
            skin: skin,
            isActive: model.isActive(skin),
            isBusy: model.isBusy,
            apply: { model.apply(skin) }
          )
        }

        if model.skins.isEmpty {
          emptyState
        }

        if !model.legacyPlugins.isEmpty {
          LegacyPluginsCard(model: model)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("这个 profile 里没有发现皮肤")
        .font(.callout)
      Text("皮肤是 node_modules 里带 skin.json（或符合市场主题约定）且带预构建 client bundle 的包。"
        + "装好皮肤后回到这里点「刷新」即可，不需要重启。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let failure = model.failure {
        MessageRow(systemImage: "exclamationmark.triangle.fill", tint: .red, text: failure)
      } else if let status = model.status {
        MessageRow(systemImage: "checkmark.circle.fill", tint: .green, text: status)
      }

      ForEach(model.warnings, id: \.self) { warning in
        MessageRow(systemImage: "exclamationmark.circle", tint: .orange, text: warning)
      }

      HStack(spacing: 10) {
        Text("切换 = 重写 profile 的 cordis.patch.yml，互斥生效；配置文件是热载入的。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("重载页面") { model.reloadPage() }
          .disabled(!model.needsPageReload)
          .help("让正在显示的页面重新加载，从而套用刚切换的皮肤")
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

// MARK: - Cards

/// The "no skin" row.
///
/// First in the list on purpose: it is the way back, and a user who has just put on a skin
/// they cannot read through needs to find it without hunting.
private struct OfficialSkinCard: View {
  let isActive: Bool
  let isBusy: Bool
  let apply: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
        Image(systemName: "circle.lefthalf.filled")
          .font(.system(size: 22))
          .foregroundStyle(.secondary)
      }
      .frame(width: 132, height: 88)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text("官方默认").font(.headline)
          if isActive { SkinBadge(text: "使用中", tint: .green) }
        }
        Text("DeepSeek Harness 原生外观：关闭全部已装皮肤。")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button(isActive ? "已启用" : "应用") { apply() }
        .disabled(isBusy || isActive)
    }
    .padding(12)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
  }
}

/// One installed skin.
private struct SkinCard: View {
  let skin: Skin
  let isActive: Bool
  let isBusy: Bool
  let apply: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      SkinPreview(skin: skin)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Circle()
            .fill(SkinColor(hex: skin.accent) ?? Color.secondary)
            .frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(.separator))
          Text(skin.name).font(.headline)
          if isActive { SkinBadge(text: "使用中", tint: .green) }
          // Said out loud rather than hidden: a bundle-wired skin is on through its own
          // bundle patch, which is why switching to it writes no insert row.
          if skin.isBundleWired { SkinBadge(text: "bundle 挂载", tint: .blue) }
          if !skin.hasSkinManifest { SkinBadge(text: "市场主题", tint: .secondary) }
        }

        Text("\(skin.id) · \(skin.package)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)

        if !skin.tagline.isEmpty {
          Text(skin.tagline)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if !skin.tags.isEmpty {
          Text(skin.tags.prefix(6).joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 6) {
        Button(isActive ? "已启用" : "应用") { apply() }
          .disabled(isBusy || isActive)
        if !skin.author.isEmpty {
          Text(skin.author).font(.caption2).foregroundStyle(.tertiary)
        }
      }
    }
    .padding(12)
    .background(
      isActive ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 10)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(isActive ? Color.accentColor.opacity(0.45) : Color.clear)
    )
  }
}

/// A skin's preview, following the window's appearance where the registry offers both.
private struct SkinPreview: View {
  let skin: Skin

  @State private var image: NSImage?
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill((SkinColor(hex: skin.accent) ?? Color.secondary).opacity(0.18))
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        Image(systemName: "paintbrush.pointed")
          .font(.system(size: 20))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 132, height: 88)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    .task(id: previewURL) {
      image = previewURL.flatMap { NSImage(contentsOf: $0) }
    }
  }

  private var previewURL: URL? {
    colorScheme == .dark
      ? (skin.previewDark ?? skin.previewLight)
      : (skin.previewLight ?? skin.previewDark)
  }
}

/// The replaced web plugins, and the offer to switch them off.
private struct LegacyPluginsCard: View {
  @ObservedObject var model: SkinManagerModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(model.legacyPlugins) { plugin in
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: "shippingbox")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
              Text(plugin.name).font(.callout).monospaced()
              if plugin.isEnabled {
                SkinBadge(text: "仍在启用", tint: .orange)
              } else {
                SkinBadge(text: "已停用", tint: .secondary)
              }
            }
            Text(plugin.isEnabled
              ? "这是本窗口替代的网页插件，它仍会写同一段 cordis.patch.yml。两个写入方会互相覆盖，建议停用它。"
              : "这是本窗口替代的网页插件，已停用。package.json 里的依赖仍保留，可以在「Plugin…」窗口里卸载。")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          if plugin.isEnabled {
            Button("停用") { Task { await model.disable(plugin) } }
              .disabled(model.isBusy)
          }
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    .padding(.top, 4)
  }
}

// MARK: - Small pieces

/// A status line: one icon, one sentence, and the tint that says which kind it is.
private struct MessageRow: View {
  let systemImage: String
  let tint: Color
  let text: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage).foregroundStyle(tint)
      Text(text)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      Spacer(minLength: 0)
    }
  }
}

private struct SkinBadge: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text)
      .font(.caption2)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(tint.opacity(0.16), in: Capsule())
      .foregroundStyle(tint)
  }
}

/// `#rrggbb` from a skin's registry, as a colour.
///
/// Returns nil for anything it does not recognise, so a registry with a typo in it falls
/// back to the neutral swatch instead of drawing a black circle that looks deliberate.
private func SkinColor(hex: String) -> Color? {
  var digits = hex
  if digits.hasPrefix("#") { digits.removeFirst() }
  guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
  return Color(
    red: Double((value >> 16) & 0xFF) / 255,
    green: Double((value >> 8) & 0xFF) / 255,
    blue: Double(value & 0xFF) / 255
  )
}
