# Projector v1.0 Retrospective

> **Purpose**: Complete handoff document for any LLM or developer picking up v2.0
> **Date**: 2026-01-10
> **Status**: v1.0 SHIPPED

---

## Table of Contents

1. [What Is Projector?](#what-is-projector)
2. [Architecture Overview](#architecture-overview)
3. [Technology Stack](#technology-stack)
4. [The Agent System](#the-agent-system)
5. [Critical Lessons Learned](#critical-lessons-learned)
6. [Common Mistakes We Made](#common-mistakes-we-made)
7. [Golden Patterns (Use These)](#golden-patterns-use-these)
8. [Anti-Patterns (Avoid These)](#anti-patterns-avoid-these)
9. [The Most Painful Bugs](#the-most-painful-bugs)
10. [What Works Well](#what-works-well)
11. [What's Left for v2.0](#whats-left-for-v20)
12. [File Structure Guide](#file-structure-guide)
13. [Quick Start for New Contributors](#quick-start-for-new-contributors)

---

## What Is Projector?

Projector is a **professional macOS video playback application** designed for broadcast and post-production workflows. Think of it as a video player that can:

- **Play multi-reel video projects** with frame-accurate seeking
- **Sync to external timecode** via MTC (MIDI Time Code)
- **Respond to transport commands** via MMC (MIDI Machine Control)
- **Route audio to multi-channel interfaces** (6+ channel output support)
- **Display embedded timecode overlays**
- **Show waveforms and thumbnails** in a DAW-style timeline

### Target Users
- Video editors syncing playback to Pro Tools/Logic
- Post-production facilities needing MTC slave playback
- Anyone needing pro-grade video playback with external sync

### Business Model
- Licensed commercial software (see `LicenseManager.swift`)

---

## Architecture Overview

### The Two-Layer Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PRESENTATION LAYER                                    │
│                       (Views, ViewModels)                                   │
│                                                                              │
│   SwiftUI Views  ──▶  ViewModels (@MainActor)  ──▶  Consumes THE CONTRACT   │
│                                                                              │
│   ALLOWED: SwiftUI, AppKit, Combine                                         │
│   FORBIDDEN: CoreMIDI, CoreAudio, AVFoundation (except AVPlayerLayer)       │
├──────────────────────────────────────────────────────────────────────────────┤
│                           THE CONTRACT                                       │
│   ╔═══════════════════════════════════════════════════════════════════════╗ │
│   ║  Protocols + AsyncStreams + Sendable Types                            ║ │
│   ║  Location: Projector/Contracts/                                       ║ │
│   ╚═══════════════════════════════════════════════════════════════════════╝ │
├──────────────────────────────────────────────────────────────────────────────┤
│                           LOGIC LAYER                                        │
│                      (Managers, Actors)                                     │
│                                                                              │
│   Swift Actors  ◀──  CoreMIDI/CoreAudio  ◀──  Real-time Callbacks          │
│                                                                              │
│   ALLOWED: Foundation, CoreMIDI, CoreAudio, AVFoundation                    │
│   FORBIDDEN: SwiftUI                                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why This Matters
- **MIDI callbacks fire every 4ms** - if you process them on @MainActor, the UI stutters
- **Audio routing is complex** - keeping it isolated prevents UI bugs from breaking audio
- **Testing is easier** - you can mock the protocol without running real MIDI

### The Contract Pattern (CRITICAL)

Every cross-layer communication MUST go through a protocol:

```swift
// 1. THE CONTRACT (in Contracts/)
public protocol MIDISyncServiceProtocol: Sendable {
    var syncStateStream: AsyncStream<MIDISyncState> { get }
    func selectInput(_ name: String?) async
}

// 2. THE IMPLEMENTATION (in Managers/)
actor MIDISyncActor: MIDISyncServiceProtocol { ... }

// 3. THE CONSUMER (in ViewModels/)
@MainActor
class MIDISyncViewModel: ObservableObject {
    private let service: MIDISyncServiceProtocol
}
```

---

## Technology Stack

### Core Dependencies

| Library | Purpose | Critical Notes |
|---------|---------|----------------|
| **MIDIKit** | MTC/MMC receive | Callbacks fire on unknown threads - wrap in `Task { await actor.method() }` |
| **swift-timecode** | Timecode math | Used for frame-accurate calculations |
| **DSWaveformImage** | Waveform rendering | **MUST use `.frame()` on WaveformView** - see Anti-Patterns |
| **AVFoundation** | Video/audio playback | Multi-channel requires `kAudioChannelLayoutTag_Unknown \| count` |
| **CoreAudio** | AUMatrixMixer routing | Parameters MUST be set AFTER `engine.start()` |

### macOS Requirements
- macOS 14+ (uses modern SwiftUI features)
- Sandboxed with security-scoped bookmarks for file access

### Document Format
- `.projector` package format (folder with Contents.json + media references)
- Uses `NSFileWrapper` for atomic saves

---

## The Agent System

We built a multi-agent workflow to maintain quality. These are prompt files in `.claude/agents/`:

### The Workflow Chain

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PRO-GRADE WORKFLOW                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. PLAN (arch-architect)                                                   │
│     └─ Technical design, thread-safety strategy, THE CONTRACT               │
│                              ↓                                               │
│  2. SCOPE CHECK (scope-guard)                                               │
│     └─ Strip feature creep, verify request matches plan                     │
│                              ↓                                               │
│  3. EXECUTE (backend-logic OR ui-specialist)                                │
│     └─ Logic: MIDI/Audio/AVFoundation (no SwiftUI)                         │
│     └─ UI: SwiftUI/AppKit (no CoreMIDI)                                    │
│                              ↓                                               │
│  4. AUDIT (qa-auditor)                                                      │
│     └─ DocC coverage, edge cases, thread safety, standards                  │
│                              ↓                                               │
│  5. ROADMAP & PUSH (the-lead)                                              │
│     └─ Update PROJECT_ROADMAP.md, git commit (after QA approval)           │
│                              ↓                                               │
│  6. LEARN (the-librarian)                                                   │
│     └─ Capture Golden Patterns in KNOWLEDGE_BASE.md                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Agent Roles

| Agent | File | Purpose |
|-------|------|---------|
| **arch-architect** | `arch-architect.md` | Designs contracts and thread-safety strategies |
| **scope-guard** | `scope-guard.md` | Prevents feature creep, keeps changes focused |
| **backend-logic** | `backend-logic.md` | Implements MIDI, audio, transport logic |
| **ui-specialist** | `ui-specialist.md` | Implements SwiftUI views following HIG |
| **qa-auditor** | `qa-auditor.md` | Audits all code before commit |
| **the-lead** | `the-lead.md` | Maintains roadmap, does git operations |
| **the-librarian** | `the-librarian.md` | Documents patterns in KNOWLEDGE_BASE.md |
| **coroner** | `coroner.md` | Post-mortem analysis when bugs slip through |
| **surgeon** | `surgeon.md` | Implements fixes from coroner reports |

### When to Invoke the Coroner

**MANDATORY**: Invoke `coroner.md` when:
- A "fix" breaks something else
- A feature that was working stops working
- User shares a screenshot showing broken UI
- Any regression occurs

The coroner performs forensic analysis before any fix is attempted.

---

## Critical Lessons Learned

### 1. BUILD SUCCESS ≠ FEATURE WORKS

This was our most expensive lesson. We would:
1. Make a code change
2. Build succeeds
3. Declare it "fixed"
4. Move on to documentation

**Reality**: The build proves syntax, not functionality. UI changes require visual verification.

**New Protocol**:
```
1. Make change
2. Build
3. ASK USER TO RUN AND VERIFY VISUALLY
4. User confirms → Document
5. User reports issue → Go back to step 1
```

### 2. Never Use .id() on Async-Loading Views

```swift
// ❌ DESTROYS the view on every change - async loading never completes
WaveformView(audioURL: url, configuration: config)
    .id(clipWidth)

// ✅ CORRECT - view updates without destruction
WaveformView(audioURL: url, configuration: config)
    .frame(width: clipWidth, height: waveformHeight)
```

`.id()` is SwiftUI's "nuclear option" - it destroys and recreates the view entirely. For views that load data asynchronously, this means the loading restarts every time.

### 3. Read 3rd-Party Library Docs FIRST

Before using ANY external library component:
1. Check if it needs explicit `.frame()`
2. Check if it loads data asynchronously
3. Look at the library's example code
4. Test with documented patterns first

We broke waveforms THREE TIMES because we assumed general SwiftUI knowledge applied to DSWaveformImage.

### 4. AUConverter's channelMap is BROKEN

Apple's `AVAudioUnitConverter` claims to support channel remapping via `channelMap` property. **It doesn't work.** The property appears to be non-functional.

**Solution**: Use `kAudioUnitSubType_MatrixMixer` with crosspoint gains:
```swift
let crosspoint = UInt32((inputChannel << 16) | outputChannel)
AudioUnitSetParameter(audioUnit, kMatrixMixerParam_Volume,
                      kAudioUnitScope_Global, crosspoint, 1.0, 0)
```

### 5. MatrixMixer Parameters MUST Be Set AFTER engine.start()

```swift
// ❌ WRONG - Silent output
engine.attach(matrixMixer)
AudioUnitSetParameter(audioUnit, ...) // Silently ignored!
try engine.start()

// ✅ CORRECT
engine.attach(matrixMixer)
try engine.start()
AudioUnitSetParameter(audioUnit, ...) // Now it works
```

### 6. Guard Conditions Should Check Operational State, Not Metadata

```swift
// ❌ WRONG - Optional naming feature blocks core functionality
guard lane.outputMappingId != nil else { return nil }

// ✅ CORRECT - Check actual routing parameters
let needsCustomRouting = lane.outputChannelOffset != 0
    || lane.outputChannelCount != 2
guard needsCustomRouting else { return nil }
```

When convenience features (presets, names) are added alongside core functionality, guards should check the operational parameters, not the optional metadata.

### 7. onTapGesture Kills Trackpad Scroll Performance

Adding `.onTapGesture` to items inside a `ScrollView` introduces 150ms+ delay on trackpad scrolling. The system waits to disambiguate tap vs scroll.

**Solution**: Use `Button` instead, or `.simultaneousGesture(TapGesture(count: 2))` for double-tap.

---

## Common Mistakes We Made

### Mistake 1: @MainActor for MIDI Processing

**What We Did**: Put MIDIManager on @MainActor because it was "easy".

**Why It Broke**: MTC quarter-frames arrive every 4ms. Processing on main thread = UI jitter.

**The Fix**: Created `MIDISyncActor` (dedicated actor) with `AsyncStream` for UI updates.

### Mistake 2: Monolithic ContentView

**What We Did**: Let ContentView grow to 1,696 lines.

**Why It Broke**: Unmaintainable, hard to test, mixed concerns.

**The Fix**: Extracted:
- `VitalControlsBar.swift` (transport, timecode, zoom)
- `TimelineAccordionView.swift` (collapsible panel)
- `WindowTitleConfigurator.swift` (custom title)
- `TimelineViewModel.swift` (timeline state)

Result: 1,696 → 1,103 lines (35% reduction)

### Mistake 3: Magic Numbers Everywhere

**What We Did**: Hardcoded values like `120`, `60`, `48` throughout views.

**Why It Broke**: Inconsistent layouts, hard to maintain, no documentation.

**The Fix**: Created `LayoutConstants.swift` with domain-specific enums:
```swift
enum TimelineLayout {
    static let headerWidth: CGFloat = 120
    static let audioLaneHeight: CGFloat = 60
}
```

### Mistake 4: AVAudioFormat for Multi-Channel

**What We Did**: Used `AVAudioFormat(standardFormatWithSampleRate:channels:)` for 6+ channels.

**Why It Broke**: Returns `nil` for channel counts > 2.

**The Fix**: Use explicit channel layout:
```swift
var layout = AudioChannelLayout()
layout.mChannelLayoutTag = kAudioChannelLayoutTag_Unknown | channelCount
let channelLayout = AVAudioChannelLayout(layout: &layout)
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: channelLayout)
```

### Mistake 5: Trusting Node Format for Channel Count

**What We Did**: Used `engine.outputNode.inputFormat(forBus: 0).channelCount` to determine available channels.

**Why It Broke**: Reports 2 even when connected to a 6-channel interface.

**The Fix**: Query the device directly via CoreAudio's `kAudioDevicePropertyStreamConfiguration`.

---

## Golden Patterns (Use These)

These are proven patterns from `KNOWLEDGE_BASE.md`:

### GP-001: Actor Isolation for MIDI State
All MIDI processing in Swift Actors, not @MainActor classes.

### GP-003: Avoid Single-Tap Gestures in Scroll Content
Use `Button` instead of `.onTapGesture` inside ScrollViews.

### GP-004: THE CONTRACT Pattern
Protocol → Actor Implementation → ViewModel Consumer

### GP-005: AsyncStream for High-Frequency Updates
MTC arrives 120+ times/second. Use AsyncStream with backpressure.

### GP-006: MIDIKit Callback Wrapping
```swift
mtcReceiver = MTC.Receiver { [weak self] timecode, _, state in
    guard let self else { return }
    Task { await self.handleMTCUpdate(timecode: timecode, state: state) }
}
```

### GP-011: Accordion Headers as Buttons
```swift
Button(action: { isExpanded.toggle() }) {
    HStack { /* header content */ }
        .contentShape(Rectangle())
}
.buttonStyle(.plain)
```

### GP-012: Centralized Layout Constants
All layout values in `LayoutConstants.swift` with domain-specific enums.

### GP-013: Async Loading Guard Pattern
```swift
private var loadingIds: Set<UUID> = []

func loadAsync(_ item: Item) {
    guard !loadingIds.contains(item.id) else { return }
    loadingIds.insert(item.id)
    defer { loadingIds.remove(item.id) }
    // ... async work
}
```

### GP-015: AUMatrixMixer Channel Routing
Use crosspoint gains for M-to-N channel routing. Set parameters AFTER `engine.start()`.

---

## Anti-Patterns (Avoid These)

### AP-001: @MainActor for MIDI Processing
**NEVER** process MIDI callbacks on @MainActor.

### AP-002: Force Unwrapping in Production
**NEVER** use `!` - always handle optionals properly.

### AP-003: Business Logic in SwiftUI Views
**NEVER** sort, filter, or compute in view bodies.

### AP-004: Magic Numbers
**ALWAYS** use named constants from `LayoutConstants.swift`.

### AP-005: Using .id() on Async-Loading Views
**NEVER** use `.id()` on views that load data asynchronously.

### AP-006: Overlay-Only Buttons for Accordion Headers
**NEVER** use overlay buttons for accordion headers - they lose hit-testing in ScrollViews.

### AP-008: Guard Conditions Coupling Unrelated Features
**NEVER** let optional metadata block core functionality.

---

## The Most Painful Bugs

### 1. Waveform Rendering Failure (3 cascading fixes)

**Symptom**: Waveforms showed as solid blocks after "zoom fix".

**Root Cause Chain**:
1. Added `.id(clipWidth)` → Destroyed view mid-async-load
2. Removed `.id()`, view still blank → Didn't know WaveformView needs explicit `.frame()`
3. Added wrong zoom min (0.1) → Made clips microscopic

**Lesson**: Each "quick fix" made it worse. Should have invoked Coroner after first failure.

### 2. Multi-Channel Audio Silent on Outputs 3-6

**Symptom**: Audio only played on outputs 1-2, even with 6-channel interface.

**Root Cause Chain**:
1. AVAudioFormat created with 2 channels → Limited bus capacity
2. AUConverter `channelMap` didn't work → Non-functional API
3. MatrixMixer parameters set before `engine.start()` → Silently ignored
4. Guard checked `outputMappingId` instead of `outputChannelOffset` → Blocked routing

**Lesson**: Multi-channel audio in CoreAudio is full of undocumented gotchas.

### 3. Trackpad Scroll Latency

**Symptom**: 150ms+ delay when scrolling timeline on trackpad.

**Root Cause**: 11 `.onTapGesture` modifiers on views inside ScrollView.

**Fix**: Replaced all with Button + simultaneousGesture pattern.

---

## What Works Well

### Features at 95%+
- **Core Playback**: Multi-reel video, frame-accurate seeking, transport controls
- **MTC/MMC Sync**: Receives timecode, follows external source, handles dropout
- **Audio Routing**: Full 6-channel output support with AUMatrixMixer
- **Timeline UI**: Waveforms, thumbnails, zoom, drag-and-drop

### Architecture Wins
- **MIDISyncActor**: Thread-safe MIDI handling with clean UI separation
- **Contract Pattern**: Testable, maintainable layer separation
- **LayoutConstants**: Consistent, documented layout values
- **Agent Workflow**: Catches issues before they ship

### Documentation
- **KNOWLEDGE_BASE.md**: 17 golden patterns, 8 anti-patterns
- **PROJECT_ROADMAP.md**: Complete progress history
- **Agent definitions**: Clear responsibilities and protocols

---

## What's Left for v2.0

### High Priority
| Feature | Status | Notes |
|---------|--------|-------|
| TransportServiceProtocol | Not Started | Define contract for playback control |
| ContentView full decomposition | Partial | Still 1103 lines, target <500 |
| Drift compensation UI | Not Started | Show sync quality to user |

### Medium Priority
| Feature | Status | Notes |
|---------|--------|-------|
| 100% DocC coverage | 70% | WaveformCache, ProjectMediaLibrary need docs |
| Performance optimization | Partial | Large projects still slow |
| User documentation | Not Started | In-app help, user guide |

### Low Priority / Nice to Have
| Feature | Status | Notes |
|---------|--------|-------|
| Audio metering | Not Started | VU meters per lane |
| macOS Tahoe Liquid Glass UI | Not Started | Modern visual effects |
| Document icon in Finder | Blocked | Icon configured but not appearing |

---

## File Structure Guide

```
Projector/
├── ProjectorApp.swift           # App entry point
├── Contracts/                   # THE CONTRACT - protocol definitions
│   ├── MIDISyncServiceProtocol.swift
│   ├── TransportServiceProtocol.swift
│   └── MediaOptimizationServiceProtocol.swift
├── Managers/                    # LOGIC LAYER - actors and services
│   ├── MIDISyncActor.swift      # Thread-safe MIDI handling (778 lines)
│   ├── PlaybackEngine.swift     # AVFoundation + CoreAudio
│   ├── AudioOutputManager.swift # Audio device management
│   ├── TimelineManager.swift    # Timeline state
│   ├── WaveformCache.swift      # Async waveform loading
│   └── ...
├── ViewModels/                  # UI state management
│   ├── MIDISyncViewModel.swift  # MIDI state for UI
│   ├── TimelineViewModel.swift  # Timeline UI state
│   └── OptimizationViewModel.swift
├── Views/                       # PRESENTATION LAYER - SwiftUI
│   ├── ContentView.swift        # Main view (1103 lines)
│   ├── VitalControlsBar.swift   # Transport + timecode + zoom
│   ├── Timeline/                # Timeline components
│   │   ├── MultiTrackTimelineView.swift
│   │   ├── AudioClipView.swift
│   │   ├── WaveformShape.swift
│   │   └── ...
│   └── FileManager/             # Media library UI
├── Models/                      # Data structures
│   ├── Timeline/                # Timeline, AudioLane, AudioClip, etc.
│   ├── ProjectDocument.swift    # Document format
│   └── AppSettings.swift        # User preferences
├── Utilities/
│   ├── LayoutConstants.swift    # Centralized layout values
│   └── DebugLog.swift           # Logging utilities
└── Resources/                   # Assets, icons

.claude/
├── CLAUDE.md                    # Project standards
└── agents/                      # Agent definitions
    ├── arch-architect.md
    ├── backend-logic.md
    ├── ui-specialist.md
    ├── qa-auditor.md
    ├── scope-guard.md
    ├── the-lead.md
    ├── the-librarian.md
    ├── coroner.md
    └── surgeon.md
```

---

## Quick Start for New Contributors

### Before Writing Any Code

1. **Read CLAUDE.md** - Contains all project standards
2. **Read KNOWLEDGE_BASE.md** - Contains proven patterns
3. **Check PROJECT_ROADMAP.md** - Understand current status

### The Workflow (Mandatory)

1. **Plan first** (invoke arch-architect for non-trivial changes)
2. **Check scope** (invoke scope-guard to prevent creep)
3. **Execute** (backend-logic OR ui-specialist, never both)
4. **Audit** (qa-auditor MUST approve before commit)
5. **Update roadmap** (the-lead updates PROJECT_ROADMAP.md)
6. **Document** (the-librarian captures patterns)

### Key Rules

1. **Never guess APIs** - Read docs or WebSearch first
2. **Never process MIDI on @MainActor**
3. **Never use `.onTapGesture` in ScrollView**
4. **Never use `.id()` on async-loading views**
5. **Always use LayoutConstants for sizes**
6. **Always get QA approval before commit**
7. **Invoke Coroner for ANY regression**

### When Something Breaks

1. **STOP** - Don't attempt quick fixes
2. **Invoke Coroner** - Perform forensic analysis
3. **Understand first** - What exactly changed and why it broke
4. **Fix with confidence** - Only after understanding

### Testing Changes

**BUILD SUCCESS ≠ FEATURE WORKS**

For UI changes:
1. Build the project
2. **Ask user to run and verify visually**
3. Wait for confirmation before documenting

---

## Final Notes

v1.0 took significant iteration to get right. The agent system and documented patterns exist because we made every mistake in this document at least once.

**The most valuable assets for v2.0 are**:
1. `KNOWLEDGE_BASE.md` - 17 golden patterns
2. `PROJECT_ROADMAP.md` - Complete history
3. `coroner.md` - How to debug when things break
4. This retrospective - The meta-lessons

Good luck with v2.0. Follow the workflow, read the docs, and invoke the Coroner when things go wrong.

---

*Generated from Projector v1.0 development (2026-01-02 to 2026-01-10)*
