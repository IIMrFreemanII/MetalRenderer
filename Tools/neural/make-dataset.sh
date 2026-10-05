#!/usr/bin/env bash
# Renders the neural denoiser's training dataset (Benchmark+Dataset.swift) offscreen: every clip's noisy frames, then
# a path-traced reference for every frame. Resumable: run it again and it carries on with what is missing.
#
#   make-dataset.sh [-d <dir>]
#
#   -d  the dataset folder (default: <repo>/dataset, gitignored); the log is <dir>/run.log
#   METALRENDERER_DATASET in the environment replaces the default list (11 scenes x 4 clips, the stress building's 4
#   zones, 24 random rooms and a showcase clip per Assets/ model; 20 frames, the stress building's and the showcase's 8;
#   512 spp); any other METALRENDERER_* variable is passed on
#   (for example METALRENDERER_RT=metal).
#
# Long: about 70 s a reference on an M1 Max, 6-9 min for the showcase's and the stress building's (~1,500). Run it detached:
#   nohup Tools/neural/make-dataset.sh > /dev/null 2>&1 &
set -u

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
dir="$repo/dataset"
while getopts "d:h" opt; do
  case $opt in
    d) dir=$(mkdir -p "$OPTARG" && cd "$OPTARG" && pwd) ;;
    *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done
mkdir -p "$dir"
log="$dir/run.log"
spec=${METALRENDERER_DATASET:-"scenes=cornell|stress|spots|sun|area|tubes|emissive|mixed|fog|valley|market|forest|randomroom|showcase,clips=4,rooms=24,frames=20,spp=512"}
render="$repo/.claude/skills/offscreen/scripts/render.sh"
runs="$dir/.runs"   # render.sh's logs and PNGs

echo "start $(date): $spec" >> "$log"
if ! "$render" -q -m dataset -o "$runs/noisy" METALRENDERER_DATASET="$spec" METALRENDERER_DATASET_DIR="$dir" > /dev/null 2>> "$log"; then
  echo "noisy pass FAILED $(date) (see $runs/noisy/run.log)" >> "$log"
  exit 1
fi
echo "noisy pass done $(date): $(du -sh "$dir" | cut -f1)" >> "$log"
for attempt in 1 2 3; do
  # One command buffer a frame (METALRENDERER_BENCH_SPLIT=0): the references don't need per-pass timings.
  if "$render" -q -m datasetref -o "$runs/references" METALRENDERER_BENCH_SPLIT=0 METALRENDERER_DATASET="$spec" \
       METALRENDERER_DATASET_DIR="$dir" > /dev/null 2>> "$log"; then
    echo "references done $(date): $(du -sh "$dir" | cut -f1)" >> "$log"
    exit 0
  fi
  echo "reference pass FAILED (attempt $attempt) $(date) (see $runs/references/run.log)" >> "$log"
done
exit 1
