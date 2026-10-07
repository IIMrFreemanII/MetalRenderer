import XCTest
import Metal
import simd
@testable import MetalRenderer

/// PhysicsFlesh.swift, PhysicsRig.swift, PhysicsSkin.swift, MuscleAtlas.swift, SkeletonAtlas.swift and the muscles scene: kinematic bodies
/// that follow their table and carry what they touch, a character's rig, flesh held to its bones, muscles that bulge
/// as their joints bend and keep their volume, the skin, the écorché and its skeleton, and the GPU's steps against the CPU's.
final class MuscleTests: XCTestCase {
    // MARK: Kinematic bodies

    /// A world with a floor and one kinematic box, moved by a table of `rows` rows: `path(k)` is row k's centre.
    private func kinematicWorld(rows: Int, path: (Int) -> SIMD3<Float>) -> (PhysicsWorld, Int) {
        let w = PhysicsWorld(substeps: 16)
        w.addPlane(point: .zero, normal: [0, 1, 0], friction: 0.7, restitution: 0.1)
        let box = SDFShape(.box(halfExtents: [0.5, 0.05, 0.5], rounding: 0.01))
        let b = w.addKinematicBody(sdf: 0, box, transform: translate(path(0)), instance: 0, friction: 0.8)
        w.kinematicTable = (0..<rows).flatMap { k -> [SIMD4<Float>] in
            let (x, q) = w.bodyPose(b, translate(path(k)))
            return [SIMD4(x, 0), q]
        }
        return (w, b)
    }

    func testAKinematicBodyFollowsItsTable() {
        let rows = 120
        let path = { (k: Int) -> SIMD3<Float> in [0.8 * sin(Float(k) * 2 * .pi / Float(rows)), 0.5, 0] }
        let (w, b) = kinematicWorld(rows: rows, path: path)
        w.finish()
        for _ in 0..<150 { w.step() }
        // After step k it is at row k (the table repeats), and goes at the speed it took to get there.
        XCTAssertEqual(PhysicsMath.xyz(w.bodies[b].position).x, path(150).x, accuracy: 1e-5)
        let speed = (path(150).x - path(149).x) / PhysicsWorld.stepLength
        XCTAssertEqual(w.bodies[b].velocity.x, speed, accuracy: 0.05 * abs(speed) + 1e-3)
        XCTAssertEqual(w.bodies[b].position.w, 0, "nothing moves it")
    }

    func testAKinematicBodyCarriesABoxAndKeepsItAwake() {
        // A platform sliding 0.8 m and back (from rest, 4 s), a box resting on it: friction (0.8 g) holds it to the
        // platform's 1 m/s^2 at most.
        let rows = 240
        let path = { (k: Int) -> SIMD3<Float> in [0.4 - 0.4 * cos(Float(k) * 2 * .pi / Float(rows)), 0.3, 0] }
        let (w, b) = kinematicWorld(rows: rows, path: path)
        let box = SDFShape(.box(halfExtents: [0.1, 0.1, 0.1], rounding: 0.01))
        let i = w.addBody(sdf: 1, box, transform: translate([0, 0.46, 0]), instance: 1, density: 300, friction: 0.8, restitution: 0)
        w.finish()
        var asleep = 0
        for _ in 0..<90 {
            w.step()
            if w.bodies[i].info.y & PhysicsWorld.asleep != 0 { asleep += 1 }
        }
        let carried = PhysicsMath.xyz(w.bodies[i].position).x, moved = PhysicsMath.xyz(w.bodies[b].position).x
        print(String(format: "a box on a sliding platform: went %.3f m with it (it went %.3f m), asleep %d steps of 90", carried, moved, asleep))
        XCTAssertEqual(w.bodies[i].position.y, 0.45, accuracy: 0.01, "on the platform, not through it")
        XCTAssertEqual(carried, moved, accuracy: 0.02, "friction carries it along")
        XCTAssertEqual(asleep, 0, "a moving platform keeps it awake")
    }

    // MARK: The character's rig

    private static let library = CharacterLibrary.load()

    private func rig() throws -> CharacterRig {
        guard let character = MuscleTests.library.characters.first(where: { $0.name.contains("Y Bot") }) ?? MuscleTests.library.characters.first
        else { throw XCTSkip("no characters in \(CharacterLibrary.directory.path)") }
        return try XCTUnwrap(CharacterRig(character), "the rig finds its joints")
    }

    func testTheRigFitsTheCharacter() throws {
        let rig = try rig()
        XCTAssertEqual(rig.bones.count, CharacterRig.modelled.count)
        for b in rig.bones { print(String(format: "  %@: %.3f m thick, %.3f m long", "\(b.role)", b.thickness, simd_length(b.to - b.from))) }
        let thigh = try XCTUnwrap(rig.bones.first { $0.role == .thigh(1) }), forearm = try XCTUnwrap(rig.bones.first { $0.role == .forearm(1) })
        XCTAssert((0.04...0.12).contains(thigh.thickness), "a thigh \(thigh.thickness) m thick")
        XCTAssert((0.02...0.07).contains(forearm.thickness), "a forearm \(forearm.thickness) m thick")
        XCTAssertGreaterThan(thigh.thickness, forearm.thickness)
    }

    func testTheProgrammeRepeats() throws {
        let rig = try rig()
        let w = PhysicsWorld(substeps: 4)
        var bodies: [Int] = []
        for (b, bone) in rig.bones.enumerated() {
            bodies.append(w.addKinematicBody(sdf: b, bone.shape, transform: rig.restPlacement(b), instance: b))
        }
        let (table, radius) = rig.table(centre: .zero) { b, placed in w.bodyPose(bodies[b], placed) }
        let rows = table.count / (2 * bodies.count)
        XCTAssertEqual(rows, Int((CharacterRig.seconds / PhysicsWorld.stepLength).rounded()))
        // No bone jumps: a step's move is never far from the moves before and after it (a running foot goes 0.2 m
        // a step, smoothly), the last step's into the first included (the table repeats).
        func move(_ k: Int, _ b: Int) -> Float {
            simd_length(PhysicsMath.xyz(table[(((k + 1) % rows) * bodies.count + b) * 2] - table[(k * bodies.count + b) * 2]))
        }
        var worst: (jump: Float, step: Int, bone: Int) = (0, 0, 0), fastest: Float = 0
        for k in 0..<rows {
            for b in bodies.indices {
                let here = move(k, b), around = (move((k + rows - 1) % rows, b) + move((k + 1) % rows, b)) / 2
                fastest = max(fastest, here)
                if here - around > worst.jump { worst = (here - around, k, b) }
            }
        }
        print(String(format: "the programme: %d steps round a circle %.2f m across; a bone goes %.3f m a step at most, %.3f m more than around it (%@, step %d)",
                     rows, 2 * radius, fastest, worst.jump, "\(rig.bones[worst.bone].role)", worst.step))
        XCTAssert((2...3.5).contains(radius), "a circle \(2 * radius) m across")
        XCTAssertLessThan(worst.jump, 0.03, "no step jumps")
        XCTAssertLessThan(bodies.indices.map { move(rows - 1, $0) }.max()!, 0.02, "the last step into the first is an idle's")
    }

    // MARK: The scene's flesh

    private func scene(character: Bool = true, ragdolls: Int = 1, skin: PhysicsSettings.Skin = .embedded, muscles: Float = 1,
                       body: PhysicsSettings.Body = .skin) -> Scene {
        var settings = SceneSettings(kind: .muscles)
        settings.physics.body = body
        settings.physics.muscleGain = muscles
        settings.physics.muscleCharacter = character
        settings.physics.muscleRagdolls = ragdolls
        settings.physics.skin = skin
        settings.physics.backend = .cpu
        return Scene(settings)
    }

    /// Every pin's particle against where its bones put it now: the hard ones' worst miss, and the soft ones'.
    private func pinned(_ w: PhysicsWorld) -> (hard: Float, soft: Float) {
        var hard: Float = 0, soft: Float = 0
        for pin in w.pins {
            let miss = length(PhysicsMath.xyz(w.particles[Int(pin.particle)].position)
                              - PhysicsWorld.pinTarget(pin, w.bodies[Int(pin.bodyA)], w.bodies[Int(pin.bodyB)]))
            if pin.compliance == 0 { hard = max(hard, miss) } else { soft = max(soft, miss) }
        }
        return (hard, soft)
    }

    func testTheFleshIsHeldToItsBones() {
        // (Its muscles off: a contracting muscle moves its flesh off where the bones alone would put it.)
        let s = scene(ragdolls: 1, muscles: 0)
        let w = s.physics!
        let hard = w.pins.filter { $0.compliance == 0 }.count
        print("the muscles scene: \(w.particles.count) particles (\(w.pins.count) pinned, \(hard) hard), \(w.tets.count) tets in "
              + "\(w.tetStarts.count - 1) colours, \(w.muscles.count) muscles over \(w.fibres.count) tets, \(w.softVertices.count) drawn vertices")
        print("  volumes at rest: " + w.softBodies.indices.map { String(format: "%.4f", w.softVolume($0)) }.joined(separator: ", ") + " m^3")
        XCTAssertGreaterThan(hard, 0)
        for _ in 0..<30 { w.step() }
        // The core sits where its bones put it: exactly on the character's (kinematic), and on a ragdoll's where they
        // were before its joints and contacts moved them this substep.
        var kinematic: Float = 0, ragdoll: Float = 0, heldCharacter: Float = 0, heldRagdoll: Float = 0
        for pin in w.pins {
            let miss = length(PhysicsMath.xyz(w.particles[Int(pin.particle)].position)
                              - PhysicsWorld.pinTarget(pin, w.bodies[Int(pin.bodyA)], w.bodies[Int(pin.bodyB)]))
            let character = PhysicsWorld.kinematic(w.bodies[Int(pin.bodyA)])
            switch (pin.compliance > 0, character) {
            case (false, true): kinematic = max(kinematic, miss)
            case (false, false): ragdoll = max(ragdoll, miss)
            case (true, true): heldCharacter = max(heldCharacter, miss)
            case (true, false): heldRagdoll = max(heldRagdoll, miss)
            }
        }
        print(String(format: "after 0.5 s: the core %.2g m from its targets (the character's), %.2g m (a ragdoll's); held ones %.3f m (the character's), %.3f m (a ragdoll landing)",
                     kinematic, ragdoll, heldCharacter, heldRagdoll))
        XCTAssertLessThan(kinematic, 1e-5)
        XCTAssertLessThan(ragdoll, 2e-3)
        XCTAssertLessThan(heldCharacter, 0.03, "the rest is held near it")
        XCTAssertLessThan(heldRagdoll, 0.06, "...as the ragdoll lands too")
    }

    // MARK: Muscles

    /// One tet of a lattice whose fibre (along x) is fully active: it shortens by its share and keeps its volume.
    func testAnActiveFibreShortensAndKeepsItsVolume() {
        let w = PhysicsWorld(substeps: 16)
        w.gravity = .zero
        let points: [SIMD3<Float>] = [[0, 0, 0], [0.1, 0, 0], [0, 0.1, 0], [0, 0, 0.1]]
        let tet = SIMD4<UInt32>(0, 1, 2, 3)
        for p in points {
            w.particles.append(GPUPhysicsParticle(position: SIMD4(p, 0.01), velocity: SIMD4(.zero, 0.5), prevPosition: SIMD4(p, 1000),
                                                  info: SIMD4(PhysicsWorld.none, PhysicsWorld.softBit, 0, 0)))
        }
        let dm = simd_float3x3(columns: (points[1] - points[0], points[2] - points[0], points[3] - points[0]))
        w.unsortedTets.append(GPUPhysicsTet(ids: tet, rest: SoftModel.sixVolume(points, tet), compliance: 0, damping: 0, fibre: 1))
        w.fibres.append(GPUFleshFibre(g: SIMD4(dm.inverse * SIMD3(1, 0, 0), 0.3), muscle: 0, compliance: 0))
        // A muscle always full: two bodies whose axes are the angle it is full at apart.
        let ball = SDFShape(.sphere(radius: 0.05))
        let a = w.addKinematicBody(sdf: 0, ball, transform: translate([1, 0, 0]), instance: 0)
        let b = w.addKinematicBody(sdf: 0, ball, transform: translate([2, 0, 0]), instance: 1)
        w.muscles.append(GPUMuscle(axisA: [1, 0, 0, 0], axisB: [1, 0, 0, 0], range: [-1, 0, 1, 0], bodyA: UInt32(a), bodyB: UInt32(b)))
        w.activations.append(0)
        w.finish()
        for _ in 0..<60 { w.step() }
        let x = w.particles.map { PhysicsMath.xyz($0.position) }
        let v = (x[1] - x[0]) * w.fibres[0].g.x + (x[2] - x[0]) * w.fibres[0].g.y + (x[3] - x[0]) * w.fibres[0].g.z
        let volume = SoftModel.sixVolume(x, tet) / SoftModel.sixVolume(points, tet)
        print(String(format: "an active fibre: %.3f of its length (0.7 asked), its tet %.4f of its volume", length(v), volume))
        XCTAssertEqual(w.activations[0], 1)
        XCTAssertEqual(length(v), 0.7, accuracy: 0.01)
        XCTAssertEqual(volume, 1, accuracy: 0.02)   // (both hard, one pass a substep: they share the error)
    }

    // MARK: GPU

    private static let shaders = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MetalRenderer/Shaders.metal")
    private static var compiled: (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines)?

    private func metal() throws -> (device: MTLDevice, queue: MTLCommandQueue, pipelines: Pipelines) {
        if let compiled = MuscleTests.compiled { return compiled }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("no Metal device") }
        let pipelines = try Pipelines(device: device, source: MuscleTests.shaders, lightTypes: 0x3F, stats: false)
        MuscleTests.compiled = (device, queue, pipelines)
        return (device, queue, pipelines)
    }

    /// The muscles scene, its world stepped by the CPU, and the GPU's copy: `run(steps, reset)` encodes steps.
    private func gpuScene(ragdolls: Int = 1, skin: PhysicsSettings.Skin = .embedded, muscles: Float = 1, body: PhysicsSettings.Body = .skin) throws
        -> (scene: Scene, gpu: PhysicsGPU, run: (Int, Bool) -> Void, encode: ((ComputePass) -> Void) -> Void) {
        _ = try rig()
        let m = try metal()
        let scene = scene(ragdolls: ragdolls, skin: skin, muscles: muscles, body: body)
        let sdf = try SDFBuffers(device: m.device, scene: scene)
        let gpu = try PhysicsGPU(device: m.device, world: scene.physics!, sdfScene: sdf.scene, sdfResources: sdf.buffers, slots: 1)
        let encode = { (body: (ComputePass) -> Void) in
            let cmd = m.queue.makeCommandBuffer()!
            let enc = cmd.makeComputeCommandEncoder(dispatchType: .serial)!
            body(Metal3Pass(enc: enc))
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            XCTAssertNil(cmd.error)
        }
        let run = { (steps: Int, reset: Bool) in
            encode {
                if reset { gpu.encodeReset($0, pipelines: m.pipelines) }
                gpu.encodeSteps($0, pipelines: m.pipelines, steps: steps)
            }
        }
        return (scene, gpu, run, encode)
    }

    /// The GPU's clock (steps run) and its muscles' activations, from its flesh buffer.
    private func flesh(_ gpu: PhysicsGPU, _ w: PhysicsWorld) -> (clock: Int, activations: [Float]) {
        let words = gpu.readFlesh()
        let at = Int(words[2].z)
        let floats = words.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return (Int(words[1].z), (0..<w.muscles.count).map { floats[at * 4 + $0] })
    }

    func testGPUFleshMatchesTheCPU() throws {
        let (scene, gpu, run, _) = try gpuScene()
        let w = scene.physics!
        run(10, false)
        for _ in 0..<10 { w.step() }
        let bodies = zip(gpu.readBodies(), w.bodies).map { length(PhysicsMath.xyz($0.position - $1.position)) }.max()!
        let particles = zip(gpu.readParticles(), w.particles).map { length(PhysicsMath.xyz($0.position - $1.position)) }.max()!
        print(String(format: "GPU against CPU, flesh after 10 steps: bodies within %.2g m, particles within %.2g m", bodies, particles))
        XCTAssertLessThan(bodies, 1e-4)
        XCTAssertLessThan(particles, 2e-3)
        XCTAssertEqual(flesh(gpu, w).clock, 10)
    }

    func testGPUFleshRunsAreTheSameAndReplay() throws {
        let (_, gpu, run, _) = try gpuScene()
        run(90, false)
        let first = gpu.readParticles().map(\.position), bodies = gpu.readBodies().map(\.position)
        // Again from the start (a replay), on the same GPU copy: the kinematic bodies' clock goes back with it.
        run(90, true)
        XCTAssertEqual(first, gpu.readParticles().map(\.position))
        XCTAssertEqual(bodies, gpu.readBodies().map(\.position))
        let (_, again, rerun, _) = try gpuScene()
        rerun(90, false)
        XCTAssertEqual(first, again.readParticles().map(\.position))
    }

    func testGPUMusclesBulgeAsTheElbowBends() throws {
        // The character's left biceps at the step its elbow is bent most (from the table), with its muscles and
        // without (the same pose: bending folds the arm onto the belly either way; the muscle is the difference).
        func bent(muscles: Float) throws -> (out: Float, volume: Float, rest: Float, activation: Float, step: Int, tets: Int) {
            let (scene, gpu, run, _) = try gpuScene(ragdolls: 0, muscles: muscles)
            let w = scene.physics!
            let biceps = try XCTUnwrap(w.muscles.firstIndex { m in m.range.y > m.range.x && m.bodyA == 9 })
            let m = w.muscles[biceps], columns = w.kinematicTable.count / (2 * w.kinematicRows)
            // How bent the elbow is at a row of the table: the muscle's activation at full strength.
            func bend(_ row: Int) -> Float {
                var full = m, a = GPUPhysicsBody(), b = GPUPhysicsBody()
                full.range.z = 1
                a.rotation = w.kinematicTable[(row * columns + Int(m.bodyA)) * 2 + 1]
                b.rotation = w.kinematicTable[(row * columns + Int(m.bodyB)) * 2 + 1]
                return PhysicsWorld.activation(full, a, b)
            }
            let step = (60..<w.kinematicRows).max { bend($0) < bend($1) }!
            let tets = w.tets.filter { $0.fibre != 0 && Int(w.fibres[Int($0.fibre) - 1].muscle) == biceps }
            run(step, false)
            let particles = gpu.readParticles(), b = gpu.readBodies()[Int(m.bodyA)]
            let axis = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(m.axisA))
            var out: Float = 0, volume: Float = 0
            for t in tets {
                let x = [t.ids.x, t.ids.y, t.ids.z, t.ids.w].map { PhysicsMath.xyz(particles[Int($0)].position) }
                let c = x.reduce(.zero, +) / 4 - PhysicsMath.xyz(b.position)
                out += length(c - axis * dot(c, axis))
                volume += SoftModel.sixVolume(x, SIMD4(0, 1, 2, 3)) / 6
            }
            return (out / Float(tets.count), volume, tets.reduce(0) { $0 + $1.rest } / 6, flesh(gpu, w).activations[biceps], step, tets.count)
        }
        let active = try bent(muscles: 1), passive = try bent(muscles: 0)
        print(String(format: "the biceps (%d tets, %.1f cm^3 at rest) bent (step %d): active %.2f, its belly %.1f mm out, %.1f cm^3; relaxed %.1f mm out, %.1f cm^3",
                     active.tets, active.rest * 1e6, active.step, active.activation, active.out * 1000, active.volume * 1e6, passive.out * 1000,
                     passive.volume * 1e6))
        XCTAssertGreaterThan(active.tets, 10)
        XCTAssertGreaterThan(active.activation, 0.5)
        XCTAssertGreaterThan(active.out - passive.out, 0.0015, "it bulges")
        // (Fully active it swells by up to a tenth: one pass of its fibres' and its tets' volumes a substep doesn't
        // settle them. Relaxed, its volume is its rest volume's to 2%.)
        XCTAssertEqual(active.volume / active.rest, 1, accuracy: 0.1, "and keeps its volume")
        XCTAssertEqual(passive.volume / passive.rest, 1, accuracy: 0.02)
    }

    /// The GPU's drawn vertices after `steps` steps (its soft mesh kernel), against the CPU's from the GPU's particles
    /// and bodies: the worst miss, and the CPU's.
    private func drawn(_ steps: Int, body: PhysicsSettings.Body, ragdolls: Int = 1, muscles: Float = 1) throws
        -> (worst: Float, cpu: [SIMD3<Float>], scene: Scene, gpu: PhysicsGPU) {
        let (scene, gpu, run, encode) = try gpuScene(ragdolls: ragdolls, muscles: muscles, body: body)
        let m = try metal(), w = scene.physics!
        run(steps, false)
        let particles = gpu.readParticles(), bodies = gpu.readBodies()
        let positions = m.device.makeBuffer(length: (scene.positions.count + 16) * 16, options: .storageModeShared)!
        let normals = m.device.makeBuffer(length: (scene.positions.count + 16) * 16, options: .storageModeShared)!
        encode { gpu.encodeSoftMesh($0, pipelines: m.pipelines, slot: 0, positions: positions, normals: normals) }
        let p = positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: scene.positions.count)
        var worst: Float = 0, cpu: [SIMD3<Float>] = []
        for v in w.softVertices.indices {
            cpu.append(w.drawnSoftVertex(v, particles: particles, bodies: bodies))
            worst = max(worst, length(p[Int(w.softVertices[v].info.x)] - cpu[v]))
        }
        return (worst, cpu, scene, gpu)
    }

    func testGPUDrawsTheFleshTheCPUDoes() throws {
        let worst = try drawn(30, body: .skin).worst
        print(String(format: "GPU's drawn flesh within %.2g m of the CPU's", worst))
        XCTAssertLessThan(worst, 1e-5)
    }

    // MARK: The écorché

    func testTheMuscleAtlasCoversTheCharacter() throws {
        let rig = try rig()
        let started = Date()
        let atlas = MuscleAtlas(rig)
        let seconds = Date().timeIntervalSince(started)
        let muscles = atlas.ranges.reduce(0) { $0 + $1.count }
        print(String(format: "the écorché: %d muscles, %d of its %d vertices theirs, %d triangles, in %.2f s", atlas.shapes.count, muscles,
                     atlas.mesh.positions.count, atlas.mesh.indices.count / 3, seconds))
        XCTAssertEqual(atlas.shapes.count, 2 * MuscleAtlas.muscles(side: 1).count)
        XCTAssertEqual(Set(MuscleAtlas.muscles(side: 1).map(\.name)).count, MuscleAtlas.muscles(side: 1).count, "named once a side")
        XCTAssertLessThan(atlas.mesh.positions.count, 200_000)
        // Every muscle is there, under the skin by its fat (to a surface nets cell's error), and mirrors its other
        // side's (the Y Bot is symmetric to a few millimetres).
        var deepest: Float = -1, worstMirror: Float = 0, shallow = 0
        for (k, range) in atlas.ranges.enumerated() {
            XCTAssertGreaterThan(range.count, 100, atlas.shapes[k].muscle.name)
            let depths = atlas.mesh.positions[range].map { atlas.body.distance($0) }
            shallow += depths.filter { $0 > -MuscleAtlas.fat + 0.0015 }.count
            deepest = max(deepest, depths.max() ?? -1)
            guard atlas.shapes[k].muscle.side > 0 else { continue }
            let other = atlas.ranges[k - atlas.ranges.count / 2]
            func centre(_ r: Range<Int>) -> SIMD3<Float> { atlas.mesh.positions[r].reduce(.zero, +) / Float(r.count) }
            worstMirror = max(worstMirror, length(centre(range) * SIMD3(-1, 1, 1) - centre(other)))
        }
        print(String(format: "  under the skin by %.1f mm at least (%d vertices less than %.1f mm); sides mirror within %.1f mm", -deepest * 1000,
                     shallow, (MuscleAtlas.fat - 0.0015) * 1000, worstMirror * 1000))
        XCTAssertLessThan(deepest, 0, "none out of it")
        XCTAssertLessThan(Float(shallow), 1e-3 * Float(muscles), "all but a few by its fat")
        XCTAssertLessThan(worstMirror, 0.01)
        // Carved from the bones: none in one (but a few, to a surface nets cell's error).
        let inBone = atlas.ranges.flatMap { atlas.mesh.positions[$0] }.filter { atlas.skeleton.distance($0) < -0.001 }.count
        print("  \(inBone) of its muscles' vertices more than 1 mm in a bone")
        XCTAssertLessThan(Float(inBone), 1e-3 * Float(muscles))
        // Its muscles' and fascia's surfaces hardly branch: an edge is two triangles' (surface nets gives four where two
        // sheets of a surface pass through one cell, rarely).
        var edges: [SIMD2<UInt32>: Int] = [:]
        for (t, material) in atlas.materials.enumerated() where material < 2 {
            for k in 0..<3 {
                let a = atlas.mesh.indices[3 * t + k], b = atlas.mesh.indices[3 * t + (k + 1) % 3]
                edges[SIMD2(min(a, b), max(a, b)), default: 0] += 1
            }
        }
        let branching = edges.values.filter { $0 > 2 }.count
        print("  \(branching) of its \(edges.count) edges branch")
        XCTAssertLessThan(Float(branching), 5e-3 * Float(edges.count))
    }

    func testTheSkeletonFitsTheCharacter() throws {
        let rig = try rig()
        let atlas = MuscleAtlas(rig)
        let skeleton = atlas.skeleton
        let drawn = atlas.pieces.reduce(0) { $0 + $1.count }
        print("the skeleton: \(skeleton.pieces.count) bones, \(skeleton.meshes.reduce(0) { $0 + $1.positions.count }) vertices, \(drawn) drawn")
        // The skull, the jaw and the teeth, 24 vertebrae and the sacrum, 12 ribs a side and the sternum; 12 bones a side
        // from the clavicle to the foot.
        XCTAssertEqual(skeleton.pieces.count, 3 + 24 + 1 + 24 + 1 + 2 * 12)
        XCTAssertEqual(Set(skeleton.pieces.map { "\($0.name) \($0.side)" }).count, skeleton.pieces.count, "named once a side")
        // Every bone is whole and under the skin, its sides mirror each other (a middle one is on the middle), and
        // the drawn mesh's bone vertices ride their bones.
        var outermost: Float = -1, worstMirror: Float = 0
        func centre(_ i: Int) -> SIMD3<Float> { skeleton.meshes[i].positions.reduce(.zero, +) / Float(skeleton.meshes[i].positions.count) }
        for (i, piece) in skeleton.pieces.enumerated() {
            XCTAssertGreaterThan(skeleton.meshes[i].positions.count, 50, piece.name)
            outermost = max(outermost, skeleton.meshes[i].positions.map { atlas.body.distance($0) }.max() ?? -1)
            XCTAssert(atlas.pieces[i].allSatisfy { atlas.bones[$0] == piece.rides }, piece.name)
            if piece.side == 0 {
                worstMirror = max(worstMirror, abs(centre(i).x))
            } else if piece.side > 0, let other = skeleton.pieces.firstIndex(where: { $0.name == piece.name && $0.side < 0 }) {
                worstMirror = max(worstMirror, length(centre(i) * SIMD3(-1, 1, 1) - centre(other)))
            }
        }
        print(String(format: "  under the skin by %.1f mm at least; sides mirror within %.1f mm", -outermost * 1000, worstMirror * 1000))
        XCTAssertLessThan(outermost, 0, "none out of it")
        XCTAssertLessThan(worstMirror, 0.005)
        // What is bare in life shows: the drawn mesh keeps it.
        for name in ["skull", "mandible", "teeth", "sternum", "clavicle", "patella", "tibia", "ulna", "hand", "foot", "T6"] {
            for (i, piece) in skeleton.pieces.enumerated() where piece.name == name {
                XCTAssertGreaterThan(atlas.pieces[i].count, 50, "\(name) shows")
            }
        }
    }

    func testGPUDrawsTheEcorcheTheCPUDoes() throws {
        let worst = try drawn(30, body: .muscles, ragdolls: 0).worst
        print(String(format: "GPU's drawn écorché within %.2g m of the CPU's", worst))
        XCTAssertLessThan(worst, 1e-5)
    }

    func testTheEcorchesBicepsBulgesAsTheElbowBends() throws {
        // The écorché's left biceps (its vertices, in the drawn mesh's order: the character's flesh is the only one)
        // at the step its elbow is bent most, with the muscles and without: how far out from the upper arm's axis.
        let rig = try rig()
        let atlas = MuscleAtlas(rig)
        let biceps = try XCTUnwrap(atlas.shapes.indices.first { atlas.shapes[$0].muscle.name == "biceps" && atlas.shapes[$0].muscle.side > 0 })
        let arm = try XCTUnwrap(rig.bones.firstIndex { $0.role == .upperArm(1) })
        // The most bent step: the flesh test's (the biceps' activation from the table).
        let w = scene(ragdolls: 0).physics!
        let m = try XCTUnwrap(w.muscles.first { m in m.range.y > m.range.x && Int(m.bodyA) == arm })
        func bent(_ muscles: Float, step: Int) throws -> Float {
            let (_, cpu, scene, gpu) = try drawn(step, body: .muscles, ragdolls: 0, muscles: muscles)
            XCTAssertEqual(scene.physics!.softVertices.count, atlas.mesh.positions.count)
            let b = gpu.readBodies()[arm], axis = PhysicsMath.qrot(b.rotation, PhysicsMath.xyz(m.axisA))
            let out = atlas.ranges[biceps].map { v -> Float in
                let c = cpu[v] - PhysicsMath.xyz(b.position)
                return length(c - axis * dot(c, axis))
            }
            return out.reduce(0, +) / Float(out.count)
        }
        let columns = w.kinematicTable.count / (2 * w.kinematicRows)
        func bend(_ row: Int) -> Float {
            var full = m, a = GPUPhysicsBody(), b = GPUPhysicsBody()
            full.range.z = 1
            a.rotation = w.kinematicTable[(row * columns + Int(m.bodyA)) * 2 + 1]
            b.rotation = w.kinematicTable[(row * columns + Int(m.bodyB)) * 2 + 1]
            return PhysicsWorld.activation(full, a, b)
        }
        let step = (60..<w.kinematicRows).max { bend($0) < bend($1) }!
        let active = try bent(1, step: step), passive = try bent(0, step: step)
        print(String(format: "the écorché's biceps (%d vertices) bent (step %d): %.1f mm out from the arm's axis active, %.1f mm relaxed",
                     atlas.ranges[biceps].count, step, active * 1000, passive * 1000))
        XCTAssertGreaterThan(active - passive, 0.001, "it bulges")
    }

    func testGPUSkinSlidesButStaysOnTheFlesh() throws {
        let (scene, gpu, run, _) = try gpuScene(ragdolls: 0, skin: .sliding)
        let w = scene.physics!
        XCTAssertFalse(w.skinAttachments.isEmpty)
        run(240, false)
        let particles = gpu.readParticles()
        var gap: Float = 0, slide: Float = 0
        for a in w.skinAttachments {
            func at(_ bary: SIMD4<Float>) -> SIMD3<Float> {
                let x0 = PhysicsMath.xyz(particles[Int(a.ids.x)].position)
                return x0 + (PhysicsMath.xyz(particles[Int(a.ids.y)].position) - x0) * bary.x
                    + (PhysicsMath.xyz(particles[Int(a.ids.z)].position) - x0) * bary.y + (PhysicsMath.xyz(particles[Int(a.ids.w)].position) - x0) * bary.z
            }
            let target = at(a.bary), n = normalize(target - at(a.deep)), d = PhysicsMath.xyz(particles[Int(a.particle)].position) - target
            gap = max(gap, abs(dot(d, n)))
            slide = max(slide, length(d - n * dot(d, n)))
        }
        print(String(format: "the sliding skin after 4 s: %d particles, off the flesh by %.1f mm at most, slid %.1f mm at most", w.skinAttachments.count, gap * 1000, slide * 1000))
        XCTAssertLessThan(gap, 0.003)
        XCTAssertLessThan(slide, 0.0201)
    }
}
