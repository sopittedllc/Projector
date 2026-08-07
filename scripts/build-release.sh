#!/bin/bash
#
# Projector Release Build Script
# Builds, signs, notarizes, and creates a distributable DMG
#
# Prerequisites:
#   1. Developer ID Application certificate installed
#   2. Notarization credentials stored (run setup-notarization.sh first)
#
# Usage: ./scripts/build-release.sh [version] [--no-publish]
#   version:      Optional version string (e.g., "1.0.0"). Defaults to the current date.
#   --no-publish: Build the DMG but do not create a GitHub release for it.
#
# On success the DMG is attached to a GitHub release tagged v<version>, which is
# where the download link comes from. The DMG itself is never committed: it is
# ~11MB, git keeps every version forever, and `release-build/` is ignored.

set -e

# Configuration
SCHEME="Projector"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="${PROJECT_DIR}/scripts"
BUILD_DIR="${PROJECT_DIR}/release-build"
ARCHIVE_PATH="${BUILD_DIR}/Projector.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
APP_NAME="Projector.app"
DMG_NAME="Projector"
TEAM_ID="G398H44H6X"
DEVELOPER_ID="Developer ID Application: Keegan DeWitt (${TEAM_ID})"
NOTARY_PROFILE="notary"

# Arguments
#
# Order-independent, and --no-publish is never mistaken for a version: reading it
# as one would build a DMG called "Projector---no-publish.dmg" and tag a release
# to match.
PUBLISH=1
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --no-publish) PUBLISH=0 ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *) VERSION="$arg" ;;
    esac
done

VERSION="${VERSION:-$(date +%Y.%m.%d)}"
DMG_FILENAME="${DMG_NAME}-${VERSION}.dmg"

echo "========================================"
echo "Projector Release Build"
echo "Version: ${VERSION}"
echo "========================================"

# Clean previous build
echo ""
echo "[1/8] Cleaning previous build..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Archive
echo ""
echo "[2/8] Archiving..."

# Prettify only when the formatter is actually installed.
#
# This used to be `xcodebuild … | xcpretty || xcodebuild …`, which on a machine
# without xcpretty ran the whole archive into a broken pipe, failed, and then ran
# the entire archive a second time - doubling the longest step of the build to
# recover from a missing formatter. Checking first costs nothing and archives once.
archive() {
    xcodebuild archive \
        -project "${PROJECT_DIR}/Projector.xcodeproj" \
        -scheme "${SCHEME}" \
        -archivePath "${ARCHIVE_PATH}" \
        -configuration Release \
        CODE_SIGN_IDENTITY="${DEVELOPER_ID}" \
        DEVELOPMENT_TEAM="${TEAM_ID}" \
        CODE_SIGN_STYLE=Manual \
        OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"
}

if command -v xcpretty >/dev/null 2>&1; then
    # Fail on xcodebuild's status, not the formatter's.
    set -o pipefail
    archive | xcpretty
    set +o pipefail
else
    archive
fi

# Export
echo ""
echo "[3/8] Exporting with Developer ID signing..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${SCRIPTS_DIR}/ExportOptions.plist"

# Verify signing
echo ""
echo "[4/8] Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${EXPORT_PATH}/${APP_NAME}"
echo "Signature verification passed!"

# Show signing info
echo ""
echo "Signing details:"
codesign -dv --verbose=4 "${EXPORT_PATH}/${APP_NAME}" 2>&1 | grep -E "(Authority|TeamIdentifier|Signature)"

# Notarize the app
echo ""
echo "[5/8] Notarizing app..."
echo "Creating zip for notarization..."
ditto -c -k --keepParent "${EXPORT_PATH}/${APP_NAME}" "${BUILD_DIR}/Projector-notarize.zip"

echo "Submitting to Apple for notarization (this may take several minutes)..."
xcrun notarytool submit "${BUILD_DIR}/Projector-notarize.zip" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

# Staple the app
echo ""
echo "[6/8] Stapling notarization ticket to app..."
xcrun stapler staple "${EXPORT_PATH}/${APP_NAME}"

# Verify notarization
echo ""
echo "Verifying notarization..."
spctl --assess --type exec --verbose "${EXPORT_PATH}/${APP_NAME}"
echo "App notarization verified!"

# Create DMG using create-dmg (Homebrew version)
echo ""
echo "[7/8] Creating, signing, and notarizing DMG..."
DMG_PATH="${BUILD_DIR}/${DMG_FILENAME}"

# Create staging directory with app and Applications alias
# create-dmg copies the CONTENTS of the source folder, so we need a staging dir
STAGING_DIR="${BUILD_DIR}/dmg_staging"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

# Copy the notarized app to staging
cp -a "${EXPORT_PATH}/${APP_NAME}" "${STAGING_DIR}/"

# Create a proper Finder alias to /Applications (not a symlink)
# Symlinks show as broken icons; Finder aliases display the proper folder icon
osascript -e "tell application \"Finder\" to make new alias file at POSIX file \"${STAGING_DIR}\" to POSIX file \"/Applications\" with properties {name:\"Applications\"}"

# Set custom icon on Applications alias to prevent macOS alias icon vanishing bug
# Without this, the alias icon appears briefly then disappears on modern macOS
fileicon set "${STAGING_DIR}/Applications" "${SCRIPTS_DIR}/ApplicationsFolderIcon.icns"

# Use Homebrew create-dmg (has full customization options)
# The npm version is a different tool with limited options
CREATE_DMG="/opt/homebrew/bin/create-dmg"
if [ ! -x "$CREATE_DMG" ]; then
    echo "Error: create-dmg not found. Install via: brew install create-dmg"
    exit 1
fi

"$CREATE_DMG" \
    --volname "${DMG_NAME}" \
    --volicon "${EXPORT_PATH}/${APP_NAME}/Contents/Resources/AppIcon.icns" \
    --background "${SCRIPTS_DIR}/dmg-background.png" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "${APP_NAME}" 180 200 \
    --hide-extension "${APP_NAME}" \
    --icon "Applications" 480 200 \
    --codesign "${DEVELOPER_ID}" \
    --notarize "${NOTARY_PROFILE}" \
    "${DMG_PATH}" \
    "${STAGING_DIR}"

# Cleanup staging directory
rm -rf "${STAGING_DIR}"

echo "DMG created, signed, and notarized: ${DMG_PATH}"

# Verify DMG
echo ""
echo "[8/8] Verifying DMG..."
spctl --assess --type open --context context:primary-signature --verbose "${DMG_PATH}"

# Cleanup
rm -f "${BUILD_DIR}/Projector-notarize.zip"

# Publish as a GitHub release
#
# A release asset, not a committed file: the DMG is ~11MB and git keeps every
# version of it forever, so committing one per build grows the repository
# permanently and cannot be undone without rewriting history. A release gives the
# same thing the commit was wanted for - a stable download link tied to a commit -
# and `release-build/` stays ignored.
#
# Skipped with --no-publish, or when gh is missing or not logged in.
DOWNLOAD_URL=""
if [ "${PUBLISH}" -eq 0 ]; then
    echo ""
    echo "[publish] Skipped (--no-publish)."
elif ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo ""
    echo "[publish] Skipped: gh is not installed or not logged in."
    echo "          Publish later with:"
    echo "          gh release create v${VERSION} \"${DMG_PATH}\" --title \"Projector ${VERSION}\""
else
    echo ""
    echo "[publish] Creating GitHub release v${VERSION}..."
    COMMIT="$(git -C "${PROJECT_DIR}" rev-parse --short HEAD)"

    # Uncommitted work would ship a DMG that no commit describes.
    if ! git -C "${PROJECT_DIR}" diff --quiet HEAD 2>/dev/null; then
        echo "[publish] WARNING: uncommitted changes - this DMG does not match ${COMMIT}."
    fi

    if gh release view "v${VERSION}" >/dev/null 2>&1; then
        # Same-day rebuild: replace the asset rather than fail on the existing tag.
        echo "[publish] Release v${VERSION} exists; replacing its asset."
        gh release upload "v${VERSION}" "${DMG_PATH}" --clobber
    else
        gh release create "v${VERSION}" "${DMG_PATH}" \
            --title "Projector ${VERSION}" \
            --target "$(git -C "${PROJECT_DIR}" rev-parse --abbrev-ref HEAD)" \
            --notes "Signed, notarized, universal (x86_64 + arm64). Requires macOS 12.0 or later.

Built from \`${COMMIT}\`."
    fi

    DOWNLOAD_URL="$(gh release view "v${VERSION}" \
        --json assets --jq '.assets[0].url' 2>/dev/null || true)"
fi

# Done
echo ""
echo "========================================"
echo "BUILD COMPLETE!"
echo "========================================"
echo ""
echo "DMG location: ${DMG_PATH}"
echo "DMG size: $(du -h "${DMG_PATH}" | cut -f1)"
if [ -n "${DOWNLOAD_URL}" ]; then
    echo "Download:     ${DOWNLOAD_URL}"
fi
echo ""
echo "To test Gatekeeper acceptance:"
echo "  1. Copy DMG to another Mac or create a new user"
echo "  2. Download via browser (to add quarantine flag)"
echo "  3. Or test locally with: ./scripts/test-gatekeeper.sh"
echo ""
