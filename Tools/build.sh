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
source "$repo/Tools/devflags.sh"
# The modules above an @inlinable body that changed are rebuilt (the build doesn't: Tools/modules/inlinable.py).
python3 "$repo/Tools/modules/inlinable.py" "$repo/.build-dev"

if [[ ${1:-} == test ]]; then
  shift
  exec swift test "${flags[@]}" "$@"
fi
swift build "${flags[@]}" "$@" >&2
echo "$repo/.build-dev/debug/MetalRenderer"
