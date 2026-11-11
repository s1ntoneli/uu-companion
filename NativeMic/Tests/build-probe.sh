#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
mkdir -p build .clang-cache .tmp
export CLANG_MODULE_CACHE_PATH="$PWD/.clang-cache"
export TMPDIR="$PWD/.tmp"
swiftc -swift-version 5 -target arm64-apple-macos14.2 -O Tests/NativeMicProbe.swift -o build/uu-native-probe
echo "Built native audio probe. Run only after installing native driver."
