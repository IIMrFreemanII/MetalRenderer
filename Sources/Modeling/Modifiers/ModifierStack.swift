import Foundation
import simd

/// An object's modifier stack evaluated: the mesh each modifier gives the next, the last what the viewport shows and a
/// scene renders. Each stage's result is kept under its input's generation and its modifier's settings, so a change
/// to modifier n evaluates n and the ones after it only (ModifierCache).
package enum ModifierStack {
    package enum Purpose { case viewport, render, editMode }

    /// The modifiers that run for `purpose`.
    package static func active(_ object: ModelObject, for purpose: Purpose) -> [Modifier] {
        object.modifiers.filter { m in
            switch purpose {
            case .viewport: m.showInViewport
            case .render: m.showInRender
            case .editMode: m.showInViewport && m.showInEditMode
            }
        }
    }

    /// The object's evaluated mesh (no cache): the base (its multires level, outside edit mode), then each modifier
    /// in order. `operand` finds a boolean's other object.
    package static func evaluate(_ object: ModelObject, for purpose: Purpose, operand: (UUID) -> ModelObject? = { _ in nil }) -> EditMesh {
        var mesh = base(object, for: purpose)
        for m in active(object, for: purpose) {
            mesh = apply(m, to: mesh, object: object, purpose: purpose, operand: operand)
        }
        return mesh
    }

    /// The mesh the modifiers start from: the multires level shown for the purpose, or the mesh.
    package static func base(_ object: ModelObject, for purpose: Purpose) -> EditMesh {
        guard purpose != .editMode, let r = object.multires, r.levels > 0, Multires.fits(object.mesh, r) else { return object.mesh }
        let level = purpose == .render ? r.renderLevel : r.viewportLevel
        return level > 0 ? Multires.levelMesh(object.mesh, r, level: level) : object.mesh
    }

    /// One modifier on a mesh.
    package static func apply(_ m: Modifier, to mesh: EditMesh, object: ModelObject, purpose: Purpose, operand: (UUID) -> ModelObject?) -> EditMesh {
        run(m, on: mesh, purpose: purpose, object: object, operand: operand)
    }
}

/// The stack's results kept between frames, per object: stage k's mesh under (its input's generation, modifier k's
/// settings). Plain Swift; the meshes are values.
package final class ModifierCache {
    private struct Stage { var input: UInt64; var modifier: Modifier; var output: EditMesh }
    private var stages: [UUID: [Stage]] = [:]
    /// Each object's multires base: (its mesh's generation, the data's revision, the level) → the level's mesh.
    private var bases: [UUID: (generation: UInt64, revision: UInt64, level: Int, mesh: EditMesh)] = [:]

    package init() {}

    package func evaluate(_ object: ModelObject, for purpose: ModifierStack.Purpose, operand: (UUID) -> ModelObject? = { _ in nil }) -> EditMesh {
        let mods = ModifierStack.active(object, for: purpose)
        var mesh = cachedBase(object, for: purpose)
        guard !mods.isEmpty else { return mesh }
        var kept = stages[object.id] ?? []
        for (k, m) in mods.enumerated() {
            // A boolean depends on its operand too: never kept.
            if k < kept.count, kept[k].input == mesh.generation, kept[k].modifier == m, m.kind != .boolean {
                mesh = kept[k].output
                continue
            }
            let input = mesh.generation
            mesh = ModifierStack.apply(m, to: mesh, object: object, purpose: purpose, operand: operand)
            let stage = Stage(input: input, modifier: m, output: mesh)
            if k < kept.count { kept[k] = stage; kept.removeSubrange((k + 1)...) } else { kept.append(stage) }
        }
        if kept.count > mods.count { kept.removeSubrange(mods.count...) }
        stages[object.id] = kept
        return mesh
    }

    private func cachedBase(_ object: ModelObject, for purpose: ModifierStack.Purpose) -> EditMesh {
        guard purpose != .editMode, let r = object.multires, r.levels > 0 else { return object.mesh }
        let level = purpose == .render ? r.renderLevel : r.viewportLevel
        if let b = bases[object.id], b.generation == object.mesh.generation, b.revision == r.revision, b.level == level { return b.mesh }
        let mesh = ModifierStack.base(object, for: purpose)
        bases[object.id] = (object.mesh.generation, r.revision, level, mesh)
        return mesh
    }

    package func forget(_ id: UUID) { stages[id] = nil; bases[id] = nil }
    package func clear() { stages.removeAll(); bases.removeAll() }
}
