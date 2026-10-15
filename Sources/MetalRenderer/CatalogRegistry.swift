import Foundation

/// Definitions that scenes are built with (a plant catalog, a building catalog), kept by key: a scene's settings
/// carry only the key (SceneSettings.plantCatalog, .buildingCatalog), so that settings stay small and comparable
/// and a scene made on another thread finds what the editor had at that moment. The newest `limit` are kept.
final class CatalogRegistry<T> {
    private let lock = NSLock()
    private var kept: [String: T] = [:]
    private var order: [String] = []          // oldest first
    private let limit: Int

    init(limit: Int = 64) { self.limit = limit }

    /// Keeps `value` under `key` (its fingerprint), unless it is kept already.
    func register(_ value: T, key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard kept[key] == nil else { return }
        kept[key] = value
        order.append(key)
        if order.count > limit { kept[order.removeFirst()] = nil }
    }

    /// What is kept under `key`, if it still is.
    func registered(_ key: String) -> T? {
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return kept[key]
    }
}
