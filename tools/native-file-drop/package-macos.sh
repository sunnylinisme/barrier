#!/bin/sh
set -eu
BUILD="${1:?build directory}"
PACKAGE="$BUILD/Barrier Cross Drop"
mkdir -p "$PACKAGE"
cp "$BUILD/bin/barriers" "$BUILD/bin/barrier-pair" "$PACKAGE/"
cp tools/native-file-drop/Start-Mac.command tools/native-file-drop/README.md LICENSE "$PACKAGE/"
cp -R tools/native-file-drop/licenses "$PACKAGE/"
chmod +x "$PACKAGE/Start-Mac.command"
for PROGRAM in barriers barrier-pair; do
    codesign --force --sign - "$PACKAGE/$PROGRAM"
    otool -L "$PACKAGE/$PROGRAM"
done
git rev-parse HEAD > "$PACKAGE/COMMIT.txt"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE" "$BUILD/barrier-cross-drop-macos-arm64.zip"
