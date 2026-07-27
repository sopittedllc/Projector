# Session State

> **Last Updated**: 2026-07-26
> **Status**: IDLE — stopping point, all work committed and building
> **Branch**: codex/repair-sync-core

---

## Where we left off

A long UI/UX session. The main window was reorganised into a two-row layout, MTC sync was
debugged end to end, and the video's baked-in audio became part of a combined "Video File"
track. Everything below is committed and builds. Nothing is half-applied.

---

## The two authorities (read before touching layout or routing)

Both are written as numbered rules in code comments. They exist because the same class of bug
kept returning one instance at a time. **Extend the rules rather than adding a special case.**

### 1. Window sizing — `ContentView+Helpers.swift`, `syncWindowToContent()`

Seven rules, summarised: height follows content (`max(video column, panel stack)` clamped to
`[minimumHeight, screen]`); width is defended by `mainWindowMinWidth` and never adjusted here;
the panel stack scrolls **only** once the window hits the screen ceiling; a stale scroll offset
is a bug, so it is re-normalised after every resize; the video column is fixed; panels are
bounded so the window rarely needs to scroll at all.

Two traps already paid for:

- **Never resize the window synchronously from inside a SwiftUI update.**
  `setFrame(animate: true)` spins a nested run loop, re-enters the view graph mid-layout and
  **segfaults**. The function defers to the next runloop turn and uses `window.animator()`.
  There is a crash report from exactly this path.
- **Rule 6's test reads the window, never the content.** Asking "is the content taller than the
  viewport" is circular — that height is measured *inside* the scroll view, so disabling
  scrolling makes the content report as fitting, which keeps it disabled. That left a full
  timeline unscrollable with its top cut off.

### 2. Audio routing — `TimelineManager.swift`, `reconcileOutputMappings(with:)`

Names are never copied (the menu reads the current name from Settings, so renaming a mapping
retitles every lane using it); a lane keeps its mapping while it exists; if a mapping
disappears, re-bind by **channel range** — this is what survives an interface change;
otherwise clear it rather than silently routing somewhere the user did not choose.

---

## Layout model (sizes derive from constants — do not hardcode)

```
┌─────────────────────┬────────────────────────────┐
│  video 480x270      │  Media (2 fixed rows)      │  topRowHeight = 306
│  ─────────────────  │                            │
│  [Settings]  [FPS][stop][full][popout]  36pt     │
├─────────────────────┴────────────────────────────┤
│  Timeline — full width, set height, scrolls      │  defaultHeight ~409
└──────────────────────────────────────────────────┘
```

- Both top-row columns are framed to `MainWindowLayout.topRowHeight`. Their bottoms align
  because they are *told the same number*, not because one is derived from the other's
  internals — that earlier approach broke the moment the optimization banner appeared.
- `inlineVideoHeight` is derived: `topRowHeight - videoControlsBarHeight`. 480x270 is exactly
  16:9, so the picture fills the column with no letterboxing.
- The Timeline is a **constant** height (Video File track + 3 audio lanes); further lanes
  scroll inside it. `resizeToFitLanes` was **removed** — it shrank the panel below the default
  with fewer than three lanes, so adding lanes made the timeline briefly *shorter* and the
  window followed it down. Measured: 0 lanes → 409, 2 lanes → 328, 4 lanes → 409.
- Settings is an overlay (gear button, far left of the video controls), not a panel.
- Media and Timeline no longer collapse. `TimelineViewModel.isExpanded` is permanently true,
  kept only so older project files still decode.

### SwiftUI trap that bit us three times

**A bare `.frame(...)` centres by default.** It produced: the collapsed Media panel showing the
middle of its file list; the Media panel centring horizontally; and the timeline tracks
floating mid-panel on an empty project. Always pass `alignment:`.

---

## Combined "Video File" track

One lane holds the video **and** its baked-in audio, with reels laid along it.

- Identified by `Timeline.videoAudioLane` — derived (every clip `sourceType == .videoTrack`),
  not stored, so no project-file migration. `standaloneAudioLanes` excludes it.
- Rendered as the picture (60pt) plus a 20pt audio strip directly beneath, no divider between.
  The strip reuses `AudioLaneView` via its `laneHeight` / `showsHeader` parameters.
- Mute/Solo/rate/Output controls live in the **video header**, through the shared
  `AudioLaneControls`. One implementation only — an earlier partial extraction left two copies
  that immediately drifted in styling.
- Drops onto the strip are refused; deletion is symmetric via `deleteVideoFileTrack()`.
- `isVideoAudioExpanded` exists and is permanently true — there is no disclosure control.
  Dead state; remove it next time that file is open.

---

## Drop → lane creation (subtle, recently fixed)

Lanes must exist *before* a placement dialog opens (placement needs a lane to target; a batch
needs identities to work out ordering). So every site that creates a lane **pre-dialog**
registers it in `batchCreatedLaneIds`, and all three cancel paths call
`discardLanesCreatedForCancelledDrop()`, which removes only **empty** lanes.

- Registered (pre-dialog): `handleAudioDropOnTimeline`, single-audio import, batch video
  embedded-audio reservation, batch standalone-audio lanes.
- Not registered (created *during* placement, after confirmation): `prepareAudioLaneIfNeeded`,
  the overlap-spill lane, and the two fallbacks in `addAudioToTimelineAvoidingOverlap`.

Getting this wrong is invisible until you cancel. Three separate fixes were needed because
each drop type takes a different route — **instrument the specific route rather than reasoning
about the code.**

---

## MTC / MMC sync

- `MIDISyncActor` logs via `midiLog`, **not** `debugPrint` — the latter collides with the
  stdlib overload, whose output is buffered to stdout and silently lost.
- Frame rate comes from `mtcReceiver.mtcFrameRate.directEquivalentFrameRate` (the sender's
  rate), not `timecode.frameRate` (the converted one) — the latter flapped between 24 and 25.
- A 500ms heartbeat drives `emitState()` so `decayIncomingSignalIfStale()` can fire. Without it
  the readout held its last timecode behind a green "live" dot indefinitely, because the decay
  was only reachable from event-driven emissions.
- Spacebar is disabled while `isExternallyControlled` (MTC or MMC within 2s). Beat clock does
  **not** count as control — it carries tempo, not position.

### The "transport isn't playing" saga — do not repeat

The engine was correct throughout. What was actually wrong: no numeric position readout existed
(`TransportBarView` was referenced only by its own `#Preview`), and the playhead moved
**0.057pt/sec** at fit zoom on a 4-hour timeline — roughly one pixel every 18 seconds. Fixed by
a POS readout, zoom that reaches frame level at any duration (geometric, targeting 4px/frame),
playhead-follow, and a 1-hour default duration.

---

## Verification habit that worked

`scratchpad/mtcsend.swift` drives real MTC into the app over CoreMIDI, and temporary probe
flags (`-probe-lanes`, `-probe-collapse`, all removed) drove UI state on a timer so behaviour
could be measured without manual interaction. Several bugs this session were misdiagnosed from
reading code and only settled by measurement. **When a layout or sync claim is uncertain,
instrument it and read the numbers.**

---

## Open work

**Task #24 — defer batch lane creation until the sheet is confirmed.**
Lanes are still created before the dialog and merely rolled back on cancel, so they flash
behind the sheet. To fix properly: replace `BatchTimecodeItem.targetLaneId` with an intended
lane *name* plus an ordering index, and create the real lanes in `handleBatchTimecodeConfirm`.
**Preserve the ordering guarantee** (video embedded-audio lanes before standalone audio) —
that is what `reservedAudioLaneIds` protects, and it took several attempts to get right for the
multi-file drop bug.

Smaller known items:
- `isVideoAudioExpanded` is dead state (see above).
- `SettingsAccordionView.swift` is misnamed: the accordion is gone, but the file still holds
  `ChannelGridView`, `StereoGroupView`, `ChannelCellView`, `OutputRowView` and the shared
  `View.cursor(_:)` that `OptimizationSheetView` depends on. Relocating them is its own job.
- `PlaybackResizeHandle` / `playbackMinHeight` / `clampPlaybackHeightIfNeeded` are leftovers
  from the original embedded player; `clampPlaybackHeightIfNeeded` has zero callers.

---

## Repo conventions worth remembering

- **New `.swift` files are not compiled.** Only the ProjectorQuickLook group is
  filesystem-synchronised in the pbxproj. Add code to an existing file; when removing a file,
  empty it with an explanatory header rather than deleting it.
- **Always `grep -rn` a symbol and count call sites before editing it.** This codebase has
  repeatedly held convincing-looking dead code — `TransportBarView`, `AudioExtractionService`,
  `handleMultiFileDropNative`, `resizeToFitLanes`.
- `ContentView.swift`'s body is at the Swift type-checker's limit. Adding a modifier to it
  fails with "unable to type-check this expression in reasonable time" — extract a computed
  property or attach the modifier to a smaller subview instead.
- **Cut declarations by brace-matching; never truncate to end of file.** Doing the latter
  destroyed a shared `View.cursor(_:)` helper and broke the build.

---

## Previous session (2026-07-23) — sync core repair

Kept for context; that work is committed and green.

- Clean Debug build succeeds without a private signing certificate; Release signing stays on
  team `G398H44H6X`.
- MIDI and timeline streams broadcast to UI and transport simultaneously.
- Timeline frame rate, non-zero start timecode, MMC events, sync preferences and drift
  threshold reach playback correctly.
- Waveform generation no longer publishes during SwiftUI view evaluation, and cancels safely.
- First-run onboarding is remembered; `-reset-welcome` resets it for developers.
- Test-created audio preferences no longer leak into the user's app settings.
- Test suite passed 40/40 including UI waveform import/zoom.
