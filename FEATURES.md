# Projector - Feature Registry

> **Purpose**: Document all features with their associated files, dependencies, and integration points.
> This file tracks project progress and features.
> **Last Updated**: 2026-03-31

---

## Why This Exists

When features are added, they touch multiple layers: models, views, services, managers, constants, and state. Without a registry, removing or modifying a feature requires manual archaeology. This document ensures:

1. **Clean removal** - Know exactly what to delete
2. **Impact analysis** - Understand dependencies before changes
3. **Onboarding** - New contributors understand feature boundaries
4. **Refactoring** - Identify coupling and integration points

---

## Feature Template

When adding a new feature, copy this template:

```markdown
### [Feature Name]

**Status**: Active | Deprecated | Removed
**Added**: YYYY-MM-DD
**Removed**: YYYY-MM-DD (if applicable)

#### Description
Brief description of what the feature does.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Model | `Models/...` | Data structure |
| View | `Views/...` | UI component |
| Service | `Managers/...` | Business logic |
| ViewModel | `ViewModels/...` | UI state bridge |
| Protocol | `Contracts/...` | Interface definition |
| Utility | `Utilities/...` | Helper/constants |

#### State Properties

| File | Property | Type | Purpose |
|------|----------|------|---------|
| `ContentView.swift` | `@State var showX` | `Bool` | Controls visibility |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `ContentView.swift` | Line ~XXX | View instantiation |
| `TimelineManager.swift` | `MARK: - X Operations` | CRUD methods |

#### Dependencies
- Depends on: [Other features this requires]
- Depended by: [Features that require this]

#### Layout Constants
- `XLayout` enum in `LayoutConstants.swift`

#### Removal Checklist
- [ ] Delete model files
- [ ] Delete view files
- [ ] Delete service files
- [ ] Remove state properties from parent views
- [ ] Remove integration points
- [ ] Remove layout constants
- [ ] Update Xcode project file
- [ ] Clean build and verify
```

---

## Active Features

### Professional Codec Support (Pro Video Formats)

**Status**: Active
**Added**: 2026-08-05

#### Description

Plays professional video formats that macOS has no decoder for on its own — Avid
DNxHD/DNxHR, AVC-Intra, DVCPRO HD, HDV, XDCAM, MPEG IMX, Apple Intermediate Codec and
Uncompressed 4:2:2.

macOS ships decoders only for ProRes, H.264, HEVC, AV1, JPEG and MPEG-4
(`/System/Library/Video/Plug-Ins`). The rest live in Apple's free Pro Video Formats
package and are reachable only after calling
`VTRegisterProfessionalVideoWorkflowVideoDecoders()` once per process — Apple's
instruction from WWDC20 session 10090. Projector makes that call at launch, and when a
codec is still missing it names the format and offers to fetch the package.

Previously such a file imported looking healthy — correct duration, frame rate and
timecode — and then played black with no explanation.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Service | `Managers/ProVideoFormats.swift` | One-time decoder registration; package detection; Apple URLs |
| Service | `Managers/VideoCodecSupport.swift` | Codec identity, decodability, install-eligibility |
| Service | `Managers/ProVideoFormatsInstaller.swift` | Link discovery, host validation, download (actor) |
| View | `Views/ProVideoFormatsInstallSheet.swift` | Install progress, installer hand-off, relaunch |

#### State Properties

| File | Property | Type | Purpose |
|------|----------|------|---------|
| `MediaItem.swift` | `codecName` | `String?` | Codec's display name (**not persisted**) |
| `MediaItem.swift` | `isDecodable` | `Bool?` | Whether this Mac can decode it (**not persisted**) |
| `PlaybackEngine.swift` | `unplayableCodecName` | `String?` | Published so the video area can explain a black frame |
| `ProVideoFormatsInstallModel` | `state` | `State` | Idle / working / awaiting installer / failed |

Neither `MediaItem` field is persisted, deliberately: decodability is a fact about the
machine, not the project. Installing the package changes the answer, and a saved `false`
would outlive the problem and keep reporting a working file as broken.

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `ProjectorApp.swift` | `applicationDidFinishLaunching` | Decoder registration at launch |
| `ProjectMediaLibrary.swift` | `importFile(from:)` | Populates codec fields |
| `ContentView+Timeline.swift` | `addVideoToTimeline`, `presentCodecUnavailable` | Probe + alert after placement |
| `PlaybackEngine.swift` | `loadReel(_:)` | Names the codec before throwing `.notPlayable` |
| `AlertCoordinator.swift` | `.codecUnavailable`, `.proVideoFormatsInstall` | Alert case + sheet case |
| `VideoPlayerView.swift` | `missingCodecPlaceholder` | Replaces the black frame |
| `FloatingVideoPanel.swift` | `InlineVideoArea.onInstallCodec` | Recovery entry point (inline only) |
| `MediaOptimizationService.swift` | `fourCCToString` | Delegates to the shared codec table |
| `Projector.entitlements` | `com.apple.security.network.client` | **First networking in the app** |

#### Behaviour

An undecodable reel still imports. Its timecode, duration and frame rate are correct, so
stems can be placed against it; only the picture is missing. Once the package is
installed and the app relaunches, the existing reel plays with no re-import.

The install offer is limited to codecs the package actually supplies. Anything else gets
a plain error rather than an install that could not help.

#### Security Notes

- Projector **never asks for an administrator password**. It hands the Apple-signed
  package to macOS Installer, which raises the system's own prompt. A sandboxed app
  cannot install a system package, and an app collecting admin credentials in its own UI
  is indistinguishable from one harvesting them.
- Apple signs the **package**, not its disk image (verified: `ProVideoFormats.dmg` is
  unsigned; `ProVideoFormats.pkg` is signed *Apple Software Update* and notarized).
  Trust therefore rests on the download URL being HTTPS on `updates.cdn-apple.com`, plus
  Gatekeeper's own check inside macOS Installer.
- No `SecAssessment` check is attempted: that API is not in the public SDK.

#### Dependencies
- Depends on: Alert/Sheet Coordination, Media Import Coordination
- Depended by: none

#### Tests
- `ProjectorTests/VideoCodecSupportTests.swift` — fourCC rendering, display names, install eligibility
- `ProjectorTests/ProVideoFormatsInstallerTests.swift` — link discovery, host/scheme rejection
- `ProjectorTests/AlertCoordinatorTests.swift` — new case identities, install sheet surviving the queue

#### Known Limitations
- Requires a relaunch after installing; decoders bind at process start.
- The QuickLook extension does **not** register decoders — it previews `.projector`
  project files only and decodes no media.
- Auto-opening the package inside the mounted image may be blocked by the sandbox, in
  which case the user double-clicks it in the Finder window that opened.

---

### Multi-Track Timeline

**Status**: Active
**Added**: 2025-10-XX (initial)

#### Description
Core timeline with video track and multiple audio lanes. Supports drag-and-drop, zoom, playhead, and clip manipulation.

#### Dragging a clip between lanes (fixed 2026-08-25)

Vertical dragging was gated on `clip.sourceType == .videoTrack` in
`AudioLaneView`'s clip gesture: the branch that requested a lane change ran only
for a video's own audio, and every other clip fell into an `else` that moved it
horizontally and dropped the vertical translation on the floor. So the ordinary
case - dragging a stem off the lane it imported onto - did nothing at all, while
the rarer video-linked case worked.

Now every clip previews and commits a lane change, and three things came with it:

- **The horizontal half of the drag is carried across.** `onClipLaneChangeRequested`
  gained a landing frame. A drag is diagonal as often as not, and committing the
  lane while discarding the frame would slide a stem out of sync with picture as
  the price of moving it.
- **Multi-lane hops.** The offset was `verticalOffset > 0 ? 1 : -1`, so a drag
  across four lanes moved one. It is now `round(offset / laneHeight)`, which also
  gives the half-lane commit threshold for free.
- **Overlap is judged at the landing frame,** not the clip's old one. Testing the
  old frame refuses moves into free space and permits moves straight onto another
  clip.

`laneChangeTarget(from:offset:)` resolves the destination for both the preview and
the commit, so the highlighted lane is always the one the drop uses. It refuses a
lane locked to video, for the same reason lane reuse does.

The move registers a snapshot undo rather than the per-clip move undo, because it
mutates two lanes.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Model | `Models/Timeline/Timeline.swift` | Master timeline container |
| Model | `Models/Timeline/TimelineConfig.swift` | Frame rate, bounds config |
| Model | `Models/Timeline/VideoReel.swift` | Video clip data |
| Model | `Models/Timeline/AudioLane.swift` | Audio lane container |
| Model | `Models/Timeline/AudioClip.swift` | Audio clip data |
| Manager | `Managers/TimelineManager.swift` | Timeline CRUD operations |
| View | `Views/Timeline/MultiTrackTimelineView.swift` | Main timeline UI |
| View | `Views/Timeline/VideoTrackView.swift` | Video track rendering |
| View | `Views/Timeline/AudioLaneView.swift` | Audio lane rendering |
| View | `Views/Timeline/AudioClipView.swift` | Audio clip rendering |
| View | `Views/Timeline/VideoReelClipView.swift` | Video clip rendering |
| View | `Views/Timeline/TimelineRulerView.swift` | Timecode ruler |
| ViewModel | `ViewModels/TimelineViewModel.swift` | Timeline UI state |
| Utility | `Utilities/LayoutConstants.swift` | `TimelineLayout`, `ZoomConstants` |

#### State Properties

| File | Property | Type | Purpose |
|------|----------|------|---------|
| `ContentView.swift` | `@StateObject timelineManager` | `TimelineManager` | Timeline data |
| `ContentView.swift` | `@State isTimelineExpanded` | `Bool` | Accordion state |
| `MultiTrackTimelineView.swift` | `@State selectedVideoReelId` | `UUID?` | Selection |
| `MultiTrackTimelineView.swift` | `@State selectedAudioClipIds` | `Set<UUID>` | Multi-selection |

#### Dependencies
- Depends on: PlaybackEngine, WaveformCache, ThumbnailCache
- Depended by: MTC/MMC Sync, Audio Routing

---

### MTC/MMC Synchronization

**Status**: Active
**Added**: 2026-01-02
**Updated**: 2026-08-26 (ports named per protocol)
**Updated**: 2026-08-25 (lock preroll, Full Frame locates, backwards locates)
**Updated**: 2026-03-31 (drift compensation UI)

#### Description
MIDI Time Code (MTC) and MIDI Machine Control (MMC) synchronization for external device control. Runs on dedicated actor for thread safety. Includes live drift monitoring, configurable sync thresholds, and auto-play/pause settings.

#### One port per protocol (2026-08-26)

There was one input, `Projector MIDI IN`, carrying both protocols, and one
output, `Projector MIDI OUT`. A DAW asks for its MTC destination and its MMC
destination in two different dialogs and neither says which of Projector's ports
it wants, so setting up machine control meant reading two names that described
direction rather than content and guessing which end of the arrow was being asked
about.

Now `Projector MTC IN`, `Projector MMC IN` and `Projector MMC OUT`. The names
answer the DAW's dialogs.

**Both inputs accept everything.** The split is a label for the operator, not a
filter: a DAW that sends MTC and MMC down one port still works. Refusing traffic
on the "wrong" port would turn a cosmetic improvement into a way to break a
working session. Said explicitly in Settings, because the split invites exactly
the opposite worry.

The MTC port keeps the UID key the single port used (`ProjectorMIDIInputUID`).
CoreMIDI routing is by unique ID, so from the DAW's side this is a rename of a
port it is already pointed at rather than a port disappearing and a new one
arriving. A DAW that stores routing by *name* still needs re-pointing once.
`legacyInputName` keeps a `selectedMIDIInput` stored by an older version
resolving to "the built-in ports" instead of being hunted for among the hardware.

Verified at the CoreMIDI layer, not just in the app: `MIDIGetDestination` reports
`Projector MTC IN` and `Projector MMC IN`, `MIDIGetSource` reports
`Projector MMC OUT`.

#### Stop stutter and start lag — investigated, unresolved (2026-08-26)

Seven changes were made to the chase path on 2026-08-26 and then reverted. Each
removed a real defect; none changed the reported symptom. The write-up is
**`docs/incidents/2026-08-26-mtc-stop-stutter-unresolved.md`** and it is required
reading before touching this path again.

It records what was ruled out, a measurement error that invalidated the session's
readings (`DispatchTime.rawValue` is in `mach_absolute_time` units, not
nanoseconds), the documented architecture that should be used instead
(`AVPlayer.setRate(_:time:atHostTime:)` scheduled from MIDIKit's `preSync`
payload, per MIDIKit's own reference receiver), why a first implementation of it
was inert, and the audio path that was never examined.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Protocol | `Contracts/MIDISyncServiceProtocol.swift` | Service interface |
| Actor | `Managers/MIDISyncActor.swift` | Thread-safe MIDI handling |
| ViewModel | `ViewModels/MIDISyncViewModel.swift` | UI state bridge |
| View | `Views/SyncStatusIndicator.swift` | Live sync status display |

#### State Properties

| File | Property | Type | Purpose |
|------|----------|------|---------|
| `ContentView.swift` | `midiSyncActor` | `MIDISyncActor` | MIDI service |
| `ContentView.swift` | `midiSyncViewModel` | `MIDISyncViewModel` | UI binding |
| `AppSettings.swift` | `syncDriftThreshold` | `Int` | Re-sync threshold (frames) |
| `AppSettings.swift` | `autoPlayOnMTC` | `Bool` | Auto-play when MTC starts |
| `AppSettings.swift` | `autoPauseOnMTCStop` | `Bool` | Auto-pause when MTC stops |
| `AppSettings.swift` | `respondToMMC` | `Bool` | Respond to MMC commands |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `ContentView.swift` | initialization | Actor creation |
| `SettingsView.swift` | Sync accordion section | Configuration UI |
| `SettingsView.swift` | `midiInfoSection` | Names the three ports and says either input accepts both |
| `OnboardingView.swift` | per-DAW setup steps | MTC destinations name `Projector MTC IN` |
| `WelcomeOverlayView.swift` | MIDI sync row | Names both input ports |

#### Dependencies
- Depends on: MIDIKit (external package)
- Depended by: None

---

### Transport System

**Status**: Active
**Added**: 2026-02-XX (exact date from git history)

#### Description
Thread-safe transport control system using Swift actors. Provides play/pause/stop/seek operations with state streaming to UI layer.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Protocol | `Contracts/TransportServiceProtocol.swift` | Service interface (454 lines) |
| Actor | `Managers/TransportActor.swift` | Actor-isolated state (441 lines) |
| ViewModel | `ViewModels/TransportViewModel.swift` | UI state bridge |

#### State Properties

| File | Property | Type | Purpose |
|------|----------|------|---------|
| `TransportViewModel.swift` | `isPlaying` | `Bool` | Playback state |
| `TransportViewModel.swift` | `currentTimecode` | `Timecode?` | Current position |
| `TransportViewModel.swift` | `transportState` | `TransportState` | Full state |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `VitalControlsBar.swift` | Transport controls | UI binding |
| `TimelineViewModel.swift` | Playhead position | State observation |

#### Dependencies
- Depends on: SwiftTimecodeCore (external package)
- Depended by: MTC/MMC Synchronization, Timeline UI

---

### Audio Routing

**Status**: Active
**Added**: 2026-01-07

#### Description
Per-lane audio output routing with multi-channel support (up to 6 channels). Uses AUMatrixMixer for channel crosspoint routing.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Manager | `Managers/PlaybackEngine.swift` | Audio engine + routing |
| Manager | `Managers/AudioOutputManager.swift` | Device enumeration |
| Model | `Models/Audio/MappedAudioOutput.swift` | Output mapping config |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `AudioLaneView.swift` | Lane header | Output selector UI |
| `TimelineManager.swift` | `setLaneOutputMapping` | Routing config |

#### Dependencies
- Depends on: AVFoundation, AudioToolbox
- Depended by: Multi-Track Timeline, Output Matching from File Names

---

### DAW Routing (Aggregate Device)

**Status**: Active
**Added**: 2026-08-05

#### Description
Carries Projector's stems into a DAW as *inputs*. macOS cannot loop an output back to an
input and Apple does not grant the DriverKit audio entitlement for virtual devices, so
Projector builds a CoreAudio aggregate combining the user's interface with a loopback
device (BlackHole), installing BlackHole when absent.

Sub-device order is the channel map, and the loopback half comes **first**: the stems are
inputs 1-4 in every DAW, with the interface above them. Order is independent of the
clock - the interface remains `kAudioAggregateDeviceMainSubDeviceKey` and the loopback
half is drift-compensated, so the two cannot slide apart over a reel.

Every input channel of the aggregate is named, so no DAW shows a generic port list: stems
by output and side ("DX/SFX L"), everything else by its device and port number. Written on
the aggregate itself, never on the user's devices.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Manager | `Managers/AggregateDeviceManager.swift` | Creates/removes the device; `AggregateChannelMap`, `AggregateChannelOrigin` |
| Manager | `Managers/VirtualAudioPorts.swift` | Finds the loopback device, reports readiness |
| Manager | `Managers/BlackHoleInstaller.swift` | Downloads and installs the driver |
| Manager | `Managers/VirtualPortLabels.swift` | Names the aggregate's input channels |
| View | `Views/DAWRoutingSetupSheet.swift` | Setup flow |
| View | `Views/DAWRoutingSetupModel.swift` | Its state machine |
| View | `Views/AggregateRoutingSummary.swift` | The port list, as the DAW shows it |

#### State Properties

| View | Property | Purpose |
|------|----------|---------|
| `SettingsView` | `showDAWRoutingSetup` | Setup sheet presentation |
| `SettingsView` | `showDAWRoutingHelp` | Explanation popover |
| `SettingsView` | `isRemovingDAWRouting` | Suppresses the stale device during teardown |
| `SettingsView` | `showRemoveDAWRoutingConfirmation` | Guards a destructive removal |
| `SettingsView` | `channelOrigin` | Cached composition; a CoreAudio read kept out of the view body |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `SettingsView.swift` | `deviceRow` | Remove + help, only while the aggregate is selected |
| `SettingsView.swift` | `dawRoutingRow` | Set up / switch to, only while not selected |
| `AudioOutputManager.swift` | `saveMappedOutputs`, `loadMappedOutputs` | Publishes channel names on every change and at launch |
| `AppSettings.swift` | `selectedAudioOutput`, `audioOutputMappings` | Selection and per-device mappings |

#### Constants

| Name | Value | Where |
|------|-------|-------|
| `aggregateUID` | `com.keegandewitt.projector.aggregate` | `AggregateDeviceManager` |
| `aggregateName` | `Projector Aggregate Device` | `AggregateDeviceManager` |
| `virtualHalfName` | `Projector Virtual` | `AggregateDeviceManager` |
| `requiredVirtualChannels` | 4 | `AggregateChannelMap` |

#### Dependencies
- Depends on: CoreAudio, Audio Routing, `VirtualAudioPorts`, BlackHole (third-party driver)
- Depended by: nothing yet

#### Notes
- The device is **public**, so it persists across app quits and reboots; only the ✕ on the
  Device row destroys it.
- `AggregateChannelOrigin.current(in:)` reads the real sub-device order back, so aggregates
  built before the loopback half was moved first are still described correctly.
- Cubase ignores CoreAudio channel names entirely and generates its own from the device
  name; the channel ordering is what makes the stems findable there.

---

### Output Matching from File Names

**Status**: Active
**Added**: 2026-07-27

#### Description
On import, a file whose name says DX, SFX or MX is routed to the mapped output
filling that role. Applied at placement, not offered in a dialog: the name already
says where the stem goes, so asking permission was a question with one sensible
answer - and routing that depended on a sheet appearing meant a drop with no
timecode was never routed at all. The lane's own output menu is the override.

Matching is word-based, not substring: a word must stand alone between separators
(or at a capital following a lowercase/digit) to count, so `MIXDOWN` and
`Dxxx_alt` do not match. A name saying both roles matches neither.

Video is included - a video carries its own audio track onto a lane, and that lane
is routed the same way, found by the extracted clip (which keeps the video's URL
as its source) rather than `Timeline.videoAudioLane`, which returns only the first
such lane and cannot tell two videos apart in one batch.

Only the first clip on a lane sets its routing; a later drop onto an established
lane leaves that lane's output alone.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| View | `Views/SettingsView.swift` | `OutputRole.named(in:)` - name to role matching |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `ContentView+Timeline.swift` | `placementFrame(...)` | The one placement rule, all paths |
| `ContentView+Timeline.swift` | `outputNamedByFile(_:)` | Name to mapped-output lookup |
| `ContentView+Timeline.swift` | `applyNamedOutput(for:laneId:)` | Applied inside `addAudioToTimeline` |
| `ContentView+Timeline.swift` | `applyNamedOutputToVideoAudio(for:)` | Applied inside `addVideoToTimeline` |

#### Dependencies
- Depends on: Audio Routing (`MappedAudioOutput`, `OutputRole`)
- Depended by: none

#### Removal Checklist
- [ ] Remove `OutputRole` "Naming a Role in a Filename" extension from `SettingsView.swift`
- [ ] Remove the three helpers and their two call sites in `ContentView+Timeline.swift`

---

### Set Timeline Start to Region

**Status**: Active
**Added**: 2026-07-27

#### Description
Right-clicking any region - audio clip, video reel, or the video's linked audio -
offers "Set Timeline Start to Region", making that region's timecode the
timeline's start. Content keeps its absolute timecode, so everything shifts back
together and the region lands on frame 0. The end moves with the start, so the
timeline's duration is unchanged. Disabled for a region already at the start.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Manager | `Managers/TimelineManager.swift` | `setTimelineStart(toFrame:)` |
| View | `Views/Timeline/AudioClipView.swift` | Menu item, `onSetTimelineStart` |
| View | `Views/Timeline/VideoReelClipView.swift` | Menu item, `onSetTimelineStart` |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `AudioLaneView.swift` | `onClipSetTimelineStart` | Threads the callback to clips |
| `MultiTrackTimelineView.swift` | Lane list + `linkedAudioStrip` | Calls the manager |
| `VideoTrackView.swift` | Reel clip | Calls the manager directly |

#### Dependencies
- Depends on: Multi-Track Timeline
- Depended by: none

---

### Software Update (Sparkle)

**Status**: Active (unverified - see Verification below)
**Added**: 2026-08-07

#### Description
On launch the app reads a signed appcast, and if a newer build has been
published it offers to download and install it, then relaunches. Updates are
never silent: the user is asked first. Also reachable from **Projector → Check
for Updates...** and **Settings → Updates**.

A sandboxed app cannot replace itself in `/Applications`, so the install runs in
Sparkle's XPC service outside the sandbox, reached via two temporary-exception
entitlements. **Those entitlements are not accepted on the Mac App Store** - see
`docs/software-update.md` and `docs/app-store/entitlements-audit-checklist.md`.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Protocol | `Contracts/UpdateServiceProtocol.swift` | The seam that lets an App Store build swap Sparkle out |
| Manager | `Managers/SparkleUpdateService.swift` | Sparkle-backed implementation, logs each check |
| App | `ProjectorApp.swift` | Owns the service; adds the app-menu item |
| Config | `Projector/Info.plist` | `SUFeedURL`, `SUPublicEDKey`, `SUEnableInstallerLauncherService`, check interval |
| Config | `Projector/Projector.entitlements` | `-spks` / `-spki` mach-lookup exceptions |
| Feed | `appcast.xml` | The published version list, served from main |
| Script | `scripts/appcast.py` | Adds a release to the appcast |
| Script | `scripts/build-release.sh` | Stamps `MARKETING_VERSION`, signs the DMG, publishes the appcast |
| Docs | `docs/software-update.md` | Key generation, release flow, App Store consequence |

#### State Properties

| File | Property | Type | Purpose |
|------|----------|------|---------|
| `ProjectorApp.swift` | `let updateService` | `any UpdateServiceProtocol` | Owned by the delegate; outlives every window |
| `ProjectorApp.swift` | `EnvironmentValues.updateService` | `(any UpdateServiceProtocol)?` | How the view tree reaches it - see below |
| `ContentView.swift` | `@Environment(\.updateService)` | `(any UpdateServiceProtocol)?` | Read from the scene, passed to `SettingsView` |
| `SettingsView.swift` | `var updateService` | `(any UpdateServiceProtocol)?` | Passed in; `nil` hides the section |
| `SettingsView.swift` | `@State var checksAutomatically` | `Bool` | Mirror of the updater's own preference |
| `SettingsView.swift` | `@State var updatesExpanded` | `Bool` | Accordion state |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `ProjectorApp.swift` | `setupMenus()` | Inserts "Check for Updates..." below About |
| `ProjectorApp.swift` | `validateMenuItem` | Greys the item out while a check runs |
| `ContentView.swift` | Settings sheet | Passes the environment's service to `SettingsView` |
| `Projector.xcodeproj` | SPM | Sparkle 2.9.5, `upToNextMajorVersion` |

#### "Install and Relaunch" did nothing (2026-08-08)

**AppKit will not terminate an app with a modal sheet on screen.** It checks,
refuses, and says so - from AppKit's own log, while an update was being installed
with the QT Demo sheet open:

```
Checking whether app should terminate
App termination blocked by modal sheet
```

The download had finished and the install was ready, but the quit request was
refused before `applicationShouldTerminate` was consulted. Nothing broken, nothing
reported.

Fixed with Sparkle's own hook,
`updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`: return `true`,
clear the modals, then invoke the handler. `UpdateRelaunchHandoff` carries that
block and is idempotent, because two things can call it - the interface once its
sheets are gone, and a 3-second timeout in case nothing is listening (no window
yet, or a build without the observer). Sparkle may call the hook again on a later
attempt, which is what makes it safe for the unsaved-changes prompt to cancel: the
update stays pending until the next quit.

Window work lives in the UI layer (`ContentView.closeRemainingSheets`), not in the
manager - `NSApp` has no business in `Managers/`. SwiftUI state is dismissed first
so the app does not go on believing a sheet is up, then an `endSheet` sweep catches
what SwiftUI does not own, retried until the sheets are actually gone because
closing one is animated.

**Not yet verified end to end** - it needs a real pending update on a release
build, so the next actual update is the test.

#### A debug build no longer offers updates (2026-08-08)

`MARKETING_VERSION` is only stamped by the release script, so a build from Xcode
reports whatever the project file says and any published date-version looks newer.
Every launch from Xcode therefore offered an update aimed at a copy in
`DerivedData`.

**And it installed.** This gate was first written to test the code signature,
assuming Sparkle would refuse a development build - it does not. The Debug
configuration is signed with the same Developer ID team as a release, so Sparkle
accepted it and replaced the app *inside DerivedData* with the release build; the
next `xcodebuild` then failed with "Embedded binary is not signed with the same
certificate as the parent app" until the stale bundle was deleted. Measured after
the fact: `TeamIdentifier=G398H44H6X` on the copy in the build folder, running the
release version.

So the gate is the build configuration, which is the thing that actually differs.
A Debug build keeps the service object but leaves it disabled, so the app-menu
item is omitted rather than offered and permanently greyed out. Verified at
runtime: `Update service inert: debug build.`

**There is no Updates section in Settings** (removed 2026-08-08). It showed an
installed version, an automatic-check toggle and a Check Now button for a
mechanism that schedules and runs itself, which in a build that cannot update was
three rows explaining there was nothing to do. Updating is reached from the
application menu's Check for Updates. The `EnvironmentValues.updateService`
plumbing that fed the section went with it; the trap it documented is preserved
on `AppDelegate.updateService`.

#### `NSApp.delegate` is not the app delegate (2026-08-07)

The Settings section was **invisible from the day it shipped**, and not because
of anything in `SettingsView`: `ContentView` fetched the service with
`(NSApp.delegate as? AppDelegate)?.updateService`, which is always `nil`.
`@NSApplicationDelegateAdaptor` installs SwiftUI's own delegate as the
application delegate and forwards the callbacks on. Measured, not assumed:

```
runtime=SwiftUI.AppDelegate  expected=Projector.AppDelegate  isKind=false
```

Both classes being named `AppDelegate` is what hid it - `type(of:)` prints
"AppDelegate" either way. The **Check for Updates** menu item was unaffected
throughout, because it reaches the updater through `self`.

The service is now published into the environment from the scene body, where the
adaptor's property is the real instance. Verified at runtime: the same probe
reports `service=present enabled=true`, and the section renders with the
installed version, the automatic-check toggle and Check Now.

#### Verification

Builds clean. Verified in the built bundle: `Installer.xpc` and `Downloader.xpc`
present in the embedded framework, both mach-lookup exceptions expanded to
`com.projector.app-spks`/`-spki`, all six `SU*` keys in `Info.plist`. Launched:
takes the inert path and logs
`Update service inert: no SUPublicEDKey in Info.plist`, with no error dialog.

**Still unexercised: an actual update.** That needs the EdDSA key pair generated
(`SUPublicEDKey` is empty), and a release published through
`scripts/build-release.sh` so there is an appcast entry to find. Installing also
needs a Developer ID-signed build - the local Debug build is ad-hoc signed.

#### Dependencies
- Depends on: Sparkle 2.9.5 (SPM), the GitHub release pipeline in `build-release.sh`
- Depended by: none

---

### Frame Content on Import

**Status**: Active
**Added**: 2026-08-07

#### Description
After media is imported, the timeline zooms and scrolls so every reel and clip
is on screen. The timeline is at least two hours long whatever is on it, so
fit-to-timeline zoom drew an imported reel as a sliver against an empty field,
and content placed at its own timecode could sit off screen entirely. The fit
solves the zoom curve for the scale that makes the content span the track area,
leaves a 3% margin either side, and scrolls that span into view. Content too
short to fill the track area at maximum zoom is centred instead of pinned left.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Model | `Models/Timeline/Timeline.swift` | `earliestContentFrame` |
| View | `Views/ContentView+Timeline.swift` | `frameImportedContent()`, `snapTimelineStartToContent()` |
| ViewModel | `ViewModels/TimelineViewModel.swift` | `requestZoomToFitContent()`, `zoomToFitContentRequest` |
| View | `Views/Timeline/MultiTrackTimelineView.swift` | `zoomToFitContent()`, `contentFrameRange()`, `scrollFramedContentIntoView(framedStartFrame:framedSpanFrames:expectedDocumentWidth:attempt:)` |

#### The two widths (2026-08-07)

The fit is a function of **two different widths**, and the first version used one
for both jobs:

- The **zoom curve** must be inverted with the same width
  `pixelsPerFrame(for:)` was given - `trackAreaWidth`, the geometry the track
  area was laid out at. Solving with anything else changes the multiplier and so
  the slider position.
- The **target** is what the user can actually see, which is less: measured on a
  five-lane import, the geometry reported 1416pt while the scroll view's clip
  view was 1399pt, and an import that adds lanes brings the vertical scroller in
  *after* the fit runs.

Framing against the larger number spent the whole 3% margin: measured, the
visible span was 176,085 frames against a framed span of 178,355, leaving the
last reel ~21pt from the edge with a 17pt scroller drawn over it. With the widths
separated the visible span is 178,433 frames and the reel sits ~37pt clear.

The scroll offset is likewise derived after layout, from the settled document and
clip view, rather than converted to points with the pre-layout scale.

#### The timeline starts where the content starts (2026-08-08)

An import now snaps the timeline's start to the earliest reel or clip on it, via
the same shift as "Set Timeline Start to Region" — so content keeps its absolute
timecode and the duration is preserved.

`TimelineConfig.default` starts at 00:59:50:00 to leave pre-roll before the hour
mark, and placement never moved it, so a reel delivered at 00:59:52:00 sat two
seconds into a timeline whose first two seconds were dead. At high zoom that dead
space is what you scroll through to reach the picture.

Idempotent, which is what makes it safe after every import: `placementFrame`
clamps at frame 0, so once the earliest thing is at 0 the snap does nothing and a
later import landing further along leaves the start alone.

`Timeline.earliestContentFrame` is on the model, not gathered at the call site,
because framing and snapping must not disagree about what counts as content
(audio counts: a stem can precede the picture). `nil` for an empty timeline —
distinct from content at frame 0.

Every import path goes through `ContentView.frameImportedContent()`, which snaps
then frames, in that order: moving the start changes what frame the content sits
on.

#### Playhead-anchored zoom (2026-08-08)

Every zoom change keeps the playhead on the same pixel. Before this, the scroll
offset stayed put in *points* while the scale changed under it, so the frame at
the left edge was `offset / scale` and zooming in walked the viewport backwards
towards the start of the timeline — the sync point slid away exactly when a
closer look was wanted.

Anchored to the playhead rather than the pointer, matching Pro Tools and Resolve
(Premiere anchors to the pointer instead); a playhead already off screen is
brought to the middle, the deliberate snap-back of a playhead-anchored zoom.

The anchor position is captured **once per zoom burst**, not per value. A zoom
step is animated, so `zoomLevel` arrives as a stream of interpolated values —
measured, 195 across six clicks, some out of order — and re-reading the
playhead's position per value drifted it from 629pt to 204pt over one zoom-out,
because each read saw an offset the previous value had not applied yet. A token
drops superseded scrolls.

Verified: six discrete steps held the playhead at 655.79pt ± 0.2pt; a slider drag
holds it wherever there is scroll room and clamps at fit zoom, where the document
equals the viewport and there is nowhere to scroll.

#### State Properties

| File | Property | Type | Purpose |
|------|----------|------|---------|
| `TimelineViewModel.swift` | `@Published private(set) var zoomToFitContentRequest` | `Int` | Counter; each new value is one request |
| `MultiTrackTimelineView.swift` | `var zoomToFitContentRequest` | `Int` | Request passed in, observed via `onChangeCompat` |
| `MultiTrackTimelineView.swift` | `@State private var trackAreaWidth` | `CGFloat` | Width the zoom curve was computed from. Recorded, never fed back |
| `MultiTrackTimelineView.swift` | `@State private var isFramingContent` | `Bool` | Framing sets its own offset; the anchor stands aside for that one change |
| `MultiTrackTimelineView.swift` | `@State private var pendingAnchorX` | `CGFloat?` | Playhead position held for the zoom burst in progress |
| `MultiTrackTimelineView.swift` | `@State private var anchorToken` | `Int` | Identifies the newest zoom change so superseded scrolls are dropped |

#### Not done (deliberately)

Standard elsewhere, not built — no trackpad pinch / ⌘-scroll zoom, no keyboard
shortcuts (Pro Tools uses ⌘] / ⌘[ and ⌘⌃[ for whole timeline), no zoom-to-selected-region,
no zoom presets. Scoped out on 2026-08-08: fix the anchor only.

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `TimelineAccordionView.swift` | `timelineContent` | Passes the request to the timeline |
| `ContentView+Timeline.swift` | `handleVideoDropOnTimeline` | Requests fit after single and batch imports |
| `ContentView+Timeline.swift` | `handleAudioDropOnTimeline` | Requests fit after single and batch imports |
| `ContentView+Timeline.swift` | `handleMixedBatchDrop` | Requests fit after each placement path |
| `ContentView+Timeline.swift` | `handleAddToAudioLane` | Requests fit after adding from the media panel |
| `ContentView+Timeline.swift` | `showVideoInsertSheetViaCoordinator` | Requests fit after a confirmed insert |

#### Dependencies
- Depends on: Multi-Track Timeline
- Depended by: none

---

### Create QT Demo (review QuickTime)

**Status**: Active (UI not yet runtime-verified - see below)
**Added**: 2026-08-08

#### Description
Prints a review QuickTime: the timeline's picture against a stereo mix the user
supplies, with a chosen set of lanes underneath it. Reached from **Create QT
Demo** in the timeline header, next to Export Cue List.

The mix is placed by its own embedded timecode, so the demo lines up with picture
without the user positioning anything. The demo's length is the mix's length plus
whatever head and tail handles are asked for.

One `AVMutableComposition` serves as both the preview and the thing that gets
encoded — a preview built from a different graph would be a preview of something
else.

**Only the handles rebuild it.** Every lane goes into the composition whether it
is included or not, and both inclusion and level are expressed in the
`AVAudioMix` — so ticking a lane or moving a fader swaps the mix on the player
item already playing and the preview never stops. The first version built only
the included lanes, which meant the two controls you use *while listening* were
the ones that restarted the preview from the head.

Encoded with `AVAssetExportPreset1920x1080`: H.264 in a `.mov`, capped at 1080p
(a preset only ever scales down) at the **source frame rate**. The media
optimisation preset is deliberately *not* reused - it caps at 30fps, and a 23.976
reel resampled to 30 is useless for judging sync.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Manager | `Managers/QuickTimeDemoBuilder.swift` | Span maths, composition + mix assembly, export |
| View | `Views/QuickTimeDemoSheet.swift` | Mix picker, preview player, lane/level rows, handles, export |
| Coordinator | `Coordinators/AlertCoordinator.swift` | `quickTimeDemo(content:)` sheet case |
| View | `Views/TimelineAccordionView.swift` | The button, beside Export Cue List |
| View | `Views/ContentView+Timeline.swift` | `presentQuickTimeDemo()` |

#### Decisions

- **Lanes start excluded.** The mix is the thing being judged; adding lanes is a
  decision. A default that included everything would double the music under a new
  cue, which is worse than starting quiet.
- **A mix with no timecode is refused**, not placed at a guess. The whole point is
  that it lands where the picture is.
- **`AudioLane.volume` is deliberately ignored.** There is no control for it
  anywhere in the app, so folding it in would make the printed level differ from
  the number on the slider for a reason the user could not see. The number on
  screen is the number applied.
- **The mix is the first fader in the same list as the lanes**, with its toggle
  disabled - balancing it against them is the whole job, so separating it out read
  as two unrelated controls.
- **The picker disappears once a mix is chosen.** Its name moves to the header
  with a Change… button; leaving a picker and a duplicate summary on screen put
  clutter above the controls actually in use.
- **A lane with no audio in the span is shown but not toggleable**, marked
  "nothing in this range" - a toggle that silently does nothing is worse than one
  that is visibly unavailable.
- **The tail is not clamped to the timeline.** A mix may run past the last reel,
  and black picture with the audio continuing is the honest answer.
- Presented through `AlertCoordinator` rather than a new `.sheet` on
  `ContentView`, whose body is already at the Swift type-checker's limit.

#### Verified

End to end, headlessly: a 30s reel at 01:00:00:00, an MX stem, and a 10s mix at
01:00:05:00 with 2s head and 3s tail produced a 15.000s H.264 1280x720 @ 24/1
`.mov` with AAC stereo. Measured in the output:

| Segment | stem (220 Hz) | mix (880 Hz) |
|---|---|---|
| head 0-2s | -27.07 dB | silent |
| middle 3-11s | -27.07 dB | -21.07 dB |
| tail 12.2-15s | -27.07 dB | silent |

The mix sits exactly in its timecode window, the handles carry picture and stem
only, and the stem lands 6.00 dB under the mix - exactly the -6 dB lane gain that
was set. Re-measured after every lane moved into the composition: the included
numbers are unchanged, and with the lane excluded the stem reads -142.96 dB
(silence) while the mix stays at -21.07 dB. Span arithmetic is covered by
`QuickTimeDemoSpanTests` (7 cases).

**Not verified**: the sheet itself. Nobody has clicked the button, chosen a file
in the panel, watched the preview, or ridden a fader.

#### Not built (deliberately)

No timecode burn-in, no HEVC option, no per-clip levels, no saved presets, and no
CRF control - the preset chooses the bitrate. Scoped on 2026-08-08 to per-lane
gains and H.264 capped at 1080p.

#### Dependencies
- Depends on: Multi-Track Timeline, Alert/Sheet Coordination, Embedded Timecode
- Depended by: none

---

### One Frame Rate per Batch Import

**Status**: Active
**Added**: 2026-08-07

#### Description
A multi-file video import settles the frame rate for the whole batch **before**
placing anything: every file's rate is read, the project's rate is decided (an
empty timeline adopts the first file that reports one, as a single import
already did), and only the files matching it are imported. Whatever is left over
is named in one report at the end.

Replaces a per-file dialog that could not work in a batch. The dialog is driven
by one slot of pending state (`pendingVideoURL` / `pendingVideoFPS`) and the
import loop does not wait for it, so a second mismatching file overwrote the
first file's URL while the first file's dialog was still on screen, and a third
queued behind a dialog whose state had since been cleared.

Measured on a drop of three reels at 24, 25 and 30 fps, before the fix:

- **one** reel imported
- the dialog said "This video is 25 fps" while pointing at the 30 fps file, and
  its Change Project FPS button would have removed the reel just imported
- the third file vanished with nothing said about it

After: the 24 fps reel imports, and one **Not Imported** alert names
`MixB_25.mov` and `MixC_30.mov` against the project's 24 fps. Nothing is silently
lost, and no destructive offer is made in the middle of a batch.

Single-file imports are unchanged - there the offer to change the project's rate
is actionable and unambiguous, so `fpsConflict` still handles it.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| View | `Views/ContentView+Timeline.swift` | `addVideoFilesSequentially`, `frameRates(of:)`, `batchProjectFrameRate(urls:rates:)` |
| Coordinator | `Coordinators/AlertCoordinator.swift` | `batchFrameRateMismatch(names:projectFPS:)` case and its alert |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `ContentView+Timeline.swift` | `handleVideoDropOnTimeline` | Batch path; unchanged call site |
| `ContentView+Timeline.swift` | `handleMixedBatchDrop` | Batch path; unchanged call site |
| `ContentView+Timeline.swift` | `splitOffers.expect` | Counts importable files, not the whole drop |

#### Dependencies
- Depends on: Multi-Track Timeline, Alert/Sheet Coordination
- Depended by: none

---

### Stem Lanes on Batch Import

**Status**: Active
**Added**: 2026-08-12

#### Description
A batch drop puts audio files that declare the same stem on the **same lane**,
instead of one lane per file.

A reel-based delivery arrives as one file per reel per stem: five reels hand
over five `_DX_FX` files and five `_MX` files. One lane per file made ten lanes
holding one clip each, when the material is two stems cut into reels — nine of
them mostly empty, the timeline reading as a staircase rather than two
continuous stems.

The stem is read from the **end** of the filename, because that is the part a
delivery keeps constant: the reel number varies, and so can the descriptive
middle (a reel carrying an end-title song says so), but `_DX_FX` does not.
Tokens are taken from the end while they are a known role (`DX`, `MX`, `FX`,
`M&E`, `VO`, `FOLEY`, …, plus longer spellings) or trailing noise (a reel
number, `STEM`, a channel layout, `v2`). The walk stops at the first token that
is neither, so a project code or session name is never read as a stem.

A lane is named after the stem (`DX FX`, `MX`) only when the group collects more
than one file; a lone file keeps the filename-based lane name it has always had.
Files whose names declare no stem are unchanged — one lane each.

#### Only files that carry timecode are placed

Grouping alone was not enough, because placement undid it. A file with no
timecode used to go to the **drop frame** — the same frame for every file in the
batch. A picture turnover routinely carries no timecode at all, so every file in
a group asked for the same frames of the same lane, and
`addAudioToTimelineAvoidingOverlap` spills an overlapping file onto a lane of its
own. The grouped delivery came apart into a lane per file again, which is exactly
the symptom the grouping was built to fix.

The answer is not a better guess. A file that does not say where it belongs is
**held back**: added to the media panel, not to the timeline, and named in one
`timecodelessNotPlaced` alert. Guessing produces a timeline that looks finished
and is quietly wrong — a stem shorter than its reel drags every later reel on its
lane early, with nothing on screen to say so — and the delivery has a real
problem that the import is the right moment to surface.

The rule applies to `handleMixedBatchDrop` and to both media types, because that
handler is the one that *invents* destinations: a lane per stem for the audio, a
running position for the reels. A drop that names a lane and a frame is an
instruction, and `handleAudioDropOnTimeline` still honours it.

What counts as saying where it belongs: embedded timecode for anything, plus a
timecode in the **name** for video, because a filename timecode is exactly what
`addVideoFilesSequentially` places a video by. Audio deliberately does not count
one — no audio placement path reads it, so counting it here would let a file
through to be placed at the drop position after all.

The overlap rule itself is untouched, and is still the backstop: stems that
genuinely play at the same time cannot be stacked invisibly by this grouping.

#### A stem the timeline already carries keeps its lane (2026-08-25)

Grouping within one drop was only half the job. A session is built one turnover
at a time: reel 2 arrives in its own drop, days after reel 1. Each drop created
its own lanes, so the staircase came back one turnover later - three lanes after
the first drop, six after the second, and the lane names still filename-based
because each group held one file.

`handleMixedBatchDrop` now looks for a lane already carrying the group's stem
before creating one. The lane's stem is read back from the clips on it with the
same parser that grouped the drop, not from its name: a lane holding one file is
named after that file, so the DX lane in a session built reel by reel is called
`Show_R1_v2_DX` and matching on the name would never find it.

Two guards on what may be reused:

- **Not a video's audio lane.** Those belong to a reel and move with it, so a
  stem parked there would be dragged around by a reel it has nothing to do with.
- **Not a lane holding a mixture.** Every clip must parse to the same stem. A
  lane that says two things says nothing reliable, and guessing there would put
  a music reel under dialogue - worse than the extra lane being fixed.

A reused lane is renamed after its stem once it collects more than one file,
which is the same rule a fresh multi-file group follows, applied a drop late.
Skipped unless the current name is one the app generated - a filename of a clip
on the lane, or an `Audio N` placeholder - so a lane named by hand is never
renamed underneath the user.

A reused lane is deliberately **not** added to `batchCreatedLaneIds`. That set
drives `discardEmptyLanesCreatedForDrop()`, and a reused lane is somebody else's
with clips already on it; deleting it because this drop's file collided would
take the previous reel down with the failed import.

Existing duplicate lanes are left alone. A later drop consolidates onto the
topmost match, but nothing auto-merges lanes already on the timeline - that is a
destructive edit the user did not ask for.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Utility | `Utilities/AudioStemGrouping.swift` | `AudioStemRole`, `AudioStemLabel`, `AudioStemGroup`, filename reading and batch grouping |
| Utility | `Utilities/TimecodelessImportReport.swift` | Title, name cap and message for the held-back-files alert |
| Tests | `ProjectorTests/AudioStemGroupingTests.swift` | Name reading, aliases, noise, grouping, reel ordering, cross-drop stem keys |
| Tests | `ProjectorTests/TimecodelessImportReportTests.swift` | Truncation, singular/plural, what the message must say |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `ContentView+Timeline.swift` | `handleMixedBatchDrop` | Lane reservation loop now iterates stem groups, not files; reuses a lane the stem already owns |
| `ContentView+Timeline.swift` | `laneAlreadyCarrying(_:)` | New. Finds the lane a stem is already laid out on |
| `ContentView+Timeline.swift` | `adoptStemName(_:forLane:)` | New. Renames a reused lane after its stem, guarded against hand-named lanes |
| `ContentView+Timeline.swift` | `holdBackFilesWithoutTimecode` | New. Partitions the drop, imports the held-back files to Media, raises the alert |
| `AlertCoordinator.swift` | `AlertType.timecodelessNotPlaced` | New report-only alert case |

#### Dependencies
- Depends on: Multi-Track Timeline, Media Import Coordination
- Depended by: none

---

### No Output ("None") on a Lane

**Status**: Active
**Added**: 2026-07-27

#### Description
The lane output menu offers **None**, which routes the lane nowhere and silences
it - a binary mute that lives with the routing rather than the transport. Kept
distinct from `isMuted` so the two controls do not fight: M is a transport state,
None is where the lane's audio goes. The picker draws unfilled when set to None.

Enforced in `Timeline.activeAudioClips(at:)`, the one place that decides what
sounds, so no engine path can bypass it. Rule 5 of the routing authority keeps the
three auto-assigners from quietly undoing it.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Model | `Models/Timeline/AudioLane.swift` | `isOutputDisabled` (+ Codable, defaults false) |
| Model | `Models/Timeline/Timeline.swift` | `activeAudioClips(at:)` skips silenced lanes |
| Manager | `Managers/TimelineManager.swift` | `disableLaneOutput(id:)`, routing authority Rule 5 |
| View | `Views/Timeline/AudioLaneView.swift` | None entry, `outputPickerLabel`, `onOutputNone` |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `TimelineManager.swift` | `setLaneOutputMapping` | Choosing an output clears the flag |
| `TimelineManager.swift` | `reconcileOutputMappings` | Skips silenced lanes (Rule 5) |
| `AudioLaneView.swift` | `applyDefaultMappingIfNeeded` | Skips silenced lanes |
| `ContentView.swift` | `onChange(of: mappedOutputs)` | Skips silenced lanes |
| `VideoTrackView.swift` | `AudioLaneControls` | None for the video's audio lane |

#### Dependencies
- Depends on: Audio Routing, Multi-Track Timeline
- Depended by: none

#### Removal Checklist
- [ ] Remove `isOutputDisabled` from `AudioLane` (property, init, CodingKeys, coder)
- [ ] Remove the skip in `Timeline.activeAudioClips(at:)`
- [ ] Remove `disableLaneOutput(id:)` and Rule 5; revert the three auto-assigner guards
- [ ] Remove the None entry and `onOutputNone` from the lane picker and its call sites

---

### Waveform Rendering

**Status**: Active
**Added**: 2025-XX-XX

#### Description
Async waveform generation and caching for audio clips using DSWaveformImage library.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Manager | `Managers/WaveformCache.swift` | Waveform data cache |
| Manager | `Managers/WaveformGenerator.swift` | Sample extraction |

#### Dependencies
- Depends on: DSWaveformImage (external package)
- Depended by: Multi-Track Timeline

---

### Video Thumbnails

**Status**: Active
**Added**: 2025-XX-XX

#### Description
Async thumbnail generation for video reels displayed in timeline.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Manager | `Managers/ThumbnailCache.swift` | Thumbnail cache |

#### Dependencies
- Depends on: AVFoundation
- Depended by: Multi-Track Timeline

---

### File Manager Panel

**Status**: Active
**Added**: 2025-XX-XX

#### Description
Collapsible panel showing project media library with grid view.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| View | `Views/FileManager/FileManagerView.swift` | Panel UI |
| View | `Views/FileManager/MediaItemRow.swift` | Grid item |
| Manager | `Managers/ProjectMediaLibrary.swift` | Media tracking |
| Utility | `Utilities/LayoutConstants.swift` | `FileManagerLayout` |

#### State Properties

| File | Property | Type | Purpose |
|------|----------|------|---------|
| `ContentView.swift` | `@State isMediaPanelExpanded` | `Bool` | Accordion state |

---

### Alert/Sheet Coordination

**Status**: Active
**Added**: 2026-03-XX

#### Description
Centralized alert and sheet management using enum-based type safety. Replaces scattered @State booleans with single source of truth.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Coordinator | `Coordinators/AlertCoordinator.swift` | Alert/sheet type enum and view modifier |

#### State Properties

| File | Property | Type | Purpose |
|------|----------|------|---------|
| `ContentView.swift` | `@StateObject alerts` | `AlertCoordinator` | Centralized alert state |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `ContentView.swift` | `.alertCoordinator()` modifier | View modifier application |
| `ContentView+Timeline.swift` | `alerts.show()` calls | Alert triggering |

---

### Media Import Coordination

**Status**: Active
**Added**: 2026-03-XX

#### Description
Coordinates media file import with duplicate detection, optimization suggestions, and timeline integration.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Coordinator | `Managers/MediaImportCoordinator.swift` | Import workflow orchestration |

#### Dependencies
- Depends on: ProjectMediaLibrary, TimelineManager, MediaOptimizationService

---

### Missing File Resolution

**Status**: Active
**Added**: 2026-03-XX

#### Description
Handles missing media file detection and resolution with locate/skip/skip-all options.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Service | `Managers/MissingFileResolutionService.swift` | Missing file detection and resolution |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `ContentView.swift` | Project loading | Missing file check |
| `AlertCoordinator.swift` | `.missingFile` case | User prompts |

---

### Audio Extraction Service

**Status**: Active
**Added**: 2026-01-XX

#### Description
Two-phase async audio extraction from video files for waveform generation and audio lane creation.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Service | `Managers/AudioExtractionService.swift` | Audio track extraction |

#### Dependencies
- Depends on: AVFoundation
- Depended by: WaveformGenerator, AudioLane creation

---

### Timecode OCR

**Status**: Removed
**Added**: 2026-02-XX
**Removed**: date unknown - found gone on 2026-08-25

#### Description
OCR-based timecode detection from video frames using the Vision framework, as a
fallback for media carrying a burned-in timecode window but no embedded track.

#### Why this entry says "date unknown"

It was still listed Active while nothing of it remained. Checked on 2026-08-25:
`Managers/TimecodeOCRManager.swift` does not exist, no Swift or test file
mentions `TimecodeOCR` or OCR, and the pbxproj has no entry for it. The registry
was the only place the feature still existed, which is exactly the archaeology
the registry is meant to prevent - so it is corrected here rather than quietly
deleted.

`EmbeddedTimecodeService` is unaffected: it still reads QuickTime, BWF and XMP
timecode. Only the OCR fallback is gone, so a file with a burned-in window and no
embedded timecode is placed by filename or at the drop frame like any other.

#### Files (Deleted)

| Type | Path | Purpose |
|------|------|---------|
| Manager | `Managers/TimecodeOCRManager.swift` | Vision-based OCR |

#### Integration Points (Removed)

| File | Location | Integration Type |
|------|----------|------------------|
| `EmbeddedTimecodeService.swift` | OCR fallback | Detection pipeline |

---

### Standalone Player Window

**Status**: Active
**Added**: 2026-07-24

#### Description
The video player is a permanent separate window, never embedded in the main
window. Closing it hides it and playback continues; it is reopened from the
timeline toolbar or the View menu. A "Lock to Foreground" pin floats it above
all other apps, including fullscreen ones, so it stays visible over a
fullscreen DAW.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Controller + View | `Views/FloatingVideoPanel.swift` | `PlayerWindowController` (window lifecycle, pin, hide-on-close) and `PlayerWindowContent` (video, hover controls, drops). Filename is historical - see the note at the top of the file. |

#### State Added

| Property | Location | Purpose |
|----------|----------|---------|
| `playerWindowPinnedToFront` | `Models/AppSettings.swift` | Persisted pin state (@AppStorage) |
| `pinPlayerMenuItem` | `ProjectorApp.swift` (AppDelegate) | Retained menu item so the checkmark can be re-synced |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `Views/ContentView.swift` | `normalView.onAppear` | `configure(...)` + `show()`; supplies drop handlers |
| `Views/Timeline/MultiTrackTimelineView.swift` | Toolbar | "Show the video player window" button |
| `ProjectorApp.swift` | `setupMenus` (View menu) | "Show Video Player" (Shift-Cmd-P), "Lock Player to Foreground" (checkmark) |
| `ProjectorApp.swift` | `applicationDidFinishLaunching` | Observes `.playerWindowPinDidChange` to sync the checkmark |

#### Notes

- Window frame/screen persist via `setFrameAutosaveName("PlayerWindow")`.
- Uses `NSWindow`, not the old non-activating `NSPanel`, so it can become key
  for native fullscreen and keyboard transport.
- Pin = `.floating` level + `[.canJoinAllSpaces, .fullScreenAuxiliary]`.

---

### Bug Reporting

**Status**: Active
**Added**: 2026-08-02

#### Description

Lets any user - not just beta testers - report a problem with a diagnostic
report attached. An always-on ring buffer records recent events; the sheet
gathers those plus machine, device and project facts, shows the user the whole
report, and hands it to their mail client as a `.txt` attachment.

Reachable two ways: a ladybug button right of Settings in the timeline header,
and Help > Report a Bug...

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Protocol | `Contracts/DiagnosticLogServiceProtocol.swift` | `DiagnosticLevel`, `DiagnosticCategory`, `DiagnosticEntry`, `DiagnosticLogService` |
| Service | `Managers/DiagnosticLog.swift` | Ring-buffer actor + `diagnosticLog(_:_:_:)` free function |
| Service | `Managers/DiagnosticReportBuilder.swift` | `SupportContact`, `DiagnosticUnits`, `DiagnosticSnapshot`, `SystemFacts`, report formatting |
| ViewModel | `ViewModels/BugReportViewModel.swift` | Gathering, email/save/copy delivery |
| View | `Views/BugReportView.swift` | The sheet |

#### State Properties

| File | Property | Type | Purpose |
|------|----------|------|---------|
| `ContentView.swift` | `@State var showBugReport` | `Bool` | Sheet visibility |
| `ContentView.swift` | `@State var bugReportViewModel` | `BugReportViewModel?` | Rebuilt each time the sheet opens |
| `BugReportView.swift` | `@State private var isShowingReport` | `Bool` | Review pane, expanded by default |

#### Integration Points

| File | Location | Integration Type |
|------|----------|------------------|
| `TimelineAccordionView.swift` | `accordionHeader`, after Settings | Ladybug button + `onReportBugPressed` callback |
| `ContentView.swift` | `timelinePanel(_:)` | Passes `onReportBugPressed` |
| `ContentView.swift` | `presentBugReport()`, `makeDiagnosticSnapshot()` | Sheet presentation + state gathering |
| `ContentView.swift` | body `.sheet` + `.onReceive` | Sheet and menu notification |
| `ProjectorApp.swift` | `setupMenus()`, `reportBug(_:)` | Help menu item |
| `ProjectorApp.swift` | `.projectorReportBugRequested` | Notification name |
| `ProjectorApp.swift` | `applicationDidFinishLaunching` | Fixes `SystemFacts.launchDate`, logs launch |
| `PlaybackEngine.swift` | `play()`, `pause()`, reel/clip load failures, `setAudioOutputDevice` | `diagnosticLog` calls |
| `ProjectMediaLibrary.swift` | `importFiles(from:)` | Per-file import success/failure |
| `ProjectPersistenceService.swift` | `saveProject()`, `openProject(from:)` | Save/open outcomes |
| `MIDISyncViewModel.swift` | `subscribeToSyncState()` | MTC state + input transitions only |

#### Dependencies

- Depends on: nothing. The log is self-contained and records whether or not the
  sheet is ever opened.
- Depended by: nothing yet. Any subsystem can call `diagnosticLog`.

#### Layout Constants

- `BugReportLayout` (private) in `Views/BugReportView.swift`
- `DiagnosticLogConstants` in `Managers/DiagnosticLog.swift`
- `DiagnosticUnits` in `Managers/DiagnosticReportBuilder.swift`

#### Notes

- **Change `SupportContact.email`** in `DiagnosticReportBuilder.swift` to
  redirect reports. It ships in the binary and is visible to anyone who has the
  app.
- `diagnosticLog` is **not** compiled out of release builds - that is the point.
  It is still not safe for real-time paths: never call it from an audio render
  callback, a MIDI quarter-frame handler, or per-video-frame code.
- Debug-level entries are dropped in release builds so the ring covers a longer
  stretch of real time.
- Entries are recorded through detached tasks and can arrive out of order; they
  are timestamped at the call site and `snapshot()` sorts by that.
- Mirrored to `os.Logger` under subsystem `com.keegandewitt.projector`. Info
  level is memory-only, so `log show` will not find it - use
  `log stream --predicate 'subsystem == "com.keegandewitt.projector"' --info`.

#### Removal Checklist

- [ ] Delete the five files above
- [ ] Remove `onReportBugPressed` from `TimelineAccordionView` and its button
- [ ] Remove the two `ContentView` state properties, `.sheet`, `.onReceive`,
      `presentBugReport()`, `makeDiagnosticSnapshot()`
- [ ] Remove the Help menu block, `reportBug(_:)`, `reportBugMenuTitle` and the
      notification name from `ProjectorApp.swift`
- [ ] Remove `diagnosticLog` calls listed under Integration Points
- [ ] Remove the five file references from `project.pbxproj`

---

## Removed Features

### Import Placement Dialogs

**Status**: Removed
**Added**: various (Spot Media 2026-03, batch/embedded timecode earlier)
**Removed**: 2026-07-27

#### Description
Three sheets used to ask where a dropped file should go: `SpotMediaSheet` (single
video: filename / metadata / manual / playhead), `EmbeddedTimecodeSheetView`
(single audio with timecode) and `BatchTimecodeSheetView` (multi-file, with a
per-file "Use TC" column).

Removed because import can answer the question itself: a file goes to its own
timecode, and both the position and the routing are changeable afterwards from
the region's right-click menu and the lane's output dropdown. Asking first was a
step with one sensible answer.

#### What was removed
- `Views/SpotMediaSheet.swift`, `Views/BatchTimecodeSheetView.swift`,
  `Views/EmbeddedTimecodeSheetView.swift` (+ their pbxproj entries)
- `AlertCoordinator` cases `.embeddedTimecode`, `.batchTimecode`, `.spotMedia`
- `ContentView` state: `pendingTimecode*`, `pendingBatchTimecode`, `pendingSpot*`,
  `rememberedSpotChoice`
- `ContentView+Timeline`: the three `show*ViaCoordinator`, `handleTimecodeChoice`,
  `handleBatchTimecodeConfirm`, `handleSpotResult`, `handleRememberedSpotChoice`,
  the three `clearPending*`, `addAudioFilesSequentially`, and the `isShowing*`
  helpers for those sheets
- `PendingBatchTimecode`, and `BatchTimecodeItem.useEmbeddedTimecode`

#### What was kept
- `detectTimecodeFromFilename` - moved from `SpotMediaSheet.swift` to
  `ContentView+Timeline.swift`, still used for filename timecode
- `BatchTimecodeItem` and `detectTimecodeForBatch`, now carrying detection results
  only, with no user choice attached
- The video insert and FPS conflict dialogs, which are not import placement

#### Replaced by
`placementFrame(metadata:filenameTimecode:dropFrame:)` in `ContentView+Timeline`,
the single rule every import path uses.

---

### Floating Video Panel (pop-out / pop-back)

**Status**: Removed
**Added**: 2026-01-XX
**Removed**: 2026-07-24

#### Reason
Replaced by the always-present Standalone Player Window. Popping the video in
and out was extra state to keep consistent with no benefit once the player has
its own permanent window.

#### What Was Removed

| Symbol | Former Location | Notes |
|--------|-----------------|-------|
| `FloatingVideoPanelController` | `Views/FloatingVideoPanel.swift` | Rewritten as `PlayerWindowController` in the same file |
| `FloatingVideoContent` | `Views/FloatingVideoPanel.swift` | Rewritten as `PlayerWindowContent` |
| `isVideoFloating`, `floatVideoWindow()`, `returnVideoFromFloat()` | `Views/ContentView.swift` | Pop-out state and actions |
| `videoSection`, `embeddedVideoPlayer`, `videoFloatingPlaceholder` | `Views/ContentView.swift` | Embedded player pane and its placeholder |
| `isPlaybackDropTargeted` | `Views/ContentView.swift` | Drop highlight for the embedded pane |
| `FullScreenVideoView` | `Views/FullScreenVideoView.swift` | File retained as an empty translation unit (pbxproj); see note in file |
| `enterFullScreen()` / `exitFullScreen()` | `Views/ContentView+Helpers.swift` | Main-window video-fullscreen mode |
| `minVideoWidth`, `defaultVideoWidth`, `defaultPanelWidth` | `Utilities/LayoutConstants.swift` | Zero call sites after the split was removed |

#### Migration Note
The main window's fullscreen observers were not filtered by window, so with a
second window present the player entering fullscreen would have flipped the
main window into video mode. Removing the custom fullscreen path was required,
not optional.

---

### Cue Sheet / Cue Detection

**Status**: Removed
**Added**: 2026-01-19
**Removed**: 2026-02-15

#### Description
Cue sheet management with auto-detection from audio silence analysis. Included cue lane in timeline, cue panel, and detection UI.

#### Files (Deleted)

| Type | Path | Purpose |
|------|------|---------|
| Model | `Models/CueSheet/Cue.swift` | Cue data |
| Model | `Models/CueSheet/CueSheet.swift` | Cue container |
| Model | `Models/CueSheet/DetectedCue.swift` | Detection result |
| Service | `Managers/SilenceDetectionService.swift` | Audio analysis |
| View | `Views/CueSheet/CuesPanelView.swift` | Accordion panel |
| View | `Views/CueSheet/CuesWindowView.swift` | Popout window |
| View | `Views/CueSheet/DetectedCueListView.swift` | Import dialog |
| View | `Views/Timeline/CueLaneView.swift` | Timeline lane |
| Utility | `Utilities/LayoutConstants.swift` | `CueLaneLayout`, `CuesPanelLayout` |

#### State Properties (Removed)

| File | Property | Type |
|------|----------|------|
| `ContentView.swift` | `@State showCuesWindow` | `Bool` |
| `MultiTrackTimelineView.swift` | `@State showDetectedCuesSheet` | `Bool` |
| `MultiTrackTimelineView.swift` | `@State detectedCues` | `[DetectedCue]` |
| `MultiTrackTimelineView.swift` | `@State selectedCueId` | `UUID?` |

#### Integration Points (Removed)

| File | Location | Integration Type |
|------|----------|------------------|
| `Timeline.swift` | `cueSheets` property | Model storage |
| `TimelineManager.swift` | `MARK: - Cue Operations` | CRUD methods |
| `ContentView.swift` | Lower panels area | CuesPanelView |
| `ContentView+Helpers.swift` | `openCuesWindow()` | Window creation |
| `MultiTrackTimelineView.swift` | Tracks section | CueLaneView |
| `VitalControlsBar.swift` | Step backward | Cue position check |
| `AudioLaneView.swift` | `onDetectCues` callback | Detection trigger |
| `AudioClipView.swift` | Context menu | "Detect Cues" button |

---

## Maintenance

### When Adding a Feature

1. Create feature entry using the template above
2. List ALL files created
3. Document ALL state properties added
4. Document ALL integration points (where existing code was modified)
5. List dependencies and dependents
6. Add to "Active Features" section

### When Removing a Feature

1. Move entry to "Removed Features" section
2. Update status and removal date
3. Use the file list and integration points as removal checklist
4. Verify clean build after removal

### Periodic Audit

Periodically verify:
- All active features have complete entries
- File paths are accurate
- Integration points are current
