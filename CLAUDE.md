# Projector - Claude Code Instructions

## Pro-Grade macOS Team

This project follows **Airtight Standards** with a fully automated agent workflow. All code contributions must comply with these standards.

---

## AUTOMATION CHAIN

**MANDATORY**: Follow this chain for EVERY request:

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
│     └─ ⚠️  3RD-PARTY GATE: Read library docs BEFORE any external API use   │
│                              ↓                                               │
│  4. AUDIT (qa-auditor)                                                      │
│     └─ DocC coverage, edge cases, thread safety, standards                  │
│                              ↓                                               │
│  5. ROADMAP & PUSH (the-lead)                                              │
│     └─ Update PROJECT_ROADMAP.md, git commit (after QA approval)           │
│                              ↓                                               │
│  6. REGISTER (the-lead)                                                     │
│     └─ Add/update feature entry in FEATURES.md                             │
│                              ↓                                               │
│  7. LEARN (the-librarian)                                                   │
│     └─ Capture Golden Patterns in KNOWLEDGE_BASE.md                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Multi-Agent System

Agents are located in `.claude/agents/`:

| Agent | Description | Scope |
|-------|-------------|-------|
| `the-lead.md` | **PROACTIVE**: Maintains PROJECT_ROADMAP.md and FEATURES.md. Must update roadmap checkpoints and feature registry after every successful implementation before session ends | Project-wide |
| `arch-architect.md` | MUST BE USED to plan technical designs and thread-safety strategies for MTC/MMC logic | Architecture |
| `backend-logic.md` | MUST BE USED for all MIDI, MTC, MMC, and AVFoundation logic. No SwiftUI imports allowed | `Managers/` |
| `ui-specialist.md` | MUST BE USED for all SwiftUI/AppKit layouts. Must follow macOS HIG | `Views/` |
| `scope-guard.md` | MUST BE USED to strip 'feature creep' from plans and code | All files |
| `qa-auditor.md` | MUST BE USED to audit file changes for DocC, edge-cases, and logic safety before committing | All files |
| `the-librarian.md` | MUST BE USED after tasks to record 'Golden Patterns' into KNOWLEDGE_BASE.md | Documentation |
| `coroner.md` | **MUST BE INVOKED** when any unexpected issue occurs. Performs forensic analysis to determine root cause and prevent recurrence | Post-mortems |
| `surgeon.md` | Implements Lead-approved fixes from Coroner reports. Executes precise, surgical changes with full documentation | Fix Implementation |

---

## The Two-Layer Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PRESENTATION LAYER                                    │
│                       (ui-specialist domain)                                │
│                                                                              │
│   SwiftUI Views  ──▶  ViewModels (@MainActor)  ──▶  Consumes THE CONTRACT   │
│                                                                              │
├──────────────────────────────── THE CONTRACT ───────────────────────────────┤
│   ╔═══════════════════════════════════════════════════════════════════════╗ │
│   ║  Protocols + AsyncStreams + Sendable Types                            ║ │
│   ║  • Defined by: arch-architect (REQUIRED BEFORE ANY CODE)             ║ │
│   ║  • Implemented by: backend-logic                                      ║ │
│   ║  • Consumed by: ui-specialist                                         ║ │
│   ╚═══════════════════════════════════════════════════════════════════════╝ │
├─────────────────────────────────────────────────────────────────────────────┤
│                           LOGIC LAYER                                        │
│                      (backend-logic domain)                                 │
│                                                                              │
│   Swift Actors  ◀──  CoreMIDI/CoreAudio  ◀──  Real-time Callbacks          │
│   (NO SwiftUI imports allowed)                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

**THE CONTRACT is MANDATORY**: No cross-layer code is written without `arch-architect` first defining the protocol.

---

## Anti-Hallucination Protocol

**ALL agents and contributors MUST follow this protocol:**

1. **NEVER guess** Apple API signatures, parameters, or behaviors
2. **ALWAYS verify** using:
   - `WebSearch` for official Apple documentation
   - `WebFetch` on developer.apple.com URLs
   - Ask the user for documentation if uncertain
3. **When uncertain**, explicitly state: "I need to verify the API for [X]"
4. **Document assumptions** with `// TODO: Verify API` if time-critical

---

## Airtight Standards

### 1. Swift Concurrency (Actors) for MIDI/Transport

**REQUIRED**: All MIDI and transport logic MUST use Swift Actors for thread safety.

```swift
// CORRECT: Actor isolation for MIDI state
actor MIDITransportActor {
    private var isPlaying = false
    private var currentTimecode: Timecode?

    func handleMTCQuarterFrame(_ qf: MTC.QuarterFrame) async {
        // Safe, isolated state mutation
    }
}

// INCORRECT: @MainActor blocks UI during MIDI processing
@MainActor
class MIDIManager: ObservableObject { // ❌ VIOLATES STANDARDS
    func processMIDI() { } // Blocks main thread
}
```

### 2. Strict Layer Separation

**REQUIRED**: Enforce clear boundaries between UI and business logic.

| Layer | Allowed Imports | Forbidden Imports |
|-------|-----------------|-------------------|
| **UI** (Views) | SwiftUI, AppKit, Combine | CoreMIDI, CoreAudio, AVFoundation* |
| **Logic** (Managers) | Foundation, CoreMIDI, CoreAudio, AVFoundation | SwiftUI |

*AVFoundation allowed in UI only for AVPlayerLayer via NSViewRepresentable

### 3. 100% DocC Documentation

**REQUIRED**: Every public function and type MUST have complete DocC documentation.

```swift
/// Parses MTC quarter-frame data into a timecode piece.
///
/// - Parameter data: Raw MIDI byte from quarter-frame message
/// - Returns: The decoded MTC piece with type and value
/// - Note: Thread-safe, can be called from MIDI callback
public func parse(_ data: UInt8) -> MTCPiece
```

### 4. No Magic Numbers

**REQUIRED**: Use named constants for all values.

```swift
// ❌ FORBIDDEN
let threshold = 3

// ✅ REQUIRED
enum SyncConstants {
    static let maxDriftFrames = 3
}
```

---

## Performance Rules

1. **NO single-tap gestures in scrollable content** - Causes trackpad scroll delay
2. **Use `.drawingGroup()`** for complex graphics (waveforms, thumbnails)
3. **Avoid nested ScrollViews** - Known macOS trackpad issues
4. **Keep view bodies pure** - No side effects, no heavy computation
5. **Pre-sort in ViewModels** - Never sort in view body

---

## Dangerous SwiftUI Patterns (Learned the Hard Way)

### NEVER: Use `.id()` on Async-Loading Views

```swift
// ❌ DANGEROUS: Destroys async-loading view on every change
WaveformView(audioURL: url, configuration: config)
    .id(clipWidth)  // View destroyed and recreated on EVERY zoom change
                    // Async loading never completes!

// ✅ CORRECT: Use explicit .frame() - view updates without destruction
WaveformView(audioURL: url, configuration: config)
    .frame(width: clipWidth, height: waveformHeight)
```

**Why**: `.id()` destroys the entire view and recreates it from scratch. For views that load data asynchronously (like `WaveformView`), this means the loading restarts every time the id changes, and the view never renders.

**Safe alternatives**:
- Use `.frame()` with dynamic dimensions
- Use `@State` to track loading completion
- Only use `.id()` when you intentionally want to reset all state

### ALWAYS: Read 3rd-Party Library Docs First

Before using ANY external SwiftUI view:
1. Check if it needs explicit `.frame()`
2. Check if it loads data asynchronously
3. Look at the library's example code
4. Test with the library's documented patterns first

**Forensic source**: Waveform rendering failure (2026-01-02) - see `coroner.md` for full autopsy

---

## Project Files

| File | Purpose | Owner |
|------|---------|-------|
| `CLAUDE.md` | Standards and workflow | All agents |
| `PROJECT_ROADMAP.md` | Progress tracking | the-lead |
| `FEATURES.md` | Feature registry with files, state, and integration points | the-lead |
| `KNOWLEDGE_BASE.md` | Patterns and lessons | the-librarian |

---

## Feature Registry

**MANDATORY**: Every feature must be documented in `FEATURES.md`.

When **adding** a feature:
1. Create entry using the template in FEATURES.md
2. List ALL files created (models, views, services, utilities)
3. Document ALL state properties added to parent views
4. Document ALL integration points (existing code modified)
5. List layout constants added

When **removing** a feature:
1. Use the feature entry as a removal checklist
2. Move entry to "Removed Features" section
3. Update status and removal date
4. Clean build and verify

**Why**: Without a registry, removing features requires manual archaeology. The registry ensures clean removal, impact analysis, and maintainability.

---

## Known Issues

### Document Icon for .projector Files

**Status**: Icon configured but not appearing in Finder after logout/login

**What's Done**:
- DocumentIcon in asset catalog with logo at 1x, 2x, 3x
- Info.plist has UTTypeIconName = "DocumentIcon"
- App in /Applications and registered with Launch Services
