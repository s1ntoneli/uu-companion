#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Assets/uucompanion.iconset
/usr/bin/swift Assets/make-icon.swift Assets/uucompanion-1024.png
for p in '16:16x16' '32:16x16@2x' '32:32x32' '64:32x32@2x' '128:128x128' '256:128x128@2x' '256:256x256' '512:256x256@2x' '512:512x512' '1024:512x512@2x'; do
  dim="${p%%:*}"
  label="${p#*:}"
  /usr/bin/sips -s format png -z "$dim" "$dim" Assets/uucompanion-1024.png --out "Assets/uucompanion.iconset/icon_${label}.png" >/dev/null
done
/usr/bin/iconutil -c icns Assets/uucompanion.iconset -o Assets/uucompanion.icns
echo "Rendered Assets/uucompanion.icns"
