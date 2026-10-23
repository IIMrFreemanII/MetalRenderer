import EngineCore
import Foundation
import Physics
import simd

/// The car scene's cameras (CarPlayer: C goes round them): behind the car on a spring, on its hood, at the driver's
/// eye, circling it, and from beside the road ahead as it comes past. Each is placed from the car's frame as a frame
/// draws it (CarTelemetry: its floor's middle, forward and up) and its spec (its size, as fitted to its model).
enum CarCamera: Int, CaseIterable {
    case chase, hood, cockpit, orbit, trackside

    var title: String { ["Chase", "Hood", "Cockpit", "Orbit", "Trackside"][rawValue] }
    /// The captured mouse turns it (round the car).
    var turns: Bool { self == .chase || self == .orbit }
}

/// Where the camera is and what it looks along, eased frame to frame (`cut` starts it afresh).
struct CarCameraRig {
    var mode = CarCamera.chase
    /// Turned round the car (yaw, pitch, radians) by the captured mouse.
    var orbit = SIMD2<Float>(0, 0)
    /// The eased eye (chase) and view direction (hood, cockpit); the orbit's angle; the trackside camera's post.
    private var eye: SIMD3<Float>?
    private var view: SIMD3<Float>?
    private var spin: Float = 0
    private var post: SIMD3<Float>?

    /// The chase camera's place behind and above the car (m), what it looks at above the car's middle (its body's
    /// rings' nodes': CarTelemetry.centre), how fast it follows (s).
    static let behind: Float = 6.5, above: Float = 2.2, target: Float = 0.4, lag: Float = 0.12
    /// The orbit's radius and height (m), its turn (rad/s); the trackside post's distance ahead and aside, its height
    /// (m), and how far the car may be from it before it moves on (m).
    static let orbitRadius: Float = 7, orbitHeight: Float = 1.8, orbitRate: Float = 0.35
    static let postAhead: Float = 14, postAside: Float = 5, postHeight: Float = 1.5, postReach: Float = 30
    /// How fast the hood's and cockpit's view follows the car's turns (s): a crash jolts it without strobing.
    static let mountLag: Float = 0.05

    /// The next camera, from where it is now.
    mutating func next() {
        mode = CarCamera(rawValue: (mode.rawValue + 1) % CarCamera.allCases.count)!
        cut()
    }

    /// No easing from the last frame's place (a camera switch, a restart).
    mutating func cut() {
        eye = nil
        view = nil
        post = nil
    }

    /// The car's point `p` (x left, y up from the ground, z forward: the model's space) where frame `t` has it (its
    /// floor's middle at the spec's sill height).
    static func point(_ p: SIMD3<Float>, _ t: CarTelemetry, _ spec: CarSpec) -> SIMD3<Float> {
        let left = cross(t.up, t.forward)
        return t.position + left * p.x + t.up * (p.y - spec.sill) + t.forward * p.z
    }

    /// The hood's camera in the car's space: over the front axle, just above the hood.
    static func hoodEye(_ spec: CarSpec) -> SIMD3<Float> {
        let z = spec.wheelbase / 2 - 0.15
        return [0, spec.topHeight(z) + 0.22, z]
    }

    /// The camera for frame `t` of a car of `spec`: its eye and the unit direction it looks along. `dt`: the frame's
    /// length (real time: the orbit turns as fast in slow motion).
    mutating func place(_ t: CarTelemetry, spec: CarSpec, dt: Float) -> (eye: SIMD3<Float>, look: SIMD3<Float>) {
        var ahead = SIMD3<Float>(t.forward.x, 0, t.forward.z)
        ahead = length(ahead) > 1e-3 ? normalize(ahead) : [0, 0, 1]
        let target = t.centre + SIMD3(0, CarCameraRig.target, 0)
        switch mode {
        case .chase:
            // Behind the car (its heading on the ground), turned by the mouse, a little above; easing after it.
            let back = simd_quatf(angle: orbit.x, axis: [0, 1, 0]).act(-ahead)
            let wanted = target + back * (CarCameraRig.behind * cos(orbit.y)) + SIMD3(0, CarCameraRig.above + CarCameraRig.behind * sin(orbit.y), 0)
            let k = 1 - exp(-dt / CarCameraRig.lag)
            let e = eye.map { $0 + (wanted - $0) * k } ?? wanted
            eye = e
            return (e, normalize(target - e))
        case .hood, .cockpit:
            let at = CarCameraRig.point(mode == .hood ? CarCameraRig.hoodEye(spec) : CarPack.entry(spec.style).eye, t, spec)
            let wanted = normalize(t.forward - t.up * (mode == .hood ? 0.06 : 0.1))
            let k = 1 - exp(-dt / CarCameraRig.mountLag)
            let v = view.map { normalize($0 + (wanted - $0) * k) } ?? wanted
            view = v
            return (at, v)
        case .orbit:
            spin += dt * CarCameraRig.orbitRate
            let a = spin + orbit.x, ground = t.position.y - spec.sill
            let e = SIMD3(target.x + sin(a) * CarCameraRig.orbitRadius, ground + CarCameraRig.orbitHeight + CarCameraRig.orbitRadius * sin(max(orbit.y, -0.2)),
                          target.z + cos(a) * CarCameraRig.orbitRadius)
            return (e, normalize(target - e))
        case .trackside:
            // Ahead of the car along its way (backwards when it reverses), off to one side; moved on once it is far or
            // well past.
            let way = t.speed < -0.5 ? -ahead : ahead, side = SIMD3(way.z, 0, -way.x)
            if let p = post {
                let d = SIMD3(p.x - t.centre.x, 0, p.z - t.centre.z)
                if simd_length(d) > CarCameraRig.postReach || (dot(d, way) < -8 && abs(t.speed) > 1) { post = nil }
            }
            if post == nil {
                let ground = t.position.y - spec.sill
                post = SIMD3(t.centre.x, ground + CarCameraRig.postHeight, t.centre.z) + way * CarCameraRig.postAhead + side * CarCameraRig.postAside
            }
            return (post!, normalize(target - post!))
        }
    }
}
