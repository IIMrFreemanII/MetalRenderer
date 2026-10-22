"""The running app's script socket (Sources/MetalRenderer/Scripting/ScriptServer.swift), for Tools/script.py and the
MCP server (Tools/mcp/metalrenderer.py).

The app writes its socket's path to <scratch>/script.socket, <scratch> being the folder of the build it runs from
(.build-dev for Tools/build.sh, .build for Tools/release.sh). A request is one JSON line; the answers are JSON lines
until {"exit": n}.
"""
import json
import os
import socket
import subprocess
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUILDS = {"dev": ".build-dev", "release": ".build"}
BINARIES = {"dev": ".build-dev/debug/MetalRenderer", "release": ".build/release/MetalRenderer"}


class NoApp(Exception):
    pass


def scratch(build):
    return os.path.join(REPO, BUILDS[build])


def _pointer(build):
    return os.path.join(scratch(build), "script.socket")


def _connect(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
    except OSError:
        s.close()
        return None
    return s


def connect(build=None):
    """A connection to the running app of `build` ('dev', 'release'), or of whichever runs (the newest first)."""
    builds = [build] if build else sorted(BUILDS, key=lambda b: -_mtime(_pointer(b)))
    for b in builds:
        try:
            with open(_pointer(b)) as f:
                path = f.read().strip()
        except OSError:
            continue
        s = _connect(path)
        if s:
            return s
    where = " or ".join(_pointer(b) for b in builds)
    raise NoApp("no running MetalRenderer app with scripts (no live socket in %s). Start the app, or a headless one: "
                "METALRENDERER_BENCH=serve %s" % (where, os.path.join(REPO, BINARIES[build or "release"])))


def _mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0


def request(message, build=None, on_message=None, timeout=None):
    """Sends `message` and reads the answers: calls `on_message` with each, returns (exit status, answers)."""
    s = connect(build)
    s.settimeout(timeout)
    answers = []
    try:
        s.sendall((json.dumps(message) + "\n").encode())
        buffer = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if not line.strip():
                    continue
                answer = json.loads(line)
                answers.append(answer)
                if on_message:
                    on_message(answer)
                if "exit" in answer:
                    return answer["exit"], answers
    finally:
        s.close()
    return 2, answers + [{"out": "the app closed the connection\n"}]


def inline_script(code, build=None):
    """`code` saved as a script file the app can read: <scratch>/scripts/inline-<time>.swift."""
    folder = os.path.join(scratch(build or "release"), "scripts")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "inline-%d.swift" % int(time.time() * 1000))
    with open(path, "w") as f:
        f.write(code if code.endswith("\n") else code + "\n")
    return path


def run_script(path, args=(), build=None, on_out=None, timeout=None):
    """Runs the script at `path`; returns (exit status, its output)."""
    out = []

    def got(answer):
        if "out" in answer:
            out.append(answer["out"])
            if on_out:
                on_out(answer["out"])

    status, _ = request({"path": os.path.abspath(path), "args": list(args)}, build, got, timeout)
    return status, "".join(out)


def state(build=None):
    status, answers = request({"state": True}, build, timeout=30)
    for a in answers:
        if "state" in a:
            return a["state"]
    raise NoApp("".join(a.get("out", "") for a in answers) or "no state")


def capture(path, scale=1.0, build=None):
    """The next frame as a PNG at `path`; returns (exit status, message)."""
    status, answers = request({"capture": os.path.abspath(path), "scale": scale}, build, timeout=30)
    return status, "".join(a.get("out", "") for a in answers)


def command(name, body, build=None):
    """A typed scene command (SceneCommand: place, move, remove, camera), no compile; returns (exit status, the
    app's result or its message)."""
    status, answers = request({name: body}, build, timeout=120)
    for a in answers:
        if "result" in a:
            return status, a["result"]
    return status, "".join(a.get("out", "") for a in answers)


def quit_app(build=None):
    status, answers = request({"quit": True}, build, timeout=10)
    return status, "".join(a.get("out", "") for a in answers)


def start_headless(build="release", scene=None, timeout=180):
    """Starts a headless app (METALRENDERER_BENCH=serve, no window) from `build` and waits for its socket; returns
    (pid, log path)."""
    binary = os.path.join(REPO, BINARIES[build])
    if not os.path.exists(binary):
        raise NoApp("no %s: build it first (%s)" % (binary, "Tools/build.sh" if build == "dev" else "Tools/release.sh"))
    log = os.path.join(scratch(build), "scripts", "serve.log")
    os.makedirs(os.path.dirname(log), exist_ok=True)
    env = dict(os.environ, METALRENDERER_BENCH="serve")
    env.pop("METALRENDERER_WINDOW", None)
    if scene:
        env["METALRENDERER_SCENE"] = scene
    with open(log, "w") as f:
        process = subprocess.Popen([binary], cwd=REPO, env=env, stdout=f, stderr=subprocess.STDOUT,
                                   start_new_session=True)
    wanted = "/tmp/metalrenderer-%d/%d.sock" % (os.getuid(), process.pid)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if process.poll() is not None:
            raise NoApp("the app quit (status %d); its output is in %s" % (process.returncode, log))
        s = _connect(wanted) if os.path.exists(wanted) else None
        if s:
            s.close()
            return process.pid, log
        time.sleep(0.25)
    raise NoApp("no socket after %d s; the app's output is in %s" % (timeout, log))
