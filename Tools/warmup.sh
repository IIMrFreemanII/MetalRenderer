#!/usr/bin/env bash
# Starts the dev build (Tools/build.sh) in the background, at low priority, in a checkout that has none yet: a new
# worktree pays its first build (about 90 s on all cores) while the session is still reading, not at its first
# render.sh or related.sh. Returns at once; the build's output goes to .build-dev/warmup.log.
#
# Run by the SessionStart hook (.claude/settings.json). A build started meanwhile by render.sh or related.sh waits
# for this one (SwiftPM locks the build folder) and then has nothing left to do. Never runs the app.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
[[ -x $repo/.build-dev/debug/MetalRenderer ]] && exit 0
command -v swift >/dev/null || exit 0
mkdir -p "$repo/.build-dev"
nohup nice -n 10 "$repo/Tools/build.sh" >"$repo/.build-dev/warmup.log" 2>&1 </dev/null &
echo "warming up the dev build in the background (.build-dev/warmup.log)"
