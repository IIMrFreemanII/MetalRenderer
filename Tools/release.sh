#!/usr/bin/env bash
# The release build, after the modules above an @inlinable body that changed are marked for rebuilding (the build
# alone keeps what they inlined before: Tools/modules/inlinable.py).
#
#   Tools/release.sh [args]                  swift build -c release (the binaries benchmarks, A/Bs and
#                                            Tools/perf/hotcalls.py read: .build/release/MetalRenderer)
#   Tools/release.sh test --filter 'A|B'     swift test -c release (the same build: release builds are testable)
#
# Extra arguments go to swift build (or swift test).
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
python3 "$repo/Tools/modules/inlinable.py" "$repo/.build"
if [[ ${1:-} == test ]]; then
  shift
  exec swift test -c release --package-path "$repo" "$@"
fi
exec swift build -c release --package-path "$repo" "$@"
