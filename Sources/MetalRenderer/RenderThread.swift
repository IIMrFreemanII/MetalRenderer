import Foundation

/// The thread frames are made on. Once it runs it owns the `Renderer`: the main thread (the window, the panels, input)
/// and the background loads hand it work with `perform`, which runs between frames. So the main thread never waits
/// for a frame, however slow frames get, and the renderer's state is only ever touched from one thread.
final class RenderThread {
    private let condition = NSCondition()
    private var pending: [() -> Void] = []
    private var stopped = false
    private var thread: Thread?
    private let exited = DispatchSemaphore(value: 0)

    /// Runs `work` on the render thread before its next frame. Any thread; work posted before `start` waits for it.
    func perform(_ work: @escaping () -> Void) {
        condition.lock()
        pending.append(work)
        condition.signal()
        condition.unlock()
    }

    /// Starts the loop. Each turn runs the work posted since the last one, then `frame`, which returns false if it drew
    /// nothing (no shaders yet, the window hidden, the benchmark done): the loop then waits for work, or for a 60th of a
    /// second. A frame paces itself: it waits for a frame slot and for the drawable, which the display hands out at
    /// its refresh rate.
    func start(frame: @escaping () -> Bool) {
        let thread = Thread { [self] in
            while autoreleasepool(invoking: { turn(frame) }) {}   // the pool releases each frame's drawable
            exited.signal()
        }
        thread.name = "MetalRenderer.render"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 8 << 20   // the main thread's: a secondary thread's 512 KB is too little for the frame code
        self.thread = thread
        thread.start()
    }

    /// Stops the loop once its current frame is encoded, and waits for that (at most a second). Main thread.
    func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
        if thread != nil { _ = exited.wait(timeout: .now() + 1) }
    }

    /// One turn of the loop; false once stopped.
    private func turn(_ frame: () -> Bool) -> Bool {
        condition.lock()
        let work = pending, stop = stopped
        pending = []
        condition.unlock()
        if stop { return false }
        for w in work { w() }
        if !frame() {
            condition.lock()
            if pending.isEmpty && !stopped { _ = condition.wait(until: Date(timeIntervalSinceNow: 1.0 / 60)) }
            condition.unlock()
        }
        return true
    }
}
