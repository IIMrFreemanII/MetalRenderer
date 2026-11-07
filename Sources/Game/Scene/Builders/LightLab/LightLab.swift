import EngineCore
import MetalRenderer
import simd

/// The groups the panel lists the booths under.
enum LabGroup {
    case types, shadows, materials, counts, yard, gi

    var title: String {
        switch self {
        case .types: "Light types"
        case .shadows: "Shadows"
        case .materials: "Materials"
        case .counts: "Counts & motion"
        case .yard: "Yard"
        case .gi: "GI"
        }
    }
}

/// What a booth is scored on.
enum LabCheck: Hashable {
    case direct, gi, specular, denoise
}

struct LabBooth {
    let number: Int
    let name: String
    let group: LabGroup
    let checks: Set<LabCheck>
    let build: (Scene, BoothFrame, LightLabSettings) -> Void
    /// Where the bookmark looks from (its position and lookAt), if not the doorway (hall) or 5 m out (yard).
    var camera: ((BoothFrame) -> SceneBookmark)? = nil
}

/// The light lab: a dark corridor of light-tight booths (numbered, one edge case each) and an open yard under a sun.
enum LightLab {
    /// The booths, in number order. Their contents are the files `LightLab+Types.swift`, `+Shadows`, `+Materials` and
    /// `+CountsYard`.
    ///
    /// Light budget (the content steps keep to it): in the `normal` variant the whole scene stays under 256 lights (a mesh
    /// light counts as one), so there is no light table and the references trace every light. Booths other than 19 and 20
    /// get at most 4 lights each (booth 19's count is the variant's, booth 20's cluster is 200).
    static let booths: [LabBooth] = [
        LabBooth(number: 1, name: "Sphere sizes", group: .types, checks: [.direct, .specular]) { $0.boothSphereSizes($1, $2) },
        LabBooth(number: 2, name: "Near field", group: .types, checks: [.direct, .denoise]) { $0.boothNearField($1, $2) },
        LabBooth(number: 3, name: "Spot cones", group: .types, checks: [.direct]) { $0.boothSpotCones($1, $2) },
        LabBooth(number: 4, name: "Rects", group: .types, checks: [.direct, .specular]) { $0.boothRects($1, $2) },
        LabBooth(number: 5, name: "Tubes", group: .types, checks: [.direct, .specular]) { $0.boothTubes($1, $2) },
        LabBooth(number: 6, name: "Dynamic range", group: .types, checks: [.direct, .denoise]) { $0.boothDynamicRange($1, $2) },
        LabBooth(number: 7, name: "Cascade reach", group: .types, checks: [.direct, .gi]) { $0.boothCascadeReach($1, $2) },
        LabBooth(number: 8, name: "Contact", group: .shadows, checks: [.direct, .denoise]) { $0.boothContact($1, $2) },
        LabBooth(number: 9, name: "Penumbra ramp", group: .shadows, checks: [.direct, .denoise]) { $0.boothPenumbra($1, $2) },
        LabBooth(number: 10, name: "Leaks", group: .shadows, checks: [.direct, .gi]) { $0.boothLeaks($1, $2) },
        LabBooth(number: 11, name: "Tinted glass", group: .shadows, checks: [.direct]) { $0.boothTintedGlass($1, $2) },
        LabBooth(number: 12, name: "Cut-outs", group: .shadows, checks: [.direct, .denoise]) { $0.boothCutouts($1, $2) },
        LabBooth(number: 13, name: "Terminator", group: .shadows, checks: [.direct]) { $0.boothTerminator($1, $2) },
        LabBooth(number: 14, name: "Roughness ramp", group: .materials, checks: [.specular, .denoise]) { $0.boothRoughness($1, $2) },
        LabBooth(number: 15, name: "Sheen and brushed", group: .materials, checks: [.direct, .specular]) { $0.boothSheenBrushed($1, $2) },
        LabBooth(number: 16, name: "Hair and skin", group: .materials, checks: [.direct]) { $0.boothHairSkin($1, $2) },
        LabBooth(number: 17, name: "Albedo extremes", group: .materials, checks: [.direct, .gi]) { $0.boothAlbedoExtremes($1, $2) },
        LabBooth(number: 18, name: "Mirror and glass", group: .materials, checks: [.specular]) { $0.boothMirrorGlass($1, $2) },
        LabBooth(number: 19, name: "Light grid", group: .counts, checks: [.direct, .denoise]) { $0.boothLightGrid($1, $2) },
        LabBooth(number: 20, name: "Cluster", group: .counts, checks: [.direct]) { $0.boothCluster($1, $2) },
        LabBooth(number: 21, name: "Movers", group: .counts, checks: [.denoise]) { $0.boothMovers($1, $2) },
        LabBooth(number: 22, name: "Blinkers", group: .counts, checks: [.denoise]) { $0.boothBlinkers($1, $2) },
        LabBooth(number: 23, name: "Sun shadows", group: .yard, checks: [.direct, .denoise]) { $0.boothSunShadows($1, $2) },
        LabBooth(number: 24, name: "Window room", group: .yard, checks: [.direct, .gi], build: { $0.boothWindowRoom($1, $2) },
                 camera: { b in   // inside, from the window's corner: the sun's patches through the window and the skylight, the cube
                     SceneBookmark(name: "", group: "", position: b.p(-1.6, 1.6, 1.3), lookAt: b.p(0.6, 0.4, 4.2))
                 }),
        LabBooth(number: 25, name: "Suns", group: .yard, checks: [.direct]) { $0.boothSuns($1, $2) },
        LabBooth(number: 26, name: "Bounce room", group: .gi, checks: [.gi]) { $0.boothBounceRoom($1, $2) },
    ]

    /// Whether `number` is a yard zone (23...25) rather than a hall booth.
    static func isYard(_ number: Int) -> Bool { (23...25).contains(number) }

    /// Booth `number`'s place. Hall booths take columns in order (1 south, 2 north, ...; 26 is column 11, south); the yard
    /// zones are 6 x 6 m side by side along z (23, 24, 25) at the yard's middle.
    static func frame(_ number: Int) -> BoothFrame {
        if isYard(number) {
            let x = LabKit.yardLo + LabKit.yardSize / 2
            return BoothFrame(number: number, origin: [x, 0, Float(number - 24) * 6], right: [0, 0, 1], inward: [1, 0, 0], size: [6, 4, 6])
        }
        let slot = number == 26 ? 22 : number - 1
        let south = slot % 2 == 0
        let z: Float = south ? 3.8 : -3.8
        return BoothFrame(number: number, origin: [LabKit.columnX(slot / 2), 0, z], right: [south ? -1 : 1, 0, 0],
                          inward: [0, 0, south ? 1 : -1], size: [4, 3, 4])
    }

    /// The bookmark of `booth`.
    static func bookmark(_ booth: LabBooth) -> SceneBookmark {
        let b = frame(booth.number)
        let name = String(format: "%02d %@", booth.number, booth.name)
        if let camera = booth.camera {   // its place only: the name and group are the catalog's
            let c = camera(b)
            return SceneBookmark(name: name, group: booth.group.title, position: c.position, lookAt: c.lookAt)
        }
        if isYard(booth.number) {
            return SceneBookmark(name: name, group: booth.group.title, position: b.p(0, 1.7, -5), lookAt: b.p(0, 1, b.size.z / 2))
        }
        return SceneBookmark(name: name, group: booth.group.title, position: b.p(0, 1.6, 0.35), lookAt: b.p(0, 1.0, 4))
    }

    /// Every booth's bookmark, usable without a scene.
    static func bookmarks() -> [SceneBookmark] { booths.map(bookmark) }
}

extension Scene {
    /// The light lab: the dark corridor, the yard and its sun, and the booths (or, with `lightLab.only`, one booth alone
    /// in its place). The booths' lights are the content steps'; here a booth is a shell, a kit and a sign.
    func buildLightLab() {
        let lab = settings.lightLab
        let kit = Kit(self)
        let m = LabMaterials(self)
        let hallChecker = LabKit.checkerMesh(width: 4, depth: 4)
        let hallFloor = addMesh(hallChecker.mesh, materials: hallChecker.offsets, label: "checker")
        let yardChecker = LabKit.checkerMesh(width: LabKit.yardSize, depth: LabKit.yardSize)
        let yardFloor = addMesh(yardChecker.mesh, materials: yardChecker.offsets, label: "yard checker")
        let only = lab.only.flatMap { n in LightLab.booths.contains { $0.number == n } ? n : nil }

        // Closed booths, so the walkable interiors' box (Scene.interiorBox) over the hall and the yard's window room (one
        // box: the yard strip between them with it), a little past their walls: the cascades' intervals start inside
        // each booth (RC_INTERIOR_START) instead of past its 0.3 m walls, where they saw the next booth's light.
        let far = LabKit.yardLo + LabKit.yardSize
        interiorBox = (SIMD3<Float>(-LabKit.wall - 0.2, -0.5, -6.6), SIMD3<Float>(far, 3.8, 6.6))
        labCorridor(kit, m)
        object("Yard") {
            addInstance(yardFloor, m.checker, translate([LabKit.yardLo + LabKit.yardSize / 2, 0, 0]))
        }
        object("Sun") {
            let pose = LightPose(position: .zero, direction: LabKit.toSun, scale: [1.0, 0.95, 0.88] * 1.8)
            addLight(.sun(angularRadius: Scene.degrees(0.27)), color: [1, 1, 1], motion: .constant) { _ in pose }
        }

        for booth in LightLab.booths where only == nil || booth.number == only {
            let b = LightLab.frame(booth.number)
            let title = String(format: "%02d %@", booth.number, booth.name)
            object(title) {
                if !LightLab.isYard(booth.number) {
                    labShell(kit, b, m)
                    addInstance(hallFloor, m.checker, translate(b.p(0, 0, b.size.z / 2)))
                    labDecor(kit, b, m, signMesh: addMesh(LabKit.signMesh(booth.number, b), label: "sign"))
                }
                booth.build(self, b, lab)
            }
        }
        let start = LightLab.bookmark(LightLab.booths[0])
        if let (yaw, pitch) = SceneCommand.angles(from: start.position, to: start.lookAt) {
            defaultCamera = Scene.camera(start.position, yaw: yaw, pitch: pitch)
        }
    }

    /// The corridor (3 x 3 m, x from 0 to 55.6, closed at both ends, dark), the walls where no booth stands, and the end
    /// door into the yard with its baffle.
    private func labCorridor(_ kit: Kit, _ m: LabMaterials) {
        let t = LabKit.wall, end = LabKit.corridorEnd
        object("Corridor") {
            kit.slab([-t, -t, -1.8], [end + t, -0.002, 1.8], m.wall)                  // floor
            kit.slab([-t, 3, -1.8], [end + t, 3 + t, 1.8], m.wall)                    // ceiling
            kit.slab([-t, -t, -1.8], [0, 3 + t, 1.8], m.wall)                         // the start
            kit.slab([end, -t, -1.8], [end + t, 3 + t, -0.6], m.wall)                 // the end wall, either side of its door
            kit.slab([end, -t, 0.6], [end + t, 3 + t, 1.8], m.wall)
            kit.slab([end, 2.2, -0.6], [end + t, 3 + t, 0.6], m.wall)
            kit.slab([end - 0.75, 0, -1], [end - 0.6, 2.4, 1], m.wall)                // its baffle
            let first = LabKit.columnX(0) - 2.3, last = LabKit.columnX(LabKit.columns - 1) + 2.3
            for (lo, hi) in [(0 as Float, first), (last, end)] {                      // the gaps beside the first and last booths
                kit.slab([lo, -t, 1.5], [hi, 3 + t, 1.8], m.wall)
                kit.slab([lo, -t, -1.8], [hi, 3 + t, -1.5], m.wall)
            }
            kit.slab([LabKit.columnX(LabKit.columns - 1) - 2.3, -t, -1.8], [last, 3 + t, -1.5], m.wall)   // column 11's empty north side
        }
    }
}

extension SceneKind {
    static let lightLab = SceneKind("lightLab")
}
