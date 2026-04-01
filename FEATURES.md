# Projector - Feature Registry

> **Purpose**: Document all features with their associated files, dependencies, and integration points.
> **Owner**: the-lead agent (updates required after every feature implementation)
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
- Depended by: Multi-Track Timeline

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

## Removed Features

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

The `qa-auditor` agent should periodically verify:
- All active features have complete entries
- File paths are accurate
- Integration points are current
