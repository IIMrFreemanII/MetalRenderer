import Characters
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// A scene's own runtime logic, its gameplay (the demolition's weapons and walker, the destruction's tools): made by
/// its definition with the scene (SceneDefinition.behaviour), kept on it, and dropped with it. The renderer gives it
/// the frame, the keys and the clicks first, on the render thread.
///
/// It runs a few times a frame at most, so it is plain Swift (the data-oriented skill's "every frame, a few times"
/// row): what runs over many things each frame or each physics step stays one of the engine's systems, driven by the
/// commands the behaviour sends it (Scene.physicsCommand).
package protocol SceneBehaviour: AnyObject {
    /// A frame, before the camera moves; true when it moved the camera itself (the frame's other camera moves are off).
    func update(_ renderer: Renderer, dt: Float) -> Bool
    /// A key (its character without modifiers, lowercased); true when it took it.
    func keyDown(_ renderer: Renderer, _ key: String, isRepeat: Bool) -> Bool
    /// The left button pressed, before anything else has it; true when it took it.
    func mouseDown(_ renderer: Renderer) -> Bool
    /// The left button let go (whatever had the press).
    func mouseUp(_ renderer: Renderer)
    /// A click (a press and a release without a drag) at `cursor`, that nothing else took; true when it took it.
    func click(_ renderer: Renderer, at cursor: SIMD2<Float>) -> Bool
    /// The right button pressed; true when it took it.
    func rightMouseDown(_ renderer: Renderer) -> Bool
    /// A press may grab a physics body (Physics.swift's `grab`): not while a click fires a tool.
    var grabs: Bool { get }
    /// The mouse is captured (SceneHUD.capturesMouse): it turns the camera, `look` gets its moves.
    var captured: Bool { get set }
    func look(_ renderer: Renderer, dx: Float, dy: Float)
    /// The physics' poses drawn this frame (`state`: the demolition's, its rockets and blasts): what the scene shows of
    /// them (Scene.update).
    func drawn(_ scene: Scene, bodies: [GPUPhysicsBody], state: DemolitionState, step: Int)
    /// What the view shows over the frame (SceneHUDView), or nil.
    var hud: SceneHUD? { get }
}

package extension SceneBehaviour {
    func update(_ renderer: Renderer, dt: Float) -> Bool { false }
    func keyDown(_ renderer: Renderer, _ key: String, isRepeat: Bool) -> Bool { false }
    func mouseDown(_ renderer: Renderer) -> Bool { false }
    func mouseUp(_ renderer: Renderer) {}
    func click(_ renderer: Renderer, at cursor: SIMD2<Float>) -> Bool { false }
    func rightMouseDown(_ renderer: Renderer) -> Bool { false }
    var grabs: Bool { true }
    func look(_ renderer: Renderer, dx: Float, dy: Float) {}
    func drawn(_ scene: Scene, bodies: [GPUPhysicsBody], state: DemolitionState, step: Int) {}
    var hud: SceneHUD? { nil }
}

/// What a scene's behaviour shows over the frame (SceneHUDView): a box of text in a corner, and a crosshair (while
/// the mouse is captured, say). A view over the render: the frames never have it, and clicks go through it.
package struct SceneHUD: Equatable {
    package enum Corner { case topLeft, bottomLeft }
    package var lines: [String]
    package var corner = Corner.topLeft
    /// In a monospaced font (columns of keys and tools).
    package var monospaced = false
    package var crosshair = false
    /// A click in the view captures the mouse (it then turns the camera; Escape frees it), and the mouse is let go
    /// when this turns false.
    package var capturesMouse = false

    package init(lines: [String], corner: Corner = .topLeft, monospaced: Bool = false, crosshair: Bool = false, capturesMouse: Bool = false) {
        self.lines = lines
        self.corner = corner
        self.monospaced = monospaced
        self.crosshair = crosshair
        self.capturesMouse = capturesMouse
    }
}
