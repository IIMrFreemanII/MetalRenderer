#!/usr/bin/env bash
# The fast optimised build for iterating: the debug configuration with -O, in .build-dev.
#
#   Tools/build.sh                     build; prints the binary's path (.build-dev/debug/MetalRenderer)
#   Tools/build.sh test --filter 'A|B' build and run these test suites in it
#
# It compiles file by file and incrementally (a one-file edit rebuilds in seconds, where the whole-module release
# build recompiles everything), and runs the CPU code at nearly release speed. Release (`swift build -c release`)
# stays the build for performance numbers: A/Bs, benchmarks quoted anywhere.
# Extra arguments go to `swift build` (or `swift test`).
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
flags=(--package-path "$repo" --scratch-path "$repo/.build-dev" -Xswiftc -O)

if [[ ${1:-} == test ]]; then
  shift
  exec swift test "${flags[@]}" "$@"
fi
swift build "${flags[@]}" "$@" >&2
echo "$repo/.build-dev/debug/MetalRenderer"
