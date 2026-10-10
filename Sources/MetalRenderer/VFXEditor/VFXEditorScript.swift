import AppKit

/// `METALRENDERER_VFX_SCRIPT=<folder>` (the app with its window): the VFX editor driven through what its controls do,
/// a step every few seconds, as the renderer runs it. After each step the renderer's report (VFXStatus) is printed
/// and the editor's window is written to the folder as a PNG; the app quits at the end. With
/// `METALRENDERER_EFFECTS=<another folder>` so that Save doesn't write into Assets/Effects.
enum VFXEditorScript {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["METALRENDERER_VFX_SCRIPT"].map { URL(fileURLWithPath: $0) }
    }

    static func run(_ panel: VFXEditorPanel, main: NSWindow) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let m = panel.model
        var k = 0
        func shot(_ name: String) {
            k += 1
            let s = m.status
            let mine = s?.emitters.filter { $0.effect == m.selectedEffect } ?? []
            print("VFX script \(k) \(name): scene \(m.scene.kind.title), stage \(m.scene.stage.effects), effect \(m.selectedEffect), "
                  + "emitters \(mine.map { "\($0.name) \($0.alive)/\($0.capacity)\($0.program ? " (code)" : "")" }), "
                  + "time \(String(format: "%.2f", m.time)) s\(m.paused ? " paused" : ""), backdrop \(m.scene.stage.backdrop.rawValue), "
                  + "passes \(s?.passMs.mapValues { String(format: "%.2f", $0) } ?? [:]), compiling \(s?.compiling ?? false), "
                  + "compiled in \(s?.compileMs.map { String(format: "%.0f ms", $0) } ?? "-"), failure \(s?.failure ?? "none"), "
                  + "notes \(s?.notes ?? []), key \(s?.key ?? "-"), dirty \(m.isDirty)")
            guard let view = panel.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(String(format: "%02d-%@.png", k, name)))
        }
        var steps: [(String, Double, () -> Void)] = [
            ("open", 1, { panel.show(nextTo: main); m.select("fireworks"); m.showOnStage() }),
            ("fireworks", 5, {}),
            ("grey backdrop", 4, { m.setBackdrop(.grey) }),
            ("scrubbed to 1 s, paused", 2, { m.playPause(); m.setTime(1) }),
            ("a step on", 1.5, { m.stepFrame() }),
            ("playing at half speed, stats", 3, { m.setSpeed(0.5); m.playPause(); m.showStats = true; m.click("stars.velocity") }),
            ("full speed", 1, { m.setSpeed(1); m.showStats = false }),
            ("new effect", 1, { m.newEffect(); m.showOnStage() }),
            ("new effect running", 4, {}),
        ]
        var size = ""
        steps += [
            ("curve into size", 1, {
                let fx = m.effect
                guard let e = fx.emitters.first, let sizeBlock = e.output.first(where: { $0.kind == .size }) else { return }
                size = sizeBlock.id
                let age = m.addNode(.ageOverLife, at: [-420, 260])
                let curve = m.addNode(.curve, at: [-220, 260])
                m.setParam(curve, "curve", .curve(VFXCurve([[0, 0.02], [0.2, 0.08], [1, 0]], smooth: true)))
                _ = m.link(age, "out", to: curve, "t")
                _ = m.link(curve, "out", to: size, "size")
                m.click(curve)
            }),
            ("compiled", 5, {}),
            ("rate dragged", 1, {
                guard let rate = m.effect.emitters.first?.spawn.first?.id else { return }
                m.beginDrag()
                for r in stride(from: 60, through: 240, by: 20) { m.setParam(rate, "rate", .float(Float(r))) }
                m.endDrag()
                m.click(rate)
            }),
            ("rate live", 2, {}),
            ("saved", 1, {
                m.save()
                let back = VFXStore.load(from: VFXStore.folder)
                print("VFX script: saved \(back.effects.keys.sorted()); reloaded equals edited: \(back.effects[m.selectedEffect] == m.effect)")
            }),
            ("undo to the template", 2, { while m.undo.canUndo { m.undo.undo() } }),
            ("fireworks again", 4, { m.select("fireworks"); m.clearSelection() }),
        ]
        var t = 2.0
        for (name, wait, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { action() }
            t += wait
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { shot(name) }
            t += 0.3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.5) {
            print("VFX script done")
            NSApp.terminate(nil)
        }
    }
}
