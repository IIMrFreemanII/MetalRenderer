import XCTest
@testable import MetalRenderer

/// The loading overlay's model (LoadActivity): jobs, their steps, cancellation, streams and when it is idle.
final class LoadActivityTests: XCTestCase {
    private func quiet() -> LoadActivity {
        let activity = LoadActivity()
        activity.logsSummary = false
        return activity
    }

    func testStepsRunOneAfterAnother() {
        let activity = quiet()
        XCTAssertTrue(activity.snapshot().isIdle)
        let job = activity.begin("Gallery (Assets)")
        XCTAssertFalse(activity.snapshot().isIdle)
        let models = job.step("Scene", total: 3, detail: "owl")
        models.advance(detail: "demon")
        let textures = job.step("Textures", total: 10)   // ends "Scene"
        textures.advance(by: 4)
        var snap = activity.snapshot()
        XCTAssertEqual(snap.jobs.count, 1)
        XCTAssertEqual(snap.jobs[0].heading, "Loading Gallery (Assets)")
        XCTAssertEqual(snap.jobs[0].steps.map(\.name), ["Scene", "Textures"])
        XCTAssertNotNil(snap.jobs[0].steps[0].ended)
        XCTAssertEqual(snap.jobs[0].steps[0].done, 3, "a finished step with a count is complete")
        XCTAssertEqual(snap.jobs[0].steps[0].detail, "demon")
        XCTAssertNil(snap.jobs[0].steps[1].ended)
        XCTAssertEqual(snap.jobs[0].steps[1].done, 4)

        job.finish()
        snap = activity.snapshot()
        XCTAssertTrue(snap.isIdle)
        XCTAssertEqual(snap.jobs[0].heading, "Loaded Gallery (Assets)")
        XCTAssertEqual(snap.jobs[0].steps[1].done, 10)
        XCTAssertTrue(snap.jobs[0].steps.allSatisfy { $0.ended != nil })
        // Reports after the end change nothing.
        textures.advance(by: 100)
        job.step("Late")
        XCTAssertEqual(activity.snapshot().jobs[0].steps.count, 2)
        XCTAssertEqual(activity.snapshot().jobs[0].steps[1].done, 10)
    }

    func testAdvanceFromManyThreadsCountsEveryCall() {
        let activity = quiet()
        let job = activity.begin("shaders", verbs: ("Compiling", "Compiled"))
        let step = job.step("Shaders", total: 1000)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in step.advance() }
        XCTAssertEqual(activity.snapshot().jobs[0].steps[0].done, 1000)
        XCTAssertEqual(activity.snapshot().jobs[0].heading, "Compiling shaders")
    }

    func testCancelledJobLeavesTheListAndStopsReporting() {
        let activity = quiet()
        let old = activity.begin("Gallery")
        let step = old.step("Scene", total: 11)
        let new = activity.begin("Showcase")
        XCTAssertFalse(old.isCancelled)
        XCTAssertEqual(activity.snapshot().jobs.count, 2, "a running job stays when another begins")
        old.cancel()
        XCTAssertTrue(old.isCancelled)
        XCTAssertTrue(step.isCancelled)
        XCTAssertFalse(new.isCancelled)
        step.advance()
        XCTAssertEqual(activity.snapshot().jobs.map(\.title), ["Showcase"])
        new.finish()
        XCTAssertFalse(new.isCancelled, "finished is not cancelled")
        XCTAssertTrue(activity.snapshot().isIdle)
        // The next job takes the finished one's place.
        _ = activity.begin("Forest")
        XCTAssertEqual(activity.snapshot().jobs.map(\.title), ["Forest"])
    }

    func testFailedJob() {
        let activity = quiet()
        let job = activity.begin("City")
        job.step("Scene", total: 4).advance()
        job.fail()
        let snap = activity.snapshot()
        XCTAssertTrue(snap.jobs[0].failed)
        XCTAssertEqual(snap.jobs[0].heading, "Failed: City")
        XCTAssertEqual(snap.jobs[0].steps[0].done, 1, "a failed step keeps its count")
        XCTAssertTrue(snap.isIdle)
    }

    func testStreamsKeepItBusyAndNotify() {
        let activity = quiet()
        var changes = 0
        activity.onChange = { changes += 1 }
        let stream = LoadActivity.Stream(name: "Texture levels", done: 3, total: 9)
        activity.setStreams([stream])
        XCTAssertFalse(activity.snapshot().isIdle)
        XCTAssertEqual(changes, 1)
        activity.setStreams([LoadActivity.Stream(name: "Texture levels", done: 5, total: 9)])
        XCTAssertEqual(changes, 1, "progress alone is no change worth waking for")
        activity.setStreams([])
        XCTAssertTrue(activity.snapshot().isIdle)
        XCTAssertEqual(changes, 2)
        let job = activity.begin("Gallery")
        job.finish()
        XCTAssertEqual(changes, 4, "a job's start and end")
    }

    func testSummary() {
        let job = LoadActivity.Job(id: 1, title: "Gallery (Assets)", verbs: ("Loading", "Loaded"), started: 10, ended: 12.4,
                                   steps: [LoadActivity.Step(name: "Scene", started: 10, ended: 11),
                                           LoadActivity.Step(name: "Textures", started: 11, ended: 11.0001),
                                           LoadActivity.Step(name: "Install", started: 12.388, ended: 12.4)])
        XCTAssertEqual(LoadActivity.summary(job), "Loaded Gallery (Assets) in 2.4 s: scene 1.0 s, install 12 ms")
        let shaders = LoadActivity.Job(id: 2, title: "shaders", verbs: ("Compiling", "Compiled"), started: 0, ended: 0.026,
                                       steps: [LoadActivity.Step(name: "Shaders", started: 0, ended: 0.026)])
        XCTAssertEqual(LoadActivity.summary(shaders), "Compiled shaders in 26 ms")
    }

    /// A scene built with a job reports its build and finishes the step; a cancelled gallery stops loading models.
    func testSceneReportsItsBuild() {
        let activity = quiet()
        let job = activity.begin("Cornell box")
        _ = Scene(SceneSettings(), load: job)
        let steps = activity.snapshot().jobs[0].steps
        XCTAssertEqual(steps.map(\.name), ["Scene"])
        XCTAssertNotNil(steps[0].ended)

        var gallery = SceneSettings()
        gallery.kind = .gallery
        let cancelled = activity.begin("Gallery")
        cancelled.cancel()
        let scene = Scene(gallery, load: cancelled)
        XCTAssertTrue(scene.textures.isEmpty, "the room and its lights, no model")
    }
}

/// The pipeline sets kept per light mix (PipelineCache), with numbers for sets.
final class PipelineCacheTests: XCTestCase {
    private func key(_ lightTypes: UInt32, generation: Int = 0, api: RenderAPI = .metal3, stats: Bool = false) -> PipelineCache<Int>.Key {
        .init(api: api, stats: stats, lightTypes: lightTypes, generation: generation)
    }

    func testASetIsFoundByEverythingItWasMadeFor() {
        let cache = PipelineCache<Int>()
        cache.put(key(0b011), 1)
        XCTAssertEqual(cache.get(key(0b011)), 1)
        XCTAssertNil(cache.get(key(0b111)))
        XCTAssertNil(cache.get(key(0b011, api: .metal4)))
        XCTAssertNil(cache.get(key(0b011, stats: true)))
        cache.put(key(0b011), 2)
        XCTAssertEqual(cache.get(key(0b011)), 2, "the newer set for the same key")
        XCTAssertEqual(cache.count, 1)
    }

    func testTheLeastRecentlyUsedGoesFirst() {
        let cache = PipelineCache<Int>(capacity: 2)
        cache.put(key(1), 1)
        cache.put(key(2), 2)
        XCTAssertEqual(cache.get(key(1)), 1)   // 2 is now the oldest
        cache.put(key(3), 3)
        XCTAssertNil(cache.get(key(2)))
        XCTAssertEqual(cache.get(key(1)), 1)
        XCTAssertEqual(cache.get(key(3)), 3)
    }

    func testAReloadMakesOlderSetsStale() {
        let cache = PipelineCache<Int>()
        cache.put(key(1), 1)
        cache.put(key(2), 2)
        cache.put(key(1, generation: 1), 10)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNil(cache.get(key(2)))
        cache.put(key(2), 2)                     // made from the shaders before the reload: not kept
        XCTAssertNil(cache.get(key(2)))
        XCTAssertEqual(cache.get(key(1, generation: 1)), 10)
    }
}
