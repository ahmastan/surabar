#!/bin/bash
# Builds a Surabar release on the maintainer's Mac: a universal (Apple silicon and Intel), ad-hoc
# signed app with the Quran data from Surabar/Resources/Bundled, then
#   build/release/<version>/Surabar-<version>.dmg   for new installs (and the Homebrew cask)
#   build/release/<version>/Surabar-<version>.zip   for Sparkle updates
#   build/release/<version>/appcast.xml             the previous appcast plus this release
#   build/release/<version>/SHA256SUMS.txt and release-notes.md (this version's CHANGELOG.md section)
# The update is signed with the Sparkle key in the login Keychain (account "surabar").
# Nothing is published: the script ends by printing the command that does.
#
# Usage: tools/release.sh [--previous-appcast FILE] [--download-base URL] [--output DIR] [--notes FILE]
#   The version and build number come from project.yml; SURABAR_VERSION and SURABAR_BUILD override
#   them (for test builds). By default the previous appcast is downloaded from the latest release,
#   and the notes are this version's section of CHANGELOG.md.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
FEED_URL=https://github.com/ahmastan/surabar/releases/latest/download/appcast.xml
REQUIRED_RESOURCES=(quran.sqlite translation.sqlite translation.json UthmanicHafs_V22.ttf font.ttf)

previous_appcast=""
download_base=""
output=""
notes_file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --previous-appcast) previous_appcast=$2; shift 2 ;;
        --download-base) download_base=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        --notes) notes_file=$2; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

fail() { echo "release: $*" >&2; exit 1; }

version=${SURABAR_VERSION:-$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$ROOT/project.yml")}
build=${SURABAR_BUILD:-$(awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$ROOT/project.yml")}
[ -n "$version" ] && [ -n "$build" ] || fail "couldn't read the version and build number from project.yml"
download_base=${download_base:-https://github.com/ahmastan/surabar/releases/download/v$version}
output=${output:-$ROOT/build/release/$version}
echo "Surabar $version (build $build)"

# The data the app bundles. Without it the app builds but can't show the Quran.
for name in "${REQUIRED_RESOURCES[@]}"; do
    [ -f "$ROOT/Surabar/Resources/Bundled/$name" ] || fail "Surabar/Resources/Bundled/$name is missing: run python3 tools/prepare_app_resources.py"
done

# This version's release notes, from CHANGELOG.md ("## [0.1.0] - 2026-10-17" up to the next "## [").
if [ -n "$notes_file" ]; then
    notes=$(cat "$notes_file")
else
    notes=$(awk -v v="$version" 'index($0, "## [" v "]") == 1 {f=1; next} f && /^## \[/ {exit} f {print}' "$ROOT/CHANGELOG.md")
fi
[ -n "$(echo "$notes" | tr -d '[:space:]')" ] || fail "no release notes for $version in CHANGELOG.md"

# Sparkle's signing tools, checked against the release's published SHA-256.
tools="$ROOT/build/sparkle-$SPARKLE_VERSION"
if [ ! -x "$tools/bin/sign_update" ]; then
    mkdir -p "$tools"
    curl -fsSL -o "$tools/Sparkle-$SPARKLE_VERSION.tar.xz" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "$SPARKLE_SHA256  $tools/Sparkle-$SPARKLE_VERSION.tar.xz" | shasum -a 256 -c - >/dev/null || fail "Sparkle download doesn't match its checksum"
    tar -xf "$tools/Sparkle-$SPARKLE_VERSION.tar.xz" -C "$tools"
fi
"$tools/bin/generate_keys" --account surabar -p >/dev/null 2>&1 || fail "no Sparkle signing key for account \"surabar\" in the login Keychain"

# The previous appcast; the first release has none.
mkdir -p "$output"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ -z "$previous_appcast" ]; then
    previous_appcast="$work/previous-appcast.xml"
    if ! curl -fsSL -o "$previous_appcast" "$FEED_URL" 2>/dev/null; then
        echo "No published appcast yet: starting a new one."
        rm -f "$previous_appcast"
    fi
fi
if [ -f "$previous_appcast" ]; then
    latest=$(python3 -I -c 'import sys, xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(sys.argv[1]).getroot().iter("item")
print(max([int(i.findtext(ns + "version")) for i in items] or [0]))' "$previous_appcast")
    [ "$build" -ge "$latest" ] || fail "build $build is lower than the published build $latest"
    [ "$build" -gt "$latest" ] || echo "Build $build is already published: its appcast item will be replaced."
fi

# A universal Release build, ad-hoc signed by Xcode (CODE_SIGN_IDENTITY "-" in project.yml).
cd "$ROOT"
xcodegen generate --quiet
echo "Building (log: build/release/build.log)..."
if ! xcodebuild -project Surabar.xcodeproj -scheme Surabar -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build/release/DerivedData \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" ONLY_ACTIVE_ARCH=NO \
    clean build > "$ROOT/build/release/build.log" 2>&1; then
    grep -E ': error:' "$ROOT/build/release/build.log" | sort -u | head -20 >&2
    fail "the build failed"
fi
app="$ROOT/build/release/DerivedData/Build/Products/Release/Surabar.app"

# Checks before packaging.
archs=$(lipo -archs "$app/Contents/MacOS/Surabar")
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "the app isn't universal ($archs)"
codesign --verify --deep --strict "$app" || fail "the app's signature doesn't verify"
for name in "${REQUIRED_RESOURCES[@]}"; do
    [ -f "$app/Contents/Resources/$name" ] || fail "$name isn't in the built app"
done
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist"; }
[ "$(plist CFBundleShortVersionString)" = "$version" ] && [ "$(plist CFBundleVersion)" = "$build" ] || fail "the app's version doesn't match"
[ "$(plist SUFeedURL)" = "$FEED_URL" ] || fail "the app's SUFeedURL isn't $FEED_URL"
[ -n "$(plist SUPublicEDKey)" ] || fail "the app has no SUPublicEDKey"

# The update ZIP (ditto keeps the bundle's symlinks and signatures) and the DMG.
zip="$output/Surabar-$version.zip"
dmg="$output/Surabar-$version.dmg"
rm -f "$zip" "$dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
mkdir "$work/dmg"
ditto "$app" "$work/dmg/Surabar.app"
ln -s /Applications "$work/dmg/Applications"
hdiutil create -quiet -volname "Surabar $version" -srcfolder "$work/dmg" -fs HFS+ -format UDZO -ov "$dmg"
hdiutil verify -quiet "$dmg"

# Release notes, checksums, and the appcast with this release's signed update.
printf '%s\n' "$notes" | sed -e '/./,$!d' > "$output/release-notes.md"
signature=$("$tools/bin/sign_update" --account surabar -p "$zip")
length=$(stat -f %z "$zip")
python3 -I "$ROOT/tools/appcast.py" ${previous_appcast:+--previous "$previous_appcast"} --output "$output/appcast.xml" \
    --version "$version" --build "$build" --url "$download_base/Surabar-$version.zip" --length "$length" \
    --signature "$signature" --notes "$output/release-notes.md"
"$tools/bin/sign_update" --account surabar --verify "$zip" "$signature" >/dev/null || fail "the update's signature doesn't verify"
(cd "$output" && shasum -a 256 "Surabar-$version.dmg" "Surabar-$version.zip" > SHA256SUMS.txt)

echo
echo "Release files in $output:"
ls -lh "$output" | awk 'NR > 1 { print "  " $NF " (" $5 ")" }'
echo
echo "DMG SHA-256 (for the Homebrew cask): $(awk 'NR == 1 { print $1 }' "$output/SHA256SUMS.txt")"
echo
echo "To publish (after review):"
echo "  gh release create v$version \"$dmg\" \"$zip\" \"$output/appcast.xml\" \"$output/SHA256SUMS.txt\" \\"
echo "    --title \"Surabar $version\" --notes-file \"$output/release-notes.md\""
