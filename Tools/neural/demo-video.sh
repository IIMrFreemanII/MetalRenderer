#!/usr/bin/env bash
# Our denoising upscaler's demo video: METALRENDERER_BENCH=denoisedemo (Benchmark+Modes.swift) renders each scene's
# camera move three times offscreen - the net's input (1 sample, 640x400, no denoiser), MetalFX's denoising scaler and
# ours (Assets/Neural/denoiser.nnw, or METALRENDERER_NEURAL) - and this puts them side by side in one 1920x1200 frame,
# a third each, labelled, scene after scene.
#
#   demo-video.sh [-o out.mp4] [-k] [KEY=VALUE ...]
#
#   -o  the mp4 (default: <repo>/renders/denoiser-demo.mp4); the frames go to <out>.frames/, deleted unless -k
#   -k  keep the frames (and each scene's mp4)
#   KEY=VALUE  any METALRENDERER_* override, passed to render.sh (METALRENDERER_BENCH_ONLY="cornell noisy|cornell
#       metalfx|cornell neural" renders one scene)
#
# ~20 min on an M4 Max (ours takes ~120 ms a frame). Needs ffmpeg.
set -euo pipefail

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
out="$repo/renders/denoiser-demo.mp4"
keep=0
while getopts "o:kh" opt; do
  case $opt in
    o) out=$OPTARG ;;
    k) keep=1 ;;
    *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done
shift $((OPTIND - 1))
command -v ffmpeg >/dev/null || { echo "demo-video.sh: needs ffmpeg (brew install ffmpeg)" >&2; exit 1; }

mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"   # absolute: the concat list's paths are read from its folder
frames="${out%.*}.frames"
rm -rf "$frames"
"$repo/.claude/skills/offscreen/scripts/render.sh" -q -m denoisedemo -o "$frames" "$@" >/dev/null

font=/System/Library/Fonts/Helvetica.ttc
label() { echo "drawtext=fontfile=$font:text='$1':x=$2:y=36:fontsize=34:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=12"; }
parts=()
for tag in stress cornell market showcase; do
  noisy=$(ls -d "$frames"/*-"$tag"-noisy 2>/dev/null | head -1 || true)
  metalfx=$(ls -d "$frames"/*-"$tag"-metalfx 2>/dev/null | head -1 || true)
  neural=$(ls -d "$frames"/*-"$tag"-neural 2>/dev/null | head -1 || true)
  [[ -n $noisy && -n $metalfx && -n $neural ]] || continue
  case $tag in
    stress) title="Stress building" ;;
    cornell) title="Cornell room" ;;
    market) title="Night market" ;;
    showcase) title="Showcase" ;;
  esac
  part="$frames/$tag.mp4"
  # The input is 640x400: scaled up by whole pixels, so its noise shows as it is. Each method keeps its own third of
  # the frame (the same camera in all three), with a line between them.
  ffmpeg -loglevel error -y \
    -framerate 30 -start_number 1 -i "$noisy/f%04d.jpg" \
    -framerate 30 -start_number 1 -i "$metalfx/f%04d.jpg" \
    -framerate 30 -start_number 1 -i "$neural/f%04d.jpg" \
    -filter_complex "[0]scale=1920:1200:flags=neighbor,crop=640:1200:0:0[a];[1]crop=640:1200:640:0[b];[2]crop=640:1200:1280:0[c];\
[a][b][c]hstack=inputs=3,drawbox=x=638:y=0:w=4:h=ih:color=white@0.85:t=fill,drawbox=x=1278:y=0:w=4:h=ih:color=white@0.85:t=fill,\
$(label 'Input · 1 sample · 640×400' 24),$(label 'MetalFX denoising upscaler' 664),$(label 'Ours · neural 3×' 1304),\
drawtext=fontfile=$font:text='$title':x=24:y=h-th-36:fontsize=30:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=10" \
    -shortest -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p "$part"
  parts+=("$part")
done
[[ ${#parts[@]} -gt 0 ]] || { echo "demo-video.sh: no scene was recorded in all three versions" >&2; exit 1; }

list="$frames/parts.txt"
: > "$list"
for p in "${parts[@]}"; do echo "file '$p'" >> "$list"; done
ffmpeg -loglevel error -y -f concat -safe 0 -i "$list" -c copy -movflags +faststart "$out"
echo "$out (${#parts[@]} scenes, $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out" | awk '{printf "%.1f", $1}') s)"
[[ $keep == 1 ]] || rm -rf "$frames"
