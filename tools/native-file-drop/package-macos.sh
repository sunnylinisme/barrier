#!/bin/sh
set -eu
BUILD="${1:?build directory}"
APP="$BUILD/Barrier Share.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources/licenses" "$APP/Contents/Frameworks"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos15.0" -O \
    -framework AppKit -framework ApplicationServices \
    tools/native-file-drop/BarrierShareMac.swift -o "$APP/Contents/MacOS/BarrierShare"
cp "$BUILD/bin/barriers" "$BUILD/bin/barrierc" "$BUILD/bin/barrier-pair" "$BUILD/bin/barrier-link" "$APP/Contents/Helpers/"
cp tools/native-file-drop/GUI-README.txt LICENSE "$APP/Contents/Resources/"
cp tools/native-file-drop/icons/BarrierShare.icns "$APP/Contents/Resources/"
cp tools/native-file-drop/licenses/* "$APP/Contents/Resources/licenses/"
git rev-parse HEAD > "$APP/Contents/Resources/COMMIT.txt"
python3 - "$APP" <<'PY'
import pathlib, plistlib, shutil, subprocess, sys
app = pathlib.Path(sys.argv[1]).resolve()
contents = app / 'Contents'
with (contents / 'Info.plist').open('wb') as out:
    plistlib.dump(dict(CFBundleIdentifier='org.barriershare.desktop', CFBundleName='Barrier Share',
        CFBundleDisplayName='Barrier Share', CFBundleExecutable='BarrierShare', CFBundlePackageType='APPL',
        CFBundleVersion='5', CFBundleShortVersionString='0.3.2', CFBundleIconFile='BarrierShare.icns', LSMinimumSystemVersion='15.0',
        NSHighResolutionCapable=True, NSPrincipalClass='NSApplication',
        NSLocalNetworkUsageDescription='搜尋同一區域網路的電腦，經雙方同意後配對，共用鍵鼠與複製檔案。'), out)
# Homebrew builds need their OpenSSL libraries bundled; local static builds have none.
frameworks = contents / 'Frameworks'
queue = list((contents / 'Helpers').iterdir()) + list((contents / 'MacOS').iterdir())
seen = set()
while queue:
    binary = queue.pop(0)
    if binary in seen: continue
    seen.add(binary)
    dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]
    for line in dependencies:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith(('/System/', '/usr/lib/')): continue
        if binary.parent == frameworks and pathlib.Path(dependency).name == binary.name: continue
        if not dependency.startswith('/'):
            raise RuntimeError('Unresolved non-system dependency: ' + dependency)
        target = frameworks / pathlib.Path(dependency).name
        if not target.exists(): shutil.copy2(dependency, target); queue.append(target)
        relative = '@loader_path/' + ('' if binary.parent == frameworks else '../Frameworks/') + target.name
        subprocess.run(['install_name_tool', '-change', dependency, relative, str(binary)], check=True)
    if binary.parent == frameworks:
        subprocess.run(['install_name_tool', '-id', '@rpath/' + binary.name, str(binary)], check=True)
for binary in seen:
    subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True)
PY
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/BarrierShare" --self-test "$BUILD/gui-test"
cat "$BUILD/gui-test/PASS.txt"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$BUILD/barrier-cross-drop-macos-arm64.zip"
