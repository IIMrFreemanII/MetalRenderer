#!/usr/bin/env bash
# Do the baseline and the current code render the same images?
#
#   same.sh [--self] <mode> [<filter>] [-- KEY=VALUE …]
#
# Builds the current tree in release, runs METALRENDERER_BENCH=<mode> on the baseline (baseline.sh) and on the
# current binary with METALRENDERER_BENCH_DIR set, and compares the PNGs by name. <filter> is a
# METALRENDERER_BENCH_ONLY value; the assignments after -- go to both runs. The converged references are skipped
# (METALRENDERER_GI_REFS=0) unless an assignment says otherwise. Exits 0 when every image is identical, 1 otherwise.
#
# --self runs the baseline against itself: what differs there differs from run to run, and proves nothing.
#
# Example:
#   same.sh quick
#   same.sh stressq "32 lights" -- METALRENDERER_RT=custom
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
here=$(cd "$(dirname "$0")" && pwd)
self=0
while [[ $# -gt 0 && $1 == -* && $1 != "--" ]]; do
  case $1 in
    --self) self=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "same.sh: unknown option $1" >&2; usage 1 ;;
  esac
done
[[ $# -gt 0 && $1 != "--" ]] || usage 1
mode=$1; shift
extra=()
if [[ $# -gt 0 && $1 != "--" ]]; then extra+=("METALRENDERER_BENCH_ONLY=$1"); shift; fi
if [[ $# -gt 0 ]]; then shift; extra+=("$@"); fi
for e in "${extra[@]+"${extra[@]}"}"; do
  [[ $e == *=* ]] || { echo "same.sh: '$e' is not a KEY=VALUE assignment" >&2; exit 1; }
done

bin_a=$("$here/baseline.sh" --path)
bin_b="$repo/.build/release/MetalRenderer"
if [[ $self == 1 ]]; then
  bin_b=$bin_a
else
  swift build -c release --package-path "$repo" 2>&1 | tail -n 1   # a stale binary would prove nothing
fi

out="${TMPDIR:-/tmp}/metalrenderer-same-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out/a" "$out/b"
echo "images and logs: $out (a = baseline, b = $([[ $self == 1 ]] && echo 'baseline again' || echo current))"

run() {   # run <a|b> <bin>
  local side=$1 bin=$2
  local root; root=$(cd "$(dirname "$bin")/../.." && pwd)   # <root>/.build/release/MetalRenderer
  printf '  %s … ' "$side"
  local start=$SECONDS
  if (cd "$root" && env METALRENDERER_GI_REFS=0 "METALRENDERER_BENCH=$mode" "METALRENDERER_BENCH_DIR=$out/$side" \
        "${extra[@]+"${extra[@]}"}" "$bin") >"$out/$side.log" 2>&1; then
    echo "$((SECONDS - start)) s"
  else
    echo "failed (exit $?), see $out/$side.log" >&2; tail -n 5 "$out/$side.log" >&2; exit 1
  fi
}
run a "$bin_a"
run b "$bin_b"

names_a=$(cd "$out/a" && ls | grep '\.png$' || true)
names_b=$(cd "$out/b" && ls | grep '\.png$' || true)
[[ -n $names_a ]] || { echo "same.sh: the baseline saved no images; see $out/a.log" >&2; exit 1; }
if [[ $names_a != "$names_b" ]]; then
  echo "$mode: the two runs saved different sets of images (< baseline only, > current only):"
  diff <(echo "$names_a") <(echo "$names_b") | grep '^[<>]' || true
  exit 1
fi

total=0; differing=()
while IFS= read -r n; do
  total=$((total + 1))
  cmp -s "$out/a/$n" "$out/b/$n" || differing+=("$n")
done <<<"$names_a"

label="$mode${extra[*]+ (${extra[*]})}"
images="$total image$([[ $total -eq 1 ]] || echo s)"
if [[ ${#differing[@]} -eq 0 ]]; then
  echo "$label: $images, all identical"
  exit 0
fi

# The files differ; pngdiff.py says by how much (it needs numpy and Pillow). Files with the same pixels count as identical.
if report=$(cd "$repo" && python3 Tools/eval/pngdiff.py "$out/a" "$out/b" 2>/dev/null); then
  changed=0
  for n in "${differing[@]}"; do
    line=$(grep -F -- "$n " <<<"$report" || true)
    if [[ $line != *"max   0.0 "* ]]; then changed=$((changed + 1)); echo "$line"; fi
  done
  if [[ $changed -eq 0 ]]; then
    echo "$label: $images, all identical (${#differing[@]} files differ in bytes, not in pixels)"
    exit 0
  fi
  echo "$label: $changed of $images differ (8-bit levels above)"
else
  printf '%s\n' "${differing[@]}"
  echo "$label: ${#differing[@]} of $images differ (the files above; pngdiff.py needs numpy and Pillow to say by how much)"
fi
exit 1
