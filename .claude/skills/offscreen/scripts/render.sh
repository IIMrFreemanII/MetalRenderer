#!/usr/bin/env bash
# Renders MetalRenderer offscreen (no window, no Dock icon, no focus change), saves the PNGs and prints the table.
#
#   render.sh [-m mode] [-o outdir] [-b binary] [-q] [KEY=VALUE …]
#
#   -m  benchmark mode (default: shot, one still of the app's default look; see Benchmark+Modes.swift)
#   -o  folder for the PNGs and run.log (default: a new folder under $TMPDIR)
#   -b  binary (default: <repo>/.build/release/MetalRenderer, rebuilt first when a Swift source is newer)
#   -q  quiet: print only the PNG paths
#   KEY=VALUE  any METALRENDERER_* override, e.g. METALRENDERER_SCENE=stress METALRENDERER_GI="mode=pt"
#
# Example:
#   render.sh -o "$scratch/before" METALRENDERER_SCENE=lights METALRENDERER_VIEW="view=2"
#   render.sh -m stressq -o "$scratch/q" METALRENDERER_GI_REFS=0 && python3 Tools/eval/stress.py "$scratch/q"
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mode=shot
out=""
bin="$repo/.build/release/MetalRenderer"
custom_bin=0
quiet=0
while getopts "m:o:b:qh" opt; do
  case $opt in
    m) mode=$OPTARG ;;
    o) out=$OPTARG ;;
    b) bin=$OPTARG; custom_bin=1 ;;
    q) quiet=1 ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
for e in "$@"; do
  [[ $e == *=* ]] || { echo "render.sh: '$e' is not a KEY=VALUE assignment" >&2; exit 1; }
  [[ $e != METALRENDERER_WINDOW=1 ]] || { echo "render.sh: renders offscreen only; METALRENDERER_WINDOW=1 would open a window" >&2; exit 1; }
done

# Swift changes need a build; shader changes don't (the binary compiles Shaders.metal at launch).
if [[ $custom_bin == 0 ]] && { [[ ! -x $bin ]] || [[ -n $(find "$repo/Sources" "$repo/Package.swift" -name '*.swift' -newer "$bin" -print -quit) ]]; }; then
  echo "building (release)…" >&2
  swift build -c release --package-path "$repo" 2>&1 | grep -E "error:|Build complete" >&2 || true
  [[ -x $bin ]] || { echo "render.sh: build failed" >&2; exit 1; }
fi

[[ -n $out ]] || out="${TMPDIR:-/tmp}/metalrenderer-render-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
root=$(cd "$(dirname "$bin")/../.." && pwd)   # <root>/.build/release/MetalRenderer: its own shaders and assets
start=$SECONDS
touch "$out/.started"   # the PNGs this run writes are newer than it
if ! (cd "$root" && env METALRENDERER_BENCH="$mode" METALRENDERER_BENCH_DIR="$out" "$@" "$bin") >"$out/run.log" 2>&1; then
  echo "render.sh: the run failed, see $out/run.log" >&2
  tail -20 "$out/run.log" >&2
  exit 1
fi
# Override typos don't stop a run: show what the log says about them.
grep -iE "unknown|isn't a|not a |failed" "$out/run.log" >&2 || true
if [[ $quiet == 0 ]]; then
  awk '/^setting/{t=1} t' "$out/run.log"
  echo "log: $out/run.log ($((SECONDS - start)) s)"
fi
find "$out" -name '*.png' -newer "$out/.started" | sort
