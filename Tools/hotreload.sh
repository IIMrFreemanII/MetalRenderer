#!/usr/bin/env bash
# The dev build's hot reload of the game's code (Sources/Game). The app runs it when a file there is saved
# (MetalRenderer's DevReload):
#
#   Tools/hotreload.sh <n> <binary> <its mtime at launch>
#
# builds the Game module alone (the dev build's flags), links it into .build-dev/hotreload/Game-<n>.bundle against the
# running binary (whose engine it then calls), and prints the bundle's path. The app loads it and builds the scene
# again with the new code.
# Exit 2: something under the game changed too (the engine, a system, the editors), or the binary was built again
# since the app started: that needs Tools/build.sh and a relaunch.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/Tools/devflags.sh"
n=${1:?bundle number}
bin=${2:?the running binary}
launched=${3:?its mtime at launch}
products="$repo/.build-dev/out/Products/Debug"

if [[ $(stat -f %m "$bin") != "$launched" ]]; then
  echo "the app's binary was built again since it started: relaunch it" >&2
  exit 2
fi
swift build "${flags[@]}" --target Game >&2
for o in "$products"/*.o; do
  name=$(basename "$o" .o)
  if [[ $name != Game && $(stat -f %m "$o") -gt $launched ]]; then
    echo "$name changed since the app was built: rebuild it (Tools/build.sh) and relaunch; only Sources/Game reloads" >&2
    exit 2
  fi
done
out="$repo/.build-dev/hotreload"
mkdir -p "$out"
sdk=$(xcrun --show-sdk-path)
xcrun clang -bundle -bundle_loader "$bin" "$products/Game.o" -isysroot "$sdk" -L"$sdk/usr/lib/swift" -o "$out/Game-$n.bundle" >&2
echo "$out/Game-$n.bundle"
