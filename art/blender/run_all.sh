#!/usr/bin/env bash
# Re-render every Wordsmith 3D asset from scratch, reproducibly.
#
#   ./run_all.sh                 # everything (~2 h on 4 CPU cores)
#   ./run_all.sh tiles icon      # only some: tiles anvil cells icon hammer ui hall tin copper bronze
#                                #   iron steel silver gold damascus starmetal
#   QUICK=1 ./run_all.sh hall    # fast low-res/low-sample preview render
#
# Env: BLENDER  path to the Blender binary (default /opt/blender/blender)
#      PYTHON   python3 with Pillow + numpy for post-processing (default python3)
set -euo pipefail
cd "$(dirname "$0")"

BLENDER="${BLENDER:-/opt/blender/blender}"
PYTHON="${PYTHON:-python3}"
QUICK="${QUICK:-0}"

if [ ! -x "$BLENDER" ]; then
  echo "Blender not found at $BLENDER (set BLENDER=...). See README.md." >&2
  exit 1
fi

ALL=(tiles anvil cells icon hammer ui hall tin copper bronze iron steel silver gold damascus starmetal)
WANT=("$@")
[ ${#WANT[@]} -eq 0 ] && WANT=("${ALL[@]}")

# 1. third-party textures/fonts (pinned URLs + sha256 in sources.json)
"$PYTHON" fetch_assets.py

blend() {   # blend <script> [args...]
  local script="$1"; shift
  echo "== $script $*"
  local t0=$SECONDS
  "$BLENDER" -b --factory-startup -noaudio -P "$script" -- "$@" 2>&1 \
    | grep -E "^\[render\]|Error|Traceback|rror:" || true
  echo "   done in $((SECONDS - t0)) s"
}

quick() {   # extra args for a quick preview render
  if [ "$QUICK" = "1" ]; then echo "$@"; fi
}

POST=()
for w in "${WANT[@]}"; do
  case "$w" in
    tiles)  blend tiles.py      $(quick --samples 32 --res 384);  POST+=(tiles) ;;
    anvil)  blend anvil_face.py $(quick --samples 24 --res 640);  POST+=(anvil) ;;
    cells)  blend cells.py      $(quick --samples 32 --res 256 --grid 200); POST+=(cells) ;;
    icon)   blend icon.py       $(quick --samples 32 --res 512);  POST+=(icon) ;;
    hammer) blend hammer_sprite.py $(quick --samples 24 --res 384); POST+=(hammer) ;;
    ui)     blend ui_kit.py     $(quick --samples 32 --ss 1);     POST+=(ui) ;;
    hall)   blend scene_hall.py   $(quick --samples 24 --scale 0.3); POST+=(bg) ;;
    tin)    blend scene_tin.py    $(quick --samples 24 --scale 0.3); POST+=(bg) ;;
    copper) blend scene_copper.py $(quick --samples 24 --scale 0.3); POST+=(bg) ;;
    bronze|iron|steel|silver|gold|damascus|starmetal)
            blend "scene_$w.py" $(quick --samples 24 --scale 0.3); POST+=(bg) ;;
    *) echo "unknown asset '$w' (choose from: ${ALL[*]})" >&2; exit 1 ;;
  esac
done

# 2. post-processing: downscale, masks, glow layers, WebP -> app/assets/images, app/assets/ui,
#    art/icon. Backgrounds are only ever written from native 1080x2340 renders; QUICK previews
#    (rendered at --scale 0.3) are upscaled for a look, never for shipping.
"$PYTHON" post.py $(printf '%s\n' "${POST[@]}" | awk '!seen[$0]++') \
  $([ "$QUICK" = "1" ] && echo --allow-upscale)

echo "Render log: _renders/render_times.log"
