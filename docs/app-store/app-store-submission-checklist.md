# App Store Submission Checklist

Final checklist before submitting Projector v1.0 to the Mac App Store.

**Submission Date**: ___________
**Version**: 1.0.0
**Build Number**: ___________
**Team**: G398H44H6X (Keegan DeWitt)

---

## Pre-Submission Requirements

### App Store Connect Setup

- [ ] **App Store Connect account active**
  - Login: https://appstoreconnect.apple.com
  - Team: G398H44H6X (Keegan DeWitt)
  - Status: Active / **Inactive**

- [ ] **App created in App Store Connect**
  - App Name: Projector
  - Bundle ID: com.keegandewitt.projector
  - SKU: projector-v1
  - Status: Ready for Upload / **Not Created**

### Developer Account

- [ ] **Paid developer program membership active**
  - Expiration date: ___________
  - Membership type: Individual / Company

- [ ] **Certificates installed**
  - Developer ID Application certificate
  - Mac App Store certificate (if using App Store distribution)

---

## Code and Build Verification

### Info.plist Completeness

- [ ] **CFBundleDisplayName**: "Projector"
- [ ] **CFBundleIdentifier**: "com.keegandewitt.projector"
- [ ] **CFBundleShortVersionString**: "1.0.0" (marketing version)
- [ ] **CFBundleVersion**: "1" (build number - increment for each submission)
- [ ] **LSMinimumSystemVersion**: "14.0" (macOS 14+)
- [ ] **NSHumanReadableCopyright**: "Copyright © 2026 Keegan DeWitt. All rights reserved."
- [ ] **CFBundleDocumentTypes**: .projector file type registered
- [ ] **NSSupportsAutomaticTermination**: `true`
- [ ] **NSSupportsSuddenTermination**: `true`

### App Icons

- [ ] **All icon sizes present** in Assets.xcassets/AppIcon.appiconset:
  - [ ] 16x16 (1x)
  - [ ] 32x32 (2x of 16x16)
  - [ ] 32x32 (1x)
  - [ ] 64x64 (2x of 32x32)
  - [ ] 128x128 (1x)
  - [ ] 256x256 (2x of 128x128)
  - [ ] 256x256 (1x)
  - [ ] 512x512 (2x of 256x256)
  - [ ] 512x512 (1x)
  - [ ] 1024x1024 (2x of 512x512 - Mac App Store)

- [ ] **Icon renders correctly**
  - Open app in Finder → Icon visible
  - Mount DMG → Icon visible
  - Dock icon correct when app running

### Document Type Icon

- [ ] **.projector document icon present**
  - Assets.xcassets/DocumentIcon.icondocset
  - All sizes (16x16 to 512x512)
  - Icon appears in Finder for .projector files

---

## Entitlements and Privacy

- [ ] **Entitlements audit complete**
  - See: `entitlements-audit-checklist.md`
  - All required entitlements present
  - No unnecessary entitlements

- [ ] **Privacy Manifest complete**
  - File: `/Projector/PrivacyInfo.xcprivacy`
  - Required reason APIs declared
  - Data collection practices documented (none for v1.0)

- [ ] **Sandbox compliance verified**
  - No sandbox violations in Console
  - All file access via security-scoped bookmarks

---

## Testing and Quality Assurance

- [ ] **Playback test matrix complete**
  - See: `docs/testing/playback-test-matrix.md`
  - All critical scenarios passed
  - No P0 (critical) failures

- [ ] **Audio routing test matrix complete**
  - See: `docs/testing/audio-routing-test-matrix.md`
  - Tested on 2, 4, 6, 8-channel devices
  - No routing failures

- [ ] **Drag-drop test matrix complete**
  - See: `docs/testing/drag-drop-test-matrix.md`
  - Finder and internal drags consistent
  - No visual inconsistencies

- [ ] **Unit tests passing**
  - Command: `xcodebuild test -scheme Projector -destination 'platform=macOS'`
  - Result: _____ tests passed, _____ tests failed

- [ ] **Integration tests passing**
  - End-to-end workflows tested
  - MTC/MMC sync verified

---

## Performance and Polish

- [ ] **Performance targets met**
  - 1080p playback: <10% CPU
  - 10-lane audio: <15% CPU
  - UI: 60fps during playback

- [ ] **Accessibility support** (basic)
  - VoiceOver labels on all buttons
  - Keyboard navigation works
  - Focus indicators visible

- [ ] **Liquid Glass UI consistent**
  - All panels use `.glassPanel()`
  - All buttons use Glass*ButtonStyle
  - No hardcoded padding/spacing violations

---

## Documentation

- [ ] **User documentation complete**
  - `docs/user-guide/getting-started.md`
  - `docs/user-guide/midi-sync-setup.md`
  - `docs/user-guide/audio-routing-guide.md`
  - `docs/user-guide/keyboard-shortcuts.md`
  - `docs/user-guide/troubleshooting.md`

- [ ] **DocC documentation complete**
  - 100% coverage on all public APIs
  - DocC builds without warnings

- [ ] **README.md updated**
  - Current version listed
  - Installation instructions accurate
  - Feature list complete

---

## Code Signing and Notarization

- [ ] **Code signing verified**
  - See: `docs/app-store/notarization-verification-guide.md`
  - All binaries signed with Developer ID
  - Hardened runtime enabled

- [ ] **Notarization complete**
  - DMG submitted to Apple
  - Status: **Accepted** (✅) / Rejected (❌)
  - Ticket stapled to DMG

- [ ] **Gatekeeper approval**
  - Command: `spctl --assess --verbose /Applications/Projector.app`
  - Result: `accepted` + `source=Notarized Developer ID`

- [ ] **Tested on clean system**
  - Launched on Mac without Xcode
  - No Gatekeeper warnings
  - App runs correctly

---

## App Store Connect Metadata

### App Information

- [ ] **App Name**: "Projector"
- [ ] **Subtitle**: "Pro Video Playback with MIDI Sync" (max 30 characters)
- [ ] **Category**: Music / Video / Productivity (choose primary)
- [ ] **Secondary Category**: (optional)

### Description

- [ ] **Description written** (max 4000 characters)

  **Template**:
  ```
  Projector is a professional video playback application for macOS with MIDI timecode synchronization.

  KEY FEATURES
  • Multi-reel video playback with seamless transitions
  • MIDI Time Code (MTC) and Machine Control (MMC) sync
  • Multi-channel audio routing (up to 32 channels)
  • Frame-accurate seeking and timeline editing
  • ProRes optimization for smooth 4K playback
  • Security-scoped bookmarks for project portability

  IDEAL FOR
  • Video editors syncing playback with DAWs
  • Post-production professionals
  • Live event playback operators
  • Film and broadcast workflows

  REQUIREMENTS
  • macOS 14.0 (Sonoma) or later
  • 8GB RAM recommended
  • SSD storage for 4K playback

  SUPPORT
  Documentation: [URL]
  Issues: https://github.com/musiquela/Projector/issues
  ```

- [ ] **What's New in This Version** (max 4000 characters)
  ```
  Initial release of Projector v1.0.

  Features:
  • Professional multi-reel video playback
  • MIDI timecode synchronization (MTC/MMC)
  • Multi-channel audio routing
  • Timeline editing and project management
  • macOS Tahoe design language (Liquid Glass UI)
  ```

### Keywords

- [ ] **Keywords** (max 100 characters, comma-separated)
  ```
  video playback, MIDI, timecode, MTC, MMC, sync, audio routing, ProRes, post-production
  ```

### URLs

- [ ] **Support URL**: https://github.com/musiquela/Projector/issues (REQUIRED)
- [ ] **Marketing URL**: https://projector.app (optional, if site exists)
- [ ] **Privacy Policy URL**: (none for v1.0 - no data collection)

### Screenshots

- [ ] **At least 3 screenshots** (1280x800 minimum, 2560x1600 recommended)
  - [ ] Screenshot 1: Main window (timeline + transport + video player)
  - [ ] Screenshot 2: Settings panel (MIDI sync configuration)
  - [ ] Screenshot 3: Timeline editing (multi-lane audio)
  - [ ] Screenshot 4 (optional): Audio routing panel
  - [ ] Screenshot 5 (optional): Media library

- [ ] **Screenshots are high quality**
  - No pixelation
  - Professional composition
  - Shows actual app content (not marketing graphics)

### App Preview Video (Optional)

- [ ] **App preview video uploaded** (optional for v1.0)
  - Duration: 15-30 seconds
  - Resolution: 1920x1080 or higher
  - Shows key features in action

---

## Pricing and Availability

- [ ] **Price Tier**: Free / Paid (select tier)
  - Recommended for v1.0: **Free** (build user base)
  - Or: **Paid** (e.g., $19.99, $29.99, $49.99)

- [ ] **Availability**: All countries / Select countries
  - Recommended: **All countries**

- [ ] **License Agreement**: Standard Apple EULA / Custom EULA
  - Recommended: **Standard Apple EULA**

---

## Build Upload

### Export and Validate

- [ ] **Archive created**
  - Xcode → Product → Archive
  - Organizer shows archive

- [ ] **Exported for App Store**
  - Organizer → Distribute App → Mac App Store
  - Signed with Mac App Store certificate

- [ ] **Validated successfully**
  - Organizer → Validate App
  - No errors or warnings

### Upload to App Store Connect

- [ ] **Build uploaded**
  - Organizer → Upload to App Store
  - Upload progress: 100%
  - Status: Upload successful

- [ ] **Processing complete**
  - App Store Connect → My Apps → Projector → TestFlight/App Store
  - Status: "Processing" → "Ready to Submit" (~10-30 minutes)

- [ ] **Build appears in App Store Connect**
  - Version: 1.0.0
  - Build: 1 (or current build number)
  - Icon: Projector logo visible

---

## Pre-Submission Review

### App Review Information

- [ ] **Sign-in information** (if app requires login)
  - Demo account: ___________
  - Password: ___________
  - Notes: ___________

- [ ] **Contact information**
  - First Name: Keegan
  - Last Name: DeWitt
  - Phone: ___________
  - Email: ___________

- [ ] **Notes for reviewer**

  **Template**:
  ```
  Projector v1.0 is a professional video playback application with MIDI sync.

  TESTING NOTES:
  1. Import sample video files via File → Import or drag-drop from Finder
  2. Play/pause using spacebar or transport controls
  3. MIDI sync requires external MIDI device (optional for review)

  ENTITLEMENTS:
  • File access: Required for video/audio file import
  • Audio output: Required for playback
  • MIDI: Required for MTC/MMC sync (optional feature)

  No network access, no data collection, fully sandboxed.
  ```

### Age Rating

- [ ] **Age rating questionnaire complete**
  - Unrestricted Web Access: **No**
  - Gambling: **No**
  - Contests: **No**
  - Frequent/Intense content: **No** (media playback app)
  - **Result**: Rated 4+ (all ages)

### Export Compliance

- [ ] **Export compliance**
  - Does app use encryption? **No** (for v1.0)
  - (If yes, requires export documentation)

---

## Submit for Review

- [ ] **All metadata complete**
  - App name, description, keywords, screenshots
  - Pricing, availability
  - Age rating, export compliance

- [ ] **Build selected**
  - Version 1.0.0, Build 1

- [ ] **Ready to submit**
  - Green checkmark on all sections

### Submit

- [ ] **Click "Submit for Review"**
  - Confirmation dialog appears
  - Status changes to "Waiting for Review"

- [ ] **Submission confirmed**
  - Email confirmation received
  - App Store Connect shows "In Review" (~1-3 days)

---

## Post-Submission

### Monitor Review Status

- [ ] **Check status daily**
  - App Store Connect → My Apps → Projector
  - Statuses:
    - "Waiting for Review" → "In Review" → "Pending Developer Release" (approved) OR "Rejected"

- [ ] **Respond to App Review requests** (if any)
  - App Review may request:
    - Demo video of MIDI sync feature
    - Clarification on entitlements
    - Additional screenshots
  - Respond within 24 hours

### If Approved

- [ ] **Release to App Store**
  - Status: "Pending Developer Release"
  - Click "Release This Version"
  - App goes live within 24 hours

- [ ] **Verify app is live**
  - Search "Projector" in Mac App Store
  - App appears in search results
  - Download and test

### If Rejected

- [ ] **Read rejection reason carefully**
  - Common reasons:
    - Missing entitlement justification
    - Incomplete metadata
    - Crash during review
    - Guideline violation

- [ ] **Fix issues**
  - Address rejection reason
  - Increment build number
  - Re-upload build
  - Resubmit for review

---

## Launch Checklist

- [ ] **App live on App Store**
  - URL: https://apps.apple.com/app/projector/id__________

- [ ] **Announce launch**
  - Social media
  - Email newsletter
  - GitHub README updated

- [ ] **Monitor initial reviews**
  - Check App Store reviews daily
  - Respond to user feedback

- [ ] **Monitor crash reports** (if using App Store Connect)
  - Xcode → Organizer → Crashes
  - Fix critical crashes in v1.0.1

---

## Final Sign-Off

**Submission Ready**: _____ (Yes / No)

**Submitted to App Store**: _____ (Yes / No)

**Submission Date**: ___________

**App Review Status**: Waiting for Review / In Review / Approved / Rejected

**Notes**:
_______________________________________________________________
_______________________________________________________________
_______________________________________________________________
