import Foundation
import simd

/// Training data for the neural denoiser (Benchmark+Dataset.swift): a room made at random from `SceneSettings.seed`,
/// so many rooms give the net materials, shapes, lights and models the handmade scenes don't have. Everything comes
/// from the seed (the dataset renders a clip twice, its noisy frames and its references, and both must be the same room).
/// `bulbs` (SceneKind.bulbRoom): another room for the same seed, strung with dozens to hundreds of small bulbs, the
/// light the night market has and the other rooms don't.
extension Scene {
    func buildRandomRoom(seed: Int, bulbs: Bool = false) {
        var rng = SplitMix64(seed: (bulbs ? 0xB01B_0000 : 0x7EA1_0000) &+ UInt64(truncatingIfNeeded: seed))
        let kit = Kit(self)
        let w = rng.range(6, 20), d = rng.range(6, 18), h = rng.range(3, 7)
        let openRoof = rng.next() < 0.33

        /// A colour from hue, saturation and value.
        func color(saturation: ClosedRange<Float> = 0...0.9, value: ClosedRange<Float> = 0.05...0.9) -> SIMD3<Float> {
            let hue = rng.next() * 6, s = rng.range(saturation.lowerBound, saturation.upperBound)
            let v = rng.range(value.lowerBound, value.upperBound)
            let rgb = SIMD3<Float>(abs(hue - 3) - 1, 2 - abs(hue - 2), 2 - abs(hue - 4))
            return v * simd_mix(SIMD3(repeating: 1), simd_clamp(rgb, .zero, SIMD3(repeating: 1)), SIMD3(repeating: s))
        }
        /// A surface: diffuse, glossy dielectric, metal or, rarely, glowing.
        func material(emissive: Bool = true) -> Int {
            switch rng.int(10) {
            case 0..<4: return addMaterial(albedo: color())
            case 4..<6: return addPBRMaterial(baseColor: color(), metallic: 0, roughness: rng.range(0.03, 0.5))
            case 6..<8: return addPBRMaterial(baseColor: color(saturation: 0...0.5, value: 0.5...1), metallic: 1,
                                              roughness: rng.range(0.03, 0.7))
            case 8 where emissive: return addMaterial(albedo: .zero, emission: color(saturation: 0.3...1, value: 1...1) * rng.range(2, 8))
            default: return addMaterial(albedo: color(value: rng.next() < 0.5 ? 0.02...0.15 : 0.7...0.95))   // very dark or bright
            }
        }

        // The room: floor (often glossy), walls, a ceiling unless it's open to the sky.
        // (Light, mostly muted walls: dark or loud ones are the objects' to have, or a whole room goes black or green.)
        let floor = rng.next() < 0.6 ? addPBRMaterial(baseColor: color(saturation: 0...0.6, value: 0.2...0.7),
                                                      metallic: rng.next() < 0.15 ? 1 : 0, roughness: rng.range(0.05, 0.9))
                                     : addMaterial(albedo: color(saturation: 0...0.6, value: 0.2...0.8))
        let walls = rng.next() < 0.8 ? addMaterial(albedo: color(saturation: 0...0.5, value: 0.35...0.9))
                                     : addPBRMaterial(baseColor: color(saturation: 0...0.5, value: 0.3...0.8), metallic: 0,
                                                      roughness: rng.range(0.1, 0.6))
        kit.room(width: w, height: h, depth: d, floor: floor, walls: walls, ceiling: !openRoof)
        addInstance(kit.quad, walls, translate([0, h / 2, d / 2]) * rotate(-.pi / 2, [1, 0, 0]) * scale([w, 1, h]))   // front wall

        // The camera: inside, at least 2.5 m from the walls (the dataset's camera tracks drift up to about 2 m),
        // looking toward the middle of the room.
        let eye = SIMD3<Float>(rng.range(-0.5, 0.5) * max(w - 5, 0), rng.range(1.2, 2.2), d / 2 - rng.range(2.5, max(2.5, min(4, d / 2))))
        let look = SIMD3<Float>(rng.range(-0.25, 0.25) * w, 0.8, rng.range(-0.4, 0) * d)
        var camera = Camera()
        camera.position = eye
        camera.yaw = atan2(look.x - eye.x, eye.z - look.z)
        camera.pitch = rng.range(-0.25, -0.03)
        defaultCamera = camera

        /// A spot on the floor, clear of the walls and of the camera.
        func spot(margin: Float) -> SIMD2<Float> {
            for _ in 0..<20 {
                let p = SIMD2<Float>(rng.range(-w / 2 + margin, w / 2 - margin), rng.range(-d / 2 + margin, d / 2 - margin))
                if length(p - SIMD2(eye.x, eye.z)) > 2.2 + margin { return p }
            }
            return SIMD2(0, -d / 4)
        }

        // Boxes, balls and thin slabs, some stacked, about a third of them moving.
        var tops: [SIMD3<Float>] = []   // where something can stand on a box
        for _ in 0..<(8 + rng.int(23)) {
            let m = material()
            let size = rng.range(0.2, 1.6)
            var base: SIMD3<Float>
            if !tops.isEmpty, rng.next() < 0.2 { base = tops[rng.int(tops.count)] } else {
                let p = spot(margin: size)
                base = [p.x, 0, p.y]
            }
            let yaw = rng.range(0, .pi)
            let shape = rng.int(3)
            let extent: SIMD3<Float> = shape == 0 ? [size * rng.range(0.4, 1.5), size * rng.range(0.4, 2), size * rng.range(0.4, 1.5)]
                : shape == 1 ? SIMD3(repeating: size) : [size * rng.range(1, 3), rng.range(0.02, 0.08), size * rng.range(0.3, 1)]
            let center = base + [0, extent.y / 2, 0]
            let mesh = shape == 1 ? kit.sphere : kit.cube
            let still = translate(center) * rotate(yaw, [0, 1, 0]) * scale(shape == 1 ? SIMD3(repeating: size / 2) : extent)
            if rng.next() < 0.3 {
                let kind = rng.int(3), speed = rng.range(0.3, 1.5) * (rng.next() < 0.5 ? -1 : 1), r = rng.range(0.3, 1.2)
                let shapeScale = shape == 1 ? SIMD3(repeating: size / 2) : extent
                addInstance(mesh, m, still) { t in
                    switch kind {
                    case 0: return translate(center + [r * sin(speed * t), 0, r * cos(speed * t)]) * rotate(yaw, [0, 1, 0]) * scale(shapeScale)
                    case 1: return translate(center + [0, 0.3 * r * (1 + sin(speed * 2 * t)), 0]) * rotate(yaw, [0, 1, 0]) * scale(shapeScale)
                    default: return translate(center) * rotate(yaw + speed * t, [0, 1, 0]) * scale(shapeScale)
                    }
                }
            } else {
                addInstance(mesh, m, still)
                if shape == 0 && extent.y < 1.2 { tops.append(base + [0, extent.y, 0]) }
            }
        }
        // Sometimes standing glass panes.
        if rng.next() < 0.3 {
            for _ in 0..<(1 + rng.int(3)) {
                let p = spot(margin: 1), size = SIMD3<Float>(rng.range(0.8, 2.5), rng.range(1, 2.5), 0.02)
                kit.box([p.x, size.y / 2, p.y], size, addGlassMaterial(tint: color(saturation: 0...0.3, value: 0.7...1)),
                        yaw: rng.range(0, .pi))
            }
        }

        // Up to three of the gallery's models (Assets/), standing on the floor, some turning.
        let files = Scene.galleryFiles()
        if !files.isEmpty {
            for _ in 0..<rng.int(4) {
                let url = files[rng.int(files.count)]
                let p = spot(margin: 1.2), size = rng.range(0.6, 2), yaw = rng.range(0, 2 * .pi)
                let turn = rng.next() < 0.3 ? rng.range(-0.4, 0.4) : 0
                guard let model = try? GLTFLoader.load(url) else { print("Random room: skipping \(url.lastPathComponent)"); continue }
                let base = translate([p.x, 0, p.y]), place = Scene.placement(model, size: size)
                if turn != 0 {
                    addModel(model, url: url, transform: base * rotate(yaw, [0, 1, 0]) * place) { t in base * rotate(yaw + turn * t, [0, 1, 0]) * place }
                } else {
                    addModel(model, url: url, transform: base * rotate(yaw, [0, 1, 0]) * place)
                }
            }
        }

        // Lights: 1 to 8 spheres, spots, panels and tubes, warm, cool or neon, some moving; the sun when open.
        let brightness = (h / 3) * (h / 3)
        for _ in 0..<(1 + rng.int(8)) {
            let tint = rng.next() < 0.7 ? Scene.hue(simd_mix(SIMD3<Float>(1, 0.6, 0.3), SIMD3<Float>(0.7, 0.85, 1), SIMD3(repeating: rng.next())))
                                        : Scene.hue(color(saturation: 0.6...1, value: 1...1) + 0.01)
            let p = SIMD3<Float>(rng.range(-w / 2 + 0.5, w / 2 - 0.5), rng.range(0.6, h - 0.3), rng.range(-d / 2 + 0.5, d / 2 - 0.5))
            let target = SIMD3<Float>(rng.range(-w / 4, w / 4), 0, rng.range(-d / 4, d / 4))
            let moving = rng.next() < 0.4
            let a = SIMD3<Float>(rng.range(0.5, 2), rng.range(0, 0.4), rng.range(0.5, 2)), f = rng.range(0.2, 0.8), phase = rng.range(0, 6.28)
            func at(_ t: Float) -> SIMD3<Float> {
                guard moving else { return p }
                let q = p + a * SIMD3(sin(f * t + phase), sin(1.3 * f * t), cos(f * t + phase))
                return simd_clamp(q, [-w / 2 + 0.3, 0.3, -d / 2 + 0.3], [w / 2 - 0.3, h - 0.2, d / 2 - 0.3])
            }
            let motion: LightMotion = moving ? .animated : .constant
            switch rng.int(4) {
            case 0:
                addLight(.sphere(radius: rng.range(0.04, 0.2)), color: tint * rng.range(3, 15) * brightness, proxyMesh: kit.sphere,
                         motion: motion) { LightPose(position: at($0)) }
            case 1:
                let inner = rng.range(0.15, 0.5), outer = inner + rng.range(0.05, 0.3)
                addLight(.spot(radius: rng.range(0.04, 0.1), inner: inner, outer: outer), color: tint * rng.range(20, 80) * brightness,
                         motion: motion) { t in LightPose(position: at(t), direction: normalize(target - at(t))) }
            case 2:   // a panel on the ceiling, facing down (or high on a wall when open to the sky)
                let size = SIMD2<Float>(rng.range(0.4, 2.5), rng.range(0.3, 1.5)), radiance = tint * rng.range(2, 9)
                if openRoof {
                    addLight(.rect(width: size.x, height: size.y), color: radiance, motion: .constant) { _ in
                        LightPose(position: [p.x, h - 0.3, -d / 2 + 0.03], direction: [0, 0, 1], tangent: [1, 0, 0])
                    }
                } else {
                    addLight(.rect(width: size.x, height: size.y), color: radiance, motion: .constant) { _ in
                        LightPose(position: [p.x, h - 0.03, p.z], direction: [0, -1, 0], tangent: [1, 0, 0])
                    }
                }
            default:
                let axis = normalize(SIMD3<Float>(rng.range(-1, 1), rng.range(-1, 1), rng.range(-1, 1)))
                addLight(.tube(length: rng.range(0.5, 3), radius: 0.03), color: tint * rng.range(2, 10) * brightness, motion: motion) { t in
                    LightPose(position: at(t), direction: axis)
                }
            }
        }
        if bulbs { addBulbs(width: w, depth: d, height: h, brightness: brightness, kit: kit, rng: &rng) }
        if openRoof {
            let e = rng.range(0.25, 1.2), az = rng.range(0, 2 * .pi)
            let sun = Scene.hue(simd_mix(SIMD3<Float>(1, 0.55, 0.3), SIMD3<Float>(1, 0.95, 0.88), SIMD3(repeating: rng.next())))
            addLight(.sun(angularRadius: 0.0047), color: sun * rng.range(1.5, 5), motion: .constant) { _ in
                LightPose(position: .zero, direction: [cos(e) * sin(az), sin(e), cos(e) * cos(az)])
            }
            skyColor = simd_mix(SIMD3<Float>(0.3, 0.45, 0.8), SIMD3<Float>(0.8, 0.6, 0.5), SIMD3(repeating: rng.next() * 0.5)) * rng.range(0.2, 0.9)
        } else {
            skyColor = SIMD3(repeating: 0.01)
        }
    }
}

extension Scene {
    /// A bulb room's bulbs: 2 to 8 festoon strings sagging across the room and, sometimes, a marquee (a frame of bulbs
    /// on a wall), 8 to 60 bulbs a string, as small as the market's (Scene+Lights.swift, buildMarket), warm white or
    /// coloured, some strings chasing. Their total light doesn't depend on the count.
    fileprivate func addBulbs(width w: Float, depth d: Float, height h: Float, brightness: Float, kit: Kit,
                              rng: inout SplitMix64) {
        let palette: [SIMD3<Float>] = [[1.0, 0.15, 0.1], [0.15, 1.0, 0.25], [0.2, 0.35, 1.0], [1.0, 0.6, 0.1], [0.9, 0.2, 1.0]]
        let strings = 2 + rng.int(7), perString = 8 + rng.int(53)
        let marquee = rng.next() < 0.4 ? 24 + rng.int(57) : 0
        let power = rng.range(4, 16) * brightness / Float(strings * perString + marquee)
        let radius: Float = rng.next() < 0.5 ? 0.025 : 0.04
        let coloured = rng.next()   // how many bulbs are coloured rather than warm white
        func bulbColor() -> SIMD3<Float> {
            (rng.next() < coloured ? Scene.hue(palette[rng.int(palette.count)]) : Scene.hue([1.0, 0.72, 0.42])) * power
        }
        func bulb(_ p: SIMD3<Float>, chase: Bool, phase: Float) {
            addLight(.sphere(radius: radius), color: bulbColor(), proxyMesh: kit.sphere, motion: chase ? .scaleOnly : .constant) { t in
                LightPose(position: p, scale: SIMD3(repeating: chase ? 0.55 + 0.45 * max(0, sin(3 * t - phase)) : 1))
            }
        }
        for i in 0..<strings {
            // Across the room's width or its depth, from wall to wall, a little under the ceiling.
            let across = rng.next() < 0.5, span = across ? w : d, other = across ? d : w
            let at = rng.range(-other / 2 + 0.6, other / 2 - 0.6), y0 = h - rng.range(0.2, min(1.2, h * 0.3))
            let sag = rng.range(0.2, min(1.0, h * 0.2)), skew = rng.range(-1, 1), chase = i % 3 == 1
            for j in 0..<perString {
                let s = (Float(j) + 0.5) / Float(perString)
                let u = -span / 2 + 0.2 + (span - 0.4) * s, v = at + skew * (s - 0.5), y = y0 - 4 * sag * s * (1 - s)
                bulb(across ? [u, y, v] : [v, y, u], chase: chase, phase: Float(j) * 0.35)
            }
        }
        if marquee > 0 {   // on the back wall: a rectangle of bulbs around a sign's place
            let mw = rng.range(1.2, min(4, w - 1)), mh = rng.range(0.6, min(2, h - 1)), cx = rng.range(-w / 2 + mw / 2 + 0.3, w / 2 - mw / 2 - 0.3)
            let cy = rng.range(mh / 2 + 0.8, max(mh / 2 + 0.9, h - mh / 2 - 0.3)), chase = rng.next() < 0.5
            for k in 0..<marquee {
                var s = Float(k) / Float(marquee) * 2 * (mw + mh)   // along the frame
                var p = SIMD2<Float>(-mw / 2, -mh / 2)
                for (dir, len) in [(SIMD2<Float>(1, 0), mw), (SIMD2<Float>(0, 1), mh), (SIMD2<Float>(-1, 0), mw), (SIMD2<Float>(0, -1), mh)] {
                    let step = min(s, len)
                    p += dir * step
                    s -= step
                }
                bulb([cx + p.x, cy + p.y, -d / 2 + 0.08], chase: chase, phase: Float(k) * 0.5)
            }
        }
    }
}
