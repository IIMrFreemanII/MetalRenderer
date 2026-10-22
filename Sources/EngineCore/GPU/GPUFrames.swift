/// How many frames the CPU runs ahead of the GPU (Renderer.maxFramesInFlight): what a buffer written each frame is
/// multiplied by, and how long a system keeps what the GPU may still read (the liquids' surfaces).
package enum GPUFrames {
    package static let maxInFlight = 3
}
