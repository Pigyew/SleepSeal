#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$(uname -s)" != "Darwin" ]; then
    echo "App icon packaging requires macOS sips and iconutil." >&2
    exit 1
fi
if [ "$#" -gt 1 ]; then
    echo "Usage: ./make-icon.sh [square-transparent.png]" >&2
    exit 1
fi
MASTER=${1:-"$ROOT/Resources/AppIcon.png"}
if [ ! -f "$MASTER" ]; then
    echo "Missing app icon master: $MASTER" >&2
    exit 1
fi
METADATA=$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight -g hasAlpha "$MASTER")
FORMAT=$(printf '%s\n' "$METADATA" | /usr/bin/awk '/^[[:space:]]+format:/ {print $2}')
WIDTH=$(printf '%s\n' "$METADATA" | /usr/bin/awk '/^[[:space:]]+pixelWidth:/ {print $2}')
HEIGHT=$(printf '%s\n' "$METADATA" | /usr/bin/awk '/^[[:space:]]+pixelHeight:/ {print $2}')
ALPHA=$(printf '%s\n' "$METADATA" | /usr/bin/awk '/^[[:space:]]+hasAlpha:/ {print $2}')
if [ "$FORMAT" != "png" ] || [ "$WIDTH" != "$HEIGHT" ] || [ "$WIDTH" -lt 1024 ] || [ "$ALPHA" != "yes" ]; then
    echo "App icon master must be a square PNG of at least 1024 pixels with an alpha channel." >&2
    exit 1
fi

ICONSET="$ROOT/build/AppIcon.iconset"
OUTPUT="$ROOT/build/AppIcon.icns"
TEMP_OUTPUT="$ROOT/build/AppIcon.building.icns"
/bin/mkdir -p "$ICONSET"
trap '/bin/rm -f "$TEMP_OUTPUT"' EXIT HUP INT TERM
for SIZE in 16 32 128 256 512; do
    DOUBLE=$((SIZE * 2))
    /usr/bin/sips -z "$SIZE" "$SIZE" "$MASTER" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    /usr/bin/sips -z "$DOUBLE" "$DOUBLE" "$MASTER" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns "$ICONSET" --output "$TEMP_OUTPUT"
/bin/mv -f "$TEMP_OUTPUT" "$OUTPUT"
echo "App icon packaged: $OUTPUT"
