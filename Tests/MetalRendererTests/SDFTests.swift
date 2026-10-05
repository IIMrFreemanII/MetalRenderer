import XCTest
import Metal
import simd
@testable import MetalRenderer

/// SDF shapes (SDFShapes.swift, SDFVolume.swift, SDFBuffers.swift): the distances the shaders march (Shaders/SDF.metal
/// computes the same), the boxes the tracers clip them to, the triangles an emissive shape is sampled by as a light,
/// baked grids, and a scene with shapes on the GPU.
final class SDFTests: XCTestCase {
    private typealias Node = SDFShape.Node

    private func d(_ primitive: SDFShape.Primitive, _ p: SIMD3<Float>) -> Float {
        SDFShape(primitive).distance(p).d
    }

    func testPrimitiveDistances() {
        XCTAssertEqual(d(.sphere(radius: 0.5), [1, 0, 0]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(d(.sphere(radius: 0.5), .zero), -0.5, accuracy: 1e-6)
        XCTAssertEqual(d(.box(halfExtents: [1, 1, 1]), [2, 0, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(d(.box(halfExtents: [1, 1, 1]), .zero), -1, accuracy: 1e-6)
        XCTAssertEqual(d(.box(halfExtents: [1, 1, 1]), [2, 2, 1]), sqrt(2), accuracy: 1e-5, "past an edge: to the edge")
        XCTAssertEqual(d(.box(halfExtents: [1, 1, 1], rounding: 0.25), [2, 2, 2]), length(SIMD3<Float>(repeating: 1.25)) - 0.25, accuracy: 1e-5)
        XCTAssertEqual(d(.torus(major: 1, minor: 0.25), [1, 0, 0]), -0.25, accuracy: 1e-6)
        XCTAssertEqual(d(.torus(major: 1, minor: 0.25), [0, 1, 0]), sqrt(2) - 0.25, accuracy: 1e-5)
        XCTAssertEqual(d(.capsule(halfLength: 1, radius: 0.5), [0, 2, 0]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(d(.capsule(halfLength: 1, radius: 0.5), [1, 0.5, 0]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(d(.cylinder(halfHeight: 1, radius: 0.5), [1, 0, 0]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(d(.cylinder(halfHeight: 1, radius: 0.5), [0, 3, 0]), 2, accuracy: 1e-6)
        XCTAssertEqual(d(.cone(halfHeight: 1, bottom: 1, top: 0), [0, -2, 0]), 1, accuracy: 1e-5, "below its base")
        XCTAssertEqual(d(.cone(halfHeight: 1, bottom: 1, top: 1), [2, 0, 0]), 1, accuracy: 1e-5, "a cone with equal radii is a cylinder")
        XCTAssertLessThan(d(.cone(halfHeight: 1, bottom: 1, top: 0), [0, 0, 0]), 0)
    }

    /// A node's rotation, translation and scale: its distances stay distances.
    func testNodePlacement() {
        let node = Node(.box(halfExtents: [1, 0.5, 0.5]), at: [1, 2, 3], rotation: simd_quatf(angle: .pi / 2, axis: [0, 0, 1]), scale: 2)
        let shape = SDFShape([node])
        // Turned a quarter about z, the box's long side is along y; scaled by 2 it reaches 2 from its centre.
        XCTAssertEqual(shape.distance([1, 2 + 3, 3]).d, 1, accuracy: 1e-5)
        XCTAssertEqual(shape.distance([1 + 3, 2, 3]).d, 2, accuracy: 1e-5)
        // The GPU's rows are the same map into the primitive's space.
        let gpu = shape.gpuNodes[0]
        for p: SIMD3<Float> in [[0, 0, 0], [1, 2, 3], [-3, 0.5, 7]] {
            let v = SIMD4(p, 1)
            let q = SIMD3(dot(gpu.row0, v), dot(gpu.row1, v), dot(gpu.row2, v))
            XCTAssertLessThan(simd_distance(q, node.local(p)), 1e-5)
        }
        XCTAssertEqual(gpu.kind, SDFShape.boxKind)
        XCTAssertEqual(gpu.params, [1, 0.5, 0.5, 0])
        XCTAssertEqual(gpu.scale, 2)
    }

    func testJoinsAndTheirMaterials() {
        let sphere = Node(.sphere(radius: 1)), other = Node(.sphere(radius: 1), at: [1.5, 0, 0], material: 1)
        func shape(_ op: SDFShape.Op, smooth: Float = 0) -> SDFShape {
            var b = other
            b.op = op
            b.smooth = smooth
            return SDFShape([sphere, b])
        }
        // Union: the nearer one, and its material.
        XCTAssertEqual(shape(.union).distance([-2, 0, 0]).d, 1, accuracy: 1e-6)
        XCTAssertEqual(shape(.union).distance([-2, 0, 0]).material, 0)
        XCTAssertEqual(shape(.union).distance([3, 0, 0]).material, 1)
        // A cut: the cut face is the cutter's.
        let cut = shape(.subtract)
        XCTAssertGreaterThan(cut.distance([0.75, 0, 0]).d, 0, "inside the cutter: gone")
        XCTAssertLessThan(cut.distance([-0.5, 0, 0]).d, 0)
        XCTAssertEqual(cut.distance([0.5, 0, 0]).material, 1)
        XCTAssertEqual(cut.distance([-1, 0, 0]).material, 0)
        // An intersection: only where both are.
        XCTAssertLessThan(shape(.intersect).distance([0.75, 0, 0]).d, 0)
        XCTAssertGreaterThan(shape(.intersect).distance([-0.5, 0, 0]).d, 0)
        // A blend never lowers the union by more than k/4, and does where the two meet.
        let k: Float = 0.4
        for x in stride(from: Float(-2), through: 3, by: 0.25) {
            let p = SIMD3<Float>(x, 0.9, 0)
            let sharp = shape(.union).distance(p).d, smooth = shape(.union, smooth: k).distance(p).d
            XCTAssertLessThanOrEqual(smooth, sharp + 1e-6)
            XCTAssertGreaterThanOrEqual(smooth, sharp - k / 4 - 1e-6)
        }
        XCTAssertLessThan(shape(.union, smooth: k).distance([0.75, 1.0, 0]).d, shape(.union).distance([0.75, 1.0, 0]).d)
        XCTAssertEqual(shape(.union).stepScale, 1)
        XCTAssertLessThan(shape(.union, smooth: k).stepScale, 1)
        XCTAssertEqual(shape(.union).materialCount, 2)
    }

    /// Every point inside a shape is inside its box: the tracers march only there.
    func testBoundsHoldTheShape() {
        let tilt = simd_quatf(angle: 0.7, axis: normalize(SIMD3<Float>(1, 1, 0)))
        let shapes: [SDFShape] = [
            SDFShape([Node(.torus(major: 0.6, minor: 0.2), rotation: tilt)]),
            SDFShape([Node(.sphere(radius: 0.4), at: [-0.3, 0, 0]), Node(.sphere(radius: 0.3), smooth: 0.5, at: [0.4, 0.2, 0])]),
            SDFShape([Node(.box(halfExtents: [0.5, 0.5, 0.5])), Node(.sphere(radius: 0.6), .subtract, at: [0.5, 0.5, 0.5])]),
            SDFShape([Node(.cylinder(halfHeight: 1, radius: 0.3), rotation: tilt), Node(.box(halfExtents: [0.4, 0.4, 0.4]), .intersect)]),
            SDFShape([Node(.cone(halfHeight: 0.5, bottom: 0.4, top: 0.1), at: [0, 0.2, 0], scale: 1.5),
                      Node(.capsule(halfLength: 0.3, radius: 0.1), smooth: 0.2, at: [0.3, 0.8, 0], rotation: tilt)]),
        ]
        for (s, shape) in shapes.enumerated() {
            let box = shape.bounds()
            XCTAssertFalse(box.isEmpty)
            let lo = box.lo - 0.5, size = box.hi - box.lo + 1
            var inside = 0
            for i in 0..<20 {
                for j in 0..<20 {
                    for k in 0..<20 {
                        let p = lo + size * SIMD3(Float(i), Float(j), Float(k)) / 19
                        guard shape.distance(p).d < 0 else { continue }
                        inside += 1
                        XCTAssertTrue(all(p .>= box.lo) && all(p .<= box.hi), "shape \(s): \(p) is inside it but not its box \(box)")
                    }
                }
            }
            XCTAssertGreaterThan(inside, 0, "shape \(s)")
        }
        // An intersection's box is the overlap; a cut's, what is cut.
        let overlap = shapes[3].bounds()
        XCTAssertLessThanOrEqual(overlap.hi.x, 0.41)
        XCTAssertEqual(shapes[2].bounds().hi.x, SDFShape([Node(.box(halfExtents: [0.5, 0.5, 0.5]))]).bounds().hi.x, accuracy: 1e-6)
    }

    /// An emissive shape's light: triangles just outside its surface, about as much of them as it has.
    func testSurfaceTriangles() {
        let shape = SDFShape([Node(.sphere(radius: 1)), Node(.box(halfExtents: [0.3, 0.3, 0.3]), at: [0, 1.1, 0], material: 1)])
        let mesh = shape.triangles(cells: 40, push: 0.15)
        XCTAssertGreaterThan(mesh.indices.count, 3000)
        XCTAssertEqual(mesh.materials.count, mesh.indices.count / 3)
        let cell = simd_reduce_max(shape.bounds().hi - shape.bounds().lo) / 40
        for p in mesh.positions {
            let d = shape.distance(p).d
            XCTAssertGreaterThan(d, 0, "just outside")
            XCTAssertLessThan(d, 0.3 * cell)
        }
        var area: Float = 0, areaNormal = SIMD3<Float>()
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let (a, b, c) = (mesh.positions[Int(mesh.indices[t])], mesh.positions[Int(mesh.indices[t + 1])], mesh.positions[Int(mesh.indices[t + 2])])
            let cr = cross(b - a, c - a)
            area += length(cr) / 2
            areaNormal += cr / 2
            let centre = (a + b + c) / 3
            XCTAssertGreaterThan(dot(cr, shape.gradient(centre)), 0, "facing out")
        }
        XCTAssertLessThan(length(areaNormal) / area, 0.01, "closed")
        XCTAssertGreaterThan(area, 4 * .pi * 0.98)
        XCTAssertTrue(mesh.materials.contains(1) && mesh.materials.contains(0))
    }

    /// A baked mesh's grid against its exact distance: within a cell, the right sign, and outside the grid a bound.
    func testBakedVolumes() {
        let cube = SDFVolume.bake(Scene.cubeMesh(), resolution: 32)
        let sphere = SDFVolume.bake(Scene.icosphere(subdivisions: 4), resolution: 32)
        let exactCube = SDFShape(.box(halfExtents: [0.5, 0.5, 0.5])), exactSphere = SDFShape(.sphere(radius: 1))
        for (volume, exact, name) in [(cube, exactCube, "cube"), (sphere, exactSphere, "sphere")] {
            XCTAssertGreaterThan(volume.border, volume.cell, "\(name): room around it")
            for i in 0..<400 {
                let u = SIMD3<Float>(Float(i % 7), Float((i / 7) % 11), Float((i / 77) % 13)) / SIMD3(6, 10, 12)
                let p = volume.lo + (volume.hi - volume.lo) * u
                XCTAssertEqual(volume.distance(p), exact.distance(p).d, accuracy: volume.cell, "\(name) at \(p)")
            }
            XCTAssertLessThan(volume.distance(.zero), -0.4, name)
            for far: SIMD3<Float> in [[3, 0, 0], [0, -4, 1], [2, 2, 2]] {
                let d = volume.distance(far)
                // (Within half precision, and an icosphere's faces sit a little inside the sphere.)
                XCTAssertLessThanOrEqual(d, exact.distance(far).d + 0.01, "\(name): never past the surface")
                XCTAssertGreaterThan(d, 0.5 * exact.distance(far).d, name)
            }
        }
        // As a node of a shape (in the shape's space through its own placement).
        let placed = SDFShape([Node(.volume(0), at: [2, 0, 0])])
        XCTAssertEqual(placed.distance([2, 0, 0], volumes: [cube]).d, -0.5, accuracy: cube.cell)
        XCTAssertEqual(placed.bounds(volumes: [cube]).lo.x, 2 + cube.lo.x, accuracy: 0.01)
    }

    /// A scene's SDF instances: their records, the feature bit, their bounds, and their glow as mesh lights.
    func testSceneWithShapes() throws {
        var glowing = -1
        let scene = Scene(SceneSettings(kind: .cornell)) { scene in
            let material = scene.addMaterial(albedo: [0.5, 0.5, 0.5])
            _ = scene.addMaterial(albedo: .zero, emission: [4, 2, 1])   // the shape's second material: it glows
            scene.addInstance(scene.addMesh(Scene.quadMesh()), material, matrix_identity_float4x4)
            let shape = scene.addSDFShape(SDFShape([Node(.box(halfExtents: [0.5, 0.5, 0.5])),
                                                    Node(.sphere(radius: 0.3), at: [0, 0.6, 0], material: 1)]))
            glowing = scene.addInstance(sdf: shape, material, translate([3, 1, 0]))
            scene.addInstance(sdf: shape, material, translate([-3, 1, 0])) { t in translate([-3, 1 + t, 0]) }
        }
        XCTAssertTrue(scene.hasSDFShapes)
        XCTAssertEqual(scene.lightTypeMask & 0x0040_0000, 0x0040_0000, "SDF_SHAPES")
        XCTAssertFalse(scene.isStill)
        let (lo, hi) = scene.bounds()
        XCTAssertGreaterThan(hi.x, 3.4)
        XCTAssertLessThan(lo.x, -3.4)

        var records = [GPUInstanceData](repeating: GPUInstanceData(transform: .init(), prevTransform: .init(), normalMatrix: .init(),
                                                                  meshIndex: 0, materialIndex: 0), count: scene.instances.count)
        records.withUnsafeMutableBufferPointer { scene.writeInstanceData(into: $0.baseAddress!, all: true) }
        XCTAssertEqual(records[glowing].meshIndex, UInt32(scene.meshes.count), "past the meshes (none virtual, no assemblies)")
        XCTAssertEqual(records[glowing].pad0, Scene.maskGeometry | Scene.instanceSDF)
        XCTAssertEqual(records[0].pad0, Scene.maskGeometry)

        // Each instance's glowing ball is a mesh light of its own, on the material it glows with.
        let lights = scene.meshLights.filter { scene.instances[$0.instance].sdf >= 0 }
        XCTAssertEqual(lights.count, 2)
        XCTAssertTrue(lights.allSatisfy { $0.materialOffset == 1 && $0.triangleCount > 100 })
        XCTAssertEqual(scene.materials[scene.instances[glowing].material + 1].params.z, 1, "flagged: its glow is sampled as a light")
    }

    /// The shapes on the GPU: both tracers' buffers, and on Metal's a box per shape after the meshes' structures,
    /// which the shapes' instances' descriptors name.
    func testShapesOnTheGPU() throws {
        let scene = Scene(SceneSettings(kind: .cornell)) { scene in
            let material = scene.addMaterial(albedo: [0.5, 0.5, 0.5])
            scene.addInstance(scene.addMesh(Scene.quadMesh()), material, matrix_identity_float4x4)
            let a = scene.addSDFShape(SDFShape(.sphere(radius: 0.5)))
            let b = scene.addSDFShape(SDFShape([Node(.torus(major: 0.5, minor: 0.1)), Node(.sphere(radius: 0.2), smooth: 0.1)]))
            scene.addInstance(sdf: b, material, translate([1, 0, 0]))
            scene.addInstance(sdf: a, material, translate([-1, 0, 0]))
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let custom = try SceneBuffers(device: device, queue: queue, scene: scene, options: SceneBuffers.Options(rayTracer: .custom, api: .metal3, slots: 2))
        XCTAssertEqual(custom.sdf.shapeCount, 2)
        let shapes = UnsafeBufferPointer(start: custom.sdf.shapes.contents().bindMemory(to: GPUSDFShape.self, capacity: 2), count: 2)
        XCTAssertEqual(shapes.map(\.range.x), [0, 1])
        XCTAssertEqual(shapes.map(\.range.y), [1, 2])
        XCTAssertEqual(shapes[0].lo.w, 1, "exact: full steps")
        XCTAssertLessThan(shapes[1].lo.w, 1)
        XCTAssertTrue(custom.buffers.contains { $0 === custom.sdf.nodes })
        XCTAssertTrue(custom.sdf.boxes.isEmpty, "no boxes for the custom tracer")
        let scenes = UnsafeBufferPointer(start: custom.sdf.scene.contents().bindMemory(to: UInt64.self, capacity: 4), count: 4)
        XCTAssertEqual(Array(scenes), [custom.sdf.shapes.gpuAddress, custom.sdf.nodes.gpuAddress, custom.sdf.volumes.gpuAddress,
                                       custom.sdf.cells.gpuAddress])

        guard device.supportsRaytracing else { return }
        let metal = try SceneBuffers(device: device, queue: queue, scene: scene, options: SceneBuffers.Options(rayTracer: .metal, api: .metal3, slots: 2))
        XCTAssertEqual(metal.sdf.boxes.count, 2)
        XCTAssertEqual(metal.primitives.count, scene.meshes.count + 2)
        XCTAssertTrue(metal.primitives[scene.meshes.count] === metal.sdf.boxes[0])
        // Still: the descriptors are written. The shapes' instances name their boxes, and aren't opaque.
        let p = metal.instanceDescriptors[0].contents()
        func word(_ instance: Int, _ offset: Int) -> UInt32 { p.load(fromByteOffset: instance * 64 + offset, as: UInt32.self) }
        XCTAssertEqual(word(0, 60), 0)
        XCTAssertEqual(word(1, 60), UInt32(scene.meshes.count + 1))
        XCTAssertEqual(word(2, 60), UInt32(scene.meshes.count))
        XCTAssertEqual(word(1, 48) & MTLAccelerationStructureInstanceOptions.nonOpaque.rawValue, MTLAccelerationStructureInstanceOptions.nonOpaque.rawValue)
        XCTAssertEqual(word(0, 48) & MTLAccelerationStructureInstanceOptions.opaque.rawValue, MTLAccelerationStructureInstanceOptions.opaque.rawValue)
    }
}
