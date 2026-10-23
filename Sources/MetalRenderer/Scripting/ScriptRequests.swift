import Foundation

/// The socket's requests that other modules answer (the editors' `modeller`): a request whose key is registered here
/// goes to its handler, on the socket's client thread, with the key's body. The engine names none of them; whoever
/// registers one says what it takes. A handler's failure is a bad request when it says so (exit 2), else exit 1.
package enum ScriptRequests {
    package typealias Handler = (_ body: Any) -> Result<[String: Any], Failure>

    package struct Failure: Error, CustomStringConvertible {
        package let description: String
        /// The request itself was wrong (exit 2), not what it asked for (exit 1).
        package let badRequest: Bool
        package init(_ message: String, badRequest: Bool = false) {
            description = message
            self.badRequest = badRequest
        }
    }

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    /// `key` is answered by `handle` from now on (a second registration replaces the first).
    package static func register(_ key: String, _ handle: @escaping Handler) {
        lock.lock()
        handlers[key] = handle
        lock.unlock()
    }

    /// The handler of the first registered key `request` has, and that key's body.
    package static func handler(for request: [String: Any]) -> (key: String, body: Any, handle: Handler)? {
        lock.lock()
        defer { lock.unlock() }
        for (key, body) in request {
            if let h = handlers[key] { return (key, body, h) }
        }
        return nil
    }

    /// The keys registered.
    package static var keys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return handlers.keys.sorted()
    }
}
