import Foundation
import ImageIO
import Metal

/// Streams material textures at full resolution under a memory budget.
///
/// * On first load, every image of a model is decoded at full size, mipmapped on the GPU and written with its whole mip
///   chain to a cache file next to the model (`.metalrenderer-cache/<model>-<size>-<mtime>-t1.mgt`), read back memory-mapped.
/// * Textures are sparse, backed by a heap the size of the budget (or of all their levels, if that is less): on Metal 3
///   a sparse heap, which places the tiles
///   itself; on Metal 4 (whose residency sets take no sparse heap) placement-sparse textures on a placement heap, whose
///   tiles the streamer hands out (`TileAllocator`). At first only their small mips (up to `residentBaseSize` pixels,
///   and the packed mip tail) are mapped and uploaded, by the first `update`.
/// * Every frame the shaders record, per texture, the finest mip level primary and sharp reflection hits sampled
///   (`feedback`, an atomic min); the CPU maps and uploads finer levels ahead of this frame's work (`TextureStreamWork`),
///   coarsest first, within a per-frame upload budget, and when the heap is full unmaps the finest levels of textures
///   nobody needed lately. Shaders clamp the level to what's resident (`minLod`, per frame slot), so a missing level is
///   only blur.
final class TextureStreamer {
    static let enabled = ProcessInfo.processInfo.environment["METALRENDERER_TEXTURE_STREAMING"] != "0"
    static let residentBaseSize = 128             // levels at most this big are always resident
    private static let magic: UInt32 = 0x3154_474D   // "MGT1"

    private struct Level { var offset: Int; var size: Int; var width: Int; var height: Int }
    private struct Entry {
        var texture: MTLTexture
        var data: Data                    // the cache file (mapped)
        var levels: [Level]
        var resident: Int                 // finest mapped level
        var floor: Int                    // finest level that is always mapped (base / tail)
        var wanted: Int                   // finest level requested lately
        var lastUsed: UInt32 = 0
        var bytesPerLevel: [Int]          // heap bytes each mapped level costs (tile-rounded; the tail level: the tail)
        var tiles: [[Int]]                // placement: the heap tiles each mapped level holds
    }

    private let device: MTLDevice
    /// Metal 3: a sparse heap. Metal 4: a placement heap (`placement`).
    let heap: MTLHeap
    let budgetBytes: Int
    private let tileBytes: Int
    private var tileAllocator: TileAllocator?       // placement only
    private var entries: [Entry] = []
    private var mappedBytes = 0
    private var minLodBuffers: [MTLBuffer] = []     // per slot: float per texture
    private var feedbackBuffers: [MTLBuffer] = []   // per slot: 16 counters per texture (samples wanting each level)
    private var pendingUnmaps: [(entry: Int, level: Int, frame: UInt32)] = []
    private let lock = NSLock()
    private var collected: [UInt32] = []            // level histograms (16 per texture) from the last completed frame(s)
    static let levelBins = 16
    // Uploads go through each slot's staging buffers, reused once the slot's last frame is done and grown when a frame
    // needs more (Metal 4 keeps them resident, so they last).
    private var staging: [[MTLBuffer]]
    private var stagingCursor = (slot: 0, buffer: 0, offset: 0)
    private var work = TextureStreamWork()
    var uploadBytesPerFrame = 48 << 20
    private(set) var stats = (residentMB: 0.0, uploadedMB: 0.0, levelsMapped: 0)

    var placement: Bool { tileAllocator != nil }
    var textures: [MTLTexture] { entries.map(\.texture) }
    /// Per texture: its finest level the shaders may sample.
    var residentLevels: [Int] { entries.map(\.resident) }
    /// The levels mapped of those the textures want (base levels first), summed over the textures (render thread): the
    /// loading overlay's progress. Done when every texture has what it wants.
    var levelProgress: (done: Int, total: Int) {
        var done = 0, total = 0
        for e in entries {
            let wanted = e.levels.count - min(e.wanted, e.floor)
            total += wanted
            done += min(e.levels.count - e.resident, wanted)
        }
        return (done, total)
    }
    var details: String {
        entries.map { e in "  \(e.texture.label ?? "?"): \(e.levels[0].width)px wanted \(e.wanted) resident \(e.resident)" }
            .joined(separator: "\n")
    }
    var summary: String {
        let finest = entries.map(\.resident).min() ?? 0
        return String(format: "Textures: %.0f MB resident of %d, %d levels mapped, %.0f MB uploaded, finest level %d",
                      stats.residentMB, budgetBytes >> 20, stats.levelsMapped, stats.uploadedMB, finest)
    }
    func minLodBuffer(slot: Int) -> MTLBuffer { minLodBuffers[slot] }
    func feedbackBuffer(slot: Int) -> MTLBuffer { feedbackBuffers[slot] }

    /// Metal 3 streams through a sparse heap, Metal 4 through placement-sparse textures (macOS 26.4).
    static func isSupported(_ device: MTLDevice, api: RenderAPI) -> Bool {
        guard enabled && device.supportsFamily(.apple6) else { return false }
        if api == .metal3 { return true }
        if #available(macOS 26.4, *) { return device.supportsPlacementSparse }
        return false
    }

    /// `placement`: placement-sparse textures on a placement heap, for Metal 4's queue (see `isSupported`).
    /// `load`: the load to report the cache files and textures to.
    init(sources: [Scene.TextureSource], device: MTLDevice, queue: MTLCommandQueue, budgetMB: Int, slots: Int,
         placement: Bool, load: LoadJob? = nil) throws {
        self.device = device
        let start = CFAbsoluteTimeGetCurrent()
        let step = load?.step("Textures", total: sources.count)
        let pageSize = MTLSparsePageSize.size64
        let tileBytes = placement ? device.sparseTileSizeInBytes(sparsePageSize: pageSize) : device.sparseTileSizeInBytes
        self.tileBytes = tileBytes
        // Cache files: one per model file, holding all of its images' mip chains.
        let cached = try TextureStreamer.loadCaches(sources, device: device, queue: queue, step: step)
        step?.set(done: 0, detail: "sparse textures")
        // The heap: as large as the budget, or as everything these textures could ever map, if that is less. (It
        // counts in full against the process whatever is mapped of it, and a generated scene's textures are a tenth
        // of the budget.) A level is a tile at least: more than the mip tail takes.
        var whole = 0
        for (i, source) in sources.enumerated() {
            let format: MTLPixelFormat = source.srgb ? .rgba8Unorm_srgb : .rgba8Unorm
            let tile = placement ? device.sparseTileSize(textureType: .type2D, pixelFormat: format, sampleCount: 1, sparsePageSize: pageSize)
                : device.sparseTileSize(with: .type2D, pixelFormat: format, sampleCount: 1)
            for level in cached[i].1 {
                whole += max(((level.width + tile.width - 1) / tile.width) * ((level.height + tile.height - 1) / tile.height), 1) * tileBytes
            }
        }
        budgetBytes = max(min(budgetMB << 20, whole), tileBytes * 1024) / tileBytes * tileBytes
        let hd = MTLHeapDescriptor()
        hd.storageMode = .private
        hd.size = budgetBytes
        hd.type = .sparse
        if placement, #available(macOS 26.0, *) {
            hd.type = .placement
            hd.maxCompatiblePlacementSparsePageSize = pageSize
            tileAllocator = TileAllocator(count: budgetBytes / tileBytes)
        }
        guard let heap = device.makeHeap(descriptor: hd) else { throw RendererError.resourceCreation("sparse texture heap") }
        heap.label = "textureHeap"
        self.heap = heap
        staging = Array(repeating: [], count: slots)

        var baseBytes = 0
        for (i, source) in sources.enumerated() {
            let (data, levels) = cached[i]
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.srgb ? .rgba8Unorm_srgb : .rgba8Unorm,
                                                                width: levels[0].width, height: levels[0].height, mipmapped: true)
            desc.mipmapLevelCount = levels.count
            desc.usage = .shaderRead
            desc.storageMode = .private
            var made: MTLTexture?
            if placement, #available(macOS 26.0, *) {
                desc.placementSparsePageSize = pageSize
                made = device.makeTexture(descriptor: desc)
            } else {
                made = heap.makeTexture(descriptor: desc)
            }
            guard let texture = made else { throw RendererError.resourceCreation("sparse texture \(source.name)") }
            texture.label = source.name
            let tile = tileSize(texture.pixelFormat)
            let tail = texture.firstMipmapInTail ?? levels.count
            var cost: [Int] = []
            for (l, lv) in levels.enumerated() {
                if l > tail { cost.append(0); continue }
                if l == tail { cost.append(placement ? tailTiles(texture) * tileBytes : texture.tailSizeInBytes ?? 0); continue }
                let tx = (lv.width + tile.width - 1) / tile.width, ty = (lv.height + tile.height - 1) / tile.height
                cost.append(tx * ty * tileBytes)
            }
            let floor = min(tail, levels.firstIndex { max($0.width, $0.height) <= TextureStreamer.residentBaseSize } ?? tail)
            baseBytes += cost[floor...].reduce(0, +)
            entries.append(Entry(texture: texture, data: data, levels: levels, resident: levels.count, floor: floor,
                                 wanted: floor, bytesPerLevel: cost, tiles: Array(repeating: [], count: levels.count)))
            step?.advance()
        }
        for slot in 0..<slots {
            guard let m = device.makeBuffer(length: max(entries.count, 1) * 4, options: .storageModeShared),
                  let f = device.makeBuffer(length: max(entries.count, 1) * 4 * TextureStreamer.levelBins, options: .storageModeShared) else {
                throw RendererError.resourceCreation("texture streaming buffers")
            }
            m.label = "textureMinLod\(slot)"
            f.label = "textureFeedback\(slot)"
            memset(f.contents(), 0, f.length)
            minLodBuffers.append(m)
            feedbackBuffers.append(f)
        }
        collected = [UInt32](repeating: 0, count: entries.count * TextureStreamer.levelBins)
        for slot in 0..<slots { writeMinLod(slot: slot) }   // nothing yet: the first `update` maps the base levels
        print(String(format: "Textures: %d streamed (%@, budget %d MB, %.1f MB base levels), ready in %.1f s", entries.count,
                     placement ? "placement sparse" : "sparse", budgetBytes >> 20, Double(baseBytes) / 1_048_576,
                     CFAbsoluteTimeGetCurrent() - start))
    }

    /// Render thread, ahead of `frame`'s own work: apply the latest feedback, map and upload finer levels, schedule
    /// unmaps, publish this slot's resident levels, reset its feedback. Returns what the frame has to encode.
    func update(frame: UInt32, slot: Int, framesInFlight: Int) -> TextureStreamWork {
        work = TextureStreamWork()
        stagingCursor = (slot, 0, 0)
        lock.lock()
        let feedback = collected
        for i in collected.indices { collected[i] = 0 }
        lock.unlock()
        let bins = TextureStreamer.levelBins
        for i in entries.indices {
            let h = feedback[(bins * i)..<(bins * (i + 1))]
            let total = h.reduce(0) { $0 + Int($1) }
            if total > 0 {
                // The finest level at least 1.5% of the samples need.
                let threshold = max(2, total / 64)
                var cumulative = 0, level = bins - 1
                for (l, c) in h.enumerated() {
                    cumulative += Int(c)
                    if cumulative >= threshold { level = l; break }
                }
                entries[i].wanted = max(0, min(level, entries[i].floor))
                entries[i].lastUsed = frame
            } else if entries[i].lastUsed &+ 120 < frame {
                entries[i].wanted = entries[i].floor   // out of view for two seconds: back to the base levels
            }
        }
        // Unmaps whose frames are done (their tiles are free again from here on).
        pendingUnmaps.removeAll { u in
            guard u.frame &+ UInt32(framesInFlight) < frame else { return false }
            work.add(entries[u.entry].texture, SparseMapping(mode: .unmap, level: u.level, region: tileRegion(u.entry, u.level)))
            tileAllocator?.free(entries[u.entry].tiles[u.level])
            entries[u.entry].tiles[u.level] = []
            return true
        }
        // The always-resident levels (all of them in the first frame).
        for i in entries.indices where entries[i].resident > entries[i].floor {
            requestLevels(i, upTo: entries[i].floor, budget: .max)
        }
        // Finer levels for the textures that want them, the most wanted (biggest step) first.
        var budget = uploadBytesPerFrame
        let order = entries.indices.filter { entries[$0].wanted < entries[$0].resident }
            .sorted { entries[$0].resident - entries[$0].wanted > entries[$1].resident - entries[$1].wanted }
        for i in order where budget > 0 {
            let next = entries[i].resident - 1   // one level per texture per frame
            let cost = entries[i].bytesPerLevel[next]
            if mappedBytes + cost > budgetBytes { evict(needing: cost, frame: frame) }
            if mappedBytes + cost > budgetBytes { continue }
            budget -= requestLevels(i, upTo: next, budget: budget)
        }
        // Textures holding finer levels than they want give the finest back, one per frame (hysteresis: only after
        // they haven't asked for it for a second).
        for i in entries.indices where entries[i].resident < entries[i].wanted && entries[i].lastUsed &+ 60 < frame {
            dropFinest(i, frame: frame)
        }
        writeMinLod(slot: slot)
        memset(feedbackBuffers[slot].contents(), 0, feedbackBuffers[slot].length)
        stats.residentMB = Double(mappedBytes) / 1_048_576
        return work
    }

    /// The frame that used `slot` finished: fold its feedback in (any thread).
    func collect(slot: Int) {
        let n = entries.count * TextureStreamer.levelBins
        let f = feedbackBuffers[slot].contents().bindMemory(to: UInt32.self, capacity: n)
        lock.lock()
        for i in 0..<n { collected[i] &+= f[i] }
        lock.unlock()
    }


    // MARK: Mapping

    private func tileSize(_ format: MTLPixelFormat) -> MTLSize {
        placement ? device.sparseTileSize(textureType: .type2D, pixelFormat: format, sampleCount: 1, sparsePageSize: .size64)
            : device.sparseTileSize(with: .type2D, pixelFormat: format, sampleCount: 1)
    }

    /// Tiles the packed mip tail of a placement-sparse texture takes.
    private func tailTiles(_ t: MTLTexture) -> Int { max(1, ((t.tailSizeInBytes ?? 0) + tileBytes - 1) / tileBytes) }

    private func tileRegion(_ i: Int, _ level: Int) -> MTLRegion {
        let t = entries[i].texture
        if level >= (t.firstMipmapInTail ?? Int.max) { return MTLRegionMake3D(0, 0, 0, placement ? tailTiles(t) : 1, 1, 1) }
        let tile = tileSize(t.pixelFormat)
        let lv = entries[i].levels[level]
        return MTLRegionMake3D(0, 0, 0, (lv.width + tile.width - 1) / tile.width, (lv.height + tile.height - 1) / tile.height, 1)
    }

    /// Placement: heap tiles for `level` of entry `i` and the mappings that put them there (per tile row, runs of
    /// consecutive heap tiles in one operation; the tail in one run). Nil when the heap has no room for it.
    private func placeLevel(_ i: Int, _ level: Int) -> [SparseMapping]? {
        let region = tileRegion(i, level)
        let tx = region.size.width, ty = region.size.height
        let tiles: [Int]
        if level >= (entries[i].texture.firstMipmapInTail ?? Int.max) {
            guard let first = tileAllocator?.allocateRun(tx) else { return nil }
            tiles = Array(first..<(first + tx))
        } else {
            guard let some = tileAllocator?.allocate(tx * ty) else { return nil }
            tiles = some
        }
        entries[i].tiles[level] = tiles
        var ops: [SparseMapping] = []
        for y in 0..<ty {
            var x = 0
            while x < tx {
                let first = tiles[y * tx + x]
                var n = 1
                while x + n < tx && tiles[y * tx + x + n] == first + n { n += 1 }
                ops.append(SparseMapping(mode: .map, level: level, region: MTLRegionMake3D(x, y, 0, n, 1, 1), heapOffset: first))
                x += n
            }
        }
        return ops
    }

    /// `bytes` of this frame's staging memory (the slot's buffers, grown if needed).
    private func stage(_ bytes: Int) -> (buffer: MTLBuffer, offset: Int)? {
        let slot = stagingCursor.slot
        while stagingCursor.buffer < staging[slot].count {
            let buffer = staging[slot][stagingCursor.buffer]
            if stagingCursor.offset + bytes <= buffer.length {
                defer { stagingCursor.offset = (stagingCursor.offset + bytes + 255) & ~255 }
                return (buffer, stagingCursor.offset)
            }
            stagingCursor.buffer += 1
            stagingCursor.offset = 0
        }
        guard let buffer = device.makeBuffer(length: max(bytes, uploadBytesPerFrame), options: [.storageModeShared, .cpuCacheModeWriteCombined])
        else { return nil }
        buffer.label = "textureStaging\(slot)"
        staging[slot].append(buffer)
        stagingCursor.offset = (bytes + 255) & ~255
        return (buffer, 0)
    }

    /// Maps and uploads levels from the current resident one down to `target` (finer). Returns the bytes uploaded.
    @discardableResult
    private func requestLevels(_ i: Int, upTo target: Int, budget: Int) -> Int {
        let e = entries[i]
        guard target < e.resident else { return 0 }
        let count = e.levels.count
        let tail = min(e.texture.firstMipmapInTail ?? count, count)   // count: no packed tail
        // Levels to map, coarse first: the tail (it covers every level from `tail` down) and then single levels.
        var levels: [Int] = []
        if tail < count && e.resident > tail { levels.append(tail) }
        var l = min(e.resident, tail) - 1
        while l >= target { levels.append(l); l -= 1 }
        // Stop at the budget, but always take the levels down to the always-resident floor; placement: stop where the
        // heap has no tiles left (unmaps still pending).
        var bytes = 0
        var mapped: [Int] = []
        var ops: [SparseMapping] = []
        for level in levels {
            // Given back but not unmapped yet (the unmap waits for the frames in flight): it is still mapped and
            // still holds its pixels, so it comes back as it is and the unmap is dropped.
            if let pending = pendingUnmaps.firstIndex(where: { $0.entry == i && $0.level == level }) {
                pendingUnmaps.remove(at: pending)
                mappedBytes += e.bytesPerLevel[level]
                entries[i].resident = level
                continue
            }
            let size = level == tail ? e.levels[level...].reduce(0) { $0 + $1.size } : e.levels[level].size
            if !mapped.isEmpty && bytes + size > budget && level < e.floor { break }
            if placement {
                guard let placed = placeLevel(i, level) else { break }
                ops += placed
            } else {
                ops.append(SparseMapping(mode: .map, level: level, region: tileRegion(i, level)))
            }
            mapped.append(level)
            bytes += size
            mappedBytes += e.bytesPerLevel[level]
        }
        guard !mapped.isEmpty, let (buffer, start) = stage(bytes) else { return 0 }
        work.add(e.texture, ops)
        var offset = start
        e.data.withUnsafeBytes { raw in
            for level in mapped {
                let last = level == tail ? count - 1 : level
                for sub in level...last {
                    let lv = e.levels[sub]
                    buffer.contents().advanced(by: offset).copyMemory(from: raw.baseAddress!.advanced(by: lv.offset), byteCount: lv.size)
                    work.uploads.append(TextureUpload(source: buffer, offset: offset, bytesPerRow: lv.width * 4, bytesPerImage: lv.size,
                                                      size: MTLSize(width: lv.width, height: lv.height, depth: 1),
                                                      texture: e.texture, level: sub))
                    offset += lv.size
                }
            }
        }
        entries[i].resident = min(entries[i].resident, mapped.min()!)
        stats.uploadedMB += Double(bytes) / 1_048_576
        stats.levelsMapped += mapped.count
        return bytes
    }

    private func dropFinest(_ i: Int, frame: UInt32) {
        let level = entries[i].resident
        guard level < entries[i].floor else { return }
        entries[i].resident = level + 1
        mappedBytes -= entries[i].bytesPerLevel[level]
        pendingUnmaps.append((i, level, frame))
    }

    /// Frees heap space: finest levels first, from the textures needed least recently (and never below what they
    /// want right now unless nothing else is left).
    private func evict(needing bytes: Int, frame: UInt32) {
        var candidates = entries.indices.filter { entries[$0].resident < entries[$0].floor }
        candidates.sort { (entries[$0].lastUsed, -entries[$0].resident) < (entries[$1].lastUsed, -entries[$1].resident) }
        for i in candidates where mappedBytes + bytes > budgetBytes {
            while mappedBytes + bytes > budgetBytes && entries[i].resident < entries[i].floor
                    && (entries[i].resident < entries[i].wanted || entries[i].lastUsed &+ 2 < frame) {
                dropFinest(i, frame: frame)
            }
        }
    }

    private func writeMinLod(slot: Int) {
        let m = minLodBuffers[slot].contents().bindMemory(to: Float.self, capacity: entries.count)
        for (i, e) in entries.enumerated() { m[i] = Float(e.resident) }
    }

    // MARK: Cache files

    /// Mip chains for every source, from its model's cache file (built on first use).
    private static func loadCaches(_ sources: [Scene.TextureSource], device: MTLDevice, queue: MTLCommandQueue,
                                   step: LoadStep?) throws -> [(Data, [Level])] {
        var byModel: [String: [Int]] = [:]
        for (i, s) in sources.enumerated() { byModel[s.modelPath, default: []].append(i) }
        var out = [(Data, [Level])?](repeating: nil, count: sources.count)
        for (model, indices) in byModel {
            let url = cacheURL(for: URL(fileURLWithPath: model))
            let name = URL(fileURLWithPath: model).deletingPathExtension().lastPathComponent
            step?.set(detail: name)
            defer { step?.advance(by: indices.count) }
            if let table = try? read(url), indices.allSatisfy({ table.levels[sources[$0].cacheKey] != nil }) {
                for i in indices { out[i] = (table.data, table.levels[sources[i].cacheKey]!) }
                continue
            }
            print("Textures: building mip chains for \(URL(fileURLWithPath: model).lastPathComponent) (first load)")
            step?.set(detail: "\(name): building mip chains (first load)")
            try write(indices.map { sources[$0] }, to: url, device: device, queue: queue)
            let table = try read(url)
            for i in indices { out[i] = (table.data, table.levels[sources[i].cacheKey]!) }
        }
        return out.map { $0! }
    }

    private static func cacheURL(for model: URL) -> URL {
        let geometry = VirtualGeometryBuilder.cacheURL(for: model)   // same folder and naming
        return geometry.deletingLastPathComponent()
            .appendingPathComponent(geometry.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-v\(VirtualGeometryBuilder.version)", with: "-t1") + ".mgt")
    }

    /// Decodes each image at full size, mipmaps it on the GPU (sRGB-correct for colour maps) and writes all levels.
    private static func write(_ sources: [Scene.TextureSource], to url: URL, device: MTLDevice, queue: MTLCommandQueue) throws {
        var images = [CGImage?](repeating: nil, count: sources.count)
        images.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: sources.count) { i in
                guard sources[i].raw == nil, let src = CGImageSourceCreateWithData(sources[i].data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
                slots[i] = image   // its own slot: no lock
            }
        }
        var header = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { header.append(contentsOf: $0) } }
        var blobs: [(key: String, levels: [(width: Int, height: Int, bytes: Data)])] = []
        for (i, source) in sources.enumerated() {
            guard source.raw != nil || images[i] != nil else { throw RendererError.resourceCreation("decoding texture \(source.name)") }
            let w = source.raw?.width ?? images[i]!.width, h = source.raw?.height ?? images[i]!.height
            guard let pixels = device.makeBuffer(length: w * h * 4, options: .storageModeShared) else {
                throw RendererError.resourceCreation("texture staging")
            }
            if source.raw != nil {   // generated: the pixels as they are
                source.rawPixels.copyBytes(to: pixels.contents().assumingMemoryBound(to: UInt8.self), count: w * h * 4)
            } else if let image = images[i] {
                var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
                if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
                guard let ctx = CGContext(data: pixels.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                    throw RendererError.resourceCreation("texture context")
                }
                ctx.interpolationQuality = .none
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.srgb ? .rgba8Unorm_srgb : .rgba8Unorm,
                                                                width: w, height: h, mipmapped: true)
            desc.usage = .shaderRead
            desc.storageMode = .private
            guard let texture = device.makeTexture(descriptor: desc), let cmd = queue.makeCommandBuffer(),
                  let blit = cmd.makeBlitCommandEncoder() else { throw RendererError.resourceCreation("texture mip chain") }
            blit.copy(from: pixels, sourceOffset: 0, sourceBytesPerRow: w * 4, sourceBytesPerImage: w * h * 4,
                      sourceSize: MTLSize(width: w, height: h, depth: 1), to: texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.generateMipmaps(for: texture)
            var readbacks: [(MTLBuffer, Int, Int)] = []
            for level in 0..<texture.mipmapLevelCount {
                let lw = max(w >> level, 1), lh = max(h >> level, 1)
                guard let rb = device.makeBuffer(length: lw * lh * 4, options: .storageModeShared) else { continue }
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: lw, height: lh, depth: 1), to: rb, destinationOffset: 0,
                          destinationBytesPerRow: lw * 4, destinationBytesPerImage: lw * lh * 4)
                readbacks.append((rb, lw, lh))
            }
            blit.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            blobs.append((source.cacheKey, readbacks.map { ($0.1, $0.2, Data(bytes: $0.0.contents(), count: $0.0.length)) }))
        }
        put(magic); put(UInt32(blobs.count))
        var dataOffset = 0
        var table = Data()
        for b in blobs {
            let key = Data(b.key.utf8)
            withUnsafeBytes(of: UInt32(key.count)) { table.append(contentsOf: $0) }
            table.append(key)
            withUnsafeBytes(of: UInt32(b.levels.count)) { table.append(contentsOf: $0) }
            for lv in b.levels {
                for v in [UInt64(dataOffset), UInt64(lv.bytes.count), UInt64(lv.width), UInt64(lv.height)] {
                    withUnsafeBytes(of: v) { table.append(contentsOf: $0) }
                }
                dataOffset += lv.bytes.count
            }
        }
        let headerSize = (header.count + 8 + table.count + 4095) & ~4095
        put(UInt64(headerSize))
        header.append(table)
        header.append(Data(count: headerSize - header.count))
        let tmp = url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        try handle.write(contentsOf: header)
        for b in blobs { for lv in b.levels { try handle.write(contentsOf: lv.bytes) } }
        try handle.close()
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    private static func read(_ url: URL) throws -> (data: Data, levels: [String: [Level]]) {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var o = 0
        func get<T>(_: T.Type) throws -> T {
            guard o + MemoryLayout<T>.size <= data.count else { throw GLTFError.invalid("truncated texture cache") }
            defer { o += MemoryLayout<T>.size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: T.self) }
        }
        guard try get(UInt32.self) == magic else { throw GLTFError.invalid("not a texture cache") }
        let count = Int(try get(UInt32.self))
        let base = Int(try get(UInt64.self))
        var levels: [String: [Level]] = [:]
        for _ in 0..<count {
            let n = Int(try get(UInt32.self))
            guard o + n <= data.count else { throw GLTFError.invalid("truncated texture cache") }
            let key = String(decoding: data[o..<(o + n)], as: UTF8.self)
            o += n
            let m = Int(try get(UInt32.self))
            var lv: [Level] = []
            for _ in 0..<m {
                let off = Int(try get(UInt64.self)), size = Int(try get(UInt64.self))
                let w = Int(try get(UInt64.self)), h = Int(try get(UInt64.self))
                guard base + off + size <= data.count else { throw GLTFError.invalid("texture cache out of range") }
                lv.append(Level(offset: base + off, size: size, width: w, height: h))
            }
            levels[key] = lv
        }
        return (data, levels)
    }
}

/// One mapping update of a sparse texture: `region` and `heapOffset` in tiles (the offset only for placement-sparse
/// textures: a sparse heap places the tiles itself).
struct SparseMapping {
    var mode: MTLSparseTextureMappingMode
    var level: Int
    var region: MTLRegion
    var heapOffset = 0
}

/// A copy from a staging buffer into one level of a streamed texture.
struct TextureUpload {
    let source: MTLBuffer
    let offset: Int, bytesPerRow: Int, bytesPerImage: Int
    let size: MTLSize
    let texture: MTLTexture
    let level: Int
}

/// A frame's texture streaming: the mapping updates (per texture, in order), then the uploads into what they mapped.
struct TextureStreamWork {
    var mappings: [(texture: MTLTexture, ops: [SparseMapping])] = []
    var uploads: [TextureUpload] = []

    mutating func add(_ texture: MTLTexture, _ ops: SparseMapping...) { add(texture, ops) }
    mutating func add(_ texture: MTLTexture, _ ops: [SparseMapping]) {
        if let last = mappings.last, last.texture === texture { mappings[mappings.count - 1].ops += ops } else { mappings.append((texture, ops)) }
    }

    /// Metal 3 (a sparse heap): a resource-state encoder, then a blit encoder.
    func encode(into cmd: MTLCommandBuffer) {
        if !mappings.isEmpty, let enc = cmd.makeResourceStateCommandEncoder() {
            for (texture, ops) in mappings {
                for op in ops { enc.updateTextureMapping?(texture, mode: op.mode, region: op.region, mipLevel: op.level, slice: 0) }
            }
            enc.endEncoding()
        }
        if !uploads.isEmpty, let blit = cmd.makeBlitCommandEncoder() {
            for u in uploads {
                blit.copy(from: u.source, sourceOffset: u.offset, sourceBytesPerRow: u.bytesPerRow, sourceBytesPerImage: u.bytesPerImage,
                          sourceSize: u.size, to: u.texture, destinationSlice: 0, destinationLevel: u.level,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
            blit.endEncoding()
        }
    }
}

/// The tiles of a placement heap: a bit each, set while mapped; handed out first fit.
struct TileAllocator {
    private var used: [UInt64]
    let count: Int
    private(set) var freeCount: Int

    init(count: Int) {
        self.count = count
        freeCount = count
        used = [UInt64](repeating: 0, count: (count + 63) / 64)
        if count % 64 != 0 { used[used.count - 1] = ~0 << UInt64(count % 64) }   // past the end: never free
    }

    /// `n` tiles, wherever they are free (ascending).
    mutating func allocate(_ n: Int) -> [Int]? {
        guard n <= freeCount else { return nil }
        var tiles: [Int] = []
        tiles.reserveCapacity(n)
        var w = 0
        while tiles.count < n {
            while ~used[w] != 0 && tiles.count < n {
                let bit = (~used[w]).trailingZeroBitCount
                used[w] |= 1 << UInt64(bit)
                tiles.append(w * 64 + bit)
            }
            w += 1
        }
        freeCount -= n
        return tiles
    }

    /// `n` consecutive tiles; returns the first.
    mutating func allocateRun(_ n: Int) -> Int? {
        guard n <= freeCount else { return nil }
        var start = 0, length = 0
        for t in 0..<count {
            if used[t >> 6] & (1 << UInt64(t & 63)) != 0 { start = t + 1; length = 0; continue }
            length += 1
            if length == n {
                for u in start..<(start + n) { used[u >> 6] |= 1 << UInt64(u & 63) }
                freeCount -= n
                return start
            }
        }
        return nil
    }

    mutating func free(_ tiles: [Int]) {
        for t in tiles { used[t >> 6] &= ~(1 << UInt64(t & 63)) }
        freeCount += tiles.count
    }
}
