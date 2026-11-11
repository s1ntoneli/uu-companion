#!/bin/zsh
set -e
cd "$(dirname "$0")"
mkdir -p build .clang-cache .swift-cache .tmp
export CLANG_MODULE_CACHE_PATH="$PWD/.clang-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.swift-cache"
export TMPDIR="$PWD/.tmp"
bundle="build/uu伴侣.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.uu.companion</string>
<key>CFBundleName</key><string>uu伴侣</string>
<key>CFBundleDisplayName</key><string>uu伴侣</string>
<key>CFBundleExecutable</key><string>uu-companion</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>uu伴侣在远程 Mac 开始录音时使用本机麦克风，并将声音传送到配对的 Mac。</string>
<key>NSLocalNetworkUsageDescription</key><string>uu伴侣通过局域网连接配对的 Mac 并传输麦克风声音。</string>
<key>NSBonjourServices</key><array><string>_uucompanion._tcp</string></array>
</dict></plist>
PLIST
swiftc -O -swift-version 5 -target arm64-apple-macos14.2 Sources/Sender.swift -o "$bundle/Contents/MacOS/uu-sender"
swiftc -O -swift-version 5 -target arm64-apple-macos14.2 Sources/Receiver.swift -o "$bundle/Contents/MacOS/uu-receiver"
swiftc -O -swift-version 5 -target arm64-apple-macos14.2 Sources/CompanionApp.swift -o "$bundle/Contents/MacOS/uu-companion"
cp LICENSE "$bundle/Contents/Resources/THIRD_PARTY_LICENSE.txt"
# Local builds stay ad-hoc. Set UU_COMPANION_SIGN_IDENTITY to a
# Developer ID Application certificate for a stable production identity.
signIdentity="$UU_COMPANION_SIGN_IDENTITY"
if [[ -z "$signIdentity" || "$signIdentity" == "-" ]]; then
    codesign --force --deep --sign - "$bundle"
else
    codesign --force --deep --options runtime --timestamp --sign "$signIdentity" "$bundle"
fi
codesign --verify --deep --strict "$bundle"
echo "Built: $bundle"
