#!/bin/bash
# 下载 TVVLCKit（VLC 播放引擎，LGPL）到 ThirdParty/TVVLCKit/。编译前需要先执行一次。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="3.7.2"
URL="https://download.videolan.org/cocoapods/prod/TVVLCKit-3.7.2-3e42ae47-79128878.tar.xz"
DEST="ThirdParty/TVVLCKit"
if [ -d "$DEST/TVVLCKit.xcframework" ]; then echo "TVVLCKit $VERSION already present"; exit 0; fi
tmp=$(mktemp -d)
curl -sfL "$URL" -o "$tmp/tvvlckit.tar.xz"
tar -xJf "$tmp/tvvlckit.tar.xz" -C "$tmp"
mkdir -p "$DEST"
cp -R "$tmp/TVVLCKit-binary/TVVLCKit.xcframework" "$DEST/"
cp "$tmp/TVVLCKit-binary/COPYING.txt" "$DEST/COPYING.txt"
rm -rf "$tmp"
du -sh "$DEST"
