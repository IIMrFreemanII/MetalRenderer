import AppKit
import MetalKit
import QuartzCore
import simd

extension Renderer {
    // MARK: - Input (from RendererController)

    /// A key went down: `key` is its character without modifiers, lowercased.
    func keyDown(_ key: String, isRepeat: Bool) {
        if demolitionKey(key, isRepeat: isRepeat) { return }
        if key == "v" && !isRepeat { toggleWalk(); return }
        if let w = walker {
            switch key {
            case " ": jumpPending = true; return
            case "c": crouchHeld = true; return
            case "e": if !isRepeat { use(camera.forward) }; return
            case "f":
                if !isRepeat, let c = scene.interiorControls {
                    c.flashlight.on.toggle()
                    c.flashlight.position = camera.position
                    c.flashlight.direction = camera.forward
                    walkMessage = c.flashlight.on ? "Flashlight on" : "Flashlight off"
                }
                return
            case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                // In a lift: to that floor (0 the ground floor).
                if let p = w.standingOn, let c = scene.interiorControls, c.lifts.indices.contains(p) {
                    c.lifts[p].call(Int(key)!)
                    walkMessage = "Lift to floor \(key)"
                    return
                }
            default: break
            }
        }
        if ["w", "a", "s", "d", "q", "e"].contains(key) || Self.arrowKeys.contains(key) {
            heldKeys.insert(key)
            return
        }
        if isRepeat { return }
        if destructionKey(key) { return }
        switch key {
        case " ": settings.paused.toggle()
        case "g": settings.giEnabled.toggle()
        case "m": settings.giMode = GIMode(rawValue: (settings.giMode.rawValue + 1) % GIMode.allCases.count) ?? .pathTraced
        case "b": settings.blueNoise.toggle()
        case "`": settings.solid.toggle()
        case "n": settings.denoiser.enabled.toggle()
        case "[", "]":
            let step = key == "[" ? -1 : 1
            if settings.giMode == .restirGI { settings.restirGI.bounces = RenderSettings.bounceRange.clamp(settings.restirGI.bounces + step) }
            else { settings.bounces = RenderSettings.bounceRange.clamp(settings.bounces + step) }
        case "-": settings.renderScale = max(RenderSettings.renderScaleRange.lowerBound, settings.renderScale - RenderSettings.renderScaleStep)
        case "=", "+": settings.renderScale = min(RenderSettings.renderScaleRange.upperBound, settings.renderScale + RenderSettings.renderScaleStep)
        case "1", "2", "3", "4", "5", "6", "7", "8": settings.viewMode = Int(key)! - 1
        case "9":   // cycle the geometry debug views
            let views = RenderSettings.geometryViews
            settings.viewMode = views.contains(settings.viewMode) && settings.viewMode < views.upperBound
                ? settings.viewMode + 1 : views.lowerBound
        case "0": settings.viewMode = 0
        case "l": settings.virtualGeometry.freeze.toggle()
        case "t":   // Reference: off, accumulated passes, path traced
            settings.reference.mode = ReferenceMode(rawValue: (settings.reference.mode.rawValue + 1) % ReferenceMode.allCases.count) ?? .off
        case "u":
            guard upscaleSupported else { print("The MetalFX denoiser is not supported on this GPU or system"); break }
            let steps = upscaleSteps
            settings.upscaleFactor = steps[((steps.firstIndex(of: settings.upscaleFactor) ?? 0) + 1) % steps.count]
        case "r": reloadShaders { if $0 { print("Shaders reloaded") } }
        case "f": frameSelection(lock: shiftHeld)
        default: break
        }
    }

    func keyUp(_ key: String) {
        heldKeys.remove(key)
        if key == "c" { crouchHeld = false }
    }

    /// Control: crouching, while walking.
    func setControl(_ held: Bool) { controlHeld = held }

    /// Shift: faster movement.
    func setShift(_ held: Bool) { shiftHeld = held }
    /// Option: a drag orbits the pivot (Option-right: dollies); in paint mode it turns the camera instead of painting.
    func setOption(_ held: Bool) { optionHeld = held }
    /// Command: Option-Command-drag pans (a trackpad's middle drag, as in Unity).
    func setCommand(_ held: Bool) { commandHeld = held }

    // The scene view's mouse, as Unity's: a click selects, Option-drag orbits the pivot, Option-Command-drag and a
    // middle drag pan, a drag or a right drag looks around (W A S D Q E fly while it is held), Option-right-drag and the
    // scroll wheel dolly; the arrows look around (Option: orbit). A press on a body grabs it (Physics.swift's `grab`).
    // Walking: a drag looks, a click uses.

    func mouseDown(at cursor: SIMD2<Float>) {
        if demolitionMouseDown() { return }
        // Paint mode: a stroke (Option: the camera turns about the object).
        if paintMouseDown(at: cursor, pressure: penPressure, orbit: optionHeld) { return }
        // Sculpt mode: a stroke of the terrain's brush (Option: the camera's, as always).
        if terrainMouseDown(at: cursor, pressure: penPressure, option: optionHeld, invert: controlHeld, smooth: shiftHeld) { return }
        holding = nil
        gizmoDrag = nil
        navDrag = nil
        leftLook = false
        navCursor = cursor
        if walker == nil, optionHeld {
            navDrag = commandHeld ? .pan : .orbit
            flight = nil
            return
        }
        // The VFX editor's handle: an arrow under the cursor is dragged along its axis.
        if let handle = gizmoHandle, let target = gizmoTarget, let emitter = target.emitter,
           let k = VFXGizmos.pick(handle: handle, cursor: cursor, camera: camera, aspect: viewAspect, size: gizmoViewSize) {
            var axis = SIMD3<Float>.zero
            axis[k] = 1
            let s = VFXGizmos.along(origin: handle, axis: axis, from: camera.position, dir: cursorRay(cursor))
            gizmoDrag = (axis, handle, s)
            onGizmoMoved?(target.effect, emitter, .zero, 0)
            return
        }
        clickAt = cursor
        leftLook = walker == nil
        guard scene.physics != nil, !destructionFires else { return }
        let direction = cursorRay(cursor)
        guard let pick = scene.withPhysics({ $0.pick(origin: camera.position, direction: direction) }), let hit = pick else { return }
        let point = camera.position + direction * hit.distance
        scene.physicsGrab = GPUPhysicsGrab(target: SIMD4(point, 1), anchor: SIMD4(hit.anchor, 0), body: UInt32(hit.body))
        holding = (cursor, dot(point - camera.position, camera.forward))
        leftLook = false
    }

    func mouseDragged(dx: Float, dy: Float, at cursor: SIMD2<Float>) {
        if paintMouseDragged(dx: dx, dy: dy, at: cursor, pressure: penPressure) { return }
        if terrainMouseDragged(at: cursor, pressure: penPressure) { return }
        if let drag = gizmoDrag {
            let s = VFXGizmos.along(origin: drag.origin, axis: drag.axis, from: camera.position, dir: cursorRay(cursor))
            let move = min(max(s - drag.last, -5), 5)
            gizmoDrag?.last = s
            if move != 0, let target = gizmoTarget, let emitter = target.emitter { onGizmoMoved?(target.effect, emitter, drag.axis * move, 1) }
            return
        }
        if let c = clickAt, length(c - cursor) > 0.004 { clickAt = nil }
        if holding != nil {
            holding?.cursor = cursor
            return
        }
        if let nav = navDrag {
            navigate(nav, dx: dx, dy: dy, at: cursor)
        } else if walker != nil {
            walkLook(dx: dx, dy: dy)
        } else if leftLook, clickAt == nil {   // (once it is a drag: a click doesn't turn the view)
            navigate(.look, dx: dx, dy: dy, at: cursor)
        }
    }

    /// Lets go: the body keeps its speed (a flick throws it).
    func mouseUp() {
        demolition.firing = false
        if paintMouseUp() { return }
        if terrainMouseUp() { return }
        if gizmoDrag != nil, let target = gizmoTarget, let emitter = target.emitter { onGizmoMoved?(target.effect, emitter, .zero, 2) }
        gizmoDrag = nil
        // A click (no drag): an armed pick's; while walking: use what is there; otherwise select what is there.
        if let c = clickAt, holding == nil, navDrag == nil {
            if pickArmed {
                pickRequest = c
                pickSelects = false
                pickArmed = false
            } else if destructionFires {
                fireDestruction(at: c)
            } else if walker != nil {
                use(cursorRay(c))
            } else {
                pickRequest = c
                pickSelects = true
            }
        }
        clickAt = nil
        navDrag = nil
        leftLook = false
        holding = nil
        if scene.physics != nil { scene.physicsGrab.target.w = 0 }
    }

    /// The right button: looks around, as a left drag does (Option: dollies); W A S D Q E fly while it is held. In
    /// paint mode the camera turns about the object.
    func rightMouseDown(at cursor: SIMD2<Float>) {
        if demolition.captured { detonateCharges(); return }
        if paintMouseDown(at: cursor, pressure: 1, orbit: true) { return }
        rightHeld = true
        rightDrag = walker == nil && optionHeld ? .dolly : .look
        navCursor = cursor
        flight = nil
    }
    func rightMouseDragged(dx: Float, dy: Float, at cursor: SIMD2<Float>) {
        if paintMouseDragged(dx: dx, dy: dy, at: cursor, pressure: 1) { return }
        if walker != nil { walkLook(dx: dx, dy: dy); return }
        navigate(rightDrag ?? .look, dx: dx, dy: dy, at: cursor)
    }
    func rightMouseUp() {
        rightHeld = false
        rightDrag = nil
        _ = paintMouseUp()
    }

    /// The middle button: pans.
    func otherMouseDown(at cursor: SIMD2<Float>) {
        navCursor = cursor
        flight = nil
    }
    func otherMouseDragged(dx: Float, dy: Float, at cursor: SIMD2<Float>) {
        guard walker == nil, painter.active == nil else { return }
        navigate(.pan, dx: dx, dy: dy, at: cursor)
    }

    /// A drag's step (`dx`, `dy`: in points; `cursor`: where it is now, 0...1 across and down).
    func navigate(_ nav: NavDrag, dx: Float, dy: Float, at cursor: SIMD2<Float>) {
        flight = nil
        switch nav {
        case .orbit:
            let p = pivot
            camera.orbit(dx: dx, dy: dy, about: p)
            pivot = p
        case .look:
            pivot = camera.look(dx: dx, dy: dy, pivot: pivot)
        case .pan:
            pivot = camera.pan(by: cursor - (navCursor ?? cursor), pivot: pivot, aspect: viewAspect)
            pivotLock = nil
        case .dolly:
            pivot = camera.dolly(by: exp((dy - dx) * 0.005), pivot: pivot)
        }
        navCursor = cursor
    }

    /// Walking: a drag turns the head.
    func walkLook(dx: Float, dy: Float) {
        camera.yaw += dx * Camera.turnRate
        camera.pitch = min(max(camera.pitch - dy * Camera.turnRate, -1.5), 1.5)
    }

    /// The scroll wheel: the held body nearer (down) or farther (up); a button that looks held: the fly speed; otherwise
    /// the camera nearer the pivot or farther.
    func scrolled(dy: Float) {
        if let depth = holding?.depth {
            holding?.depth = max(depth * exp(dy * 0.05), 0.3)
            return
        }
        guard walker == nil else { return }
        if lookHeld {
            settings.moveSpeed = RenderSettings.moveSpeedRange.clamp(settings.moveSpeed * exp(dy * 0.05))
            return
        }
        flight = nil
        pivot = camera.dolly(by: exp(dy * 0.05), pivot: pivot)
    }

    /// What the terrain's colliders write to (Renderer+Terrain.swift).
    var physicsGPUForTerrain: PhysicsGPU? { physicsGPU }
}
