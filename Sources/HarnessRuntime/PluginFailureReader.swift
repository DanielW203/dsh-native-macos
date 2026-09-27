import Foundation

/// Reads a failed boot's output for the plugins it blames.
///
/// A tiny namespace rather than a method on the coordinator, because the reading rules belong
/// to the same parser the quarantine loop uses — `ProfileImporter.pluginSuspects` — and this is
/// the public door onto it for a caller that only has the output. Two copies of "which name
/// does this message blame" would drift the moment upstream changes a message, which is
/// exactly the failure this whole feature exists to stop repeating.
public enum PluginFailureReader {
  /// The names this output blames, narrowed to those `known` says the profile has.
  ///
  /// - Parameter known: the profile's declared package names. Passing the set in rather than
  ///   reading the manifest here keeps this a pure function of the output, which is what makes
  ///   it testable against a real captured boot log.
  public static func suspects(
    in diagnostic: String,
    profile: String,
    known: Set<String>
  ) -> [String] {
    ProfileImporter.pluginSuspects(in: diagnostic, profile: profile, known: known)
  }

  /// The same reading, with the profile's package names read from `paths`.
  public static func suspects(
    in diagnostic: String,
    profile: String,
    paths: RuntimePaths
  ) -> [String] {
    let manifestURL = paths.profilesDirectory
      .appendingPathComponent(profile, isDirectory: true)
      .appendingPathComponent("package.json")
    let manifest = try? ProfileManifest.read(manifestURL)
    let known: Set<String> = manifest.map { Set(ProfileManifest.dependencies($0).keys) } ?? []
    return suspects(in: diagnostic, profile: profile, known: known)
  }
}
