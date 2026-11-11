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
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
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
swiftc -O -swift-version 5 -target arm64-apple-macos14.2 Sources/CloudBridge.swift -o "$bundle/Contents/MacOS/uu-cloud-bridge"
cp LICENSE "$bundle/Contents/Resources/LICENSE.txt"
cp LICENSE-MicBridge-MIT.txt "$bundle/Contents/Resources/LICENSE-MicBridge-MIT.txt"
cp NativeMic/LICENSE-Hush-MIT.txt "$bundle/Contents/Resources/LICENSE-Hush-MIT.txt"
cp THIRD_PARTY_NOTICES.md "$bundle/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Distributable DMGs contain a separately signed and notarized driver beside
# the App. Apple notarization rejects an unsigned .pkg nested in Resources.
# Local developer builds can keep a test package for hardware acceptance.
if [[ "$UU_DISTRIBUTION_MODE" != "1" ]]; then
    if [[ ! -f NativeMic/build/UUMicNative-0.1.2.pkg ]]; then
        ./NativeMic/package.sh
    fi
    cp NativeMic/build/UUMicNative-0.1.2.pkg "$bundle/Contents/Resources/UUMicNative-0.1.2.pkg"
fi
cp INSTALL-MAC.md "$bundle/Contents/Resources/INSTALL-MAC.md"
# Bundle the driver inside the same app. Public builds must use a Developer
# ID-signed driver, built by NativeMic/build.sh before compiling this App.
if [[ ! -d NativeMic/build/UUMicNative.driver ]]; then
    ./NativeMic/build.sh
fi
cp -R NativeMic/build/UUMicNative.driver "$bundle/Contents/Resources/UUMicNative.driver"
codesign --verify --strict "$bundle/Contents/Resources/UUMicNative.driver"
if [[ "$UU_DISTRIBUTION_MODE" == "1" ]]; then
    driverTeam=$(/usr/bin/codesign -dv "$bundle/Contents/Resources/UUMicNative.driver" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')
    if [[ -z "$driverTeam" || "$driverTeam" == "not set" ]]; then
        echo "Distribution build requires a Developer ID-signed Native Mic driver" >&2
        exit 1
    fi
fi
# Local builds stay ad-hoc. Set UU_COMPANION_SIGN_IDENTITY to a
# Developer ID Application certificate for a stable production identity.
signIdentity="$UU_COMPANION_SIGN_IDENTITY"
if [[ -z "$signIdentity" || "$signIdentity" == "-" ]]; then
    codesign --force --deep --sign - "$bundle"
else
    # Hardened-runtime microphone helpers need explicit audio permission.
    codesign --force --options runtime --timestamp --entitlements Signing/Microphone.entitlements --sign "$signIdentity" "$bundle/Contents/MacOS/uu-sender"
    codesign --force --options runtime --timestamp --sign "$signIdentity" "$bundle/Contents/MacOS/uu-receiver"
    codesign --force --options runtime --timestamp --sign "$signIdentity" "$bundle/Contents/MacOS/uu-cloud-bridge"
    codesign --force --options runtime --timestamp --entitlements Signing/Microphone.entitlements --sign "$signIdentity" "$bundle"
fi
codesign --verify --deep --strict "$bundle"
echo "Built: $bundle"
