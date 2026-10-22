#!/bin/bash
# Tools/modules/loop.sh <target> <rounds> <lower module's folder> […]: builds the target (the dev build), marks what its
# errors ask for in the lower modules (pkgfix.py), and again, until it builds or nothing changes. The log is in
# .build-dev/modules-loop.log, what couldn't be fixed in .build-dev/modules-unresolved.txt.
repo=$(cd "$(dirname "$0")/../.." && pwd)
target=$1 rounds=$2; shift 2
log=$repo/.build-dev/modules-loop.log
mkdir -p "$repo/.build-dev"
for ((r = 1; r <= rounds; r++)); do
  "$repo/Tools/build.sh" --target "$target" > "$log" 2>&1 && { echo "round $r: built"; exit 0; }
  out=$(python3 "$repo/Tools/modules/pkgfix.py" "$repo" "$log" "$@")
  echo "round $r: $(echo "$out" | head -1) ($(grep -c 'error:' "$log") error lines)"
  echo "$out" > "$repo/.build-dev/modules-unresolved.txt"
  echo "$out" | head -1 | grep -q "^marked 0 " && ! grep -q "non-local scope" "$log" && { echo "stuck"; exit 1; }
done
exit 1
