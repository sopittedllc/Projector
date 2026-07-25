# Brief: multi-file drops lose all but one file on the timeline video track

**Date**: 2026-07-24
**Status**: Root cause identified with runtime evidence. Fix not yet written.
**Branch**: `codex/repair-sync-core` (4 commits landed earlier today; player-window
work + this investigation are uncommitted).

---

## The symptom

Dragging 1 video + 3 audio stems together onto the **timeline**:

- All 4 files import into the **Media panel** correctly.
- The **timeline** receives only the video. The 3 `.wav` stems never arrive.

The user has reported this repeatedly. Several fixes were attempted against the
wrong layer (see "What was already fixed" below) before the drop-reception layer
was instrumented.

---

## Root cause (evidence, not inference)

Instrumentation was added at every drop-reception boundary. One drag of the same
4 files produced:

```
FileManagerView.handleDrop:  RECEIVED 4 provider(s)
VideoTrackDropDelegate.performDrop:
    itemProviders(for: supportedTypes) vended 1; fileURL-only vends 1
VideoTrackView.handleDrop:   RECEIVED 1 provider(s)
VideoTrackView.handleDrop:   resolved 1 URL(s) -> 1 video, 0 audio
```

**`DropInfo.itemProviders(for:)` inside a `DropDelegate` vends only ONE provider,
while the closure-based `.onDrop` receives all four from the same drag.**

Critically, `fileURL-only vends 1` rules out the type list as the cause — the
delegate was asked for the single broadest type and still got one provider.

### Why the other drop targets work

| Target | Mechanism | Files received |
|---|---|---|
| Media panel (`FileManagerView`) | SwiftUI `.onDrop(of:isTargeted:perform:)` — closure | **all 4** ✅ |
| Audio lanes (`AudioLaneView`) | AppKit `NSDraggingInfo`, reads `draggingPasteboard` directly via `AudioLaneDragCaptureView` | **all 3** ✅ (confirmed in earlier logs) |
| Timeline video track (`VideoTrackView`) | SwiftUI `.onDrop(of:delegate:)` — **`DropDelegate`** | **1 only** ❌ |

The video track is the **only** drop target in the app using the `DropDelegate`
form, and it is the only one that loses files.

---

## Suggested direction (not prescriptive)

Bring `VideoTrackView` onto a mechanism already proven in this codebase. Two
options, in order of preference:

1. **Use the AppKit path the audio lanes already use.** `AudioLaneView` has
   `AudioLaneDragCaptureView` (an `NSViewRepresentable` over `NSView` +
   `registerForDraggedTypes`) and reads
   `info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])`,
   which reliably returns every dragged file. `MultiTrackTimelineView` has an
   equivalent `DragCaptureView`. Reusing that pattern makes all three timeline
   targets consistent.
2. **Convert to the closure form** `.onDrop(of:isTargeted:perform:)` like
   `FileManagerView`. Simpler, but loses `dropEntered`/`dropUpdated`, which
   `VideoTrackView` uses to draw its drop-position preview. Only viable if that
   preview is reimplemented or dropped.

`VideoTrackView.handleDrop(providers:at:)` already routes correctly once it has
the providers — `routeDroppedMedia(videoURLs:audioURLs:...)` sends mixed drops to
`onDropMixedMedia`. **The routing is fine; only the provider supply is broken.**

### Verification

`scripts/`-free, use the running app: launch the binary directly so `debugPrint`
(NSLog-based, `>>>` prefix) is captured —
`…/Projector.app/Contents/MacOS/Projector > /tmp/p.log 2>&1` — then drop 1 video
+ 3 stems on the video track and confirm:

```
VideoTrackView.handleDrop: RECEIVED 4 provider(s)
VideoTrackView.handleDrop: resolved 4 URL(s) -> 1 video, 3 audio
handleMixedBatchDrop: ENTRY - 1 video, 3 audio
```

`log stream` is useless here — it redacts NSLog output as `<private>`.

---

## What was already fixed (keep — real bugs, wrong layer for this symptom)

These are all downstream of provider supply. They were fixing genuine defects but
could never fix this symptom. All are in the working tree, built, and should be
retained:

| Fix | File | Why it's still right |
|---|---|---|
| Lane reservations skipped by video import | `ContentView+Timeline.swift` `prepareAudioLaneIfNeeded` + `reservedAudioLaneIds` | Video import adopted *any* non-overlapping lane, including empty lanes reserved for a batch's audio files. An empty lane never "overlaps". |
| Retry on a fresh lane when placement returns nil | `addAudioToTimelineAvoidingOverlap` | `addAudioClip` returns `nil` when the target lane no longer exists, silently losing the file with no error. |
| Overlap spill to new lanes | `addAudioToTimelineAvoidingOverlap` | `AudioLane.addClip` appends unconditionally; stems sharing a start timecode stacked invisibly on one lane. |
| Mixed path uses overlap-safe placement | `handleMixedBatchDrop` | It was the one batch path still calling plain `addAudioToTimeline`. |
| Order-preserving URL collection | `AudioLaneView`, `MultiTrackTimelineView` | Slot-indexed writes instead of racing appends. |

---

## Codebase traps (each cost real time this week)

1. **Check call sites before trusting or editing any function.** This codebase
   ships dead code that looks live. Confirmed dead and since removed:
   `resizeToFitLanes` (was never called), `handleMultiFileDropNative`,
   `AudioLaneView.handleDrop(providers:)` (the live path is
   `handleDropNative(info:)`), `MediaItemRow`, `FullScreenVideoView`.
   A fix was written against `AudioLaneView.handleDrop(providers:)` before
   anyone noticed it had zero call sites.
2. **New `.swift` files are not compiled.** Only the `ProjectorQuickLook` group
   is filesystem-synchronized in the pbxproj. Repurpose an existing file or add
   through Xcode.
3. **`.help()` does not fire on `glassEffect` surfaces (macOS 26).** Use
   `GlassActionButtonStyle(tint:help:)`, which draws its own tooltip from
   `.onHover`. Plain buttons over opaque backgrounds are unaffected.
4. **Capturing app logs**: launch the binary directly (above). `log stream`
   redacts NSLog as `<private>`.
5. **UI changes require user runtime verification before commit** (project rule
   in `.claude/rules/ui-verification-required.md`).

---

## Current state of the working tree

Built and running. Verified working by the user:

- Multi-file **audio-only** drops onto the timeline
- Panel + window vertical growth for new lanes (bounded at
  `MainWindowLayout.expandedHeight`; earlier unbounded version grew the window
  to fill the display)
- Standalone player window: opens on first video, collapse button, pin to
  foreground, ⇧⌘P, native fullscreen
- Per-project UI state (window frames, panel expansion, timeline height) saved
  in `ProjectData.uiState`, optional so older `.projector` files still load

Outstanding: this brief's bug, and the temporary reception instrumentation in
`VideoTrackView` / `FileManagerView`, which should be removed or downgraded once
the fix lands.
