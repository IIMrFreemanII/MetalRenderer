import EngineCore
import Foundation
import Plants

/// The Mixamo motions Tools/mixamo/download.py fetched: `METALRENDERER_MIXAMO`, or ~/MixamoAnimations, one folder per
/// character it was baked on, each with an index.json. Far too many to load at once (~2,450), so a run names the
/// ones it wants and CharacterLibrary.load() reads them with the clips in Assets/Characters/Animations:
/// - `METALRENDERER_CLIPS="Name, Name, random:24"` adds clips (`random:N` or `random:N:seed` picks N at random);
/// - `METALRENDERER_ROUTINE="Name:4, Name"` is the muscles figure's programme instead of its dance (CharacterRig),
///   each clip for its seconds, or its length once.
/// A name is a clip's Mixamo name, any case, a part of only one name, or the start of its id; a name several motions
/// share means the first of them. Empty and
/// silent without the folder.
struct MixamoLibrary {
    struct Entry: Decodable, Equatable {
        package var id: String
        package var name: String
        package var description: String?
        package var file: String
        package var duration: Double?
        package var loopable: Bool?
    }

    /// The clips, with the file each is read from: a motion baked on several characters is listed once, from the
    /// first folder (Y Bot's, then the others by name).
    private(set) var entries: [(entry: Entry, url: URL)] = []

    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["METALRENDERER_MIXAMO"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MixamoAnimations")
    }

    package init(_ directory: URL = MixamoLibrary.directory) {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let names = all.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.map(\.lastPathComponent).sorted()
        let folders = (names.filter { $0 == "Y Bot" } + names.filter { $0 != "Y Bot" }).map { directory.appendingPathComponent($0) }
        var seen = Set<String>()
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")) else { continue }
            guard let index = try? JSONDecoder().decode([Entry].self, from: data) else {
                print("Mixamo: could not read \(folder.lastPathComponent)/index.json")
                continue
            }
            for e in index where seen.insert(e.id).inserted {
                entries.append((e, folder.appendingPathComponent(e.file)))
            }
        }
    }

    /// The clip a name means (see the type's comment), or nil, with a message, if none or several do.
    func find(_ name: String) -> (entry: Entry, url: URL)? {
        let lower = name.lowercased()
        if let exact = entries.first(where: { $0.entry.name == name }) { return exact }
        if let caseless = entries.first(where: { $0.entry.name.lowercased() == lower }) { return caseless }
        if lower.count >= 4, let byID = entries.first(where: { $0.entry.id.hasPrefix(lower) }) { return byID }
        // Mixamo has several motions under one name (a man's and a woman's turn): a part of only that name means its first.
        let partial = entries.filter { $0.entry.name.lowercased().contains(lower) }
        if let first = partial.first, partial.allSatisfy({ $0.entry.name == first.entry.name }) { return first }
        print(partial.isEmpty ? "Mixamo: no clip \"\(name)\""
                              : "Mixamo: \"\(name)\" matches \(partial.count) clips (\(partial.prefix(5).map(\.entry.name).joined(separator: ", ")), ...)")
        return nil
    }

    /// `count` clips picked at random, the same ones for the same seed.
    func random(count: Int, seed: UInt64 = 1) -> [(entry: Entry, url: URL)] {
        var rng = SplitMix64(seed: seed), picked = entries
        for i in stride(from: picked.count - 1, to: 0, by: -1) { picked.swapAt(i, rng.int(i + 1)) }
        return Array(picked.prefix(count))
    }

    // MARK: What a run asks for

    /// `METALRENDERER_ROUTINE`'s steps, or nil.
    static let routine: [(clip: String, seconds: Float?)]? = ProcessInfo.processInfo.environment["METALRENDERER_ROUTINE"].map(parseRoutine)

    /// "Name:4, Name" as steps; a step's seconds follow its last colon.
    static func parseRoutine(_ text: String) -> [(clip: String, seconds: Float?)] {
        text.split(separator: ",").compactMap { part in
            let step = part.trimmingCharacters(in: .whitespaces)
            guard !step.isEmpty else { return nil }
            if let colon = step.lastIndex(of: ":"), let seconds = Float(step[step.index(after: colon)...].trimmingCharacters(in: .whitespaces)) {
                return (step[..<colon].trimmingCharacters(in: .whitespaces), seconds)
            }
            return (step, nil)
        }
    }

    /// The files of the clips `clips` (METALRENDERER_CLIPS's text) and `routine` ask for, less the names in `have`
    /// (the clips already in Assets/Characters/Animations), each once.
    func files(clips: String?, routine: [String], have: Set<String>) -> [URL] {
        var urls: [URL] = []
        func add(_ found: (entry: Entry, url: URL)?) {
            if let url = found?.url, !urls.contains(url) { urls.append(url) }
        }
        for name in routine where !have.contains(name) { add(find(name)) }
        for part in (clips ?? "").split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("random:") {
                let numbers = name.dropFirst("random:".count).split(separator: ":").compactMap { UInt64($0) }
                guard let count = numbers.first else { print("Mixamo: \"\(name)\" is not random:N or random:N:seed"); continue }
                random(count: Int(count), seed: numbers.count > 1 ? numbers[1] : 1).forEach(add)
            } else if !name.isEmpty, !have.contains(name) {
                add(find(name))
            }
        }
        return urls
    }

    /// The files this run's METALRENDERER_CLIPS and METALRENDERER_ROUTINE ask for, besides `have`.
    static func requested(have: Set<String>) -> [URL] {
        let env = ProcessInfo.processInfo.environment
        guard env["METALRENDERER_CLIPS"] != nil || routine != nil else { return [] }
        let library = shared
        let urls = library.files(clips: env["METALRENDERER_CLIPS"], routine: (routine ?? []).map(\.clip), have: have)
        print("Mixamo: \(urls.count) clips from \(library.entries.count) in \(directory.path)")
        return urls
    }

    /// The library in `directory`, read once.
    static let shared = MixamoLibrary()

    /// The index in `character`'s clips of the Mixamo clip `name` means (a part of its name, say), if it was loaded.
    static func loadedClip(_ name: String, in character: SkinnedCharacter) -> Int? {
        shared.find(name).flatMap { character.clip(named: clipName($0.url)) }
    }

    /// A clip's name from its file: "Hip Hop Dancing [c9c8f2a1].fbx" is "Hip Hop Dancing".
    static func clipName(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let open = stem.range(of: " [", options: .backwards), stem.hasSuffix("]"),
              stem[open.upperBound..<stem.index(before: stem.endIndex)].allSatisfy(\.isHexDigit) else { return stem }
        return String(stem[..<open.lowerBound])
    }
}
