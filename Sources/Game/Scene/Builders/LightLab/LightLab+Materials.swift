import EngineCore
import MetalRenderer
import simd

/// A frame that puts a thing modelled facing +z (its +x across, +y up) at `point`, turned so that its +z is the normal
/// that mirrors `light` into `camera` (the half vector): its highlight, or its reflection, faces the camera.
private func labFacing(_ point: SIMD3<Float>, camera: SIMD3<Float>, light: SIMD3<Float>) -> float4x4 {
    let n = simd_normalize(simd_normalize(camera - point) + simd_normalize(light - point))
    let x = simd_normalize(simd_cross([0, 1, 0], n)), y = simd_cross(n, x)
    return float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(n, 0), SIMD4(point, 1)))
}

/// A flat disc of `radius` in the xy plane facing +z, its UVs planar (U along x), so a brushed material's stretch runs
/// along x.
private func labDiscMesh(radius: Float, segments: Int = 48) -> (mesh: MeshGeometry, uvs: [SIMD2<Float>]) {
    var positions: [SIMD3<Float>] = [[0, 0, 0]], uvs: [SIMD2<Float>] = [[0.5, 0.5]], indices: [UInt32] = []
    for i in 0...segments {
        let a = Float(i) / Float(segments) * 2 * .pi, c = cos(a), s = sin(a)
        positions.append([radius * c, radius * s, 0])
        uvs.append([0.5 + 0.5 * c, 0.5 + 0.5 * s])
    }
    for i in 0..<UInt32(segments) { indices += [0, 1 + i, 2 + i] }
    return ((positions, [SIMD3<Float>](repeating: [0, 0, 1], count: positions.count), indices), uvs)
}

extension Scene {
    /// Booth 14, roughness ramp 0.03 to 1, metal and dielectric, under a rect and a tiny sphere (highlight sampling).
    /// 2 lights.
    func boothRoughness(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let plinth = addMaterial(albedo: SIMD3(repeating: 0.12))
        let gold = Self.labRamp.map { addPBRMaterial(baseColor: [1.0, 0.77, 0.34], metallic: 1, roughness: $0) }
        let grey = Self.labRamp.map { addPBRMaterial(baseColor: SIMD3(repeating: 0.5), metallic: 0, roughness: $0) }
        let r: Float = 0.18
        object("Shelves") {
            labSlab(kit, b, [-1.95, 0, 2.05], [1.95, 0.45, 2.75], plinth)    // the front step: dielectrics
            labSlab(kit, b, [-1.95, 0, 2.75], [1.95, 0.95, 3.6], plinth)     // the back step: metals
        }
        object("Metal row") {
            for i in 0..<6 {
                kit.scaledSphere(b.p(-1.55 + 0.62 * Float(i), 0.95 + r, 3.15), r, gold[i], self)
            }
        }
        object("Dielectric row") {
            for i in 0..<6 {
                kit.scaledSphere(b.p(-1.55 + 0.62 * Float(i), 0.45 + r, 2.4), r, grey[i], self)
            }
        }
        object("Lights") {
            // A rect and a tiny sphere high on the door side, apart, so each sphere shows two highlights.
            let rectAt = b.p(-0.7, 2.8, 1.4), target = b.p(0, 1, 3)
            let rectPose = LightPose(position: rectAt, direction: simd_normalize(target - rectAt), tangent: b.dir([1, 0, 0]))
            addLight(.rect(width: 0.8, height: 0.3), color: SIMD3(1.0, 0.97, 0.92) * 40, motion: .constant) { _ in rectPose }
            let tiny = LightPose(position: b.p(0.8, 2.6, 1.1))
            addLight(.sphere(radius: 0.01), color: SIMD3(repeating: 12), motion: .constant) { _ in tiny }
        }
    }

    /// Booth 15, sheen cloth and brushed metal (anisotropy; readShadingLobes in both modes). 1 light (a tube).
    ///
    /// The brushed plates are discs with planar UVs, so the engine's tangent (along the UVs' U, turned about the normal
    /// by `anisotropyRotation`) runs along the plate's x: the left plate stretches its highlight one way, the right one
    /// (rotated a quarter turn) the other.
    func boothSheenBrushed(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let dark = addMaterial(albedo: SIMD3(repeating: 0.1))
        let cloth = addPBRMaterial(baseColor: [0.35, 0.05, 0.08], metallic: 0, roughness: 0.85, sheen: [0.95, 0.9, 0.9], sheenRoughness: 0.3)
        let acrossBrush = addPBRMaterial(baseColor: SIMD3(repeating: 0.8), metallic: 1, roughness: 0.35, sheen: .zero, anisotropy: 0.8)
        let alongBrush = addPBRMaterial(baseColor: SIMD3(repeating: 0.8), metallic: 1, roughness: 0.35, sheen: .zero, anisotropy: 0.8,
                                        anisotropyRotation: .pi / 2)
        let disc = labDiscMesh(radius: 0.4)
        let discMesh = addMesh(disc.mesh, uvs: disc.uvs, label: "brushed plate")
        let camera = b.p(0, 1.6, 0.35), light = b.p(0.2, 2.7, 1.7)
        object("Cloth") {
            let drum = addMesh(Scene.cylinderMesh(), label: "cloth")
            addInstance(drum, cloth, translate(b.p(-1.2, 0, 3.0)) * scale([0.38, 0.75, 0.38]))
            // a fold: a lower, wider drum in front of it
            addInstance(drum, cloth, translate(b.p(-1.05, 0, 2.3)) * scale([0.3, 0.3, 0.3]))
        }
        object("Brushed plates") {
            for (x, material) in [(0.5 as Float, acrossBrush), (1.4, alongBrush)] {
                let at = b.p(x, 1.25, 3.3)
                addInstance(discMesh, material, labFacing(at, camera: camera, light: light))
                labSlab(kit, b, [x - 0.02, 0, 3.55], [x + 0.02, 1.25, 3.6], dark)   // its stand, behind it
            }
        }
        object("Lights") {
            let pose = LightPose(position: light, direction: b.dir([1, 0, 0]))
            addLight(.tube(length: 1, radius: 0.02), color: SIMD3(1.0, 0.97, 0.92) * 22, motion: .constant) { _ in pose }
        }
    }

    /// Booth 16, hair and skin (the hair lobes). 2 lights (a key spot and a weaker fill).
    ///
    /// Hair: static strands from `addCurves` (the curves the ray tracer draws, as the hair scene and the characters
    /// make them) with `addHairMaterial`, on a 'head' sphere; skin: a material with params.w < 0 (as
    /// `addCharacterMaterials` makes its skin), untextured.
    func boothHairSkin(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let plinth = addMaterial(albedo: SIMD3(repeating: 0.12))
        let head = addPBRMaterial(baseColor: [0.62, 0.48, 0.4], metallic: 0, roughness: 0.6)
        let skin = addMaterial(GPUMaterial(albedo: SIMD4(0.75, 0.5, 0.4, 0), emission: SIMD4(.zero, 0.45), params: SIMD4(1, 1, 0, -1)))
        let hair = addHairMaterial(color: [0.5, 0.3, 0.14])
        let radius: Float = 0.22
        object("Stands") {
            labSlab(kit, b, [-0.8 - 0.3, 0, 2.7], [-0.8 + 0.3, 0.8, 3.3], plinth)
            labSlab(kit, b, [0.8 - 0.3, 0, 2.7], [0.8 + 0.3, 0.8, 3.3], plinth)
        }
        // the ball of each sits on its stand: centre 0.8 + a little under the radius
        let headCentre = b.p(-0.8, 0.8 + radius - 0.02, 3.0), skinCentre = b.p(0.8, 0.8 + radius - 0.02, 3.0)
        object("Head") { kit.scaledSphere(headCentre, radius, head, self) }
        object("Skin sphere") { kit.scaledSphere(skinCentre, radius, skin, self) }
        object("Hair") {
            let strands = 500, segments = 6, length: Float = 0.12
            var points: [SIMD3<Float>] = [], radii: [Float] = [], bounds = AABB()
            points.reserveCapacity(strands * (segments + 3))
            let taper = (0...segments).map { 0.0012 + (0.0004 - 0.0012) * Float($0) / Float(segments) }
            for i in 0..<strands {
                let t = (Float(i) + 0.5) / Float(strands), y = 0.1 + 0.9 * t, ring = (1 - y * y).squareRoot()
                let phi = Float(i) * 2.39996
                let normal = b.dir([ring * cos(phi), 0, ring * sin(phi)]) + SIMD3(0, y, 0)
                var strand = [headCentre + normal * (radius - 0.004)]
                for k in 1...segments {
                    let f = Float(k) / Float(segments), bend = 0.15 + 0.6 * f
                    let d = simd_normalize(normal * (1 - bend) + SIMD3(0, -1, 0) * bend)
                    strand.append(strand[k - 1] + d * (length / Float(segments)))
                }
                strand.insert(strand[0] - (strand[1] - strand[0]), at: 0)
                strand.append(strand[segments + 1] + (strand[segments + 1] - strand[segments]))
                for p in strand { bounds.grow(p) }
                points += strand
                radii += [taper[0]] + taper + [taper[segments]]
            }
            bounds.lo -= SIMD3(repeating: 0.03); bounds.hi += SIMD3(repeating: 0.03)
            let mesh = addCurves(points: points, perStrand: segments + 3, radii: radii, bounds: bounds)
            addDeformingInstance(mesh, hair)
        }
        object("Lights") {
            let keyAt = b.p(-1.3, 2.5, 1.2), target = b.p(0, 1.1, 3.0)
            let key = LightPose(position: keyAt, direction: simd_normalize(target - keyAt))
            addLight(.spot(radius: 0.05, inner: 0.35, outer: 0.5), color: SIMD3(1.0, 0.95, 0.88) * 26, motion: .constant) { _ in key }
            let fill = LightPose(position: b.p(1.6, 1.7, 1.0))
            addLight(.sphere(radius: 0.1), color: SIMD3(0.8, 0.9, 1.0) * 6, motion: .constant) { _ in fill }
        }
    }

    /// Booth 17, albedo extremes and saturated walls (energy, colour bleeding). 1 light.
    func boothAlbedoExtremes(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let red = addMaterial(albedo: [0.8, 0.05, 0.05]), green = addMaterial(albedo: [0.05, 0.65, 0.08])
        let white = addMaterial(albedo: SIMD3(repeating: 0.8))
        let albedos: [Float] = [0.02, 0.04, 0.18, 0.5, 0.9, 0.97]
        object("Albedo row") {
            for (i, a) in albedos.enumerated() {
                let x = -1.25 + 0.5 * Float(i)
                labSlab(kit, b, [x - 0.14, 0, 1.6], [x + 0.14, 0.28, 1.88], addMaterial(albedo: SIMD3(repeating: a)))
            }
        }
        object("Bleed") {
            labSlab(kit, b, [-2, 0.5, 2.2], [-1.99, 2.5, 3.7], red)      // left wall, inner half
            labSlab(kit, b, [1.99, 0.5, 2.2], [2, 2.5, 3.7], green)      // right wall
            labSlab(kit, b, [-0.3, 0, 2.8], [0.3, 0.6, 3.4], white)      // the white cube between them
        }
        object("Lights") {
            let pose = LightPose(position: b.p(0, 2.7, 2.6))
            addLight(.sphere(radius: 0.1), color: SIMD3(1.0, 0.97, 0.92) * 30, motion: .constant) { _ in pose }
        }
    }

    /// Booth 18, mirror and glass: a light seen in a mirror and through glass (reflected lights). 2 lights.
    func boothMirrorGlass(_ b: BoothFrame, _ lab: LightLabSettings) {
        let kit = Kit(self)
        let mirror = addPBRMaterial(baseColor: SIMD3(repeating: 0.95), metallic: 1, roughness: 0.02)
        let glass = addGlassMaterial(tint: [1, 1, 1])
        let dark = addMaterial(albedo: SIMD3(repeating: 0.1)), grey = addMaterial(albedo: SIMD3(repeating: 0.5))
        let camera = b.p(0, 1.6, 0.35)
        // A light behind the camera, high by the door: seen only in the mirror, whose normal bisects it and the camera.
        let doorLight = b.p(0.3, 2.7, 0.2)
        object("Mirror") {
            let at = b.p(1.4, 1.5, 3.1)
            addInstance(kit.cube, mirror, labFacing(at, camera: camera, light: doorLight) * scale([1.2, 1.5, 0.02]))
        }
        object("Glass") {
            let x: Float = -1.2, y: Float = 1.3, z: Float = 3.0, w: Float = 0.35, h: Float = 0.45
            addInstance(kit.cube, glass, translate(b.p(x, y, z)) * rotate(b.yaw(), [0, 1, 0]) * scale([2 * w, 2 * h, 0.01]),
                        mask: Scene.maskGlass)
            for (lo, hi) in [([x - w - 0.02, y - h - 0.02, z - 0.02], [x + w + 0.02, y - h, z + 0.02]),
                             ([x - w - 0.02, y + h, z - 0.02], [x + w + 0.02, y + h + 0.02, z + 0.02]),
                             ([x - w - 0.02, y - h, z - 0.02], [x - w, y + h, z + 0.02]),
                             ([x + w, y - h, z - 0.02], [x + w + 0.02, y + h, z + 0.02])] as [(SIMD3<Float>, SIMD3<Float>)] {
                labSlab(kit, b, lo, hi, dark)
            }
            labSlab(kit, b, [x - 0.03, 0, z - 0.03], [x + 0.03, y - h - 0.02, z + 0.03], dark)
        }
        object("Props") {
            labSlab(kit, b, [-0.1, 0, 2.5], [0.5, 0.4, 3.1], grey)
        }
        object("Lights") {
            let behind = LightPose(position: doorLight)
            addLight(.sphere(radius: 0.08), color: SIMD3(1.0, 0.97, 0.92) * 30, motion: .constant) { _ in behind }
            let seen = LightPose(position: b.p(-1.2, 1.3, 3.6))
            addLight(.sphere(radius: 0.08), color: SIMD3(1.0, 0.9, 0.8) * 12, motion: .constant) { _ in seen }
        }
    }

    /// Booth 14's roughnesses.
    fileprivate static let labRamp: [Float] = [0.03, 0.1, 0.2, 0.35, 0.6, 1.0]
}

private extension Scene.Kit {
    /// A ball of `radius` at world `centre`.
    func scaledSphere(_ centre: SIMD3<Float>, _ radius: Float, _ material: Int, _ scene: Scene) {
        scene.addInstance(sphere, material, translate(centre) * scale(radius))
    }
}
