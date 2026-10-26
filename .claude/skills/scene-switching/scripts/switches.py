#!/usr/bin/env python3
"""Scene switches in a headless app (no window), as the window makes them, and what went wrong in each step.

  switches.py [--saved] [--build dev|release] [-o <folder>] [--env KEY=VALUE ...] [steps ...]

Starts its own headless app (METALRENDERER_BENCH=serve, METALRENDERER_RESIDENCY_LIFE=16 so that a resource a frame
reaches without declaring it faults within the run), runs Scripts/scene-switches.swift through that app's socket (never
another app's, so the user's window is left alone), quits it, then reads its log step by step. Steps: tour pairs midload
remake jump stale (all by default). --saved runs with the window's saved settings (UserDefaults' renderSettings), which
is where the 2026-10 timeout showed. Exit status 0 when every step is clean.

A step fails on: a Metal command buffer that failed, an interlude whose wait gave up, physics that had to catch up over
frames (outside `jump` and `slow`), a scene load that failed, a FAIL line of the script's, the app quitting, or a pair of `stale`
pictures further apart than noise.
"""
import argparse
import base64
import json
import os
import plistlib
import re
import socket
import struct
import subprocess
import sys
import time

REPO = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                      cwd=os.path.dirname(os.path.abspath(__file__))).stdout.strip()
BINARIES = {"dev": ".build-dev/debug/MetalRenderer", "release": ".build/release/MetalRenderer"}
FAILURES = [
    (re.compile(r"command buffer \S+ failed"), "GPU"),
    (re.compile(r"took over \d+ ms; committing"), "interlude wait"),
    (re.compile(r"Physics: \d+ steps behind"), "catch-up"),
    (re.compile(r"Scene (load|rebuild) failed"), "load"),
    (re.compile(r"^FAIL "), "check"),
    (re.compile(r"PageFault|Fatal error|fatal error"), "fault"),
]
STALE_DB = 30.0   # the same picture of a paused scene, before and after a detour: noise stays far above this


def saved_settings(folder):
    """The window's saved RenderSettings (UserDefaults, domain MetalRenderer) as a JSON file."""
    out = subprocess.run(["defaults", "export", "MetalRenderer", "-"], capture_output=True)
    if out.returncode != 0:
        sys.exit("no saved settings (defaults export MetalRenderer failed)")
    data = plistlib.loads(out.stdout).get("renderSettings")
    if data is None:
        sys.exit("the saved defaults have no renderSettings")
    path = os.path.join(folder, "saved-settings.json")
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else base64.b64decode(data))
    return path


def request(sock_path, message, timeout=None):
    """One request on the app's socket; returns (exit status, the script's output)."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.settimeout(timeout)
    out, buffer = [], b""
    try:
        s.sendall((json.dumps(message) + "\n").encode())
        while True:
            chunk = s.recv(65536)
            if not chunk:
                return 2, "".join(out)
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if line.strip():
                    answer = json.loads(line)
                    if "out" in answer:
                        out.append(answer["out"])
                        sys.stdout.write(answer["out"])
                        sys.stdout.flush()
                    if "exit" in answer:
                        return answer["exit"], "".join(out)
    finally:
        s.close()


def bmp_pixels(png):
    """A PNG's pixels (rows of RGB bytes), through sips' BMP: numpy-free, Pillow-free."""
    bmp = png[:-4] + ".bmp"
    subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp], capture_output=True)
    with open(bmp, "rb") as f:
        data = f.read()
    offset, = struct.unpack_from("<I", data, 10)
    width, height = struct.unpack_from("<ii", data, 18)
    bpp, = struct.unpack_from("<H", data, 28)
    step = bpp // 8
    row = (width * step + 3) & ~3
    return width, abs(height), [data[offset + y * row: offset + y * row + width * step] for y in range(abs(height))], step


def psnr(a, b):
    wa, ha, ra, sa = bmp_pixels(a)
    wb, hb, rb, sb = bmp_pixels(b)
    if (wa, ha) != (wb, hb):
        return 0.0
    total, count = 0, 0
    for x, y in zip(ra, rb):
        for i in range(0, len(x), sa):
            for c in range(3):
                d = x[i + c] - y[i + c]
                total += d * d
            count += 3
    mse = total / max(count, 1)
    return 99.0 if mse == 0 else 10 * __import__("math").log10(255 * 255 / mse)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("steps", nargs="*")
    p.add_argument("--saved", action="store_true", help="run with the window's saved settings")
    p.add_argument("--build", choices=BINARIES, default="dev")
    p.add_argument("-o", "--out", default=os.path.join(os.environ.get("TMPDIR", "/tmp"), "scene-switches"))
    p.add_argument("--env", action="append", default=[], help="KEY=VALUE for the app (e.g. METALRENDERER_SLOW_FRAME=300)")
    a = p.parse_args()
    os.makedirs(a.out, exist_ok=True)
    binary = os.path.join(REPO, BINARIES[a.build])
    if not os.path.exists(binary):
        sys.exit("no %s: build it first (Tools/build.sh or Tools/release.sh)" % binary)

    args = list(a.steps) + ["out=" + a.out]
    if a.saved:
        args.append("settings=" + saved_settings(a.out))
    env = dict(os.environ, METALRENDERER_BENCH="serve", METALRENDERER_RESIDENCY_LIFE="16")
    env.pop("METALRENDERER_WINDOW", None)
    env.update(kv.split("=", 1) for kv in a.env)
    log_path = os.path.join(a.out, "app.log")
    started = time.time()
    with open(log_path, "w") as log:
        app = subprocess.Popen([binary], cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    sock = "/tmp/metalrenderer-%d/%d.sock" % (os.getuid(), app.pid)
    while not os.path.exists(sock):
        if app.poll() is not None or time.time() - started > 180:
            sys.exit("the app didn't start; its output is in %s" % log_path)
        time.sleep(0.25)
    time.sleep(0.5)

    status, _ = request(sock, {"path": os.path.join(REPO, "Scripts/scene-switches.swift"), "args": args})
    died = app.poll() is not None
    if not died:
        try:
            request(sock, {"quit": True}, timeout=10)
        except OSError:
            pass
        try:
            app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            app.kill()

    # The log, step by step.
    steps, step, shots = {}, "start", {}
    with open(log_path, errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("STEP "):
                step = line[5:]
                steps.setdefault(step, [])
                continue
            m = re.match(r"SHOT (\S+) (before|after) (\S+)", line)
            if m:
                shots.setdefault(m.group(1), {})[m.group(2)] = m.group(3)
            for pattern, kind in FAILURES:
                if pattern.search(line) and not (kind == "catch-up" and step in ("jump", "slow")):
                    steps.setdefault(step, []).append("%s: %s" % (kind, line.strip()[:160]))
                    break
    for name, pair in sorted(shots.items()):
        if "before" in pair and "after" in pair and os.path.exists(pair["before"]) and os.path.exists(pair["after"]):
            db = psnr(pair["before"], pair["after"])
            print("stale %-12s %.1f dB" % (name, db))
            if db < STALE_DB:
                steps.setdefault("stale", []).append("stale: %s differs after a detour (%.1f dB)" % (name, db))
    if died:
        steps.setdefault(step, []).append("the app quit (status %s) during %s" % (app.returncode, step))
    if status != 0 and not died:
        steps.setdefault(step, []).append("the script ended with status %d" % status)

    print("\n%-10s %s" % ("step", "result"))
    bad = 0
    for name, problems in steps.items():
        if name in ("start", "done") and not problems:
            continue
        bad += bool(problems)
        print("%-10s %s" % (name, "ok" if not problems else "%d problem(s): %s" % (len(problems), problems[0])))
        for extra in problems[1:4]:
            print("%-10s   %s" % ("", extra))
    print("\nlog: %s (%.0f s)" % (log_path, time.time() - started))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
