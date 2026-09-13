import Foundation

/// A lock-protected value shared between the app's main actor and the channel's actors.
///
/// The running harness URL changes as the harness starts and stops, and the channel reads it
/// from a background actor. Passing the current value through one small synchronized box is
/// less error-prone than reaching across actor boundaries for a UI-owned property — and it
/// keeps the token-bearing URL out of any log.
public final class SharedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  public init(_ initial: Value) {
    self.stored = initial
  }

  public var value: Value {
    get {
      lock.lock(); defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock(); stored = newValue; lock.unlock()
    }
  }
}
