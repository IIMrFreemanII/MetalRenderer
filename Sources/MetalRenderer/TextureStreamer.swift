import Foundation
import ImageIO
import Metal

/// Streams material textures at full resolution under a memory budget.
///
/// * On first load, every image of a model is decoded at full size, mipmapped on the GPU and written with its whole mip
///   chain to a cache file next to the model (`.metalrenderer-cache/<model>-<size>-<mtime>-t1.mgt`), read back memory-mapped.
/// * Textures are sparse (allocated in a sparse heap the size of the budget): at first only their small mips (up to
///   `residentBaseSize` pixels, and the packed mip tail) are mapped and uploaded.
/// * Every frame the shaders record, per texture, the finest mip level primary and sharp reflection hits sampled
///   (`feedback`, an atomic min); the CPU maps and uploads finer levels in this frame's command buffer, coarsest first,
///   within a per-frame upload budget, and when the heap is full unmaps the finest levels of textures nobody needed
///   lately. Shaders clamp the level to what's resident (`minLod`, per frame slot), so a missing level is only blur.
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
    }

    private let device: MTLDevice
    let heap: MTLHeap
    let budgetBytes: Int
    private var entries: [Entry] = []
    private var mappedBytes = 0
    private var minLodBuffers: [MTLBuffer] = []     // per slot: float per texture
    private var feedbackBuffers: [MTLBuffer] = []   // per slot: 16 counters per texture (samples wanting each level)
    private var pendingUnmaps: [(entry: Int, level: Int, frame: UInt32)] = []
    private let lock = NSLock()
    private var collected: [UInt32] = []            // level histograms (16 per texture) from the last completed frame(s)
    static let levelBins = 16
    private var staging: MTLBuffer?
    var uploadBytesPerFrame = 48 << 20
    private(set) var stats = (residentMB: 0.0, uploadedMB: 0.0, levelsMapped: 0)

    var textures: [MTLTexture] { entries.map(\.texture) }
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

    static func isSupported(_ device: MTLDevice) -> Bool { enabled && device.supportsFamily(.apple6) }

    init(sources: [Scene.TextureSource], device: MTLDevice, queue: MTLCommandQueue, budgetMB: Int, slots: Int) throws {
        self.device = device
        let start = CFAbsoluteTimeGetCurrent()
        let tileBytes = device.sparseTileSizeInBytes
        budgetBytes = max(budgetMB << 20, tileBytes * 1024) / tileBytes * tileBytes
        let hd = MTLHeapDescriptor()
        hd.type = .sparse
        hd.storageMode = .private
        hd.size = budgetBytes
        guard let heap = device.makeHeap(descriptor: hd) else { throw RendererError.resourceCreation("sparse texture heap") }
        heap.label = "textureHeap"
        self.heap = heap

        // Cache files: one per model file, holding all of its images' mip chains.
        let cached = try TextureStreamer.loadCaches(sources, device: device, queue: queue)
        for (i, source) in sources.enumerated() {
            let (data, levels) = cached[i]
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.srgb ? .rgba8Unorm_srgb : .rgba8Unorm,
                                                                width: levels[0].width, height: levels[0].height, mipmapped: true)
            desc.mipmapLevelCount = levels.count
            desc.usage = .shaderRead
            desc.storageMode = .private
            guard let texture = heap.makeTexture(descriptor: desc) else { throw RendererError.resourceCreation("sparse texture \(source.name)") }
            texture.label = source.name
            let tile = device.sparseTileSize(with: .type2D, pixelFormat: desc.pixelFormat, sampleCount: 1)
            let tail = texture.firstMipmapInTail ?? levels.count
            var cost: [Int] = []
            for (l, lv) in levels.enumerated() {
                if l > tail { cost.append(0); continue }
                if l == tail { cost.append(texture.tailSizeInBytes ?? 0); continue }
                let tx = (lv.width + tile.width - 1) / tile.width, ty = (lv.height + tile.height - 1) / tile.height
                cost.append(tx * ty * tileBytes)
            }
            let floor = min(tail, levels.firstIndex { max($0.width, $0.height) <= TextureStreamer.residentBaseSize } ?? tail)
            entries.append(Entry(texture: texture, data: data, levels: levels, resident: levels.count, floor: floor,
                                 wanted: floor, bytesPerLevel: cost))
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

        // The always-resident levels, right away.
        guard let cmd = queue.makeCommandBuffer() else { throw RendererError.resourceCreation("texture upload") }
        for i in entries.indices { requestLevels(i, upTo: entries[i].floor, cmd: cmd, budget: .max) }
        cmd.commit()
        cmd.waitUntilCompleted()
        for slot in 0..<slots { writeMinLod(slot: slot) }
        print(String(format: "Textures: %d streamed (sparse, budget %d MB, %.1f MB resident), ready in %.1f s", entries.count,
                     budgetBytes >> 20, Double(mappedBytes) / 1_048_576, CFAbsoluteTimeGetCurrent() - start))
    }

    /// Main thread, before encoding `frame` into `cmd` (ahead of the frame's own work): apply the latest feedback,
    /// map and upload finer levels, schedule unmaps, publish this slot's resident levels, reset its feedback.
    func update(frame: UInt32, slot: Int, framesInFlight: Int, cmd: MTLCommandBuffer) {
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
        // Unmaps whose frames are done.
        if !pendingUnmaps.isEmpty, let enc = cmd.makeResourceStateCommandEncoder() {
            pendingUnmaps.removeAll { u in
                guard u.frame &+ UInt32(framesInFlight) < frame else { return false }
                enc.updateTextureMapping?(entries[u.entry].texture, mode: .unmap, region: tileRegion(u.entry, u.level),
                                         mipLevel: u.level, slice: 0)
                return true
            }
            enc.endEncoding()
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
            budget -= requestLevels(i, upTo: next, cmd: cmd, budget: budget)
        }
        // Textures holding finer levels than they want give the finest back, one per frame (hysteresis: only after
        // they haven't asked for it for a second).
        for i in entries.indices where entries[i].resident < entries[i].wanted && entries[i].lastUsed &+ 60 < frame {
            dropFinest(i, frame: frame)
        }
        writeMinLod(slot: slot)
        memset(feedbackBuffers[slot].contents(), 0, feedbackBuffers[slot].length)
        stats.residentMB = Double(mappedBytes) / 1_048_576
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

    private func tileRegion(_ i: Int, _ level: Int) -> MTLRegion {
        let t = entries[i].texture
        if level >= (t.firstMipmapInTail ?? Int.max) { return MTLRegionMake3D(0, 0, 0, 1, 1, 1) }
        let tile = device.sparseTileSize(with: .type2D, pixelFormat: t.pixelFormat, sampleCount: 1)
        let lv = entries[i].levels[level]
        return MTLRegionMake3D(0, 0, 0, (lv.width + tile.width - 1) / tile.width, (lv.height + tile.height - 1) / tile.height, 1)
    }

    /// Maps and uploads levels from the current resident one down to `target` (finer). Returns the bytes uploaded.
    @discardableResult
    private func requestLevels(_ i: Int, upTo target: Int, cmd: MTLCommandBuffer, budget: Int) -> Int {
        var e = entries[i]
        guard target < e.resident else { return 0 }
        let count = e.levels.count
        let tail = min(e.texture.firstMipmapInTail ?? count, count)   // count: no packed tail
        // Levels to map, coarse first: the tail (it covers every level from `tail` down) and then single levels.
        var levels: [Int] = []
        if tail < count && e.resident > tail { levels.append(tail) }
        var l = min(e.resident, tail) - 1
        while l >= target { levels.append(l); l -= 1 }
        // Stop at the budget, but always take the levels down to the always-resident floor.
        var bytes = 0
        var mapped: [Int] = []
        for level in levels {
            let size = level == tail ? e.levels[level...].reduce(0) { $0 + $1.size } : e.levels[level].size
            if !mapped.isEmpty && bytes + size > budget && level < e.floor { break }
            mapped.append(level)
            bytes += size
        }
        guard !mapped.isEmpty else { return 0 }
        if let enc = cmd.makeResourceStateCommandEncoder() {
            for level in mapped {
                enc.updateTextureMapping?(e.texture, mode: .map, region: tileRegion(i, level), mipLevel: level, slice: 0)
                mappedBytes += e.bytesPerLevel[level]
            }
            enc.endEncoding()
        }
        // Upload through a staging buffer (grown as needed; the caller waits on nothing: each frame's command buffer
        // gets a fresh one when the previous is still in use).
        guard let staging = device.makeBuffer(length: max(bytes, 16), options: .storageModeShared),
              let blit = cmd.makeBlitCommandEncoder() else { return bytes }
        var offset = 0
        e.data.withUnsafeBytes { raw in
            for level in mapped {
                let last = level == tail ? count - 1 : level
                for sub in level...last {
                    let lv = e.levels[sub]
                    staging.contents().advanced(by: offset).copyMemory(from: raw.baseAddress!.advanced(by: lv.offset), byteCount: lv.size)
                    blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: lv.width * 4, sourceBytesPerImage: lv.size,
                              sourceSize: MTLSize(width: lv.width, height: lv.height, depth: 1), to: e.texture,
                              destinationSlice: 0, destinationLevel: sub, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    offset += lv.size
                }
            }
        }
        blit.endEncoding()
        e.resident = mapped.min()!
        entries[i] = e
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
    private static func loadCaches(_ sources: [Scene.TextureSource], device: MTLDevice, queue: MTLCommandQueue) throws
        -> [(Data, [Level])] {
        var byModel: [String: [Int]] = [:]
        for (i, s) in sources.enumerated() { byModel[s.modelPath, default: []].append(i) }
        var out = [(Data, [Level])?](repeating: nil, count: sources.count)
        for (model, indices) in byModel {
            let url = cacheURL(for: URL(fileURLWithPath: model))
            if let table = try? read(url), indices.allSatisfy({ table.levels[sources[$0].cacheKey] != nil }) {
                for i in indices { out[i] = (table.data, table.levels[sources[i].cacheKey]!) }
                continue
            }
            print("Textures: building mip chains for \(URL(fileURLWithPath: model).lastPathComponent) (first load)")
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
                guard let src = CGImageSourceCreateWithData(sources[i].data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
                slots[i] = image   // its own slot: no lock
            }
        }
        var header = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { header.append(contentsOf: $0) } }
        var blobs: [(key: String, levels: [(width: Int, height: Int, bytes: Data)])] = []
        for (i, source) in sources.enumerated() {
            guard let image = images[i] else { throw RendererError.resourceCreation("decoding texture \(source.name)") }
            let w = image.width, h = image.height
            guard let pixels = device.makeBuffer(length: w * h * 4, options: .storageModeShared) else {
                throw RendererError.resourceCreation("texture staging")
            }
            var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
            guard let ctx = CGContext(data: pixels.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw RendererError.resourceCreation("texture context")
            }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
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
