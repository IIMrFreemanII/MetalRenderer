import Foundation
import QuartzCore

/// What the app is loading in the background and how far along it is, for the loading overlay (LoadingOverlay).
/// A job is one load (a scene switch, a shader compile) made of steps that run one after another; streams are what keeps
/// coming in after a scene is installed (texture levels, virtual geometry pages, distance-field bakes), reported by the
/// render thread while they are unsettled. Any thread may report or read: everything goes through one lock, held only
/// to copy a few values.
final class LoadActivity: @unchecked Sendable {
    struct Step {
        var name: String
        var done = 0
        var total = 0               // 0: no count (an indeterminate bar)
        var detail = ""             // what it is on now: a model's name, MB built
        var started: Double
        var ended: Double?
        func seconds(now: Double) -> Double { (ended ?? now) - started }
    }
    struct Job {
        let id: Int
        var title: String           // what is loaded: "Gallery (Assets)", "shaders"
        var verbs: (running: String, done: String)
        var started: Double
        var ended: Double?
        var failed = false
        var steps: [Step] = []
        func seconds(now: Double) -> Double { (ended ?? now) - started }
        /// "Loading Gallery (Assets)", "Loaded Gallery (Assets)".
        var heading: String { "\(ended == nil ? verbs.running : failed ? "Failed:" : verbs.done) \(title)" }
    }
    struct Stream: Equatable {
        var name: String
        var done: Int
        var total: Int              // 0: no count
        var detail = ""
    }
    struct Snapshot {
        var jobs: [Job]             // running, and the finished ones until the next job begins
        var streams: [Stream]
        var now: Double
        /// When everything had finished, nil while something is running.
        var idleSince: Double?
        var isIdle: Bool { idleSince != nil }
    }

    private let lock = NSLock()
    private var jobs: [Job] = []
    private var cancelled: Set<Int> = []
    private var streams: [Stream] = []
    private var idleSince: Double? = 0
    private var nextID = 0
    private var changed: (() -> Void)?
    /// When a job begins or ends, or the streams start or settle (any thread: the overlay hops to the main thread).
    var onChange: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changed }
        set { lock.lock(); changed = newValue; lock.unlock() }
    }
    /// Print a line with the steps' times when a job finishes.
    var logsSummary = true

    func snapshot(now: Double = CACurrentMediaTime()) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(jobs: jobs, streams: streams, now: now, idleSince: idleSince)
    }

    /// Starts a job. The finished ones go from the list (a running one stays: a shader compile while a scene loads).
    func begin(_ title: String, verbs: (running: String, done: String) = ("Loading", "Loaded")) -> LoadJob {
        let now = CACurrentMediaTime()
        lock.lock()
        nextID += 1
        jobs.removeAll { $0.ended != nil }
        jobs.append(Job(id: nextID, title: title, verbs: verbs, started: now))
        let job = LoadJob(activity: self, id: nextID)
        let notify = updateIdle(now)
        lock.unlock()
        notify?()
        return job
    }

    /// The render thread's streams, as of now: only the unsettled ones are listed.
    func setStreams(_ new: [Stream]) {
        lock.lock()
        guard new != streams else { lock.unlock(); return }
        let wasEmpty = streams.isEmpty
        streams = new
        var notify = updateIdle(CACurrentMediaTime())
        if wasEmpty != new.isEmpty { notify = changed }
        lock.unlock()
        notify?()
    }

    /// (Under the lock.) Notes when everything is done; returns the callback to call once the lock is let go.
    private func updateIdle(_ now: Double) -> (() -> Void)? {
        let idle = streams.isEmpty && jobs.allSatisfy { $0.ended != nil }
        if idle == (idleSince != nil) { return nil }
        idleSince = idle ? now : nil
        return changed
    }

    // MARK: Reports (LoadJob, LoadStep)

    fileprivate func isCancelled(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(id)
    }

    /// Changes job `id` if it is still listed and running.
    private func withJob(_ id: Int, _ change: (inout Job, Double) -> Void) {
        let now = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        guard let j = jobs.firstIndex(where: { $0.id == id }), jobs[j].ended == nil else { return }
        change(&jobs[j], now)
    }

    fileprivate func startStep(_ id: Int, name: String, total: Int, detail: String) -> Int {
        var index = -1
        withJob(id) { job, now in
            for s in job.steps.indices where job.steps[s].ended == nil {   // one at a time: the one before is done
                job.steps[s].ended = now
                if job.steps[s].total > 0 { job.steps[s].done = job.steps[s].total }
            }
            job.steps.append(Step(name: name, total: max(total, 0), detail: detail, started: now))
            index = job.steps.count - 1
        }
        return index
    }

    fileprivate func updateStep(_ id: Int, _ step: Int, _ change: (inout Step) -> Void) {
        withJob(id) { job, _ in
            guard job.steps.indices.contains(step), job.steps[step].ended == nil else { return }
            change(&job.steps[step])
        }
    }

    fileprivate func finishStep(_ id: Int, _ step: Int) {
        withJob(id) { job, now in
            guard job.steps.indices.contains(step), job.steps[step].ended == nil else { return }
            job.steps[step].ended = now
            if job.steps[step].total > 0 { job.steps[step].done = job.steps[step].total }
        }
    }

    fileprivate func end(_ id: Int, failed: Bool, cancel: Bool) {
        let now = CACurrentMediaTime()
        lock.lock()
        guard let j = jobs.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
        if cancel {
            // Superseded: it goes from the list, and its loaders stop where they check (LoadJob.isCancelled).
            cancelled.insert(id)
            jobs.remove(at: j)
            let notify = updateIdle(now) ?? changed
            lock.unlock()
            notify?()
            return
        }
        guard jobs[j].ended == nil else { lock.unlock(); return }
        for s in jobs[j].steps.indices where jobs[j].steps[s].ended == nil {
            jobs[j].steps[s].ended = now
            if !failed && jobs[j].steps[s].total > 0 { jobs[j].steps[s].done = jobs[j].steps[s].total }
        }
        jobs[j].ended = now
        jobs[j].failed = failed
        let job = jobs[j]
        let notify = updateIdle(now) ?? changed
        lock.unlock()
        if logsSummary && !failed { print(LoadActivity.summary(job)) }
        notify?()
    }

    /// "Loaded Gallery (Assets) in 2.4 s: shaders 1.5 s, scene 1.0 s, …" (steps under a millisecond left out; none
    /// when only one is left).
    static func summary(_ job: Job) -> String {
        let steps = job.steps.compactMap { s -> String? in
            let t = s.seconds(now: s.ended ?? job.ended ?? s.started)
            return t < 0.001 ? nil : "\(s.name.lowercased()) \(duration(t))"
        }
        return "\(job.heading) in \(duration(job.seconds(now: job.ended ?? job.started)))"
            + (steps.count < 2 ? "" : ": " + steps.joined(separator: ", "))   // (one step is the whole of it)
    }

    /// 12 ms, 1.4 s.
    static func duration(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.1f s", seconds)
    }
}

/// One load's handle for its loaders (any thread). All of it does nothing once the job is cancelled or has ended.
final class LoadJob: @unchecked Sendable {
    private weak var activity: LoadActivity?
    let id: Int

    fileprivate init(activity: LoadActivity, id: Int) {
        self.activity = activity
        self.id = id
    }

    /// Superseded by a newer load: loaders that can stop early do (their result is thrown away anyway).
    var isCancelled: Bool { activity?.isCancelled(id) ?? true }

    /// Starts the next step (the one before it is done). `total` 0: no count.
    @discardableResult
    func step(_ name: String, total: Int = 0, detail: String = "") -> LoadStep {
        LoadStep(job: self, index: activity?.startStep(id, name: name, total: total, detail: detail) ?? -1)
    }

    func finish() { activity?.end(id, failed: false, cancel: false) }
    func fail() { activity?.end(id, failed: true, cancel: false) }
    func cancel() { activity?.end(id, failed: false, cancel: true) }

    fileprivate func update(_ step: Int, _ change: (inout LoadActivity.Step) -> Void) {
        activity?.updateStep(id, step, change)
    }
    fileprivate func finish(_ step: Int) { activity?.finishStep(id, step) }
}

/// A step of a job (any thread; `advance` may be called from a concurrentPerform's iterations).
struct LoadStep {
    fileprivate let job: LoadJob
    fileprivate let index: Int

    var isCancelled: Bool { job.isCancelled }

    /// `n` more done; `detail`: what it is on now.
    func advance(by n: Int = 1, detail: String? = nil) {
        job.update(index) { s in
            s.done += n
            if let detail { s.detail = detail }
        }
    }

    func set(done: Int? = nil, total: Int? = nil, detail: String? = nil) {
        job.update(index) { s in
            if let done { s.done = done }
            if let total { s.total = max(total, 0) }
            if let detail { s.detail = detail }
        }
    }

    func finish() { job.finish(index) }
}
