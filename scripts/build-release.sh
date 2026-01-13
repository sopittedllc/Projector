#!/bin/bash
#
# Projector Release Build Script
# Builds, signs, notarizes, and creates a distributable DMG
#
# Prerequisites:
#   1. Developer ID Application certificate installed
#   2. Notarization credentials stored (run setup-notarization.sh first)
#
# Usage: ./scripts/build-release.sh [version]
#   version: Optional version string (e.g., "1.0.0"). If not provided, uses current date.

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

# Version
VERSION="${1:-$(date +%Y.%m.%d)}"
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
xcodebuild archive \
    -project "${PROJECT_DIR}/Projector.xcodeproj" \
    -scheme "${SCHEME}" \
    -archivePath "${ARCHIVE_PATH}" \
    -configuration Release \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    | xcpretty || xcodebuild archive \
    -project "${PROJECT_DIR}/Projector.xcodeproj" \
    -scheme "${SCHEME}" \
    -archivePath "${ARCHIVE_PATH}" \
    -configuration Release \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"

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

# Create DMG using create-dmg
echo ""
echo "[7/8] Creating DMG with create-dmg..."
DMG_PATH="${BUILD_DIR}/${DMG_FILENAME}"

create-dmg \
    --volname "${DMG_NAME}" \
    --volicon "${EXPORT_PATH}/${APP_NAME}/Contents/Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "${APP_NAME}" 180 170 \
    --hide-extension "${APP_NAME}" \
    --app-drop-link 480 170 \
    --codesign "${DEVELOPER_ID}" \
    "${DMG_PATH}" \
    "${EXPORT_PATH}/${APP_NAME}"

echo "DMG created and signed: ${DMG_PATH}"

# Notarize the DMG
echo ""
echo "[8/8] Notarizing DMG..."
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

# Staple the DMG
echo ""
echo "Stapling notarization ticket to DMG..."
xcrun stapler staple "${DMG_PATH}"

# Verify DMG
echo ""
echo "Verifying DMG..."
spctl --assess --type open --context context:primary-signature --verbose "${DMG_PATH}"

# Cleanup
rm -f "${BUILD_DIR}/Projector-notarize.zip"

# Done
echo ""
echo "========================================"
echo "BUILD COMPLETE!"
echo "========================================"
echo ""
echo "DMG location: ${DMG_PATH}"
echo "DMG size: $(du -h "${DMG_PATH}" | cut -f1)"
echo ""
echo "To test Gatekeeper acceptance:"
echo "  1. Copy DMG to another Mac or create a new user"
echo "  2. Download via browser (to add quarantine flag)"
echo "  3. Or test locally with: ./scripts/test-gatekeeper.sh"
echo ""
