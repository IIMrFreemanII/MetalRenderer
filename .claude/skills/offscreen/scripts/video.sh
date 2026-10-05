#!/usr/bin/env bash
# Renders a recording mode offscreen (every frame of its camera track, Benchmark.Config.recording) and encodes the
# frames as an mp4 with ffmpeg.
#
#   video.sh -m mode -o out.mp4 [-f fps] [-k] [KEY=VALUE …]
#
#   -m  a mode whose settings record (e.g. shapesdemo; see Benchmark+Modes.swift)
#   -o  the mp4 to write; its frames go into <out>.frames/ next to it (deleted afterwards unless -k)
#   -f  frames a second (default 60: the benchmark's clock steps 1/60 s)
#   -k  keep the frames
#   KEY=VALUE  any METALRENDERER_* override, passed to render.sh
#
# Example:
#   video.sh -m shapesdemo -o "$scratch/shapes-demo.mp4"
#   video.sh -m shapesdemo -o "$scratch/look.mp4" -f 2 METALRENDERER_RECORD_STEP=30   # a quick look along the track
set -euo pipefail

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

mode=""
out=""
fps=60
keep=0
while getopts "m:o:f:kh" opt; do
  case $opt in
    m) mode=$OPTARG ;;
    o) out=$OPTARG ;;
    f) fps=$OPTARG ;;
    k) keep=1 ;;
    h) usage 0 ;;
    *) usage 1 ;;
  esac
done
shift $((OPTIND - 1))
[[ -n $mode && -n $out ]] || usage 1
command -v ffmpeg >/dev/null || { echo "video.sh: needs ffmpeg (brew install ffmpeg)" >&2; exit 1; }

frames="${out%.*}.frames"
rm -rf "$frames"
"$(dirname "$0")/render.sh" -q -m "$mode" -o "$frames" "$@" >/dev/null
count=$(find "$frames" -name '*-[0-9][0-9][0-9][0-9].png' | wc -l | tr -d ' ')
[[ $count -gt 0 ]] || { echo "video.sh: mode $mode saved no numbered frames (does it record?)" >&2; exit 1; }
# One setting's frames (the first recording setting's, if the mode has several), linked as 0000.png, 0001.png ...: in
# order, without the gaps METALRENDERER_RECORD_STEP leaves.
first=$(find "$frames" -name '*-[0-9][0-9][0-9][0-9].png' | sort | awk 'NR == 1')
prefix=$(basename "$first" | sed -E 's/-[0-9]{4}\.png$//')
mkdir -p "$frames/seq"
i=0
for f in "$frames/$prefix"-[0-9][0-9][0-9][0-9].png; do
  ln -sf "$f" "$frames/seq/$(printf %04d $i).png"
  i=$((i + 1))
done
count=$i
ffmpeg -loglevel error -y -framerate "$fps" -start_number 0 -i "$frames/seq/%04d.png" \
  -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -movflags +faststart "$out"
[[ $keep == 1 ]] || rm -rf "$frames"
echo "$out ($count frames, $(awk "BEGIN { printf \"%.1f\", $count / $fps }") s at $fps fps)"
