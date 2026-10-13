import Foundation
import QuartzCore
import simd

/// The scene's outline (SceneOutline): what the builders named (`Scene.object`), then the rest by system and by what it
/// is an instance of.
extension Scene {
    /// Groups of more than this many instances of one thing are one node (an aggregate).
    static let outlineGroupLimit = 24

    func makeOutline() -> SceneOutline {
        let start = CACurrentMediaTime()
        var b = OutlineBuilder(self)
        b.build()
        var outline = SceneOutline(kind: settings.kind.envName, title: settings.kind.title, scope: MaterialAssignments.scope(settings),
                                   nodes: b.nodes, links: b.links, instanceCount: instances.count,
                                   lightCount: lights.filter { !$0.isMesh }.count)
        outline.nodes[0].assets = subjectAssets()
        outline.buildMs = (CACurrentMediaTime() - start) * 1000
        return outline
    }

    /// What a workshop shows: the asset its editor edits.
    private func subjectAssets() -> [AssetKey] {
        switch settings.kind {
        case .plants: return [AssetKey(kind: .species, name: settings.plants.species)]
        case .buildings: return [AssetKey(kind: .buildingStyle, name: settings.buildings.style)]
        case .characters: return [AssetKey(kind: .character, name: settings.characterWorkshop.character)]
        case .materials: return [AssetKey(kind: .materialGraph, name: settings.materialWorkshop.graph)]
        case .painter: return [AssetKey(kind: .painterDoc, name: settings.painterWorkshop.document)]
        default: return []
        }
    }

    /// What instance `i` is as its builder made it: its geometry and its size. An edit made of it (SceneOverrides) holds
    /// while this does.
    func outlineFingerprint(_ i: Int) -> String {
        guard instances.indices.contains(i) else { return "" }
        let inst = instances[i]
        var h = Hasher64()
        h.add(UInt64(bitPattern: Int64(inst.mesh)))
        h.add(UInt64(bitPattern: Int64(inst.virtualMesh)))
        h.add(UInt64(bitPattern: Int64(inst.assembly)))
        h.add(UInt64(bitPattern: Int64(inst.sdf)))
        if inst.mesh >= 0 && inst.mesh < meshes.count { h.add(UInt64(meshes[inst.mesh].indexCount)) }
        let (lo, hi) = localBounds(of: inst)
        h.add(SIMD4(lo, 0))
        h.add(SIMD4(hi, 0))
        return String(h.value, radix: 36)
    }

    /// Instance `i`'s bounds in the world, as it is now.
    func worldBounds(of i: Int) -> AABB {
        guard instances.indices.contains(i) else { return AABB() }
        let (lo, hi) = localBounds(of: instances[i])
        return AABB(lo: lo, hi: hi).transformed(sceneOverrides.hiddenTransforms[i] ?? instances[i].transform)
    }
}

/// Makes a scene's outline: where each instance, light and effect goes (the innermost object it was added in, or its
/// system), then the nodes, their bounds and counts, and the links between them.
private struct OutlineBuilder {
    let scene: Scene
    var nodes: [SceneOutline.Node] = []
    var links: [SceneOutline.Link] = []
    private var index: [String: Int] = [:]

    /// A node its things are gathered in before its children are made: an object of the builder's or a system.
    private struct Container {
        var node: Int
        var tag: Scene.ObjectTag?
        var instances: [Int] = []
        var lights: [Int] = []          // by Light.order
        var effects: [Int] = []
        var childTags = 0
    }
    private var containers: [Container] = []
    private var systems: [String: Int] = [:]          // name -> container
    /// Per instance: its node, and its place among the node's members.
    private var nodeOf: [Int32]
    private var memberOf: [Int32]

    init(_ scene: Scene) {
        self.scene = scene
        nodeOf = [Int32](repeating: -1, count: scene.instances.count)
        memberOf = [Int32](repeating: 0, count: scene.instances.count)
    }

    mutating func build() {
        add(SceneOutline.Node(id: "scene", parent: -1, kind: .scene, name: scene.settings.kind.title))
        let tags = makeTagContainers()
        // (The lights the graph hid are out of the scene's: the outline keeps them, hidden.)
        let lightByOrder = Dictionary((scene.lights + scene.sceneOverrides.hiddenLights).filter { !$0.isMesh }.map { ($0.order, $0) },
                                      uniquingKeysWith: { a, _ in a })
        let copies = scene.sceneOverrides.duplicates
        let copiedInstances = Set(copies.flatMap(\.instances)), copiedLights = Set(copies.flatMap(\.lights))

        // The innermost tag of each thing: outer tags first, inner ones over them.
        var instanceOwner = [Int](repeating: -1, count: scene.instances.count)
        var lightOwner: [Int: Int] = [:], effectOwner = [Int](repeating: -1, count: scene.effects.count)
        for c in tags.sorted(by: { containers[$0].tag!.instances.count > containers[$1].tag!.instances.count }) {
            for i in containers[c].tag!.instances where i < instanceOwner.count { instanceOwner[i] = c }
        }
        for c in tags.sorted(by: { containers[$0].tag!.lights.count > containers[$1].tag!.lights.count }) {
            for l in containers[c].tag!.lights { lightOwner[l] = c }
        }
        for c in tags.sorted(by: { containers[$0].tag!.effects.count > containers[$1].tag!.effects.count }) {
            for e in containers[c].tag!.effects where e < effectOwner.count { effectOwner[e] = c }
        }

        // A light's shape is the light's: not an instance of its own.
        var proxies = Set<Int>()
        for l in lightByOrder.values where l.proxyInstance >= 0 { proxies.insert(l.proxyInstance) }
        let particleSlots = particleSlotOwners()
        let bodies = Set(scene.physics?.bodies.map { Int($0.info.z) } ?? [])
        let walkers = Set(scene.crowd?.walkers.map(\.instance) ?? [])

        for i in scene.instances.indices where !proxies.contains(i) && !copiedInstances.contains(i) {
            if instanceOwner[i] >= 0 { containers[instanceOwner[i]].instances.append(i); continue }
            let inst = scene.instances[i]
            let system: String
            if particleSlots[i] != nil { system = "Particles" }
            else if bodies.contains(i) { system = "Physics" }
            else if walkers.contains(i) || (scene.crowd != nil && inst.deforms) { system = "Characters" }
            else if inst.deforms || inst.simulated { system = "Soft bodies and cloth" }
            else if inst.assembly >= 0 { system = scene.assemblies[inst.assembly].rigid ? "Buildings" : "Plants" }
            else if inst.sdf >= 0 { system = "SDF shapes" }
            else if inst.mask & Scene.maskLiquid != 0 { system = "Fluids" }
            else if inst.mask & Scene.maskGlass != 0 { system = "Glass" }
            else if inst.virtualMesh >= 0 { system = "Models" }
            else if inst.mesh >= 0 && (scene.meshes[inst.mesh].sways != 0 || scene.meshes[inst.mesh].cutout != 0
                                       || scene.meshLabels[inst.mesh]?.asset?.kind == .species) { system = "Plants" }
            else { system = "Meshes" }
            containers[self.system(system)].instances.append(i)
        }
        for order in lightByOrder.keys.sorted() where !copiedLights.contains(order) {
            containers[lightOwner[order] ?? system("Lights")].lights.append(order)
        }
        for e in scene.effects.indices { containers[effectOwner[e] >= 0 ? effectOwner[e] : system("Effects")].effects.append(e) }

        for c in containers.indices { fill(c, lightByOrder: lightByOrder, particleSlots: particleSlots) }
        if !scene.groups.isEmpty {
            let tiles = system("Open world tiles")
            for g in scene.groups {
                add(SceneOutline.Node(id: "\(nodes[containers[tiles].node].id)|\(g.name)", parent: containers[tiles].node, kind: .tiles,
                                      name: g.name, count: g.count, locked: "Streams in with the open world"))
            }
        }
        addCopies(lightByOrder: lightByOrder)
        for n in nodes.indices where scene.sceneOverrides.hidden.contains(nodes[n].id) { nodes[n].hidden = true }
        sumUp()
        makeLinks(particleSlots: particleSlots)
    }

    /// The graph's duplicates, each beside what it copies.
    private mutating func addCopies(lightByOrder: [Int: Scene.Light]) {
        for copy in scene.sceneOverrides.duplicates {
            let source = copy.edit.source.id
            let at = index[source] ?? SceneOutline.member(of: source).flatMap { index[$0.aggregate] }
            let parent = at.map { nodes[$0].parent >= 0 ? nodes[$0].parent : 0 } ?? 0
            let n = add(SceneOutline.Node(id: copy.edit.id, parent: parent, kind: .object, name: copy.edit.name,
                                          assets: at.map { nodes[$0].assets } ?? [], copyOf: source))
            if copy.instances.count == 1 && copy.lights.isEmpty {
                setMembers(n, copy.instances)
                nodes[n].fingerprint = scene.outlineFingerprint(copy.instances[0])
                nodes[n].info = info(copy.instances[0])
            } else if copy.instances.isEmpty && copy.lights.count == 1, let l = lightByOrder[copy.lights[0]] {
                makeLight(l, node: n)
            } else {
                // A copy of many things: one node of them all.
                nodes[n].kind = .aggregate
                setMembers(n, copy.instances)
                nodes[n].count += copy.lights.count
            }
            nodes[n].info["Copy of"] = at.map { nodes[$0].name } ?? source
        }
    }

    // MARK: - Containers

    @discardableResult
    private mutating func add(_ node: SceneOutline.Node) -> Int {
        nodes.append(node)
        index[node.id] = nodes.count - 1
        return nodes.count - 1
    }

    /// The builder's objects as nodes, in the order they were begun; two of one name are "Name", "Name (2)".
    private mutating func makeTagContainers() -> [Int] {
        let tags = scene.objectTags.sorted {
            ($0.instances.lowerBound, $0.lights.lowerBound, $0.effects.lowerBound, $0.path.count)
                < ($1.instances.lowerBound, $1.lights.lowerBound, $1.effects.lowerBound, $1.path.count)
        }
        var made: [Int] = []
        var taken = Set<String>()
        for tag in tags {
            var path = tag.path
            guard !path.isEmpty else { continue }
            var n = 1
            while taken.contains(path.joined(separator: "/")) {
                n += 1
                path[path.count - 1] = "\(tag.path.last!) (\(n))"
            }
            taken.insert(path.joined(separator: "/"))
            let parent = folder(Array(path.dropLast()))
            let node = add(SceneOutline.Node(id: "t:" + path.joined(separator: "/"), parent: parent, kind: .folder, name: path.last!,
                                             assets: tag.assets))
            containers.append(Container(node: node, tag: tag))
            made.append(containers.count - 1)
        }
        var children: [Int: Int] = [:]
        for n in nodes where n.parent >= 0 { children[n.parent, default: 0] += 1 }
        for c in containers.indices where containers[c].tag != nil { containers[c].childTags = children[containers[c].node] ?? 0 }
        return made
    }

    /// The folder node of `path` (the scene for none), made with its parents if new.
    private mutating func folder(_ path: [String]) -> Int {
        guard !path.isEmpty else { return 0 }
        let id = "t:" + path.joined(separator: "/")
        if let i = index[id] { return i }
        let parent = folder(Array(path.dropLast()))
        return add(SceneOutline.Node(id: id, parent: parent, kind: .folder, name: path.last!))
    }

    private mutating func system(_ name: String) -> Int {
        if let c = systems[name] { return c }
        let node = add(SceneOutline.Node(id: "s:" + name, parent: 0, kind: .system, name: name))
        containers.append(Container(node: node, tag: nil))
        systems[name] = containers.count - 1
        return containers.count - 1
    }

    // MARK: - Things

    /// What instance `i` is an instance of, and what it is made with.
    private func describe(_ i: Int) -> (label: String, assets: [AssetKey]) {
        let inst = scene.instances[i]
        var assets: [AssetKey] = []
        let label: String
        if inst.assembly >= 0 {
            let rigid = scene.assemblies[inst.assembly].rigid
            if let name = scene.assemblyLabels[inst.assembly] {
                label = name
                assets.append(AssetKey(kind: rigid ? .building : .species, name: name, local: rigid))
            } else {
                label = rigid ? "building \(inst.assembly)" : "plant \(inst.assembly)"
                assets.append(AssetKey(kind: rigid ? .building : .species, name: label, local: true))
            }
        } else if inst.virtualMesh >= 0 {
            label = scene.virtualMeshNames[inst.virtualMesh]
            assets.append(AssetKey(kind: .mesh, name: label))
        } else if inst.sdf >= 0 {
            label = scene.sdfLabels[inst.sdf] ?? "SDF shape \(inst.sdf)"
            assets.append(AssetKey(kind: .sdfShape, name: label, local: true))
        } else if let l = scene.meshLabels[inst.mesh] {
            label = l.name
            assets.append(AssetKey(kind: .mesh, name: l.name, local: !l.shared))
            if let a = l.asset { assets.append(a) }
        } else if let name = scene.meshNames[inst.mesh] {
            // (A name the renderer's caches know it by: "city <lot> <fingerprint>". Not an asset of the project's.)
            label = name
            assets.append(AssetKey(kind: .mesh, name: name, local: true))
        } else {
            label = "mesh \(inst.mesh)"
            assets.append(AssetKey(kind: .mesh, name: label, local: true))
        }
        if let p = scene.procedural.first(where: { $0.material == inst.material }) {
            assets.append(AssetKey(kind: .materialGraph, name: p.graph))
        } else {
            assets.append(AssetKey(kind: .material, name: "material \(inst.material)", local: true))
        }
        if let painted = scene.painted.first(where: { $0.instance == i }) {
            assets.append(AssetKey(kind: .painterDoc, name: painted.document))
        }
        return (label, assets)
    }

    private func info(_ i: Int) -> [String: String] {
        let inst = scene.instances[i]
        var out = ["Instance": "\(i)", "Material": "\(inst.material)"]
        if inst.mesh >= 0 && inst.mesh < scene.meshes.count { out["Triangles"] = "\(scene.meshes[inst.mesh].indexCount / 3)" }
        if inst.animation != nil { out["Moves"] = "animated" }
        if inst.simulated { out["Moves"] = "physics" }
        if inst.travels { out["Moves"] = "walks" }
        if inst.mask & Scene.maskGlass != 0 { out["Glass"] = "yes" }
        if scene.meshLights.contains(where: { $0.instance == i }) { out["Emits light"] = "yes" }
        let p = inst.transform.columns.3
        out["Position"] = String(format: "%.2f, %.2f, %.2f", p.x, p.y, p.z)
        return out
    }

    private func locked(_ i: Int, particleSlot: Bool) -> String? {
        let inst = scene.instances[i]
        if particleSlot { return "A particle: its effect places it" }
        if inst.simulated { return "Moved by the physics" }
        if inst.deforms { return "Deforms every frame" }
        if inst.travels { return "Walks a lane" }
        return nil
    }

    /// Container `c`'s children: its instances by what they are, its lights, its effects.
    private mutating func fill(_ c: Int, lightByOrder: [Int: Scene.Light], particleSlots: [Int: Int]) {
        let container = containers[c]
        let parent = container.node, cid = nodes[parent].id
        // A named object of one instance (or one light) is that instance.
        if container.tag != nil && container.childTags == 0 {
            if container.instances.count == 1 && container.lights.isEmpty && container.effects.isEmpty {
                let i = container.instances[0]
                let d = describe(i)
                nodes[parent].kind = .object
                setMembers(parent, [i])
                nodes[parent].assets = Array(Set(nodes[parent].assets + d.assets)).sorted()
                nodes[parent].fingerprint = scene.outlineFingerprint(i)
                nodes[parent].locked = locked(i, particleSlot: particleSlots[i] != nil)
                nodes[parent].info = info(i)
                nodes[parent].info["Mesh"] = d.label
                return
            }
            if container.instances.isEmpty && container.lights.count == 1 && container.effects.isEmpty, let l = lightByOrder[container.lights[0]] {
                makeLight(l, node: parent)
                return
            }
        }
        if nodes[parent].kind == .folder && container.tag != nil && (container.instances.count + container.lights.count + container.effects.count) > 0 {
            nodes[parent].kind = .object
        }
        var order: [String] = [], groups: [String: (assets: [AssetKey], members: [Int])] = [:]
        for i in container.instances {
            let d = describe(i)
            if groups[d.label] == nil { order.append(d.label); groups[d.label] = (d.assets, []) }
            groups[d.label]!.members.append(i)
        }
        for label in order {
            let g = groups[label]!
            let id = "\(cid)|\(label)"
            if g.members.count == 1 {
                let i = g.members[0]
                let n = add(SceneOutline.Node(id: id, parent: parent, kind: .object, name: label, assets: g.assets,
                                              fingerprint: scene.outlineFingerprint(i), locked: locked(i, particleSlot: particleSlots[i] != nil),
                                              info: info(i)))
                setMembers(n, [i])
            } else if g.members.count <= Scene.outlineGroupLimit {
                let group = add(SceneOutline.Node(id: id, parent: parent, kind: .group, name: label, assets: g.assets))
                for (k, i) in g.members.enumerated() {
                    let n = add(SceneOutline.Node(id: "\(id)#\(k)", parent: group, kind: .object, name: "\(label) #\(k)",
                                                  assets: g.assets, fingerprint: scene.outlineFingerprint(i),
                                                  locked: locked(i, particleSlot: particleSlots[i] != nil), info: info(i)))
                    setMembers(n, [i])
                }
            } else {
                let i = g.members[0]
                var detail = info(i)
                detail["Instance"] = nil
                detail["Position"] = nil
                let n = add(SceneOutline.Node(id: id, parent: parent, kind: .aggregate, name: label, assets: g.assets,
                                              fingerprint: scene.outlineFingerprint(i), locked: locked(i, particleSlot: particleSlots[i] != nil),
                                              info: detail))
                setMembers(n, g.members)
            }
        }
        for (k, order) in container.lights.enumerated() {
            guard let l = lightByOrder[order] else { continue }
            let n = add(SceneOutline.Node(id: "\(cid)|light \(k)", parent: parent, kind: .light, name: ""))
            makeLight(l, node: n)
        }
        var names: [String: Int] = [:]
        for e in container.effects {
            let name = scene.effects[e].effect.name
            names[name, default: 0] += 1
            let n = names[name]!
            add(SceneOutline.Node(id: "\(cid)|fx:\(name)" + (n > 1 ? " (\(n))" : ""), parent: parent, kind: .effect,
                                  name: n > 1 ? "\(name) (\(n))" : name, effect: e, assets: [AssetKey(kind: .vfxGraph, name: name)],
                                  bounds: Box(lo: scene.effects[e].place.offset - 0.5, hi: scene.effects[e].place.offset + 0.5),
                                  info: ["Emitters": "\(scene.effects[e].effect.emitters.count)"]))
        }
    }

    private mutating func setMembers(_ n: Int, _ members: [Int]) {
        nodes[n].members = IndexRuns(members)
        var box = AABB()
        for (k, i) in members.enumerated() {
            nodeOf[i] = Int32(n)
            memberOf[i] = Int32(k)
            box.grow(scene.worldBounds(of: i))
        }
        nodes[n].bounds = Box(box)
        nodes[n].count = members.count
    }

    private mutating func makeLight(_ light: Scene.Light, node n: Int) {
        let kind: String
        var radius: Float = 0.1
        switch light.kind {
        case .sphere(let r): kind = "Sphere light"; radius = r
        case .spot(let r, _, _): kind = "Spot light"; radius = r
        case .sun: kind = "Sun"
        case .rect(let w, let h): kind = "Rect light"; radius = max(w, h) / 2
        case .tube(let length, let r): kind = "Tube light"; radius = max(length / 2, r)
        case .mesh: kind = "Mesh light"
        }
        nodes[n].kind = .light
        if nodes[n].name.isEmpty { nodes[n].name = kind }
        nodes[n].light = light.order
        nodes[n].count = 1
        let p = light.current.position
        if !light.kind.isSun { nodes[n].bounds = Box(lo: p - radius, hi: p + radius) }
        var h = Hasher64()
        h.add("\(light.kind)")
        nodes[n].fingerprint = String(h.value, radix: 36)
        let c = light.color
        nodes[n].info = ["Kind": kind, "Colour": String(format: "%.2f, %.2f, %.2f", c.x, c.y, c.z),
                         "Moves": light.motion == .animated ? "animated" : light.motion == .scaleOnly ? "flickers" : "no"]
        if !light.kind.isSun { nodes[n].info["Position"] = String(format: "%.2f, %.2f, %.2f", p.x, p.y, p.z) }
        if light.proxyInstance >= 0 {
            nodeOf[light.proxyInstance] = Int32(n)
            nodes[n].members = IndexRuns([light.proxyInstance])
        }
    }

    // MARK: - Totals and links

    /// Counts and bounds up the tree: a folder's are its children's.
    private mutating func sumUp() {
        for n in nodes.indices.reversed() where n > 0 {
            let p = nodes[n].parent
            guard p >= 0 else { continue }
            if nodes[p].kind == .scene || nodes[p].kind == .folder || nodes[p].kind == .system || nodes[p].kind == .group
                || (nodes[p].kind == .object && nodes[p].members.isEmpty) {
                nodes[p].count += nodes[n].count
                if let b = nodes[n].bounds { nodes[p].bounds = nodes[p].bounds.map { $0.union(b) } ?? b }
            }
        }
    }

    /// Instance `i`'s id: its node's, or its member's of an aggregate.
    private func id(ofInstance i: Int) -> String? {
        guard nodeOf.indices.contains(i), nodeOf[i] >= 0 else { return nil }
        let n = Int(nodeOf[i])
        return nodes[n].kind == .aggregate ? SceneOutline.memberID(nodes[n].id, Int(memberOf[i])) : nodes[n].id
    }

    /// Each particle slot's emitter.
    private func particleSlotOwners() -> [Int: Int] {
        guard let p = scene.particles else { return [:] }
        var out: [Int: Int] = [:]
        for (e, first) in p.meshInstances.enumerated() {
            guard let first else { continue }
            for i in first..<(first + p.emitters[e].capacity) { out[i] = e }
        }
        return out
    }

    private mutating func makeLinks(particleSlots: [Int: Int]) {
        var made = Set<SceneOutline.Link>()
        func link(_ a: String?, _ b: String?, _ kind: SceneOutline.Link.Kind) {
            guard let a, let b, a != b else { return }
            made.insert(SceneOutline.Link(from: a, to: b, kind: kind))
        }
        // Jointed bodies (ragdolls, chains).
        if let physics = scene.physics {
            for j in physics.joints {
                let a = Int(j.info.x), b = Int(j.info.y)
                guard physics.bodies.indices.contains(a), physics.bodies.indices.contains(b) else { continue }
                link(id(ofInstance: Int(physics.bodies[a].info.z)), id(ofInstance: Int(physics.bodies[b].info.z)), .joint)
            }
            // A body hangs from another (info.w = that body + 1).
            for body in physics.bodies where body.info.w > 0 && Int(body.info.w) - 1 < physics.bodies.count {
                link(id(ofInstance: Int(body.info.z)), id(ofInstance: Int(physics.bodies[Int(body.info.w) - 1].info.z)), .attached)
            }
        }
        // An effect's particles: their node to the effect's.
        if !particleSlots.isEmpty {
            let effectNodes = Dictionary(nodes.indices.filter { nodes[$0].kind == .effect }.map { (nodes[$0].assets.first?.name ?? "", nodes[$0].id) },
                                         uniquingKeysWith: { a, _ in a })
            var seen = Set<Int>()
            for (i, e) in particleSlots where !seen.contains(e) {
                seen.insert(e)
                let owner = scene.effectOwners.indices.contains(e) ? scene.effectOwners[e] : ""
                guard nodeOf[i] >= 0 else { continue }
                link(nodes[Int(nodeOf[i])].id, effectNodes[owner], .owner)
            }
        }
        links = made.sorted { ($0.from, $0.to, $0.kind.rawValue) < ($1.from, $1.to, $1.kind.rawValue) }
    }
}
