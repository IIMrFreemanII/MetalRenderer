import XCTest
import Metal
import simd
@testable import MetalRenderer

/// The effects as graphs (Sources/MetalRenderer/VFX): the built-in ones lower to the emitters the scenes had before
/// (byte for byte), JSON and Swift round trips, the generated code against the CPU's interpreter of the same graph,
/// rate curves' bounds, conditions, attributes.
final class VFXTests: XCTestCase {
    private func builtInScene(_ kind: SceneKind) -> Scene {
        var settings = SceneSettings(kind: kind)
        settings.effects = "builtin"
        return Scene(settings)
    }

    /// Two descriptors' bytes, field by field (their names for the message).
    private func assertSame(_ a: GPUParticleEmitter, _ b: GPUParticleEmitter, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let fields: [(String, KeyPath<GPUParticleEmitter, SIMD4<Float>>)] = [
            ("origin", \.origin), ("axis", \.axis), ("extent", \.extent), ("velocity", \.velocity), ("speed", \.speed), ("life", \.life),
            ("burst", \.burst), ("forces", \.forces), ("noise", \.noise), ("attractor", \.attractor), ("size", \.size),
            ("color0", \.color0), ("color1", \.color1), ("color2", \.color2), ("look", \.look), ("flip", \.flip), ("lock", \.lock),
            ("extra", \.extra), ("field", \.field),
        ]
        for (f, k) in fields {
            let x = a[keyPath: k], y = b[keyPath: k]
            XCTAssertEqual((0..<4).map { x[$0].bitPattern }, (0..<4).map { y[$0].bitPattern }, "\(name).\(f): \(x) vs \(y)", file: file, line: line)
        }
        for (f, k) in [("ids", \GPUParticleEmitter.ids), ("ids2", \GPUParticleEmitter.ids2), ("ids3", \GPUParticleEmitter.ids3)] {
            XCTAssertEqual(a[keyPath: k], b[keyPath: k], "\(name).\(f)", file: file, line: line)
        }
    }

    /// The particles scene's effects lower to the emitters it had, byte for byte: the same descriptors in the same
    /// order (so the same pool), the same colliders and fields, no programs.
    func testBuiltInEffectsLowerToTheEmittersTheyWere() throws {
        let scene = builtInScene(.particles)
        let system = try XCTUnwrap(scene.particles)
        XCTAssertTrue(scene.effectNotes.isEmpty, "\(scene.effectNotes)")
        XCTAssertTrue(system.programs.allSatisfy { $0 == nil })
        XCTAssertNil(system.programSource)
        let rubble = try XCTUnwrap(system.emitters.first { $0.name == "rubble" })
        let vortex = try XCTUnwrap(system.fields.firstIndex { $0.lo == ParticleField.vortex(center: [-1.9, 0.05, 2.2], radius: 0.7, height: 1.6,
                                                                                               swirl: 1.2, lift: 0.6).lo })
        let legacy = LegacyEffects.particles(colliders: scene.effectColliders.map(\.collider), rock: try XCTUnwrap(rubble.mesh),
                                             fields: (0, 1))
        XCTAssertEqual(vortex, 0, "the fields in the order they were: the whirl, then the hot air")
        legacy.meshInstances = system.meshInstances
        XCTAssertEqual(system.emitters.map(\.name), legacy.emitters.map(\.name))
        for (i, (a, b)) in zip(system.gpuEmitters, legacy.gpuEmitters).enumerated() { assertSame(a, b, system.emitters[i].name) }
        XCTAssertEqual(system.bases, legacy.bases)
        XCTAssertEqual(system.capacity, legacy.capacity)
        XCTAssertEqual(system.gpuColliders.map(\.a), legacy.gpuColliders.map(\.a))
        XCTAssertEqual(system.gpuColliders.map(\.b), legacy.gpuColliders.map(\.b))
        let (t0, s0) = system.gpuFields, (t1, s1) = legacy.gpuFields
        XCTAssertEqual(t0.map(\.lo), t1.map(\.lo))
        XCTAssertEqual(t0.map(\.dims), t1.map(\.dims))
        XCTAssertEqual(s0, s1)
    }

    // MARK: GPU

    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static var compiled: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)?

    private func metal() throws -> (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines) {
        if let compiled = VFXTests.compiled { return compiled }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: VFXTests.shaders, lightTypes: 0x3F, stats: false)
        VFXTests.compiled = (device, queue, pipelines)
        return (device, queue, pipelines)
    }

    /// `system` on the GPU, reset, with its programs' kernels compiled (VFXCompiler) if it has any: `run(steps)`.
    private func gpu(_ system: ParticleSystem) throws -> (gpu: ParticlesGPU, run: (Int) -> Void) {
        let m = try metal()
        let gpu = try ParticlesGPU(device: m.device, system: system, slots: 1)
        if let source = system.programSource {
            let setup = VFXCompiler.Setup(entry: VFXTests.shaders.deletingLastPathComponent().appendingPathComponent("ShadersVFX.metal"),
                                          lightTypes: 0x3F, stats: false, metal4: false)
            gpu.programKernels = VFXCompiler.shared.kernels(for: source, setup: setup, device: m.device, compiler: nil, wait: true)
            XCTAssertNotNil(gpu.programKernels, VFXCompiler.shared.failure(for: source, setup: setup) ?? "")
        }
        let run = { (steps: Int) in
            let cmd = m.queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            if steps < 0 { gpu.encodeReset(Metal3Pass(enc: enc), pipelines: m.pipelines, slot: 0) }
            var left = max(steps, 0)
            while left > 0 {
                let n = min(left, ParticlesGPU.maxStepsPerFrame)
                gpu.encodeSteps(Metal3Pass(enc: enc), pipelines: m.pipelines, steps: n, slot: 0)
                left -= n
            }
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            XCTAssertNil(cmd.error)
        }
        run(-1)
        return (gpu, run)
    }

    private struct Key: Hashable { let emitter: UInt32; let spawn: UInt32 }
    private func alive(_ g: ParticlesGPU) -> [Key: GPUParticle] {
        let all = g.readParticles()
        return Dictionary(g.readAliveSlots().map { all[Int($0)] }.map { (Key(emitter: $0.info.z, spawn: $0.info.x), $0) },
                          uniquingKeysWith: { a, _ in a })
    }

    // MARK: Programs

    /// An effect that needs generated code for every kind of hook: a rate a curve scales, a wired lifetime, an
    /// attribute set at birth and read later, a wired gravity share, a force of curl noise, a kill above a height, a
    /// trigger for a child on a condition, a smooth size curve and a gradient of four keys.
    private func programEffect() -> VFXEffect {
        VFXEffect("program", emitters: [
            VFXEmitter("fountain", capacity: 3000, seed: 1,
                       spawn: [.rate(500, overTime: VFXCurve([[0, 0.2], [0.5, 1], [1, 0.5]]), span: 1.5)],
                       initialize: [.shape("disc", at: [0, 0.2, 0], radius: 0.1), .velocity(speed: 2...3, spread: 0.3),
                                    .lifetime(0.8...1.6, max: 2, id: "life"), .setAttribute("A", id: "tint")],
                       update: [.gravity(1, id: "g"), .drag(0.8, wind: 1), .force(id: "push"), .kill(id: "ceiling"), .trigger(id: "burst")],
                       output: [.billboard(), .size(curve: VFXCurve([[0, 0.02], [0.3, 0.06], [1, 0]], smooth: true)),
                                .color(VFXGradient([.init(0, [1, 0, 0, 1]), .init(0.25, [1, 1, 0, 1]), .init(0.5, [0, 1, 0, 1]),
                                                    .init(1, [0, 0, 1, 0])]))]),
            VFXEmitter("sparkles", capacity: 2000, seed: 2,
                       spawn: [.event("fountain", on: "condition", count: 2)],
                       initialize: [.velocity(speed: 0.2...0.4, spread: 3), .lifetime(0.3...0.5)],
                       output: [.billboard(), .size(0.01, 0)]),
        ], nodes: [
            VFXNode(.random, ["salt": .int(0)], id: "r0"),
            VFXNode(.multiply, ["b": .float(0.8)], id: "spread"),
            VFXNode(.add, ["b": .float(0.8)], id: "lifeValue"),
            VFXNode(.random, ["salt": .int(1)], id: "r1"),
            VFXNode(.ageOverLife, id: "t"),
            VFXNode(.curve, ["curve": .curve(VFXCurve([[0, 1.5], [1, -0.5]]))], id: "share"),
            VFXNode(.position, id: "p"),
            VFXNode(.curlNoise, ["frequency": .float(1.5), "scroll": .float(0.4)], id: "curl"),
            VFXNode(.multiply, ["b": .float(3)], id: "strength"),
            VFXNode(.splitVector, id: "split"),
            VFXNode(.compare, ["b": .float(2.2), "op": .choice(">")], id: "high"),
            VFXNode(.getAttribute, ["attribute": .choice("A")], id: "a"),
            VFXNode(.splitColor, id: "aSplit"),
            VFXNode(.compare, ["b": .float(0.9), "op": .choice(">")], id: "lucky"),
            VFXNode(.compare, ["b": .float(0.5), "op": .choice(">")], id: "late"),
            VFXNode(.and, id: "both"),
        ], links: [
            VFXLink("r0", to: "spread", "a"), VFXLink("spread", to: "lifeValue", "a"), VFXLink("lifeValue", to: "life", "lifetime"),
            VFXLink("r1", to: "tint", "value"),
            VFXLink("t", to: "share", "t"), VFXLink("share", to: "g", "share"),
            VFXLink("p", to: "curl", "p"), VFXLink("curl", to: "strength", "a"), VFXLink("strength", to: "push", "force"),
            VFXLink("p", to: "split", "v"), VFXLink("split", "y", to: "high", "a"), VFXLink("high", to: "ceiling", "when"),
            VFXLink("a", to: "aSplit", "c"), VFXLink("aSplit", "a", to: "lucky", "a"),
            VFXLink("t", to: "late", "a"), VFXLink("lucky", to: "both", "a"), VFXLink("late", to: "both", "b"),
            VFXLink("both", to: "burst", "when"),
        ])
    }

    private func programSystem() -> ParticleSystem {
        let lowered = VFXLowering.system([VFXInstance(effect: programEffect(), place: .identity)])
        XCTAssertTrue(lowered.diagnostics.isEmpty, "\(lowered.diagnostics)")
        return lowered.system
    }

    func testAProgramIsMadeOnlyWhereTheGraphAsksForOne() throws {
        let system = programSystem()
        let fountain = try XCTUnwrap(system.programs[0]), sparkles = system.programs[1]
        XCTAssertEqual(fountain.hooks, [.spawn, .step, .output, .rate])
        XCTAssertNil(sparkles, "the child is the fixed emitter's")
        XCTAssertEqual(fountain.attributes, 1)
        XCTAssertEqual(system.attributeStride, 1)
        XCTAssertEqual(system.emitters[1].trigger, .condition)
        XCTAssertNotNil(system.emitters[0].rateCurve)
        // Its values are parameters, never literals: a value's edit needs no compile.
        let source = try XCTUnwrap(system.programSource)
        XCTAssertFalse(source.contains("2.2"), "the Compare's value is read from the parameters")
        XCTAssertTrue(source.contains("vfxStep1"))
        let slot = try XCTUnwrap(fountain.slots["high.b"])
        XCTAssertEqual(fountain.params[slot].x, 2.2)
    }

    func testProgramsMatchTheInterpreter() throws {
        let system = programSystem()
        let (g, run) = try gpu(system)
        let cpu = VFXInterpreter(system)
        var worst: [Float] = []
        for steps in [1, 10, 120] {
            run(steps - g.stepIndex)
            cpu.advance(steps: steps - cpu.stepIndex)
            let a = alive(g)
            let b = Dictionary(cpu.current.map { (Key(emitter: $0.info.z, spawn: $0.info.x), $0) }, uniquingKeysWith: { x, _ in x })
            for e in 0..<2 {
                let na = a.keys.filter { $0.emitter == e }.count, nb = b.keys.filter { $0.emitter == e }.count
                XCTAssertEqual(Float(na), Float(nb), accuracy: max(Float(nb) * 0.02, 2), "\(system.emitters[e].name) after \(steps) steps")
            }
            var w: Float = 0, shared = 0
            for (k, p) in a where k.emitter == 0 {
                guard let q = b[k] else { continue }
                shared += 1
                XCTAssertEqual(p.info.y, q.info.y, "the same seed")
                XCTAssertEqual(p.velocity.w, q.velocity.w, accuracy: 1e-5, "the same (wired) lifetime")
                w = max(w, length(ParticleMath.xyz(p.position) - ParticleMath.xyz(q.position)))
            }
            XCTAssertGreaterThan(shared, 0)
            worst.append(w)
        }
        print("program, GPU against CPU: within \(worst) m after 1, 10, 120 steps; the VFX library compiled in \(VFXCompiler.shared.lastMilliseconds ?? 0) ms")
        XCTAssertLessThan(worst[0], 1e-5)
        XCTAssertLessThan(worst[1], 1e-4)
        XCTAssertLessThan(worst[2], 2e-3)
        // Its attribute, set at birth from its seed: the same as the CPU's.
        let stride = system.attributeStride
        let gpuAttributes = g.attributes.contents().bindMemory(to: SIMD4<Float>.self, capacity: system.capacity * stride)
        for slot in g.readAliveSlots().prefix(50) {
            let p = g.readParticles()[Int(slot)]
            guard p.info.z == 0 else { continue }
            XCTAssertEqual(gpuAttributes[Int(slot) * stride].w, ParticleMath.random(p.info.y, 17), accuracy: 1e-6)
        }
        // The children come from the condition only (a death is no event for them).
        XCTAssertGreaterThan(alive(g).keys.filter { $0.emitter == 1 }.count, 0)
    }

    /// A fixed emitter's particles in the VFX library's kernels (a system with programs) are the main library's to fast
    /// math's rounding: the same particles, a few ulps apart (the compiler fuses the same statements differently in
    /// the other library). A scene without programs runs the main library: its frames don't change at all.
    func testFixedEmittersInTheVFXLibraryAreTheMainLibrarysToRounding() throws {
        let plain = VFXLowering.system([VFXInstance(effect: VFXLibrary.magic(at: [0, 1, 0]), place: .identity)]).system
        let mixed = VFXLowering.system([VFXInstance(effect: VFXLibrary.magic(at: [0, 1, 0]), place: .identity),
                                        VFXInstance(effect: programEffect(), place: .identity)]).system
        let (p, runP) = try gpu(plain), (q, runQ) = try gpu(mixed)
        XCTAssertNil(p.programKernels)
        XCTAssertNotNil(q.programKernels)
        runP(120); runQ(120)
        let pa = alive(p), qa = alive(q)
        let e = UInt32(mixed.emitters.firstIndex { $0.name == "magic" }!)
        let motes = pa.filter { plain.emitters[Int($0.key.emitter)].name == "magic" }
        XCTAssertGreaterThan(motes.count, 100)
        var same = 0, worst: Float = 0
        for (k, x) in motes {
            guard let y = qa[Key(emitter: e, spawn: k.spawn)] else { XCTFail("a mote missing"); continue }
            same += x.position == y.position && x.velocity == y.velocity ? 1 : 0
            worst = max(worst, length(ParticleMath.xyz(x.position) - ParticleMath.xyz(y.position)))
            XCTAssertEqual(x.velocity.w, y.velocity.w, accuracy: 1e-5, "the same lifetime")
        }
        print("fixed emitters in the VFX library: \(same) of \(motes.count) motes bit for bit, the rest within \(worst) m after 120 steps")
        XCTAssertLessThan(worst, 1e-4)
    }

    /// `METALRENDERER_VFX_FORCE=all` (measuring generated code's cost): every emitter of the built-in effects gets a
    /// program, which does what its fixed emitter does: the same particles, to the other library's rounding. (The
    /// effects without scene collisions: this test has no scene to trace.)
    func testForcedProgramsDoWhatTheFixedEmittersDo() throws {
        let effects = ["campfire", "magic", "embers", "bubbles", "dust", "runes"].compactMap(VFXLibrary.named)
        let instances = effects.map { VFXInstance(effect: $0, place: .identity) }
        let plain = VFXLowering.system(instances).system
        let saved = VFXForce.mode
        VFXForce.mode = .all
        let forced = VFXLowering.system(instances).system
        VFXForce.mode = saved
        XCTAssertTrue(forced.programs.allSatisfy { $0 != nil })
        XCTAssertTrue(forced.programs.allSatisfy { $0!.hooks.isSuperset(of: [.spawn, .step]) })
        XCTAssertEqual(forced.gpuEmitters.map(\.size), plain.gpuEmitters.map(\.size))
        let (p, runP) = try gpu(plain), (q, runQ) = try gpu(forced)
        runP(120); runQ(120)
        let pa = alive(p), qa = alive(q)
        XCTAssertGreaterThan(pa.count, 500)
        var same = 0, missing = 0, worst: Float = 0
        for (k, x) in pa {
            guard let y = qa[k] else { missing += 1; continue }
            same += x.position == y.position && x.velocity == y.velocity ? 1 : 0
            worst = max(worst, length(ParticleMath.xyz(x.position) - ParticleMath.xyz(y.position)))
        }
        print("forced programs: \(same) of \(pa.count) particles bit for bit, \(missing) missing, the rest within \(worst) m after 120 steps")
        XCTAssertEqual(Float(qa.count), Float(pa.count), accuracy: Float(pa.count) * 0.01)
        XCTAssertLessThan(worst, 1e-3)
    }

    /// The pose's size and colour from the program (a smooth size curve, a gradient of four keys) are the CPU's.
    func testProgramsLookAsTheInterpreterSays() throws {
        let system = programSystem()
        let m = try metal()
        let (g, run) = try gpu(system)
        run(60)
        let cmd = m.queue.makeCommandBuffer()!, enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
        g.encodePose(Metal3Pass(enc: enc), pipelines: m.pipelines, slot: 0)
        enc.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
        let cpu = VFXInterpreter(system)
        cpu.advance(steps: 60)
        let particles = g.readParticles()
        var checked = 0
        for r in g.readRender(slot: 0) where r.centerRadius.w > 0 {
            let slot = Int(r.info.x & 0xFFFFFF)
            let q = particles[slot]
            guard q.info.z == 0 else { continue }
            let (size, color) = cpu.look(q, slot: slot)
            XCTAssertEqual(r.centerRadius.w, size, accuracy: 1e-5)
            XCTAssertEqual(Float(r.color.x), color.x, accuracy: 2e-3)
            XCTAssertEqual(Float(r.color.y), color.y, accuracy: 2e-3)
            XCTAssertEqual(Float(r.color.w), color.w, accuracy: 2e-3)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 50)
    }

    /// A rate curve's births: the GPU's per step as the CPU's, and the CPU's bound holds them.
    func testARateCurvesBirthsAndBound() throws {
        let system = programSystem()
        let cpu = VFXInterpreter(system)
        var most = 0
        for k in 0..<240 {
            cpu.step()
            let n = cpu.current.filter { $0.info.z == 0 }.count
            most = max(most, n)
            XCTAssertLessThanOrEqual(n, system.aliveBounds(after: k + 1)[0], "the bound holds after \(k + 1) steps")
        }
        // 500/s scaled from 0.2 up to 1 and back to 0.5 over 1.5 s: about (0.2 + 1) / 2 * 0.75 + (1 + 0.5) / 2 * 0.75 = 1.0 s at 500/s.
        let s = system.stepParams(0)
        var total = 0
        for k in 0..<90 { var p = s; p.step = UInt32(k); total += Int(ParticleSystem.requests(system.gpuEmitters[0], p, curve: system.emitters[0].rateCurve!)) }
        XCTAssertEqual(Float(total), 500 * 1.0125, accuracy: 3, "the curve's integral over its span, at 500/s")
        XCTAssertGreaterThan(most, 0)
    }

    // MARK: Round trips

    func testEffectsRoundTripThroughJSON() throws {
        let fire = SIMD3<Float>(-2.6, 0.95, -0.5)
        for e in [VFXLibrary.campfire(fire: fire), VFXLibrary.rain(center: [1, 2, 3], half: [1, 0, 1]), VFXLibrary.rubble(at: .zero),
                  VFXLibrary.runes(height: 1, radius: 2, speed: 0.6, color: [1, 0.5, 0.2]), programEffect()] {
            let back = try VFXStore.decode(VFXStore.encode(e))
            XCTAssertEqual(back, e, e.name)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vfx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try VFXStore.save(programEffect(), in: folder)
        XCTAssertEqual(VFXStore.load(from: folder).effects["program"], programEffect())
    }

    func testCopyAsSwiftWritesTheBuilders() {
        let swift = VFXLibrary.campfire(fire: [-2.6, 0.95, -0.5]).swiftSource
        XCTAssertTrue(swift.contains("VFXEmitter(\"flames\", capacity: 200, seed: 0"))
        XCTAssertTrue(swift.contains(".rate(180)"))
        XCTAssertTrue(swift.contains(".curl(2, frequency: 2.5, speed: 1.5, baked: true)"))
        XCTAssertTrue(swift.contains(".orient(\"axis\")"), "the axis is its default")
        XCTAssertTrue(swift.contains("VFXField(name: \"hot air\", kind: .plume"))
        let program = programEffect().swiftSource
        XCTAssertTrue(program.contains(".lifetime(0.8...1.6, max: 2, id: \"life\")"), program)
        XCTAssertTrue(program.contains("VFXLink(\"split\", \"y\", to: \"high\", \"a\")"))
        print(program)
    }
}
