import AppKit
import MetalKit
import UniformTypeIdentifiers

protocol InputHandler: AnyObject {
    func keyDown(_ event: NSEvent)
    func keyUp(_ event: NSEvent)
    func mouseDragged(dx: Float, dy: Float)
}

/// MTKView that forwards keyboard and mouse input to the renderer.
final class RenderView: MTKView {
    weak var inputHandler: InputHandler?

    var onDropModels: (([URL]) -> Void)?

    /// What File > Open and drag and drop accept: glTF models, and HDR images (.hdr, .exr) for the sky.
    static let openableExtensions = ["glb", "gltf", "hdr", "exr"]
    static let modelTypes: [UTType] = openableExtensions.compactMap { UTType(filenameExtension: $0) }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        registerForDraggedTypes([.fileURL])
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func modelURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { RenderView.openableExtensions.contains($0.pathExtension.lowercased()) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { modelURLs(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = modelURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropModels?(urls)
        return true
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Not calling super avoids the system "beep" for unhandled keys.
    override func keyDown(with event: NSEvent) { inputHandler?.keyDown(event) }
    override func keyUp(with event: NSEvent) { inputHandler?.keyUp(event) }

    override func mouseDragged(with event: NSEvent) {
        inputHandler?.mouseDragged(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }
}
