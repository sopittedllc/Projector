#!/bin/bash
#
# Projector Release Build Script
# Builds, signs, notarizes, and creates a distributable DMG
#
# Prerequisites:
#   1. Developer ID Application certificate installed
#   2. Notarization credentials stored (run setup-notarization.sh first)
#
# Usage: ./scripts/build-release.sh [version] [--no-publish] [--no-upload] [--no-install]
#   version:      Optional version string (e.g., "1.0.0"). Defaults to the current date.
#   --no-publish: Do not create a GitHub release.
#   --no-upload:  Do not upload to Google Drive.
#   --no-install: Do not replace /Applications/Projector.app.
#
# On success the DMG replaces the copy in /Applications, is attached to a GitHub
# release tagged v<version>, and is copied to Google Drive - so the machine and
# both links move together. The DMG itself is never committed: it is ~11MB, git
# keeps every version forever, and `release-build/` is ignored.

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
DRIVE_REMOTE="gdrive"
DRIVE_FOLDER="Projector Builds"
INSTALL_PATH="/Applications/${APP_NAME}"

# Arguments
#
# Order-independent, and --no-publish is never mistaken for a version: reading it
# as one would build a DMG called "Projector---no-publish.dmg" and tag a release
# to match.
PUBLISH=1
UPLOAD=1
INSTALL=1
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --no-publish) PUBLISH=0 ;;
        --no-upload)  UPLOAD=0 ;;
        --no-install) INSTALL=0 ;;
        -*) echo "Unknown option: $arg" >&2; exit 1 ;;
        *) VERSION="$arg" ;;
    esac
done

VERSION="${VERSION:-$(date +%Y.%m.%d)}"
DMG_FILENAME="${DMG_NAME}-${VERSION}.dmg"

# Build number, stamped into the app so builds can be told apart.
#
# Both version fields are stamped from this run. MARKETING_VERSION used to be
# left at whatever the project file said - 1.4 - while the release, the tag and
# the DMG were all named after the date, so a build published as 2026.08.07
# called itself 1.4 everywhere it introduced itself. Harmless while nothing read
# it; not harmless once the app compares its own version against the appcast,
# where it would offer "1.4" as the upgrade from "1.4".
#
# CURRENT_PROJECT_VERSION was pinned too, so every build called itself "1.4 (4)"
# whatever day it was cut - which is why four crash reports from a tester all
# claimed the same version, and why an installed copy could not be identified.
#
# Always the clock, never the version argument: deriving it from the version made
# `build-release.sh 1.0.0` produce build 100, going *backwards* from a dated build.
# Date plus time so two builds on one day are still distinguishable, which is the
# normal case while chasing a bug.
BUILD_NUMBER="$(date +%Y%m%d.%H%M)"

echo "========================================"
echo "Projector Release Build"
echo "Version: ${VERSION} (build ${BUILD_NUMBER})"
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
        MARKETING_VERSION="${VERSION}" \
        CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
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

# Install into /Applications
#
# Before publishing, so a network problem cannot cost the local install. The app
# copied in is the same notarized, stapled bundle that goes into the DMG.
#
# Never removes the installed copy until a verified replacement is standing beside
# it: a failed copy that had already deleted the old app would leave the machine
# with no Projector at all, which is a worse outcome than a stale one.
#
# Skipped with --no-install.
INSTALLED=0
if [ "${INSTALL}" -eq 0 ]; then
    echo ""
    echo "[install] Skipped (--no-install)."
else
    echo ""
    echo "[install] Replacing ${INSTALL_PATH}..."

    # A running copy cannot be replaced cleanly. Asked to quit rather than killed,
    # so the app's own unsaved-changes prompt still gets to interrupt - and if the
    # user cancels that prompt, the install is skipped rather than forced.
    if pgrep -x "${DMG_NAME}" >/dev/null 2>&1; then
        echo "[install] Projector is running - asking it to quit..."
        osascript -e "tell application \"${DMG_NAME}\" to quit" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            pgrep -x "${DMG_NAME}" >/dev/null 2>&1 || break
            sleep 1
        done
    fi

    if pgrep -x "${DMG_NAME}" >/dev/null 2>&1; then
        echo "[install] WARNING: Projector is still running. Skipped."
        echo "          Quit it and re-run, or install from the DMG by hand."
    else
        STAGED="/Applications/.${DMG_NAME}-incoming.app"
        rm -rf "${STAGED}"

        if cp -a "${EXPORT_PATH}/${APP_NAME}" "${STAGED}" \
           && codesign --verify --strict "${STAGED}" 2>/dev/null; then
            rm -rf "${INSTALL_PATH}"
            mv "${STAGED}" "${INSTALL_PATH}"

            # Launch Services still holds the old bundle's record - document icons
            # and the .projector file association come from it.
            /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
                -f "${INSTALL_PATH}" >/dev/null 2>&1 || true

            INSTALLED=1
            echo "[install] Installed ${VERSION} to ${INSTALL_PATH}"
        else
            rm -rf "${STAGED}"
            echo "[install] WARNING: copy or signature check failed."
            echo "          The existing ${INSTALL_PATH} was left untouched."
        fi
    fi
fi

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

# Add this build to the appcast
#
# The appcast is the list of versions the app reads on launch to decide whether
# it is out of date. Until an entry lands here, a build is published but
# invisible to every copy already installed - so this runs on every publish, not
# as a separate remembered step.
#
# Signed with the EdDSA key in this machine's keychain, which is the only thing
# standing between a tampered feed and an installed update: Sparkle verifies the
# signature against SUPublicEDKey in Info.plist and refuses anything that does
# not match. The signature covers the notarized, stapled DMG exactly as
# uploaded, which is why this runs after the release rather than before it.
#
# Skipped without a release to point at - an entry whose enclosure URL 404s is
# worse than no entry, because Sparkle would offer an update it cannot fetch.
APPCAST_PATH="${PROJECT_DIR}/appcast.xml"
APPCAST_UPDATED=0
if [ -z "${DOWNLOAD_URL}" ]; then
    echo ""
    echo "[appcast] Skipped: no published release to point at."
    echo "          Existing installs will not see ${VERSION}."
else
    # sign_update ships inside Sparkle's SPM artifact, which lands in DerivedData,
    # or in the Homebrew cask. Neither path is guaranteed, so both are tried.
    SIGN_UPDATE=""
    for candidate in \
        "$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
            -maxdepth 6 -type f -name sign_update -path '*Sparkle*' 2>/dev/null | head -1)" \
        "/opt/homebrew/Caskroom/sparkle/*/bin/sign_update" \
        "/Applications/Sparkle/bin/sign_update"; do
        # shellcheck disable=SC2086
        expanded="$(ls -1 ${candidate} 2>/dev/null | head -1)"
        if [ -n "${expanded}" ] && [ -x "${expanded}" ]; then
            SIGN_UPDATE="${expanded}"
            break
        fi
    done

    if [ -z "${SIGN_UPDATE}" ]; then
        echo ""
        echo "[appcast] Skipped: sign_update not found."
        echo "          Build once in Xcode so the Sparkle package resolves, or:"
        echo "          brew install --cask sparkle"
        echo "          Existing installs will not see ${VERSION}."
    else
        echo ""
        echo "[appcast] Signing ${DMG_FILENAME}..."

        # Prints: sparkle:edSignature="..." length="..."
        SIGNATURE_OUTPUT="$("${SIGN_UPDATE}" "${DMG_PATH}" 2>/dev/null || true)"
        SIGNATURE="$(printf '%s' "${SIGNATURE_OUTPUT}" \
            | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
        DMG_BYTES="$(stat -f%z "${DMG_PATH}")"

        if [ -z "${SIGNATURE}" ]; then
            echo "[appcast] WARNING: sign_update produced no signature."
            echo "          The private key may not be in this keychain. Generate one once with"
            echo "          Sparkle's generate_keys, then put the public half in Info.plist."
            echo "          Existing installs will not see ${VERSION}."
        else
            python3 "${SCRIPTS_DIR}/appcast.py" \
                --appcast "${APPCAST_PATH}" \
                --version "${VERSION}" \
                --build "${BUILD_NUMBER}" \
                --url "${DOWNLOAD_URL}" \
                --length "${DMG_BYTES}" \
                --signature "${SIGNATURE}" \
                --min-system "12.0" \
                --link "https://github.com/sopittedllc/Projector/releases/tag/v${VERSION}" \
                --notes "Signed, notarized, universal (x86_64 + arm64). Requires macOS 12.0 or later."

            # Committed on its own, by path: the working tree may hold unrelated
            # work in progress, and a release must never sweep that into a commit
            # nobody reviewed.
            #
            # Staged first because `git commit <path>` refuses a path git has
            # never seen - which is exactly the state on the first release after
            # this feature landed, so the one release that most needed to
            # publish a feed would have been the one that could not.
            if git -C "${PROJECT_DIR}" add "${APPCAST_PATH}" >/dev/null 2>&1 \
               && git -C "${PROJECT_DIR}" commit "${APPCAST_PATH}" \
                 -m "release: add ${VERSION} to the appcast" >/dev/null 2>&1 \
               && git -C "${PROJECT_DIR}" push >/dev/null 2>&1; then
                APPCAST_UPDATED=1
                echo "[appcast] Published ${VERSION}; installed copies will offer it."
            else
                echo "[appcast] WARNING: appcast.xml was updated but not pushed."
                echo "          Existing installs will not see ${VERSION} until you run:"
                echo "          git add appcast.xml && git commit -m 'release: add ${VERSION}' && git push"
            fi
        fi
    fi
fi

# Upload to Google Drive
#
# Alongside the GitHub release rather than instead of it: two links cost nothing
# and either one surviving is better than a single point of failure. The Drive
# link is "anyone with the link" - unlisted, not private.
#
# Skipped with --no-upload, or when the rclone remote is not configured.
DRIVE_URL=""
if [ "${UPLOAD}" -eq 0 ]; then
    echo ""
    echo "[upload] Skipped (--no-upload)."
elif ! command -v rclone >/dev/null 2>&1 \
     || ! rclone listremotes 2>/dev/null | grep -q "^${DRIVE_REMOTE}:$"; then
    echo ""
    echo "[upload] Skipped: rclone remote '${DRIVE_REMOTE}' is not configured."
    echo "          Set one up with: rclone config create ${DRIVE_REMOTE} drive scope=drive"
else
    echo ""
    echo "[upload] Uploading to Google Drive (${DRIVE_FOLDER})..."
    rclone mkdir "${DRIVE_REMOTE}:${DRIVE_FOLDER}" 2>/dev/null || true

    if rclone copy "${DMG_PATH}" "${DRIVE_REMOTE}:${DRIVE_FOLDER}" --stats-one-line; then
        DRIVE_URL="$(rclone link \
            "${DRIVE_REMOTE}:${DRIVE_FOLDER}/${DMG_FILENAME}" 2>/dev/null || true)"
    else
        echo "[upload] WARNING: upload failed. The DMG and any release link are still good."
    fi
fi

# Done
echo ""
echo "========================================"
echo "BUILD COMPLETE!"
echo "========================================"
echo ""
echo "DMG location: ${DMG_PATH}"
echo "DMG size: $(du -h "${DMG_PATH}" | cut -f1)"
if [ "${INSTALLED}" -eq 1 ]; then
    echo "Installed:    ${INSTALL_PATH}"
fi
if [ -n "${DOWNLOAD_URL}" ]; then
    echo "GitHub:       ${DOWNLOAD_URL}"
fi
if [ -n "${DRIVE_URL}" ]; then
    echo "Drive:        ${DRIVE_URL}"
fi
if [ "${APPCAST_UPDATED}" -eq 1 ]; then
    echo "Appcast:      published (installed copies will offer ${VERSION})"
else
    echo "Appcast:      NOT published - installed copies will not see ${VERSION}"
fi
echo ""
echo "To test Gatekeeper acceptance:"
echo "  1. Copy DMG to another Mac or create a new user"
echo "  2. Download via browser (to add quarantine flag)"
echo "  3. Or test locally with: ./scripts/test-gatekeeper.sh"
echo ""
