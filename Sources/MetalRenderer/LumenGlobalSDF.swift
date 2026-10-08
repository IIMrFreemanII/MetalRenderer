import Metal
import simd

/// Matches `LumenClipLevel` in Shaders/LumenSDF.metal: one level of the global distance field.
struct GPULumenClipLevel {
    var origin: SIMD4<Int32>    // xyz = the window's first cell (in this level's voxels, from the world's origin)
    var voxel: SIMD4<Float>     // x = voxel (m), y = band (m): what the level stores at most
}

/// Lumen's global distance field: a clipmap of `levels` windows of 128³ cells around the camera, each twice the
/// voxel of the one before, toroidal (a cell's texel is its absolute position modulo 128, so a window that moves
/// keeps what it had). Each cell holds the nearest distance to the instances' mesh fields (up to the level's band) and
/// which instance that is (its owner: a hit there is lit through that instance's cards). Cells are composed in bricks
/// of 8³ when they enter the window, when a moving instance's box (last frame's or this one's) touches them, and when
/// the scene's fields change; at most `budget` bricks a frame, the finest levels first.
final class LumenGlobalSDF {
    static let size = 128
    static let brick = 8
    static let bricksASide = size / brick
    static let bandVoxels: Float = 4

    let levels: Int
    let baseVoxel: Float
    let distance: MTLTexture        // r16Float 3D, the levels one above the other in z
    let owner: MTLTexture           // r32Uint 3D, alike
    private(set) var origins: [SIMD3<Int32>?]
    private var pending: [Set<SIMD3<Int32>>]   // per level: absolute bricks to compose
    private var dirtyBuffers: [MTLBuffer]
    let binLists: MTLBuffer
    static let budget = 4096
    static let binSize = 128        // a brick's instance list: a count, then up to 127 (LUMEN_BIN)

    private(set) var dirtyCount = 0

    var megabytes: Int { (LumenGlobalSDF.size * LumenGlobalSDF.size * LumenGlobalSDF.size * levels * 6) >> 20 }

    /// Levels and voxel for a scene of these bounds: 0.1 m at the finest (0.2 m in the large outdoor scenes), and
    /// enough levels (2...6) for the coarsest to reach across the scene.
    static func layout(bounds: (SIMD3<Float>, SIMD3<Float>), large: Bool, voxel chosen: Float = 0) -> (levels: Int, voxel: Float) {
        let voxel: Float = chosen > 0 ? chosen : large ? 0.2 : 0.1
        let radius = length(bounds.1 - bounds.0) / 2
        var levels = 2
        while levels < 6 && Float(size) / 2 * voxel * Float(1 << (levels - 1)) < radius { levels += 1 }
        return (levels, voxel)
    }

    init(device: MTLDevice, levels: Int, voxel: Float, frameSlots: Int) throws {
        self.levels = levels
        baseVoxel = voxel
        func volume(_ format: MTLPixelFormat, _ label: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = .type3D
            d.pixelFormat = format
            d.width = LumenGlobalSDF.size
            d.height = LumenGlobalSDF.size
            d.depth = LumenGlobalSDF.size * levels
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RendererError.resourceCreation(label) }
            t.label = label
            return t
        }
        distance = try volume(.r16Float, "lumen global sdf")
        owner = try volume(.r32Uint, "lumen global owner")
        origins = Array(repeating: nil, count: levels)
        pending = Array(repeating: [], count: levels)
        dirtyBuffers = try (0..<frameSlots).map { i in
            guard let b = device.makeBuffer(length: LumenGlobalSDF.budget * 16, options: .storageModeShared) else {
                throw RendererError.resourceCreation("lumen global dirty")
            }
            b.label = "lumen global dirty \(i)"
            return b
        }
        guard let bins = device.makeBuffer(length: LumenGlobalSDF.budget * LumenGlobalSDF.binSize * 4, options: .storageModePrivate) else {
            throw RendererError.resourceCreation("lumen global bins")
        }
        binLists = bins
    }

    func voxel(level: Int) -> Float { baseVoxel * Float(1 << level) }

    /// The window of a level around the camera: its first cell, on a brick, the camera in the middle.
    static func window(camera: SIMD3<Float>, voxel: Float) -> SIMD3<Int32> {
        let cell = SIMD3<Int32>((camera / voxel).rounded(.down))
        let b = Int32(brick)
        let floorDiv = SIMD3<Int32>(cell.x >= 0 ? cell.x / b : (cell.x - b + 1) / b, cell.y >= 0 ? cell.y / b : (cell.y - b + 1) / b,
                                    cell.z >= 0 ? cell.z / b : (cell.z - b + 1) / b)
        return (floorDiv &- Int32(bricksASide / 2)) &* b
    }

    /// The bricks (absolute) of window `new` that window `old` didn't have (all of them without an old one).
    static func enteringBricks(old: SIMD3<Int32>?, new: SIMD3<Int32>) -> [SIMD3<Int32>] {
        let b = Int32(brick), n = Int32(bricksASide)
        let first = new / b
        var out: [SIMD3<Int32>] = []
        for z in 0..<n { for y in 0..<n { for x in 0..<n {
            let a = first &+ SIMD3(x, y, z)
            if let old {
                let o = old / b
                if all(a .>= o) && all(a .< o &+ n) { continue }
            }
            out.append(a)
        } } }
        return out
    }

    /// The bricks of window `origin` that a box (grown by the level's band) touches.
    static func bricks(touching box: AABB, voxel: Float, band: Float, origin: SIMD3<Int32>) -> [SIMD3<Int32>] {
        let b = Float(brick) * voxel, n = Int32(bricksASide)
        let first = origin / Int32(brick)
        let lo = simd_max(SIMD3<Int32>(((box.lo - band) / b).rounded(.down)), first)
        let hi = simd_min(SIMD3<Int32>(((box.hi + band) / b).rounded(.down)), first &+ n &- 1)
        guard all(lo .<= hi) else { return [] }
        var out: [SIMD3<Int32>] = []
        for z in lo.z...hi.z { for y in lo.y...hi.y { for x in lo.x...hi.x { out.append(SIMD3(x, y, z)) } } }
        return out
    }

    /// This frame's windows and the bricks to compose (written to slot `slot`'s list, finest level first, at most
    /// `budget`; the rest wait). `changed`: boxes whose fields changed this frame (moving instances, then and now).
    /// `everything`: the scene's fields changed (a bake landed): every brick again.
    func update(camera: SIMD3<Float>, changed: [AABB], everything: Bool, slot: Int) -> [GPULumenClipLevel] {
        var out: [GPULumenClipLevel] = []
        for l in 0..<levels {
            let v = voxel(level: l), band = LumenGlobalSDF.bandVoxels * v
            let origin = LumenGlobalSDF.window(camera: camera, voxel: v)
            if everything { pending[l].removeAll(); origins[l] = nil }
            if origins[l] != origin {
                let entering = LumenGlobalSDF.enteringBricks(old: origins[l], new: origin)
                // Bricks that left the window are dropped from the queue; new ones join it.
                if let old = origins[l], old != origin {
                    let first = origin / Int32(LumenGlobalSDF.brick), n = Int32(LumenGlobalSDF.bricksASide)
                    pending[l] = pending[l].filter { all($0 .>= first) && all($0 .< first &+ n) }
                }
                pending[l].formUnion(entering)
                origins[l] = origin
            }
            for box in changed { pending[l].formUnion(LumenGlobalSDF.bricks(touching: box, voxel: v, band: band, origin: origin)) }
            out.append(GPULumenClipLevel(origin: SIMD4(origin, 0), voxel: SIMD4(v, band, 0, 0)))
        }
        var list: [SIMD4<Int32>] = []
        for l in 0..<levels where list.count < LumenGlobalSDF.budget {
            // Nearest the camera first within a level.
            let centre = SIMD3<Int32>((camera / (voxel(level: l) * Float(LumenGlobalSDF.brick))).rounded(.down))
            let sorted = pending[l].sorted { length_squared(SIMD3<Float>($0 &- centre)) < length_squared(SIMD3<Float>($1 &- centre)) }
            let take = sorted.prefix(LumenGlobalSDF.budget - list.count)
            for b in take { list.append(SIMD4(b, Int32(l))) }
            pending[l].subtract(take)
        }
        dirtyCount = list.count
        list.withUnsafeBytes { if let base = $0.baseAddress { dirtyBuffers[slot].contents().copyMemory(from: base, byteCount: $0.count) } }
        return out
    }

    func dirty(slot: Int) -> MTLBuffer { dirtyBuffers[slot] }
    var isComplete: Bool { pending.allSatisfy(\.isEmpty) }
}
