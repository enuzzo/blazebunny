import Foundation

/// Minimal thread-safe box for values shared with `@Sendable` callbacks.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ new: Value) { lock.withLock { stored = new } }
}
