---
name: multitracktimelineview-dual-drop-paths
description: MultiTrackTimelineView.swift once had two parallel drop paths, one of them dead; the dead one was deleted 2026-08-08, leaving only the NSDraggingInfo/DragCaptureView path.
metadata:
  type: project
---

**Historical as of 2026-08-08 — the duplication is gone.** Kept because the
checking habit it teaches is still worth having.

`Projector/Views/Timeline/MultiTrackTimelineView.swift` used to contain two
independent implementations of "handle a file drop on an empty/new audio lane":

1. An NSItemProvider-based subsystem (`handleEmptyAudioDrop`,
   `beginEmptyAudioDrop`, both `loadURL` overloads, `loadFirstURL`,
   `mediaItem(from:)`, `quickMediaType(from:)`, `extractURL`,
   `extractProjectorMediaURL`, `extractProjectorMediaInfo`,
   `updateEmptyAudioDropPreview`) with **zero call sites** — leftover from an
   earlier SwiftUI-native drop implementation. The file has no `.onDrop(`
   modifier, so nothing ever fed it providers. **Deleted 2026-08-08**, ~290 lines.
2. An NSDraggingInfo/AppKit subsystem wired through `DragCaptureView`'s
   `onEntered`/`onUpdated`/`onPerform` to `handleNewLaneDragEntered` /
   `handleNewLaneDragUpdated` / `handleNewLanePerformDrop` → `audioCandidate(from:)`
   / `audioURLs(from:)` / `videoURLs(from:)`. **This is now the only path.**

It cost a wrong fix first: (1) read as the obvious place to fix a drop bug,
having the exact `urls.filter { mediaType == .audio }` pattern anyone chasing a
"video silently discarded" report would recognise — but a fix applied there ships
invisibly broken, because nothing calls it, and neither `xcodebuild` nor a runtime
check reveals that.

**How to apply**: the specific trap is gone, but the habit stands — before
trusting a fix to any drop handler here, confirm the edited function is reached
from a `DragCaptureView(...)` construction. `grep -c` on the function name is
enough; a count of 1 means only its own definition. Mixed video+audio routing now
lives in `handleNewLanePerformDrop`. See
[[projector-mixed-drop-fix-targeted-dead-code]].
