#!/usr/bin/env bash
# Regenerate medo's bundled assets: the header font, the four mascot PNGs and
# the three sound cues. Everything here is reproducible from the sources in
# medo/assets/ — the PNGs and .ogg files are build output, committed so the
# plugin ships complete.
#
#   ./tools/gen-assets.sh          regenerate what is missing or stale
#   ./tools/gen-assets.sh --all    force everything (re-downloads the font)
#
# Requires: curl, ffmpeg (with libvorbis) and ImageMagick with an SVG delegate
# (`magick -list format | grep SVG`). Baloo 2 is SIL OFL 1.1; the licence text is
# written next to the font.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$ROOT/medo/assets"
FORCE=0
[[ "${1:-}" == "--all" ]] && FORCE=1

# Baloo 2 SemiBold, served by Google Fonts as a static instance of weight 600.
# The variable font in google/fonts would need instancing at build time; this
# URL gives the exact cut the plugin uses and keeps fontTools out of the loop.
FONT_URL="https://fonts.gstatic.com/s/baloo2/v23/wXK0E3kTposypRydzVT08TS3JnAmtdjEyqpv.ttf"
OFL_URL="https://raw.githubusercontent.com/google/fonts/main/ofl/baloo2/OFL.txt"

for tool in curl ffmpeg magick; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libvorbis \
  || { echo "ffmpeg has no libvorbis encoder" >&2; exit 1; }

mkdir -p "$ASSETS/fonts" "$ASSETS/mascot" "$ASSETS/sounds"

# ── font ────────────────────────────────────────────────────────────────────
if [[ $FORCE -eq 1 || ! -s "$ASSETS/fonts/Baloo2-SemiBold.ttf" ]]; then
  echo "font   Baloo2-SemiBold.ttf"
  curl -fsSL -o "$ASSETS/fonts/Baloo2-SemiBold.ttf" "$FONT_URL"
fi
if [[ $FORCE -eq 1 || ! -s "$ASSETS/fonts/OFL.txt" ]]; then
  echo "font   OFL.txt"
  curl -fsSL -o "$ASSETS/fonts/OFL.txt" "$OFL_URL"
fi

# ── mascot: SVG source at 64 units, rasterised at 2× (128 px) ───────────────
for state in sleepy focused proud worried; do
  source="$ASSETS/mascot/$state.svg"
  target="$ASSETS/mascot/$state.png"
  if [[ $FORCE -eq 1 || ! -f "$target" || "$source" -nt "$target" ]]; then
    echo "mascot $state.png"
    magick -background none "$source" -resize 128x128 "$target"
  fi
done

# ── sounds: synthesised, short and quiet ────────────────────────────────────
# chime — one soft bell when a task reaches 100 %
if [[ $FORCE -eq 1 || ! -s "$ASSETS/sounds/chime.ogg" ]]; then
  echo "sound  chime.ogg"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "aevalsrc=0.18*sin(2*PI*880*t)*exp(-7*t)+0.09*sin(2*PI*1320*t)*exp(-9*t):d=0.5:s=44100" \
    -af "afade=t=out:st=0.35:d=0.15" -c:a libvorbis -q:a 3 "$ASSETS/sounds/chime.ogg"
fi

# jingle — three rising notes when the whole list is done
if [[ $FORCE -eq 1 || ! -s "$ASSETS/sounds/jingle.ogg" ]]; then
  echo "sound  jingle.ogg"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "aevalsrc=0.16*sin(2*PI*523.25*t)*exp(-7*t):d=0.3:s=44100" \
    -f lavfi -i "aevalsrc=0.16*sin(2*PI*659.25*t)*exp(-7*t):d=0.3:s=44100" \
    -f lavfi -i "aevalsrc=0.18*sin(2*PI*783.99*t)*exp(-6*t):d=0.4:s=44100" \
    -filter_complex "[0]adelay=0|0[a];[1]adelay=170|170[b];[2]adelay=340|340[c];[a][b][c]amix=inputs=3:duration=longest,afade=t=out:st=0.55:d=0.2" \
    -c:a libvorbis -q:a 3 "$ASSETS/sounds/jingle.ogg"
fi

# thud — one low, dry knock when a task is dropped
if [[ $FORCE -eq 1 || ! -s "$ASSETS/sounds/thud.ogg" ]]; then
  echo "sound  thud.ogg"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "aevalsrc=0.3*sin(2*PI*90*t)*exp(-16*t)+0.05*sin(2*PI*45*t)*exp(-9*t):d=0.28:s=44100" \
    -af "afade=t=out:st=0.2:d=0.08" -c:a libvorbis -q:a 3 "$ASSETS/sounds/thud.ogg"
fi

echo
echo "assets in $ASSETS"
find "$ASSETS" -type f -printf '  %-38p %8s bytes\n' | sort
