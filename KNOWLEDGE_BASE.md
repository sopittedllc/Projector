# Projector Knowledge Base

> **Last Updated**: 2026-01-06
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

### GP-007: DSWaveformImage Component Selection
**Added**: 2026-01-02
**Updated**: 2026-01-02 (corrected after WaveformLiveCanvas failure)
**Source**: https://github.com/dmrschmidt/DSWaveformImage README
**Category**: Third-Party Integration

#### Problem
DSWaveformImage offers multiple components. Using the wrong one causes rendering failures.

#### Component Selection Guide
| Component | Use Case | Input |
|-----------|----------|-------|
| `WaveformView` | Static waveform from audio FILE | Audio URL |
| `WaveformLiveCanvas` | **LIVE RECORDING ONLY** (VU meter) | Live samples |
| `WaveformImageDrawer` | Generate cacheable NSImage | Audio URL + size |
| `WaveformAnalyzer` | Extract raw samples | Audio URL |

#### Solution
```swift
// For static audio files - extract samples with WaveformAnalyzer
let analyzer = WaveformAnalyzer()
let samples = try await analyzer.samples(fromAudioAt: url, count: sampleCount)

// Render using a custom view (e.g., WaveformShape)
WaveformShape(samples: samples)
    .stroke(Color.white.opacity(0.8), lineWidth: 1)
```

#### CRITICAL: WaveformLiveCanvas is NOT for Static Files
```swift
// ❌ WRONG - WaveformLiveCanvas is for live recording, not file playback
WaveformLiveCanvas(samples: analyzedSamples, ...)

// ✅ CORRECT - WaveformView handles file analysis internally
WaveformView(audioURL: fileURL, ...)
```

#### Documentation Evidence
- README: "WaveformLiveCanvas - renders a live waveform from (0...1) normalized samples"
- README: "WaveformView - renders a one-off waveform from an audio file"
- Sample formats differ: Analyzer (0=loud) vs LiveCanvas expects (0=quiet)

#### Related Files
- `Projector/Managers/WaveformCache.swift`

---

### GP-008: WaveformShape Rendering for Zoom-Stable Clips
**Added**: 2026-01-02
**Source**: `Projector/Views/Timeline/AudioClipView.swift`
**Category**: UI Performance

#### Problem
Waveform images rendered at a fixed size do not scale when the clip width changes,
causing centered waveforms and stale placeholders after zoom changes.

#### Solution
```swift
ZStack {
    Rectangle()
        .fill(laneColor.opacity(0.3))

    if let waveformData, !waveformData.samples.isEmpty {
        GeometryReader { geometry in
            WaveformShape(samples: waveformData.samples)
                .stroke(Color.white.opacity(0.8), lineWidth: 1)
                .drawingGroup()
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    } else if isLoadingWaveform {
        ProgressView()
            .scaleEffect(0.5)
            .tint(.white.opacity(0.6))
    }
}
```

#### Why It Works
The waveform is drawn from cached samples and re-renders for the current clip
width, so zoom changes update the waveform without reprocessing audio.

#### When to Use
Timeline clip rendering that needs stable visuals across zoom levels.

---

### GP-009: UI Test Import Hook via Launch Arguments
**Added**: 2026-01-02
**Source**: `Projector/Views/ContentView.swift`
**Category**: Testing

#### Problem
UI tests need a reliable way to load media without manual drag-and-drop.

#### Solution
```swift
let arguments = ProcessInfo.processInfo.arguments
guard arguments.contains("-ui-testing") else { return }
guard let index = arguments.firstIndex(of: "-test-audio-url"),
      arguments.indices.contains(index + 1) else { return }

let url = URL(fileURLWithPath: arguments[index + 1])
Task { await addAudioToTimeline(url: url, laneId: lane.id) }
```

#### Why It Works
Launch arguments let UI tests inject deterministic inputs without changing
interactive user flows in production.

If the provided path is unreadable under sandbox restrictions, the app
generates a short audio file inside its own caches directory for tests.

#### When to Use
Automated UI tests that must load media or projects without user interaction.

---

### GP-010: Skip UI Tests When Accessibility Is Unavailable
**Added**: 2026-01-02
**Source**: `ProjectorUITests/ProjectorUITests.swift`
**Category**: Testing

#### Problem
macOS UI tests fail when Accessibility permissions are not granted to the
test runner, making local CLI runs brittle.

#### Solution
```swift
let window = app.windows.firstMatch
guard window.waitForExistence(timeout: 10) else {
    throw XCTSkip("UI automation window not found. Enable Accessibility permissions.")
}
```

#### Why It Works
Tests report a clear skip reason instead of hard failures when the OS blocks
UI automation, while still exercising the UI when permissions are enabled.

#### When to Use
Local or CI environments where Accessibility permissions may not be configured.

---

### GP-011: Accordion Headers as Buttons (Reliable Hit-Testing)
**Added**: 2026-01-02
**Source**: `Projector/Views/SettingsView.swift`
**Category**: UI

#### Problem
Accordion headers implemented via overlay-only buttons can lose hit-testing
inside ScrollViews, preventing collapse/expand actions.

#### Solution
```swift
Button(action: { isExpanded.toggle() }) {
    HStack { /* header content */ }
        .contentShape(Rectangle())
}
.buttonStyle(.plain)
```

#### Why It Works
The header itself becomes the button label, so SwiftUI assigns a concrete
hit-test frame without relying on overlay sizing behavior.

#### When to Use
Any collapsible header inside scrollable containers.

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

### AP-005: Using .id() on Async-Loading Views
**Added**: 2026-01-02
**Discovered**: Waveform Rendering Failure (Coroner Report)
**Severity**: Critical

#### The Mistake
```swift
// ❌ PROHIBITED - Destroys async-loading view on every change
WaveformView(audioURL: url, configuration: config)
    .id(clipWidth)  // Each zoom change destroys and recreates the view
```

#### Why It's Wrong
1. `.id()` is SwiftUI's "nuclear option" - it destroys and recreates the view entirely
2. `WaveformView` loads audio asynchronously - starts loading, then renders when complete
3. Each `.id()` change destroys the view mid-load, creating a new one
4. The new view starts loading from scratch
5. Result: View is in perpetual "loading" state, never renders

#### The Fix
```swift
// ✅ CORRECT - Use explicit .frame() instead
WaveformView(audioURL: url, configuration: config) {
    Color.clear  // placeholder
}
.frame(width: clipWidth, height: waveformHeight)
```

#### When .id() IS Appropriate
- Resetting scroll position in ScrollView
- Forcing complete state reset when data source changes
- Navigation destination identity

---

### AP-006: Overlay-Only Buttons for Accordion Headers
**Added**: 2026-01-02
**Discovered**: Accordion collapse regression
**Severity**: Medium

#### The Mistake
```swift
HStack { /* header */ }
    .overlay {
        Button(action: { toggle() }) { Color.clear }
    }
```

#### Why It's Wrong
Overlay-only buttons can lose hit-testing inside ScrollViews, making header
clicks unreliable and blocking expected interactions.

#### The Fix
```swift
Button(action: { toggle() }) {
    HStack { /* header */ }
        .contentShape(Rectangle())
}
.buttonStyle(.plain)
```

#### Incident
Settings accordion headers stopped collapsing after overlay-only buttons were used.

---

### AP-007: GeometryReader Placeholder With Geometry Usage
**Added**: 2026-01-03
**Discovered**: Build failure in `AudioClipView`
**Severity**: Low

#### The Mistake
```swift
GeometryReader { _ in
    // ...
    .frame(width: geometry.size.width, height: geometry.size.height) // geometry not in scope
}
```

#### Why It's Wrong
Using `_` discards the `GeometryProxy`, so any reference to `geometry` fails at compile time.

#### The Fix
```swift
GeometryReader { geometry in
    // use geometry.size
}
```

#### Incident
Build failed after a GeometryReader closure used `_` but still referenced `geometry`.

#### When .id() IS DANGEROUS
- Any view with async loading (network, file I/O)
- Views from 3rd-party libraries
- Views with complex internal state

---

### AP-008: Guard Conditions Coupling Unrelated Features
**Added**: 2026-01-06
**Discovered**: Multi-channel audio routing failure
**Severity**: High

#### The Mistake
```swift
// ❌ PROHIBITED - Optional naming feature blocks core routing functionality
private func makeChannelMap(lane: AudioLane, inputChannelCount: Int) -> [NSNumber]? {
    guard lane.outputMappingId != nil else { return nil }  // If no preset name, skip ALL routing
    // ... channel mapping logic
}
```

#### Why It's Wrong
This guard condition couples two unrelated features:
1. **`outputMappingId`**: An optional naming/preset feature (convenience)
2. **Channel routing** (`outputChannelOffset`, `outputChannelCount`): The core functionality

The result: multi-channel audio routing ONLY worked when a named preset was selected, even though `AudioLane` already had explicit `outputChannelOffset` and `outputChannelCount` properties that should work independently.

#### The Fix
```swift
// ✅ CORRECT - Check actual routing parameters, not optional metadata
private func makeChannelMap(lane: AudioLane, inputChannelCount: Int) -> [NSNumber]? {
    let needsCustomRouting = lane.outputChannelOffset != 0
        || (lane.outputChannelCount != 2 && lane.outputChannelCount != inputChannelCount)

    guard needsCustomRouting else { return nil }
    // ... channel mapping logic
}
```

#### Root Cause Pattern
Guard conditions that check for "optional feature X" can accidentally block "required feature Y" when:
- X was added as a convenience/enhancement to Y
- The guard assumes X is the trigger for Y
- Y actually has its own independent state that should work without X

#### Prevention
When writing guards, ask: **"What is the minimum data required for this function to work?"**
- Check the actual operational parameters, not convenience metadata
- Optional naming/preset features should never block core functionality
- Test features independently: "Does routing work without presets?"

#### Incident
Audio routing to channels 3+ failed until a mapping preset was selected in the UI, even when `outputChannelOffset` was correctly set to route to those channels.

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

### LL-004: Guard Conditions Should Check Operational State, Not Metadata
**Date**: 2026-01-06
**Source**: `Projector/Managers/PlaybackEngine.swift:680`

**Problem**: Multi-channel audio routing failed silently when no mapping preset was selected.

**Root Cause**: The `makeChannelMap` function used `guard lane.outputMappingId != nil` to determine if channel mapping was needed. This checked for the presence of a named preset (metadata) rather than checking if the actual routing parameters differed from defaults.

**Solution**: Changed the guard to check the operational state:
```swift
let needsCustomRouting = lane.outputChannelOffset != 0
    || (lane.outputChannelCount != 2 && lane.outputChannelCount != inputChannelCount)
guard needsCustomRouting else { return nil }
```

**Key Insight**: When optional convenience features (presets, names, tags) are added alongside core functionality, guard conditions should always check the core operational parameters, not the optional metadata. The question to ask: "What data does this function actually need to do its job?"

**Related**: See AP-008 for the anti-pattern documentation.

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
