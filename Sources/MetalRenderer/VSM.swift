import Metal
import simd

/// Virtual Shadow Maps' state on the GPU (ShadowMethod.virtualMaps, Shaders/VSM.metal): the views of the mapped lights
/// (a sun's clipmap levels, a spot's mips, a sphere's cube faces and their mips), one page table over all of them,
/// the pool of physical pages and the lists that draw them. Made for a scene's lights and the VSM settings; the
/// views are written every frame (`writeViews`), from the lights as the frame has them and the camera.
final class VSMTargets {
    /// A view's kind (MSL VSM_SUN...).
    enum Kind: UInt32 { case sun = 0, spot, sphere }

    static let page = 128                   // texels a page side (VSM_PAGE)
    static let sunPages = 128               // pages a side of a sun's level, a spot's mip 0...
    static let spotPages = 128
    static let spherePages = 32             // ...and of a sphere's face at mip 0
    static let sunLevel0: Float = 16        // metres a side of the sun's level 0 (doubling with each level)
    static let maxSpotAngle: Float = 1.4    // radians of half cone a spot can have to be mapped (wider: rays)
    static let recordSize = 112             // VSMInstance
    static let countersSize = 80            // VSMCounters
    static let viewSize = 128               // GPUVSMView
    static let sceneSize = 96               // VSMScene
    static let maxDraws = 1 << 20           // (chunk, page) draws a frame
    static let maxGroups = 1 << 16

    /// A mapped light: its index among the lights, kind, first view and views (levels, or mips x faces).
    struct Light: Equatable {
        let index: Int
        let kind: Kind
        let firstView: Int
        let levels: Int
        var views: Int { kind == .sphere ? 6 * levels : levels }
    }

    let lights: [Light]
    let viewCount: Int
    let entries: Int
    let poolPages: Int
    let pool: MTLTexture                    // depth32Float, VSMTargets.page x page, a slice a physical page
    let table, tags, requests, slots, entryView: MTLBuffer
    let pages: MTLBuffer                    // per physical page: its entry, the frame it was last asked for
    let freeList, renderList, counters: MTLBuffer
    let rects, active, activeViews: MTLBuffer
    let groups, records, draws: MTLBuffer
    let lightTable: MTLBuffer               // GPUVSMLight per light index (the analytic lights')
    let views: [MTLBuffer]                  // per frame slot: GPUVSMView per view
    let sceneArgs: [MTLBuffer]              // per frame slot: MSL VSMScene
    /// The free list holds every page: set once its first frame has run (`VSMTargets.encodeInit`).
    var initialized = false
    /// Last frame's view rows, per view: a light that moved has its pages drawn again.
    private var previous: [GPUVSMView] = []
    let settings: VSMSettings

    /// The lights `lights` (analytic, as the GPU has them) that get maps: suns (the first two), then spots and sphere
    /// lights, up to `settings.maxLights`.
    static func mapped(_ lights: [GPULight], settings: VSMSettings) -> [Light] {
        var out: [Light] = [], view = 0, suns = 0, local = 0
        for (i, l) in lights.enumerated() {
            let type = Float(UInt32(l.color.w) >> 2)
            let kind: Kind
            let levels: Int
            if type == GPULight.sun {
                guard suns < 2 else { continue }
                suns += 1
                kind = .sun
                levels = settings.levels
            } else if type == GPULight.spot && acos(min(max(l.params.x, -1), 1)) <= maxSpotAngle {
                guard local < settings.maxLights else { continue }
                local += 1
                kind = .spot
                levels = Int(log2(Double(spotPages))) + 1
            } else if type == GPULight.sphere {
                guard local < settings.maxLights else { continue }
                local += 1
                kind = .sphere
                levels = Int(log2(Double(spherePages))) + 1
            } else {
                continue
            }
            let light = Light(index: i, kind: kind, firstView: view, levels: levels)
            out.append(light)
            view += light.views
        }
        return out
    }

    /// Pages a side of view `v` (0 ..< light.views) of `light`.
    static func pagesASide(_ light: Light, view v: Int) -> Int {
        switch light.kind {
        case .sun: return sunPages
        case .spot: return spotPages >> v
        case .sphere: return spherePages >> (v % light.levels)
        }
    }

    init?(device: MTLDevice, lights all: [GPULight], settings: VSMSettings, frameSlots: Int) {
        self.settings = settings
        lights = VSMTargets.mapped(all, settings: settings)
        guard !lights.isEmpty else { return nil }
        viewCount = lights.reduce(0) { $0 + $1.views }
        var entryOf: [UInt16] = []
        for light in lights {
            for v in 0..<light.views {
                let n = VSMTargets.pagesASide(light, view: v)
                entryOf += [UInt16](repeating: UInt16(light.firstView + v), count: n * n)
            }
        }
        entries = entryOf.count
        poolPages = settings.pool
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: VSMTargets.page, height: VSMTargets.page,
                                                         mipmapped: false)
        d.textureType = .type2DArray
        d.arrayLength = poolPages
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        guard let pool = device.makeTexture(descriptor: d) else { return nil }
        pool.label = "vsm pool"
        self.pool = pool
        func buffer(_ length: Int, _ label: String, shared: Bool = false) -> MTLBuffer? {
            let b = device.makeBuffer(length: max(length, 16), options: shared ? .storageModeShared : .storageModePrivate)
            b?.label = label
            return b
        }
        let budget = VSMSettings.budgetRange.upperBound
        guard let table = buffer(entries * 4, "vsm table", shared: true), let tags = buffer(entries * 4, "vsm tags"),
              let requests = buffer(entries * 4, "vsm requests", shared: true), let slots = buffer(entries * 4, "vsm slots"),
              let entryView = buffer(entries * 2, "vsm entry views", shared: true),
              let pages = buffer(poolPages * 8, "vsm pages", shared: true), let freeList = buffer(poolPages * 4, "vsm free list", shared: true),
              let renderList = buffer(budget * 16, "vsm render list"), let counters = buffer(VSMTargets.countersSize, "vsm counters", shared: true),
              let rects = buffer(viewCount * 16, "vsm rects"), let active = buffer(viewCount * 4, "vsm active"),
              let activeViews = buffer(viewCount * 4, "vsm active views"),
              let groups = buffer(VSMTargets.maxGroups * 16, "vsm groups"), let records = buffer(VSMTargets.maxGroups * VSMTargets.recordSize, "vsm instances"),
              let draws = buffer(VSMTargets.maxDraws * 16, "vsm draws"),
              let lightTable = buffer(all.count * MemoryLayout<GPUVSMLight>.stride, "vsm lights", shared: true) else { return nil }
        (self.table, self.tags, self.requests, self.slots, self.entryView) = (table, tags, requests, slots, entryView)
        (self.pages, self.freeList, self.renderList, self.counters) = (pages, freeList, renderList, counters)
        (self.rects, self.active, self.activeViews) = (rects, active, activeViews)
        (self.groups, self.records, self.draws, self.lightTable) = (groups, records, draws, lightTable)
        // Nothing resident, nothing asked for; every physical page free.
        memset(table.contents(), 0, table.length)
        memset(requests.contents(), 0, requests.length)
        entryOf.withUnsafeBytes { entryView.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        let page = pages.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: poolPages)
        let free = freeList.contents().bindMemory(to: UInt32.self, capacity: poolPages)
        for p in 0..<poolPages {
            page[p] = SIMD2(UInt32.max, 0)
            free[p] = UInt32(poolPages - 1 - p)
        }
        memset(counters.contents(), 0, counters.length)
        counters.contents().storeBytes(of: UInt32(poolPages), toByteOffset: 64, as: UInt32.self)   // freeCount
        let table0 = lightTable.contents().bindMemory(to: GPUVSMLight.self, capacity: all.count)
        for i in 0..<all.count { table0[i] = GPUVSMLight() }
        for l in lights {
            table0[l.index] = GPUVSMLight(firstView: UInt32(l.firstView + 1), levels: UInt32(l.levels), kind: l.kind.rawValue)
        }
        var made: [MTLBuffer] = [], args: [MTLBuffer] = []
        for s in 0..<frameSlots {
            guard let v = buffer(viewCount * VSMTargets.viewSize, "vsm views \(s)", shared: true),
                  let a = buffer(VSMTargets.sceneSize, "vsm scene \(s)", shared: true) else { return nil }
            made.append(v)
            args.append(a)
        }
        views = made
        sceneArgs = args
    }

    /// Bytes on the GPU (the Debug window's memory line).
    var megabytes: Double {
        let buffers = [table, tags, requests, slots, entryView, pages, freeList, renderList, counters, rects, active, activeViews,
                       groups, records, draws, lightTable] + views + sceneArgs
        let bytes = buffers.reduce(poolPages * VSMTargets.page * VSMTargets.page * 4) { (sum: Int, b: MTLBuffer) in sum + b.length }
        return Double(bytes) / 1_048_576
    }

    /// What the trace's samples reach through SceneShading.vsm.
    var resources: [MTLResource] { [pool, table, tags, requests, lightTable] }

    // MARK: - Views

    /// A frame of the views: from `lights` (the GPU's, as written this frame) and the camera. A view whose light moved
    /// since the last frame is marked stale (its pages are drawn again).
    func writeViews(slot: Int, lights all: [GPULight], camera: SIMD3<Float>) {
        var out: [GPUVSMView] = []
        out.reserveCapacity(viewCount)
        var table: UInt32 = 0
        for light in lights {
            let l = all[light.index]
            for v in 0..<light.views {
                var view = VSMTargets.view(light, v, l, camera: camera)
                let n = VSMTargets.pagesASide(light, view: v)
                view.table = table
                view.pages = UInt32(n)
                view.light = UInt32(light.index)
                view.kind = light.kind.rawValue
                view.level = UInt32(light.kind == .sphere ? v % light.levels : v)
                table += UInt32(n * n)
                out.append(view)
            }
        }
        // A view whose light moved (its rows, but for the sun's window scrolling): drawn pages are stale.
        if previous.count == out.count {
            for i in out.indices where !VSMTargets.sameLight(out[i], previous[i]) { out[i].flags |= GPUVSMView.stale }
        }
        previous = out
        out.withUnsafeBytes { views[slot].contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }

    /// The same light seen the same way (a sun's window may move: its pages are named by where they are).
    static func sameLight(_ a: GPUVSMView, _ b: GPUVSMView) -> Bool {
        if a.kind == Kind.sun.rawValue {
            // (x and y differ in their w only by the window, which is in the origin)
            return a.x == b.x && a.y == b.y && a.z == b.z && a.params == b.params
        }
        return a.x == b.x && a.y == b.y && a.z == b.z && a.w == b.w && a.origin == b.origin
    }

    /// An orthonormal pair across `axis`.
    static func basis(_ axis: SIMD3<Float>) -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        let ref: SIMD3<Float> = abs(axis.y) < 0.99 ? [0, 1, 0] : [1, 0, 0]
        let right = normalize(cross(ref, axis))
        return (right, cross(axis, right))
    }

    /// View `v` of `light` (the GPU light `l`): its rows, origin and params (table, pages and the rest are set by
    /// `writeViews`). The rows map a world point relative to the origin to a clip position over the whole view, whose
    /// NDC x goes right along the page columns, y up against the page rows; z / w is larger nearer the light.
    static func view(_ light: Light, _ v: Int, _ l: GPULight, camera: SIMD3<Float>) -> GPUVSMView {
        var out = GPUVSMView()
        switch light.kind {
        case .sun:
            // Level v: E metres a side, 128 pages of E / 128, around the camera; its pages named by their place in the
            // light's space (`window`: the absolute page of the view's first).
            let d = normalize(SIMD3(l.axis.x, l.axis.y, l.axis.z)), (right, up) = basis(d)
            let e = sunLevel0 * Float(1 << v), ps = e / Float(sunPages)
            let reach = max(2 * l.params.w, sunLevel0 * Float(1 << (light.levels - 1))) + 100   // depth range, each way
            let wx = Int32(floor(dot(camera, right) / ps)) - Int32(sunPages / 2)
            let wy = Int32(floor(-dot(camera, up) / ps)) - Int32(sunPages / 2)
            let centre = SIMD3(l.params.x, l.params.y, l.params.z)
            let origin = right * (Float(wx) * ps) - up * (Float(wy) * ps) + d * dot(centre, d)
            out.x = SIMD4(right * (2 / e), -1)
            out.y = SIMD4(up * (2 / e), 1)
            out.z = SIMD4(d / (2 * reach), 0.5)
            out.w = SIMD4(0, 0, 0, 1)
            out.origin = SIMD4(origin, 0)
            out.params = SIMD4(e / Float(sunPages * page), 2 * reach, 0, 0)
            out.window = SIMD2(wx, wy)
        case .spot, .sphere:
            let centre = SIMD3(l.positionRadius.x, l.positionRadius.y, l.positionRadius.z)
            let axis: SIMD3<Float>, tanHalf: Float, pages0: Int, mip: Int
            if light.kind == .spot {
                axis = normalize(SIMD3(l.axis.x, l.axis.y, l.axis.z))
                tanHalf = tan(min(acos(min(max(l.params.x, -1), 1)) + 0.02, maxSpotAngle))
                pages0 = spotPages
                mip = v
            } else {
                let faces: [SIMD3<Float>] = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
                axis = faces[v / light.levels]
                tanHalf = 1.01
                pages0 = spherePages
                mip = v % light.levels
            }
            let (right, up) = basis(axis)
            let near = max(0.5 * l.positionRadius.w, 0.02)
            out.x = SIMD4(right / tanHalf, 0)
            out.y = SIMD4(up / tanHalf, 0)
            out.z = SIMD4(0, 0, 0, near)
            out.w = SIMD4(axis, 0)
            out.origin = SIMD4(centre, 0)
            out.params = SIMD4(2 * tanHalf / Float(pages0 * page) * Float(1 << mip), 0, near, 0)
        }
        return out
    }

    /// This frame's VSMScene (SceneShading.vsm). `traced`: the scene has geometry the raster doesn't draw.
    func writeScene(slot: Int, lightCount: Int, traced: Bool, settings: VSMSettings, uniforms u: Uniforms) {
        let p = sceneArgs[slot].contents()
        for (k, address) in [views[slot].gpuAddress, lightTable.gpuAddress, table.gpuAddress, tags.gpuAddress, requests.gpuAddress].enumerated() {
            p.storeBytes(of: address, toByteOffset: 8 * k, as: UInt64.self)
        }
        p.storeBytes(of: pool.gpuResourceID, toByteOffset: 40, as: MTLResourceID.self)
        p.storeBytes(of: UInt32(lightCount), toByteOffset: 48, as: UInt32.self)
        p.storeBytes(of: UInt32(settings.steps), toByteOffset: 52, as: UInt32.self)
        p.storeBytes(of: settings.bias, toByteOffset: 56, as: Float.self)
        p.storeBytes(of: traced ? UInt32(1) : 0, toByteOffset: 60, as: UInt32.self)   // VSM_S_TRACED
        p.storeBytes(of: SIMD4(u.camPos.x, u.camPos.y, u.camPos.z, 2 * u.camUp.w / Float(u.height)), toByteOffset: 64, as: SIMD4<Float>.self)
        p.storeBytes(of: u.camForward, toByteOffset: 80, as: SIMD4<Float>.self)
    }
}
