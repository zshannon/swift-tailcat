import Foundation

/// A shareable, thread-safe set of canonical node public-key strings.
/// Use `Tailcat.Server.Policy(allowClient: { keys.contains(clientKey: $0) })` for admission.
/// Removing a key affects later admission; use `server.disconnect` or `revoke`
/// to end an established client's access.
extension Tailcat.Server {
public final class ClientKeySet: @unchecked Sendable {
    private var keys: Set<String>
    private let lock = NSLock()

    public init(clientKeys: [String] = []) { keys = Set(clientKeys) }

    public func add(clientKey: String) { _ = lock.withLock { keys.insert(clientKey) } }
    public func contains(clientKey: String) -> Bool { lock.withLock { keys.contains(clientKey) } }
    public func remove(clientKey: String) { _ = lock.withLock { keys.remove(clientKey) } }
}
}
