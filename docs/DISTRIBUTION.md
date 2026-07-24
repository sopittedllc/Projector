# Projector Distribution Guide

Quick reference for creating Gatekeeper-approved builds for direct distribution.

**Team ID**: G398H44H6X
**Bundle ID**: com.projector.app
**Current Version**: 1.2

---

## Quick Distribution Steps

### 1. Archive the App

```
Xcode → Product → Archive
```

Wait for archive to complete (~2-5 minutes).

### 2. Export with Developer ID + Notarization

1. **Window → Organizer** (opens automatically after archive)
2. Select the archive
3. Click **"Distribute App"**
4. Choose **"Developer ID"** (NOT App Store)
5. Select **"Upload"** for automatic notarization
6. Wait for notarization (usually 5-15 minutes)
7. Click **"Export Notarized App"** when approved

### 3. Create DMG (Optional)

```bash
# Create DMG from notarized app
hdiutil create -volname "Projector" \
  -srcfolder /path/to/export/Projector.app \
  -ov -format UDZO \
  Projector-1.2.dmg

# Sign the DMG with timestamp
codesign --timestamp \
  -s "Developer ID Application: Keegan DeWitt (G398H44H6X)" \
  Projector-1.2.dmg
```

### 4. Verify Gatekeeper Approval

```bash
# Verify app signature
codesign --verify --deep --strict --verbose=2 /path/to/Projector.app

# Check Gatekeeper approval
spctl --assess --verbose /path/to/Projector.app
# Expected output: accepted / source=Notarized Developer ID

# Verify DMG signature
codesign --verify --verbose Projector-1.2.dmg
spctl --assess --verbose --type open Projector-1.2.dmg
```

---

## Troubleshooting

### "Developer cannot be verified" Error

The app was not notarized. Re-export using the steps above with "Upload" option.

### "Damaged and can't be opened" Error

Usually means the app was modified after signing. Re-archive and re-export.

### Notarization Rejected

Check the rejection email for details. Common issues:
- Unsigned frameworks/libraries
- Missing hardened runtime
- Invalid entitlements

Run the stapler to check status:
```bash
xcrun stapler validate /path/to/Projector.app
```

---

## Manual Notarization (if needed)

If automatic upload fails, use manual notarization:

```bash
# Create ZIP for notarization
ditto -c -k --keepParent /path/to/Projector.app Projector.zip

# Submit for notarization
xcrun notarytool submit Projector.zip \
  --apple-id "your@email.com" \
  --team-id G398H44H6X \
  --password "@keychain:AC_PASSWORD" \
  --wait

# Staple the ticket to the app
xcrun stapler staple /path/to/Projector.app
```

---

## Build Configurations

| Configuration | Signing Identity | Use For |
|---------------|------------------|---------|
| Debug | Ad hoc (`-`) | Local development and automated testing only |
| Release | Apple Development | Archive → Export with Developer ID |

**Never distribute the Debug product.** It is ad-hoc signed and test builds may embed XCTest support. Release builds use Apple Development for archiving; Developer ID signing happens during the Archive → Export step in Xcode.

For command-line QA, unit tests may use `CODE_SIGNING_ALLOWED=NO`. macOS UI tests must use the project’s default ad-hoc Debug signing or the UI runner will not launch.

---

## Checklist Before Distribution

- [ ] Version numbers updated (Info.plist: 1.2)
- [ ] All entitlements justified and minimal
- [ ] No network entitlement (removed - no license validation yet)
- [ ] Archive builds without errors
- [ ] Notarization succeeds
- [ ] Test on clean Mac without Xcode
- [ ] App opens without security warnings

---

## Related Documentation

- [Notarization Verification Guide](app-store/notarization-verification-guide.md)
- [Entitlements Audit Checklist](app-store/entitlements-audit-checklist.md)
- [App Store Submission Checklist](app-store/app-store-submission-checklist.md)
