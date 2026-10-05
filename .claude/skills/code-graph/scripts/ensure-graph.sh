#!/usr/bin/env bash
# Builds graphify's knowledge graph when this checkout doesn't have one.
#
#   ensure-graph.sh               build graphify-out/graph.json with `graphify update .` if it is missing
#   ensure-graph.sh --check       only report: exit 0 when the graph is there, 1 when it is missing
#
# graphify-out/ is gitignored, so every new worktree starts without a graph. The build is AST only (no API cost).
# A graph that is already there is left alone: refresh it with `graphify update .` after changing code.
set -euo pipefail

usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
graph=$repo/graphify-out/graph.json
check=0

while (($#)); do
  case $1 in
    -h|--help) usage 0 ;;
    --check|-n) check=1 ;;
    *) echo "ensure-graph.sh: unknown argument $1" >&2; usage 1 ;;
  esac
  shift
done

if [[ -f $graph ]]; then
  echo "graph present: $graph"
  exit 0
fi

if ((check)); then
  echo "graph missing: $graph"
  exit 1
fi

command -v graphify >/dev/null || { echo "ensure-graph.sh: graphify is not on PATH" >&2; exit 2; }

echo "graph missing, building it with graphify update . in $repo"
cd "$repo"
graphify update .

[[ -f $graph ]] || { echo "ensure-graph.sh: graphify update . finished but $graph is still missing" >&2; exit 1; }
echo "graph built: $graph"
