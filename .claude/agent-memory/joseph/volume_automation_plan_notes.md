---
name: volume-automation-plan-notes
description: Corrections and status notes for implementing docs/plans/VOLUME-AUTOMATION-PLAN.md. All of steps 1-6 done as of 2026-09-16; step 7 (docs) is what remains.
metadata:
  type: project
---

**Step 5 (row geometry, done 2026-09-16):** `Projector/Views/Timeline/TrackGeometry.swift`
(new) is the single source of vertical layout for standalone rows, the picture strip and
expanded linked-audio strips. `Timeline.swift`'s `LaneReorder` was rewritten to take
`rows: [LaneRowMetric]` + `hysteresis` instead of a scalar `rowHeight`; `LaneChangePreview`
now carries `sourceLaneId`/`targetLaneId: UUID` instead of index fields, and
`AudioLaneView.onClipLaneChangeRequested`/`onClipLaneChangePreview` carry a lane id instead
of a lane-count offset, resolved via a new `laneIdForVerticalDrag: (CGFloat) -> UUID?`
closure the parent supplies per row (default `{ _ in nil }`, so the one `#Preview` call site
did not need updating).

Two things worth knowing before touching this again:
- **The plan's §6.2 prose ("moving down: `dragOffset > 0`... moving up: ...") describes the
  wrong gating condition.** Gating the advance/retreat check on the raw sign of `dragOffset`
  cannot reproduce the old, already-shipped reversal behavior (drag past a boundary, ease back
  without ever going net-negative, and the target must retreat one row - `dragOffset` stays
  positive the whole time). The implementation in `Timeline.swift` checks **both** the advance
  and retreat edge every iteration, unconditional on `dragOffset`'s sign, which is what actually
  reproduces every case the plan's own §6.2 hysteresis story requires (verified by hand against
  the old `rows`-fraction formula for ~10 scenarios before writing it). If a future session
  re-reads §6.2 and "fixes" the gating to match the prose literally, it will re-break reversal.
- **`TrackGeometry`'s rects carry no real X** (`x: 0, width: .greatestFiniteMagnitude`) - the
  initializer takes only `timeline`/`isVideoAudioExpanded`, not `pixelsPerFrame`, so it cannot
  compute a real horizontal position and was never meant to. Every consumer (marquee, lane-change
  hit-testing) reads `minY`/`maxY`/`midY` only and computes X separately from `ppf` exactly as
  before this type existed. Do not "fix" this by threading `ppf` into `TrackGeometry` - that
  would tie a per-layout-pass geometry cache to zoom, recomputing it on every scroll/zoom change
  for no consumer that needs it.
- Marquee selection now correctly excludes a lane's automation strip/sub-lane from clip
  hit-testing (`row.clipRect` only, not `row.rowRect`), and linked-audio clip selection is now
  keyed off `linkedStripRects` instead of walking `timeline.audioLanes` positionally - the old
  code did the latter and silently mis-selected linked clips whenever any were expanded, since it
  advanced its Y cursor through *every* lane including ones actually drawn inside the video
  group. That was a real latent bug fixed as an explicit, plan-directed part of this step, not
  scope creep.
- Did not touch the `"timelineTracks"` named-coordinate-space question: the marquee gesture's
  own coordinate space is anchored at the top of the ruler row (a `GeometryReader` ancestor
  above the ScrollView), while the marquee math (both old and new) assumes y=0 is the top of the
  scroll content, ~25pt lower. This mismatch predates this step and was reproduced exactly
  (same numeric convention as the pre-existing code), not fixed - fixing it was out of scope and
  is worth a session of its own with the app actually running to confirm it is real before
  touching it.

Step 2 of `docs/plans/VOLUME-AUTOMATION-PLAN.md` (editor prototype in the real
timeline) is done: `Projector/Views/Timeline/VolumeAutomationEnvelopeView.swift`
(AppKit `NSView` editor) and `VolumeAutomationLaneView.swift` (SwiftUI sub-lane
row) exist and are wired into `MultiTrackTimelineView.swift`'s per-lane
`VStack`, gated on `lane.automation != nil && lane.isAutomationShown`. The
temporary way to add automation is the lane's own context menu
("Add Automation" / "Show/Hide Automation") via `AudioLaneView`'s new
`onAutomationToggle` closure param — there is no `A` well yet (that's step 6).

**Why:** recorded so a future session resuming step 5 (row geometry) or step 6
(the real editor: well, both menus, undo, Set Level…, snapping, accessibility)
does not have to re-derive what step 2 already validated, and does not
re-trip on plan-text errors already found once.

**Update (2026-09-16):** the user tried the step-2 prototype and rejected both
affordances planned for step 6 §5.2 — no `A` well in the header, no
context-menu items ("Add/Show/Hide Automation" removed from both
`AudioLaneView`'s own menu and the reorder-handle overlay menu in
`MultiTrackTimelineView.swift`). Replaced with a permanent per-lane row: every
standalone lane now always shows either the 48pt `VolumeAutomationLaneView`
(when `automation != nil && isAutomationShown`) or a new 18pt
`VolumeAutomationStripView` (`Projector/Views/Timeline/VolumeAutomationStripView.swift`,
`TimelineLayout.automationStripHeight`) with a "+ Add/Show Automation"
button. `VolumeAutomationLaneView` gained an `onHide: () -> Void` closure and
a chevron-up button on its "Volume" row to collapse back to the strip.
`AudioLaneView.onAutomationToggle` was deleted entirely (no remaining call
sites). **When resuming step 5 or 6, treat plan §5.2 and the `A`-well bullets
in §9's acceptance criteria as superseded by this** — every standalone row is
now 80 (lane) + 18 (strip) or 80 + 48 (expanded sub-lane), never just 80, so
step 5's row-height table (§6.4) must add the strip's 18pt to every
standalone row's base case, not only the expanded case the plan text
describes.

**How to apply:** before trusting a symbol name quoted in the plan text
itself, grep for it — the plan was written before/alongside implementation and
at least one call-site name in it is wrong:
- Plan §5.3/step 2 brief says `AppColors.color(forLaneIndex:)`; the real API
  is `LaneColor.color(forLaneIndex:)` (`Projector/Utilities/LayoutConstants.swift`).
- Also worth knowing for step 5/6: the `.offset(y:)/.zIndex/.animation`
  modifiers on the per-lane row in `MultiTrackTimelineView.swift` are chained
  onto `AudioLaneView(...)` itself, not onto the wrapping `VStack(spacing: 0)`
  — so the automation sub-lane, added as the VStack's second child, does NOT
  get displaced during a lane-reorder drag. That's an accepted, known gap
  until step 5's geometry work, not a bug to fix in isolation.
- Swift's synthesized memberwise init for a View struct requires arguments in
  exact declaration order even when every argument is labelled — adding a new
  defaulted property (e.g. `onAutomationToggle`) to `AudioLaneView` means its
  argument at the call site must go in declaration position, not be appended
  after later params like `selectedClipIds`, or the build fails.

**Step 4 (export, done 2026-09-16):** `mixParameters(for:trimDB:automation:span:rate:)`
replaces the old `gainDB:` overload in `QuickTimeDemoBuilder.swift` and is `internal`
(was `private`) purely so `QuickTimeDemoBuilderTests` can drive it without a video asset.
`QuickTimeDemo` gained `rate`/`laneAutomation`; its `securityScopedResources` and
`QuickTimeDemoSecurityScope` went `fileprivate` → `internal` for the same reason (test
target needs to construct a `QuickTimeDemo` by hand) — no other behavior changed.

Two things §4/§7 of the plan got wrong or left open, found by actually running the PCM
harness rather than reasoning about it:
- **§4.4's trim question is answered, not still open.** +6 dB trim over a 0→−12→0 dB
  envelope measures at ~1.994× (theory 1.995×) at the 0 dB end and ~0.501× (theory
  0.5012×) at the −6 dB point — AVFoundation renders a combined level above unity as
  configured, it does not clamp. No cap on trim was added for automated lanes. If a
  future session sees "trim contract TBD" anywhere, that's stale.
- **§7's ±1 ms boundary-exclusion margin is too tight for a one-frame step.** A ~41.7 ms
  0→−60 dB step (1 frame at 24 fps) leaves a measurable settling artifact for several ms
  afterward — up to ~0.075 dB, above the hold tolerance the plan states (0.05 dB), if only
  ±1 ms is excluded around it. Every *other* boundary (a 1 s slope's ends, ordinary holds)
  is clean at ±1 ms; this is specific to a transition this fast. Fix used: ±15 ms around
  that one boundary, ±1 ms everywhere else, documented inline in the test. If step 3's
  frame-stepped playback hook (§3.3) is ever compared against export this precisely,
  expect the same kind of settling behavior near very fast steps, not a bug in the hook.

**Tooling gap, not a plan or code issue:** on this machine, neither `xcodebuild test`'s
stdout nor `xcresulttool` (console log, activities, or test-details) surfaces a test's
plain `print()` output — confirmed by trying all three. `testMeasurePositiveTrimOnAutomatedLane`
and the PCM reference test both `print` their measured numbers, but reading them back out
of a CLI run requires either a standalone harness with the same formula (what was done
here, cross-checked against the shipped test's own passing assertions) or opening the
`.xcresult` in Xcode's GUI test navigator.

**Step 6 (the real editor, done 2026-09-16):** undo/redo, "Set Level…", Option-drag fine
control + unity snap, and accessibility landed in `VolumeAutomationEnvelopeView.swift`
(the `NSView`), `VolumeAutomationLaneView.swift` (the popover) and `MultiTrackTimelineView.swift`
(undo wiring). New file `Projector/Views/Timeline/AutomationUndo.swift` — a free `enum`,
not a method on the view — holds the inverse-op undo/redo trick and the stale-edit guard,
specifically so `ProjectorTests/VolumeAutomationUndoTests.swift` can drive it against a
real `TimelineManager` + `UndoManager` without a SwiftUI view instance.

Two things worth knowing before touching AppKit accessibility or `UndoManager` again in
this codebase:
- **Every AppKit accessibility override in this codebase must use function-style
  overrides, not computed-var overrides, despite the SDK headers showing `@property` for
  almost all of them.** `NSAccessibilityProtocols.h` declares `accessibilityRole`,
  `accessibilityLabel`, `accessibilityChildren`, `isAccessibilityElement`,
  `accessibilityCustomActions` as `@property` on the giant `NSAccessibility` protocol, and
  `accessibilityFrameInParentSpace`/`accessibilityParent` as plain properties too — every
  one of those reads like a Swift `var` should work. It doesn't: the compiler rejects
  `override var accessibilityRole: ...` with "property does not override any property from
  its superclass", and rejects `element.accessibilityFrameInParentSpace = rect` on an
  `NSAccessibilityElement` instance with "is a method". The actual Swift-importer surface
  for *all* of these, on both `NSView` subclasses and `NSAccessibilityElement` instances,
  is the get/set **function** pair (`accessibilityRole() -> NSAccessibility.Role?` /
  `setAccessibilityRole(_:)`, `accessibilityChildren() -> [Any]?`,
  `setAccessibilityFrameInParentSpace(_:)`, etc.) — only `accessibilityPerformIncrement()`
  /`Decrement()`/`Delete()` (never `@property` in the header to begin with) match what the
  header format would suggest. Found by writing the property-style version, letting
  `xcodebuild build` reject it, and fixing to function style from the compiler's own
  errors rather than continuing to guess — worth doing that same build-and-read-the-error
  loop again rather than trusting the header's declaration style for any *other*
  AppKit-via-category accessibility member not listed above.
- **A real `UndoManager` cannot `.undo()`/`.redo()` synchronously right after
  `registerUndo(withTarget:handler:)` in a unit test.** `registerUndo` opens an undo group
  implicitly if none is open; in a real app that group closes on its own at the end of the
  current run-loop event, but a synchronous XCTest method never reaches one, so calling
  `.undo()` while it's still open raises ("was called during undo grouping"). Fix: call
  `undoManager.endUndoGrouping()` once, right after the *first* top-level `registerUndo`
  call in a test, before the first `.undo()`. Not needed again inside the cycle —
  `.undo()`/`.redo()` manage their own grouping internally for the recursive
  re-registration `AutomationUndo.register` does from inside its own undo closure, which is
  exactly what let `VolumeAutomationUndoTests` exercise two full undo→redo cycles per edit
  type without ever calling `endUndoGrouping()` a second time.
