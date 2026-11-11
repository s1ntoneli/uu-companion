#!/bin/sh
set -eu
SRC="$(cd "$(dirname "$0")" && pwd)/build/UUMicNative.driver"
DEST="/Library/Audio/Plug-Ins/HAL/UUMicNative.driver"
[ -f "$SRC/Contents/MacOS/UUMicNative" ] || exit 3
/usr/bin/codesign --verify --strict "$SRC"
if [ -d "$DEST" ]; then
  /bin/mv "$DEST" "/Library/Audio/Plug-Ins/HAL/UUMicNative.driver.bak"
fi
/bin/cp -R "$SRC" "$DEST"
/usr/sbin/chown -R root:wheel "$DEST"
/bin/chmod -R go-w "$DEST"
/usr/bin/codesign --verify --strict "$DEST"
/usr/bin/killall coreaudiod || true
echo "uu native microphone installed; audio services restarted"
