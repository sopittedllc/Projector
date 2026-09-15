# Mac App Store Plan

> **Status**: Draft for decision — nothing implemented
> **Written**: 2026-09-15
> **Owner**: Keegan
> **Supersedes**: the generic checklists in `docs/app-store/` (July; wrong
> bundle ID, wrong minimum OS, version `1.0.0`). Keep those only for the
> notarization walkthrough; everything decision-shaped lives here.

---

## Where Projector stands today

Projector is closer to the App Store than a typical Developer ID app, because
the direct build is *already* sandboxed:

| Requirement | Today | App Store |
|---|---|---|
| App Sandbox | ✅ on, and the app works under it | required |
| Hardened runtime | ✅ | not required, harmless |
| Entitlements | user-selected r/w, bookmarks (app + document), movies r/w, audio-output, MIDI, network client | all accepted |
| `temporary-exception.mach-lookup.global-name` (Sparkle XPC) | ✅ present | **rejected** — the one hard blocker |
| Sparkle framework in the bundle | ✅ | must be absent |
| QuickLook extension | sandboxed, read-only | accepted |
| Signing | Developer ID, team `G398H44H6X`, manual | needs Apple Distribution + Mac Installer Distribution |
| Price | free (donations go to Altadena Girls) | free — no Paid Apps agreement, no IAP |

`UpdateServiceProtocol` was written for exactly this: the App Store build swaps
in a service that reports "no updates here" and the menu item hides itself.
The work is therefore mostly *packaging and review risk*, not features.

---

## Decisions needed before Phase 1 (Keegan)

These change what gets built. Recommendations are marked.

1. **Channel strategy.** *Recommend: both.* Direct DMG with Sparkle stays the
   primary channel (fast, no review lag); the App Store is a second front door
   for people who only install from there. One codebase, two build targets.
   Consequence: every release ships twice, and App Store users get it 1–3 days
   later. If you would rather not maintain two, the alternative is
   App-Store-only with Sparkle removed entirely — not recommended while
   releases are this frequent.
2. **Seller identity.** The team `G398H44H6X` is an individual account
   ("Keegan DeWitt"), and that is the seller name the store shows. An
   organisation listing ("So Pitted LLC") means enrolling the LLC (D-U-N-S
   number, ~1–2 weeks) and transferring or re-creating the app. *Recommend:
   ship as the individual first; transfer later if it matters.*
3. **Bundle ID.** *Recommend: keep `com.projector.app` for both channels.*
   Apple allows the same bundle ID for a Developer ID build and an App Store
   build; an App Store install replaces a direct install in place, keeps the
   document association, and the `.projector` UTI stays one identifier. It must
   be registered as an explicit App ID in the developer portal (check —
   Developer ID signing may have used a wildcard).
4. **Version scheme.** App Store Connect requires `CFBundleShortVersionString`
   to be at most three period-separated integers. Today's date scheme
   `2026.09.15` is three integers, but `2026.08.10.3` (a past release) is four
   and would be refused, and leading zeros are undocumented territory.
   *Recommend: `2026.9.15`, and a same-day re-release bumps only
   `CFBundleVersion`* (already `YYYYMMDD.HHMM`, strictly increasing, two
   integers — fine). Sparkle compares `CFBundleVersion`, so the direct channel
   is unaffected. **Verify with a TestFlight upload before relying on it.**
5. **The two installers.** See Risk R1 below — the App Store build should stop
   downloading packages. Decide whether that also changes the direct build
   (simpler, one behaviour) or stays App-Store-only.

---

## Phase 1 — Two build targets, one codebase

**Goal**: an `Projector App Store` target that builds today's app without
Sparkle or the temporary-exception entitlements, from the same sources.

### 1.1 Make the source tree shared automatically

The main target's files are listed individually in `project.pbxproj` (adding
`StemOffPictureReport.swift` today meant four hand-written pbxproj entries).
A second target would double that chore and the two would drift. The
QuickLook target already uses Xcode 16's `PBXFileSystemSynchronizedRootGroup`.

- Convert the `Projector/` group to a synchronized folder (Xcode: select the
  group → File Inspector → *Convert to Folder*).
- Exceptions: `Managers/SparkleUpdateService.swift` is excluded from the App
  Store target via a `PBXFileSystemSynchronizedBuildFileExceptionSet` (the
  same mechanism the QuickLook target uses). Everything else is shared.

**Acceptance**: both targets build with no file added to one but not the other;
`git diff --stat project.pbxproj` for a new source file is zero lines.

### 1.2 Duplicate the target

- Xcode: duplicate `Projector` → `Projector App Store`. Same product name
  `Projector.app`, same `PRODUCT_BUNDLE_IDENTIFIER` (decision 3).
- Remove the Sparkle package product from *Link Binary With Libraries* and the
  *Embed Frameworks* phase of the new target only. The SPM dependency stays in
  the project for the direct target.
- `SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) APP_STORE` on the new
  target.
- `CODE_SIGN_ENTITLEMENTS = Projector/Projector-AppStore.entitlements`: a copy
  of today's file **minus** the `temporary-exception.mach-lookup.global-name`
  block. Nothing else changes.
- `INFOPLIST_FILE = Projector/Info-AppStore.plist`: a copy of today's plist
  **minus** every `SU*` key, **plus** `ITSAppUsesNonExemptEncryption = NO`
  (HTTPS only; skips the export-compliance question on every upload). Two
  plists is duplication, but plist preprocessing is fragile with the
  comments this file carries, and the diff between the two is meant to stay
  tiny — a test in 1.4 enforces it.
- Signing: *Automatically manage signing* for this target only, so Xcode
  provisions the App Store profile; the direct target keeps manual Developer
  ID signing untouched.
- A new scheme `Projector App Store`, shared, archive configuration Release.

### 1.3 Code changes (small, all behind `#if APP_STORE`)

| File | Change |
|---|---|
| `ProjectorApp.swift:101` | `updateService = NoUpdateService()` under `#if APP_STORE`; Sparkle otherwise. |
| `Managers/NoUpdateService.swift` (new) | `UpdateServiceProtocol` with `isEnabled = false`, `canCheckForUpdates = false`, `checkForUpdates()` no-op. The menu item already hides when `!isEnabled` (`ProjectorApp.swift:500`). |
| `Managers/SparkleUpdateService.swift:205` | `UpdateRelaunchHandoff` is Sparkle-free (plain Foundation) but lives in the Sparkle file, which the App Store target excludes. Move it to `Contracts/UpdateServiceProtocol.swift` so `ContentView+Setup.closeRemainingSheets(then:)` compiles in both targets. |
| `Info-AppStore.plist` | Drop `NSAppleEventsUsageDescription` and `NSLocalNetworkUsageDescription` — no code sends Apple Events or uses the local network (grep confirms), and unexplained purpose strings invite reviewer questions. Consider dropping them from the direct plist too. |
| `ProVideoFormatsInstallSheet`, `DAWRoutingSetupSheet` | See R1. |

### 1.4 Tests

- `EntitlementsTests` (new, runs on the built product): read the entitlements
  of the archived App Store app with `codesign -d --entitlements :-` and assert
  no key starts with `com.apple.security.temporary-exception`; assert
  `Sparkle.framework` is absent from `Contents/Frameworks`.
- `InfoPlistParityTests`: the two plists differ only in the `SU*` keys and
  `ITSAppUsesNonExemptEncryption`. Stops the copies drifting.

**Acceptance for Phase 1**: `xcodebuild -scheme "Projector App Store" archive`
succeeds; the archived app launches, opens a project, plays, chases MTC; the
App menu has no *Check for Updates…*; the two tests pass.

---

## Phase 2 — Review risks specific to Projector

Ranked by likelihood of a rejection. Each has a mitigation that should land
*before* the first submission, not after the first rejection.

### R1 — Downloading and opening installers (Guideline 2.4.5(iv), 2.5.2)

`ProVideoFormatsInstaller` and `BlackHoleInstaller` download a package and
hand it to macOS Installer. Projector never installs anything itself, and the
code documents that carefully — but the guideline text is "apps must not
download or install standalone apps, kexts, additional code, or resources to
add functionality", and BlackHole is a HAL driver. A reviewer who clicks
*Install BlackHole* and sees a download progress bar is likely to reject.

*Mitigation*: in the App Store build, the two sheets skip the download and open
the vendor's download page instead (`NSWorkspace.shared.open(URL)` — both
sheets already have that fallback path), with the same step-by-step text.
Pro Video Formats is Apple's own support download, so linking is exactly what
Apple's support article does. Decide (decision 5) whether the direct build
keeps the convenience download.

**Acceptance**: in the App Store build, neither sheet performs a network
request; `URLSession` use in `BlackHoleInstaller`/`ProVideoFormatsInstaller`
is compiled out or unreachable under `APP_STORE`.

### R2 — Hardware the reviewer does not have (Guideline 2.1)

MTC chase needs a MIDI source sending timecode. App Review has no DAW. Apps
that need external hardware must provide a demo video and explain how to
evaluate without it.

*Mitigation*:
- A **review notes** paragraph (kept in `docs/app-store/review-notes.md`, pasted
  into App Store Connect each submission): what the app is, that sync needs a
  DAW, that everything else — import, spotting, playback, routing, cue sheet,
  Create QT Demo — works standalone.
- A **demo video** (screen recording, 2–3 minutes: import stems and picture,
  spot, play, then chase from a DAW) hosted on a URL the reviewer can open.
- A **sample project** with neutral media (the README screenshot project — see
  `never-reference-client-material`; no delivery filenames, no watermarked
  frames) attached as a zip via a link in the notes.
- Consider an **internal MTC test source** (a virtual port that emits MTC from
  Projector's own transport) so a reviewer can watch sync lock with nothing
  attached. Not required for submission; strongly reduces back-and-forth.
  Research item for thomas: whether MIDIKitSync can generate MTC.

### R3 — Public aggregate device from a sandboxed app

`AggregateDeviceManager` creates a *public* aggregate device
(`kAudioAggregateDeviceIsPrivateKey: 0`). It works in today's sandboxed build,
so the sandbox permits it; review does not inspect it. Risk is low, but the
device is system-wide and persists. *Mitigation*: none needed for review.
Note in review notes that DAW routing creates an aggregate device the user can
remove in Audio MIDI Setup, in case a reviewer notices it.

### R4 — App Privacy questionnaire

Projector collects nothing. The bug report composes an email via
`NSSharingService` with a diagnostic bundle — user-initiated, user-sent, not
"collected". *Answer*: **Data Not Collected**. Confirm the diagnostic bundle
contains no file paths under `/Users` that would surprise a user (it is their
own email, but the privacy label should still be honest).

### R5 — Privacy policy URL (mandatory, even with nothing collected)

Publish `docs/privacy.md` on GitHub Pages (the repo is public; enable Pages on
`main` → `/docs`) and use that URL. Content: no data collected; bug reports
are emails the user sends; downloads (if any remain) come from vendor hosts.
Also needed: **Support URL** (the repo's issues page or the user guide) and
optionally a **Marketing URL** (repo README).

### R6 — Screenshots and metadata

- Required sizes: 1280×800, 1440×900, 2560×1600 or 2880×1800; 1–10 images.
  Take them from a **generic project** — never a delivery.
- Name "Projector" is likely taken on the store; check availability early
  (App Store Connect → New App). Fallbacks to decide in advance, e.g.
  "Projector — Spot to Picture". Bundle ID is unaffected by the display name.
- Category: Video (already `public.app-category.video`); secondary Music.
- Age rating: 4+.
- Keywords, subtitle, description — draft in `docs/app-store/metadata.md` so
  they are versioned with the release that shipped them.

### R7 — Version string (decision 4)

Verify on the first TestFlight upload. If App Store Connect refuses
`2026.09.15`, switch `build-release.sh` and `build-appstore.sh` to
`date +%Y.%-m.%-d` together so both channels carry the same marketing version.

---

## Phase 3 — Submission pipeline

**Goal**: a script that does for the App Store what `build-release.sh` does
for the DMG, with the same "print what was skipped" discipline.

### 3.1 App Store Connect setup (one-time, manual)

1. Confirm `com.projector.app` is an explicit App ID with no capabilities
   beyond what the entitlements need (developer portal → Identifiers).
2. Create the app record: name, primary language, bundle ID, SKU
   (`projector`), free, category Video.
3. Certificates: **Apple Distribution** and **Mac Installer Distribution**
   (Xcode → Settings → Accounts → Manage Certificates). Automatic signing on
   the App Store target uses them.
4. App Store Connect API key (App Manager role) stored as
   `~/.private_keys/AuthKey_<ID>.p8`; the script uploads with it, no Apple ID
   password prompt.
5. TestFlight: add yourself as an internal tester.

### 3.2 `scripts/build-appstore.sh`

```
xcodebuild -project Projector.xcodeproj -scheme "Projector App Store" \
    -configuration Release archive -archivePath build/Projector-AppStore.xcarchive \
    MARKETING_VERSION=<version> CURRENT_PROJECT_VERSION=<build>
xcodebuild -exportArchive -archivePath build/Projector-AppStore.xcarchive \
    -exportOptionsPlist scripts/ExportOptions-AppStore.plist \
    -exportPath build/appstore \
    -allowProvisioningUpdates \
    -authenticationKeyPath ~/.private_keys/AuthKey_<ID>.p8 \
    -authenticationKeyID <ID> -authenticationKeyIssuerID <issuer>
```

`ExportOptions-AppStore.plist`: `method = app-store-connect`,
`destination = upload`, `teamID = G398H44H6X`, `uploadSymbols = true`.
Version and build come from the same `date` expressions `build-release.sh`
uses, so a release day produces one version on both channels.

After upload the script prints the App Store Connect URL for the build and
stops: selecting the build, pasting release notes and pressing *Submit for
Review* stay manual until the first three submissions have gone through
cleanly — the review-notes text and the "what's new" text are the parts worth
reading each time.

### 3.3 "Ship" semantics

`CLAUDE.md`'s *Ship* stays the direct release. Add **"ship to the store"** as a
separate phrase that runs `build-appstore.sh` for the version just shipped,
so the App Store never gets a build the direct channel has not already
verified. Document both in `CLAUDE.md`.

**Acceptance for Phase 3**: a TestFlight build installs on this Mac from the
TestFlight app, launches, opens a project, plays and chases; App Store Connect
shows the version string the script set.

---

## Phase 4 — First submission and after

1. TestFlight build → use it for a real session (a week of normal work).
2. Submit with the review notes, demo video and sample project.
3. Expect one rejection round; typical asks are the demo video link, the
   privacy policy, or a question about the aggregate device. Answer in the
   Resolution Center rather than re-submitting blindly.
4. After approval: README gets a *Mac App Store* badge next to the DMG link;
   `docs/user-guide/getting-started.md` says which channel updates how
   (Sparkle vs App Store's own updater).
5. Every direct release is followed by `ship to the store` the same day.
   Crash reports for App Store installs arrive in Xcode Organizer — check them
   at the weekly maintenance pass (isidore).

---

## What this does NOT include

- Paid pricing, IAP, or receipt validation — the app is free.
- iOS/iPadOS — none of the CoreAudio/CoreMIDI routing exists there.
- Removing Sparkle from the direct build.
- Localisation.

---

## Resume instructions

Read this file, then `git log --oneline -- docs/plans/APP-STORE-PLAN.md` to
see which decisions have been recorded (each decision is committed as an
edit to the *Decisions needed* section with the answer and date). Phases are
sequential; a phase is done when its **Acceptance** line holds. Phase 1 needs
no App Store Connect access and can start any time; Phase 3.1 is the only
part that needs the browser.

Related: `docs/software-update.md` (why Sparkle needs the exception),
`Contracts/UpdateServiceProtocol.swift` (the seam the App Store build uses),
`docs/app-store/notarization-verification-guide.md` (still valid for signing
checks), memory `never-reference-client-material` (screenshots, sample
project, demo video).
