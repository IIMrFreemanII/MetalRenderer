import EngineCore
import Foundation
import simd

/// A material slot of an object: what its faces with that index look like (PBR values, as the engine's materials;
/// `graph` names a Material Designer material to use instead, when the scene has it).
package struct MaterialSlot: Codable, Equatable {
    package var name: String
    package var baseColor: SIMD4<Float> = [0.8, 0.8, 0.8, 1]
    package var metallic: Float = 0
    package var roughness: Float = 0.5
    package var emission: SIMD3<Float> = .zero
    package var graph: String?

    package init(name: String, baseColor: SIMD4<Float> = [0.8, 0.8, 0.8, 1], metallic: Float = 0, roughness: Float = 0.5,
                 emission: SIMD3<Float> = .zero, graph: String? = nil) {
        self.name = name
        self.baseColor = baseColor
        self.metallic = metallic
        self.roughness = roughness
        self.emission = emission
        self.graph = graph
    }
}

/// Location, rotation (Euler XYZ, radians) and scale, as the N-panel shows them.
package struct ObjectTransform: Codable, Equatable {
    package var location: SIMD3<Float> = .zero
    package var rotation: SIMD3<Float> = .zero
    package var scale: SIMD3<Float> = .one

    package init(location: SIMD3<Float> = .zero, rotation: SIMD3<Float> = .zero, scale: SIMD3<Float> = .one) {
        self.location = location
        self.rotation = rotation
        self.scale = scale
    }

    package var rotationMatrix: float3x3 {
        let (sx, cx) = (sin(rotation.x), cos(rotation.x))
        let (sy, cy) = (sin(rotation.y), cos(rotation.y))
        let (sz, cz) = (sin(rotation.z), cos(rotation.z))
        let rx = float3x3(rows: [[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
        let ry = float3x3(rows: [[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
        let rz = float3x3(rows: [[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
        return rz * ry * rx
    }

    package var matrix: float4x4 {
        let r = rotationMatrix
        let c0 = r.columns.0 * scale.x, c1 = r.columns.1 * scale.y, c2 = r.columns.2 * scale.z
        return float4x4(columns: (SIMD4(c0, 0), SIMD4(c1, 0), SIMD4(c2, 0), SIMD4(location, 1)))
    }

    /// The Euler angles of a rotation matrix (XYZ order, as `rotationMatrix` builds: Rz · Ry · Rx).
    package static func euler(_ r: float3x3) -> SIMD3<Float> {
        // Row i, column j is r.columns.j[i].
        let r20 = r.columns.0.z
        let y = asin(max(-1, min(1, -r20)))
        if abs(r20) < 0.9999 {
            return SIMD3(atan2(r.columns.1.z, r.columns.2.z), y, atan2(r.columns.0.y, r.columns.0.x))
        }
        return SIMD3(atan2(-r.columns.2.y, r.columns.1.y), y, 0)
    }
}

/// One object of a model: a mesh in edit space, where it is, its modifier stack and materials.
package struct ModelObject: Identifiable {
    package var id = UUID()
    package var name: String
    package var transform = ObjectTransform()
    package var mesh: EditMesh
    package var modifiers: [Modifier] = []
    package var materials: [MaterialSlot] = [MaterialSlot(name: "Material")]
    /// Multires levels and their displacements (nil: none).
    package var multires: MultiresData?
    /// Sculpt mode's mask by vertex, kept between visits (empty: none).
    package var sculptMasks: [Float] = []
    /// Shown in the viewport (the outliner's eye).
    package var visible = true
    /// Part of the model when it is saved and rendered (a boolean's cutter isn't).
    package var renders = true
    /// The procedural network that makes the mesh (its JSON, the Procedural module's `ProcGraph`; nil: none). The mesh
    /// is the network's cooked output; the Modeller's Procedural workspace edits the network.
    package var network: String?

    package init(name: String, mesh: EditMesh) {
        self.name = name
        self.mesh = mesh
    }
}

/// What the modelling window edits: a model, as objects. Saving it writes a model asset (ModelAsset); a scene places
/// the asset, which is all its rendered objects' evaluated meshes.
package struct ModelingDocument {
    package var name = "Model"
    package var objects: [ModelObject] = []
    package var active: Int?
    /// The asset it was opened from or saved as (its slug), nil while new.
    package var asset: String?
    /// Selected objects (object mode); the active one is `active`.
    package var selection: Set<UUID> = []
    /// The 3D cursor: where Add puts things, a pivot.
    package var cursor = SIMD3<Float>.zero

    package init() {}

    package init(name: String, objects: [ModelObject]) {
        self.name = name
        self.objects = objects
        active = objects.isEmpty ? nil : 0
        if let a = active { selection = [objects[a].id] }
    }

    /// A new document with Blender's start-up cube.
    package static func startup() -> ModelingDocument {
        ModelingDocument(name: "Model", objects: [ModelObject(name: "Cube", mesh: Primitive.cube.mesh())])
    }

    /// Adds an object, selected and active alone (as Add does).
    package mutating func add(_ object: ModelObject) {
        var o = object
        o.name = uniqueName(o.name)
        objects.append(o)
        active = objects.count - 1
        selection = [o.id]
    }

    package var activeObject: ModelObject? { active.flatMap { $0 < objects.count ? objects[$0] : nil } }


    package func uniqueName(_ name: String) -> String {
        let names = Set(objects.map(\.name))
        guard names.contains(name) else { return name }
        var base = name
        if let dot = name.lastIndex(of: "."), Int(name[name.index(after: dot)...]) != nil { base = String(name[..<dot]) }
        var i = 1
        while names.contains(String(format: "%@.%03d", base, i)) { i += 1 }
        return String(format: "%@.%03d", base, i)
    }

    package func index(of id: UUID) -> Int? { objects.firstIndex { $0.id == id } }
}

/// The modes of the header's menu (Tab: object and edit; Ctrl-Tab: the pie).
package enum EditorMode: String, CaseIterable, Codable {
    case object, edit, sculpt
    package var title: String {
        switch self {
        case .object: "Object Mode"
        case .edit: "Edit Mode"
        case .sculpt: "Sculpt Mode"
        }
    }
}
