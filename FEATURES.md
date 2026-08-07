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
**Updated**: 2026-03-31 (drift compensation UI)

#### Description
MIDI Time Code (MTC) and MIDI Machine Control (MMC) synchronization for external device control. Runs on dedicated actor for thread safety. Includes live drift monitoring, configurable sync thresholds, and auto-play/pause settings.

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

**Status**: Active
**Added**: 2026-02-XX

#### Description
OCR-based timecode detection from video frames using Vision framework.

#### Files

| Type | Path | Purpose |
|------|------|---------|
| Manager | `Managers/TimecodeOCRManager.swift` | Vision-based OCR |

#### Integration Points

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
