#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
icon_source="assets/app-icon.png"
icon_set=".build/NetPulse.iconset"
mkdir -p "$icon_set"
for icon_size in 16 32 128 256 512; do
    sips -z "$icon_size" "$icon_size" "$icon_source" --out "$icon_set/icon_${icon_size}x${icon_size}.png" >/dev/null
    icon_retina_size=$((icon_size * 2))
    sips -z "$icon_retina_size" "$icon_retina_size" "$icon_source" --out "$icon_set/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_set" -o assets/NetPulse.icns
printf 'Icon: %s/assets/NetPulse.icns\n' "$PWD"
