#!/usr/bin/env bash
# Alternating A/B benchmark runner for MetalRenderer.
#
#   ab.sh [-n rounds] [-c "col1,col2"] [--bin-a PATH] [--bin-b PATH] -- <env for A> -- <env for B>
#
# Runs A, B, A, B, … (`rounds` times each, default 2) so thermal drift and launch noise hit both alike, saves every
# log, then prints the chosen table columns (default "GPU total") per setting: each round's value, the medians and
# the delta B − A. Each binary runs from its own repo root, so it loads its own Shaders.metal; build a baseline in a
# git worktree to compare code against code (see references/measuring.md).
#
# Example:
#   ab.sh -n 3 -- METALRENDERER_BENCH=quick METALRENDERER_BENCH_ONLY="camera move" METALRENDERER_TG=trace=8x8 \
#              -- METALRENDERER_BENCH=quick METALRENDERER_BENCH_ONLY="camera move"
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
rounds=2
columns="GPU total"
bin_a="$repo/.build/release/MetalRenderer"
bin_b="$bin_a"

while [[ $# -gt 0 && $1 != "--" ]]; do
  case $1 in
    -n) rounds=$2; shift 2 ;;
    -c) columns=$2; shift 2 ;;
    --bin-a) bin_a=$2; shift 2 ;;
    --bin-b) bin_b=$2; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "ab.sh: unknown option $1" >&2; usage 1 ;;
  esac
done
[[ $# -gt 0 ]] || usage 1
shift   # the first --
env_a=(); env_b=()
while [[ $# -gt 0 && $1 != "--" ]]; do env_a+=("$1"); shift; done
[[ $# -gt 0 ]] || { echo "ab.sh: missing the second -- before B's environment" >&2; usage 1; }
shift
env_b=("$@")

check_bin() {
  local bin=$1
  [[ -x $bin ]] || { echo "ab.sh: $bin not found; run swift build -c release" >&2; exit 1; }
  [[ $bin == */release/* ]] || { echo "ab.sh: $bin is not a release build" >&2; exit 1; }
}
check_bin "$bin_a"; check_bin "$bin_b"
for e in "${env_a[@]}" "${env_b[@]}"; do
  [[ $e == *=* ]] || { echo "ab.sh: '$e' is not a KEY=VALUE assignment" >&2; exit 1; }
done
[[ " ${env_a[*]} ${env_b[*]} " == *METALRENDERER_BENCH=* ]] || echo "ab.sh: warning: no METALRENDERER_BENCH=… set; the app will not quit by itself" >&2

out="${TMPDIR:-/tmp}/metalrenderer-ab-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
echo "logs: $out"
echo "A: bin=${bin_a#"$repo"/} ${env_a[*]}"
echo "B: bin=${bin_b#"$repo"/} ${env_b[*]}"

run() {   # run <label> <round> <bin> <env…>
  local label=$1 round=$2 bin=$3; shift 3
  local root; root=$(cd "$(dirname "$bin")/../.." && pwd)   # <root>/.build/release/MetalRenderer
  local log="$out/$label$round.log"
  printf '  round %s %s … ' "$round" "$label"
  local start=$SECONDS
  if (cd "$root" && env "$@" "$bin") >"$log" 2>&1; then
    echo "$((SECONDS - start)) s"
  else
    echo "failed (exit $?), see $log" >&2; exit 1
  fi
}

for ((r = 1; r <= rounds; r++)); do
  run A "$r" "$bin_a" "${env_a[@]+"${env_a[@]}"}"
  run B "$r" "$bin_b" "${env_b[@]+"${env_b[@]}"}"
done

python3 - "$out" "$rounds" "$columns" <<'EOF'
import glob, os, re, statistics, sys

out, rounds, columns = sys.argv[1], int(sys.argv[2]), [c.strip() for c in sys.argv[3].split(",") if c.strip()]

def table(path):
    """{setting: {column: float}} from a benchmark log (the last table in it)."""
    rows, header = {}, None
    for line in open(path, errors="replace"):
        cells = re.split(r" {2,}", line.strip())
        if cells and cells[0] == "setting":
            header, rows = cells, {}
        elif header and len(cells) == len(header) and not line.startswith("-"):
            vals = {}
            for c, v in zip(header, cells):
                try: vals[c] = float(v)
                except ValueError: pass
            rows[cells[0]] = vals
    return rows

runs = {lab: [table(f"{out}/{lab}{r}.log") for r in range(1, rounds + 1)] for lab in "AB"}
if not any(runs["A"]) or not any(runs["B"]):
    sys.exit(f"no benchmark table found in the logs in {out}")
settings = list(dict.fromkeys(s for t in runs["A"] + runs["B"] for s in t))
w = max([len(s) for s in settings] + [7])
for col in columns:
    if not any(col in t.get(s, {}) for t in runs["A"] + runs["B"] for s in settings):
        print(f"\n{col}: no setting has this column (columns are named per pass; see the logs)")
        continue
    print(f"\n{col} (ms; median of {rounds} alternating rounds)")
    print(f"{'setting':{w}s}  {'A rounds':>22s}  {'B rounds':>22s}  {'A med':>7s}  {'B med':>7s}  {'Δ ms':>7s}  {'Δ %':>6s}  same sign")
    for s in settings:
        a = [t[s][col] for t in runs["A"] if s in t and col in t[s]]
        b = [t[s][col] for t in runs["B"] if s in t and col in t[s]]
        if not a or not b:
            continue
        ma, mb = statistics.median(a), statistics.median(b)
        pairs = [y - x for x, y in zip(a, b)]
        steady = "yes" if all(d > 0 for d in pairs) or all(d < 0 for d in pairs) else "no"
        fmt = lambda v: " ".join(f"{x:.2f}" for x in v)
        print(f"{s:{w}s}  {fmt(a):>22s}  {fmt(b):>22s}  {ma:7.2f}  {mb:7.2f}  {mb - ma:+7.2f}  {100 * (mb - ma) / ma if ma else 0:+6.1f}  {steady}")
print("\nNoise: launches swing 0.1–0.4 ms; trust a delta only above that and with the same sign in every round.")
EOF
