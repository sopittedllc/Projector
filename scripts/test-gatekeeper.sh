#!/bin/bash
#
# Test Gatekeeper Acceptance Locally
#
# This script simulates what happens when a user downloads your app
# from the internet by adding the quarantine attribute and testing
# Gatekeeper assessment.
#
# Usage: ./scripts/test-gatekeeper.sh [path-to-dmg-or-app]
#

set -e

# Find the file to test
if [ -n "$1" ]; then
    TARGET="$1"
else
    # Look for most recent DMG in release-build
    PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    TARGET=$(ls -t "${PROJECT_DIR}/release-build"/*.dmg 2>/dev/null | head -1)

    if [ -z "$TARGET" ]; then
        echo "Usage: $0 [path-to-dmg-or-app]"
        echo ""
        echo "No DMG found in release-build/. Either:"
        echo "  1. Run ./scripts/build-release.sh first"
        echo "  2. Specify a path to a DMG or app"
        exit 1
    fi
fi

if [ ! -e "$TARGET" ]; then
    echo "Error: File not found: $TARGET"
    exit 1
fi

echo "========================================"
echo "Gatekeeper Test"
echo "========================================"
echo ""
echo "Testing: $TARGET"
echo ""

# Check if it's a DMG or app
if [[ "$TARGET" == *.dmg ]]; then
    IS_DMG=true
    echo "Type: DMG"
else
    IS_DMG=false
    echo "Type: App Bundle"
fi

echo ""
echo "----------------------------------------"
echo "1. Checking code signature..."
echo "----------------------------------------"
if [ "$IS_DMG" = true ]; then
    codesign -dv --verbose=2 "$TARGET" 2>&1 || true
else
    codesign --verify --deep --strict --verbose=2 "$TARGET"
fi

echo ""
echo "----------------------------------------"
echo "2. Checking notarization status..."
echo "----------------------------------------"
xcrun stapler validate "$TARGET" 2>&1 || echo "Note: Stapler validation may fail on unsigned items"

echo ""
echo "----------------------------------------"
echo "3. Gatekeeper assessment (spctl)..."
echo "----------------------------------------"
if [ "$IS_DMG" = true ]; then
    spctl --assess --type open --context context:primary-signature --verbose "$TARGET" 2>&1 || true
else
    spctl --assess --type exec --verbose "$TARGET" 2>&1 || true
fi

echo ""
echo "----------------------------------------"
echo "4. Simulating quarantine (downloaded file)..."
echo "----------------------------------------"

# Create a temp copy with quarantine attribute
TEMP_DIR=$(mktemp -d)
TEMP_TARGET="${TEMP_DIR}/$(basename "$TARGET")"
cp -R "$TARGET" "$TEMP_TARGET"

# Add quarantine attribute (simulates download from internet)
xattr -w com.apple.quarantine "0083;$(printf '%x' $(date +%s));Safari;$(uuidgen)" "$TEMP_TARGET"

echo "Added quarantine attribute to temp copy"
echo ""

echo "Testing quarantined file with Gatekeeper..."
if [ "$IS_DMG" = true ]; then
    RESULT=$(spctl --assess --type open --context context:primary-signature --verbose "$TEMP_TARGET" 2>&1) || true
else
    RESULT=$(spctl --assess --type exec --verbose "$TEMP_TARGET" 2>&1) || true
fi

echo "$RESULT"

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo "----------------------------------------"
echo "5. Summary"
echo "----------------------------------------"

if echo "$RESULT" | grep -q "accepted"; then
    echo ""
    echo "PASSED: Gatekeeper will accept this file!"
    echo ""
    echo "Users will NOT see the 'unidentified developer' warning."
else
    echo ""
    echo "FAILED: Gatekeeper may reject this file"
    echo ""
    echo "Common issues:"
    echo "  - Not signed with 'Developer ID Application' certificate"
    echo "  - Not notarized (run build-release.sh)"
    echo "  - Notarization ticket not stapled"
    echo ""
    echo "To fix, ensure you've run:"
    echo "  1. ./scripts/setup-notarization.sh (one-time setup)"
    echo "  2. ./scripts/build-release.sh"
fi

echo ""
echo "----------------------------------------"
echo "6. Additional Manual Test (Recommended)"
echo "----------------------------------------"
echo ""
echo "For the most accurate test:"
echo "  1. Upload the DMG to a web server or cloud storage"
echo "  2. Download it using Safari on a clean Mac/user account"
echo "  3. Double-click to open - should work without warnings"
echo ""
echo "Or use a different user account on this Mac:"
echo "  1. Create a new macOS user account"
echo "  2. Copy DMG to that user's Downloads folder"
echo "  3. Add quarantine: xattr -w com.apple.quarantine \"0083;...;Safari;...\" /path/to/dmg"
echo "  4. Try to open the DMG and run the app"
echo ""
