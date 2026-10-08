import XCTest
import Metal
import simd
@testable import MetalRenderer

/// Particles.swift, ParticlesCPU.swift, ParticlesGPU.swift and Shaders/Particles.metal: what emitters ask for, the
/// pool's invariants (every slot alive or on its emitter's dead list, once), the GPU's step against the CPU's
/// (compared as sets: the GPU's lists are in its atomics' order), a GPU run against another, curl noise's divergence.
final class ParticleTests: XCTestCase {
    // MARK: Systems

    /// A fountain in curl noise and a vortex, drag toward a wind: no colliders, so the CPU and the GPU agree particle
    /// for particle.
    private func swirl(capacity: Int = 3000) -> ParticleSystem {
        var f = ParticleEmitter("fountain", capacity: capacity, at: [0, 0.2, 0])
        f.shape = .disc(radius: 0.1)
        f.rate = 600
        f.lifetime = 0.8...1.6
        f.speed = 2...3
        f.spread = 0.3
        f.drag = 0.8
        f.wind = 1
        f.curl = 3
        f.curlFrequency = 1.5
        f.curlSpeed = 0.4
        var v = ParticleEmitter("vortex", capacity: capacity / 2, at: [1, 1, 0])
        v.shape = .sphere(radius: 0.3)
        v.rate = 200
        v.burst = (0.25, 150, 0.5, 3)
        v.lifetime = 1...2
        v.speed = 0.2...0.5
        v.radial = true
        v.gravity = 0
        v.vortex = 2
        v.attraction = 0.5
        // A draft: the baked curl tile, and a vortex field it is carried by (ParticleField).
        var d = ParticleEmitter("draft", capacity: capacity / 2, at: [-1, 0.3, 0])
        d.shape = .disc(radius: 0.3)
        d.rate = 150
        d.lifetime = 1...2
        d.speed = 0.2...0.6
        d.gravity = 0.2
        d.curl = 2
        d.curlFrequency = 1.3
        d.curlSpeed = 0.5
        d.bakedCurl = true
        d.field = (index: 0, strength: 3, follow: true)
        let column = ParticleField.vortex(center: [-1, 0, 0], radius: 0.6, height: 2.5, swirl: 1.5, lift: 1.2, dims: 12)
        return ParticleSystem(emitters: [f, v, d], fields: [column])
    }

    /// Sparks that bounce off a floor and a box, leave smoke where they die, and rain that splashes on the floor.
    private func sparks(capacity: Int = 2000) -> ParticleSystem {
        var s = ParticleEmitter("sparks", capacity: capacity, at: [0, 1, 0])
        s.rate = 300
        s.lifetime = 0.6...1.2
        s.speed = 3...5
        s.spread = 0.8
        s.colliders = 0b11
        s.restitution = 0.5
        s.friction = 0.3
        s.orientation = .velocity(stretch: 0.02)
        var smoke = ParticleEmitter("smoke", capacity: capacity, at: .zero)
        smoke.parent = 0
        smoke.perEvent = 2
        smoke.inherit = 0.2
        smoke.lifetime = 0.5...1
        smoke.gravity = -0.2
        smoke.shape = .sphere(radius: 0.02)
        var rain = ParticleEmitter("rain", capacity: capacity, at: [0, 3, 0])
        rain.shape = .box(halfExtents: [1, 0, 1])
        rain.rate = 400
        rain.lifetime = 3...3
        rain.colliders = 0b01
        rain.dieOnCollision = true
        var splash = ParticleEmitter("splash", capacity: capacity, at: .zero)
        splash.parent = 2
        splash.trigger = .collision
        splash.perEvent = 3
        splash.speed = 0.5...1
        splash.spread = 1
        splash.lifetime = 0.2...0.4
        return ParticleSystem(emitters: [s, smoke, rain, splash],
                              colliders: [.plane(normal: [0, 1, 0], point: .zero), .box(center: [0.8, 0.2, 0], halfExtents: [0.2, 0.2, 0.2])])
    }

    // MARK: What emitters ask for

    func testTheRateCarriesItsFraction() {
        var e = ParticleEmitter("a", capacity: 10, at: .zero)
        e.rate = 30
        e.start = 0.5
        e.stop = 9.5
        let system = ParticleSystem(emitters: [e])
        let g = system.gpuEmitters[0]
        var total: UInt32 = 0
        for step in 0..<660 {
            let n = ParticleSystem.requests(g, system.stepParams(step))
            XCTAssertLessThanOrEqual(n, 1, "30 a second at 60 steps a second: never two in a step")
            if Float(step + 1) * ParticleSystem.stepLength <= 0.5 { XCTAssertEqual(n, 0, "nothing before it starts") }
            total += n
        }
        XCTAssertEqual(Int(total), 270, "30 a second for 9 s")
    }

    func testBurstsLandOnTheirStep() {
        var e = ParticleEmitter("b", capacity: 10, at: .zero)
        e.burst = (0.5, 20, 0, 0)
        var p = ParticleEmitter("p", capacity: 10, at: .zero)
        p.burst = (1, 7, 0.25, 3)
        let system = ParticleSystem(emitters: [e, p])
        let g = system.gpuEmitters
        var once: [Int: UInt32] = [:], periodic: [Int: UInt32] = [:]
        for step in 0..<300 {
            let s = system.stepParams(step)
            if case let n = ParticleSystem.requests(g[0], s), n > 0 { once[step] = n }
            if case let n = ParticleSystem.requests(g[1], s), n > 0 { periodic[step] = n }
        }
        XCTAssertEqual(once, [30: 20])
        XCTAssertEqual(periodic, [60: 7, 75: 7, 90: 7], "every 0.25 s from 1 s, three times")
    }

    // MARK: The pool (CPU)

    /// Every slot is alive (in the list the next step reads) or on its emitter's dead list, once; alive slots are
    /// their emitters'.
    private func checkPool(system: ParticleSystem, alive: [UInt32], particles: [GPUParticle], dead: (Int) -> [UInt32],
                           _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        var seen = Set<UInt32>()
        for slot in alive {
            XCTAssertTrue(seen.insert(slot).inserted, "\(label): slot \(slot) alive twice", file: file, line: line)
            let p = particles[Int(slot)], e = Int(p.info.z)
            XCTAssertEqual(p.info.w, ParticleSystem.alive, "\(label): an alive slot's particle isn't", file: file, line: line)
            XCTAssertTrue((system.bases[e]..<system.bases[e] + system.emitters[e].capacity).contains(Int(slot)),
                          "\(label): slot \(slot) isn't its emitter's", file: file, line: line)
        }
        for e in system.emitters.indices {
            let d = dead(e)
            let base = system.bases[e], cap = system.emitters[e].capacity
            for slot in d {
                XCTAssertTrue(seen.insert(slot).inserted, "\(label): slot \(slot) dead twice, or dead and alive", file: file, line: line)
                XCTAssertTrue((base..<base + cap).contains(Int(slot)), "\(label): emitter \(e)'s dead list holds \(slot)", file: file, line: line)
            }
        }
        XCTAssertEqual(seen.count, system.capacity, "\(label): every slot alive or dead", file: file, line: line)
    }

    private func checkCPU(_ cpu: ParticlesCPU, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let system = cpu.system
        checkPool(system: system, alive: cpu.alive[cpu.stepIndex & 1], particles: cpu.particles, dead: { e in
            let base = system.bases[e]
            return Array(cpu.deadList[base..<base + cpu.deadCount[e]])
        }, label, file: file, line: line)
    }

    func testThePoolHoldsEverySlotOnce() {
        for system in [swirl(), sparks(capacity: 300)] {
            let cpu = ParticlesCPU(system)
            for k in 0..<240 {
                cpu.step(wind: [1, 0, 0.5, 0])
                checkCPU(cpu, "step \(k)")
            }
            XCTAssertGreaterThan(cpu.current.count, 0)
        }
    }

    func testBirthsBeyondTheBudgetAreDropped() {
        var e = ParticleEmitter("flood", capacity: 50, at: .zero)
        e.rate = 6000
        e.lifetime = 5...5
        let cpu = ParticlesCPU(ParticleSystem(emitters: [e]))
        cpu.advance(steps: 30)
        XCTAssertEqual(cpu.current.count, 50, "the pool full, the rest dropped")
        XCTAssertEqual(cpu.deadCount[0], 0)
        checkCPU(cpu, "flooded")
    }

    func testChildrenSpawnWhereTheirParentsDie() {
        let cpu = ParticlesCPU(sparks())
        var children = 0, splashes = 0
        for _ in 0..<180 {
            cpu.step()
            children = max(children, cpu.current.filter { $0.info.z == 1 }.count)
            splashes = max(splashes, cpu.current.filter { $0.info.z == 3 }.count)
        }
        XCTAssertGreaterThan(children, 50, "dead sparks leave smoke")
        XCTAssertGreaterThan(splashes, 50, "rain splashes on the floor")
        for p in cpu.current where p.info.z == 3 {
            XCTAssertLessThan(p.position.y, 0.6, "a splash starts on the floor")
        }
        for p in cpu.current where p.info.z == 0 || p.info.z == 2 {
            XCTAssertGreaterThanOrEqual(p.position.y, -1e-5, "nothing goes through the floor")
        }
    }

    // MARK: Curl noise

    func testTheNoisesGradientIsItsDerivative() {
        var r = ParticleMath.Rng(state: 7)
        let h: Float = 1e-3
        var worst: Float = 0
        for _ in 0..<500 {
            let x = SIMD3(r.next(), r.next(), r.next()) * 10 - 5
            let n = ParticleMath.noise(x, 0x1B873593)
            for k in 0..<3 {
                var a = x, b = x
                a[k] += h
                b[k] -= h
                let fd = (ParticleMath.noise(a, 0x1B873593).x - ParticleMath.noise(b, 0x1B873593).x) / (2 * h)
                worst = max(worst, abs(fd - n[k + 1]))
            }
        }
        print("noise: analytic gradient within \(worst) of central differences")
        XCTAssertLessThan(worst, 2e-2)
    }

    func testCurlNoiseIsDivergenceFree() {
        var r = ParticleMath.Rng(state: 11)
        let h: Float = 2e-3
        var divergence: Float = 0, size: Float = 0
        for _ in 0..<500 {
            let x = SIMD3(r.next(), r.next(), r.next()) * 6 - 3
            var div: Float = 0
            for k in 0..<3 {
                var a = x, b = x
                a[k] += h
                b[k] -= h
                div += (ParticleMath.curl(a, frequency: 1.3, time: 0.7)[k] - ParticleMath.curl(b, frequency: 1.3, time: 0.7)[k]) / (2 * h)
            }
            divergence = max(divergence, abs(div))
            size += length(ParticleMath.curl(x, frequency: 1.3, time: 0.7))
        }
        size /= 500
        print("curl noise: mean speed \(size), divergence at most \(divergence)")
        XCTAssertGreaterThan(size, 0.3)
        // A field's divergence is of the order of its size x its frequency; the differences' truncation and rounding
        // leave a few hundredths of that.
        XCTAssertLessThan(divergence, 0.03 * size * 1.3)
    }

    // MARK: GPU

    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static var compiled: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)?

    private func metal() throws -> (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines) {
        if let compiled = ParticleTests.compiled { return compiled }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: ParticleTests.shaders, lightTypes: 0x3F, stats: false)
        ParticleTests.compiled = (device, queue, pipelines)
        return (device, queue, pipelines)
    }

    /// `system` on the GPU, reset: `run(steps, wind)` encodes steps (a reset with steps < 0).
    private func gpu(_ system: ParticleSystem) throws -> (gpu: ParticlesGPU, run: (Int, SIMD4<Float>) -> Void) {
        let m = try metal()
        let gpu = try ParticlesGPU(device: m.device, system: system, slots: 1)
        let run = { (steps: Int, wind: SIMD4<Float>) in
            let cmd = m.queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            if steps < 0 { gpu.encodeReset(Metal3Pass(enc: enc), pipelines: m.pipelines, slot: 0) }
            var left = max(steps, 0)
            while left > 0 {
                let n = min(left, ParticlesGPU.maxStepsPerFrame)
                gpu.encodeSteps(Metal3Pass(enc: enc), pipelines: m.pipelines, steps: n, slot: 0, wind: wind)
                left -= n
            }
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            XCTAssertNil(cmd.error)
        }
        run(-1, .zero)
        return (gpu, run)
    }

    private func gpuAlive(_ g: ParticlesGPU) -> [GPUParticle] {
        let all = g.readParticles()
        return g.readAliveSlots().map { all[Int($0)] }
    }

    private struct Key: Hashable { let emitter: UInt32; let spawn: UInt32 }
    private func keyed(_ ps: [GPUParticle]) -> [Key: GPUParticle] {
        Dictionary(ps.map { (Key(emitter: $0.info.z, spawn: $0.info.x), $0) }, uniquingKeysWith: { a, _ in a })
    }

    func testGPUPoolHoldsEverySlotOnce() throws {
        for system in [swirl(), sparks(capacity: 300)] {
            let (g, run) = try gpu(system)
            for k in 0..<12 {
                run(20, [1, 0, 0.5, 0])
                checkPool(system: system, alive: g.readAliveSlots(), particles: g.readParticles(), dead: g.readDead, "GPU, step \(20 * (k + 1))")
            }
        }
    }

    func testGPUMatchesTheCPU() throws {
        let system = swirl()
        let (g, run) = try gpu(system)
        let cpu = ParticlesCPU(system)
        let wind: SIMD4<Float> = [0.6, 0.8, 0.7, 0]
        var worst: [Float] = []
        for steps in [1, 10, 120] {
            run(steps - g.stepIndex, wind)
            cpu.advance(steps: steps - cpu.stepIndex, wind: wind)
            let a = keyed(gpuAlive(g)), b = keyed(cpu.current)
            XCTAssertEqual(a.count, b.count, "as many alive after \(steps) steps")
            XCTAssertEqual(Set(a.keys), Set(b.keys), "the same particles alive after \(steps) steps")
            var w: Float = 0
            for (k, p) in a {
                guard let q = b[k] else { continue }
                XCTAssertEqual(p.info.y, q.info.y, "the same seed")
                XCTAssertEqual(p.position.w, q.position.w, accuracy: 1e-6, "the same age")
                XCTAssertEqual(p.velocity.w, q.velocity.w, accuracy: 1e-5, "the same lifetime")
                w = max(w, length(ParticleMath.xyz(p.position) - ParticleMath.xyz(q.position)))
            }
            worst.append(w)
        }
        print("GPU against CPU: within \(worst) m after 1, 10, 120 steps")
        XCTAssertLessThan(worst[0], 1e-5)
        XCTAssertLessThan(worst[1], 1e-4)
        XCTAssertLessThan(worst[2], 2e-3)
    }

    func testGPUEventsMatchTheCPUsCounts() throws {
        let system = sparks()
        let (g, run) = try gpu(system)
        let cpu = ParticlesCPU(system)
        run(150, .zero)
        cpu.advance(steps: 150)
        let a = gpuAlive(g), b = cpu.current
        for e in 0..<4 {
            let na = a.filter { $0.info.z == e }.count, nb = b.filter { $0.info.z == e }.count
            print("emitter \(system.emitters[e].name): GPU \(na), CPU \(nb) alive after 150 steps")
            XCTAssertEqual(Float(na), Float(nb), accuracy: max(Float(nb) * 0.03, 3), "\(system.emitters[e].name)")
        }
    }

    func testGPURunsAreTheSame() throws {
        let system = sparks()
        let (first, runFirst) = try gpu(system)
        let (second, runSecond) = try gpu(system)
        runFirst(200, [1, 0, 1, 0])
        runSecond(200, [1, 0, 1, 0])
        let a = keyed(gpuAlive(first)), b = keyed(gpuAlive(second))
        XCTAssertEqual(Set(a.keys), Set(b.keys))
        for (k, p) in a {
            guard let q = b[k] else { continue }
            XCTAssertEqual(p.position, q.position, "bit for bit: a particle's step doesn't depend on the others'")
            XCTAssertEqual(p.velocity, q.velocity)
        }
    }

    func testGPUResetStartsOver() throws {
        let system = swirl(capacity: 800)
        let (g, run) = try gpu(system)
        run(90, .zero)
        let first = keyed(gpuAlive(g))
        run(-1, .zero)
        XCTAssertEqual(g.readAliveSlots().count, 0)
        run(90, .zero)
        let again = keyed(gpuAlive(g))
        XCTAssertEqual(Set(first.keys), Set(again.keys))
        for (k, p) in first { XCTAssertEqual(p.position, again[k]?.position) }
    }

    // MARK: What rays meet

    /// Every alive particle's billboard, posed on the GPU in each orientation, lies inside its box: rays from all
    /// around that meet it within its square meet it inside the box (the box is what the traversal hands the loops).
    func testBillboardsStayInTheirBoxes() throws {
        var emitters: [ParticleEmitter] = []
        for (k, o) in [ParticleEmitter.Orientation.rayFacing, .velocity(stretch: 0.05), .axis([0.3, 1, 0.2]), .world(normal: [0.2, 1, -0.4])].enumerated() {
            var e = ParticleEmitter("e\(k)", capacity: 300, at: [Float(k), 1, 0])
            e.rate = 300
            e.lifetime = 2...2
            e.speed = 1...4
            e.spread = 1.2
            e.spin = 3
            e.size = (0.1, 0.3)
            e.sizeJitter = 0.5
            e.orientation = o
            e.atlas = ParticleTextures.Kind.allCases[k]
            emitters.append(e)
        }
        let system = ParticleSystem(emitters: emitters)
        let (g, run) = try gpu(system)
        run(30, .zero)
        let m = try metal()
        let cmd = m.queue.makeCommandBuffer()!
        let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
        g.encodePose(Metal3Pass(enc: enc), pipelines: m.pipelines, slot: 0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let render = g.readRender(slot: 0)
        let boxes = g.boxes[0].contents().bindMemory(to: Float.self, capacity: system.capacity * 6)
        var r = ParticleMath.Rng(state: 3)
        var hits = 0, alive = 0
        for slot in 0..<system.capacity where render[slot].centerRadius.w > 0 {
            alive += 1
            let lo = SIMD3(boxes[6 * slot], boxes[6 * slot + 1], boxes[6 * slot + 2])
            let hi = SIMD3(boxes[6 * slot + 3], boxes[6 * slot + 4], boxes[6 * slot + 5])
            let c = ParticleMath.xyz(render[slot].centerRadius)
            for _ in 0..<40 {
                // A ray from 3 m away in a random direction, aimed at a random point near the particle.
                let z = 2 * r.next() - 1, phi = 2 * Float.pi * r.next(), s = (1 - z * z).squareRoot()
                let from = c + SIMD3(s * cos(phi), s * sin(phi), z) * 3
                let aim = c + (SIMD3(r.next(), r.next(), r.next()) * 2 - 1) * render[slot].centerRadius.w * 1.5
                let d = normalize(aim - from)
                guard let (t, uv, _) = ParticleMath.billboard(render[slot], from, d), abs(uv.x) <= 1, abs(uv.y) <= 1 else { continue }
                // A ray-facing or world quad turns: its box holds the disc its picture is in (the trim), not the corners.
                let orient = (render[slot].info.x >> 27) & 3, kind = ParticleTextures.Kind(rawValue: Int(render[slot].info.z >> 24))!
                if (orient == 0 || orient == 3) && length(uv) > ParticleTextures.trim(kind) { continue }
                let p = from + d * t
                hits += 1
                XCTAssertTrue(all(p .>= lo - 1e-4) && all(p .<= hi + 1e-4), "slot \(slot): its billboard at \(p) outside its box \(lo)...\(hi)")
            }
        }
        print("billboards: \(hits) hits on \(alive) particles, all inside their boxes")
        XCTAssertGreaterThan(alive, 500)
        XCTAssertGreaterThan(hits, 1000)
    }

    func testTheKBufferIsExactUpToItsSizeAndOrderFree() {
        var r = ParticleMath.Rng(state: 5)
        func fragment() -> ParticleMath.Fragment {
            let a = r.next()
            return ParticleMath.Fragment(t: r.next() * 10, alpha: a, rgb: SIMD3(r.next(), r.next(), r.next()) * a)
        }
        for n in 1...4 {
            for _ in 0..<50 {
                let fs = (0..<n).map { _ in fragment() }
                let exact = ParticleMath.composite(fs.sorted { $0.t < $1.t })
                var k: [ParticleMath.Fragment] = []
                for f in fs.shuffled() { ParticleMath.insert(&k, capacity: 4, f) }
                XCTAssertEqual(k.map(\.t), fs.map(\.t).sorted())
                let got = ParticleMath.composite(k)
                XCTAssertLessThan(length(got - exact), 1e-5, "\(n) fragments: the exact front-to-back composite")
            }
        }
        // Past its size: what the far merges lose is bounded by what the nearest four leave visible.
        var worst: Float = 0
        for _ in 0..<200 {
            let fs = (0..<12).map { _ in fragment() }
            let exact = ParticleMath.composite(fs.sorted { $0.t < $1.t })
            var k: [ParticleMath.Fragment] = []
            for f in fs { ParticleMath.insert(&k, capacity: 4, f) }
            let got = ParticleMath.composite(k)
            XCTAssertEqual(got.w, exact.w, accuracy: 1e-5, "how much they hide doesn't depend on the order")
            worst = max(worst, length(SIMD3(got.x, got.y, got.z) - SIMD3(exact.x, exact.y, exact.z)))
        }
        print("k-buffer of 4 under 12 fragments: colour within \(worst) of the exact composite")
        XCTAssertLessThan(worst, 0.5)
    }

    func testTheFlipbooksStayInsideTheirTrim() {
        let n = ParticleTextures.size, c = ParticleTextures.cell
        for kind in ParticleTextures.Kind.allCases {
            let pixels = ParticleTextures.generate(kind)
            XCTAssertEqual(pixels, ParticleTextures.generate(kind), "\(kind): the same every time")
            var reach: Float = 0, border = 0
            for y in 0..<n {
                for x in 0..<n where pixels[(y * n + x) * 4 + 3] > 1 {
                    let lx = x % c, ly = y % c
                    let st = SIMD2((Float(lx) + 0.5) / Float(c) * 2 - 1, (Float(ly) + 0.5) / Float(c) * 2 - 1)
                    reach = max(reach, length(st))
                    if lx == 0 || ly == 0 || lx == c - 1 || ly == c - 1 { border += 1 }
                }
            }
            print(String(format: "flipbook %@: reaches %.3f of its cell (trim %.2f)", "\(kind)", reach, ParticleTextures.trim(kind)))
            XCTAssertEqual(border, 0, "\(kind): nothing on a cell's border (the filter would bleed into the next frame)")
            // A ray-facing particle's box holds a disc of the trim's radius: everything visible must be in it.
            XCTAssertLessThanOrEqual(reach, ParticleTextures.trim(kind) + 0.02, "\(kind)")
        }
    }

    /// A frame encodes its reset, steps and pose in one go (Renderer.encodeSceneUpdate): the pose's parameters mustn't
    /// take the place of a step's or the reset's before the GPU has run them (a burst at the first step was lost that
    /// way; and the pose's pool, the billboards', once left the mesh slots' dead list unset).
    func testThePoseLeavesTheStepsAlone() throws {
        var e = ParticleEmitter("burst", capacity: 12, at: [0, 0.5, 0])
        e.burst = (0, 12, 0, 0)
        e.lifetime = 100...100
        e.gravity = 0
        var rocks = ParticleEmitter("rocks", capacity: 8, at: [1, 0.5, 0])
        rocks.mesh = (0, 0)
        rocks.burst = (0.1, 5, 0, 0)
        rocks.lifetime = 100...100
        let system = ParticleSystem(emitters: [e, rocks])
        let m = try metal()
        let g = try ParticlesGPU(device: m.device, system: system, slots: 1)
        let cmd = m.queue.makeCommandBuffer()!
        let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
        g.encodeReset(Metal3Pass(enc: enc), pipelines: m.pipelines, slot: 0)
        g.encodeSteps(Metal3Pass(enc: enc), pipelines: m.pipelines, steps: 30, slot: 0)
        g.encodePose(Metal3Pass(enc: enc), pipelines: m.pipelines, slot: 0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        XCTAssertEqual(g.readAliveSlots().count, 17)
        XCTAssertEqual(Set(g.readAliveSlots()).count, 17, "each in a slot of its own")
        XCTAssertEqual(g.readRender(slot: 0).filter { $0.centerRadius.w > 0 }.count, 12, "all twelve billboards posed")
    }

    // MARK: Heat haze

    /// A distortion emitter's slots sit between the billboards' and the meshes'; it is simulated like any other, but
    /// never posed as a record or a box (no ray but the haze pass's meets it), nor counted in the builds' bounds.
    func testDistortionEmittersAreNeverBoxes() throws {
        var smoke = ParticleEmitter("smoke", capacity: 30, at: [0, 1, 0])
        smoke.rate = 20
        var sparks = ParticleEmitter("sparks", capacity: 20, at: [1, 1, 0])
        sparks.rate = 15
        sparks.castsShadows = false
        var heat = ParticleEmitter("heat", capacity: 24, at: [0, 0.5, 0])
        heat.rate = 30
        heat.lifetime = 0.5...0.8
        heat.speed = 0.5...1
        heat.distortion = 0.003
        var rocks = ParticleEmitter("rocks", capacity: 10, at: [2, 0.5, 0])
        rocks.mesh = (0, 0)
        rocks.burst = (0, 5, 0, 0)
        let system = ParticleSystem(emitters: [heat, smoke, rocks, sparks])
        XCTAssertEqual(system.casterCapacity, 30)
        XCTAssertEqual(system.billboardCapacity, 50)
        XCTAssertEqual(system.distortRange, 50..<74)
        XCTAssertEqual(system.bases, [50, 0, 74, 30])
        XCTAssertEqual(system.capacity, 84)
        let bounds = system.aliveBounds(after: 120)
        XCTAssertEqual(system.partBounds(after: 120), SIMD2(bounds[1], bounds[3]), "the haze isn't in the builds' bounds")
        XCTAssertEqual(system.gpuEmitters[0].extra.z, 0.003)

        let (g, run) = try gpu(system)
        run(60, .zero)
        let m = try metal()
        let cmd = m.queue.makeCommandBuffer()!
        let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
        g.encodePose(Metal3Pass(enc: enc), pipelines: m.pipelines, slot: 0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let all = g.readParticles()
        let hot = system.distortRange.filter { all[$0].info.w == ParticleSystem.alive }
        XCTAssertGreaterThan(hot.count, 10, "the heat is simulated")
        XCTAssertTrue(hot.allSatisfy { all[$0].info.z == 0 }, "its slots are its own")
        let billboards = (0..<system.billboardCapacity).filter { all[$0].info.w == ParticleSystem.alive }.count
        let render = g.readRender(slot: 0)
        let drawn = render.filter { $0.centerRadius.w > 0 }
        XCTAssertEqual(drawn.count, billboards, "a record for each alive billboard, none for the heat")
        XCTAssertTrue(drawn.allSatisfy { Int($0.info.x & 0xFFFFFF) < system.billboardCapacity })
    }

    // MARK: Mesh particles

    /// A mesh emitter's slots pose their instances: an alive one where its particle is, at its size, turned (a
    /// rotation times its size: orthogonal columns of that length) and last frame's place behind it along its
    /// velocity; a dead one shrunk at the emitter. The descriptor's transform is the record's.
    func testMeshParticlesPoseTheirInstances() throws {
        var dots = ParticleEmitter("dots", capacity: 50, at: [0, 1, 0])
        dots.rate = 60
        var rocks = ParticleEmitter("rocks", capacity: 40, at: [1, 0.5, 0])
        rocks.mesh = (0, 0)
        rocks.burst = (0, 25, 0, 0)
        rocks.lifetime = 5...5
        rocks.speed = 1...2
        rocks.spread = 0.5
        rocks.size = (0.1, 0.1)
        rocks.spin = 4
        let system = ParticleSystem(emitters: [dots, rocks])
        system.meshInstances[1] = 3
        XCTAssertEqual(system.billboardCapacity, 50)
        XCTAssertEqual(system.bases[1], 50)
        let (g, run) = try gpu(system)
        let m = try metal()
        let stride = 64
        let instances = m.device.makeBuffer(length: 50 * MemoryLayout<GPUInstanceData>.stride, options: .storageModeShared)!
        let descriptors = m.device.makeBuffer(length: 50 * stride, options: .storageModeShared)!
        func pose() {
            let cmd = m.queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            g.encodeMeshPose(Metal3Pass(enc: enc), pipelines: m.pipelines, instances: instances, descriptors: descriptors, descriptorStride: stride)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        run(20, .zero)
        pose()
        run(10, .zero)
        pose()
        let records = instances.contents().bindMemory(to: GPUInstanceData.self, capacity: 50)
        let all = g.readParticles()
        var alive = 0
        for k in 0..<40 {
            let q = all[50 + k], r = records[3 + k]
            let t = r.transform
            if q.info.w == ParticleSystem.alive {
                alive += 1
                XCTAssertLessThan(length(ParticleMath.xyz(t.columns.3) - ParticleMath.xyz(q.position)), 1e-5, "rock \(k) where its particle is")
                for c in [t.columns.0, t.columns.1, t.columns.2] { XCTAssertEqual(length(ParticleMath.xyz(c)), 0.1, accuracy: 1e-4) }
                XCTAssertEqual(dot(ParticleMath.xyz(t.columns.0), ParticleMath.xyz(t.columns.1)), 0, accuracy: 1e-4)
                let back = ParticleMath.xyz(q.position) - ParticleMath.xyz(q.velocity) * 10 * ParticleSystem.stepLength
                XCTAssertLessThan(length(ParticleMath.xyz(r.prevTransform.columns.3) - back), 1e-4, "last frame's place: 10 steps back")
                let inverse = r.normalMatrix.transpose
                XCTAssertLessThan(simd_length((inverse * t).columns.0 - SIMD4(1, 0, 0, 0)), 1e-3, "the normal matrix is the inverse's transpose")
            } else {
                XCTAssertLessThan(length(ParticleMath.xyz(t.columns.0)), 1e-3, "a dead rock is nothing")
                XCTAssertLessThan(length(ParticleMath.xyz(t.columns.3) - SIMD3(1, 0.5, 0)), 1e-5, "...at its emitter")
            }
            let d = (descriptors.contents() + (3 + k) * stride).bindMemory(to: Float.self, capacity: 12)
            XCTAssertEqual(SIMD3(d[9], d[10], d[11]), ParticleMath.xyz(t.columns.3), "the descriptor's translation")
        }
        XCTAssertEqual(alive, 25)
        XCTAssertEqual(g.traceCounts(slot: 0), .zero, "no boxes posed yet")
    }

    // MARK: Fields

    /// A field read at its nodes is what was put there; between them, trilinear; outside its box nothing. The baked
    /// curl tile repeats, is the curl it baked at its nodes, and between them nearly divergence-free.
    func testFieldsAndTheBakedCurl() {
        let f = ParticleField(center: [1, 2, 3], halfExtents: [1, 0.5, 2], dims: [3, 4, 5]) { p in p * SIMD3(2, -1, 0.5) }
        let g = f.gpu, samples = f.samples.map { SIMD4($0, 0) }
        var r = ParticleMath.Rng(state: 9)
        for _ in 0..<200 {
            let p = f.lo + f.size * SIMD3(r.next(), r.next(), r.next())
            XCTAssertLessThan(length(ParticleMath.field(g, samples, p) - p * SIMD3(2, -1, 0.5)), 1e-4, "linear: trilinear is exact")
        }
        XCTAssertEqual(ParticleMath.field(g, samples, f.lo - 0.1), .zero, "outside its box")

        let tile = ParticleSystem.curlTile, t = tile.gpu, ts = tile.samples.map { SIMD4($0, 0) }
        var worstDiv: Float = 0, mean: Float = 0, worstNode: Float = 0
        for _ in 0..<300 {
            let p = SIMD3(r.next(), r.next(), r.next()) * 4
            let a = ParticleMath.field(t, ts, p), b = ParticleMath.field(t, ts, p + SIMD3(4, -8, 12))
            XCTAssertLessThan(length(a - b), 1e-4, "it tiles")
            let h: Float = 0.02
            func c(_ o: SIMD3<Float>) -> SIMD3<Float> { ParticleMath.field(t, ts, p + o) }
            let div = (c([h, 0, 0]).x - c([-h, 0, 0]).x + c([0, h, 0]).y - c([0, -h, 0]).y + c([0, 0, h]).z - c([0, 0, -h]).z) / (2 * h)
            worstDiv = max(worstDiv, abs(div))
            mean += length(a) / 300
            let node = (SIMD3(r.next(), r.next(), r.next()) * 32).rounded(.down) / 8
            worstNode = max(worstNode, length(ParticleMath.field(t, ts, node) - ParticleMath.periodicCurl(node, period: 4)))
        }
        print("baked curl: |v| ~ \(mean), divergence at most \(worstDiv), off the baked curl at its nodes by \(worstNode)")
        XCTAssertLessThan(worstNode, 1e-4)
        XCTAssertLessThan(worstDiv, mean * 2.5, "about divergence-free (the interpolation's error, a cell is an eighth of the noise's)")
    }

    // MARK: Trails

    /// A trail's control points are its particle's last places, oldest first, `every` steps apart, then its head (where
    /// it is), tapering from the head's radius to nothing; a dead particle's trail is nothing.
    func testTrailsFollowTheirParticles() throws {
        var e = ParticleEmitter("wisps", capacity: 40, at: [0, 1, 0])
        e.rate = 60
        e.lifetime = 1.5...1.5
        e.speed = 1...2
        e.spread = 0.6
        e.gravity = 0
        e.size = (0.02, 0.02)
        e.trail = (points: 6, every: 2)
        e.trailWidth = 0.5
        let system = ParticleSystem(emitters: [e])
        XCTAssertEqual(system.trailControlPoints, 7)
        XCTAssertEqual(system.trailSegments, 4)
        let (g, run) = try gpu(system)
        let m = try metal()
        run(61, .zero)
        let cmd = m.queue.makeCommandBuffer()!
        let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
        g.encodePose(Metal3Pass(enc: enc), pipelines: m.pipelines, slot: 0)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let points = g.trailPoints[0].contents().bindMemory(to: SIMD4<Float>.self, capacity: 40 * 7)
        let all = g.readParticles()
        var checked = 0
        let dt = ParticleSystem.stepLength
        for slot in 0..<40 {
            let q = all[slot], c = (0..<7).map { points[slot * 7 + $0] }
            guard q.info.w == ParticleSystem.alive else {
                XCTAssertTrue(c.allSatisfy { $0.w == 0 }, "a dead particle's trail is nothing")
                continue
            }
            let v = ParticleMath.xyz(q.velocity)
            XCTAssertLessThan(length(ParticleMath.xyz(c[6]) - ParticleMath.xyz(q.position)), 1e-5, "the head is where it is")
            for j in 0..<7 { XCTAssertEqual(c[j].w, 0.02 * 0.5 * Float(j) / 6, accuracy: 1e-6, "tapering to nothing") }
            // Old enough for a full ring (6 places, 2 steps apart): its places are 2 steps of its flight apart.
            guard q.position.w > 14 * dt else { continue }
            for j in 0..<5 {
                XCTAssertLessThan(length(ParticleMath.xyz(c[j + 1] - c[j]) - v * 2 * dt), 1e-4, "place \(j) to \(j + 1)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 20)
        XCTAssertEqual(g.trailShape, SIMD2(40, 7))
    }

    // MARK: The structures' sizes

    /// The CPU's bound on each emitter's alive particles (what the builds take) holds at every step, children and
    /// splashes too, and isn't the pool when the pool is larger than the effect.
    func testTheAliveBoundHolds() {
        for system in [swirl(), sparks(capacity: 900)] {
            let cpu = ParticlesCPU(system)
            var slack = [Int](repeating: Int.max, count: system.emitters.count)
            for _ in 0..<400 {
                cpu.step(wind: [1, 0, 0.5, 0])
                let bounds = system.aliveBounds(after: cpu.stepIndex)
                for e in system.emitters.indices {
                    let n = cpu.current.filter { $0.info.z == e }.count
                    XCTAssertLessThanOrEqual(n, bounds[e], "\(system.emitters[e].name) after \(cpu.stepIndex) steps")
                    slack[e] = min(slack[e], bounds[e] - n)
                }
            }
            print("alive bounds: least slack \(slack) (\(system.emitters.map(\.name)))")
        }
        // A long-lived burst: its bound is the burst, not the pool.
        var e = ParticleEmitter("burst", capacity: 1000, at: .zero)
        e.burst = (1, 12, 0, 0)
        e.lifetime = 1e6...1e6
        let system = ParticleSystem(emitters: [e])
        XCTAssertEqual(system.aliveBounds(after: 30), [0])
        XCTAssertEqual(system.aliveBounds(after: 61), [12])
        XCTAssertEqual(system.aliveBounds(after: 100_000), [12])
    }

    /// The pose packs every alive particle at the front of its structure's range, frame after frame (its counters
    /// alternate), and empties the rest.
    func testThePosePacksTheAlive() throws {
        var lit = ParticleEmitter("lit", capacity: 400, at: [0, 1, 0])
        lit.rate = 200
        lit.lifetime = 0.5...1.5
        lit.speed = 1...2
        var glow = ParticleEmitter("glow", capacity: 600, at: [1, 1, 0])
        glow.rate = 300
        glow.burst = (0.3, 100, 0.4, 0)
        glow.lifetime = 0.3...1
        glow.castsShadows = false
        let system = ParticleSystem(emitters: [lit, glow])
        let (g, run) = try gpu(system)
        let m = try metal()
        for frame in 0..<6 {
            run(17, .zero)
            let cmd = m.queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            g.encodePose(Metal3Pass(enc: enc), pipelines: m.pipelines, slot: 0)
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            let alive = gpuAlive(g)
            let casters = alive.filter { $0.info.z == 0 }.count, others = alive.count - casters
            let bound = g.traceCounts(slot: 0)
            XCTAssertLessThanOrEqual(casters, Int(bound.x))
            XCTAssertLessThanOrEqual(others, Int(bound.y))
            let render = g.readRender(slot: 0), live = render.map { $0.centerRadius.w > 0 }
            let boxes = g.boxes[0].contents().bindMemory(to: Float.self, capacity: system.capacity * 6)
            for i in 0..<system.capacity {
                let expected = i < casters || (i >= Int(bound.x) && i < Int(bound.x) + others)
                XCTAssertEqual(live[i], expected, "frame \(frame): record \(i)")
                XCTAssertEqual(boxes[6 * i] < 1e29, expected, "frame \(frame): box \(i)")
            }
            let slots = Set(render.filter { $0.centerRadius.w > 0 }.map { $0.info.x & 0xFFFFFF })
            XCTAssertEqual(slots, Set(g.readAliveSlots()), "frame \(frame): each alive slot posed once")
            print("pose \(frame): casters \(casters) of bound \(bound.x), others \(others) of \(bound.y), pool \(system.capacity)")
        }
    }
}
