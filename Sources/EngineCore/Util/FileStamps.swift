import Foundation

/// What each file the dev build watches held when the app last wrote it or looked at it (a hash of its bytes): the hot
/// reload (MetalRenderer's DevReload) acts on another program's saves, not on the app's own.
package enum FileStamps {
    private static let lock = NSLock()
    private static var stamps: [String: UInt64] = [:]

    /// `url` holds what the app just wrote.
    package static func note(_ url: URL) {
        guard let h = hash(url) else { return }
        lock.lock()
        stamps[url.standardizedFileURL.path] = h
        lock.unlock()
    }

    /// Whether `url` holds something else than when it was last noted or looked at (a first look: yes), or went.
    package static func changed(_ url: URL) -> Bool {
        let h = hash(url), key = url.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        let old = stamps[key]
        stamps[key] = h
        return h != old
    }

    private static func hash(_ url: URL) -> UInt64? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var hasher = Hasher64()
        data.withUnsafeBytes { hasher.add($0) }
        return hasher.value
    }
}
