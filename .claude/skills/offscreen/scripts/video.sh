#!/usr/bin/env bash
# Renders a recording mode offscreen (Benchmark.Config.recording: every other frame of a setting, a 30 fps JPEG
# sequence in a folder per setting) and joins each setting's frames into an mp4 with ffmpeg.
#
#   video.sh -m mode -o out.mp4 [-k] [KEY=VALUE …]
#
#   -m  a mode whose settings record (e.g. shapesdemo, stressdemo, showcasevideo; see Benchmark+Modes.swift)
#   -o  the mp4 to write; a mode of several recording settings writes one per setting, <out>-<setting>.mp4. The frames
#       go into <out>.frames/ next to it (deleted afterwards unless -k)
#   -k  keep the frames
#   KEY=VALUE  any METALRENDERER_* override, passed to render.sh
#
# Example:
#   video.sh -m shapesdemo -o "$scratch/shapes-demo.mp4"
set -euo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

mode=""
out=""
keep=0
while getopts "m:o:kh" opt; do
  case $opt in
    m) mode=$OPTARG ;;
    o) out=$OPTARG ;;
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
settings=()
for d in "$frames"/*/; do [[ -f $d/f0001.jpg ]] && settings+=("${d%/}"); done
[[ ${#settings[@]} -gt 0 ]] || { echo "video.sh: mode $mode recorded no frames (does a setting use .recording()?)" >&2; exit 1; }
for d in "${settings[@]}"; do
  target=$out
  [[ ${#settings[@]} -eq 1 ]] || target="${out%.*}-$(basename "$d").mp4"
  ffmpeg -loglevel error -y -framerate 30 -start_number 1 -i "$d/f%04d.jpg" \
    -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -movflags +faststart "$target"
  count=$(find "$d" -name 'f[0-9][0-9][0-9][0-9].jpg' | wc -l | tr -d ' ')
  echo "$target ($count frames, $(awk "BEGIN { printf \"%.1f\", $count / 30 }") s at 30 fps)"
done
[[ $keep == 1 ]] || rm -rf "$frames"
