#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_dir=${1:?Usage: build-macos.sh OUTPUT_DIRECTORY}
app="$output_dir/Barrier Drop Probe.app"
mkdir -p "$app/Contents/MacOS"
clang++ -std=c++14 -fobjc-arc -Wall -Wextra -Werror \
    -mmacosx-version-min=11.0 "$source_dir/MacProbe.mm" \
    -framework Cocoa -o "$app/Contents/MacOS/native-drop-probe"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>native-drop-probe</string>
<key>CFBundleIdentifier</key><string>org.barrier.native-drop-probe</string>
<key>CFBundleName</key><string>Barrier Drop Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
"$app/Contents/MacOS/native-drop-probe" --self-test
