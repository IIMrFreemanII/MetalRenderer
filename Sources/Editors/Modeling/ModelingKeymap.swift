import AppKit
import Foundation
import Modeling

/// A key with its modifiers, as the keymap names it: "g", "tab", "delete", "esc", "return", "space", "home",
/// "numpad1" …, "f3"; Ctrl, Shift, Alt (Option), Cmd.
struct KeyChord: Hashable, CustomStringConvertible {
    var key: String
    var ctrl = false
    var shift = false
    var alt = false
    var cmd = false

    init(_ key: String, ctrl: Bool = false, shift: Bool = false, alt: Bool = false, cmd: Bool = false) {
        self.key = key
        self.ctrl = ctrl
        self.shift = shift
        self.alt = alt
        self.cmd = cmd
    }

    /// The chord of a key event (nil for one the keymap has no name for). With `emulateNumpad` the number row is the
    /// numpad (Blender's Emulate Numpad, for keyboards without one).
    init?(_ event: NSEvent, emulateNumpad: Bool = false) {
        let f = event.modifierFlags
        ctrl = f.contains(.control)
        shift = f.contains(.shift)
        alt = f.contains(.option)
        cmd = f.contains(.command)
        switch event.keyCode {
        case 48: key = "tab"
        case 51: key = "backspace"
        case 117: key = "delete"
        case 53: key = "esc"
        case 36: key = "return"
        case 76: key = "numpadenter"
        case 49: key = "space"
        case 115: key = "home"
        case 119: key = "end"
        case 116: key = "pageup"
        case 121: key = "pagedown"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 50: key = "`"
        case 122: key = "f1"
        case 120: key = "f2"
        case 99: key = "f3"
        case 118: key = "f4"
        // The numpad's keys.
        case 82: key = "numpad0"
        case 83: key = "numpad1"
        case 84: key = "numpad2"
        case 85: key = "numpad3"
        case 86: key = "numpad4"
        case 87: key = "numpad5"
        case 88: key = "numpad6"
        case 89: key = "numpad7"
        case 91: key = "numpad8"
        case 92: key = "numpad9"
        case 65: key = "numpad."
        case 69: key = "numpad+"
        case 78: key = "numpad-"
        case 67: key = "numpad*"
        case 75: key = "numpad/"
        default:
            guard let c = event.charactersIgnoringModifiers?.lowercased(), !c.isEmpty else { return nil }
            // Shifted symbols come back as their unshifted keys (Shift-1 is "1" with shift).
            let unshifted: [String: String] = ["!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
                                               "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "~": "`", "?": "/",
                                               ">": ".", "<": ","]
            key = unshifted[c] ?? c
        }
        if emulateNumpad, key.count == 1, let d = Int(key), (0...9).contains(d) { key = "numpad\(d)" }
    }

    var description: String {
        var s = ""
        if cmd { s += "⌘" }
        if ctrl { s += "Ctrl " }
        if alt { s += "Alt " }
        if shift { s += "Shift " }
        let names = ["tab": "Tab", "delete": "Delete", "backspace": "Backspace", "esc": "Esc", "return": "Return", "space": "Space",
                     "home": "Home", "numpad.": "Numpad .", "numpadenter": "Enter"]
        if let n = names[key] { return s + n }
        if key.hasPrefix("numpad") { return s + "Numpad " + key.dropFirst(6) }
        return s + key.uppercased()
    }
}

/// What a key does (Blender's keymap): one action per chord and mode.
enum ModelingAction: Equatable {
    // Anywhere.
    case undo, redo, save
    case toggleEditMode, modeMenu, setSelectMode(SelectMode)
    case toggleToolbar, toggleSidebar
    case addMenu, snapMenu, shadingMenu, viewMenu, contextMenu
    case toggleXray, toggleWireframe
    case view(ViewportCamera.AlignedView), toggleOrtho, orbitStep(yaw: Float, pitch: Float), zoomStep(Float)
    case frameSelected, frameAll, cursorReset
    case selectAll, deselectAll, invertSelection, boxSelect, circleSelect
    case grab, rotate, scale, clearLocation, clearRotation, clearScale
    case delete(menu: Bool), duplicate, hide(selected: Bool), reveal
    case search
    // Object mode.
    case join, applyMenu, subdivisionLevel(Int), shadeSmooth, shadeFlat
    // Edit mode.
    case extrude, extrudeMenu, inset, bevel(vertices: Bool), loopCut, knife, fill, connect, merge, separate
    case slide, bridge, spin
    case selectLinked(pick: Bool), selectMore, selectLess
    case edgeMenu, faceMenu, vertexMenu, normalsMenu, recalcNormals, uvMenu
    case triangulate, trisToQuads, toggleProportional, splitFaces
    // Sculpt mode.
    case brush(String), brushRadius, brushStrength, brushSize(Float), toggleDyntopo, voxelRemesh, voxelSize
    case maskMenu, clearMask, invertMask, faceSetsMenu, toggleMaskEdit
}

enum ModelingKeymap {
    /// The action of a chord in a mode, nil if none.
    static func action(for k: KeyChord, mode: EditorMode) -> ModelingAction? {
        // ⌘ first: the app's.
        if k.cmd {
            switch (k.key, k.shift) {
            case ("z", false): return .undo
            case ("z", true): return .redo
            case ("s", _): return .save
            default: return nil
            }
        }
        if let a = common(k, mode: mode) { return a }
        switch mode {
        case .object: return object(k)
        case .edit: return edit(k)
        case .sculpt: return sculpt(k)
        }
    }

    private static func common(_ k: KeyChord, mode: EditorMode) -> ModelingAction? {
        switch (k.key, k.ctrl, k.shift, k.alt) {
        case ("tab", false, false, false): return mode == .sculpt ? .modeMenu : .toggleEditMode
        case ("tab", true, false, false): return .modeMenu
        case ("t", false, false, false) where mode != .sculpt: return .toggleToolbar
        case ("t", true, false, false) where mode == .sculpt: return .toggleToolbar
        case ("n", false, false, false): return .toggleSidebar
        case ("a", false, true, false) where mode != .sculpt: return .addMenu
        case ("s", false, true, false) where mode != .sculpt: return .snapMenu
        case ("z", false, false, false) where mode != .sculpt: return .shadingMenu
        case ("z", false, false, true): return .toggleXray
        case ("z", false, true, false): return .toggleWireframe
        case ("`", false, false, false): return .viewMenu
        case ("numpad1", let c, _, _): return .view(c ? .back : .front)
        case ("numpad3", let c, _, _): return .view(c ? .left : .right)
        case ("numpad7", let c, _, _): return .view(c ? .bottom : .top)
        case ("numpad5", _, _, _): return .toggleOrtho
        case ("numpad4", _, _, _): return .orbitStep(yaw: -.pi / 12, pitch: 0)
        case ("numpad6", _, _, _): return .orbitStep(yaw: .pi / 12, pitch: 0)
        case ("numpad8", _, _, _): return .orbitStep(yaw: 0, pitch: .pi / 12)
        case ("numpad2", _, _, _): return .orbitStep(yaw: 0, pitch: -.pi / 12)
        case ("numpad+", _, _, _), ("=", true, _, _): return .zoomStep(0.8)
        case ("numpad-", _, _, _): return .zoomStep(1.25)
        case ("numpad.", _, _, _): return .frameSelected
        case ("home", _, _, _): return .frameAll
        case ("c", false, true, false): return .cursorReset
        case ("f3", _, _, _): return .search
        default: return nil
        }
    }

    private static func selection(_ k: KeyChord) -> ModelingAction? {
        switch (k.key, k.ctrl, k.shift, k.alt) {
        case ("a", false, false, false): return .selectAll
        case ("a", false, false, true): return .deselectAll
        case ("i", true, false, false): return .invertSelection
        case ("b", false, false, false): return .boxSelect
        case ("c", false, false, false): return .circleSelect
        case ("g", false, false, false): return .grab
        case ("r", false, false, false): return .rotate
        case ("s", false, false, false): return .scale
        case ("x", false, false, false): return .delete(menu: true)
        case ("delete", false, false, false), ("backspace", false, false, false): return .delete(menu: false)
        case ("d", false, true, false): return .duplicate
        case ("h", false, false, false): return .hide(selected: true)
        case ("h", false, true, false): return .hide(selected: false)
        case ("h", false, false, true): return .reveal
        default: return nil
        }
    }

    private static func object(_ k: KeyChord) -> ModelingAction? {
        if let s = selection(k) { return s }
        switch (k.key, k.ctrl, k.shift, k.alt) {
        case ("g", false, false, true): return .clearLocation
        case ("r", false, false, true): return .clearRotation
        case ("s", false, false, true): return .clearScale
        case ("j", true, false, false): return .join
        case ("a", true, false, false): return .applyMenu
        case ("0", true, false, false), ("1", true, false, false), ("2", true, false, false), ("3", true, false, false),
             ("4", true, false, false), ("5", true, false, false):
            return .subdivisionLevel(Int(k.key)!)
        case ("w", false, false, false), ("space", false, false, false): return nil
        default: return nil
        }
    }

    private static func edit(_ k: KeyChord) -> ModelingAction? {
        if let s = selection(k) { return s }
        switch (k.key, k.ctrl, k.shift, k.alt) {
        case ("1", false, false, false): return .setSelectMode(.vertex)
        case ("2", false, false, false): return .setSelectMode(.edge)
        case ("3", false, false, false): return .setSelectMode(.face)
        case ("e", false, false, false): return .extrude
        case ("e", false, false, true): return .extrudeMenu
        case ("i", false, false, false): return .inset
        case ("b", true, false, false): return .bevel(vertices: false)
        case ("b", true, true, false): return .bevel(vertices: true)
        case ("r", true, false, false): return .loopCut
        case ("k", false, false, false): return .knife
        case ("f", false, false, false): return .fill
        case ("j", false, false, false): return .connect
        case ("v", false, true, false): return .slide
        case ("m", false, false, false): return .merge
        case ("p", false, false, false): return .separate
        case ("y", false, false, false): return .splitFaces
        case ("l", false, false, false): return .selectLinked(pick: true)
        case ("l", true, false, false): return .selectLinked(pick: false)
        case ("=", true, false, false), ("numpad+", true, false, false): return .selectMore
        case ("-", true, false, false), ("numpad-", true, false, false): return .selectLess
        case ("e", true, false, false): return .edgeMenu
        case ("f", true, false, false): return .faceMenu
        case ("v", true, false, false): return .vertexMenu
        case ("n", false, false, true): return .normalsMenu
        case ("n", false, true, false): return .recalcNormals
        case ("u", false, false, false): return .uvMenu
        case ("t", true, false, false): return .triangulate
        case ("j", false, false, true): return .trisToQuads
        case ("o", false, false, false): return .toggleProportional
        default: return nil
        }
    }

    private static func sculpt(_ k: KeyChord) -> ModelingAction? {
        switch (k.key, k.ctrl, k.shift, k.alt) {
        case ("x", false, false, false): return .brush("draw")
        case ("c", false, false, false): return .brush("clayStrips")
        case ("i", false, false, false): return .brush("inflate")
        case ("g", false, false, false): return .brush("grab")
        case ("s", false, false, false): return .brush("smooth")
        case ("c", false, true, false): return .brush("crease")
        case ("p", false, false, false): return .brush("pinch")
        case ("t", false, true, false): return .brush("flatten")
        case ("m", false, false, false): return .brush("mask")
        case ("f", false, false, false): return .brushRadius
        case ("f", false, true, false): return .brushStrength
        case ("[", false, false, false): return .brushSize(1 / 1.2)
        case ("]", false, false, false): return .brushSize(1.2)
        case ("d", true, false, false): return .toggleDyntopo
        case ("r", true, false, false): return .voxelRemesh
        case ("r", false, false, false): return .voxelSize
        case ("a", false, false, false): return .maskMenu
        case ("m", false, false, true): return .clearMask
        case ("i", true, false, false): return .invertMask
        case ("w", false, true, false): return .faceSetsMenu
        case ("h", false, false, false): return .hide(selected: true)
        case ("h", false, false, true): return .reveal
        case ("numpad.", _, _, _): return .frameSelected
        default: return nil
        }
    }

    /// The status bar's hints for a mode: what the mouse buttons do.
    static func hints(_ mode: EditorMode) -> [(String, String)] {
        switch mode {
        case .object, .edit: [("LMB", "Select"), ("MMB", "Rotate View"), ("RMB", "Context Menu"), ("Shift-A", "Add"), ("Tab", "Mode")]
        case .sculpt: [("LMB", "Sculpt"), ("Ctrl", "Invert"), ("Shift", "Smooth"), ("F", "Radius"), ("MMB", "Rotate View")]
        }
    }
}
