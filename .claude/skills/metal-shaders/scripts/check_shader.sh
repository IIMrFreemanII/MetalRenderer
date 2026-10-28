#!/usr/bin/env bash
# Compile-check Metal shaders with the Xcode toolchain, without launching anything.
#
#   check_shader.sh --repo                  MetalRenderer's shader libraries, the way the app compiles them
#   check_shader.sh --snippets file.md ...  every ```metal block in these Markdown files, each on its own
#   check_shader.sh --code body.metal ...   a material graph Code node's text, inside the kernel the app wraps it in
#   check_shader.sh file.metal [...] [-std=metal4.0] [-sdk iphoneos] [-I dir] [-D NAME=VAL]
#
# The language is MSL 3.2, the app's, unless -std says otherwise.
# Errors and warnings (-Wall) are printed as file:line; exits non-zero on any error.
# In --snippets, a block whose first line is `// check: skip <why>` is skipped, and `// check: <flags>` adds compiler
# flags (e.g. `// check: -std=metal4.0`). A block without `#include <metal_stdlib>` gets it (and `using namespace
# metal;`) put in front.
set -euo pipefail

sdk="macosx"
std="-std=metal3.2"
mode="files"
files=()
extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) mode="repo"; shift ;;
    --snippets) mode="snippets"; shift ;;
    --code) mode="code"; shift ;;
    -sdk) sdk="$2"; shift 2 ;;
    -std=*) std="$1"; shift ;;
    -I|-D) extra+=("$1" "$2"); shift 2 ;;
    -I*|-D*) extra+=("$1"); shift ;;
    *.metal|*.md|*.txt) files+=("$1"); shift ;;
    *) extra+=("$1"); shift ;;
  esac
done

if ! command -v xcrun >/dev/null 2>&1; then
  echo "check_shader: xcrun not found: the Metal compiler needs macOS with Xcode." >&2
  echo "check_shader: shader NOT compiled; say so, and self-review with the SKILL.md checklist." >&2
  exit 2
fi

# The compiler. Since Xcode 26 the Metal toolchain is a separate download, mounted as a cryptex; when xcrun can't
# reach it (a sandbox blocks the asset query) the binary in the mount works on its own.
metal=""
if found=$(xcrun -sdk "$sdk" --find metal 2>/dev/null) && "$found" --version >/dev/null 2>&1; then
  metal="$found"
else
  for m in /private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-*/Metal.xctoolchain/usr/bin/metal; do
    [[ -x "$m" ]] && metal="$m"
  done
fi
if [[ -z "$metal" ]]; then
  echo "check_shader: no Metal compiler. On Xcode 26+ install it with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 2
fi
sysroot=$(xcrun --sdk "$sdk" --show-sdk-path 2>/dev/null || true)

tmp="$(mktemp -d "${TMPDIR:-/tmp}/check_shader.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
# The default module cache is outside what a sandbox may write; this one is per user and survives runs.
base=(-fmodules-cache-path="${TMPDIR:-/tmp}/check_shader-modules" -Wall)
[[ -n "$sysroot" ]] && base+=(-isysroot "$sysroot")

status=0

# One compile; prints its diagnostics and "ok" or "FAILED".
compile() {  # label, then compiler arguments
  local label="$1"; shift
  if "$metal" "${base[@]}" "$@" > "$tmp/log" 2>&1; then
    local warnings; warnings=$(grep -c "warning:" "$tmp/log" || true)
    cat "$tmp/log"
    if [[ $warnings -gt 0 ]]; then echo "   ok: $label ($warnings warning$([[ $warnings -gt 1 ]] && echo s))"; else echo "   ok: $label"; fi
  else
    cat "$tmp/log"
    echo "   FAILED: $label"
    status=1
  fi
}

case "$mode" in
repo)
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel)
  # Each entry is its own library (Pipelines.compile, MatCompiler, VFXCompiler, ViewportRenderer); the relative
  # `#include "Shaders/X.metal"` lines resolve from the entry's folder, as ShaderSource's splicing does. The two that
  # include Shaders/Intersect.metal are compiled with the ray queries' counters (RT_STATS) off and on.
  for entry in Sources/MetalRenderer/Shaders.metal Sources/MetalRenderer/ShadersVFX.metal \
               Sources/MetalRenderer/ShadersMaterial.metal Sources/MetalRenderer/ShadersMaterialCode.metal \
               Sources/Modeling/Shaders/Viewport.metal; do
    echo "== $entry"
    stats=(0)
    grep -q '"Shaders/Intersect.metal"' "$root/$entry" && stats=(0 1)
    for s in "${stats[@]}"; do
      compile "RT_STATS=$s" -fsyntax-only "$std" -DRT_STATS="$s" "$root/$entry" ${extra[@]+"${extra[@]}"}
    done
  done
  ;;

snippets)
  [[ ${#files[@]} -eq 0 ]] && { echo "usage: $0 --snippets file.md [...]" >&2; exit 64; }
  for md in "${files[@]}"; do
    # Split the ```metal blocks into numbered files; the first line of each is the block's line in the .md.
    rm -f "$tmp"/block-*
    awk -v dir="$tmp" '
      /^```metal[[:space:]]*$/ { n++; f = sprintf("%s/block-%03d", dir, n); print NR + 1 > f; inside = 1; next }
      inside && /^```/          { inside = 0; close(f); next }
      inside                    { print > f }
    ' "$md"
    for block in "$tmp"/block-*; do
      [[ -e "$block" ]] || continue
      line=$(head -1 "$block")
      first=$(sed -n 2p "$block")
      flags=()
      if [[ "$first" =~ ^//[[:space:]]*check:[[:space:]]*skip(.*)$ ]]; then
        echo "   skipped: $md:$line${BASH_REMATCH[1]}"
        continue
      elif [[ "$first" =~ ^//[[:space:]]*check:[[:space:]]*(.*)$ ]]; then
        read -r -a flags <<< "${BASH_REMATCH[1]}"
      fi
      src="$tmp/snippet.metal"
      {
        grep -q "#include <metal_stdlib>" "$block" || printf '#include <metal_stdlib>\nusing namespace metal;\n'
        echo "#line $line \"$md\""
        tail -n +2 "$block"
      } > "$src"
      compile "$md:$line" -fsyntax-only "$std" ${flags[@]+"${flags[@]}"} -I "$(dirname "$md")" \
        ${extra[@]+"${extra[@]}"} "$src"
    done
  done
  ;;

code)
  [[ ${#files[@]} -eq 0 ]] && { echo "usage: $0 --code body.metal [...]" >&2; exit 64; }
  root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel)
  # What MatCompiler compiles for a Code node: ShadersMaterialCode.metal, then `#line 1 "generated"` and the node's
  # text inside `MatCompiler.codeSource`'s wrapper, which is read from the Swift source so the two can't drift.
  wrapper=$(awk '/static func codeSource/ { f = 1; next } f && /"""/ { if (inside) exit; inside = 1; next } inside' \
    "$root/Sources/Materials/MaterialGraph/MatCompiler.swift")
  [[ "$wrapper" == *'\(body)'* ]] || { echo "check_shader: can't find MatCompiler.codeSource's wrapper" >&2; exit 2; }
  for body in "${files[@]}"; do
    echo "== $body"
    src="$tmp/code.metal"
    {
      cat "$root/Sources/MetalRenderer/ShadersMaterialCode.metal"
      printf '\n#line 1 "generated"\n'
      printf '%s\n' "${wrapper%%'\(body)'*}" | sed '$d'
      echo "#line 1 \"$body\""
      cat "$body"
      printf '%s\n' "${wrapper#*'\(body)'}"
    } > "$src"
    compile "$body" -fsyntax-only "$std" -I "$root/Sources/MetalRenderer" ${extra[@]+"${extra[@]}"} "$src"
  done
  ;;

files)
  [[ ${#files[@]} -eq 0 ]] && {
    echo "usage: $0 --repo | --snippets file.md [...] | --code body.metal [...] | file.metal [...] [-std=metal3.2] [-sdk iphoneos|macosx|xros] [-I dir] [-D NAME=VAL]" >&2
    exit 64
  }
  airs=()
  for f in "${files[@]}"; do
    air="$tmp/$(basename "${f%.metal}").air"
    echo "== $f"
    compile "$f" -c "$f" -o "$air" "$std" -I "$(dirname "$f")" ${extra[@]+"${extra[@]}"}
    [[ -e "$air" ]] && airs+=("$air")
  done
  # The link step catches duplicate symbols across files.
  if [[ $status -eq 0 && ${#airs[@]} -gt 1 ]]; then
    echo "== linking metallib"
    if "$(dirname "$metal")/metallib" "${airs[@]}" -o "$tmp/check.metallib"; then echo "   ok"; else status=1; fi
  fi
  ;;
esac

exit $status
