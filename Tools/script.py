#!/usr/bin/env python3
"""Runs a Swift script in the running MetalRenderer app (README, "Scripts"), through its socket.

  Tools/script.py Scripts/grid.swift [args...]       compile and run it in the app; its output here
  Tools/script.py -e 'renderer.camera.position = [0, 2, 8]'
  Tools/script.py --state                             the app's state as JSON (scene, camera, objects, settings)
  Tools/script.py --capture out.png [--scale 0.5]     the next frame as a PNG
  Tools/script.py --serve [--scene city]              start a headless app (no window) and wait for it
  Tools/script.py --quit                              quit a headless app

--build dev|release picks the app of that build (Tools/build.sh, Tools/release.sh); default: whichever runs. The exit
status is the script's: 0 done, 1 it failed, 2 it didn't compile or load (or no app runs).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp"))
import client  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("script", nargs="?", help="the .swift file")
    parser.add_argument("args", nargs=argparse.REMAINDER, help="the script's arguments (ScriptRun.arguments)")
    parser.add_argument("-e", dest="code", help="a script's code instead of a file")
    parser.add_argument("--build", choices=sorted(client.BUILDS), help="the app of this build")
    parser.add_argument("--state", action="store_true", help="print the app's state")
    parser.add_argument("--capture", metavar="PNG", help="save the next frame")
    parser.add_argument("--scale", type=float, default=1.0, help="the capture's size, times the frame's")
    parser.add_argument("--serve", action="store_true", help="start a headless app (METALRENDERER_BENCH=serve)")
    parser.add_argument("--scene", help="with --serve: the scene it opens (default: the stage)")
    parser.add_argument("--quit", action="store_true", help="quit a headless app")
    a = parser.parse_args()
    try:
        if a.serve:
            pid, log = client.start_headless(a.build or "release", a.scene)
            print("headless app %d is up (its output: %s)" % (pid, log))
            return 0
        if a.state:
            print(json.dumps(client.state(a.build), indent=2))
            return 0
        if a.capture:
            status, message = client.capture(a.capture, a.scale, a.build)
            print(message.rstrip() or os.path.abspath(a.capture))
            return status
        if a.quit:
            status, message = client.quit_app(a.build)
            if message:
                print(message.rstrip())
            return status
        if a.code is not None:
            path = client.inline_script(a.code, a.build)
            args = ([a.script] if a.script else []) + a.args
        elif a.script:
            path, args = a.script, a.args
        else:
            parser.print_help()
            return 2
        status, _ = client.run_script(path, args, a.build, on_out=lambda text: (sys.stdout.write(text), sys.stdout.flush()))
        return status
    except client.NoApp as e:
        print(e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
