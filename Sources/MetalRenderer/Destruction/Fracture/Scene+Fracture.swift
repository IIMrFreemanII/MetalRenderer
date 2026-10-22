import Characters
import Effects
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// Fractured objects in a scene (Physics+Fracture.swift): every node of an object's fracture tree an SDF shape, an
/// instance and a body. A piece is its object's shape cut by its cell (the object's nodes, then the cell's cut planes
/// intersected, whose faces take the interior material); a convex object's (a box's) pieces are their cells exactly,
/// with mass properties from the polytope; any other object's are built from their fields, side by side.
extension Scene {
    /// Where a fractured object is held: nowhere (it falls, rolls, is knocked over), by the ground under it (its
    /// lowest pieces don't move until they come free), or round its edge (a pane in its frame: the pieces along its
    /// rim), and the object itself until it breaks.
    package enum FractureAnchor {
        case none
        case ground(Float)
        case rim
    }

    /// How deep the ground holds an object standing on it (m): the pieces reaching this low are anchored (a wall's
    /// foundation; with only the pieces touching it, the wall above a hole near its foot slid off as one slab).
    package static let foundation: Float = 0.25

    /// What one fractured object became: its root's body and instance, its tree.
    package struct Fractured {
        package var tree: FractureTree
        package var firstBody: Int
        var firstInstance: Int
        package var name: String
    }

    /// Object `shape` (shape space) placed by `transform` (a rotation and a translation), fractured by `recipe`, drawn
    /// with `material` outside and `interior` (a later material) on its broken faces. `mask`: its instances' (glass's).
    @discardableResult
    package func addFractured(_ name: String, shape: SDFShape, recipe: FractureRecipe, transform: float4x4, material: Int, interior: Int,
                      anchor: FractureAnchor, mask: UInt32 = Scene.maskGeometry, toughness: Float = 1, strength: Float = 1,
                      fadeRadius: Float = 0.1) -> Fractured {
        precondition(interior >= material, "the interior material comes after the outside's")
        let world = physicsWorld()
        world.setVolumes(sdfVolumes)
        // A box at the shape's origin is its own cell; anything else is cut inside its box.
        var convex = false
        var cell = ConvexCell(box: shape.bounds(volumes: sdfVolumes).lo, shape.bounds(volumes: sdfVolumes).hi)
        if shape.nodes.count == 1, case .box(let half, let rounding) = shape.nodes[0].primitive, rounding == 0,
           shape.nodes[0].position == .zero, abs(shape.nodes[0].rotation.real) > 0.99999 {
            convex = true
            cell = ConvexCell(box: -half, half)
        }
        let volumes = sdfVolumes
        let tree = FractureTree(recipe: recipe, cell: cell, inside: convex ? nil : { shape.distance($0, volumes: volumes).d })
        // Each node's shape: the object's, then its cell's cuts (outer faces are the object's own).
        let offset = interior - material
        if offset > 0 { markCutFace(interior) }
        var shapes: [SDFShape] = []
        for (k, node) in tree.nodes.enumerated() {
            guard k > 0 else { shapes.append(shape); continue }
            let cuts = node.cell.planes { $0 != ConvexCell.outer }
            let box = node.cell.bounds
            var nodes = shape.nodes
            nodes.append(SDFShape.Node(.cell(planes: cuts, lo: box.lo, hi: box.hi), .intersect, material: offset))
            shapes.append(SDFShape(nodes))
        }
        let sdfs = shapes.map { addSDFShape($0) }
        for (k, s) in sdfs.enumerated() { label(sdf: s, k == 0 ? name : "\(name) piece") }
        // Their physics shapes, side by side.
        var builds = [PhysicsWorld.ShapeBuild?](repeating: nil, count: shapes.count)
        builds.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: shapes.count) { k in
                if k == 0 && convex { return }   // (a box: the world's own analytic one)
                out[k] = convex ? PhysicsWorld.pieceShape(tree.nodes[k].cell, sdf: sdfs[k])
                                : PhysicsWorld.buildShape(shapes[k], index: sdfs[k], volumes: volumes)
            }
        }
        let firstInstance = instances.count, firstBody = world.bodies.count
        let hidden = transform * scale(PhysicsWorld.hiddenScale)
        let m = recipe.material
        for k in tree.nodes.indices {
            let i = addInstance(sdf: sdfs[k], material, k == 0 ? transform : hidden, mask: mask)
            editInstance(i) { $0.simulated = true }
            if let b = builds[k] {
                world.addPiece(sdf: sdfs[k], shapes[k], build: b, transform: transform, instance: i, material: m)
            } else {
                world.addBody(sdf: sdfs[k], shapes[k], transform: transform, instance: i, density: m.density, friction: m.friction,
                              restitution: m.restitution)
            }
        }
        world.addFracture(tree, first: firstBody, transform: transform, anchored: Scene.anchored(tree, cell: cell, transform: transform, anchor),
                          toughness: toughness, strength: strength, fadeRadius: fadeRadius)
        return Fractured(tree: tree, firstBody: firstBody, firstInstance: firstInstance, name: name)
    }

    /// Which of `tree`'s nodes the ground (or the frame) holds, the object (`cell`, its box) placed by `transform`.
    package static func anchored(_ tree: FractureTree, cell: ConvexCell, transform: float4x4, _ anchor: FractureAnchor) -> [Bool] {
        tree.nodes.map { node -> Bool in
            switch anchor {
            case .none: return false
            case .ground(let y):
                let lowest = node.cell.vertices.map { (transform * SIMD4($0, 1)).y }.min() ?? .infinity
                return lowest < y + Scene.foundation
            case .rim:
                // A face of the object's own box whose normal lies across the pane (not its front or back).
                let e = cell.bounds.hi - cell.bounds.lo
                let thin = e.x <= e.y && e.x <= e.z ? 0 : e.y <= e.z ? 1 : 2
                return node.cell.faces.contains { $0.tag == ConvexCell.outer && abs($0.plane[thin]) < 0.5 }
            }
        }
    }

    /// A fractured model (a .glb: a statue, a bench): its parts merged into one mesh in its own space, `height` tall,
    /// its feet at the origin, then placed by `transform`. Each piece is the mesh cut by its cell (MeshCutter: its
    /// triangles, their textures kept, and caps of `interior` on the cuts), and collides as the mesh's baked distance
    /// grid cut by the cell. Nil if the model can't be read.
    @discardableResult
    package func addFracturedModel(_ name: String, url: URL, height: Float, transform: float4x4, recipe: FractureRecipe,
                           interior: SIMD3<Float>, anchor: FractureAnchor, toughness: Float = 1, strength: Float = 1) -> Fractured? {
        guard let model = try? GLTFLoader.load(url), !model.parts.isEmpty else {
            print("Destruction: can't load \(url.lastPathComponent)")
            return nil
        }
        let world = physicsWorld()
        // Its materials, a grey for parts without one, then the inside's.
        let firstMaterial = addModelMaterials(model, url: url)
        let fallback = addMaterial(albedo: [0.7, 0.7, 0.7]) - firstMaterial
        let insideMaterial = addPBRMaterial(baseColor: interior, metallic: 0, roughness: 0.9)
        markCutFace(insideMaterial)
        let inside = insideMaterial - firstMaterial
        precondition(inside < 256, "\(name): more materials than a triangle's offset holds")
        // Its parts in one mesh, in model space.
        var merged = MeshCutter.Mesh()
        for part in model.parts {
            let m = model.meshes[part.mesh], normalMatrix = part.transform.inverse.transpose
            let base = UInt32(merged.positions.count)
            for (k, p) in m.positions.enumerated() {
                let q = part.transform * SIMD4(p, 1), n = normalMatrix * SIMD4(m.normals.indices.contains(k) ? m.normals[k] : [0, 1, 0], 0)
                _ = merged.add(SIMD3(q.x, q.y, q.z), PhysicsMath.direction(SIMD3(n.x, n.y, n.z)), m.uvs.indices.contains(k) ? m.uvs[k] : .zero)
            }
            merged.indices += m.indices.map { $0 + base }
            merged.materials += [UInt8](repeating: UInt8(m.material ?? fallback), count: m.indices.count / 3)
        }
        // `height` tall, its feet at the origin.
        let b = merged.bounds
        let s = height / max(b.hi.y - b.lo.y, 1e-4), foot = SIMD3((b.lo.x + b.hi.x) / 2, b.lo.y, (b.lo.z + b.hi.z) / 2)
        merged.positions = merged.positions.map { ($0 - foot) * s }
        let volume = SDFVolume.cached((merged.positions, merged.normals, merged.indices), resolution: 72)
        let v = addSDFVolume(volume)
        world.setVolumes(sdfVolumes)
        let box = merged.bounds
        let pad = simd_reduce_max(box.hi - box.lo) * 0.01
        let cell = ConvexCell(box: box.lo - pad, box.hi + pad)
        let tree = FractureTree(recipe: recipe, cell: cell, inside: { volume.distance($0) })
        // Each node's mesh and collider, side by side.
        let cutter = MeshCutter(merged, inside: { volume.distance($0) })
        let colliders = tree.nodes.enumerated().map { k, node -> SDFShape in
            guard k > 0 else { return SDFShape(.volume(v)) }
            let b = node.cell.bounds
            return SDFShape([SDFShape.Node(.volume(v)),
                             SDFShape.Node(.cell(planes: node.cell.planes { $0 != ConvexCell.outer }, lo: b.lo, hi: b.hi), .intersect)])
        }
        let sdfs = colliders.map { addSDFShape($0) }
        var pieces = [MeshCutter.Mesh](repeating: MeshCutter.Mesh(), count: tree.nodes.count)
        var builds = [PhysicsWorld.ShapeBuild?](repeating: nil, count: tree.nodes.count)
        let volumes = sdfVolumes
        pieces.withUnsafeMutableBufferPointer { out in
            builds.withUnsafeMutableBufferPointer { built in
                DispatchQueue.concurrentPerform(iterations: tree.nodes.count) { k in
                    out[k] = k == 0 ? merged : cutter.piece(tree.nodes[k].cell, capped: { $0 != ConvexCell.outer }, interior: UInt8(inside),
                                                            uvScale: 2, cellSize: volume.cell * 0.5)
                    built[k] = PhysicsWorld.buildShape(colliders[k], index: sdfs[k], volumes: volumes)
                }
            }
        }
        beginObject(name)
        defer { endObject() }
        let firstInstance = instances.count, firstBody = world.bodies.count
        let hidden = transform * scale(PhysicsWorld.hiddenScale)
        let m = recipe.material
        for k in tree.nodes.indices {
            var piece = pieces[k]
            if piece.indices.isEmpty {   // (nothing of the mesh in it: a speck to keep its structure valid)
                let c = tree.nodes[k].cell.centroid
                for _ in 0..<3 { _ = piece.add(c, [0, 1, 0], .zero) }
                piece.indices = [0, 1, 2]
                piece.materials = [UInt8(inside)]
            }
            let mesh = addMesh((piece.positions, piece.normals, piece.indices), uvs: piece.uvs, materials: piece.materials,
                               label: k == 0 ? name : "\(name) piece")
            let i = addInstance(mesh, firstMaterial, k == 0 ? transform : hidden)
            editInstance(i) { $0.simulated = true }
            world.addPiece(sdf: sdfs[k], colliders[k], build: builds[k]!, transform: transform, instance: i, material: m)
        }
        world.addFracture(tree, first: firstBody, transform: transform, anchored: Scene.anchored(tree, cell: cell, transform: transform, anchor),
                          toughness: toughness, strength: strength, fadeRadius: 0.06)
        return Fractured(tree: tree, firstBody: firstBody, firstInstance: firstInstance, name: name)
    }
}
