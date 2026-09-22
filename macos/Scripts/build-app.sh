#!/bin/bash
# Builds "OpenSubtitles Uploader.app" (and optionally a .dmg) from the Swift package.
#
#   Scripts/build-app.sh            # release build → build/OpenSubtitles Uploader.app
#   Scripts/build-app.sh --dmg      # …and build/OpenSubtitles-Uploader-<version>-macOS.dmg
#   Scripts/build-app.sh --debug    # debug build
#
# Works with plain Command Line Tools (no Xcode.app required). Produces a universal
# (Apple silicon + Intel) binary when the toolchain supports it.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
NAME="OpenSubtitles Uploader"
EXECUTABLE="OpenSubtitlesUploader"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/OpenSubtitlesUploader/Support/Preferences.swift)"
CONFIG="release"
MAKE_DMG=0
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=1 ;;
        --debug) CONFIG="debug" ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

echo "▸ Building $NAME $VERSION ($CONFIG)…"
# Build one slice per architecture (the --arch flags need Xcode's build system) and
# merge them with lipo into a universal binary. Falls back to the native slice alone
# if the other one cannot be built on this machine.
BUILD_FLAGS=(-c "$CONFIG" --build-system native)
SLICES=()
for TRIPLE in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
    if swift build "${BUILD_FLAGS[@]}" --triple "$TRIPLE" 2>&1 | grep -vE "deprecated"; then
        SLICES+=("$(swift build "${BUILD_FLAGS[@]}" --triple "$TRIPLE" --show-bin-path 2>/dev/null)/$EXECUTABLE")
    else
        echo "  (could not build $TRIPLE, skipping that slice)"
    fi
done
[ "${#SLICES[@]}" -gt 0 ] || { echo "Build failed" >&2; exit 1; }
BIN_DIR="$(dirname "${SLICES[0]}")"

# Assemble and sign in a temporary folder: iCloud Drive / Finder keep re-adding extended
# attributes (com.apple.FinderInfo) to folders under ~/Documents, which makes codesign refuse
# the bundle ("resource fork, Finder information, or similar detritus not allowed").
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/osu-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$NAME.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
mkdir -p "$CONTENTS/MacOS" "$RES"

echo "▸ Assembling $APP"
if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create "${SLICES[@]}" -output "$CONTENTS/MacOS/$EXECUTABLE"
else
    cp "${SLICES[0]}" "$CONTENTS/MacOS/$EXECUTABLE"
fi
sed "s/__VERSION__/$VERSION/g" Info.plist > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp Sources/OpenSubtitlesUploader/Resources/AppIcon.icns "$RES/AppIcon.icns"
# SwiftPM resource bundle (Bundle.module) + localizations in the main bundle so that
# System Settings › Language & Region can offer a per-app language.
cp -R "$BIN_DIR/${EXECUTABLE}_${EXECUTABLE}.bundle" "$RES/"
for lproj in Sources/OpenSubtitlesUploader/Resources/*.lproj; do
    cp -R "$lproj" "$RES/"
done

# Finder metadata / extended attributes make codesign fail ("resource fork ... not allowed")
find "$APP" -name .DS_Store -delete
xattr -cr "$APP"

echo "▸ Signing (ad hoc)"
codesign --force --deep --sign - --identifier io.github.drzaphod85.opensubtitles-uploader "$APP"
codesign --verify --deep --strict "$APP"

FINAL="$ROOT/build/$NAME.app"
mkdir -p "$ROOT/build"
rm -rf "$FINAL"
ditto "$APP" "$FINAL"
APP="$FINAL"
echo "✓ $APP"

if [ "$MAKE_DMG" = 1 ]; then
    DMG="$ROOT/build/OpenSubtitles-Uploader-$VERSION-macOS.dmg"
    STAGING="$STAGE/dmg"
    rm -f "$DMG"
    mkdir -p "$STAGING"
    ditto "$STAGE/$NAME.app" "$STAGING/$NAME.app"   # the signed copy, untouched by Finder
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
    echo "✓ $DMG"
fi
