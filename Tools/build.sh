#!/usr/bin/env bash
# The fast optimised build for iterating: the debug configuration with -O, in .build-dev.
#
#   Tools/build.sh                     build; prints the binary's path (.build-dev/debug/MetalRenderer)
#   Tools/build.sh test --filter 'A|B' build and run these test suites in it
#
# It compiles file by file and incrementally (a one-file edit rebuilds in seconds, where the whole-module release
# build recompiles everything), and runs the CPU code at nearly release speed. Release (`Tools/release.sh`)
# stays the build for performance numbers: A/Bs, benchmarks quoted anywhere.
# Extra arguments go to `swift build` (or `swift test`).
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# 80 batches of files, not one per core: the files' costs differ, and with one batch a core a few slow batches kept a
# clean build waiting on one or two cores (M1 Max: 88 s; 73 s with 80). An edit rebuilds the same either way.
flags=(--package-path "$repo" --scratch-path "$repo/.build-dev" -Xswiftc -O -Xswiftc -driver-batch-count -Xswiftc 80)
# The modules above an @inlinable body that changed are rebuilt (the build doesn't: Tools/modules/inlinable.py).
python3 "$repo/Tools/modules/inlinable.py" "$repo/.build-dev"

if [[ ${1:-} == test ]]; then
  shift
  exec swift test "${flags[@]}" "$@"
fi
swift build "${flags[@]}" "$@" >&2
echo "$repo/.build-dev/debug/MetalRenderer"
