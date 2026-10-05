import Metal
import simd

/// Matches `LumenCard` in Shaders/LumenCards.metal: one face of an instance's box, as a square of the atlas.
struct GPULumenCard {
    var atlas: SIMD4<UInt32>   // xy = the card's first texel in the atlas, z = its side (texels), w = face | instance << 3
    var lo: SIMD4<Float>       // the instance's box, in its own space
    var hi: SIMD4<Float>
}

/// Lumen's surface cache: cards on the faces of the instances' boxes (in their own space, so a moving instance keeps
/// its cards), captured once by rays from the face into the box (Shaders/LumenCards.metal), lit every frame, read where
/// GI rays hit. Each card is a square of 8 to 128 texels, sized by how big its face looks, in a 2048² atlas of 128²
/// pages; a page holds cards of one size. Faces on edge (thin boxes) get none, and nor do instances too small on
/// screen: their hits are lit as before.
final class LumenCards {
    static let atlasSize = 2048
    static let pageSize = 128
    static let sizes = 8...128
    static let noCard = UInt32.max

    struct Card {
        var origin: SIMD2<Int>
        var size: Int
    }

    /// The atlas: albedo (a = coverage), the surface's normal (object space, octahedral) and depth into the box
    /// (rgba16Unorm: xy = normal, z = depth, w = coverage), emission, direct light, and what hits read (albedo x light
    /// + emission).
    let albedo: MTLTexture
    let normalDepth: MTLTexture
    let emission: MTLTexture
    let direct: MTLTexture
    let final: MTLTexture
    /// Radiosity: indirect light, a texel per 4x4 block of the atlas (a = frames in its running mean).
    let indirect: MTLTexture

    private let device: MTLDevice
    private var cards: [[Card?]] = []            // per instance of the scene: its 6 faces'
    private var freePages: [SIMD2<Int>]
    private var freeSlots: [Int: [SIMD2<Int>]] = [:]
    private var lightCursor = 0                  // round robin over the cards to light
    private var radiosityCursor = 0              // ...and over those to update the radiosity of

    // Per frame slot: the cards, the instances' card table, the tiles to capture and light.
    private var cardBuffers: [MTLBuffer]
    private var tableBuffers: [MTLBuffer]
    private var tileBuffers: [MTLBuffer]
    private(set) var captureTiles = 0
    private(set) var lightTiles = 0
    private(set) var radiosityTiles = 0
    private(set) var cardCount = 0
    private(set) var texelsInUse = 0

    init(device: MTLDevice, frameSlots: Int) throws {
        self.device = device
        func make(_ format: MTLPixelFormat, _ label: String, side: Int = LumenCards.atlasSize) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: side, height: side, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation("texture \(label)") }
            t.label = label
            return t
        }
        albedo = try make(.rgba8Unorm, "lumen card albedo")
        normalDepth = try make(.rgba16Unorm, "lumen card normal depth")
        emission = try make(.rg11b10Float, "lumen card emission")
        direct = try make(.rg11b10Float, "lumen card direct")
        final = try make(.rg11b10Float, "lumen card final")
        indirect = try make(.rgba16Float, "lumen card indirect", side: LumenCards.atlasSize / 4)
        let pages = LumenCards.atlasSize / LumenCards.pageSize
        freePages = (0..<pages * pages).reversed().map { SIMD2($0 % pages, $0 / pages) &* LumenCards.pageSize }
        func buffers(_ length: Int, _ label: String) throws -> [MTLBuffer] {
            try (0..<frameSlots).map { i in
                guard let b = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                    throw RendererError.resourceCreation(label)
                }
                b.label = "\(label) \(i)"
                return b
            }
        }
        cardBuffers = try buffers(4096 * MemoryLayout<GPULumenCard>.stride, "lumen cards")
        tableBuffers = try buffers(4096 * 32, "lumen card table")
        tileBuffers = try buffers(65536 * 8, "lumen card tiles")
    }

    var megabytes: Int { (LumenCards.atlasSize * LumenCards.atlasSize * 24) >> 20 }

    func cards(slot: Int) -> MTLBuffer { cardBuffers[slot] }
    func table(slot: Int) -> MTLBuffer { tableBuffers[slot] }
    func tiles(slot: Int) -> MTLBuffer { tileBuffers[slot] }

    // MARK: - Allocation

    private func allocate(_ size: Int) -> SIMD2<Int>? {
        if freeSlots[size, default: []].isEmpty {
            guard let page = freePages.popLast() else { return nil }
            let n = LumenCards.pageSize / size
            freeSlots[size] = (0..<n * n).reversed().map { page &+ SIMD2($0 % n, $0 / n) &* size }
        }
        return freeSlots[size]!.popLast()
    }

    private func release(_ card: Card) { freeSlots[card.size, default: []].append(card.origin) }

    /// The side a face's card wants: a texel for every 2 pixels across the face (powers of two, 8...128); 0 = no card.
    static func wantedSize(extent: Float, pixelsPerMeter: Float) -> Int {
        let pixels = extent * pixelsPerMeter
        guard pixels >= 8 else { return 0 }
        let texels = min(max(pixels / 2, Float(sizes.lowerBound)), Float(sizes.upperBound))
        return 1 << Int(ceil(log2(texels)))
    }

    /// Faces: 0 +x, 1 -x, 2 +y, 3 -y, 4 +z, 5 -z. A face's card spans the box's two other axes.
    static func faceAxes(_ face: Int) -> (axis: Int, u: Int, v: Int) {
        let a = face / 2
        return (a, (a + 1) % 3, (a + 2) % 3)
    }

    // MARK: - The frame

    /// Sizes, allocates and schedules the cards for this frame, and writes slot `slot`'s buffers: the cards, the
    /// instances' card table, the capture tiles (cards new this frame), the lighting tiles (the new cards, then
    /// round robin up to `lightBudget` texels), then the radiosity tiles (alike, up to `radiosityBudget`).
    /// `eligible`: which of the scene's instances get cards.
    func update(scene: Scene, eligible: (Scene.Instance) -> Bool, camera: Camera, viewportHeight: Int, slot: Int,
                captureBudget: Int = 1 << 19, lightBudget: Int = 1 << 20, radiosityBudget: Int = 1 << 20) {
        let instances = scene.instances
        if cards.count != instances.count {
            for list in cards { for card in list { if let card { release(card) } } }
            cards = Array(repeating: Array(repeating: nil, count: 6), count: instances.count)
        }
        let pixelsAt1m = Float(viewportHeight) / (2 * tan(camera.fovY / 2))

        // Wanted sizes, the instances seen biggest first (they get the atlas when it runs out).
        var wanted: [(index: Int, sizes: [Int], priority: Float)] = []
        wanted.reserveCapacity(instances.count)
        for (i, inst) in instances.enumerated() {
            guard eligible(inst) else { wanted.append((i, [0, 0, 0, 0, 0, 0], 0)); continue }
            let (lo, hi) = scene.localBounds(of: inst)
            let m = inst.transform
            let axes = [SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                        SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)]
            let size = hi - lo
            let ext = SIMD3(length(axes[0]) * size.x, length(axes[1]) * size.y, length(axes[2]) * size.z)
            let centre4 = m * SIMD4((lo + hi) / 2, 1)
            let distance = max(length(SIMD3(centre4.x, centre4.y, centre4.z) - camera.position) - length(ext) / 2, 0.25)
            let ppm = pixelsAt1m / distance
            let largest = ext.max()
            let sizes = (0..<6).map { face -> Int in
                let (_, u, v) = LumenCards.faceAxes(face)
                guard largest > 0, min(ext[u], ext[v]) >= 0.05 * largest else { return 0 }   // on edge: no card
                return LumenCards.wantedSize(extent: max(ext[u], ext[v]), pixelsPerMeter: ppm)
            }
            wanted.append((i, sizes, largest * ppm))
        }
        wanted.sort { $0.priority > $1.priority }

        var capture: [SIMD2<Int>] = []   // (instance, face) captured this frame
        var captureTexels = 0
        for w in wanted {
            for face in 0..<6 {
                let want = w.sizes[face], old = cards[w.index][face]
                // Hysteresis: grow at once, shrink only to a quarter. A card keeps its old size until it has the new.
                if let old, want != 0 && want <= old.size && want * 4 > old.size { continue }
                if want == 0 {
                    if let old { release(old); cards[w.index][face] = nil }
                    continue
                }
                guard captureTexels + want * want <= captureBudget, let origin = allocate(want) else { continue }
                if let old { release(old) }
                cards[w.index][face] = Card(origin: origin, size: want)
                capture.append(SIMD2(w.index, face))
                captureTexels += want * want
            }
        }

        // The GPU's records: every card, the table, the tiles.
        var records: [GPULumenCard] = []
        var table = [UInt32](repeating: LumenCards.noCard, count: instances.count * 8)
        var index: [SIMD2<Int>: Int] = [:]
        texelsInUse = 0
        for (i, list) in cards.enumerated() {
            guard list.contains(where: { $0 != nil }) else { continue }
            let (lo, hi) = scene.localBounds(of: instances[i])
            for (face, card) in list.enumerated() {
                guard let card else { continue }
                index[SIMD2(i, face)] = records.count
                table[i * 8 + face] = UInt32(records.count)
                records.append(GPULumenCard(atlas: SIMD4(UInt32(card.origin.x), UInt32(card.origin.y), UInt32(card.size),
                                                         UInt32(face) | UInt32(i) << 3),
                                            lo: SIMD4(lo, 0), hi: SIMD4(hi, 0)))
                texelsInUse += card.size * card.size
            }
        }
        cardCount = records.count
        func tiles(of card: Int) -> [SIMD2<UInt32>] {
            let n = Int(records[card].atlas.z) / 8
            return (0..<n * n).map { SIMD2(UInt32(card), UInt32($0)) }
        }
        var tileList: [SIMD2<UInt32>] = capture.flatMap { tiles(of: index[$0]!) }
        captureTiles = tileList.count
        // Lighting: the new cards, then round robin.
        let fresh = Set(capture.map { index[$0]! })
        tileList += tileList   // (the capture tiles again: lit right after they are captured)
        func roundRobin(from cursor: inout Int, budget: Int) {
            guard !records.isEmpty else { return }
            var budget = budget
            cursor %= records.count
            var visited = 0
            while visited < records.count && budget > 0 {
                let c = (cursor + visited) % records.count
                visited += 1
                if fresh.contains(c) { continue }
                tileList += tiles(of: c)
                budget -= Int(records[c].atlas.z * records[c].atlas.z)
            }
            cursor += visited
        }
        roundRobin(from: &lightCursor, budget: lightBudget - captureTexels)
        lightTiles = tileList.count - captureTiles
        tileList += tileList[0..<captureTiles]
        roundRobin(from: &radiosityCursor, budget: radiosityBudget - captureTexels)
        radiosityTiles = tileList.count - captureTiles - lightTiles

        func write<T>(_ values: [T], to buffers: inout [MTLBuffer], _ label: String) {
            let bytes = values.count * MemoryLayout<T>.stride
            if buffers[slot].length < bytes, let b = device.makeBuffer(length: bytes * 2, options: .storageModeShared) {
                b.label = buffers[slot].label
                buffers[slot] = b
            }
            guard buffers[slot].length >= bytes else { return }
            values.withUnsafeBytes { buffers[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        }
        write(records, to: &cardBuffers, "lumen cards")
        write(table, to: &tableBuffers, "lumen card table")
        write(tileList, to: &tileBuffers, "lumen card tiles")
    }
}
