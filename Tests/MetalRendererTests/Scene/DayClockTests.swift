import AppKit
import XCTest
@testable import MetalRenderer

/// The day as a clock (DayClock.swift): the scenes' suns along their days, the presets, holding the day, and the day bar.
final class DayClockTests: XCTestCase {
    private let running: [SceneKind] = [.world, .sun, .valley, .forest, .city]

    func testClocksAreTheScenesDays() {
        for kind in running {
            let clock = DayClock.of(kind)!
            XCTAssertTrue(clock.runs)
            XCTAssertEqual(clock.cycle, kind.dayCycle, "\(kind)")
        }
        XCTAssertFalse(DayClock.of(.cityNight)!.runs)
        XCTAssertNil(DayClock.of(.gallery))
        XCTAssertNil(DayClock.of(.cornell))
    }

    /// The scenes' suns are posed as they were before DaySweep: the frames are the same.
    func testSweepsAreTheScenesSuns() {
        for t in stride(from: Float(-50), through: 400, by: 7.3) {
            XCTAssertEqual(DaySweep.valley.phase(t), 0.5 - 0.5 * cos(.pi * (t / 90 + 0.35)), accuracy: 1e-5)
            XCTAssertEqual(DaySweep.city.phase(t), 0.5 - 0.5 * cos(.pi * (t / 90 + 0.3)), accuracy: 1e-5)
            XCTAssertEqual(cos(2 * .pi * DaySweep.courtyard.phase(t)), cos(2 * .pi * (t + 12) / 60), accuracy: 1e-4)
            XCTAssertEqual(sin(2 * .pi * DaySweep.courtyard.phase(t)), sin(2 * .pi * (t + 12) / 60), accuracy: 1e-4)
        }
    }

    func testHoursGoThereAndBack() {
        for kind in running {
            let clock = DayClock.of(kind)!
            for hour in stride(from: clock.hours.lowerBound, to: clock.hours.upperBound, by: 0.25) {
                let t = clock.dayTime(hour: hour)
                XCTAssertTrue((0..<clock.cycle).contains(t), "\(kind) \(hour): \(t)")
                XCTAssertEqual(clock.hour(dayTime: t)!, hour, accuracy: 0.01, "\(kind)")
            }
        }
    }

    func testTheWorldsPresets() {
        let clock = DayClock.of(.world)!
        func elevation(_ p: DayPreset) -> Float { Heavens(at: clock.dayTime(hour: clock.hour(of: p)!)).sunElevation * 180 / .pi }
        XCTAssertEqual(elevation(.noon), 60, accuracy: 0.5)
        XCTAssertLessThan(elevation(.night), -20)
        for p in [DayPreset.dawn, .sunset] { XCTAssertEqual(elevation(p), 0, accuracy: 3, "\(p): just over the horizon") }
        XCTAssertTrue(clock.isNight(hour: clock.hour(of: .night)))
        XCTAssertFalse(clock.isNight(hour: clock.hour(of: .noon)))
        XCTAssertTrue(DayPreset.allCases.allSatisfy(clock.offers))
    }

    /// The daylight scenes: Dawn and Sunset are the ends of their suns' days, Noon the middle; Night only in the city.
    func testTheDaylightPresets() {
        for kind in [SceneKind.sun, .valley, .forest, .city] {
            let clock = DayClock.of(kind)!
            guard case .sweep(let sweep) = clock.path else { return XCTFail("\(kind)") }
            for (p, phase) in [(DayPreset.dawn, Float(0)), (.noon, 0.5), (.sunset, 1)] {
                let got = sweep.phase(clock.dayTime(hour: clock.hour(of: p)!))
                // The courtyard's evening is its next morning.
                XCTAssertEqual(kind == .sun && phase == 1 ? (got < 0.5 ? got + 1 : got) : got, phase, accuracy: 1e-3, "\(kind) \(p)")
            }
            XCTAssertNil(clock.hour(of: .night))
            XCTAssertEqual(clock.offers(.night), kind == .city)
        }
        XCTAssertEqual(DayClock.of(.city)!.preset(at: 13), .noon)
        XCTAssertNil(DayClock.of(.city)!.preset(at: 14))
        XCTAssertEqual(DayClock.of(.cityNight)!.preset(at: nil), .night)
    }

    func testNightTakesTheCityToItsNight() {
        let defaults = RenderSettings()
        var s = RenderSettings()
        s.scene.kind = .city
        s.holdDay(.night, defaults: defaults)
        XCTAssertEqual(s.scene.kind, .cityNight)
        s.holdDay(.night, defaults: defaults)
        XCTAssertEqual(s.scene.kind, .cityNight, "Night by night stays")
        s.holdDay(.noon, defaults: defaults)
        XCTAssertEqual(s.scene.kind, .city)
        XCTAssertTrue(s.dayHeld)
        XCTAssertEqual(s.heldHour!, 13, accuracy: 0.01)
        s.holdDay(.sunset, defaults: defaults)
        XCTAssertEqual(s.heldHour!, 19, accuracy: 0.01)
        // The valley has no night to go to.
        s.scene.kind = .valley
        s.holdDay(.dawn, defaults: defaults)
        let before = s
        s.holdDay(.night, defaults: defaults)
        XCTAssertEqual(s, before)
    }

    /// Holding the day, and letting it run again, leave it where it was.
    func testHoldingKeepsTheDay() {
        for kind in running {
            for animTime: Float in [0, 37.5, 1000] {
                var s = RenderSettings()
                s.scene.kind = kind
                s.timeOfDay = 0.3
                var held = s
                held.dayHeld = true
                held.keepDay(from: s, animTime: animTime)
                let cycle = kind.dayCycle!
                func same(_ a: Float, _ b: Float) -> Bool { abs(DayClock.wrap(a - b + cycle / 2, cycle) - cycle / 2) < 1e-2 }
                XCTAssertTrue(same(held.dayTime(animTime: animTime), s.dayTime(animTime: animTime)), "\(kind) \(animTime)")
                XCTAssertEqual(held.dayTime(animTime: animTime + 50), held.dayTime(animTime: animTime), "held: the day stays")
                var run = held
                run.dayHeld = false
                run.keepDay(from: held, animTime: animTime)
                XCTAssertTrue(same(run.dayTime(animTime: animTime), held.dayTime(animTime: animTime)), "\(kind) \(animTime)")
            }
        }
        // A scene without a day keeps the animation's time, held or not.
        var s = RenderSettings()
        s.scene.kind = .gallery
        s.dayHeld = true
        XCTAssertEqual(s.dayTime(animTime: 12), 12)
    }

    func testLabels() {
        XCTAssertEqual(DayClock.label(0), "00:00")
        XCTAssertEqual(DayClock.label(14.5), "14:30")
        XCTAssertEqual(DayClock.label(23.999), "00:00")
    }

    /// DAY_BAR_PNG=<folder>: the day bar drawn offscreen in a few scenes.
    func testDayBarPictures() throws {
        guard let path = ProcessInfo.processInfo.environment["DAY_BAR_PNG"] else { throw XCTSkip("DAY_BAR_PNG not set") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = RenderSettings()
        let views: [(String, SceneKind, DayPreset?)] = [("world-noon", .world, .noon), ("world-night", .world, .night),
                                                       ("valley-running", .valley, nil), ("city-night", .cityNight, nil)]
        for (name, kind, preset) in views {
            var s = RenderSettings()
            s.scene.kind = kind
            if let preset { s.holdDay(preset, defaults: defaults) }
            let bar = DayBar()
            bar.show(s)
            if preset == nil, let clock = DayClock.of(kind), clock.runs { bar.show(dayTime: clock.dayTime(hour: 10.25)) }
            let host = NSView(frame: NSRect(x: 0, y: 0, width: DayBar.width + 40, height: 100))
            host.appearance = NSAppearance(named: .darkAqua)
            bar.attach(to: host)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("daybar-\(name).png"))
        }
    }
}
