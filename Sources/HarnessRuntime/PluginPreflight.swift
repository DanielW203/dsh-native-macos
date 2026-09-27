import Foundation

/// What the app decided about a profile's plugins *before* switching to a release.
///
/// The distinction this type carries is the whole point of doing it before rather than after:
/// a plugin named here is one the app is about to turn off, so the caller has to be able to
/// say what it found, what it could not find, and what it actually disabled — in the same
/// report the user will read when the upgrade is over.
public struct PluginPreflightReport: Sendable, Equatable {
  /// Package name → the first line of the error. Only proof-backed findings.
  public var unloadable: [String: String]
  /// Names the app disabled as a result, sorted.
  public var quarantined: [String]
  /// Anything the probe could not decide, or the disable could not do.
  public var notes: [String]

  public init(
    unloadable: [String: String] = [:],
    quarantined: [String] = [],
    notes: [String] = []
  ) {
    self.unloadable = unloadable
    self.quarantined = quarantined
    self.notes = notes
  }

  public static let nothingFound = PluginPreflightReport()
}

/// The pre-upgrade half of the plugin repair: look, then take out of the picture.
///
/// A protocol rather than the concrete `PluginLoadProbe` + `PluginStore` pair, because the
/// interesting behaviour in the coordinator is what it does with the answer — proceed, note,
/// or refuse to touch anything — and none of that needs a profile, a Node, or a real plugin.
public protocol PluginPreflighting: Sendable {
  /// What would fail to load under `releaseID`.
  func findUnloadable(profile: String, releaseID: String) async -> PluginLoadProbeResult

  /// Turn these plugins off, recording that the app did it and for which release.
  ///
  /// - Returns: the names actually disabled, which may be shorter than the input when a
  ///   plugin is not in the profile's manifest at all.
  func quarantine(
    _ names: [String],
    profile: String,
    releaseID: String
  ) async -> [String]
}

/// The production preflight: the load probe, then the profile's own bundle list.
public struct PluginPreflight: PluginPreflighting {
  public let probe: PluginLoadProbe
  public let store: PluginStore

  public init(probe: PluginLoadProbe, store: PluginStore) {
    self.probe = probe
    self.store = store
  }

  public func findUnloadable(profile: String, releaseID: String) async -> PluginLoadProbeResult {
    await probe.probe(profile: profile, releaseID: releaseID)
  }

  public func quarantine(
    _ names: [String],
    profile: String,
    releaseID: String
  ) async -> [String] {
    var disabled: [String] = []
    for name in names.sorted() {
      do {
        _ = try await store.setEnabled(
          name,
          enabled: false,
          profile: profile,
          quarantinedDuring: releaseID
        )
        disabled.append(name)
      } catch {
        // A plugin that is not in the manifest cannot be disabled, and that is not a reason
        // to abandon the ones that can.
        continue
      }
    }
    return disabled
  }
}
