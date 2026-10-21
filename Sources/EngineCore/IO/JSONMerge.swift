/// JSON objects laid over each other: what a saved file has replaces the defaults', key by key, objects merged in
/// depth (a settings file of an older version, a building style saved before a field was added).
package enum JSONMerge {
    package static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let b = base[k] as? [String: Any], let o = v as? [String: Any] { out[k] = merge(b, o) } else { out[k] = v }
        }
        return out
    }
}
