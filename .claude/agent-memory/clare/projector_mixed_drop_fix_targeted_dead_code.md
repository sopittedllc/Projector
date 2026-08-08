---
name: projector-mixed-drop-fix-targeted-dead-code
description: RESOLVED 2026-08-08 — the mixed-drop fix first landed in the unreachable handleEmptyAudioDrop, was moved to handleNewLanePerformDrop, and the dead subsystem has since been deleted.
metadata:
  type: project
---

**Resolved — do not re-report this.** Kept only for the lesson.

On 2026-08-08 a fix for "a mixed drop on the audio area silently discards the
video" was first written into `handleEmptyAudioDrop`, which had **no caller**. The
build passed and a runtime check passed, so it looked done. Neither was evidence:
Swift does not warn on unused private methods, and the runtime check was performed
on a timeline that already had a lane, where `AudioLaneView.routeDroppedMedia`
handles the drop and already routed mixed batches correctly. Only the *first* drop
into an empty project was ever broken.

Caught by tracing `DragCaptureView`'s `onPerform` closures to their real target.

**What the code looks like now**: the fix lives in `handleNewLanePerformDrop`,
which pairs the existing `audioURLs(from:)` with a new `videoURLs(from:)` and
routes to `onDropMixedMedia` when a batch carries both. The entire orphaned
NSItemProvider subsystem — `handleEmptyAudioDrop`, `beginEmptyAudioDrop`,
`loadFirstURL`, both `loadURL` overloads, `extractURL`,
`extractProjectorMediaURL`, `extractProjectorMediaInfo`, `mediaItem(from:)`,
`quickMediaType(from:)`, `updateEmptyAudioDropPreview` — has been deleted, along
with the write-only `emptyAudioDropLocation` state and the then-unused
`mediaLibrary` dependency. So [[multitracktimelineview-dual-drop-paths]] no longer
describes the file: there is now one drop path, the `NSDraggingInfo` one.

**The lesson worth carrying**: a passing build plus a passing runtime check still
did not show that the edited function was unreachable. When a fix appears to work,
confirm the edited code is on the path that actually ran — `grep -c` on the
function name is enough to catch it.
