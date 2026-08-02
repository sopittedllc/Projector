# Projector - Claude Code Instructions

## Pro-Grade macOS Team

This project follows **Airtight Standards** with a fully automated agent workflow. All code contributions must comply with these standards.

---

## Core Operating Principle

**NEVER do anything just to please the user or to accomplish a quick "win".**

All goals must serve the broader plan and the user's actual workflow needs. This means:

1. **No appeasement fixes**: Don't make small patches just to show progress. If something needs fixing, understand the root cause and fix it properly.

2. **No improvisation**: Use the agent architecture. Run audits. Follow the workflow. Don't skip steps to appear faster.

3. **No cosmetic wins**: A "completed" task that doesn't serve the user's actual workflow is worse than an incomplete task that does.

4. **Question the request**: If a user asks for X, first ask whether X actually solves their underlying need. The user's workflow (import → optimize → place → sync) is the north star, not individual feature requests.

5. **Plans are working documents**: Plans exist to guide implementation, not to satisfy review. If a plan doesn't have technical details, acceptance criteria, and resume instructions, it's not a real plan.

**Why this matters**: AI assistants have a tendency to optimize for perceived approval rather than actual value. This principle explicitly rejects that pattern.

---

## AUTOMATION CHAIN

**MANDATORY**: Follow this chain for EVERY request:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PRO-GRADE WORKFLOW                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. RESEARCH (thomas)                                                       │
│     └─ Look up docs, check local files first, cite sources                 │
│                              ↓                                               │
│  2. IMPLEMENT (joseph)                                                      │
│     └─ Write code from approved plans, NO scope creep                      │
│     └─ ⚠️  3RD-PARTY GATE: Read library docs BEFORE any external API use   │
│                              ↓                                               │
│  3. REVIEW (clare)                                                          │
│     └─ Read-only code review against CLAUDE.md standards                   │
│                              ↓                                               │
│  4. QA (gabriel)                                                            │
│     └─ Dispatches clare + cecilia as needed                                │
│                              ↓                                               │
│  5. 🚨 USER VERIFICATION (for UI changes)                                   │
│     └─ User must RUN THE APP and verify:                                    │
│        • Click new/modified buttons - correct behavior?                     │
│        • Test drag-drop flows - right dialogs appear?                       │
│        • Check visual layout - alignment, spacing, styling?                 │
│        • Dismiss dialogs/banners - do they stay dismissed?                  │
│     └─ ⚠️  CODE AUDITS CANNOT REPLACE RUNTIME TESTING                       │
│                              ↓                                               │
│  6. COMMIT (after USER approval)                                            │
│     └─ Git commit with proper message                                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### ⚠️ CRITICAL: Code Audits vs Runtime Testing

**Code audits (clare) check:**
- Syntax, types, layer violations, documentation

**Code audits CANNOT check:**
- Whether clicking a button shows the right dialog
- Whether UI elements are visually aligned
- Whether dialogs stay dismissed after user closes them
- Whether drag-drop flows work end-to-end

**No UI feature is complete until the user runs the app and verifies it works.**

---

## Multi-Agent System

Agents are located in `.claude/agents/`:

| Agent | Description | Scope |
|-------|-------------|-------|
| `thomas.md` | Research agent. Checks local docs first, then web. Cites everything. | Research |
| `clare.md` | Read-only code reviewer. Reviews against CLAUDE.md standards, reports findings. | Code review |
| `joseph.md` | Implementer. Writes code from approved plans. Does NOT expand scope. | Implementation |
| `gabriel.md` | QA dispatcher. Figures out what QA is needed and runs appropriate checks. | QA gate |
| `cecilia.md` | Blind product tester. Tests running app against holdout criteria. | Product testing |
| `isidore.md` | Repository janitor. Git diagnostics, stale branches, sync status. | Maintenance |

---

## The Two-Layer Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PRESENTATION LAYER                                    │
│                                                                              │
│   SwiftUI Views  ──▶  ViewModels (@MainActor)  ──▶  Consumes Protocols     │
│                                                                              │
├──────────────────────────────── THE CONTRACT ───────────────────────────────┤
│   ╔═══════════════════════════════════════════════════════════════════════╗ │
│   ║  Protocols + AsyncStreams + Sendable Types                            ║ │
│   ║  • Define contracts BEFORE implementation                             ║ │
│   ║  • Managers implement protocols                                       ║ │
│   ║  • Views consume protocols via ViewModels                             ║ │
│   ╚═══════════════════════════════════════════════════════════════════════╝ │
├─────────────────────────────────────────────────────────────────────────────┤
│                           LOGIC LAYER                                        │
│                                                                              │
│   Swift Actors  ◀──  CoreMIDI/CoreAudio  ◀──  Real-time Callbacks          │
│   (NO SwiftUI imports allowed)                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

**THE CONTRACT is MANDATORY**: Define protocols before implementing cross-layer code.

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

## UI Audit Checklist (MANDATORY for Production Audits)

**LESSON LEARNED**: Backend code audits catch runtime bugs. UI audits catch UX bugs. **Both are required.**

When auditing for production readiness, check:

### 1. Spacing Consistency
```bash
# Find hardcoded padding (should use Spacing.xs/sm/md/lg/xl/xxl)
grep -rn "padding.*[0-9])" Views/
grep -rn "\.frame(width: [0-9]" Views/
```
- All padding should use `Spacing.xs` (4pt), `Spacing.sm` (8pt), `Spacing.md` (12pt), `Spacing.lg` (16pt), `Spacing.xl` (20pt), `Spacing.xxl` (24pt)
- No magic numbers: 3, 6, 10 are **forbidden**

### 2. Alignment
- Compare left padding of panel headers vs content headers
- Track/lane headers should match accordion header padding
- Empty states should use `.frame(maxWidth: .infinity)` not `.offset()`

### 3. Edge Margins
- All controls must have proper edge padding (not flush to container edge)
- Toolbars need trailing padding on rightmost control
- Footer/hint text needs consistent horizontal padding

### 4. macOS HIG Compliance
- Icon sizes: 16pt (secondary), 18pt (standard), 20pt (prominent), 24pt (large)
- Touch targets: 44pt minimum
- 4pt grid system respected

### 5. Visual Inspection (MANDATORY - NOT OPTIONAL)
**STOP. Build and run the app. Check these visually:**

- [ ] **Symmetric padding**: Top padding matches bottom padding in all content areas
- [ ] **Centered content**: Empty states are visually centered (not just code-centered)
- [ ] **Panel headers align**: Headers across different panels align horizontally
- [ ] **Breathing room**: Controls have space from all edges (not cramped)
- [ ] **Consistent gaps**: Space between sections is uniform throughout

**If you skip this step, you WILL miss obvious issues that code review cannot catch.**

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

**Forensic source**: Waveform rendering failure (2026-01-02)

---

## Project Files

| File | Purpose |
|------|---------|
| `CLAUDE.md` | Standards and workflow |
| `PROJECT_ROADMAP.md` | Progress tracking |
| `FEATURES.md` | Feature registry with files, state, and integration points |
| `KNOWLEDGE_BASE.md` | Patterns and lessons |
| `.claude/SESSION_STATE.md` | Real-time session tracking (survives crashes) |

---

## Session State Tracking (Crash Recovery)

**PURPOSE**: Ensure work survives terminal crashes, disconnects, and context compaction.

### File: `.claude/SESSION_STATE.md`

This file is **updated in real-time** during work and contains:
- Current task being worked on
- Active todos
- Modified files (uncommitted)
- Context for resume
- Session history

### MANDATORY: Update Session State

**Update `.claude/SESSION_STATE.md` at these checkpoints:**

1. **Session Start**: Set status to `ACTIVE`, record current task
2. **After Each Significant Action**: Update modified files, completed items
3. **Before Long Operations**: Record what you're about to do
4. **Session End**: Set status to `IDLE`, summarize completions

### Template for Session State Updates

```markdown
## Current Task

**Task**: [What you're working on]
**Started**: [Timestamp]
**Files**: [Files being modified]

## Active Todos

- [ ] Todo 1
- [x] Todo 2 (completed)
```

### Resume from Crash

**CLI Command** (run from project root):
```bash
.claude/resume
```

**Or paste this into new Claude Code session:**
```
Resume from .claude/SESSION_STATE.md - read it, summarize status, continue work.
```

### Why This Matters

- **Terminal crash**: SESSION_STATE.md persists on disk
- **Context compaction**: File contains full context to resume
- **Session timeout**: Instant context recovery vs. archaeology

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

### ~~Only the First Audio Track of a Video Is Imported~~ (RESOLVED)

**Status**: Resolved. Implemented per-track extraction for tracks 1+ while
keeping track 0 playing directly from the video container.

**Solution**: Videos with multiple audio tracks now create one lane per track.
Track 0 plays directly via `AVAudioFile`. Tracks 1+ are extracted to temporary
CAF files using `AVAssetReader`/`AVAssetWriter` in `AudioTrackExtractor`, then
played via `extractedAudioURL`. Extraction happens in the background after
import; clips are playable once extraction completes. Lane headers show track
names when there are multiple audio tracks. Extracted files are cleaned up when
the video reel is removed.

**Files changed**:
- `Managers/AudioTrackExtractor.swift` (new) - extraction service
- `Views/ContentView+Timeline.swift` - `prepareAudioLanesForAllTracks()`
- `Managers/PlaybackEngine.swift` - uses `extractedAudioURL` for tracks 1+
- `Managers/TimelineManager.swift` - cleanup and `updateExtractedAudioURL()`
- `Views/Timeline/MultiTrackTimelineView.swift` - shows track labels

### Document Icon for .projector Files

**Status**: Icon configured but not appearing in Finder after logout/login

**What's Done**:
- DocumentIcon in asset catalog with logo at 1x, 2x, 3x
- Info.plist has UTTypeIconName = "DocumentIcon"
- App in /Applications and registered with Launch Services
