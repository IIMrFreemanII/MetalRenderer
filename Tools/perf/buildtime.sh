#!/usr/bin/env bash
# Build times, measured on a copy of this tree: clean builds, a no-op, one-line edits.
#
#   Tools/perf/buildtime.sh                     every scenario, every build
#   Tools/perf/buildtime.sh -b dev,devtest      these builds only (dev, devtest, release, releasetest)
#   Tools/perf/buildtime.sh -s clean,renderer   these scenarios only (below)
#   Tools/perf/buildtime.sh -w <folder>         the copy's folder (default: $TMPDIR/metalrenderer-buildtime); kept,
#                                               so a second run starts from its builds
#   Tools/perf/buildtime.sh --stats             also print the compiler's time per phase (-stats-output-dir)
#   Tools/perf/buildtime.sh --rev origin/main   a commit instead of the working tree (use its own -w folder), for
#                                               the numbers before a change
#
# The copy holds this tree's Sources, Tests, Tools and Package.swift as they are now, uncommitted changes included, so
# a flag tried in Package.swift or Tools/build.sh is measured too. Builds: dev = Tools/build.sh (the copy's), devtest =
# the same with the tests, release = swift build -c release, releasetest = the same with the tests.
# Scenarios:
#   clean      the build folder removed first (a fresh worktree)
#   noop       nothing changed
#   renderer   a line in a function body of Renderer+Stages.swift (the engine)
#   physics    a line in a function body of PhysicsCPU+Narrow.swift
#   editor     a line in a SwiftUI body (MaterialEditorView.swift)
#   test       a line in a test (PhysicsThreadsTests.swift)
#   interface  a static added to Uniforms (GPUTypes.swift), which nearly every file sees
#   engineinterface  a static added to Scene (Scene.swift): the engine's interface, which the editors and game see
#   game       a line in a function body of a scene's builder (Scene+Demolition.swift)
#   core, plants, characters, effects, materials, buildings, landscape
#              a line in a function body of BVH.swift, Foliage.swift, Crowd.swift, Particles.swift, MatCompiler.swift,
#              Building.swift, Terrain.swift: each module's own edit once it is a module
# Files are found by name wherever they are (they move between modules). Each edit scenario is measured twice, the
# line added and then removed; the faster counts. Before each build it waits for other sessions' compiles to finish.
# Prints: scenario, build, seconds, the object files it recompiled, and how many in each module.
set -euo pipefail

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=${TMPDIR:-/tmp}/metalrenderer-buildtime
builds=dev,devtest,release,releasetest
scenarios=clean,noop,renderer,physics,editor,test,interface,engineinterface,game
stats=0
rev=
while (($#)); do
  case $1 in
    -h|--help) usage 0 ;;
    -b) builds=${2:?}; shift ;;
    -s) scenarios=${2:?}; shift ;;
    -w) work=${2:?}; shift ;;
    --stats) stats=1 ;;
    --rev) rev=${2:?}; shift ;;
    *) echo "buildtime.sh: unknown argument $1" >&2; usage 1 ;;
  esac
  shift
done

# The copy: the tracked and untracked files, mtimes kept, so unchanged files stay unchanged for the incremental builds.
mkdir -p "$work"
if [[ -n $rev ]]; then
  # once: unpacking it again would give every file a new time and rebuild everything
  [[ -f $work/Package.swift ]] || git -C "$repo" archive "$rev" Sources Tests Tools Package.swift | tar -x -C "$work"
else
  listed=$(cd "$repo" && git ls-files -co --exclude-standard -- Sources Tests Tools Package.swift Package.resolved)
  rsync -a --files-from=<(echo "$listed") "$repo/" "$work/"
  # what the tree no longer has (a file moved to another module) goes from the copy too
  (cd "$work" && find Sources Tests Tools -type f 2>/dev/null) | grep -vxF -f <(echo "$listed") | (cd "$work" && xargs rm -f)
fi
w=$work

# file name | a part of the line after which the edit goes | the edit
spec_for() {
  case $1 in
    renderer) echo "Renderer+Stages.swift|func bind(_ enc: ComputePass|        _ = 1 // buildtime" ;;
    physics) echo "PhysicsCPU+Narrow.swift|func narrowPhase(|        _ = 1 // buildtime" ;;
    editor) echo "MaterialEditorView.swift|var body: some View {|        let _ = 1 // buildtime" ;;
    test) echo "PhysicsThreadsTests.swift|func testOneThreadAndAllAgree() throws {|        _ = 1 // buildtime" ;;
    interface) echo "GPUTypes.swift|struct Uniforms {|    static let buildtimeProbe = 0 // buildtime" ;;
    engineinterface) echo "Scene.swift|final class Scene {|    static let buildtimeProbe = 0 // buildtime" ;;
    game) echo "Scene+Demolition.swift|func buildDemolition(|        _ = 1 // buildtime" ;;
    core) echo "BVH.swift|static func build(boxes:|        _ = 1 // buildtime" ;;
    plants) echo "Foliage.swift|static func perpendicular(_ t: SIMD3<Float>, up:|        _ = 1 // buildtime" ;;
    characters) echo "Crowd.swift|func pose(at t: Float) {|        _ = 1 // buildtime" ;;
    effects) echo "Particles.swift|func stepsTo(_ time: Float)|        _ = 1 // buildtime" ;;
    materials) echo "MatCompiler.swift|static func shorten(_ message: String)|        _ = 1 // buildtime" ;;
    buildings) echo "Building.swift|mutating func setFrame(_ frame: float4x4) {|        _ = 1 // buildtime" ;;
    landscape) echo "Terrain.swift|static func fbm(_ p: SIMD2<Float>, octaves:|        _ = 1 // buildtime" ;;
  esac
}

# file (found by name under Sources and Tests) | anchor | the edit
edit_for() {
  local name anchor line file
  IFS='|' read -r name anchor line <<<"$(spec_for "$1")"
  file=$(cd "$w" && find Sources Tests -name "$name" | head -1)
  [[ -n $file ]] || { echo "buildtime.sh: $name not found" >&2; exit 1; }
  echo "$file|$anchor|$line"
}

# Adds the edit, or removes it when it is there.
toggle() {
  IFS='|' read -r file anchor line <<<"$(edit_for "$1")"
  python3 - "$w/$file" "$anchor" "$line" <<'EOF'
import sys
path, anchor, line = sys.argv[1:]
src = open(path).read().split("\n")
if line in src:
    src.remove(line)
else:
    i = next(i for i, l in enumerate(src) if anchor in l)
    src.insert(i + 1, line)
open(path, "w").write("\n".join(src))
EOF
}

idle() {
  local said=0
  while pgrep -x swift-frontend >/dev/null; do
    ((said)) || { echo "  (waiting for other compiles to finish)" >&2; said=1; }
    sleep 2
  done
}

scratch_of() { case $1 in dev*) echo "$w/.build-dev" ;; *) echo "$w/.build" ;; esac; }

# Runs one build; prints its seconds and the object files written.
run() {
  local build=$1 log=$w/last-$1.log statdir=$w/stats-$1
  local flags=()
  rm -rf "$statdir"
  ((stats)) && { mkdir -p "$statdir"; flags=(-Xswiftc -stats-output-dir -Xswiftc "$statdir"); }
  idle
  local stamp=$w/.stamp; : >"$stamp"
  local t0 t1
  t0=$(python3 -c 'import time; print(time.time())')
  case $build in
    dev) "$w/Tools/build.sh" ${flags[@]+"${flags[@]}"} >"$log" 2>&1 ;;
    devtest) "$w/Tools/build.sh" --build-tests ${flags[@]+"${flags[@]}"} >"$log" 2>&1 ;;
    release) swift build -c release --package-path "$w" ${flags[@]+"${flags[@]}"} >"$log" 2>&1 ;;
    releasetest) swift build -c release --build-tests --package-path "$w" ${flags[@]+"${flags[@]}"} >"$log" 2>&1 ;;
  esac || { echo "buildtime.sh: $build failed, see $log" >&2; tail -20 "$log" >&2; exit 1; }
  t1=$(python3 -c 'import time; print(time.time())')
  local objects
  objects=$(find "$(scratch_of "$build")" -name '*.o' -newer "$stamp" 2>/dev/null | python3 -c '
import collections, re, sys
per = collections.Counter()
for path in sys.stdin.read().split():
    # .../<Target>-t.build/... (swift-build) or .../<Target>.build/... ; a product (.o of a whole module) by its name
    m = re.findall(r"/([^/]+?)(?:-[tp])?\.build/", path)
    per[m[-1] if m else path.rsplit("/", 1)[-1][:-2]] += 1
print(sum(per.values()), ",".join(f"{k}:{v}" for k, v in sorted(per.items())) or "-")')
  python3 -c "print(f'{$t1 - $t0:.1f}')"
  echo "$objects"
}

phases() {
  local statdir=$w/stats-$1
  [[ -d $statdir ]] || return 0
  python3 - "$statdir" <<'EOF'
import json, os, sys, collections
total = collections.Counter()
for f in os.listdir(sys.argv[1]):
    try:
        d = json.load(open(os.path.join(sys.argv[1], f)))
    except Exception:
        continue
    for k, v in d.items():
        if k.startswith("time.swift.") and k.endswith(".wall"):
            total[k[len("time.swift."):-len(".wall")]] += v
for k, v in total.most_common(8):
    print(f"      {k:40} {v:7.1f} s")
EOF
}

printf '%-16s %-12s %8s %8s  %s\n' scenario build seconds objects modules
IFS=, read -ra bs <<<"$builds"
IFS=, read -ra ss <<<"$scenarios"
for s in "${ss[@]}"; do
  for b in "${bs[@]}"; do
    case $s in
      clean)
        rm -rf "$(scratch_of "$b")"
        # the tests' build after a clean app build: what a fresh worktree pays for its first related.sh
        [[ $b == *test ]] && run "${b%test}" >/dev/null
        read -r secs objs mods < <(run "$b" | paste -sd' ' -) ;;
      noop)
        run "$b" >/dev/null
        read -r secs objs mods < <(run "$b" | paste -sd' ' -) ;;
      *)
        run "$b" >/dev/null   # up to date first
        best=
        for _ in 1 2; do
          toggle "$s"
          read -r t o m < <(run "$b" | paste -sd' ' -)
          if [[ -z $best ]] || python3 -c "import sys; sys.exit(0 if $t < $best else 1)"; then best=$t; objs=$o; mods=$m; fi
        done
        secs=$best ;;
    esac
    printf '%-16s %-12s %8s %8s  %s\n' "$s" "$b" "$secs" "$objs" "$mods"
    if ((stats)); then phases "$b"; fi
  done
done
