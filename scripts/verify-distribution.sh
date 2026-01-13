#!/bin/bash
#
# Verify Distribution - Tests that a DMG will pass Gatekeeper
#
# Usage: ./scripts/verify-distribution.sh /path/to/your.dmg
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "${YELLOW}WARN${NC}: $1"; }

FAILURES=0

if [ -z "$1" ]; then
    echo "Usage: $0 /path/to/your.dmg"
    exit 1
fi

DMG="$1"

if [ ! -f "$DMG" ]; then
    echo "Error: File not found: $DMG"
    exit 1
fi

echo "========================================"
echo "Distribution Verification"
echo "========================================"
echo "File: $DMG"
echo ""

# ============================================
# CHECK 1: DMG Signature
# ============================================
echo "----------------------------------------"
echo "1. DMG Code Signature"
echo "----------------------------------------"

DMG_SIG=$(codesign -dv --verbose=2 "$DMG" 2>&1)
DMG_AUTHORITY=$(echo "$DMG_SIG" | grep "^Authority=" | head -1 | cut -d= -f2)

if echo "$DMG_AUTHORITY" | grep -q "Developer ID Application"; then
    pass "DMG signed with Developer ID Application"
elif echo "$DMG_AUTHORITY" | grep -q "Apple Development"; then
    fail "DMG signed with Apple Development (should be Developer ID Application)"
else
    fail "DMG signature authority: $DMG_AUTHORITY"
fi

# ============================================
# CHECK 2: DMG Notarization
# ============================================
echo ""
echo "----------------------------------------"
echo "2. DMG Notarization"
echo "----------------------------------------"

STAPLER_OUT=$(xcrun stapler validate "$DMG" 2>&1)
if echo "$STAPLER_OUT" | grep -q "worked"; then
    pass "DMG has notarization ticket stapled"
else
    fail "DMG does NOT have notarization ticket stapled"
fi

# ============================================
# CHECK 3: DMG Gatekeeper Assessment
# ============================================
echo ""
echo "----------------------------------------"
echo "3. DMG Gatekeeper Assessment"
echo "----------------------------------------"

SPCTL_OUT=$(spctl --assess --type open --context context:primary-signature --verbose "$DMG" 2>&1)
if echo "$SPCTL_OUT" | grep -q "accepted"; then
    pass "DMG passes Gatekeeper"
else
    fail "DMG REJECTED by Gatekeeper"
    echo "   $SPCTL_OUT"
fi

# ============================================
# CHECK 4: Mount and check app inside
# ============================================
echo ""
echo "----------------------------------------"
echo "4. App Inside DMG"
echo "----------------------------------------"

MOUNT_POINT=$(mktemp -d)
hdiutil attach "$DMG" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

APP_PATH=$(find "$MOUNT_POINT" -maxdepth 1 -name "*.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    fail "No .app found inside DMG"
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
else
    APP_NAME=$(basename "$APP_PATH")
    echo "Found: $APP_NAME"
    echo ""

    # Check app signature
    APP_SIG=$(codesign -dv --verbose=2 "$APP_PATH" 2>&1)
    APP_AUTHORITY=$(echo "$APP_SIG" | grep "^Authority=" | head -1 | cut -d= -f2)

    if echo "$APP_AUTHORITY" | grep -q "Developer ID Application"; then
        pass "App signed with Developer ID Application"
    else
        fail "App NOT signed with Developer ID Application"
        echo "   Authority: $APP_AUTHORITY"
    fi

    # Check app notarization
    APP_STAPLER=$(xcrun stapler validate "$APP_PATH" 2>&1)
    if echo "$APP_STAPLER" | grep -q "worked"; then
        pass "App has notarization ticket stapled"
    else
        fail "App does NOT have notarization ticket stapled"
    fi

    # Check hardened runtime
    if echo "$APP_SIG" | grep -q "flags=0x10000(runtime)"; then
        pass "Hardened Runtime enabled"
    else
        fail "Hardened Runtime NOT enabled"
    fi

    hdiutil detach "$MOUNT_POINT" -quiet
    rmdir "$MOUNT_POINT"
fi

# ============================================
# CHECK 5: Quarantine Simulation
# ============================================
echo ""
echo "----------------------------------------"
echo "5. Quarantine Simulation (Download Test)"
echo "----------------------------------------"

TEMP_DIR=$(mktemp -d)
TEMP_DMG="$TEMP_DIR/$(basename "$DMG")"
cp "$DMG" "$TEMP_DMG"

# Add quarantine attribute (simulates Safari download)
xattr -w com.apple.quarantine "0083;$(printf '%x' $(date +%s));Safari;$(uuidgen)" "$TEMP_DMG"

QUARANTINE_TEST=$(spctl --assess --type open --context context:primary-signature --verbose "$TEMP_DMG" 2>&1)
if echo "$QUARANTINE_TEST" | grep -q "accepted"; then
    pass "Quarantined DMG passes Gatekeeper"
else
    fail "Quarantined DMG REJECTED by Gatekeeper"
    echo "   This is what users will experience when downloading!"
fi

rm -rf "$TEMP_DIR"

# ============================================
# SUMMARY
# ============================================
echo ""
echo "========================================"
echo "SUMMARY"
echo "========================================"

if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}ALL CHECKS PASSED${NC}"
    echo ""
    echo "This DMG should work for users without Gatekeeper warnings."
else
    echo -e "${RED}$FAILURES CHECK(S) FAILED${NC}"
    echo ""
    echo "Fix the issues above before distributing."
    echo ""
    echo "Common fixes:"
    echo "  - Sign DMG with: --identity=\"Developer ID Application: Keegan DeWitt (G398H44H6X)\""
    echo "  - Notarize DMG: xcrun notarytool submit your.dmg --keychain-profile notary --wait"
    echo "  - Staple DMG: xcrun stapler staple your.dmg"
fi

echo ""
exit $FAILURES
