#!/usr/bin/env bash
# Time-Profiles one benchmark setting offscreen and prints where its frames' CPU time goes.
#
#   profile.sh [-b binary] [-o outdir] [-t seconds] <mode> "<setting>" [KEY=VALUE …] [-- profile.py options]
#
#   <mode>, <setting>  METALRENDERER_BENCH and METALRENDERER_BENCH_ONLY (Benchmark+Modes.swift)
#   -b  binary (default <repo>/.build/release/MetalRenderer: profile release, `swift build -c release` first)
#   -o  folder for the .trace and its export (default: a new folder under $TMPDIR)
#   -t  time limit for the recording (default: until the benchmark quits)
#   KEY=VALUE  more METALRENDERER_* settings, e.g. METALRENDERER_API=metal4
#   after --    passed to profile.py, e.g. --callers swift_beginAccess --top 40
#
# Example:
#   profile.sh crowd "131072 characters"
#   profile.sh forest "forest moving 3x" METALRENDERER_API=metal4 -- --callers conformsToProtocol
# Runs are offscreen like every benchmark (no window, no focus change). A binary outside this repo (a baseline copy)
# needs METALRENDERER_ASSETS=<repo>/Assets.
set -euo pipefail

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
bin="$repo/.build/release/MetalRenderer"
out=""
limit=()
while getopts "b:o:t:h" opt; do
  case $opt in
    b) bin=$OPTARG ;;
    o) out=$OPTARG ;;
    t) limit=(--time-limit "${OPTARG}s") ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -ge 2 ]] || usage 1
mode=$1 setting=$2
shift 2
envs=(--env "METALRENDERER_BENCH=$mode" --env "METALRENDERER_BENCH_ONLY=$setting")
while [[ $# -gt 0 && $1 != "--" ]]; do
  [[ $1 == *=* ]] || { echo "profile.sh: '$1' is not a KEY=VALUE setting" >&2; exit 1; }
  envs+=(--env "$1"); shift
done
[[ $# -gt 0 ]] && shift   # the --
[[ -x $bin ]] || { echo "profile.sh: $bin not found; run swift build -c release" >&2; exit 1; }

out=${out:-"${TMPDIR:-/tmp}/metalrenderer-profile-$(date +%Y%m%d-%H%M%S)"}
mkdir -p "$out"
trace="$out/$mode.trace"
rm -rf "$trace"
echo "trace: $trace"
(cd "$(dirname "$(dirname "$(dirname "$bin")")")" &&
  xcrun xctrace record --template 'Time Profiler' --output "$trace" ${limit[@]+"${limit[@]}"} "${envs[@]}" --launch -- "$bin" >"$out/record.log" 2>&1) ||
  { echo "profile.sh: recording failed, see $out/record.log" >&2; exit 1; }
xcrun xctrace export --input "$trace" --xpath '/trace-toc/run/data/table[@schema="time-profile"]' >"$out/time-profile.xml"
python3 "$(dirname "$0")/profile.py" "$out/time-profile.xml" "$@"
