import Foundation
import HarnessKit

/// The provider/model/reasoning-effort triple the harness runs a turn with.
///
/// The harness calls this a *selection*: it is validated against the live adapter set, then
/// durably recorded on the session (`model/selection`), so it survives the turn and shows up in
/// the session list's `modelSelection` projection. `reasoningEffort == nil` is meaningful — it
/// means "whatever this provider defaults to", which is not the same as any named effort.
public struct HarnessModelSelection: Sendable, Equatable, Codable {
  public var provider: String
  public var model: String
  public var reasoningEffort: String?

  public init(provider: String, model: String, reasoningEffort: String? = nil) {
    self.provider = provider
    self.model = model
    self.reasoningEffort = reasoningEffort
  }

  /// What the phone shows: the model id, with the pinned effort when there is one.
  public var displayName: String {
    guard let reasoningEffort, !reasoningEffort.isEmpty else { return model }
    return "\(model) · \(reasoningEffort)"
  }

  /// Decode one selection off the wire.
  ///
  /// A selection is only meaningful with both a provider and a model, so a payload missing
  /// either is treated as "no selection" rather than as a partially applied one.
  public static func decode(_ value: JSONValue?) -> HarnessModelSelection? {
    guard let value,
          let provider = value["provider"]?.stringValue, !provider.isEmpty,
          let model = value["model"]?.stringValue, !model.isEmpty else { return nil }
    let effort = value["reasoningEffort"]?.stringValue
    return HarnessModelSelection(
      provider: provider,
      model: model,
      reasoningEffort: (effort?.isEmpty ?? true) ? nil : effort
    )
  }
}

/// One reasoning effort a model accepts (`high`, `medium`, `low`, …).
public struct HarnessModelEffort: Sendable, Equatable {
  public var id: String
  public var name: String
  public var detail: String?

  public init(id: String, name: String, detail: String? = nil) {
    self.id = id
    self.name = name
    self.detail = detail
  }
}

/// One selectable model, flattened out of the catalog's provider groups.
public struct HarnessModelChoice: Sendable, Equatable {
  public var provider: String
  public var providerName: String
  public var model: String
  public var name: String
  public var detail: String?
  public var efforts: [HarnessModelEffort]
  public var defaultEffort: String?

  public init(
    provider: String,
    providerName: String,
    model: String,
    name: String,
    detail: String? = nil,
    efforts: [HarnessModelEffort] = [],
    defaultEffort: String? = nil
  ) {
    self.provider = provider
    self.providerName = providerName
    self.model = model
    self.name = name
    self.detail = detail
    self.efforts = efforts
    self.defaultEffort = defaultEffort
  }

  /// What `/model <n>` installs when the user names no effort.
  ///
  /// The provider's own default for the newly chosen model, which is what the desktop model menu
  /// does: carrying the previous model's effort over would send `high` to a model whose adapter
  /// spells it `HIGH`, or has no such tier at all.
  public var defaultSelection: HarnessModelSelection {
    HarnessModelSelection(provider: provider, model: model, reasoningEffort: defaultEffort)
  }

  /// Resolve a user-typed effort against this model's own tiers.
  ///
  /// Case-insensitive on both the id and the display name, because the phone keyboard
  /// capitalizes the first word and the user reads the name, not the id.
  public func effort(matching target: String) -> HarnessModelEffort? {
    let needle = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return nil }
    return efforts.first { $0.id.lowercased() == needle }
      ?? efforts.first { $0.name.lowercased() == needle }
  }

  /// Whether two rows address the same provider-owned model.
  public func isSameModel(as selection: HarnessModelSelection?) -> Bool {
    selection?.provider == provider && selection?.model == model
  }
}

/// Everything the host will route to, as `session/modelCatalog` reports it.
///
/// Same value the desktop model menu reads, so the phone cannot offer a model the GUI does not,
/// and a provider that failed to enumerate itself is reported instead of being hidden.
public struct HarnessModelCatalog: Sendable, Equatable {
  public struct Failure: Sendable, Equatable {
    public var id: String
    public var name: String
    public var message: String

    public init(id: String, name: String, message: String) {
      self.id = id
      self.name = name
      self.message = message
    }
  }

  public var defaultSelection: HarnessModelSelection?
  public var choices: [HarnessModelChoice]
  public var failures: [Failure]

  public init(
    defaultSelection: HarnessModelSelection? = nil,
    choices: [HarnessModelChoice] = [],
    failures: [Failure] = []
  ) {
    self.defaultSelection = defaultSelection
    self.choices = choices
    self.failures = failures
  }

  public static func decode(_ value: JSONValue) -> HarnessModelCatalog {
    var choices: [HarnessModelChoice] = []
    for group in value["groups"]?.arrayValue ?? [] {
      let provider = group["id"]?.stringValue ?? ""
      guard !provider.isEmpty else { continue }
      let providerName = group["name"]?.stringValue ?? provider
      for model in group["models"]?.arrayValue ?? [] {
        guard let id = model["id"]?.stringValue, !id.isEmpty else { continue }
        let efforts = (model.path("reasoning.efforts")?.arrayValue ?? []).compactMap { raw -> HarnessModelEffort? in
          guard let effortID = raw["id"]?.stringValue, !effortID.isEmpty else { return nil }
          return HarnessModelEffort(
            id: effortID,
            name: raw["name"]?.stringValue ?? effortID,
            detail: raw["description"]?.stringValue
          )
        }
        choices.append(HarnessModelChoice(
          provider: provider,
          providerName: providerName,
          model: id,
          name: model["name"]?.stringValue ?? id,
          detail: model["description"]?.stringValue,
          efforts: efforts,
          defaultEffort: model.path("reasoning.defaultEffort")?.stringValue
        ))
      }
    }
    let failures = (value["failures"]?.arrayValue ?? []).compactMap { raw -> Failure? in
      guard let message = raw["message"]?.stringValue, !message.isEmpty else { return nil }
      return Failure(
        id: raw["id"]?.stringValue ?? "",
        name: raw["name"]?.stringValue ?? "",
        message: message
      )
    }
    return HarnessModelCatalog(
      defaultSelection: HarnessModelSelection.decode(value["default"]),
      choices: choices,
      failures: failures
    )
  }

  /// The row a typed target names: a model id, `provider/model`, or a display name.
  ///
  /// Ids win over names, and a bare id that several providers offer resolves to the first group
  /// the host listed — the same order the numbered listing shows, so the phone and the list agree.
  public func choice(matching target: String) -> HarnessModelChoice? {
    let needle = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return nil }
    if let slash = needle.firstIndex(of: "/") {
      let provider = String(needle[needle.startIndex..<slash])
      let model = String(needle[needle.index(after: slash)...])
      if let exact = choices.first(where: { $0.provider.lowercased() == provider && $0.model.lowercased() == model }) {
        return exact
      }
    }
    return choices.first { $0.model.lowercased() == needle }
      ?? choices.first { $0.name.lowercased() == needle }
      ?? choices.first { $0.model.lowercased().hasPrefix(needle) }
  }

  /// Which row a current selection belongs to, so `/effort` can list that model's tiers.
  public func choice(for selection: HarnessModelSelection?) -> HarnessModelChoice? {
    guard let selection else { return nil }
    return choices.first { $0.isSameModel(as: selection) }
  }
}

extension SessionSummary {
  /// What this session's next turn will run with.
  ///
  /// `session/list` projects the same value the desktop model menu shows: the pending selection
  /// when one is installed, otherwise the model the last request actually used. Reading it from
  /// the host — rather than remembering what the phone last set — is what keeps `/model` honest
  /// when the same session was changed from the desktop window.
  public var modelSelection: HarnessModelSelection? {
    guard let provider, !provider.isEmpty, let model, !model.isEmpty else { return nil }
    return HarnessModelSelection(provider: provider, model: model, reasoningEffort: reasoningEffort)
  }
}
