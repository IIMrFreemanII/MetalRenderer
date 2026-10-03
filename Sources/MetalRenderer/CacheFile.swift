import Foundation

/// Files the app derives from something else and keeps so it need not derive them again: where they live and how
/// they are written. (The virtual geometry and texture caches sit next to their model; see VirtualGeometryBuilder.)
enum CacheFile {
    /// ~/Library/Caches/MetalRenderer, created on first use: for what belongs to the app, not to a model.
    static let userFolder: URL = {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MetalRenderer")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// Writes `data` to a temporary file next to `url`, then moves it into place: a reader never sees half a file.
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: temporary)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}

/// How long the app takes to show its first frame, measured from the creation of the process (so the dynamic loader's
/// share counts), with the steps on the way. One line, printed when the first frame is on screen.
enum Launch {
    private static var marks: [(name: String, ms: Double)] = []
    private static var reported = false

    /// Milliseconds since the process was created.
    static func elapsedMs() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_starttime
        var now = timeval()
        gettimeofday(&now, nil)
        return Double(now.tv_sec - start.tv_sec) * 1000 + Double(now.tv_usec - start.tv_usec) / 1000
    }

    /// Notes a step reached now (main thread).
    static func mark(_ name: String) {
        if !reported { marks.append((name, elapsedMs())) }
    }

    /// The first frame is done: prints the steps, once.
    static func firstFrame() {
        guard !reported else { return }
        mark("first frame")
        reported = true
        print("Launch: " + marks.map { String(format: "%@ after %.0f ms", $0.name, $0.ms) }.joined(separator: ", "))
    }
}
