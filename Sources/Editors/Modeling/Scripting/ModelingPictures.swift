import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Modeling
import SwiftUI
import UniformTypeIdentifiers

/// Pictures of a Modeller that no window shows (the tests', a scripted one's): the viewport as its renderer draws it,
/// and the whole window as AppKit draws its views, the viewport's frame in it. Main thread.
enum ModelingPictures {
    /// The viewport's frame, `scale` times the view's pixels.
    static func viewport(_ model: ModelingModel, scale: Float = 1) -> CGImage? {
        var f = model.frame()
        f.size = SIMD2(max(1, Int((model.viewSize.x * model.pixelScale * scale).rounded())),
                       max(1, Int((model.viewSize.y * model.pixelScale * scale).rounded())))
        f.pixelScale = model.pixelScale * scale
        return model.renderer?.snapshot(f)
    }

    /// The window at `size` points: its panels, and the viewport drawn into its place. With `viewport`, the window
    /// grows or shrinks so its viewport has that size (a scripted Modeller's points then land where its clicks did).
    static func window(_ model: ModelingModel, size: CGSize = CGSize(width: 1440, height: 860), viewport: SIMD2<Float>? = nil) -> NSBitmapImageRep? {
        ModelingViewport.pictures = true
        defer { ModelingViewport.pictures = false }
        func draw(_ size: CGSize) -> NSBitmapImageRep? {
            let host = NSHostingView(rootView: ModelingView().environmentObject(model).frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        let first = draw(size)
        // (The viewport's picture takes the size it is laid out at: the panels around it are the rest.)
        guard let want = viewport, model.viewSize != want else { return first }
        let fitted = CGSize(width: size.width + CGFloat(want.x - model.viewSize.x), height: size.height + CGFloat(want.y - model.viewSize.y))
        return draw(fitted)
    }

    /// `image` as a PNG at `url`, `scale` times its size.
    static func write(_ image: CGImage, to url: URL, scale: Double = 1) throws {
        var out = image
        if scale > 0, abs(scale - 1) > 1e-3 {
            let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
            g.interpolationQuality = .high
            g.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = g.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            out = scaled
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
