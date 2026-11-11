#!/bin/zsh
# Generate a local-only unsigned macOS flat component installer using
# standard cpio, mkbom and xar. Distribution requires Developer ID Installer
# signing and notarization; this script is for development/acceptance only.
set -eu
cd "$(dirname "$0")"
./build.sh
mkdir -p pkgroot/Library/Audio/Plug-Ins/HAL pkg-scripts build manualpkg
rm -rf pkgroot/Library/Audio/Plug-Ins/HAL/UUMicNative.driver
cp -R build/UUMicNative.driver pkgroot/Library/Audio/Plug-Ins/HAL/
chmod -R a+rX pkgroot/Library/Audio/Plug-Ins/HAL/UUMicNative.driver
cat > pkg-scripts/postinstall <<'POST'
#!/bin/sh
set -eu
p="/Library/Audio/Plug-Ins/HAL/UUMicNative.driver"
/usr/sbin/chown -R root:wheel "$p"
/bin/chmod -R go-w "$p"
/bin/chmod -R a+rX "$p"
/usr/bin/codesign --verify --strict "$p"
/usr/bin/killall coreaudiod >/dev/null 2>&1 || true
exit 0
POST
chmod +x pkg-scripts/postinstall
rm -rf manualpkg
mkdir -p manualpkg
(cd pkgroot && find . -print | /usr/bin/cpio -o -H odc 2>/dev/null | /usr/bin/gzip -9 > ../manualpkg/Payload)
/usr/bin/mkbom pkgroot manualpkg/Bom
(cd pkg-scripts && find . -print | /usr/bin/cpio -o -H odc 2>/dev/null | /usr/bin/gzip -9 > ../manualpkg/Scripts)
cat > manualpkg/PackageInfo <<'PKG'
<?xml version="1.0" encoding="utf-8"?>
<pkg-info format-version="2" identifier="com.uucompanion.native.audio.installer" version="0.1.2" install-location="/" auth="root">
  <payload installKBytes="2800" numberOfFiles="16"/>
  <scripts><postinstall file="./postinstall"/></scripts>
</pkg-info>
PKG
out=build/UUMicNative-0.1.2.pkg
(cd manualpkg && /usr/bin/xar --compression none -cf "../$out" PackageInfo Payload Bom Scripts)
pkgutil --payload-files "$out" | grep -F 'UUMicNative.driver/Contents/MacOS/UUMicNative' >/dev/null
pkgutil --payload-files "$out" | grep -F 'LICENSE-Hush-MIT.txt' >/dev/null
echo "Staged local-only installer: $out"
