#!/bin/sh
# Build, sign and verify the Mac app, then start the shared vX.Y.Z release of Barrier Share.
#
#   BARRIER_CODESIGN_IDENTITY='Apple Development: NAME (TEAMID)' sh tools/native-file-drop/release-macos.sh
#
# Run from the repository root on an Apple Silicon Mac with Xcode command line tools,
# Homebrew cmake and openssl@3, and the GitHub CLI signed in (gh auth login).
# The version comes from package-macos.sh and must match windows-setup.iss; the notes
# come from GUI-README.txt ("X.Y.Z 更新（Windows）" and "X.Y.Z 更新（Mac）"). The installed
# app at OLD_APP (default: /Applications) is checked for a compatible signing identity
# before anything is published. This pushes the tag and creates a draft release with the
# Mac ZIP; the vX.Y.Z tag build in GitHub Actions then attaches the Windows installer and
# portable ZIP and publishes the release, so clients only see it once both are there.
set -eu
: "${BARRIER_CODESIGN_IDENTITY:?Set the fixed signing identity used for earlier Mac releases}"
if [ "$BARRIER_CODESIGN_IDENTITY" = "-" ]; then
    echo "An ad-hoc signature cannot be released: macOS would drop the granted permissions." >&2; exit 1
fi
OLD_APP="${OLD_APP:-/Applications/Barrier Share.app}"
BUILD="${BUILD:-build-release}"

version=$(sed -n "s/.*CFBundleShortVersionString='\([0-9.]*\)'.*/\1/p" tools/native-file-drop/package-macos.sh)
tag="v$version"
[ -n "$version" ] || { echo "Cannot read the Mac version from package-macos.sh" >&2; exit 1; }
grep -q "#define AppVersion \"$version\"" tools/native-file-drop/windows-setup.iss || { echo "windows-setup.iss is not at $version; both platforms share one release" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash local changes first" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in first: gh auth login" >&2; exit 1; }
if gh release view "$tag" >/dev/null 2>&1; then echo "$tag is already published" >&2; exit 1; fi
notes=$(mktemp)
for platform in Windows Mac; do
    section=$(awk -v head="$version 更新（$platform）" '$0==head{on=1} on&&/^$/{exit} on' tools/native-file-drop/GUI-README.txt)
    [ -n "$section" ] || { echo "GUI-README.txt has no \"$version 更新（$platform）\" section" >&2; exit 1; }
    printf '%s\n\n' "$section" >> "$notes"
done
cat >> "$notes" <<EOF
下載
- Windows 10/11 x64：BarrierShare-Setup-$version-x64.exe（安裝版；安裝前先從系統匣選「結束」，會保留配對及設定）或 BarrierShare-$version-x64-portable.zip（免安裝）
- Apple Silicon Mac（macOS 15+）：BarrierShare-$version-macos-arm64.zip；解壓縮後將 Barrier Share.app 放到「應用程式」取代舊版，更新前先結束舊程式
EOF

echo "== Building Barrier Share for Mac $version"
rm -rf "$BUILD"
cmake -S . -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBARRIER_BUILD_GUI=OFF -DBARRIER_BUILD_INSTALLER=OFF -DBARRIER_BUILD_TESTS=OFF \
    -DBARRIER_USE_SYSTEM_OPENSSL=ON -DBARRIER_NATIVE_DROP_TESTS=ON \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)"
cmake --build "$BUILD" --parallel
ctest --test-dir "$BUILD" --output-on-failure
sh tools/native-file-drop/package-macos.sh "$BUILD"

echo "== Checking the update keeps the signing identity of $OLD_APP"
if [ -d "$OLD_APP" ]; then
    python3 tools/native-file-drop/verify-macos-update.py "$OLD_APP" "$BUILD/Barrier Share.app"
else
    echo "No installed app at $OLD_APP; set OLD_APP to the previous release to compare." >&2; exit 1
fi

zip="$BUILD/BarrierShare-$version-macos-arm64.zip"
mv "$BUILD/barrier-cross-drop-macos-arm64.zip" "$zip"
echo "== Publishing $tag"
git tag -a "$tag" -m "Barrier Share $version"
git push origin "$tag"
gh release create "$tag" "$zip" --draft --title "Barrier Share $version" --notes-file "$notes" --verify-tag
rm -f "$notes"
echo "Draft created. The $tag build in GitHub Actions adds the Windows files and publishes it:"
echo "  gh run list --branch $tag"
