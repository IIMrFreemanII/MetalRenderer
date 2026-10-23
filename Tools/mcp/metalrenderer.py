#!/usr/bin/env python3
"""An MCP server (stdio) for driving the running MetalRenderer app: Swift scripts run in it, its state, its frames.

Registered in the project's .mcp.json as `metalrenderer`. It talks to the app's script socket (Tools/mcp/client.py,
README "Scripts"), so it needs a running app: the user's window, or a headless one it can start itself
(`start_headless`: METALRENDERER_BENCH=serve, no window). No dependencies: JSON-RPC 2.0, one message a line.
"""
import base64
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import client  # noqa: E402

PROTOCOL = "2025-06-18"
BUILD = {"type": "string", "enum": sorted(client.BUILDS),
         "description": "The app of this build (Tools/build.sh: dev, Tools/release.sh: release); default: whichever runs."}

VEC3 = {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3, "description": "[x, y, z] in metres; y is up."}
ROTATION = {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 4,
            "description": "[x, y, z] in degrees (turned about y, then x, then z), or a quaternion [x, y, z, w]."}
SCALE = {"description": "A number, or [x, y, z].", "anyOf": [{"type": "number"}, VEC3]}
# The typed tools: the socket's SceneCommand by its key.
COMMANDS = {"place_object": "place", "move_object": "move", "remove_objects": "remove", "set_camera": "camera"}

TOOLS = [
    {
        "name": "run_swift",
        "description": (
            "Compile and run a Swift script inside the running MetalRenderer app, against its live engine (the package "
            "API). For one object or the camera, use place_object, move_object, remove_objects or set_camera instead "
            "(no compile); use a script for loops, procedural layouts and anything else in the engine (EngineCore, "
            "MetalRenderer and the system modules). Short form: plain statements, run on the render "
            "thread with `renderer: Renderer`, `scene: Scene` and `run: ScriptRun` in scope. Full form: declare "
            "`func run(_ run: ScriptRun)`, run on its own thread; `run.render { renderer in ... }` runs a closure on the "
            "render thread, `run.waitForScene()`, `run.wait(frames:)`, `run.onFrame { renderer, dt in }`, "
            "`run.capture()`. Change what a scene has with `renderer.editPlaced { file in ... }` (SceneFile objects: "
            "asset \"prefab:box|ball|quad\" or \"model:<path>\", name, position, rotation, scale, material; lights; "
            "camera), written to the scene's file at once. Settings: `renderer.settings` (RenderSettings), or "
            "`SettingsEnv.apply(.view, to: &renderer.settings, from: [\"METALRENDERER_VIEW\": \"solid=1\"])`. "
            "Switch scene: `renderer.settings.scene.kind = SceneRegistry.kind(named: \"stage\")!`. The `stage` scene is "
            "an empty floor to build on. The Modeller: the modeller tool, or `run.modeller` in a full-form script "
            "(import Editors, Modeling). Returns the script's output and exit status (0 done, 1 failed, 2 compile "
            "error). A trap in the script crashes the app.")
        ,
        "inputSchema": {
            "type": "object",
            "properties": {
                "code": {"type": "string", "description": "The script's Swift code."},
                "path": {"type": "string", "description": "A .swift file to run instead of `code`."},
                "args": {"type": "array", "items": {"type": "string"}, "description": "ScriptRun.arguments."},
                "capture": {"type": "boolean", "description": "Also return the frame after the script (default false)."},
                "scale": {"type": "number", "description": "With capture: the picture's size, times the frame's (default 0.5)."},
                "build": BUILD,
            },
        },
    },
    {
        "name": "scene_state",
        "description": ("The app's state as JSON: the scene asked for and the one loaded, the scenes there are, the camera, "
                        "the clock, counts of meshes/instances/lights, the scene file's objects and lights, the named "
                        "materials and prefabs a scene file can use, and every setting by METALRENDERER_* list and key."),
        "inputSchema": {"type": "object", "properties": {"build": BUILD}},
    },
    {
        "name": "capture",
        "description": "The app's next frame as a PNG image (also saved under <build>/scripts/captures).",
        "inputSchema": {"type": "object", "properties": {
            "scale": {"type": "number", "description": "The picture's size, times the frame's (default 0.5)."},
            "build": BUILD}},
    },
    {
        "name": "switch_scene",
        "description": "Load another scene by its name (scene_state lists them) and wait until it is in.",
        "inputSchema": {"type": "object", "required": ["name"], "properties": {"name": {"type": "string"}, "build": BUILD}},
    },
    {
        "name": "set_settings",
        "description": ("Set settings by a METALRENDERER_* list and its key=value items, e.g. list 'view', items "
                        "'solid=1,tod=18' (scene_state's settings show the lists and keys)."),
        "inputSchema": {"type": "object", "required": ["list", "items"], "properties": {
            "list": {"type": "string"}, "items": {"type": "string"}, "build": BUILD}},
    },
    {
        "name": "place_object",
        "description": ("Place an object in the scene's file (no compile): an asset (prefab:box, prefab:ball, prefab:quad, "
                        "a scene's own prefab, model:<path under Assets>) at a position, with a rotation, scale and a "
                        "named material (scene_state lists prefabs and namedMaterials). An object of the same name is "
                        "replaced, so placing again updates it. Written to the scene's .scene file at once."),
        "inputSchema": {"type": "object", "required": ["asset", "name"], "properties": {
            "asset": {"type": "string"}, "name": {"type": "string"}, "position": VEC3,
            "rotation": ROTATION, "scale": SCALE, "material": {"type": "string"},
            "parent": {"type": "string", "description": "The name of the object it hangs from: its position, rotation and scale are then in the parent's space (a parent's scale applies to it)."},
            "build": BUILD}},
    },
    {
        "name": "move_object",
        "description": "Move, turn or scale an object of the scene's file by its name; applied live, without a new scene.",
        "inputSchema": {"type": "object", "required": ["name"], "properties": {
            "name": {"type": "string"}, "position": VEC3, "rotation": ROTATION, "scale": SCALE, "build": BUILD}},
    },
    {
        "name": "remove_objects",
        "description": "Remove objects of the scene's file by name or name prefix, with what hangs from them.",
        "inputSchema": {"type": "object", "properties": {
            "names": {"type": "array", "items": {"type": "string"}}, "prefix": {"type": "string"}, "build": BUILD}},
    },
    {
        "name": "set_camera",
        "description": "Place the camera: a position, and where it looks (lookAt) or its yaw and pitch in degrees; the field of view in degrees.",
        "inputSchema": {"type": "object", "properties": {
            "position": VEC3, "lookAt": VEC3,
            "yaw": {"type": "number", "description": "Degrees; 0 looks down -Z."}, "pitch": {"type": "number", "description": "Degrees; negative looks down."},
            "fov": {"type": "number"}, "build": BUILD}},
    },
    {
        "name": "modeller",
        "description": (
            "Drive the app's Modeller (the Blender-like modelling and sculpting editor) as a user would, offscreen: a "
            "Modeller of its own in the app (headless or the window's), never the user's Modeller window. The steps run "
            "in order; then its state (mode, selection, the operator running and its hints, the popup or F3 search "
            "open, every object's vertex/edge/face counts, selection, modifiers, bounds; sculpt mode's mesh) and a "
            "picture: 'viewport' (its raster viewport), 'window' (the whole window with its panels, as AppKit draws "
            "it) or 'rendered' (the Rendered view's path-traced stage; {\"shading\": \"rendered\"} first). The "
            "Modeller lasts between calls until {\"close\": true}; it starts with Blender's cube. Points are the "
            "viewport's, in points from its top left (1000 x 640 by default; the centre is [500, 320]). Keys are "
            "Blender's (README, Modeller), Mac style: tool keys with ctrl+, app keys with cmd+ (cmd+z undo). For "
            "anything the steps don't reach, a full-form run_swift script has `run.modeller` (import Editors, Modeling): "
            "keys(), click(), drag(), run(), pick(), document, edit {}, capture().")
        ,
        "inputSchema": {
            "type": "object",
            "properties": {
                "steps": {
                    "type": "array",
                    "description": (
                        "Each step an object of one key: "
                        "{\"keys\": \"tab 3 ctrl+r shift+a f3\"} chords through the keymap (ctrl+ shift+ alt+ cmd+; "
                        "tab return esc space backspace delete up down left right f1-f4 numpad0-9 home `); "
                        "{\"type\": \"1.5\"} each character a key (typed values; F3's query while it is open); "
                        "{\"click\": [x, y], \"button\": \"left|right|middle\", \"mods\": \"shift ctrl alt cmd\", "
                        "\"count\": 2}; {\"drag\": [[x, y], ...], \"button\", \"mods\", \"pressure\": [p, ...], "
                        "\"steps\": n (moves per stretch)} press, moves, release (box select, gizmos, sculpt strokes); "
                        "{\"move\": [x, y]} the mouse (modal operators follow it); {\"scroll\": dy, \"at\": [x, y]}; "
                        "{\"run\": \"Bridge Edge Loops\"} an operator of the mode's menus by name or path (F3's list); "
                        "{\"pick\": \"At Center\"} an item of the popup the last key opened (w, x, m, shift+a); "
                        "{\"add\": \"cube|plane|circle|uvSphere|icoSphere|cylinder|cone|torus|grid|head\"}; "
                        "{\"mode\": \"object|edit|sculpt\"}; {\"selectMode\": \"vertex|edge|face\"}; "
                        "{\"tool\": \"select|move|extrude|knife|...\"}; "
                        "{\"shading\": \"wireframe|solid|matcap|rendered\"}; "
                        "{\"workspace\": \"layout|modeling|sculpting|uv\"}; {\"brush\": \"draw|clay|...\"}; "
                        "{\"open\": {\"primitive\": \"cube\"} | {\"asset\": slug} | {\"file\": path} | "
                        "{\"selection\": true}}; {\"new\": true}; {\"save\": \"Name\"} (into the asset library: "
                        "Assets/Models, or METALRENDERER_MODELS); {\"place\": true} (the saved model into the app's "
                        "scene as mesh:<slug>); {\"size\": [w, h]}; {\"wait\": seconds}; {\"close\": true}. A point is "
                        "[x, y] in the viewport or {\"world\": [x, y, z]}, where the camera shows it."),
                    "items": {"type": "object"},
                },
                "capture": {"type": "string", "enum": ["viewport", "window", "rendered"],
                            "description": "A picture after the steps (default: none)."},
                "scale": {"type": "number", "description": "The picture's size, times its pixels (default 0.5)."},
                "state": {"type": "boolean", "description": "Return the state too (default true)."},
                "build": BUILD,
            },
        },
    },
    {
        "name": "start_headless",
        "description": ("Start a MetalRenderer app without a window (METALRENDERER_BENCH=serve) for the other tools to "
                        "drive, and wait for it. Use when no app runs; the user's window is never opened."),
        "inputSchema": {"type": "object", "properties": {
            "build": {"type": "string", "enum": sorted(client.BUILDS), "description": "Default: release."},
            "scene": {"type": "string", "description": "The scene it opens (default: stage)."}}},
    },
    {
        "name": "quit_headless",
        "description": "Quit a headless app (a window's app is never quit).",
        "inputSchema": {"type": "object", "properties": {"build": BUILD}},
    },
]


def text(t, error=False):
    return {"content": [{"type": "text", "text": t}], "isError": error}


def picture(build, scale):
    folder = os.path.join(client.scratch(build or "release"), "scripts", "captures")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "capture-%d.png" % int(time.time() * 1000))
    status, message = client.capture(path, scale, build)
    if status != 0:
        return None, message or "no capture"
    with open(path, "rb") as f:
        return {"type": "image", "data": base64.b64encode(f.read()).decode(), "mimeType": "image/png"}, path


def swift_string(s):
    return json.dumps(s)   # a JSON string is a valid Swift string literal for plain text


def run_code(code, build, args=()):
    path = client.inline_script(code, build)
    return client.run_script(path, args, build, timeout=900)


def call(name, a):
    build = a.get("build")
    if name == "run_swift":
        if a.get("path"):
            status, out = client.run_script(a["path"], a.get("args", []), build, timeout=900)
        elif a.get("code") is not None:
            status, out = run_code(a["code"], build, a.get("args", []))
        else:
            return text("run_swift needs `code` or `path`", True)
        result = text("%s\n(exit %d)" % (out.rstrip(), status), status != 0)
        if a.get("capture") and status != 2:
            image, where = picture(build, a.get("scale", 0.5))
            if image:
                result["content"] += [image, {"type": "text", "text": where}]
            else:
                result["content"].append({"type": "text", "text": "capture: " + where})
        return result
    if name in COMMANDS:
        body = {k: v for k, v in a.items() if k != "build"}
        status, result = client.command(COMMANDS[name], body, build)
        return text(json.dumps(result) if isinstance(result, dict) else result.rstrip(), status != 0)
    if name == "modeller":
        folder = os.path.join(client.scratch(build or "release"), "scripts", "captures")
        os.makedirs(folder, exist_ok=True)
        view = a.get("capture")
        path = os.path.join(folder, "modeller-%s-%d.png" % (view, int(time.time() * 1000))) if view else None
        status, result = client.modeller(a.get("steps", []), view, a.get("scale", 0.5), path, build, a.get("state", True))
        if not isinstance(result, dict):
            return text("%s\n(exit %d)" % (result.rstrip(), status), True)
        notes = ["%d. %s" % (k + 1, n) for k, n in enumerate(result.get("steps", [])) if n]
        body = "\n".join(notes + ([json.dumps(result["state"], indent=1)] if "state" in result else []))
        content = [{"type": "text", "text": body or "done"}]
        if result.get("capture"):
            with open(result["capture"], "rb") as f:
                content += [{"type": "image", "data": base64.b64encode(f.read()).decode(), "mimeType": "image/png"},
                            {"type": "text", "text": result["capture"]}]
        return {"content": content, "isError": False}
    if name == "scene_state":
        return text(json.dumps(client.state(build), indent=1))
    if name == "capture":
        image, where = picture(build, a.get("scale", 0.5))
        return {"content": [image, {"type": "text", "text": where}], "isError": False} if image else text(where, True)
    if name == "switch_scene":
        code = ("guard let kind = SceneRegistry.kind(named: %s) else { print(\"no scene named \\(%s); the scenes: "
                "\\(SceneRegistry.kinds.map(\\.envName))\"); run.fail(\"unknown scene\"); return }\n"
                "var s = renderer.settings\ns.scene.kind = kind\ns.scene.extraModels = []\n"
                "s.applySceneDefaults(from: renderer.defaultSettings)\nrenderer.settings = s\n"
                % (swift_string(a["name"]), swift_string(a["name"])))
        status, out = run_code(code, build)
        return text("%s\n(exit %d)" % (out.rstrip(), status), status != 0)
    if name == "set_settings":
        variable = "METALRENDERER_" + a["list"].upper()
        code = ("guard let list = EnvVariable(rawValue: %s) else { run.fail(\"no list %s\"); return }\n"
                "SettingsEnv.apply(list, to: &renderer.settings, interactive: true, from: [%s: %s])\n"
                % (swift_string(variable), variable, swift_string(variable), swift_string(a["items"])))
        status, out = run_code(code, build)
        return text("%s\n(exit %d)" % (out.rstrip(), status), status != 0)
    if name == "start_headless":
        try:
            client.connect(a.get("build"))
            return text("an app is already running; the tools use it")
        except client.NoApp:
            pass
        pid, log = client.start_headless(a.get("build") or "release", a.get("scene"))
        return text("headless app %d is up; its output: %s" % (pid, log))
    if name == "quit_headless":
        status, message = client.quit_app(build)
        return text(message or "quit", status != 0)
    return text("unknown tool %s" % name, True)


def handle(message):
    method, mid = message.get("method"), message.get("id")
    if method == "initialize":
        version = message.get("params", {}).get("protocolVersion", PROTOCOL)
        return {"protocolVersion": version, "capabilities": {"tools": {}},
                "serverInfo": {"name": "metalrenderer", "version": "1.0"},
                "instructions": "Drive the running MetalRenderer app: run_swift, scene_state, capture. "
                                "If no app runs, start_headless (never open the user's window)."}
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "tools/call":
        params = message.get("params", {})
        try:
            return call(params.get("name"), params.get("arguments") or {})
        except client.NoApp as e:
            return text(str(e), True)
        except Exception as e:  # a tool's failure is the tool's answer, not the server's
            return text("%s: %s" % (type(e).__name__, e), True)
    if method == "ping":
        return {}
    if mid is not None:
        raise KeyError(method)
    return None


def main():
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        mid = message.get("id")
        try:
            result = handle(message)
            if mid is None:
                continue   # a notification
            reply = {"jsonrpc": "2.0", "id": mid, "result": result}
        except KeyError as e:
            reply = {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown method %s" % e}}
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
