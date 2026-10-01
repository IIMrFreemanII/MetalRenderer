import AppKit
import MetalKit

protocol InputHandler: AnyObject {
    func keyDown(_ event: NSEvent)
    func keyUp(_ event: NSEvent)
    func mouseDragged(dx: Float, dy: Float)
}

/// MTKView that forwards keyboard and mouse input to the renderer.
final class RenderView: MTKView {
    weak var inputHandler: InputHandler?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Not calling super avoids the system "beep" for unhandled keys.
    override func keyDown(with event: NSEvent) { inputHandler?.keyDown(event) }
    override func keyUp(with event: NSEvent) { inputHandler?.keyUp(event) }

    override func mouseDragged(with event: NSEvent) {
        inputHandler?.mouseDragged(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }
}
