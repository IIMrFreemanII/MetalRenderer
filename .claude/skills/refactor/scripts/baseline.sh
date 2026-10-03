#!/usr/bin/env bash
# Freezes the code as it stands as the baseline a refactor is proven against.
#
#   baseline.sh [<ref>]    make the baseline and build it
#   baseline.sh --path     print the baseline binary's path
#   baseline.sh --remove   remove the baseline
#
# Checks the working tree out as it is now (uncommitted changes and untracked files included; or <ref>, a commit)
# into the git worktree ../MetalGI-base and builds it in release, so the baseline binary loads its own shaders.
# Nothing is committed or stashed in this tree. Run it before the first edit: a baseline made later holds the
# refactor it should be compared with, so an existing one is never replaced.
#
# same.sh and the performance skill's ab.sh (--bin-a) take the binary from there.
set -euo pipefail

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
base="$(dirname "$repo")/MetalGI-base"   # the worktree the performance skill's measuring.md uses
bin="$base/.build/release/MetalRenderer"

case ${1:-} in
  -h|--help) usage 0 ;;
  --path)
    [[ -x $bin ]] || { echo "baseline.sh: no baseline at $base; run baseline.sh before the first edit" >&2; exit 1; }
    echo "$bin"; exit 0 ;;
  --remove)
    git -C "$repo" worktree remove --force "$base"
    echo "removed $base"; exit 0 ;;
  -*) echo "baseline.sh: unknown option $1" >&2; usage 1 ;;
esac

if [[ -e $base ]]; then
  echo "baseline.sh: $base exists (at $(git -C "$base" log -1 --format='%h %s' 2>/dev/null || echo '?'))." >&2
  echo "It is the baseline of a pass that started earlier. Keep using it, or run baseline.sh --remove first." >&2
  exit 1
fi

ref=${1:-}
untracked=0
if [[ -z $ref ]]; then
  ref=$(git -C "$repo" stash create)   # a commit of the tracked changes; no ref, no change to this tree
  [[ -n $ref ]] || ref=HEAD
  untracked=1
fi
git -C "$repo" worktree add --detach "$base" "$ref" >/dev/null
if [[ $untracked == 1 ]]; then
  git -C "$repo" ls-files -z --others --exclude-standard | while IFS= read -r -d '' f; do
    mkdir -p "$base/$(dirname "$f")"
    cp -p "$repo/$f" "$base/$f"
  done
fi

echo "baseline: $(git -C "$base" log -1 --format='%h %s')$([[ -n $(git -C "$repo" status --porcelain) && $untracked == 1 ]] && echo ' + uncommitted work')"
swift build -c release --package-path "$base"
echo "$bin"
