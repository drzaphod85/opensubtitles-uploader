#!/bin/bash
# Builds "OpenSubtitles Uploader.app" (and optionally a .dmg) from the Swift package.
#
#   Scripts/build-app.sh             # release build → build/OpenSubtitles Uploader.app
#   Scripts/build-app.sh --dmg       # …and build/OpenSubtitles-Uploader-<version>-macOS.dmg
#   Scripts/build-app.sh --notarize  # …DMG notarized by Apple and stapled (implies --dmg)
#   Scripts/build-app.sh --debug     # debug build
#   Scripts/build-app.sh --install   # …and install to ~/Applications (no admin rights needed)
#   Scripts/build-app.sh --release   # notarized DMG → GitHub release v<VERSION> → Homebrew cask (implies --notarize)
#
# Releasing: the code must be committed and pushed. The DMG is uploaded to the GitHub release v<VERSION> (created
# with the notes in RELEASE_NOTES.md when that file exists, else GitHub's generated notes; an existing release gets
# its DMG replaced). Then version and sha256 in Casks/opensubtitles-uploader.rb of the tap (TAP_DIR, default
# ../../homebrew-tap, cloned from drzaphod85/homebrew-tap when missing) are updated, committed and pushed.
#
# Signing: with a "Developer ID Application" certificate in the keychain the app is signed with it
# (hardened runtime + secure timestamp); otherwise it is signed ad hoc. Override the certificate with
# SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" or force ad hoc with SIGN_IDENTITY="-".
#
# Notarizing needs credentials stored once with:
#   xcrun notarytool store-credentials <profile> --apple-id <apple id> --team-id <TEAMID>
# (asks for an app-specific password from appleid.apple.com). The profile name is taken from
# NOTARY_PROFILE (default "VideoCleaner", the profile already used for the author's other app).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SCRATCH="${TMPDIR:-/tmp}/OpenSubtitlesUploader-build"   # outside iCloud Drive: its xattrs break codesign
NAME="OpenSubtitles Uploader"
EXECUTABLE="OpenSubtitlesUploader"
BUNDLE_ID="io.github.drzaphod85.opensubtitles-uploader"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/OpenSubtitlesUploader/Support/Preferences.swift)"
DMG_NAME="OpenSubtitles-Uploader-$VERSION-macOS.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-VideoCleaner}"
REPO="drzaphod85/opensubtitles-uploader"
BRANCH="master"
TAP_REPO="drzaphod85/homebrew-tap"
TAP_DIR="${TAP_DIR:-$ROOT/../../homebrew-tap}"
CASK="Casks/opensubtitles-uploader.rb"
CONFIG="release"
MAKE_DMG=0
NOTARIZE=0
INSTALL=0
RELEASE=0
for arg in "$@"; do
    case "$arg" in
        --dmg) MAKE_DMG=1 ;;
        --notarize) MAKE_DMG=1; NOTARIZE=1 ;;
        --debug) CONFIG="debug" ;;
        --install) INSTALL=1 ;;
        --release) MAKE_DMG=1; NOTARIZE=1; RELEASE=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
if [ "$NOTARIZE" = 1 ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Notarizing needs a Developer ID Application certificate in the keychain." >&2
    exit 1
fi

if [ "$RELEASE" = 1 ]; then
    # Release exactly what is on GitHub: the tag is made from the pushed commit
    command -v gh >/dev/null || { echo "Releasing needs the GitHub CLI (gh)." >&2; exit 1; }
    if [ -n "$(git status --porcelain)" ]; then
        echo "Commit your changes before releasing." >&2; exit 1
    fi
    git fetch -q origin
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$BRANCH")" ]; then
        echo "Push $BRANCH before releasing (HEAD is not origin/$BRANCH)." >&2; exit 1
    fi
fi

# iCloud Drive sometimes creates "File 2.swift" duplicates that break the build
find Sources Tests -name "* 2.*" -delete 2>/dev/null || true

echo "▸ Building $NAME $VERSION ($CONFIG)…"
# Universal binary (Apple silicon + Intel). With Xcode the --arch flags do it in one go; with the
# Command Line Tools alone each architecture is built separately and merged with lipo.
BUNDLE_DIR=""
if swift build --scratch-path "$SCRATCH" -c "$CONFIG" --arch arm64 --arch x86_64 >/dev/null 2>&1; then
    BIN_DIR="$(swift build --scratch-path "$SCRATCH" -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)"
    SLICES=("$BIN_DIR/$EXECUTABLE")
else
    SLICES=()
    for TRIPLE in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
        if swift build --scratch-path "$SCRATCH" -c "$CONFIG" --build-system native --triple "$TRIPLE" >/dev/null 2>&1; then
            SLICES+=("$(swift build --scratch-path "$SCRATCH" -c "$CONFIG" --build-system native --triple "$TRIPLE" --show-bin-path 2>/dev/null)/$EXECUTABLE")
        else
            echo "  (could not build $TRIPLE, skipping that slice)"
        fi
    done
    [ "${#SLICES[@]}" -gt 0 ] || { echo "Build failed; run 'swift build' to see the errors." >&2; exit 1; }
    BIN_DIR="$(dirname "${SLICES[0]}")"
fi

# Assemble, sign and notarize in a temp folder (iCloud/Finder add xattrs that codesign rejects)
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/osu-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$NAME.app"
CONTENTS="$APP/Contents"
RES="$CONTENTS/Resources"
mkdir -p "$CONTENTS/MacOS" "$RES"

if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create "${SLICES[@]}" -output "$CONTENTS/MacOS/$EXECUTABLE"
else
    cp "${SLICES[0]}" "$CONTENTS/MacOS/$EXECUTABLE"
fi
echo "  architectures: $(lipo -archs "$CONTENTS/MacOS/$EXECUTABLE")"
sed "s/__VERSION__/$VERSION/g" Info.plist > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp Sources/OpenSubtitlesUploader/Resources/AppIcon.icns "$RES/AppIcon.icns"
cp ../LICENSE "$RES/LICENSE.txt"
# SwiftPM resource bundle (Bundle.module) + localizations in the main bundle so that
# System Settings › Language & Region can offer a per-app language.
cp -R "$BIN_DIR/${EXECUTABLE}_${EXECUTABLE}.bundle" "$RES/"
for lproj in Sources/OpenSubtitlesUploader/Resources/*.lproj; do
    cp -R "$lproj" "$RES/"
done
find "$APP" -name .DS_Store -delete
xattr -cr "$APP"

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "▸ Signing (ad hoc — no Developer ID certificate found)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
    echo "▸ Signing with $SIGN_IDENTITY"
    # Hardened runtime is required for notarization. No entitlements are needed: networking, the
    # Keychain, notifications and running mediainfo/ffprobe as separate processes are allowed by default.
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

if [ "$MAKE_DMG" = 1 ]; then
    DMG="$ROOT/build/$DMG_NAME"
    mkdir -p "$ROOT/build" "$STAGE/dmg"
    ditto "$APP" "$STAGE/dmg/$NAME.app"
    ln -s /Applications "$STAGE/dmg/Applications"
    rm -f "$DMG"
    hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE/dmg" -ov -format UDZO "$STAGE/$DMG_NAME"
    if [ "$SIGN_IDENTITY" != "-" ]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$STAGE/$DMG_NAME"
    fi
    if [ "$NOTARIZE" = 1 ]; then
        echo "▸ Notarizing (usually a few minutes)…"
        xcrun notarytool submit "$STAGE/$DMG_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
        # The ticket covers the DMG and the app inside it; staple both so they open offline too
        xcrun stapler staple "$STAGE/$DMG_NAME"
        xcrun stapler staple "$APP"
        spctl --assess --type open --context context:primary-signature -v "$STAGE/$DMG_NAME"
        spctl --assess --type execute -v "$APP"
    fi
    cp "$STAGE/$DMG_NAME" "$DMG"
    echo "✓ $DMG"
fi

if [ "$RELEASE" = 1 ]; then
    TAG="v$VERSION"
    SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
    if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
        echo "▸ Replacing the DMG of release $TAG"
        gh release upload "$TAG" "$DMG" -R "$REPO" --clobber
    else
        echo "▸ Creating release $TAG"
        if [ -f RELEASE_NOTES.md ]; then NOTES=(--notes-file RELEASE_NOTES.md); else NOTES=(--generate-notes); fi
        gh release create "$TAG" "$DMG" -R "$REPO" --target "$(git rev-parse HEAD)" --title "OpenSubtitles Uploader for Mac $VERSION" "${NOTES[@]}"
    fi
    # The cask must match what users download, so check the uploaded file itself
    URL="https://github.com/$REPO/releases/download/$TAG/$DMG_NAME"
    REMOTE_SHA="$(curl -sfL "$URL" | shasum -a 256 | cut -d' ' -f1)"
    if [ "$REMOTE_SHA" != "$SHA" ]; then
        echo "The DMG on GitHub ($REMOTE_SHA) differs from the local one ($SHA)." >&2; exit 1
    fi
    echo "✓ $URL"

    echo "▸ Updating the Homebrew cask"
    if [ ! -d "$TAP_DIR/.git" ]; then gh repo clone "$TAP_REPO" "$TAP_DIR" -- -q; fi
    git -C "$TAP_DIR" pull -q --ff-only
    sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP_DIR/$CASK"
    git -C "$TAP_DIR" add "$CASK" README.md
    if git -C "$TAP_DIR" diff --cached --quiet; then
        echo "  (cask already up to date)"
    else
        git -C "$TAP_DIR" commit -q -m "opensubtitles-uploader $VERSION"
        git -C "$TAP_DIR" push -q
        echo "✓ $TAP_REPO: opensubtitles-uploader $VERSION ($SHA)"
    fi
fi

mkdir -p "$ROOT/build"
rm -rf "$ROOT/build/$NAME.app"
ditto "$APP" "$ROOT/build/$NAME.app"
echo "✓ $ROOT/build/$NAME.app"

if [ "$INSTALL" = 1 ]; then
    DEST="$HOME/Applications/$NAME.app"
    mkdir -p "$HOME/Applications"
    osascript -e "quit app \"$NAME\"" 2>/dev/null || true
    rm -rf "$DEST"
    ditto --noextattr --noqtn "$APP" "$DEST"   # the signed copy from the temp folder
    codesign --verify --strict "$DEST"
    echo "✓ Installed: $DEST"
fi
