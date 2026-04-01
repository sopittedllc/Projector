# Notarization Verification Guide

Step-by-step guide for verifying code signing and notarization before App Store submission.

---

## Prerequisites

- [ ] Xcode installed (version 15.0+)
- [ ] Developer ID Application certificate installed in Keychain
- [ ] App Store Connect access (for notarization)
- [ ] `xcrun` command-line tools installed

---

## Step 1: Verify Code Signing Configuration (Xcode)

### Check Signing Settings

1. Open Projector.xcodeproj in Xcode
2. Select **Projector** target → **Signing & Capabilities** tab
3. Verify:
   - [ ] **Automatically manage signing**: Unchecked (for release builds)
   - [ ] **Team**: G398H44H6X (Keegan DeWitt)
   - [ ] **Signing Certificate**: "Developer ID Application: Keegan DeWitt (G398H44H6X)"
   - [ ] **Provisioning Profile**: "Projector Developer ID" (or "Automatic")

### Check All Targets

- [ ] **Projector** (main app) - Signing configured
- [ ] **ProjectorQuickLook** (QuickLook extension) - Signing configured
- [ ] **ProjectorTests** (test bundle) - Can be unsigned (not distributed)

---

## Step 2: Build Release Archive

### Create Archive

1. Xcode → **Product** → **Archive**
2. Wait for archive to complete (~2-5 minutes)
3. Organizer window opens automatically

### Verify Archive

- [ ] **Archive Name**: "Projector 1.0.0" (or current version)
- [ ] **Date**: Matches today
- [ ] **Size**: ~50-100 MB (varies)

---

## Step 3: Export Signed App

### Export for Distribution

1. In Organizer, select archive
2. Click **Distribute App**
3. Select **Developer ID** (NOT "Mac App Store")
4. Click **Next**
5. **Destination**: Export (saves to disk)
6. **Options**:
   - [ ] **Include bitcode**: Unchecked (not needed for macOS)
   - [ ] **Rebuild from bitcode**: Unchecked
   - [ ] **Strip Swift symbols**: Checked (reduces size)
   - [ ] **Upload symbols**: Unchecked (no crash reporting yet)
7. Click **Next**
8. **Signing**: Automatic (uses Developer ID certificate)
9. Click **Export**
10. Save to: `~/Desktop/Projector-1.0.0-Release/`

### Verify Export

- [ ] **Projector.app** created in export folder
- [ ] **File size**: 40-80 MB (varies)
- [ ] **Icon**: Projector logo visible in Finder

---

## Step 4: Verify Code Signature (Command Line)

### Check Main App Signature

```bash
cd ~/Desktop/Projector-1.0.0-Release/
codesign -dvv Projector.app
```

**Expected Output**:
```
Executable=/Users/.../Projector.app/Contents/MacOS/Projector
Identifier=com.keegandewitt.projector
Format=app bundle with Mach-O universal (x86_64 arm64)
CodeDirectory v=20500 size=... flags=0x10000(runtime) hashes=...
Signature size=...
Authority=Developer ID Application: Keegan DeWitt (G398H44H6X)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=...
Info.plist entries=...
TeamIdentifier=G398H44H6X
Sealed Resources version=2 rules=...
```

- [ ] **Format**: "app bundle with Mach-O universal (x86_64 arm64)" (Universal Binary)
- [ ] **Authority**: "Developer ID Application: Keegan DeWitt (G398H44H6X)"
- [ ] **Flags**: `0x10000(runtime)` (Hardened Runtime enabled)
- [ ] **TeamIdentifier**: G398H44H6X

### Check QuickLook Extension Signature

```bash
codesign -dvv Projector.app/Contents/PlugIns/ProjectorQuickLook.appex
```

**Expected**:
- [ ] **Authority**: Developer ID Application: Keegan DeWitt (G398H44H6X)
- [ ] **Flags**: `0x10000(runtime)`

### Verify Deep Signature

```bash
codesign --verify --deep --strict --verbose=2 Projector.app
```

**Expected Output**:
```
Projector.app: valid on disk
Projector.app: satisfies its Designated Requirement
```

- [ ] **Result**: "valid on disk" + "satisfies Designated Requirement"
- [ ] **No errors** (if errors appear, signature is broken → rebuild)

---

## Step 5: Create DMG for Distribution

### Create DMG

```bash
cd ~/Desktop/Projector-1.0.0-Release/

# Create DMG
hdiutil create -volname "Projector 1.0.0" \
               -srcfolder Projector.app \
               -ov \
               -format UDZO \
               -fs HFS+ \
               Projector-1.0.0.dmg
```

**Result**: `Projector-1.0.0.dmg` created (30-60 MB)

### Verify DMG

- [ ] **Mount DMG**: Double-click DMG → Projector volume mounts
- [ ] **App inside**: Projector.app visible in mounted volume
- [ ] **Drag to /Applications**: Works correctly

---

## Step 6: Notarize DMG with Apple

### Submit for Notarization

**Important**: You MUST have an app-specific password stored in Keychain for notarization.

**Create app-specific password** (if not already done):
1. Go to https://appleid.apple.com
2. Sign in with your Apple ID
3. **Security** → **App-Specific Passwords** → **Generate**
4. Name: "Projector Notarization"
5. Copy password
6. Store in Keychain:
   ```bash
   xcrun notarytool store-credentials "notary" \
       --apple-id "your@email.com" \
       --team-id "G398H44H6X" \
       --password "xxxx-xxxx-xxxx-xxxx"
   ```

**Submit DMG for notarization**:

```bash
cd ~/Desktop/Projector-1.0.0-Release/

xcrun notarytool submit Projector-1.0.0.dmg \
    --keychain-profile "notary" \
    --wait
```

**Expected Output**:
```
Conducting pre-submission checks for Projector-1.0.0.dmg...
Submission ID received
  id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Successfully uploaded file
  id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  path: /Users/.../Projector-1.0.0.dmg
Waiting for processing to complete...
Current status: In Progress........
Current status: Accepted

Processing complete
  id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  status: Accepted
```

- [ ] **Status**: `Accepted` (✅ SUCCESS)
- [ ] **NOT** `Invalid` or `Rejected` (❌ FAILED - see logs)

### Check Notarization Status (if needed)

```bash
# View submission history
xcrun notarytool history --keychain-profile "notary"

# Get detailed log for submission
xcrun notarytool log <submission-id> --keychain-profile "notary"
```

**Common Rejection Reasons**:
- Missing entitlements
- Unsigned binaries (frameworks, plugins)
- Hardened runtime not enabled
- Invalid Info.plist keys

---

## Step 7: Staple Notarization Ticket to DMG

### Staple Ticket

```bash
xcrun stapler staple Projector-1.0.0.dmg
```

**Expected Output**:
```
Processing: /Users/.../Projector-1.0.0.dmg
Processing: /Users/.../Projector-1.0.0.dmg
The staple and validate action worked!
```

- [ ] **Result**: "The staple and validate action worked!"

### Verify Stapling

```bash
xcrun stapler validate Projector-1.0.0.dmg
```

**Expected Output**:
```
Processing: /Users/.../Projector-1.0.0.dmg
The validate action worked!
```

- [ ] **Result**: "The validate action worked!"

---

## Step 8: Verify Gatekeeper Approval

### Test on Clean System (Recommended)

**Best Practice**: Test on a different Mac or clean macOS VM

1. Copy DMG to test Mac (via AirDrop, USB, or network)
2. Mount DMG
3. Drag Projector.app to /Applications
4. Double-click Projector.app to launch

**Expected**:
- [ ] App launches immediately (no Gatekeeper dialog)
- [ ] **NO** "cannot be opened because the developer cannot be verified"
- [ ] **NO** "damaged and can't be opened"

### Command-Line Verification

```bash
# On test Mac
spctl --assess --verbose /Applications/Projector.app
```

**Expected Output**:
```
/Applications/Projector.app: accepted
source=Notarized Developer ID
origin=Developer ID Application: Keegan DeWitt (G398H44H6X)
```

- [ ] **Assessment**: `accepted`
- [ ] **Source**: `Notarized Developer ID` (NOT "Developer ID" without "Notarized")

---

## Step 9: Final DMG Distribution

### Create Final DMG with Installer

**Optional**: Create DMG with custom background and drag-to-Applications instructions

1. Create folder: `~/Desktop/DMG-Contents/`
2. Copy Projector.app into it
3. Create symlink to /Applications:
   ```bash
   ln -s /Applications ~/Desktop/DMG-Contents/Applications
   ```
4. Create DMG:
   ```bash
   hdiutil create -volname "Projector 1.0.0" \
                  -srcfolder ~/Desktop/DMG-Contents/ \
                  -ov \
                  -format UDZO \
                  -fs HFS+ \
                  Projector-1.0.0-Installer.dmg
   ```
5. **Notarize and staple** this new DMG (repeat Steps 6-7)

---

## Step 10: App Store Upload (Alternative to DMG Distribution)

### Export for App Store

1. Xcode → Organizer → Select archive
2. **Distribute App** → **Mac App Store**
3. **Destination**: Upload
4. **Options**:
   - [ ] Include bitcode: Unchecked
   - [ ] Upload symbols: Checked (if using App Store Connect)
5. **Signing**: Automatic (uses Mac App Store certificate)
6. **Upload**

### Wait for Processing

1. Go to https://appstoreconnect.apple.com
2. **My Apps** → **Projector**
3. **TestFlight** or **App Store** tab
4. Wait for "Processing" → "Ready to Submit" (~10-30 minutes)

- [ ] **Status**: Ready to Submit
- [ ] **Build Number**: 1 (or current build)
- [ ] **Version**: 1.0.0

---

## Troubleshooting

### "Signature invalid" error

**Cause**: Unsigned or incorrectly signed binary

**Fix**:
1. Check all targets are signed (Step 1)
2. Rebuild archive
3. Verify signature (Step 4)

### Notarization rejected: "Invalid binary"

**Cause**: Missing hardened runtime or entitlements

**Fix**:
1. Check Xcode → Signing & Capabilities → Hardened Runtime enabled
2. Verify entitlements (see `entitlements-audit-checklist.md`)
3. Rebuild and resubmit

### Gatekeeper shows "damaged" warning

**Cause**: Notarization ticket not stapled OR quarantine flag set

**Fix**:
1. Verify stapling (Step 7)
2. Remove quarantine flag:
   ```bash
   xattr -d com.apple.quarantine /Applications/Projector.app
   ```

### "No binaries found" during notarization

**Cause**: Submitting source code instead of compiled app

**Fix**:
1. Submit the **DMG** (not .xcodeproj)
2. DMG must contain signed Projector.app

---

## Checklist Summary

- [ ] Code signing verified (all binaries signed)
- [ ] Hardened runtime enabled
- [ ] DMG created
- [ ] Notarization submitted
- [ ] Notarization **Accepted**
- [ ] Ticket stapled to DMG
- [ ] Gatekeeper assessment: `accepted`
- [ ] Tested on clean system (launches without warnings)

**Notarization Complete**: _____ (Yes / No)

**DMG Ready for Distribution**: _____ (Yes / No)

**Next Step**: Upload to App Store Connect OR distribute DMG
