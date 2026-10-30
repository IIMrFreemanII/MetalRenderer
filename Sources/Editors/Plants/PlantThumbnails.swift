import AppKit
import MetalRenderer
import Plants
import simd

/// The nodes' small pictures: the graph run once for all of them, and drawn, on a queue of their own and only ever the
/// latest edit, so that a slider dragged doesn't wait for them. The main thread only swaps the images in.
final class PlantThumbnails: ObservableObject {
    /// In points, and pixels to a point.
    static let size = 48
    static let scale: CGFloat = 2

    @Published private(set) var images: [Int32: CGImage] = [:]

    private struct Request {
        var def: Foliage.SpeciesDef
        var species: Foliage.Species
        var age: Foliage.Age
        var variant: Int
        var seed: UInt64
    }

    private let queue = DispatchQueue(label: "plant thumbnails", qos: .utility)
    private var wanted: Request?                // main thread
    private var running = false                 // main thread
    /// How often they change, at most.
    private let interval = 0.1

    func want(_ def: Foliage.SpeciesDef, species: Foliage.Species, age: Foliage.Age, variant: Int, seed: UInt64) {
        wanted = Request(def: def, species: species, age: age, variant: variant, seed: seed)
        startNext()
    }

    private func startNext() {
        guard !running, let request = wanted else { return }
        wanted = nil
        running = true
        let interval = self.interval
        queue.async { [weak self] in
            let start = CFAbsoluteTimeGetCurrent()
            let made = PlantPrograms.sketches(request.def, species: request.species, age: request.age, variant: request.variant, seed: request.seed)
                .compactMapValues(PlantThumbnails.draw)
            let rest = interval - (CFAbsoluteTimeGetCurrent() - start)
            DispatchQueue.main.async {
                self?.images = made
                DispatchQueue.main.asyncAfter(deadline: .now() + max(rest, 0)) {
                    self?.running = false
                    self?.startNext()
                }
            }
        }
    }

    /// A colour a generation as the workshop's skeleton view has them, the leaves green, standing on its picture's foot.
    static func draw(_ sketch: PlantSketch) -> CGImage? {
        let pixels = Int(CGFloat(size) * scale)
        guard let box = sketch.bounds, let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let margin: Float = 4, room = Float(pixels) - 2 * margin
        let extent = simd_max(box.hi - box.lo, SIMD2(repeating: 1e-4)), fit = room / max(extent.x, extent.y)
        let x0 = margin + (room - extent.x * fit) / 2
        func at(_ p: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(x0 + (p.x - box.lo.x) * fit), y: CGFloat(margin + (p.y - box.lo.y) * fit)) }
        c.setLineCap(.round)
        c.setLineJoin(.round)
        let colors = Scene.skeletonColors
        for line in sketch.lines where line.points.count > 1 {
            let color = colors[min(line.level, colors.count - 2)]
            c.setStrokeColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 0.95)
            c.setLineWidth(line.level == 0 ? 1.6 : 0.8)
            c.beginPath()
            c.move(to: at(line.points[0]))
            for p in line.points.dropFirst() { c.addLine(to: at(p)) }
            c.strokePath()
        }
        c.setFillColor(red: 0.45, green: 0.8, blue: 0.35, alpha: 0.75)
        // (A twig's few leaves as big as a tree's many are small.)
        let r: CGFloat = sketch.dots.count < 60 ? 2.5 : 0.75
        for p in sketch.dots {
            let q = at(p)
            c.fill(CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
        }
        return c.makeImage()
    }
}
