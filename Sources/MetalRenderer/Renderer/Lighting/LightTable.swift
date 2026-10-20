import simd

/// One entry of the light table's alias table (MSL LightTableEntry).
struct GPULightTableEntry {
    var threshold: Float   // keep this column's element if u < threshold, else take `alias`
    var alias: UInt32
    var pdf: Float         // probability of picking `element`
    var element: UInt32    // LightTable.analytic | light index, or LightTable.triangle | emissive triangle index
}

/// Per emissive triangle (MSL TriangleInfo): its light and its mean emitted luminance, for ReSTIR's target function.
struct GPUTriangleInfo {
    var light: UInt32
    var radianceLum: Float
}

/// The lights as one table of *elements* (every analytic light but the suns, and every emissive-mesh triangle) to draw
/// from in O(1), in proportion to nominal power (Vose's alias method). ReSTIR DI draws its candidates from it, so its
/// cost doesn't depend on the light count. Built once per scene: moving or flickering lights change only the target
/// function, not the table. A share `epsilon` of the probability is uniform, so a dim light that happens to be close
/// still gets candidates (no fireflies from tiny pdfs). The suns (at most `maxSuns`) are drawn separately, one candidate
/// each per pixel.
struct LightTable {
    static let analytic: UInt32 = 0, triangle: UInt32 = 1 << 30, indexMask: UInt32 = (1 << 30) - 1
    static let epsilon: Float = 0.1
    static let maxSuns = 2

    var entries: [GPULightTableEntry] = []
    var triangles: [GPUTriangleInfo] = []
    var suns: [UInt32] = []

    /// Bytes after the lights in each frame's light buffer: entries (16 B each), then triangles (8 B each).
    var byteCount: Int {
        entries.count * MemoryLayout<GPULightTableEntry>.stride + triangles.count * MemoryLayout<GPUTriangleInfo>.stride
    }

    init() {}

    init(scene: Scene) {
        let lum = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        var elements: [UInt32] = [], weights: [Float] = []
        for (i, l) in scene.lights.enumerated() {
            let power: Float
            switch l.kind {
            case .sun:
                if suns.count < LightTable.maxSuns { suns.append(UInt32(i)); continue }
                power = .pi * pow(scene.sceneSphere.w, 2) * dot(l.color, lum)   // more suns: what falls on the scene
            case .sphere, .tube: power = 4 * .pi * dot(l.color, lum)
            case .spot(_, _, let outer): power = 2 * .pi * (1 - cos(outer)) * dot(l.color, lum)
            case .rect(let w, let h): power = .pi * dot(l.color, lum) * w * h
            case .mesh: continue   // its triangles instead
            }
            elements.append(LightTable.analytic | UInt32(i))
            weights.append(max(power, 0))
        }
        // Emissive-mesh lights: each triangle by its share of the light's power (the CDF's step) x the instance's area scale.
        triangles = [GPUTriangleInfo](repeating: GPUTriangleInfo(light: 0, radianceLum: 0), count: scene.emissiveTriangles.count)
        for (i, l) in scene.lights.enumerated() {
            guard case .mesh(let m) = l.kind else { continue }
            let mesh = scene.meshLights[m]
            let t = scene.instances[mesh.instance].transform
            let linear = float3x3(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z), SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                                  SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
            let areaScale = pow(abs(linear.determinant), 2.0 / 3.0)
            let total = dot(mesh.power, lum)   // sum of area x emitted luminance (object space)
            var previous: Float = 0
            for k in 0..<mesh.triangleCount {
                let tri = scene.emissiveTriangles[mesh.firstTriangle + k]
                let p = tri.v0.w - previous
                previous = tri.v0.w
                let area = length(cross(SIMD3(tri.e1.x, tri.e1.y, tri.e1.z), SIMD3(tri.e2.x, tri.e2.y, tri.e2.z))) / 2
                let index = mesh.firstTriangle + k
                triangles[index] = GPUTriangleInfo(light: UInt32(i), radianceLum: area > 0 ? p * total / area : 0)
                elements.append(LightTable.triangle | UInt32(index))
                weights.append(2 * .pi * max(p * total, 0) * areaScale)   // two-sided: pi L A per side
            }
        }
        entries = LightTable.aliasTable(elements: elements, weights: weights)
    }

    /// Vose's alias method over the weights mixed with `epsilon` of uniform probability.
    static func aliasTable(elements: [UInt32], weights: [Float]) -> [GPULightTableEntry] {
        let n = elements.count
        guard n > 0 else { return [] }
        let sum = weights.reduce(0, +)
        let pdf = weights.map { sum > 0 ? (1 - epsilon) * $0 / sum + epsilon / Float(n) : 1 / Float(n) }
        var scaled = pdf.map { $0 * Float(n) }
        var entries = (0..<n).map { GPULightTableEntry(threshold: 1, alias: UInt32($0), pdf: pdf[$0], element: elements[$0]) }
        var small: [Int] = [], large: [Int] = []
        for i in 0..<n { if scaled[i] < 1 { small.append(i) } else { large.append(i) } }
        while !small.isEmpty && !large.isEmpty {
            let s = small.removeLast(), l = large[large.count - 1]
            entries[s].threshold = scaled[s]
            entries[s].alias = UInt32(l)
            scaled[l] -= 1 - scaled[s]
            if scaled[l] < 1 { large.removeLast(); small.append(l) }
        }
        // Left over (rounding): keep their own element.
        for i in small + large { entries[i].threshold = 1; entries[i].alias = UInt32(i) }
        return entries
    }
}
