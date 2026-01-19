# Projector Knowledge Base

> **Last Updated**: 2026-01-19 (GP-024, GP-025, GP-026 added - Cue Detection UI Patterns)
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

### GP-012: Centralized Layout Constants
**Added**: 2026-01-06
**Source**: `Projector/Utilities/LayoutConstants.swift`
**Category**: Architecture

#### Problem
Magic numbers (hardcoded values like `120`, `60`, `48`) were duplicated across multiple view files. This caused:
- Inconsistent layout values when views were modified independently
- No clear documentation of what values represent
- Difficult maintenance when design changes require updating multiple files
- Violations of AP-004 (No Magic Numbers standard)

#### Solution
Create a centralized `LayoutConstants.swift` file with domain-specific nested enums:

```swift
/// Timeline layout constants
enum TimelineLayout {
    /// Width of track/lane headers (video track, audio lanes)
    static let headerWidth: CGFloat = 120

    /// Height of the video track
    static let videoTrackHeight: CGFloat = 60

    /// Height of each audio lane
    static let audioLaneHeight: CGFloat = 60

    /// Height of audio clips
    static let audioClipHeight: CGFloat = 50
}

/// File manager panel constants
enum FileManagerLayout {
    /// Height when collapsed (header only)
    static let collapsedHeight: CGFloat = 32

    /// Height when expanded
    static let expandedHeight: CGFloat = 125
}

/// Common spacing and padding
enum Spacing {
    /// Standard content padding
    static let contentPadding: CGFloat = 12

    /// Small spacing between controls
    static let controlSpacing: CGFloat = 4
}
```

#### Usage in Views
```swift
// Before (magic numbers scattered across files)
.frame(width: 120, height: 60)  // What do these mean?

// After (centralized, documented constants)
.frame(width: TimelineLayout.headerWidth, height: TimelineLayout.audioLaneHeight)
```

#### Why It Works
- **Single source of truth**: All layout values defined in one place
- **Self-documenting**: Enum names and DocC comments explain purpose
- **Type-safe**: Compiler catches typos in constant names
- **Domain organization**: Nested enums group related constants (TimelineLayout, FileManagerLayout, etc.)
- **Easy refactoring**: Change once, applied everywhere

#### When to Use
- Any numeric layout value used in more than one file
- Any value that represents a design decision (heights, widths, spacing)
- Constants that may need tuning during development

#### Files Using This Pattern
- `Projector/Views/Timeline/MultiTrackTimelineView.swift`
- `Projector/Views/Timeline/AudioLaneView.swift`
- `Projector/Views/Timeline/VideoTrackView.swift`
- `Projector/Views/FileManager/FileManagerView.swift`

#### Related
- Addresses AP-004 (Magic Numbers anti-pattern)

---

### GP-013: Async Loading Guard Pattern
**Added**: 2026-01-07
**Source**: Session pattern for preventing redundant async loads
**Category**: Threading / Performance

#### Problem
Rapid state updates (e.g., sync loops running at frame rate, frequent zoom changes) can trigger the same async load operation hundreds of times before the first one completes. This causes:
- Wasted CPU cycles spawning redundant tasks
- Memory pressure from overlapping operations
- Potential race conditions when multiple completions update state
- UI flickering as loading states toggle repeatedly

#### Solution
Use a `Set<UUID>` (or appropriate identifier type) to track in-flight operations. Guard at entry and clean up on completion:

```swift
private var loadingIds: Set<UUID> = []

func loadAsync(_ item: Item) {
    // Guard: Skip if already loading this item
    guard !loadingIds.contains(item.id) else { return }

    // Mark as loading
    loadingIds.insert(item.id)

    Task {
        defer { loadingIds.remove(item.id) }

        // ... async work (file I/O, network, audio analysis, etc.)
        let result = try await performExpensiveOperation(item)

        // Update state with result
        await MainActor.run {
            self.cache[item.id] = result
        }
    }
}
```

#### Why It Works
- **Idempotent entry**: Multiple calls for the same item become no-ops
- **Automatic cleanup**: `defer` ensures the ID is removed even if the task fails
- **Memory efficient**: Set lookup is O(1), minimal overhead
- **Thread-safe**: Can be made actor-isolated for concurrent access

#### Variations
For actor-isolated contexts:
```swift
actor WaveformLoader {
    private var loadingIds: Set<UUID> = []

    func load(_ clip: AudioClip) async {
        guard !loadingIds.contains(clip.id) else { return }
        loadingIds.insert(clip.id)
        defer { loadingIds.remove(clip.id) }

        // async work...
    }
}
```

#### When to Use
- Waveform loading triggered by timeline updates
- Thumbnail generation during scroll
- Any async operation that may be triggered faster than it completes
- Operations expensive enough that redundant execution is wasteful

#### Related Files
- `Projector/Managers/WaveformCache.swift`

---

### GP-014: AVAudioEngine Multi-Channel Format Pattern
**Added**: 2026-01-07
**Source**: Multi-channel audio routing implementation
**Category**: Audio / AVFoundation

#### Problem
When connecting AVAudioEngine nodes with a 2-channel (stereo) format, audio cannot be routed to outputs beyond channels 1-2 (e.g., outputs 3-6 on a multi-channel audio interface). Even with correct channel mapping logic, the bus format itself limits which channels are accessible.

#### Solution
Create the output format using the device's actual channel count for connections to the main mixer:

```swift
// Get the device's actual channel count
let deviceChannelCount = engine.outputNode.outputFormat(forBus: 0).channelCount

// Create format that supports all device channels
let multiChannelFormat = AVAudioFormat(
    standardFormatWithSampleRate: sampleRate,
    channels: AVAudioChannelCount(deviceChannelCount)
)

// Connect with multi-channel format
engine.connect(sourceNode, to: engine.mainMixerNode, format: multiChannelFormat)
```

#### Why It Works
- AVAudioEngine bus formats define the maximum channel capacity for that connection
- A 2-channel format only allocates buffer space for channels 0-1
- Channel mapping (via `AVAudioMixerNode` pan/volume or `AVAudioChannelLayout`) operates within the bus format's channel count
- Using the device's full channel count allows the mapper to route to any supported output

#### Implementation Notes
```swift
// ❌ WRONG - Limits routing to stereo outputs only
let stereoFormat = AVAudioFormat(
    standardFormatWithSampleRate: 48000,
    channels: 2
)
engine.connect(playerNode, to: engine.mainMixerNode, format: stereoFormat)

// ✅ CORRECT - Supports full device channel count
let outputFormat = engine.outputNode.outputFormat(forBus: 0)
let multiFormat = AVAudioFormat(
    standardFormatWithSampleRate: outputFormat.sampleRate,
    channels: outputFormat.channelCount
)
engine.connect(playerNode, to: engine.mainMixerNode, format: multiFormat)
```

#### Edge Cases
- **Fallback for headphones**: When connected to 2-channel output, `deviceChannelCount` is 2, so the pattern degrades gracefully
- **Sample rate matching**: Always match the device's sample rate to avoid automatic conversion
- **Hot-plugging**: If the output device changes, the format may need to be updated (engine restart may be required)

#### Separation of Concerns
This pattern is **separate from channel mapping logic**:
1. **Bus format** (this pattern): Defines maximum channel capacity
2. **Channel mapping**: Routes specific input channels to specific output channels within that capacity

Both must be correct for multi-channel routing to work.

#### When to Use
- Any audio application supporting multi-channel output interfaces
- Pro audio applications with configurable output routing
- Applications that need to route audio to non-stereo outputs (surround, headphone mixes, etc.)

#### Related Files
- `Projector/Managers/PlaybackEngine.swift`

---

### GP-015: AUMatrixMixer Channel Routing
**Added**: 2026-01-08
**Source**: Multi-channel audio routing implementation
**Category**: Audio / CoreAudio

#### Problem
`AVAudioUnitEQ` and `AVAudioUnitConverter`'s `channelMap` property is non-functional for actual channel routing in AVAudioEngine. Setting `channelMap` appears to have no effect on audio output routing, leaving no apparent way to route mono/stereo sources to specific output channels.

#### Solution
Use `kAudioUnitSubType_MatrixMixer` AudioUnit with crosspoint gain values to achieve precise channel routing:

```swift
// Create Matrix Mixer AudioUnit
var componentDescription = AudioComponentDescription(
    componentType: kAudioUnitType_Mixer,
    componentSubType: kAudioUnitSubType_MatrixMixer,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0,
    componentFlagsMask: 0
)
let matrixMixer = AVAudioUnitGenerator(audioComponentDescription: componentDescription)
engine.attach(matrixMixer)

// Connect in the chain
engine.connect(sourceNode, to: matrixMixer, format: sourceFormat)
engine.connect(matrixMixer, to: engine.mainMixerNode, format: outputFormat)

// CRITICAL: Start engine BEFORE setting parameters
try engine.start()

// Set volumes (required for any output)
let audioUnit = matrixMixer.audioUnit
AudioUnitSetParameter(audioUnit, kMatrixMixerParam_Volume, kAudioUnitScope_Global, 0, 1.0, 0)
AudioUnitSetParameter(audioUnit, kMatrixMixerParam_Volume, kAudioUnitScope_Input, 0, 1.0, 0)
AudioUnitSetParameter(audioUnit, kMatrixMixerParam_Volume, kAudioUnitScope_Output, 0, 1.0, 0)

// Set crosspoint gains to route input channel to output channel
// Crosspoint element = (inputChannel << 16) | outputChannel
let crosspoint = UInt32((inputChannel << 16) | outputChannel)
AudioUnitSetParameter(audioUnit, kMatrixMixerParam_Volume, kAudioUnitScope_Global, crosspoint, 1.0, 0)
```

#### Critical Implementation Details

1. **Parameter timing**: All `AudioUnitSetParameter` calls MUST occur AFTER `engine.start()`. Setting parameters before start causes silent output.

2. **Crosspoint calculation**: The element parameter encodes both channels:
   ```swift
   let element = UInt32((inputCh << 16) | outputCh)
   ```

3. **Volume hierarchy**: Must set all three volume levels:
   - Global volume (overall mixer level)
   - Input volume (per-input-bus level)
   - Output volume (per-output-bus level)
   - Crosspoint volume (individual routing gain)

4. **Default state**: All crosspoints default to 0.0 (silent). You must explicitly enable each desired routing.

#### Why It Works
The Matrix Mixer is designed specifically for M-to-N channel routing scenarios. Each crosspoint represents a gain value between an input channel and output channel, allowing:
- Mono to specific output channel
- Stereo split across non-adjacent outputs
- Input channel duplication to multiple outputs
- Per-crosspoint gain control for mixing

#### Common Mistakes
```swift
// WRONG - Setting parameters before engine.start()
engine.attach(matrixMixer)
AudioUnitSetParameter(audioUnit, ...) // Silent output!
try engine.start()

// WRONG - Using channelMap on converter (non-functional)
let converter = AVAudioUnitConverter()
converter.channelMap = [2, 3] // Does nothing

// WRONG - Forgetting to set global/input/output volumes
AudioUnitSetParameter(audioUnit, kMatrixMixerParam_Volume, kAudioUnitScope_Global, crosspoint, 1.0, 0)
// Missing global/input/output volume settings = silent
```

#### When to Use
- Routing audio to specific output channels on multi-channel interfaces
- Creating custom monitor mixes
- Any scenario requiring M-to-N channel routing

#### Related Files
- `Projector/Managers/PlaybackEngine.swift`

---

### GP-016: Multi-Channel AVAudioFormat Creation
**Added**: 2026-01-08
**Source**: Multi-channel audio routing implementation
**Category**: Audio / AVFoundation

#### Problem
Creating `AVAudioFormat` for multi-channel (>2) audio requires specific initialization patterns. Common approaches fail:

1. `AVAudioFormat(standardFormatWithSampleRate:channels:)` returns `nil` for channel counts > 2
2. Using `kAudioChannelLayoutTag_DiscreteInOrder` causes silent output on multi-output interfaces

#### Solution
Use `AVAudioChannelLayout` with `kAudioChannelLayoutTag_Unknown | channelCount`:

```swift
func createMultiChannelFormat(sampleRate: Double, channelCount: UInt32) -> AVAudioFormat? {
    // For stereo, use the simple initializer
    if channelCount <= 2 {
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)
    }

    // For multi-channel, create explicit channel layout
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Unknown | channelCount
    layout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
    layout.mNumberChannelDescriptions = 0

    guard let channelLayout = AVAudioChannelLayout(layout: &layout) else {
        return nil
    }

    return AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channelLayout: channelLayout
    )
}
```

#### Why `kAudioChannelLayoutTag_Unknown | channelCount`
- The `Unknown` tag tells CoreAudio "I'm providing raw channels without semantic meaning"
- The bitwise OR with channel count specifies how many channels exist
- This combination works reliably with multi-output audio interfaces

#### Why NOT `kAudioChannelLayoutTag_DiscreteInOrder`
Despite seeming like the correct choice for "discrete channels in order," this tag causes silent output on many multi-channel interfaces. The exact reason is undocumented, but empirical testing confirms `Unknown | count` works where `DiscreteInOrder | count` fails.

#### Implementation Pattern
```swift
// CORRECT - Works for 6-channel interface
let layout = kAudioChannelLayoutTag_Unknown | UInt32(6)

// WRONG - Causes silent output
let layout = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(6)

// WRONG - Returns nil for > 2 channels
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 6) // nil!
```

#### When to Use
- Creating formats for multi-channel audio interfaces (>2 outputs)
- Building audio processing graphs that support arbitrary channel counts
- Pro audio applications with configurable output routing

#### Related Files
- `Projector/Managers/PlaybackEngine.swift`

---

### GP-017: AVAudioEngine Device Channel Count Query
**Added**: 2026-01-08
**Source**: Multi-channel audio routing implementation
**Category**: Audio / CoreAudio

#### Problem
`engine.outputNode.inputFormat(forBus: 0).channelCount` may incorrectly report 2 channels even when connected to a 6+ channel audio interface. Relying on this value for multi-channel routing decisions results in only stereo output being available.

#### Solution
Use CoreAudio's `kAudioDevicePropertyStreamConfiguration` to query the actual device capabilities:

```swift
func getDeviceChannelCount(deviceID: AudioDeviceID) -> UInt32 {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    var propertySize: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        deviceID,
        &propertyAddress,
        0,
        nil,
        &propertySize
    )

    guard status == noErr, propertySize > 0 else { return 2 }

    let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(
        capacity: Int(propertySize) / MemoryLayout<AudioBufferList>.size + 1
    )
    defer { bufferListPointer.deallocate() }

    status = AudioObjectGetPropertyData(
        deviceID,
        &propertyAddress,
        0,
        nil,
        &propertySize,
        bufferListPointer
    )

    guard status == noErr else { return 2 }

    let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
    var totalChannels: UInt32 = 0

    for buffer in bufferList {
        totalChannels += buffer.mNumberChannels
    }

    return totalChannels
}
```

#### Why the Node Format is Unreliable
AVAudioEngine's `outputNode.inputFormat` reflects the format of the *connection* to the output node, not the device's actual capabilities. When no explicit multi-channel format has been set, it defaults to stereo regardless of the hardware.

#### Implementation Pattern
```swift
// WRONG - May report 2 even for 6-channel device
let channelCount = engine.outputNode.inputFormat(forBus: 0).channelCount

// CORRECT - Query device directly
let deviceChannelCount = getDeviceChannelCount(deviceID: outputDeviceID)

// Store and preserve the device-queried value
self.availableOutputChannels = deviceChannelCount
```

#### Key Implementation Notes
1. **Query once, cache result**: Device capabilities don't change while running. Query at startup or device change.

2. **Never overwrite with node format**: If you query the device and get 6, don't later overwrite that value with the node's reported 2.

3. **Handle device changes**: Re-query when the output device changes (via `AudioObjectPropertyListenerProc`).

4. **Fallback gracefully**: If the query fails, fall back to stereo (2 channels) to ensure basic functionality.

#### When to Use
- Determining available output channels for routing UI
- Creating multi-channel formats that match device capabilities
- Any code that needs to know the true channel count of the audio output device

#### Related Files
- `Projector/Managers/PlaybackEngine.swift`

---

### GP-018: DMG Distribution Build with Finder Alias
**Added**: 2026-01-13
**Source**: `scripts/build-release.sh`
**Category**: Distribution / Build

#### Problem
Creating professional macOS DMG installers requires:
1. Proper code signing and notarization
2. Styled Finder window with background and positioned icons
3. Applications folder shortcut that displays correct icon

Standard approaches fail:
- `create-dmg --app-drop-link` creates a **symlink** that shows as broken/placeholder icon
- Finder aliases work but their icons **vanish** on macOS Sonoma/Sequoia due to Apple bug

#### Solution
Use three-part approach: Finder alias + custom icon + staging directory

```bash
# 1. Create staging directory (create-dmg copies CONTENTS of source)
STAGING_DIR="${BUILD_DIR}/dmg_staging"
mkdir -p "${STAGING_DIR}"
cp -a "${EXPORT_PATH}/${APP_NAME}" "${STAGING_DIR}/"

# 2. Create Finder alias (NOT symlink - symlinks show broken icons)
osascript -e "tell application \"Finder\" to make new alias file at POSIX file \"${STAGING_DIR}\" to POSIX file \"/Applications\" with properties {name:\"Applications\"}"

# 3. Set custom icon to prevent macOS alias icon vanishing bug
fileicon set "${STAGING_DIR}/Applications" "${SCRIPTS_DIR}/ApplicationsFolderIcon.icns"

# 4. Create DMG from staging directory
create-dmg \
    --volname "AppName" \
    --background "dmg-background.png" \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "AppName.app" 180 200 \
    --icon "Applications" 480 200 \
    --codesign "Developer ID Application: ..." \
    --notarize "notary-profile" \
    "output.dmg" \
    "${STAGING_DIR}"
```

#### Why It Works
1. **Finder alias vs symlink**: Symlinks (`ln -s`) inherit target icon but often display as broken rectangle in DMGs. Finder aliases properly inherit and display the target folder's icon.

2. **Custom icon via fileicon**: macOS Sonoma/Sequoia has a bug where alias icons appear briefly then vanish. Setting an explicit custom icon with `fileicon` persists correctly.

3. **Staging directory**: `create-dmg` copies the **contents** of the source folder. Passing `App.app` directly results in only `Contents/` being copied. A staging directory ensures the `.app` bundle structure is preserved.

#### Critical Implementation Details

**Prerequisites:**
```bash
brew install create-dmg fileicon
```

**Required files:**
- `scripts/dmg-background.png` - 660x400 background with arrow
- `scripts/ApplicationsFolderIcon.icns` - Custom Applications folder icon
- `scripts/ExportOptions.plist` - Developer ID export settings

**DO NOT use `--sandbox-safe`** unless absolutely necessary - it skips Finder AppleScript, resulting in wrong window size and no background.

#### When to Use
Any macOS app distribution requiring professional DMG installer appearance.

#### Related Files
- `scripts/build-release.sh`
- `scripts/verify-distribution.sh`
- `~/.claude/macos-swift-reference.md` (full template)

---

### GP-019: macOS Drag-Drop Architecture (Definitive Guide)
**Added**: 2026-01-15
**Source**: Apple Drag and Drop Programming Topics, MacRumors Forums research, empirical testing
**Category**: UI / AppKit / SwiftUI Integration

This is the **definitive reference** for implementing drag-drop in macOS applications, especially those mixing SwiftUI and AppKit.

---

#### Part 1: Ground Truth - How AppKit Drag-Drop Actually Works

##### The Window Server Makes the Decision

**CRITICAL INSIGHT**: Drag destination selection happens in the **window server**, not your application code.

> "The whole of a drag and drop operation happens within the window server. This includes determining which view is under the mouse and therefore the target of the d'n'd operation. The target application doesn't get any events or messages, so it's impossible for your application to change this determination."
> — MacRumors Forums

**Implications:**
- You CANNOT "pass" a drag from parent to child by returning `[]` from `draggingEntered:`
- The window server decides the target BEFORE your code runs
- Once a view is selected, it handles the entire drag session

##### Registration Permanently Marks a View

```swift
// Once called, this view is FOREVER a potential drag destination
view.registerForDraggedTypes([.fileURL])
```

**Critical Rule**: If a subview **ever** registers for drag types, it will intercept drags from its superview. Even calling `unregisterDraggedTypes()` doesn't fully undo this.

##### The Lifecycle

```
                                    ┌─────────────────────────────────┐
                                    │     Window Server Decision      │
                                    │   (Based on view registration   │
                                    │    and mouse position)          │
                                    └─────────────────────────────────┘
                                                   │
                                                   ▼
┌─────────────────┐   Returns .copy    ┌─────────────────┐
│ draggingEntered │ ────────────────▶  │ draggingUpdated │ (periodic)
└─────────────────┘                    └─────────────────┘
        │                                      │
        │ Returns []                           │ Image released
        │                                      ▼
        ▼                              ┌─────────────────────┐
   Drag Rejected                       │ prepareForDragOp    │
   (cursor shows ⊘)                    └─────────────────────┘
                                               │
                                               ▼
                                       ┌─────────────────────┐
                                       │ performDragOp       │
                                       └─────────────────────┘
                                               │
                                               ▼
                                       ┌─────────────────────┐
                                       │ concludeDragOp      │
                                       └─────────────────────┘
```

##### Return Values from draggingEntered

| Return Value | Effect |
|--------------|--------|
| `.copy` | Accept drag, show "+" cursor badge |
| `.move` | Accept drag, indicate move operation |
| `[]` (empty) | **Reject drag** - shows ⊘ cursor, `performDragOperation` NOT called |

**MYTH BUSTED**: Returning `[]` does NOT pass the drag to child views. It simply rejects the drag at this view.

---

#### Part 2: SwiftUI Integration Pitfalls

##### SwiftUI Overlays Create Siblings, Not Children

```swift
// This creates SIBLING NSViews in AppKit, not parent-child!
VStack {
    ChildView()
}
.overlay {
    ParentDragHandler()  // NSView is SIBLING to ChildView's NSView
}
```

**The Problem**: SwiftUI's `.overlay` and `.background` modifiers create views that are **siblings** in the underlying NSView hierarchy, not parent-child. This breaks AppKit's drag destination selection model.

##### NSViewRepresentable Drag Handlers

When using `NSViewRepresentable` for drag handling:
```swift
struct DragCaptureView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragCaptureNSView {
        let view = DragCaptureNSView()
        view.registerForDraggedTypes([.fileURL])  // Now a permanent drag target
        return view
    }
}
```

**Problem**: Every `DragCaptureView` in your hierarchy creates a separate registered view. The **topmost in z-order** intercepts all drags.

##### SwiftUI .onDrop Limitations

- **Breaks inside List**: `.onDrop` stops working on views inside `List` (known SwiftUI bug)
- **Workaround**: Use `ScrollView + ForEach` instead of `List`
- **Alternative**: Use `NSViewRepresentable` with explicit drag handling

---

#### Part 3: Correct Architecture Patterns

##### Pattern A: Single Coordinator (Recommended)

**Use ONE drag handler that routes based on coordinates:**

```swift
struct TimelineView: View {
    var body: some View {
        ZStack {
            // Content layers (no drag registration)
            VideoTrackView()
            AudioLanesView()
            NewLaneDropZone()
        }
        .overlay {
            // SINGLE drag coordinator handles ALL drags
            TimelineDragCoordinator(
                onDrop: { info, location in
                    // Determine target based on coordinates
                    if isOverVideoTrack(location) {
                        handleVideoTrackDrop(info, location)
                    } else if let laneIndex = laneAt(location) {
                        handleAudioLaneDrop(info, location, laneIndex)
                    } else {
                        handleNewLaneDrop(info, location)
                    }
                }
            )
        }
    }
}
```

**Why This Works:**
- Only ONE view registers for drags
- No competition between handlers
- Coordinator has full knowledge of layout
- Preview state can be managed centrally

##### Pattern B: Child-Only Registration (No Parent)

**Register ONLY the leaf views that handle drops:**

```swift
struct AudioLaneView: View {
    var body: some View {
        LaneContent()
            .overlay {
                LaneDragHandler()  // Each lane has its own handler
            }
    }
}

// NO parent drag handler - each lane handles its own drops
struct TimelineView: View {
    var body: some View {
        VStack {
            VideoTrackView()  // Has its own handler
            ForEach(lanes) { lane in
                AudioLaneView(lane: lane)  // Each has its own handler
            }
        }
        // NO overlay drag handler here!
    }
}
```

**Why This Works:**
- No parent to intercept
- Each leaf view receives its own drags
- Works for simple cases

**Limitation**: Coordination between views (e.g., multi-file distribution) becomes complex.

##### Pattern C: Glass View for Tracking Only

**Use a glass view to observe without intercepting:**

```swift
class GlassTrackingView: NSView {
    // CRITICAL: Return nil from hitTest
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil  // Transparent to all mouse events
    }

    // DO NOT register for drag types if you want to pass through
    // OR register but ALWAYS return [] to observe without claiming
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Track for UI purposes
        updateDragItemCount(from: sender)
        // ALWAYS return [] - never claim
        return []
    }
}
```

**Why This Works:**
- Observes drags for UI feedback (showing overlays)
- Never claims drags, so children can handle them
- **BUT**: Works only if children are actual NSView subviews, not SwiftUI siblings

---

#### Part 4: Reading Files from NSDraggingInfo

##### Modern Pattern (macOS 10.13+)

```swift
override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard

    // Preferred: readObjects with type filtering
    guard let urls = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] else {
        return false
    }

    // Filter by media type
    let audioURLs = urls.filter { ProjectMediaLibrary.mediaType(for: $0) == .audio }
    let videoURLs = urls.filter { ProjectMediaLibrary.mediaType(for: $0) == .video }

    // Handle the drop
    handleDrop(audioURLs: audioURLs, videoURLs: videoURLs)
    return true
}
```

##### Sandbox Considerations

```swift
// For sandboxed apps, access security-scoped URLs
for url in urls {
    guard url.startAccessingSecurityScopedResource() else { continue }
    defer { url.stopAccessingSecurityScopedResource() }

    // Use the file...
}
```

##### Internal vs External Drags

```swift
// Check if drag is from within the app
let isInternalDrag = pasteboard.types?.contains(
    NSPasteboard.PasteboardType("com.yourapp.internal-item")
) ?? false

if isInternalDrag {
    // Use shared drag context (faster, has metadata)
    let items = DragContext.shared.items
} else {
    // Parse from pasteboard (external drag from Finder)
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [:])
}
```

---

#### Part 5: Anti-Patterns (What Breaks)

##### AP-DND-001: Multiple Competing Drag Handlers

```swift
// ❌ BROKEN - Multiple overlays with drag handlers
VStack {
    Content()
}
.overlay { ParentDragHandler() }   // Claims all drags!
.overlay { ChildDragHandler() }    // Never receives anything
```

**Why It Breaks**: First overlay claims all drags. Second never sees them.

##### AP-DND-002: Expecting Parent-to-Child Passthrough

```swift
// ❌ BROKEN - Expecting [] to pass to children
override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    if shouldHandleHere {
        return .copy
    } else {
        return []  // MYTH: This does NOT pass to children!
    }
}
```

**Why It Breaks**: Window server already chose this view. Returning `[]` just rejects the drag.

##### AP-DND-003: Using .background for Drag Observation

```swift
// ❌ UNRELIABLE - Background may not receive drags
VStack { Content() }
    .background {
        DragObserver()  // May or may not work depending on z-order
    }
```

**Why It Breaks**: Z-order of `.background` vs content is implementation-defined.

##### AP-DND-004: SwiftUI List with onDrop

```swift
// ❌ BROKEN - Known SwiftUI bug
List(items) { item in
    ItemRow(item: item)
        .onDrop(of: [.fileURL]) { ... }  // Does not work!
}
```

**Fix**: Use `ScrollView + ForEach` instead:
```swift
ScrollView {
    ForEach(items) { item in
        ItemRow(item: item)
            .onDrop(of: [.fileURL]) { ... }  // Works
    }
}
```

---

#### Part 6: Debugging Drag-Drop Issues

##### Diagnostic Questions

1. **How many views register for drag types?**
   - Search for `registerForDraggedTypes` and `.onDrop`
   - Each registration creates a potential interceptor

2. **What's the actual NSView hierarchy?**
   - Use Xcode's View Debugger (Debug → View Debugging → Capture View Hierarchy)
   - Look at NSView tree, not SwiftUI tree

3. **Which view is claiming drags?**
   - Add logging to `draggingEntered` in ALL drag-registered views
   - Only ONE should fire per drag session

4. **Is the cursor showing the right indicator?**
   - "+" badge = `.copy` returned
   - ⊘ symbol = `[]` returned (rejected)
   - No badge = `.move` or `.generic`

##### Debug Logging Pattern

```swift
override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    print("[\(type(of: self))] draggingEntered at \(sender.draggingLocation)")
    let result: NSDragOperation = // your logic
    print("[\(type(of: self))] returning \(result)")
    return result
}
```

---

#### Part 7: The Projector Implementation

Based on the above principles, Projector's timeline uses **Pattern A (Single Coordinator)** conceptually, but due to SwiftUI's overlay architecture, we implement it as:

1. **Parent DragCaptureView** (`.background`): Only tracks `externalDragItemCount` for overlay visibility, ALWAYS returns `[]`
2. **Child handlers** (per-lane, per-track): Actually handle drops, return `.copy` when accepting
3. **No multi-level claiming**: Only leaf views claim drags

This works because:
- Parent uses `.background` (lower z-order)
- Parent never claims (returns `[]`)
- Children are at higher z-order and claim appropriately

---

#### Summary: The Three Rules

1. **ONE handler per drop zone** - Never have multiple registered views covering the same area
2. **Window server decides first** - Your code cannot redirect drags between views
3. **Leaf views handle drops** - Parent views should observe, not claim

---

#### Sources

- [Apple: Dragging Destinations](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Concepts/dragdestination.html)
- [Apple: Receiving Drag Operations](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/DragandDrop/Tasks/acceptingdrags.html)
- [MacRumors: Subview Blocking Drag/Drop](https://forums.macrumors.com/threads/cocoa-nsview-subview-blocking-drag-drop.1147942/)
- [SwiftUI Lab: Drag & Drop](https://swiftui-lab.com/drag-drop-with-swiftui/)

---

### GP-020: macOS Audio Interface Architecture (Foundational Guide)
**Added**: 2026-01-15
**Source**: Apple CoreAudio Documentation, OBS Studio, WWDC Sessions 501/502/510
**Category**: Audio / CoreAudio / AVAudioEngine

This is the **definitive reference** for macOS audio device management - enumeration, selection, hot-plugging, and AVAudioEngine integration.

---

#### Part 1: CoreAudio Device Enumeration

##### Property-Based Architecture

CoreAudio uses a **tree-structured object model** with the root element `kAudioObjectSystemObject`. All device interaction happens through property queries using `AudioObjectPropertyAddress`:

```swift
struct AudioObjectPropertyAddress {
    var mSelector: AudioObjectPropertySelector  // e.g., kAudioHardwarePropertyDevices
    var mScope: AudioObjectPropertyScope        // e.g., kAudioObjectPropertyScopeGlobal
    var mElement: AudioObjectPropertyElement    // e.g., kAudioObjectPropertyElementMain
}
```

**Critical Property Selectors:**
- `kAudioHardwarePropertyDevices` - Enumerate all connected devices
- `kAudioDevicePropertyDeviceUID` - Persistent device identifier (survives reboots)
- `kAudioDevicePropertyDeviceID` - Session-scoped device identifier (ephemeral)
- `kAudioDevicePropertyDeviceName` - Human-readable device name
- `kAudioHardwarePropertyDefaultOutputDevice` - System default output

##### Core Enumeration Pattern

```c
// Step 1: Get device list size
AudioObjectPropertyAddress addr = {
    .mSelector = kAudioHardwarePropertyDevices,
    .mScope = kAudioObjectPropertyScopeGlobal,
    .mElement = kAudioObjectPropertyElementMain
};

UInt32 size = 0;
AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size);

// Step 2: Allocate and retrieve device IDs
AudioDeviceID *ids = malloc(size);
UInt32 count = size / sizeof(AudioDeviceID);
AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, ids);

// Step 3: Query each device
for (UInt32 i = 0; i < count; i++) {
    // Query device properties for ids[i]
}
```

**Key Implementation Details:**
- Always call `AudioObjectGetPropertyDataSize()` first to allocate correct buffer
- Memory returned by CoreAudio (like CFString) must be CFReleased

---

#### Part 2: AudioDeviceID vs UID - When to Use Each

| Identifier | Scope | Persistence | Use Case |
|-----------|-------|-------------|----------|
| **AudioDeviceID** | Session | Lost on app restart | Runtime operations |
| **Device UID** | Permanent | Survives reboots | User preferences storage |

##### Best Practice Pattern

```swift
// Store: Always use UID
let deviceUID = getDeviceUID(from: deviceID)
UserDefaults.standard.set(deviceUID, forKey: "preferredAudioOutputUID")

// Retrieve: Must convert UID back to ID
if let storedUID = UserDefaults.standard.string(forKey: "preferredAudioOutputUID"),
   let newDeviceID = deviceIDFromUID(storedUID) {
    setCurrentDevice(newDeviceID)
} else {
    useSystemDefaultDevice()  // Fallback if device disconnected
}
```

**Critical Issue:** AudioDeviceID becomes stale after:
- Device unplug/replug
- App restart
- System sleep/wake

---

#### Part 3: Hot-Plugging Detection

##### Property Listener Registration

```c
// Register listener for device addition/removal
AudioObjectPropertyAddress addr = {
    .mSelector = kAudioHardwarePropertyDevices,
    .mScope = kAudioObjectPropertyScopeGlobal,
    .mElement = kAudioObjectPropertyElementMain
};

AudioObjectAddPropertyListener(
    kAudioObjectSystemObject,
    &addr,
    deviceListChangedCallback,
    NULL
);
```

##### Critical Listener Cleanup

**Major crash source if not done correctly:**

```c
// MUST match the EXACT address used during registration
AudioObjectRemovePropertyListener(
    kAudioObjectSystemObject,
    &addr,  // Same scope/element as registration
    deviceListChangedCallback,
    NULL
);

// Common bug: Different scope/element = listener NOT removed = crash
```

---

#### Part 4: Device Selection at Runtime

##### Setting Device via AudioUnit

```swift
// Get output node's underlying audio unit
guard let audioUnit = audioEngine.outputNode.audioUnit else { return }

// Set device ID
var deviceID: AudioDeviceID = targetDeviceID
AudioUnitSetProperty(
    audioUnit,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &deviceID,
    UInt32(MemoryLayout<AudioDeviceID>.size)
)
```

##### System Default vs Specific Device

```swift
enum AudioOutputDevice {
    case systemDefault  // Maps to kAudioHardwarePropertyDefaultOutputDevice
    case specific(deviceUID: String)
}

func applyOutputSelection(_ device: AudioOutputDevice) {
    switch device {
    case .systemDefault:
        // Don't set kAudioOutputUnitProperty_CurrentDevice
        break
    case .specific(let uid):
        if let deviceID = deviceIDFromUID(uid) {
            // Set specific device
        }
    }
}
```

---

#### Part 5: AVAudioEngine Integration

##### Critical Limitation

**AVAudioEngine on macOS is restricted to a single audio device** for both input and output simultaneously. For different input/output devices, use Core Audio directly.

##### Configuration Change Notification

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(handleAudioEngineConfigurationChange),
    name: .AVAudioEngineConfigurationChange,
    object: audioEngine
)

@objc func handleAudioEngineConfigurationChange() {
    // Device disconnected, sample rate changed, or route changed
    audioEngine.stop()
    // Rebuild audio graph
    try? audioEngine.start()
}
```

---

#### Part 6: Thread Safety

##### Safe Operations (No Locking Required)
- Reading simple numeric properties
- AudioDeviceID comparison
- Property listener registration/removal

##### NOT Thread-Safe (Require Synchronization)
- Writing multiple properties simultaneously
- Modifying device list during enumeration
- Changing device while rendering

##### MIDI Callback Constraints

**Never do in MIDI/audio callbacks:**
- Allocate memory
- Call pthread_mutex_lock
- Call into Objective-C runtime
- dispatch_async

---

#### Part 7: Common Pitfalls

##### Pitfall 1: Stale Device IDs

```swift
// ❌ DANGEROUS - ID becomes invalid
var currentDeviceID: AudioDeviceID = 0

// ✅ CORRECT - Use UID
var preferredDeviceUID: String = ""
```

##### Pitfall 2: Property Address Mismatch

```c
// ❌ Registered with Global, removed with Output = LEAK
addr.mScope = kAudioObjectPropertyScopeGlobal;  // Registration
removeAddr.mScope = kAudioObjectPropertyScopeOutput;  // Removal - WRONG!
```

##### Pitfall 3: Device Change During Playback

```swift
// ❌ DANGEROUS - Format mismatch
AudioUnitSetProperty(outputNode.audioUnit, kAudioOutputUnitProperty_CurrentDevice, ...)
// Audio corrupted!

// ✅ CORRECT - Stop, change, restart
audioEngine.stop()
AudioUnitSetProperty(...)
try audioEngine.start()
```

---

#### Sources

- [Apple CoreAudio Documentation](https://developer.apple.com/documentation/coreaudio)
- [WWDC 2014 Session 501 - What's New in Core Audio](https://asciiwwdc.com/2014/sessions/501/)
- [WWDC 2014 Session 502 - AVAudioEngine in Practice](https://asciiwwdc.com/2014/sessions/502/)
- [OBS Studio macOS Audio Device Enumeration](https://github.com/obsproject/obs-studio)
- [kAudioOutputUnitProperty_CurrentDevice](https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_currentdevice)

---

### GP-021: macOS Audio Routing Architecture (Foundational Guide)
**Added**: 2026-01-15
**Source**: Apple AVAudioEngine Documentation, Audio Unit Programming Guide
**Category**: Audio / Channel Routing / Multi-Output

This is the **definitive reference** for macOS audio channel routing - channel maps, stereo pairs, device-specific persistence, and multi-output configuration.

---

#### Part 1: Channel Mapping Core Concepts

##### The Channel Map Array

Channel mapping describes how input channels map to output channels:

```
Input Channels:  [0, 1]
                  |  |
Channel Map:    [0, 1, -1, -1]
                  |  |   |   |
Output Channels:[L, R, Ch3, Ch4]
```

**Key Rules:**
- Each array index = output channel
- Array value = which input channel feeds it (-1 = silent)
- Array length MUST match hardware output channel count
- Single input can route to multiple outputs

##### Implementation via AudioUnit

```swift
// Query hardware output channel count
let outputChannelCount = Int(outputNode.outputFormatForBus(0).channelCount)

// Create map array
var channelMap = [SInt32](repeating: -1, count: outputChannelCount)
channelMap[0] = 0  // Output 0 <- Input 0
channelMap[1] = 1  // Output 1 <- Input 1

// Apply to output unit
AudioUnitSetProperty(
    outputNode.audioUnit,
    kAudioOutputUnitProperty_ChannelMap,
    kAudioUnitScope_Global,
    0,
    &channelMap,
    UInt32(MemoryLayout<SInt32>.size * channelMap.count)
)
```

**Critical Constraint:** Channel mapping ONLY works on output units (`AVAudioEngine.outputNode`), NOT on mixer nodes.

---

#### Part 2: AVAudioEngine Graph Architecture

##### The Graph Model

```
Source Nodes              Processing              Destination
(AVAudioPlayerNode)       (AVAudioMixerNode)     (outputNode)
        |                       |                      |
        +---> Bus 0 ---+        |                      |
        |              |------> Mixer -------> outputNode ---> Hardware
        +---> Bus 1 ---+     (format         (channel map)
                            conversion)
```

##### Node Types

1. **Source Nodes**: `AVAudioPlayerNode`, `AVAudioInputNode`
2. **Processing Nodes**: `AVAudioMixerNode`, `AVAudioUnitEQ`
3. **Output Node**: `outputNode` (routes to hardware)

---

#### Part 3: Multi-Channel Format Creation

##### The kAudioChannelLayoutTag_Unknown Pattern

For arbitrary channel counts (not standard layouts like stereo or 5.1):

```swift
let channelCount: UInt32 = 8
let layoutTag = kAudioChannelLayoutTag_Unknown | channelCount

var layout = AudioChannelLayout()
layout.mChannelLayoutTag = layoutTag
layout.mChannelBitmap = 0
layout.mNumberChannelDescriptions = 0

let avLayout = AVAudioChannelLayout(layout: &layout)
let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 48000,
    interleaved: false,
    channelLayout: avLayout
)
```

**Why This Works:**
- Standard layout tags (stereo, 5.1) have fixed channel counts
- `kAudioChannelLayoutTag_Unknown | N` allows any channel count
- Required for professional multi-channel interfaces

---

#### Part 4: Stereo Pairs for Professional Workflows

##### The Stereo Pair Abstraction

Professional interfaces expose channels as logical pairs:

```
Physical Channels    Logical Pairs
─────────────────    ─────────────
[0, 1]          →    Main L/R (speakers)
[2, 3]          →    Headphones
[4, 5]          →    Aux Send 1
[6, 7]          →    Aux Send 2
```

##### Routing Implementation

```swift
struct OutputPair {
    let name: String
    let leftChannel: Int
    let rightChannel: Int
}

func buildChannelMap(pairs: [OutputPair], hardwareChannels: Int) -> [SInt32] {
    var map = [SInt32](repeating: -1, count: hardwareChannels)
    for pair in pairs {
        if pair.leftChannel < hardwareChannels {
            map[pair.leftChannel] = 0   // Input L
        }
        if pair.rightChannel < hardwareChannels {
            map[pair.rightChannel] = 1  // Input R
        }
    }
    return map
}
```

---

#### Part 5: Device-Specific Routing Persistence

##### The Problem

Routing configurations don't persist across device changes because:
- Channel counts differ per device
- Channel maps are hardware-specific arrays

##### Solution: Store with Device Identity

```swift
struct RoutingConfiguration: Codable {
    let deviceUID: String
    let channelCount: Int

    struct OutputPair: Codable {
        let name: String
        let leftChannelIndex: Int
        let rightChannelIndex: Int
    }

    let outputPairs: [OutputPair]
}

// Save
func saveRouting(_ config: RoutingConfiguration) {
    let data = try? JSONEncoder().encode(config)
    UserDefaults.standard.set(data, forKey: "routing_\(config.deviceUID)")
}

// Restore with validation
func restoreRouting(forDevice device: AudioDevice) -> RoutingConfiguration? {
    guard let data = UserDefaults.standard.data(forKey: "routing_\(device.uid)"),
          let config = try? JSONDecoder().decode(RoutingConfiguration.self, from: data),
          config.channelCount == device.outputChannelCount else {
        return nil  // Config invalid for this device
    }
    return config
}
```

---

#### Part 6: AUMatrixMixer for M-to-N Routing

For complex routing (multiple sources to multiple outputs independently):

```swift
// Create matrix mixer
var componentDesc = AudioComponentDescription(
    componentType: kAudioUnitType_Mixer,
    componentSubType: kAudioUnitSubType_MatrixMixer,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0,
    componentFlagsMask: 0
)

// Configure: 4 inputs, 8 outputs
AudioUnitSetProperty(matrixMixer,
    kAudioUnitProperty_BusCount,
    kAudioUnitScope_Input, 0, &inputCount, ...)
AudioUnitSetProperty(matrixMixer,
    kAudioUnitProperty_BusCount,
    kAudioUnitScope_Output, 0, &outputCount, ...)

// Set matrix element volumes
// matrixElement[input][output] = gain
AudioUnitSetParameter(matrixMixer,
    kMatrixMixerParam_Volume,
    kAudioUnitScope_Global,
    (input << 16) | output,  // Encode input/output indices
    gainValue, 0)
```

---

#### Part 7: Common Pitfalls

##### Pitfall 1: Channel Map on Wrong Node

```swift
// ❌ WRONG - Channel map doesn't work on mixer
AudioUnitSetProperty(mainMixer.audioUnit, kAudioOutputUnitProperty_ChannelMap, ...)

// ✅ CORRECT - Only on outputNode
AudioUnitSetProperty(outputNode.audioUnit, kAudioOutputUnitProperty_ChannelMap, ...)
```

##### Pitfall 2: Array Size Mismatch

```swift
// ❌ WRONG - 4-element map for 8-channel device
var channelMap = [SInt32](0, 1, -1, -1)  // Only 4 elements
// AudioUnitSetProperty fails or produces garbage

// ✅ CORRECT - Match hardware exactly
let hwChannels = Int(outputNode.outputFormatForBus(0).channelCount)
var channelMap = [SInt32](repeating: -1, count: hwChannels)
```

##### Pitfall 3: Format Mismatches

```swift
// ❌ WRONG - Different formats without mixer
let fileFormat = file.processingFormat  // 48kHz, 2ch
let hwFormat = outputNode.outputFormatForBus(0)  // 44.1kHz, 8ch
engine.connect(player, to: outputNode, format: fileFormat)  // FAILS

// ✅ CORRECT - Use mixer for format conversion
engine.connect(player, to: mainMixer, format: fileFormat)
engine.connect(mainMixer, to: outputNode, format: hwFormat)
```

---

#### Part 8: The Golden Pattern

**Channel Routing in macOS Audio:**

1. **Query** device capabilities (channel count)
2. **Create** channel map array (one element per output)
3. **Validate** map size matches hardware
4. **Apply** to `outputNode.audioUnit` via `AudioUnitSetProperty`
5. **Connect** nodes with matching formats (mixer handles conversion)
6. **Persist** routing with device UID for restoration

---

#### Sources

- [AVAudioEngine and Multiroute | Apple Developer Forums](https://developer.apple.com/forums/thread/15416)
- [Audio Unit Programming Guide](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitProgrammingGuide/)
- [AVAudioChannelLayout Documentation](https://developer.apple.com/documentation/avfaudio/avaudiochannellayout)
- [Create Aggregate Devices | Apple Support](https://support.apple.com/en-us/102171)

---

### GP-022: Sample Rate and Frame Rate Handling (Foundational Guide)
**Added**: 2026-01-15
**Source**: Apple AVAudioConverter Documentation, MIDI 1.0 Specification, Professional Video Standards
**Category**: Audio / Video Sync / MTC

This is the **definitive reference** for sample rate and frame rate management in professional video editing with MTC synchronization.

---

#### Part 1: Sample Rate Fundamentals

##### Core Sample Rates

| Rate | Use Case |
|------|----------|
| **44.1 kHz** | Consumer audio (CDs) |
| **48 kHz** | **Professional video standard** (broadcast, film) |
| **96 kHz** | High-resolution audio |
| **192 kHz** | Premium high-res |

**For video editing: 48 kHz is the standard** because it divides evenly into common frame rates.

##### Device vs Project Sample Rate

Two rates must be managed:
1. **Device Rate** - What hardware is configured to use
2. **Project Rate** - What the editing application expects

**Critical macOS Issue:** When device sample rate changes mid-playback:
- Audio callbacks stop entirely
- Device must be closed and reopened
- No graceful mid-playback rate switching

---

#### Part 2: Frame Rate Fundamentals

##### Standard Frame Rates

| Rate | Use Case | Notes |
|------|----------|-------|
| 24 fps | Film/cinema | Exact 24.0 or 23.976 for NTSC |
| 25 fps | PAL video | European broadcast |
| 29.97 fps | NTSC video | American/Japanese (30÷1.001) |
| 30 fps | Non-broadcast HD | Less common |
| 59.94 fps | High-frame NTSC | Sports, slow-mo |
| 60 fps | High-frame non-broadcast | 4K, gaming |

##### Drop-Frame vs Non-Drop-Frame

**Non-Drop-Frame (NDF):**
- Notation: `HH:MM:SS:FF` (all colons)
- Counts every frame sequentially
- Drifts from real time at 29.97 fps

**Drop-Frame (DF):**
- Notation: `HH:MM:SS;FF` (semicolon before frames)
- **Does NOT drop actual frames** - only frame numbers
- Drops frames 00 and 01 at each minute boundary (except every 10th minute)
- Keeps timecode synchronized to wall-clock time

---

#### Part 3: The Critical Relationship - Samples Per Frame

##### Basic Calculation

**Samples Per Frame = Sample Rate ÷ Frame Rate**

| Frame Rate | Samples/Frame at 48kHz | Notes |
|-----------|------------------------|-------|
| 24 fps | 2000 | Exact |
| 25 fps | 1920 | Exact |
| 29.97 fps | **1601.6** | FRACTIONAL |
| 30 fps | 1600 | Exact |
| 59.94 fps | **800.8** | FRACTIONAL |
| 60 fps | 800 | Exact |

##### The Fractional Sample Problem

At 29.97 fps, each frame has 1601.6 samples. Over time:
- 30 frames = 48,048 samples (48 extra)
- 1000 frames = 1,600 extra samples accumulated

**Professional apps MUST track fractional sample accumulation:**

```swift
var accumulatedSamples: Double = 0
for frameNumber in 0..<totalFrames {
    accumulatedSamples += 48000.0 / frameRate
    let samplesThisFrame = Int(accumulatedSamples)
    accumulatedSamples -= Double(samplesThisFrame)
    // Process samplesThisFrame
}
```

##### Why 48 kHz for Video

48,000 is divisible by 24, 25, 30, 50, 60 - eliminating fractional samples for non-NTSC rates.

---

#### Part 4: MTC (MIDI Time Code) Fundamentals

##### MTC Structure

Timecode is encoded as 8 quarter-frame messages:
- Hours (0-23), Minutes (0-59), Seconds (0-59), Frames (0-29)
- Status byte: `0xF1`
- Complete update every 2 video frames

##### Frame Rate Encoding

Embedded in MTC messages using 2-bit field:

| Bits | Frame Rate |
|------|-----------|
| 00 | 24 fps |
| 01 | 25 fps |
| 10 | 30 fps drop-frame |
| 11 | 30 fps non-drop-frame |

##### Professional Sync Performance

- Pro Tools: ±7 samples (≈0.15 ms)
- High-quality synchronizers: ±19 samples (≈0.4 ms)
- Achieved via quarter-frame prediction and PLL filtering

---

#### Part 5: Sample Rate Conversion

##### AVAudioConverter (Recommended)

```swift
let converter = AVAudioConverter(from: inputFormat, to: outputFormat)

converter.convert(to: outputBuffer, error: nil) { packetCount, status in
    // Provide input samples on-demand
    status.pointee = .haveData
    return inputBuffer
}
```

**Use Cases:**
- File sample rate ≠ device sample rate
- Multi-source mixing at different rates
- Real-time playback conversion

##### AVAudioMixerNode (Automatic)

The mixer node handles sample rate conversion automatically:
```swift
engine.connect(player, to: mainMixer, format: fileFormat)  // 44.1kHz
engine.connect(mainMixer, to: outputNode, format: hwFormat)  // 48kHz
// Mixer converts 44.1→48 automatically
```

---

#### Part 6: Drift and Clock Synchronization

##### The Nature of Drift

Clock differences accumulate:
- 0.01% variation = 1.7 seconds drift per hour
- 0.16% (44.1 vs 48 kHz) = 38.4 samples/hour

##### PLL-Based Drift Correction

```swift
actor SyncController {
    private var driftPLL: PhaseLockedLoop

    func updateFromMTC(_ timecode: Timecode, sampleTime: Int64) {
        let expectedSamples = frameToSampleCount(timecode.frameCount, frameRate)
        let drift = sampleTime - Int64(expectedSamples)
        driftPLL.update(drift: drift)

        let rateAdjustment = driftPLL.getPlaybackRateAdjustment()
        // Apply to playback engine
    }
}
```

---

#### Part 7: Common Pitfalls

##### Pitfall 1: Assuming Integer Samples Per Frame

```swift
// ❌ WRONG for 29.97 fps
let samplesPerFrame = 48000 / 30  // = 1600, not 1601.6!

// ✅ CORRECT - Track fractional accumulation
let samplesPerFrame = 48000.0 / 29.97  // = 1601.6...
```

##### Pitfall 2: Hardcoding Frame Rate

```swift
// ❌ WRONG - Assumes 30 fps
let frameRate = 30.0

// ✅ CORRECT - Extract from MTC
let frameRateBits = (mtcQuarterFrame >> 4) & 0x3
let frameRate: Double = switch frameRateBits {
    case 0: 24.0
    case 1: 25.0
    case 2, 3: 29.97
    default: 30.0
}
```

##### Pitfall 3: Not Handling Device Rate Changes

```swift
// ❌ WRONG - Ignores sample rate changes
// App crashes or glitches

// ✅ CORRECT - Listen and reconfigure
AudioUnitAddPropertyListener(audioUnit, kAudioUnitProperty_SampleRate, ...)

func handleSampleRateChange() {
    stopAudioEngine()
    reconfigureForNewSampleRate()
    startAudioEngine()
}
```

##### Pitfall 4: Drop-Frame Misunderstanding

```swift
// ❌ WRONG - Thinking DF drops actual frames
// "Drop-frame skips video frames" - FALSE!

// ✅ CORRECT - DF only drops FRAME NUMBERS
// Frames 00, 01 are skipped in numbering at minute boundaries
// (except every 10th minute)
// All actual video frames are present
```

---

#### Part 8: Professional Standards

| Application | Sample Rate | Frame Rate | Buffer Size | Sync |
|------------|-------------|-----------|-------------|------|
| Film editing | 48 kHz | 24 fps | 1024-4096 | MTC/LTC |
| Broadcast PAL | 48 kHz | 25 fps | 1024-2048 | MTC |
| Broadcast NTSC | 48 kHz | 29.97 fps (DF) | 1024-2048 | MTC |
| Live streaming | 48 kHz | 29.97/59.94 fps | 512-1024 | Network TC |

---

#### Part 9: Projector Implementation Pattern

##### Sample Rate Policy

1. **Project initialization**: Default 48 kHz
2. **Device detection**: Query actual device rate
3. **Mismatch handling**: Create AVAudioConverter, warn user
4. **Mid-playback changes**: Pause → reconfigure → resume

##### Frame-to-Sample Conversion

```swift
func frameToSampleCount(_ frameCount: Int, frameRate: Double, sampleRate: Int = 48000) -> Int {
    // Handle fractional samples correctly
    let accumulatedSamples = Int64(frameCount) * Int64(sampleRate)
    return Int(accumulatedSamples / Int64(Int(frameRate * 1000)) * 1000)
}
```

---

#### Sources

- [TN3136: AVAudioConverter - Sample Rate Conversions](https://developer.apple.com/documentation/technotes/tn3136)
- [Sound on Sound - SMPTE & MTC](https://www.soundonsound.com/techniques/smpte-mtc-midi-code)
- [David Heidelberger - Drop-Frame Timecode](https://www.davidheidelberger.com/2010/06/10/drop-frame-timecode/)
- [Wikipedia - MIDI Timecode](https://en.wikipedia.org/wiki/MIDI_timecode)
- [Sound Devices - Sample Rate and Frame Rate Settings](https://www.sounddevices.com/sample-rate-and-frame-rate-settings-for-production-sound/)

---

### GP-023: Xcode project.pbxproj Target Identification Protocol
**Added**: 2026-01-18
**Source**: Post-mortem from cue sheet feature implementation
**Category**: Build System, Developer Experience

#### Problem
When programmatically adding files to an Xcode project, files may be added to the wrong target (e.g., UITests instead of main app). This causes "Cannot find type in scope" build errors even though files exist on disk and appear in the project.

**Root Cause**: Xcode projects have MULTIPLE `PBXSourcesBuildPhase` sections - one per target. The UITests phase may appear BEFORE the main app phase in the file. Searching for "first PBXSourcesBuildPhase" grabs the wrong one.

#### Solution
Always follow the Target → buildPhases → Sources chain:

```
PBXNativeTarget (find by name or productType)
        ↓
   buildPhases array (from target object)
        ↓
   buildPhases[0] = Sources phase ID (always first)
        ↓
PBXSourcesBuildPhase (look up by that specific ID)
        ↓
   files array (add your build file reference here)
```

#### Target Types (productType field)

| productType | Target Kind |
|-------------|-------------|
| `com.apple.product-type.application` | Main App (use this!) |
| `com.apple.product-type.bundle.unit-test` | Unit Tests |
| `com.apple.product-type.bundle.ui-testing` | UI Tests |
| `com.apple.product-type.app-extension` | App Extension |

#### Correct Implementation

```python
def add_file_to_main_app(project_path, file_path):
    content = read_pbxproj(project_path)

    # Step 1: Find main app target by productType
    target = find_native_target(content,
        productType="com.apple.product-type.application")

    # Step 2: Get Sources phase ID (ALWAYS first in buildPhases)
    sources_phase_id = target.buildPhases[0]

    # Step 3: Find that specific PBXSourcesBuildPhase by ID
    sources_phase = find_sources_phase(content, sources_phase_id)

    # Step 4: Add file to that phase's files array
    sources_phase.files.append(new_build_file_id)
```

#### Projector-Specific Reference

```
Target: Projector (main app)
  productType: com.apple.product-type.application
  buildPhases[0]: A1000001227D3F000000000C  ← CORRECT Sources phase

Target: ProjectorUITests (DO NOT USE)
  productType: com.apple.product-type.bundle.ui-testing
  buildPhases[0]: 50F3CF58997D9E2F0BCEE6AD  ← Listed first in file!
```

#### Anti-Pattern (What Causes Failures)

```python
# ❌ NEVER DO THIS
for phase in all_sources_phases:
    phase.files.append(file)  # Wrong! Grabs first found (UITests)

# ❌ ALSO WRONG
sources_pattern = r'PBXSourcesBuildPhase.*?files = \('
first_match = re.search(sources_pattern, content)  # UITests!
```

#### Verification Steps

After adding files:
1. `grep "YourFile.swift in Sources" project.pbxproj` - should appear once
2. Check the line number - should be in the A1000001227D3F000000000C phase (around line 746+)
3. Build in Xcode - "Cannot find type" means wrong target

#### Related Files
- `~/.claude/xcode-reference.md` - Comprehensive Xcode reference
- `Projector.xcodeproj/project.pbxproj` - Project configuration

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
**Updated**: 2026-01-06 (solution implemented via GP-012)
**Discovered**: Architectural standards
**Severity**: Medium

#### The Mistake
```swift
// ❌ PROHIBITED
let height = 120.0  // What is this?
let frameRate = 29.97  // Where did this come from?
.frame(width: 120, height: 60)  // Duplicated across files
```

#### Why It's Wrong
Magic numbers make code incomprehensible and error-prone. They hide intent, make refactoring dangerous, and lead to inconsistencies when the same value is duplicated across files.

#### The Fix
```swift
// ✅ CORRECT - Use centralized LayoutConstants.swift (see GP-012)
.frame(width: TimelineLayout.headerWidth, height: TimelineLayout.audioLaneHeight)

// For frame rates and other domain constants
enum FrameRate {
    static let ntscDropFrame: Double = 29.97
}
```

#### Resolution
This anti-pattern is now addressed by **GP-012: Centralized Layout Constants**. All layout values should be defined in `Projector/Utilities/LayoutConstants.swift` using domain-specific enums.

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

### GP-024: Menu-Based Action Trigger with Capability Check
**Added**: 2026-01-19
**Source**: `Projector/Views/CueSheet/CuesPanelView.swift:390-420`
**Category**: UI

#### Problem
When offering menu actions that depend on external resources (async-loaded data), users see actions that can't be completed, leading to confusion. The UI should communicate resource availability clearly.

#### Solution
Implement a menu that:
1. Checks resource availability before rendering each option
2. Displays resource state in the label (e.g., "Loading...")
3. Disables options when prerequisites aren't met

```swift
private var detectCuesMenu: some View {
    Menu {
        let audioClips = allAudioClips
        if audioClips.isEmpty {
            Text("No audio clips")
        } else {
            ForEach(audioClips, id: \.clip.id) { item in
                let hasWaveform = waveformCache.clipAtlases[item.clip.id] != nil
                Button {
                    detectCuesFromClip(item.clip)
                } label: {
                    if hasWaveform {
                        Text("\(item.clip.displayName) (Lane \(item.laneIndex + 1))")
                    } else {
                        Text("\(item.clip.displayName) (Loading...)")
                    }
                }
                .disabled(!hasWaveform)
            }
        }
    } label: {
        HStack(spacing: 4) {
            Image(systemName: "waveform.circle")
            Text("Detect...")
        }
    }
}
```

#### Why It Works
- **Availability Check**: `hasWaveform` queries the cache to verify prerequisites
- **Status Feedback**: Showing "(Loading...)" manages user expectations
- **Disabling**: `.disabled(!hasWaveform)` prevents invalid operations
- **No Polling**: Relies on already-computed cache state, no extra async calls

#### When to Use
- Menu actions that depend on background-loaded resources
- Actions requiring specific data availability
- User guidance in progressive disclosure UIs
- Any case where capabilities vary by item

#### Related Files
- `Projector/Views/CueSheet/CuesPanelView.swift`
- `Projector/Managers/WaveformCache.swift`

---

### GP-025: Reusing Infrastructure for New Features
**Added**: 2026-01-19
**Source**: Cue detection UI implementation (feature/cue-sheet-from-audio)
**Category**: Architecture

#### Problem
New features often tempt developers to create new protocols, services, and UI dialogs, leading to code bloat and maintenance burden. This violates the DRY principle.

#### Solution
When implementing a new feature, audit existing infrastructure first:

**What Already Exists** → **How It's Reused**
- `TimelineManager` (existing contract) → Added `importDetectedCues()` method to existing protocol
- `SilenceDetectionService` (existing) → Reused for cue detection algorithm
- `DetectedCueListView` (existing) → Already implements the UI for review/import
- `WaveformCache` (existing) → Dependency injected into views that need it

**Code Added to CuesPanelView**:
```swift
struct CuesPanelView: View {
    @ObservedObject var timelineManager: TimelineManager
    let waveformCache: WaveformCache  // ← Added dependency
    // ... existing properties ...
}

// Later, in actions:
private func detectCuesFromClip(_ clip: AudioClip) {
    guard let atlas = waveformCache.clipAtlases[clip.id],
          let level = atlas.levels[4096] ?? atlas.levels.values.first else {
        return
    }

    detectedCues = SilenceDetectionService.detectCues(
        from: level,
        clipStartFrame: clip.timelineStartFrame,
        clipDurationFrames: clip.durationFrames,
        timelineConfig: timelineManager.timeline.config
    )
    detectedCuesClipName = clip.displayName
    showDetectedCuesSheet = true  // Reuse existing view
}
```

#### Why It Works
- **Minimal new code**: Only menu integration + detection trigger
- **Proven services**: Reuses already-tested detection logic
- **Dependency injection**: Passes `waveformCache` through view hierarchy
- **No new protocols**: Works within existing `TimelineManager` contract
- **Faster delivery**: Feature ships with less code, easier testing

#### Key Insight
**Question to ask**: "What does this feature actually *add* that doesn't exist yet?"
- Detection algorithm? No, `SilenceDetectionService` exists.
- Cue import UI? No, `DetectedCueListView` exists.
- Waveform data? No, `WaveformCache` exists.
- What's *actually* new? Just the UI trigger (menu in `CuesPanelView`).

This keeps features small, focused, and maintainable.

#### When to Use
- Feature involves multiple systems (audio, UI, state management)
- New protocol or service temptation arises
- Audit step: "Is there already a service that does this?"

#### Related Files
- `Projector/Views/CueSheet/CuesPanelView.swift`
- `Projector/Managers/SilenceDetectionService.swift`
- `Projector/Managers/TimelineManager.swift`
- `Projector/Views/CueSheet/DetectedCueListView.swift`

---

### GP-026: Dependency Injection Through View Hierarchy
**Added**: 2026-01-19
**Source**: `Projector/Views/CueSheet/CuesPanelView.swift`
**Category**: Architecture

#### Problem
Views that need resources (like `WaveformCache`) often try to create their own instances or access singletons, violating the contract pattern and making testing difficult.

#### Solution
Pass dependencies through the view hierarchy as explicit parameters:

```swift
// In ContentView or parent
CuesPanelView(
    timelineManager: timelineManager,
    waveformCache: waveformCache,  // ← Explicitly passed
    onSeekToCue: { ... },
    onPopOut: { ... }
)

// In CuesPanelView
struct CuesPanelView: View {
    @ObservedObject var timelineManager: TimelineManager
    let waveformCache: WaveformCache  // ← Stored as property

    // Can now use in methods:
    private func detectCuesFromClip(_ clip: AudioClip) {
        guard let atlas = waveformCache.clipAtlases[clip.id] else { return }
        // ...
    }
}
```

#### Why It Works
- **Testability**: Easy to inject test doubles in previews/tests
- **Clarity**: View contract explicitly lists all dependencies
- **No side effects**: View doesn't create or mutate global state
- **Preview support**: Previews can pass mock caches
- **Compile-time checking**: Missing dependencies cause build errors, not runtime crashes

#### When to Use
- Any resource needed by multiple views
- Views that perform operations (like cue detection)
- Services with state (like caches, managers)
- Tests and previews that need to isolate behavior

#### Anti-Pattern (What NOT to Do)
```swift
// ❌ DON'T: Access singleton
class CuesPanelView {
    let cache = WaveformCache.shared  // Violates contract
}

// ❌ DON'T: Create new instances
struct CuesPanelView {
    let cache = WaveformCache()  // Separate cache, data won't sync
}
```

#### Related Files
- `Projector/Views/CueSheet/CuesPanelView.swift`
- `Projector/Managers/WaveformCache.swift`

---

## Contributing to This Document

When adding new entries:

1. **Golden Patterns**: Must cite source file or commit
2. **Anti-Patterns**: Must include incident reference
3. **MTC/MMC Standards**: Must cite MIDI spec section
4. **Lessons Learned**: Must include date and commit hash

Use The Librarian agent to maintain this document.
