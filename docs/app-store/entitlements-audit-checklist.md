# Entitlements and Sandbox Compliance Audit Checklist

Comprehensive checklist for verifying entitlements and sandbox compliance before App Store submission.

**Audit Date**: ___________
**Auditor**: ___________
**Build Version**: ___________
**Xcode Version**: ___________

---

## Entitlements Files to Audit

- [ ] `/Projector/Projector.entitlements` (main app)
- [ ] `/Projector/ProjectorQuickLook/ProjectorQuickLook.entitlements` (QuickLook extension)

---

## Required Entitlements Checklist

### Sandbox (REQUIRED for App Store)

- [ ] **`com.apple.security.app-sandbox` = `true`**
  - **Status**: _____ (Present / Missing)
  - **Verification**: Open `Projector.entitlements`, verify key exists and value is `true`
  - **Why Required**: All App Store apps must be sandboxed

### File Access (REQUIRED for media playback app)

- [ ] **`com.apple.security.files.user-selected.read-write` = `true`**
  - **Status**: _____ (Present / Missing)
  - **Why Required**: Allows reading/writing files user explicitly selects (Open/Save dialogs, drag-drop)

- [ ] **`com.apple.security.files.bookmarks.app-scope` = `true`**
  - **Status**: _____ (Present / Missing)
  - **Why Required**: Allows storing security-scoped bookmarks to access files after restart

- [ ] **`com.apple.security.files.bookmarks.document-scope` = `true`**
  - **Status**: _____ (Present / Missing)
  - **Why Required**: Allows storing bookmarks within project documents

### Media Playback (REQUIRED)

- [ ] **`com.apple.security.assets.movies.read-write` = `true`**
  - **Status**: _____ (Present / Missing)
  - **Why Required**: Allows reading video files for playback

### Audio Output (REQUIRED)

- [ ] **`com.apple.security.device.audio-output` = `true`**
  - **Status**: _____ (Present / Missing)
  - **Why Required**: Allows audio playback to output devices

---

## Optional/Conditional Entitlements

### MIDI Access (REQUIRED for MTC/MMC sync)

- [ ] **`com.apple.security.device.midi` = `true`** *(if using CoreMIDI)*
  - **Status**: _____ (Present / Missing / Not Needed)
  - **Check**: Does app use CoreMIDI for MTC/MMC sync?
    - [ ] Yes → Entitlement REQUIRED
    - [ ] No → Entitlement NOT needed

### Temporary Exceptions (ONLY if absolutely necessary)

- [ ] **`com.apple.security.temporary-exception.mach-lookup.global-name`**
  - **Status**: _____ (Present / Missing)
  - **Services Listed**: _________________________________
  - **Why Needed**: (e.g., "CoreAudio daemon access for MIDI")
  - **Justification**: Must be documented in App Review Notes

---

## Entitlements to AVOID (App Store Rejection Risk)

### Network Access (NOT NEEDED for Projector v1.0)

- [ ] **`com.apple.security.network.client` = `true`**
  - **Status**: _____ (Present / **SHOULD BE MISSING**)
  - **Action**: If present, REMOVE (app doesn't use network)

- [ ] **`com.apple.security.network.server` = `true`**
  - **Status**: _____ (Present / **SHOULD BE MISSING**)
  - **Action**: If present, REMOVE

### Audio Input (NOT NEEDED for playback-only app)

- [ ] **`com.apple.security.device.audio-input` = `false` or missing**
  - **Status**: _____ (Correctly absent / **INCORRECTLY present**)
  - **Action**: If present, REMOVE (app only outputs audio, no recording)

### USB Access (NOT NEEDED - CoreMIDI handles MIDI devices)

- [ ] **`com.apple.security.device.usb` = missing**
  - **Status**: _____ (Correctly absent / **INCORRECTLY present**)
  - **Action**: If present, REMOVE (CoreMIDI accesses MIDI devices, not direct USB)

---

## App Group Entitlement (REQUIRED if QuickLook shares data with main app)

- [ ] **`com.apple.security.application-groups`**
  - **Status**: _____ (Present / Missing / Not Needed)
  - **Group ID**: `group.com.keegandewitt.projector` (if used)
  - **Verification**:
    - [ ] Same group ID in main app and QuickLook extension
    - [ ] Group registered in Developer Portal

---

## Sandbox Compliance Testing

### Manual Verification with `sandbox-exec`

- [ ] **Run app under strict sandbox constraints**

  **Command**:
  ```bash
  sandbox-exec -f /usr/share/sandbox/bsd.sb /Applications/Projector.app/Contents/MacOS/Projector
  ```

  **Actions to Test**:
  - [ ] Open project file → **Expected**: Works (security-scoped bookmark)
  - [ ] Import video from Finder → **Expected**: Works (user-selected file)
  - [ ] Save project → **Expected**: Works
  - [ ] Play video → **Expected**: Works
  - [ ] Play audio → **Expected**: Works
  - [ ] Access MIDI devices → **Expected**: Works

  **Result**: _____ (All actions passed / Some failed - see notes)

### Console Log Sandbox Violations

- [ ] **Check Console.app for sandbox denials**

  **Command**:
  ```bash
  log show --predicate 'process == "Projector" AND messageType == ERROR' --last 1h | grep "deny"
  ```

  **Result**: _____ violations found

  **Violations (if any)**:
  1. _____________________________________________________
  2. _____________________________________________________
  3. _____________________________________________________

  **Action**: Fix violations by adding required entitlements or changing code

---

## File Access Verification

### Security-Scoped Bookmarks

- [ ] **Project files use security-scoped bookmarks**
  - **Test**: Open project, close app, reopen → project reloads without permission dialog
  - **Result**: _____ (Passed / Failed)

- [ ] **Media files use security-scoped bookmarks**
  - **Test**: Open project with media, close app, reopen → media loads without permission dialog
  - **Result**: _____ (Passed / Failed)

### Fallback to Permission Dialogs

- [ ] **Expired bookmarks trigger permission dialog**
  - **Test**: Manually expire bookmark (modify project file), reopen
  - **Result**: _____ (Shows "Locate Missing Files" dialog / Silent failure)

---

## QuickLook Extension Entitlements

- [ ] **QuickLook entitlements match main app** (subset)
  - **Entitlements in `ProjectorQuickLook.entitlements`**:
    - [ ] `com.apple.security.app-sandbox` = `true`
    - [ ] `com.apple.security.files.user-selected.read-only` = `true` (read-only for previews)
    - [ ] `com.apple.security.application-groups` = same as main app (if sharing data)

  - **Status**: _____ (All correct / Missing entitlements)

---

## Code Signing Verification

- [ ] **All binaries are signed**

  **Commands**:
  ```bash
  # Main app
  codesign -dvv /Applications/Projector.app

  # QuickLook extension
  codesign -dvv /Applications/Projector.app/Contents/PlugIns/ProjectorQuickLook.appex

  # Verify deep signature
  codesign --verify --deep --strict --verbose=2 /Applications/Projector.app
  ```

  **Result**: _____ (All binaries signed / Unsigned binaries found)

  **Unsigned Binaries (if any)**:
  1. _____________________________________________________
  2. _____________________________________________________

---

## Hardened Runtime Verification

- [ ] **Hardened runtime enabled**

  **Command**:
  ```bash
  codesign -dvv /Applications/Projector.app 2>&1 | grep -i runtime
  ```

  **Expected Output**: `flags=0x10000(runtime)`

  **Result**: _____ (Enabled / **NOT ENABLED** - MUST FIX)

- [ ] **No hardened runtime exceptions** (unless justified)

  **Command**:
  ```bash
  codesign -d --entitlements :- /Applications/Projector.app
  ```

  **Exceptions Found**: _____

  **Justification**: _________________________________________

---

## App Store Review Notes (Required for Temporary Exceptions)

If using **any** `com.apple.security.temporary-exception.*` entitlements:

- [ ] **Justification written for App Review Notes**

  **Entitlement**: ___________________________________________
  **Justification**: ________________________________________
  _____________________________________________________________
  _____________________________________________________________

---

## Test Results Summary

**Total Checks**: _____
**Passed**: _____
**Failed**: _____

### Critical Issues (P0 - MUST FIX before submission)

1. _____________________________________________________
2. _____________________________________________________
3. _____________________________________________________

### High-Priority Issues (P1 - SHOULD FIX before submission)

1. _____________________________________________________
2. _____________________________________________________
3. _____________________________________________________

### Low-Priority Issues (P2 - Can defer)

1. _____________________________________________________
2. _____________________________________________________
3. _____________________________________________________

---

## Sign-Off

**Entitlements Audit Complete**: _____ (Yes / No)

**Auditor Signature**: ________________________  **Date**: ___________

**Notes**:
_______________________________________________________________
_______________________________________________________________
_______________________________________________________________
