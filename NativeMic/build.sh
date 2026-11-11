#!/bin/zsh
set -e
cd "$(dirname "$0")"
umask 022
mkdir -p build .clang-cache .tmp
export CLANG_MODULE_CACHE_PATH="$PWD/.clang-cache"
export TMPDIR="$PWD/.tmp"
b=build/UUMicNative.driver
rm -rf "$b"
mkdir -p "$b/Contents/MacOS" "$b/Contents/Resources"
swiftc -O -parse-as-library -emit-library -Xlinker -bundle -target arm64-apple-macos14.2 -module-name UUMicNative -framework CoreAudio -framework CoreFoundation src/NativeMic.swift -o "$b/Contents/MacOS/UUMicNative"
cp Info.plist "$b/Contents/Info.plist"
cp LICENSE-Hush-MIT.txt "$b/Contents/Resources/LICENSE-Hush-MIT.txt"
chmod 644 "$b/Contents/Info.plist" "$b/Contents/Resources/LICENSE-Hush-MIT.txt"
chmod 755 "$b/Contents/MacOS/UUMicNative"
signIdentity="$UU_DRIVER_SIGN_IDENTITY"
if [[ -z "$signIdentity" || "$signIdentity" == "-" ]]; then
    codesign --force --sign - "$b"
else
    codesign --force --options runtime --timestamp --sign "$signIdentity" "$b"
fi
codesign --verify --strict "$b"
echo "Native driver built: $b"
