#!/bin/zsh
# Reproducible, credential-free Apple Silicon distributable staging ZIP.
# Requires two Developer ID Application-signed components.
set -e
cd "$(dirname "$0")/.."
if [[ -z "$UU_COMPANION_SIGN_IDENTITY" || -z "$UU_DRIVER_SIGN_IDENTITY" ||
      "$UU_COMPANION_SIGN_IDENTITY" == "-" || "$UU_DRIVER_SIGN_IDENTITY" == "-" ]]; then
  echo "Provide UU_COMPANION_SIGN_IDENTITY and UU_DRIVER_SIGN_IDENTITY (Developer ID Application)" >&2
  exit 2
fi
label="$1"
if [[ -z "$label" ]]; then label="v0.2.0-preview3"; fi
./NativeMic/build.sh
UU_DISTRIBUTION_MODE=1 ./build.sh
app="build/uu伴侣.app"
driver="NativeMic/build/UUMicNative.driver"
codesign --verify --deep --strict "$app"
codesign --verify --strict "$driver"
if [[ -e "$app/Contents/Resources/UUMicNative-0.1.2.pkg" ]]; then
  echo "Public App incorrectly embeds unsigned pkg" >&2
  exit 3
fi
mkdir -p build/release
folder="build/release/uu伴侣-$label-macOS"
archive="build/release/uu-companion-$label-macOS-arm64.zip"
rm -rf "$folder"
mkdir -p "$folder"
cp -R "$app" "$folder/"
cp -R "$driver" "$folder/"
cp INSTALL-MAC.md "$folder/安装说明.md"
ln -s /Applications "$folder/Applications"
ln -s /Library/Audio/Plug-Ins/HAL "$folder/音频插件位置"
ditto -c -k --sequesterRsrc --keepParent "$folder" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
echo "Built signed ZIP: $archive"
echo "Submit this exact ZIP to Apple and require status Accepted before publication."
