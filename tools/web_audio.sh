#!/usr/bin/env bash
# MP3 copies of the game's sounds for the browser version (app/web/audio/,
# served next to the web build only, so the APK doesn't carry them). Safari
# on older iPhones can't play the Ogg Vorbis files the app uses.
# Re-run after changing anything in app/assets/audio/. Needs ffmpeg with lame.
set -euo pipefail
cd "$(dirname "$0")/.."
out=app/web/audio
mkdir -p "$out"
for f in app/assets/audio/*.ogg; do
  name=$(basename "$f" .ogg)
  case "$name" in
    music_*|forge_ambience) q=4 ;;  # loops: VBR ~165 kbps
    *) q=6 ;;                        # short effects: VBR ~115 kbps
  esac
  ffmpeg -v error -y -i "$f" -codec:a libmp3lame -q:a "$q" "$out/$name.mp3"
done
du -sh "$out"
