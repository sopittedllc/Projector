#!/bin/bash
#
# Setup Notarization Credentials
#
# This script helps you store your App Store Connect credentials
# securely in the macOS Keychain for use with notarytool.
#
# Requirements:
#   - Apple ID enrolled in Apple Developer Program
#   - App-specific password generated from appleid.apple.com
#
# To create an app-specific password:
#   1. Go to https://appleid.apple.com
#   2. Sign in with your Apple ID
#   3. Go to "Sign-In and Security" > "App-Specific Passwords"
#   4. Click "Generate an app-specific password"
#   5. Name it something like "Notarization"
#   6. Copy the generated password
#

echo "========================================"
echo "Notarization Credentials Setup"
echo "========================================"
echo ""
echo "This will store your Apple ID credentials securely in the Keychain."
echo ""
echo "You'll need:"
echo "  1. Your Apple ID email"
echo "  2. An app-specific password from appleid.apple.com"
echo "  3. Your Team ID: G398H44H6X"
echo ""
echo "To create an app-specific password:"
echo "  1. Go to https://appleid.apple.com"
echo "  2. Sign in > App-Specific Passwords > Generate"
echo ""
read -p "Press Enter to continue..."
echo ""

xcrun notarytool store-credentials "notary" \
    --apple-id "" \
    --team-id "G398H44H6X"

echo ""
echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""
echo "Your credentials are stored in the Keychain under profile 'notary'."
echo "You can now run: ./scripts/build-release.sh"
echo ""
