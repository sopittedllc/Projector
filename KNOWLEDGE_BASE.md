# Projector Knowledge Base

> **Last Updated**: 2026-01-02
> **Maintainer**: The Librarian Agent
>
> This document captures institutional knowledge extracted from the Projector codebase.
> All patterns and anti-patterns are evidence-based with citations to source files.

---

## Table of Contents

1. [Golden Patterns](#golden-patterns)
2. [Prohibited Anti-Patterns](#prohibited-anti-patterns)
3. [MTC/MMC Sync Standards](#mtcmmc-sync-standards)
4. [Lessons Learned](#lessons-learned)
5. [Glossary](#glossary)

---

## Golden Patterns

### GP-001: Actor Isolation for MIDI State
**Added**: 2026-01-02
**Source**: Architectural standard (see CLAUDE.md)
**Category**: Threading

#### Problem
MIDI callbacks fire at high frequencies and can cause race conditions when modifying shared state. Processing on the main thread causes UI jitter.

#### Solution
```swift
actor MIDITransportActor {
    private var isPlaying = false
    private var currentTimecode: Timecode?

    func handleMTCQuarterFrame(_ qf: MTC.QuarterFrame) async {
        // State mutations are automatically thread-safe
    }
}
```

#### Why It Works
Swift Actors provide compile-time guarantees for thread safety. The actor's executor serializes all access to internal state, eliminating data races without explicit locks.

#### Related Files
- All files in `Projector/Managers/` should follow this pattern

---

### GP-002: DrawingGroup for Waveform Rendering
**Added**: 2026-01-02
**Source**: Commit `9249780` - DSWaveformImage integration
**Category**: UI Performance

#### Problem
Complex SwiftUI graphics (waveforms, thumbnails) cause excessive CPU usage and frame drops during scrolling.

#### Solution
```swift
WaveformView(samples: waveformData)
    .drawingGroup() // Rasterizes to Metal layer
```

#### Why It Works
`.drawingGroup()` composites the view into a single Metal texture, reducing per-frame SwiftUI diffing overhead.

#### Related Files
- Waveform rendering views
- Timeline thumbnail views

---

### GP-003: Avoid Single-Tap Gestures in Scroll Content
**Added**: 2026-01-02
**Source**: Known macOS SwiftUI issue (see CLAUDE.md)
**Category**: UI Performance

#### Problem
Adding `.onTapGesture` to items inside a `ScrollView` introduces a 150ms+ delay on trackpad scroll initiation as the system waits to disambiguate tap vs scroll.

#### Solution
- Use `Button` for clickable elements (handles disambiguation properly)
- Use `.simultaneousGesture` if gesture is absolutely required
- Consider AppKit `NSView` via `NSViewRepresentable` for complex interactions

#### Why It Works
`Button` integrates with the system's gesture recognizer priorities correctly. Direct tap gestures compete with scroll gestures.

---

### GP-004: THE CONTRACT Pattern for Cross-Layer Communication
**Added**: 2026-01-02
**Source**: `Projector/Contracts/MIDISyncServiceProtocol.swift`
**Category**: Architecture

#### Problem
UI and Logic layers become tightly coupled when views directly access MIDI managers, making testing difficult and violating layer separation.

#### Solution
```swift
// 1. THE CONTRACT (defined by arch-architect)
public protocol MIDISyncServiceProtocol: Sendable {
    var syncStateStream: AsyncStream<MIDISyncState> { get }
    func selectInput(_ name: String?) async
}

// 2. THE IMPLEMENTATION (by backend-logic)
actor MIDISyncActor: MIDISyncServiceProtocol {
    var syncStateStream: AsyncStream<MIDISyncState> { ... }
    func selectInput(_ name: String?) async { ... }
}

// 3. THE CONSUMER (by ui-specialist)
@MainActor
class MIDISyncViewModel: ObservableObject {
    private let service: MIDISyncServiceProtocol  // Only sees the contract
}
```

#### Why It Works
- Protocol boundary enforces layer separation at compile time
- UI can be tested with mock implementations
- Logic layer can evolve without UI changes
- `Sendable` requirement catches thread-safety issues at compile time

#### When to Use
Any time UI needs to interact with Logic layer (MIDI, audio, transport, timeline).

---

### GP-005: AsyncStream for High-Frequency Actor-to-UI Updates
**Added**: 2026-01-02
**Source**: `Projector/Managers/MIDISyncActor.swift`
**Category**: Threading

#### Problem
MTC quarter-frames arrive every ~4ms (120+ per second at 30fps). Direct @Published updates would flood the main thread.

#### Solution
```swift
actor MIDISyncActor {
    private var continuation: AsyncStream<MIDISyncState>.Continuation?

    var syncStateStream: AsyncStream<MIDISyncState> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { _ in
                Task { await self.handleStreamTermination() }
            }
        }
    }

    private func emitState() {
        continuation?.yield(currentState)
    }
}

// Consumer (ViewModel) - controls update rate
@MainActor
class MIDISyncViewModel: ObservableObject {
    func startObserving() {
        Task {
            for await state in service.syncStateStream {
                self.updateUI(with: state)  // UI updates at its own pace
            }
        }
    }
}
```

#### Why It Works
- Actor processes MIDI at full speed without blocking
- AsyncStream provides backpressure - UI only processes what it can handle
- `for await` loop runs on @MainActor, ensuring thread-safe UI updates
- Stream termination is handled cleanly via `onTermination`

#### When to Use
Any high-frequency data flow from actors to UI (timecode, meters, waveform updates).

---

### GP-006: MIDIKit Callback Wrapping for Thread Safety
**Added**: 2026-01-02
**Source**: `Projector/Managers/MIDISyncActor.swift:311`
**Category**: Threading

#### Problem
MIDIKit callbacks execute on unknown threads, but actor methods require isolation.

#### Solution
```swift
// Create receiver with callback that bridges to actor
mtcReceiver = MTC.Receiver(
    name: "Projector MTC",
    initialLocalFrameRate: localFrameRate,
    syncPolicy: .init(lockFrames: 8, dropOutFrames: 10)
) { [weak self] timecode, _, state in
    guard let self else { return }
    Task {
        await self.handleMTCUpdate(timecode: timecode, state: state)
    }
}
```

#### Why It Works
- `Task { await ... }` bridges from sync callback to async actor context
- `[weak self]` prevents retain cycles during object teardown
- Actor's executor serializes all updates, eliminating races
- No locks needed - Swift concurrency handles synchronization

#### When to Use
Any external library callback that needs to update actor state (MIDI, audio, network).

---

## Prohibited Anti-Patterns

### AP-001: @MainActor for MIDI Processing
**Added**: 2026-01-02
**Discovered**: Architectural review
**Severity**: Critical

#### The Mistake
```swift
// ❌ PROHIBITED
@MainActor
class MIDIManager: ObservableObject {
    func handleMTCQuarterFrame(_ qf: MTC.QuarterFrame) {
        // Blocks UI during MIDI processing
    }
}
```

#### Why It's Wrong
MTC quarter-frames arrive every 4.17ms at 30fps. Processing on the main actor blocks SwiftUI rendering, causing visible UI stutters, especially during timecode chase.

#### The Fix
Use a dedicated actor for MIDI state, with @MainActor only for UI-bound properties:
```swift
actor MIDITransportActor {
    func handleMTCQuarterFrame(_ qf: MTC.QuarterFrame) async { }
}

@MainActor
class MIDIViewModel: ObservableObject {
    @Published var displayTimecode: String = ""
    private let transport = MIDITransportActor()
}
```

---

### AP-002: Force Unwrapping in Production Code
**Added**: 2026-01-02
**Discovered**: QA Auditor standards
**Severity**: High

#### The Mistake
```swift
// ❌ PROHIBITED
let url = URL(string: path)!
let data = try! Data(contentsOf: url)
```

#### Why It's Wrong
Force unwraps crash the application. In a professional media application, crashes during playback or editing destroy user trust.

#### The Fix
```swift
// ✅ CORRECT
guard let url = URL(string: path) else {
    throw ProjectorError.invalidPath(path)
}
let data = try Data(contentsOf: url)
```

---

### AP-003: Business Logic in SwiftUI Views
**Added**: 2026-01-02
**Discovered**: Architectural review
**Severity**: Medium

#### The Mistake
```swift
// ❌ PROHIBITED
struct TimelineView: View {
    var body: some View {
        // Sorting in view body - recalculated every render
        ForEach(clips.sorted { $0.startTime < $1.startTime }) { clip in
            ClipView(clip: clip)
        }
    }
}
```

#### Why It's Wrong
SwiftUI view bodies can be called multiple times per second. Computation in the body causes frame drops and makes the code harder to test.

#### The Fix
Move logic to ViewModel:
```swift
@MainActor
class TimelineViewModel: ObservableObject {
    @Published private(set) var sortedClips: [Clip] = []

    func updateClips(_ clips: [Clip]) {
        sortedClips = clips.sorted { $0.startTime < $1.startTime }
    }
}
```

---

### AP-004: Magic Numbers
**Added**: 2026-01-02
**Discovered**: Architectural standards
**Severity**: Medium

#### The Mistake
```swift
// ❌ PROHIBITED
let height = 120.0  // What is this?
let frameRate = 29.97  // Where did this come from?
```

#### Why It's Wrong
Magic numbers make code incomprehensible and error-prone. They hide intent and make refactoring dangerous.

#### The Fix
```swift
// ✅ CORRECT
enum LayoutConstants {
    static let transportBarHeight: CGFloat = 120
}

enum FrameRate {
    static let ntscDropFrame: Double = 29.97
}
```

---

## MTC/MMC Sync Standards

### MTC-001: Frame Rate Encoding
**Added**: 2026-01-02
**Spec Reference**: MIDI 1.0 Specification, MTC section

#### Requirement
MTC encodes frame rate in the high nibble of the hours byte in full-frame messages and quarter-frame message 7.

#### Implementation
| Frame Rate | Type Code | Binary | Notes |
|------------|-----------|--------|-------|
| 24 fps     | 0         | 00     | Film standard |
| 25 fps     | 1         | 01     | PAL/SECAM |
| 29.97 df   | 2         | 10     | NTSC drop-frame |
| 30 fps     | 3         | 11     | NTSC non-drop |

```swift
enum MTCFrameRateType: UInt8 {
    case fps24 = 0x00
    case fps25 = 0x01
    case fps29_97df = 0x02
    case fps30 = 0x03
}
```

#### Edge Cases
- 29.97 non-drop is not directly supported by MTC; use 30fps type
- Some devices report 30fps for 29.97 content - verify externally
- MIDIKit handles this via `MTC.FrameRate` enum

---

### MTC-002: Quarter-Frame Message Sequence
**Added**: 2026-01-02
**Spec Reference**: MIDI 1.0 Specification, MTC Quarter-Frame section

#### Requirement
Quarter-frame messages transmit timecode across 8 messages (2 per frame). The complete sequence:

| Piece | Data Nibble | Content |
|-------|-------------|---------|
| 0     | 0nnn        | Frames low nibble |
| 1     | 0nnn        | Frames high nibble |
| 2     | 0nnn        | Seconds low nibble |
| 3     | 0nnn        | Seconds high nibble |
| 4     | 0nnn        | Minutes low nibble |
| 5     | 0nnn        | Minutes high nibble |
| 6     | 0nnn        | Hours low nibble |
| 7     | 0rrh        | Hours high nibble + frame rate |

#### Implementation
Use MIDIKit's `MTC.Receiver` which handles reassembly:
```swift
let mtcReceiver = MTC.Receiver { timecode, _, _ in
    // Full timecode received after 8 quarter-frames
}
```

#### Edge Cases
- Direction detection: Forward play sends pieces 0-7, reverse sends 7-0
- Lock time: Takes 2 frames minimum to establish valid timecode
- Dropout handling: If pieces are missed, timecode should be considered invalid until next full sequence

---

### MMC-001: Device ID Handling
**Added**: 2026-01-02
**Spec Reference**: MIDI 1.0 Specification, MMC section

#### Requirement
MMC commands include a device ID byte. Special handling required:

| ID | Meaning |
|----|---------|
| 0x7F | All devices (broadcast) |
| 0x00-0x7E | Specific device |

#### Implementation
```swift
func sendMMCCommand(_ command: MMC.Command, to deviceID: UInt8 = 0x7F) {
    // Default to broadcast for maximum compatibility
}
```

#### Edge Cases
- Some devices only respond to their specific ID, not 0x7F
- Store per-device ID preferences when discovered
- Pro Tools uses device ID 0x00 by default

---

### MMC-002: Transport Command Codes
**Added**: 2026-01-02
**Spec Reference**: MIDI 1.0 Specification, MMC Commands

#### Requirement
Standard MMC transport commands that Projector must respond to:

| Command | Code | Action |
|---------|------|--------|
| Stop | 0x01 | Stop playback |
| Play | 0x02 | Start forward playback |
| Deferred Play | 0x03 | Play after locate completes |
| Fast Forward | 0x04 | Shuttle forward |
| Rewind | 0x05 | Shuttle backward |
| Record Strobe | 0x06 | Toggle record (not used in Projector) |
| Record Exit | 0x07 | Exit record mode |
| Pause | 0x09 | Pause playback |
| Locate | 0x44 | Go to specific timecode |

#### Implementation
```swift
func handleMMC(_ command: MMCCommand) async {
    switch command {
    case .stop: await transport.stop()
    case .play: await transport.play()
    case .pause: await transport.pause()
    case .locate(let tc): await transport.seek(to: tc)
    default: break // Ignore unsupported commands
    }
}
```

---

### MTC-003: Sync State Machine
**Added**: 2026-01-02
**Spec Reference**: Best practices from professional video applications

#### Requirement
MTC receivers must handle various sync states gracefully:

```
┌─────────┐     QF received      ┌──────────┐
│  IDLE   │ ──────────────────▶  │ LOCKING  │
└─────────┘                      └──────────┘
     ▲                                │
     │                      8 QFs received
     │ Dropout > N frames             │
     │                                ▼
     │                           ┌──────────┐
     └─────────────────────────  │  SYNCED  │
                                 └──────────┘
```

#### Implementation
```swift
enum MTCSyncState {
    case idle           // No MTC received
    case locking        // Receiving QFs, building timecode
    case synced         // Valid timecode, following source
    case freewheeling   // Brief dropout, using last velocity
}

actor MTCSyncActor {
    private var state: MTCSyncState = .idle
    private var lockFrameCount = 0
    private var dropoutFrameCount = 0

    static let lockThreshold = 8      // QFs to confirm lock
    static let dropoutThreshold = 10  // Frames before reverting to idle
}
```

#### Edge Cases
- Lock threshold: Require 8 quarter-frames (2 frames) before trusting TC
- Dropout handling: Freewheel for up to 10 frames before going idle
- Direction changes: Reset lock state on direction change

---

## Lessons Learned

### LL-001: ScrollView Trackpad Latency
**Date**: 2026-01-02
**Commit**: `9249780`

**Problem**: Timeline scrolling had 150-200ms latency on trackpad.

**Root Cause**: `TapGesture` on timeline clips created gesture disambiguation delay.

**Solution**: Removed `.onTapGesture` from elements inside ScrollView, used selection via click handling at the ScrollView level.

**Prevention**: Added to CLAUDE.md performance rules.

---

### LL-002: Contract Scope Refinement Prevents Feature Creep
**Date**: 2026-01-02
**Task**: MIDIManager refactor to actor

**Problem**: Initial `TransportServiceProtocol` design combined MIDI sync (MTC/MMC) with playback control (play/pause/seek), creating an overly broad contract.

**Root Cause**: Natural tendency to design for "eventual" needs rather than immediate requirements. MIDIManager only handles MIDI sync, not playback.

**Solution**: scope-guard agent identified the creep and recommended splitting:
- `MIDISyncServiceProtocol` - MTC reception, MMC commands, MIDI input selection (Phase 1)
- `TransportServiceProtocol` - Playback control, seeking, state (Phase 2)

**Benefit**:
- Focused implementation (MIDISyncActor: 778 lines vs estimated 1200+ combined)
- Clearer ownership and testing
- Incremental delivery - Phase 1 shipped independently

**Prevention**: Always ask "What does this component *actually* do today?" before designing contracts.

---

### LL-003: Sendable Constraint Catches Architecture Violations Early
**Date**: 2026-01-02
**Source**: `MIDISyncServiceProtocol.swift`

**Problem**: Easy to accidentally pass non-thread-safe types across actor boundaries.

**Solution**: Mark all protocols and shared types as `Sendable`:
```swift
public protocol MIDISyncServiceProtocol: Sendable { }
public struct MIDISyncState: Sendable, Equatable { }
public enum MTCSyncState: Sendable, Equatable, Hashable { }
```

**Benefit**: Compiler errors if you try to:
- Include non-Sendable properties in state structs
- Pass closure capturing mutable state
- Reference class instances across actors

**Prevention**: Always add `: Sendable` to protocols and types that cross actor boundaries.

---

## Glossary

| Term | Definition |
|------|------------|
| **MTC** | MIDI Time Code - Protocol for synchronizing timecode over MIDI |
| **MMC** | MIDI Machine Control - Protocol for transport control over MIDI |
| **Quarter-Frame** | One of 8 MTC messages that together form a complete timecode |
| **Drop-Frame** | Timecode compensation for 29.97fps to sync with real time |
| **Actor** | Swift concurrency primitive providing thread-safe state isolation |
| **@MainActor** | Swift attribute ensuring code runs on the main thread |
| **DocC** | Apple's documentation compiler for Swift |

---

## Contributing to This Document

When adding new entries:

1. **Golden Patterns**: Must cite source file or commit
2. **Anti-Patterns**: Must include incident reference
3. **MTC/MMC Standards**: Must cite MIDI spec section
4. **Lessons Learned**: Must include date and commit hash

Use The Librarian agent to maintain this document.
