# Plan: Per-Lane Volume Automation — revision 3

> **Revision 3, after Codex's round-2 review** (`docs/audits/VOLUME_AUTOMATION_PLAN_AUDIT.md`,
> "Revision 2 review"). Every R2 item is addressed; where the item is cross-referenced below it
> is marked `[R2-n]`. Design inputs unchanged: attenuation-only envelope, apply-on-release,
> standalone lanes only, ducker as a follow-up.
>
> Changes: trim contract narrowed and measured, not claimed (§4.4) `[R2-1]`; `segments` covers
> the whole span with holds; closed-form `rampCount`; boundary construction rules (§2.1, §4.1)
> `[R2-2]`; undo is inverse-op per lane with explicit redo, pre-capture before insert,
> double-click rule, stale-edit guard (§5.5) `[R2-3]`; signed frames internally, shift is
> reversible; linked-lane policy = retain data, bypass everywhere (§2.1, §2.5) `[R2-4]`;
> video group bounds, edge-crossing reorder rule on frozen geometry, pitch per row, pure
> `LaneRowMetric` in the model (§6) `[R2-5]`; live path gate expanded, cache holds the full
> base product (§3) `[R2-6]`; PCM reference test via `AVAssetReaderAudioMixOutput`, codec test
> separate; minor corrections (§7, §5.3, §9) `[R2-7]`.
>
> **To the reviewer (Codex), round 3:** the items I consider closed are listed; please
> confirm or object per item. Specific asks: (1) the trim contract in §4.4 — is "measured,
> documented, not claimed" acceptable, or do you want automated lanes to refuse positive trim?
> (2) the reorder rule in §6.2. (3) the `AVAssetReaderAudioMixOutput` harness in §7.

---

## 1. Context

Projector builds "review QuickTimes": picture + a stereo mix WAV the user supplies + selected
timeline audio lanes, each at one fixed level (`QuickTimeDemoSheet` dB slider, −40…+6). There is
no way to change a lane's level over time anywhere in the app. Users want to ride levels — a
dialogue or temp lane ducked under the mix, a reference stem faded in — so the demo they send
reads like a mix.

**Feature (this plan):** each standalone audio lane can get an **automation sub-lane** (DAW
convention): an `A` well in the lane header adds a shorter row under the lane; the user clicks
to add nodes and drags them; straight lines join nodes; the envelope is heard in playback and
printed into the demo export. Saved with the project.

**What it does not do — stated in the feature description:** the demo's supplied mix WAV is
not a timeline lane (`QuickTimeDemoBuilder.swift:227` inserts it separately) and is **not
automated**. Lanes are ducked *against* the WAV; the WAV itself is not ridden.

**Follow-up (separate plan):** a sidechain ducker — analyse the DX (optionally SFX) lane,
generate an attack/release envelope, apply it to a music lane *or* the mix WAV. This plan's
`VolumeAutomation` is source-agnostic and `mixParameters` (§4.1) takes an optional envelope for
*any* composition track, so the ducker is "generate an envelope, hand it to the same renderer".

**User decisions:** range **−60 … 0 dB** (attenuate only), 0 dB default; **standalone lanes
only**; **apply on release** (drawing follows the mouse, engine hears it at mouse-up);
ducker later.

**Out of scope:** curves, per-clip automation, other parameters, automating the mix WAV,
folding `AudioLane.volume`/`AudioClip.volume` into export (unchanged), keyboard nudging, a
limiter or normalisation (the sum can clip exactly as today; automation ≤ 0 dB never adds to it).

---

## 2. Model (`Projector/Models/Timeline/`)

### 2.1 New file `VolumeAutomation.swift`

```swift
public struct VolumeAutomationPoint: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var frame: Int      // absolute timeline frame; MAY be negative (see below)
    public var gainDB: Float   // within gainRange, finite
}

/// A lane's volume envelope: sorted breakpoints with unique frames, linear-in-dB between
/// neighbours, held before the first and after the last. Empty == unity.
public struct VolumeAutomation: Codable, Equatable, Sendable {
    public static let gainRange: ClosedRange<Float> = -60 ... 0
    public static let unityDB: Float = 0
    public private(set) var points: [VolumeAutomationPoint]

    /// No gain anywhere (empty, or every point at 0 dB). Not "flat": a constant −12 dB is flat.
    public var isUnity: Bool
    public func gainDB(at frame: Int) -> Float
    public func linearGain(at frame: Int) -> Float
    public static func linearVolume(fromDB: Float) -> Float   // moved from QuickTimeDemoBuilder:186

    /// Adds a point, or replaces the gain of the point on that frame (id kept). Interactive
    /// callers pass frame >= 0; the model itself accepts any Int.
    @discardableResult public mutating func insert(frame: Int, gainDB: Float) -> VolumeAutomationPoint
    /// Frame clamped to (previous.frame + 1 ... next.frame - 1); gain clamped to the range.
    public mutating func move(id: UUID, toFrame: Int, gainDB: Float)
    public mutating func setGain(id: UUID, gainDB: Float)
    public mutating func remove(id: UUID)
    public mutating func removeAll()
    /// Reversible, monotonic frame transform used by regrid/shift. Keeps negative results;
    /// re-sorts; if rounding lands two points on one frame, keeps the later one.
    public mutating func mapFrames(_ transform: (Int) -> Int)

    /// Full coverage of [startFrame, endFrame): leading hold, node-to-node pieces, trailing
    /// hold. Never empty for a non-empty range; the first segment always starts at
    /// `startFrame`. A single-point envelope yields one hold at that point's gain.
    public func segments(from startFrame: Int, to endFrame: Int) -> [Segment]
    public struct Segment: Equatable {
        let startFrame: Int; let endFrame: Int; let startDB: Float; let endDB: Float
        var isHold: Bool { startDB == endDB }
    }

    /// Ramps needed so a linear-amplitude ramp over `deltaDB` stays within `toleranceDB`
    /// of the dB-linear line. Closed form: maxDelta = (40/ln10)·acosh(10^(tol/20));
    /// count = max(1, ceil(|delta| / maxDelta)); delta == 0 → 0. `toleranceDB` is clamped to
    /// >= 0.01 (non-finite or smaller is treated as 0.01), so count is bounded (≤ 200 at Δ=60).
    /// Revision (2026-09-16, after Codex's implementation audit): maxDelta is no longer the
    /// midpoint closed form with a 0.99 margin — that under-split at loose tolerances (≈2.06 dB
    /// error at a 2 dB tolerance). `maximumRampErrorDB(forDeltaDB:)` is the true maximum
    /// (`q = ln10·|Δ|/20`, `u = 1/q − 1/expm1(q)`, err = (20/ln10)(log1p(u·expm1 q) − q·u)) and
    /// `maximumRampDeltaDB(forToleranceDB:)` bisects it, so the guarantee is exact for any
    /// tolerance (≈ 2.636 dB at 0.1). Non-finite deltas → 0 ramps; |Δ| capped at the range span;
    /// frames clamped to `frameRange = ±2⁴⁰` everywhere so no Int arithmetic can overflow.
    public static func rampCount(forDeltaDB delta: Float, toleranceDB: Float) -> Int
}
```

**Frames are signed inside the model** `[R2-4]`. Clip positions survive `shiftAllContent`
negative (`TimelineManager.swift:316`), and a shifted fade must keep its shape and be
reversible, so points do the same. Only interactive placement (§5.4) clamps to `>= 0`; the
editor draws what is visible and `gainDB(at:)` is defined for every frame.

**Invariants enforced on every entry point, including decode** (custom `init(from:)`, not
synthesised): sorted by frame; unique frames (keep the last); finite gains clamped to the
range; ids regenerated when missing or duplicated. Non-finite frames cannot occur (Int).

### 2.2 `AudioLane.swift` — two new stored properties

```swift
/// The lane's volume envelope, once added. `nil` means never added. A hidden envelope is still
/// applied — showing is view state, not bypass.
public var automation: VolumeAutomation?
/// Whether the sub-lane is drawn. Meaningless while `automation == nil`.
public var isAutomationShown: Bool
```
Four-place pattern (`AudioLane.swift:65-225`): property, `init`, `CodingKeys`, `init(from:)` with
`decodeIfPresent` / `encode(to:)` with `encodeIfPresent`. Defaults `nil` / `false`.

**Compatibility, precisely:** pre-feature projects open with no automation. A project saved by
this build and re-saved by an *older* build loses its automation (unknown keys dropped).
`ProjectData.version` is decoded but not used to select a migration; not bumped.

### 2.3 `Timeline.swift` — `LaneReorder` (L376-404) takes pure row metrics `[R2-5]`

```swift
/// Pure geometry of one visible row, in points. Model-layer; no CGRect, no view types.
public struct LaneRowMetric: Equatable {
    public let id: UUID; public let top: CGFloat; public let height: CGFloat
    /// height + the divider under this row (0 for the last row — see §6.3).
    public let pitch: CGFloat
}
struct LaneReorder {
    let rows: [LaneRowMetric]       // frozen at gesture start
    let hysteresis: CGFloat         // points
    func target(sourceOrdinal: Int, heldOrdinal: Int?, dragOffset: CGFloat) -> Int
}
```
Rule in §6.2. `LaneRowGeometry` (view layer, with rects) is *derived from* metrics, never the
other way round.

### 2.4 `TimelineManager.swift` — mutations (copy-modify-write, like `setLaneVolume` L742)

```swift
func addAutomation(toLane id: UUID)                 // guard standalone; .init(); shown = true
func setAutomationShown(_ shown: Bool, laneId: UUID)
func removeAutomation(fromLane id: UUID)            // nil; shown = false
func setAutomation(_ automation: VolumeAutomation, laneId: UUID)   // guard standalone
```
`guard timeline.standaloneAudioLanes.contains { $0.id == id }` (excludes inferred legacy
linked lanes too).

### 2.5 Policy for a lane that is not standalone `[R2-4]`
**Retain the data, bypass it everywhere.** Stored automation on a non-standalone lane is kept in
the model, but is *not* evaluated by playback (§3.2 table excludes it) and *not* captured in the
export snapshot (§4.2), and cannot be edited (§2.4). The three agree by construction because all
three use `standaloneAudioLanes` membership. If the lane becomes standalone again its envelope
is back.

### 2.6 Timeline edits that move content
Automation is at absolute timeline frames; moving/trimming/splitting/re-laning a clip does not
move it; a reordered lane carries it. `regridContent(from:to:)` (`TimelineManager.swift:223`)
and `shiftAllContent(by:)` (`:316`) call `automation.mapFrames(_:)` with the same transform they
apply to clips. Regression test `[R2-4]`: points `(0, 0 dB)`, `(100, −60 dB)`, shift by −50 →
`gainDB(at: 0) == −30`, `gainDB(at: 50) == −60`; shift back by +50 restores the original.

---

## 3. Live playback (`Projector/Managers/PlaybackEngine.swift`)

### 3.1 One gain function
`playbackGain(for:lane:)` (L1993) — the single function used by `syncAudioPlayer` (L2022),
`scheduleAudioPlayback` (L2124), `applyMixToLoadedPlayers` (L2009) — becomes
`base(clip, lane) * automationGain(laneId, currentFrame)` where `base` is today's
`isLaneAudible ? clip.volume * lane.volume : 0`. Product stays within 0…1. No new gain stage.

### 3.2 `AutomationGainTable` (internal struct, testable) `[R2-6]`
Built in `updateTimelineProperties()` (L3348) on every timeline replacement, including undo:
- per lane: `baseGain` for each of its clips (mute/solo/None/`clip.volume`/`lane.volume` already
  folded in), and `automation` **only if the lane is standalone and `!isUnity`**;
- `laneOfClip: [UUID: UUID]`.
`gain(forClip:at:)` returns `base * automation.linearGain(at:)`. The frequent hook never sees a
raw envelope value; a muted player stays at 0. Tests: solo/mute/None at a frame transition;
removing the last envelope restores base; moving a loaded clip between lanes re-keys it.

### 3.3 Per-frame hook — frame-stepped, conditional `[R2-6]`
`currentFrame` (L115) gains a `didSet` → `applyAutomationGainIfNeeded()`: return when the table
has no automated lanes; else evaluate each automated lane once, then set `player.volume` for
loaded clips of those lanes from the table. No timeline traversal, no file or routing work.
Seeks, MTC jumps, gap timer, restarts all assign `currentFrame` and so all reconcile here.

**This is frame-stepped (41.7 ms at 24 fps, main queue), not sample-accurate, and it is accepted
only if the measurement gate in step 3 passes.** The plan makes no smoothing claim about the
player→converter→matrix graph. Gate (recorded, not just listened to): log `(hostTime,
player.volume)` per tick from a debug hook and compare against the intended envelope for
(a) a 2 s 0→−60 fade, (b) a one-frame 0→−60 step, (c) seek into the middle of a slope,
(d) an MTC jump, (e) an output-mapping change mid-slope, (f) stop/start mid-slope,
(g) main-thread load (drag a window over the timeline while playing). Separately listen for
clicks on (a) and (b). Fallback if it fails: scheduled parameter ramps via a pre-render
callback (`AudioUnitScheduleParameters`) on the per-clip matrix mixer — requires verifying the
parameter accepts scheduled events, a lock-free state hand-off, seek cancellation, and
restoration after `configureMatrixMixerRouting` resets (L2329). That is a design change and would
be planned, not improvised.

### 3.4 Edits while stopped
`MixState.LaneMix` (L3301) gains `automation`, so a committed edit or removing the last envelope
changes `MixState` and `updateTimelineProperties()` calls `applyMixToLoadedPlayers()`. The
committed gain applies **immediately at the current playhead position** (not on a later pass).

---

## 4. Export (`Projector/Managers/QuickTimeDemoBuilder.swift`)

Facts (confirmed against the SDK header): one composition track per lane (L246); composition
time 0 = `span.startFrame`; `time(forFrame:at:)` (L569) is exact rational; AVAudioMix is unity
before the first setting, interpolates inside a ramp, holds after the last; parameters are in
composition time.

### 4.1 `mixParameters(for:trimDB:automation:span:rate:)` replaces `mixParameters(for:gainDB:)` (L528) `[R2-2]`
- Excluded lane → `setVolume(linear(silentDB), at: .zero)` only; automation bypassed.
- `automation == nil || isUnity` → `setVolume(linear(trimDB), at: .zero)`.
- Otherwise `segments = automation.segments(from: span.startFrame, to: span.endFrame)` covers
  the span from its first frame, so the mix always has an instruction at time zero:
  - hold segment → `setVolume(linear(trimDB + startDB), at: t(start))`;
  - sloped segment → `n = rampCount(forDeltaDB: endDB − startDB, toleranceDB:
    AutomationExport.toleranceDB)`; boundaries `b_k = t(start) + CMTimeMultiplyByRatio(
    t(end) − t(start), multiplier: Int32(k), divisor: Int32(n))` for `k = 0…n`, each computed
    once; ramp k = `setVolumeRamp(from: linear(trimDB + dB(k/n)), to: linear(trimDB +
    dB((k+1)/n)), timeRange: CMTimeRange(start: b_k, end: b_{k+1}))` with dB interpolated
    linearly. Neighbouring endpoints match exactly; ramps are contiguous, non-overlapping,
    positive-duration, chronological; boundaries are exact rationals at the composition
    timescale (never re-expressed at 600); `k`, `n` fit `Int32` trivially; the final boundary
    is exactly `t(end)`.
- `AutomationExport.toleranceDB = 0.1` → `maxDelta ≈ 2.64 dB` by the closed form; at 2.5 dB the
  maximum error is 0.0898 dB at normalised position 0.476 (Codex's independent figure).
- Cost scales with dB change, not duration; holds are one call each.

### 4.2 Plumbing
`QuickTimeDemo` (L92) gains `rate: TimecodeFrameRate` and `laneAutomation: [UUID:
VolumeAutomation]` captured in `makeDemo` (L201) from **standalone** lanes with non-unity
envelopes. `replacingAudioMix(_:)` (L113) and every initialiser/fixture carry both. `makeDemo`
and `makeAudioMix` (L308) both call the new `mixParameters`; the WAV passes `automation: nil`.
Stale `makeAudioMix` doc comment fixed.

### 4.3 Handles
`segments(from:to:)` clips to the span and holds outside the points; head/tail handles and
spans beyond the timeline need no special case. Tested: span wholly before the first point,
wholly after the last, nonzero span start.

### 4.4 Positive trim on an automated lane — the contract `[R2-1]`
`trimDB + envelopeDB` can exceed 0 dB whenever trim is positive; those values (>1.0 linear) are
outside AVFoundation's documented range. This plan **does not claim** they are rendered
correctly. What it does:
- States, in the demo sheet's help text for the trim slider and in `FEATURES.md`, that levels
  above 0 dB rely on observed AVFoundation behaviour, as the shipping slider already does.
- **Measures it**: the PCM harness (§7) runs +6 dB trim over a 0→−12→0 envelope and records
  the actual gain trajectory. If the render is correct (2.0× with the dip), that is documented
  in `KNOWLEDGE_BASE.md` as measured on the SDK in use. If it is clamped or wrong, the feature
  **caps trim at 0 dB for automated lanes** (slider range limited while an envelope is present,
  with a note in the row) — a narrowed contract chosen on evidence, not a silent clamp.
- Does not touch the WAV's or unautomated lanes' trim behaviour.

---

## 5. UI (`Projector/Views/Timeline/`)

### 5.1 Composition (what exists)
`AudioLaneView.laneHeader` (L195-252): name + `AudioLaneControls` (L1229): `M` `S` wells and
sample-rate on row 1, output picker on row 2, 140 × 80 pt. Two lane context menus: the lane's
own (`AudioLaneView.swift:150`) and the reorder handle's overlay (`MultiTrack…:1347`, with a
load-bearing modifier order documented there). Nothing automation-related exists.

### 5.2 The "+ Add Automation" strip (replaces the `A` well and the menu items — user decision, 2026-09-16, after using the prototype)
- Every standalone lane row carries an **18pt strip** (`TimelineLayout.automationStripHeight`)
  along its bottom edge while its sub-lane is not shown: `plus.circle` + "Add Automation"
  (or "Show Automation" when an envelope exists but is hidden), leading-aligned with the lane
  name, tertiary colour brightening on hover, `Button` not a tap gesture. Clicking it adds the
  envelope (or shows it) and the strip is replaced by the 48pt sub-lane
  (`VolumeAutomationStripView.swift`).
- The sub-lane header has a `chevron.up` collapse button ("Hide Automation").
- No `A` well; no context-menu items in either lane menu; `AudioLaneView.onAutomationToggle`
  removed. "Remove Automation" (destructive) stays available from the sub-lane's right-click
  menu (§5.4), which is where the envelope is.
- The video track's linked strips get nothing (scope decision).
- Row height for a standalone lane is therefore **80 + 18** (strip) or **80 + 48** (sub-lane),
  plus the divider — §6's row table must use these, never a bare 80.

### 5.3 The sub-lane: `VolumeAutomationLaneView.swift`
Sibling below `AudioLaneView` in the per-lane `VStack(spacing: 0)` (`MultiTrack…:1202`), shown
when `automation != nil && isAutomationShown`. `AudioLaneView` stays 80 pt.

`HStack(spacing: 0) { header.frame(width: headerWidth) ; envelope.frame(width:
totalContentWidth − headerWidth) }.frame(width: totalContentWidth, height:
automationLaneHeight)` — `totalContentWidth` includes the header column (L1325, L1667).
- Header: `Text("Volume")` (`Typography.monoTiny`, `AppColors.textTertiary`) aligned with the
  lane name (`Spacing.sm`), plus `gainDB(at: playhead)` as `"%+.1f dB"`; uses
  `TimelineHeaderColumnBackground` and the `timelineHeaderScrollOffset` offset (L127).
- Editor: `VolumeAutomationEnvelopeView: NSViewRepresentable` over a custom `NSView`
  (`isFlipped = true`; editable band inset by `automationNodeHitRadius` top and bottom → **32
  editable points for 60 dB ≈ 1.9 dB/pt** `[R2-7]`; hence fine-drag and numeric entry). Draws
  only what intersects `dirtyRect`: dashed 0 dB line, envelope path, nodes, dragged node
  enlarged with a `"%+.1f dB"` readout. X = `frame * pixelsPerFrame` in clip coordinates;
  negative-frame points are simply off-canvas.
- Why AppKit: the row lives inside the timeline `ScrollView` with a marquee
  `DragGesture(minimumDistance: 5)` (L1486) and clip `DragGesture`s; an NSView returning itself
  from `hitTest` receives mouse events before SwiftUI gesture arbitration, has `clickCount`,
  exact hit-testing and `NSMenu`, and does not override `scrollWheel`. **Validated by the
  step-2 prototype** (§8) before anything else depends on it.
  **Prototype finding (2026-09-16):** `hitTest` returning `self` does *not* exclude ancestor
  SwiftUI gestures — AppKit offers the mouse-down to ancestor gesture recognizers first, so the
  tracks-area marquee started under a node drag. Resolved by an explicit `onBeginEdit`/`onEndEdit`
  pair from the NSView that sets `isEditingAutomation` in `MultiTrackTimelineView`, which the
  marquee gesture checks before starting (the same pattern it uses for external file drags).
- Precision aids: Option-drag = 0.1 dB/pt; snap to 0 dB within 1 dB unless Option; node menu
  "Set Level…" → popover with a dB field (timecode shown read-only).
- Accessibility `[R2-7]`: each node is an `NSAccessibilityElement` with a value ("−6.0 dB"),
  label including its timecode, and **actions** increment/decrement (1 dB) and delete; the
  envelope view itself exposes an "Add node at playhead" action. Keyboard nudging with the
  mouse cursor remains out of scope.
- Drops: no drop handler; the prototype confirms a dragged file is refused, not imported.

### 5.4 Interaction contract
- mouseDown on a node → begin transaction (§5.5 capture happens **before** any change) → drag.
- mouseDown on empty space → begin transaction → insert node at (frame from x, clamped `>= 0`
  and `<= durationFrames`; dB from y) → drag.
- mouseDragged → `onPreview(envelope)` (drawing only — not heard).
- mouseUp → `onCommit(envelope)` if it differs from the captured one; else discard.
- Frame clamped strictly between neighbours; dB to the range.
- **Double-click** `[R2-3]`: deletes a node only if that node existed *before the first click of
  the pair*. Implementation: the view remembers the id inserted by the previous mouseDown; on
  `clickCount == 2` over that id it does nothing (the node stays, added by one committed edit).
  Over any other node it removes it (one committed edit). On empty space: nothing.
- Right-click node → "Delete Node", "Set Level…"; right-click empty → "Reset Automation"
  (`removeAll`). Set Level to the same value and Reset on an already-empty envelope commit
  nothing.
- Drag leaving the row continues, clamped. View teardown, lane removal, or document replacement
  mid-drag / while the popover is open → transaction dropped, preview state cleared, nothing
  committed or registered.

### 5.5 Undo — lane-scoped inverse operations with real redo `[R2-3]`
Not the snapshot helper: `registerTimelineUndo` (`MultiTrack…:2831`) registers a closure that only
assigns a snapshot and does not re-register during undo, so redo is not available through it.
New helper in `MultiTrackTimelineView`:
```swift
private func registerAutomationUndo(laneId: UUID, from old: VolumeAutomation?, to new: VolumeAutomation?, actionName: String) {
    undoManager?.registerUndo(withTarget: timelineManager) { manager in
        manager.applyAutomation(old, laneId: laneId)               // restore
        registerAutomationUndo(laneId: laneId, from: new, to: old, actionName: actionName)  // arms redo
    }
    undoManager?.setActionName(actionName)
}
```
(`applyAutomation(_:laneId:)` sets `automation` and, for `nil`, `isAutomationShown = false`; a
non-nil restore keeps the lane's current shown state.) Rules:
- Capture `old` at transaction begin, before any insert/preview. On commit, compare; register
  only if different; register **immediately before** the mutation, in the same call.
- Stale-edit guard: on commit, if the lane's *current* envelope in `timelineManager.timeline` is
  not `== old` (an undo or external change happened during the drag), discard the edit. Lane
  id plus envelope equality is the check; document identity is implied because a replaced
  document replaces the manager's timeline and so fails the equality.
- Because entries are lane-scoped, unrelated changes made during a preview are never rolled
  back.
- Menu commands (Delete Node, Set Level…, Reset, Add/Remove Automation) each register one entry
  via the same helper. Tests: edit→undo→redo→undo (two cycles) for move, add, delete, reset,
  remove.

### 5.6 Layout constants (`LayoutConstants.swift`, `TimelineLayout`)
`automationLaneHeight = 48`, `automationNodeRadius = 4`, `automationNodeHitRadius = 8`,
`automationLineWidth = 1.5`, `automationReferenceDash: [CGFloat] = [4, 4]`,
`automationFineDragDBPerPoint: Float = 0.1`, `automationUnitySnapDB: Float = 1`,
`laneReorderHysteresis: CGFloat = 14` (≈ the old 0.18 × 81). Colours via `AppColors`.

---

## 6. Row geometry — one table, shared by everything `[R2-5]`

### 6.1 Types
```swift
// View layer. Derived from the timeline each layout pass.
struct TrackGeometry {
    let pictureRect: CGRect                 // the video row's picture strip
    let linkedStripRects: [UUID: CGRect]    // each expanded linked-audio strip, by lane id
    let videoGroupHeight: CGFloat           // picture + strips + dividers; standalone rows start below it
    let rows: [LaneRowGeometry]             // standalone lanes in visible order
}
struct LaneRowGeometry: Identifiable {
    let id: UUID; let ordinal: Int; let modelIndex: Int
    let rowRect: CGRect; let clipRect: CGRect; let automationRect: CGRect?
    let metric: LaneRowMetric               // the pure part handed to LaneReorder
}
```
Index-space rule: **layout and hit-testing work in visible ordinals or rects; mutations resolve
a lane id, then its model index.** Never add a row delta to an `audioLanes` index.

### 6.2 Reorder rule (replaces the 0.18-row fraction; equivalent feel on equal rows)
Geometry is **frozen at gesture start** (undisplaced positions; the animated displacement of
other rows never feeds back into targeting). Moving down: the target advances past a lower row
when the dragged row's **bottom edge** crosses that row's centre by `laneReorderHysteresis`;
moving up: when its **top edge** crosses the upper row's centre by the hysteresis. On equal
81 pt rows this triggers at ≈ 0.5 row + 14 pt ≈ 55 pt, the old threshold. Reversal uses the
held ordinal as the reference, as today. Tests: up, down, reversal, multi-row jump, mixed
heights `[81, 129, 81, 81]`, and the resulting **slot positions** (not only ordinals).

### 6.3 Divider convention and displacement
Divider after every row except the last (as today). `pitch = height + divider`, and the last
row's `pitch = height`. Displaced rows move by the **dragged row's pitch**; when the last row is
dragged upward the rows it passes move down by its height only, which is exactly the space it
vacates. Tested with the last row.

### 6.4 Sites

| Site | Change |
|---|---|
| `:1325` | keep 80 for `AudioLaneView`; sub-lane adds its own row |
| `:1125-1133` `audioLanesHeight` / `baseTracksHeight` | `videoGroupHeight + Σ rows.pitch`; fixes the existing miscount when linked strips are open |
| `:2897-2910`, `:2918/2925` reorder | `LaneReorder(rows: metrics, hysteresis:)` in ordinal space, commit by id → `moveLane`; delete the "stems are contiguous at the end" assumption and comment |
| `:3004-3028` displacement | dragged row's pitch (§6.3) |
| `:2884`, `:1273/1302`, `AudioLaneView:518` lane-change | parent supplies `laneRow(forVerticalDrag:)`; preview and commit resolve the same **id**; refuse non-standalone |
| `:1368/1388/1393` last-row border, dividers, placeholder | from `rows` (visible), not model index/count |
| `:3080-3118` marquee | picture selected only from `pictureRect`; linked clips from their own `linkedStripRects`; standalone clips from `clipRect` only — `automationRect` selects nothing |
| `:342-347`, `:2131-2134` | delete (dead) |

Untouched: playhead height (L1432), `laneDragHandleHeight`, keyboard lane navigation, static
panel floors (`LayoutConstants.swift:652, 1072`).

Tests (`LaneRowGeometryTests`): mixed heights; linked strips expanded/collapsed; a linked lane
between stems in model order; first/last rows; no standalone rows.

---

## 7. Tests

**`VolumeAutomationTests.swift`**: unity/empty; single point holds; two-point midpoint is the
dB midpoint; hold before/after; `insert` replaces keeping id; `move` cannot cross; `setGain`;
`remove`/`removeAll`; `mapFrames` keeps negatives, re-sorts, dedupes; the §2.6 shift regression;
decode normalisation from hand-written JSON (unsorted, duplicates, out-of-range, missing id);
legacy `AudioLane` JSON → `automation == nil` (pattern `HardPannedSplitTests.swift:79`);
`segments` full coverage incl. single-point and spans before/after/around the points;
`rampCount`: zero delta → 0, tolerance clamping, closed-form `maxDelta`, and the analytic
maximum-error check `[R2-2]` (`q = ln10·|Δ|/20`, `u = 1/q − 1/expm1(q)`, error =
`20/ln10·(log1p(u·expm1(q)) − q·u)`) ≤ tolerance for Δ ∈ {0.1, 2.5, 2.63, 30, 60}, plus a
100-point sampled check as extra coverage.

**`QuickTimeDemoBuilderTests.swift`** (new):
- Ramp construction at 24 and 23.976: assert with `getVolumeRamp(for:…)` (it returns the *next*
  ramp when queried before one) that ramps are contiguous, ordered, endpoints equal, boundaries
  at the expected rationals (one-frame 60 dB step at 23.976 → 1001/576000 s pieces).
- **PCM reference test** `[R2-7]`: synthesise a −20 dBFS tone with `TestAudioFileFactory`; build
  a composition + mix for an envelope (hold, −60 dip, one-frame step, single non-unity point);
  read it back through `AVAssetReader` with an `AVAssetReaderAudioMixOutput` carrying the mix —
  lossless PCM, no codec. Expected = input sample × envelope(t) evaluated at the same sample
  time from the same envelope maths; compare per sample with tolerance = ramp bound + 0.05 dB,
  including samples inside slopes. Also: +6 dB trim over 0→−12→0 (§4.4), sequential
  include/exclude and trim changes, nonzero span start.
- **Codec end-to-end**: `AVAssetExportSession` (`AVAssetExportPresetAppleM4A`) with loose
  tolerance and edge exclusion, on a −12 dBFS tone with a −24 dB dip (kept well above the
  codec floor).
- `replacingAudioMix` preserves `rate` and `laneAutomation`.

**`TimelineManagerTests.swift`**: add/set/remove reach the timeline and mark dirty; refuse a
linked lane; regrid and shift transform points; `LaneReorder` cases (§6.2, §6.3).

**`AutomationGainTableTests.swift`**: §3.2 cases.

**Undo tests** (view-model level, with a real `UndoManager`): §5.5 cycles.

---

## 8. Implementation order

1. **Model + tests** (§2, §7 first block).
2. **Editor prototype in the real timeline** (hard-coded envelope, no persistence). Must show:
   node drag never starts marquee or reorder; horizontal and vertical trackpad scroll over the
   sub-lane work; right-click gets the sub-lane's menu; a drag released outside the row ends
   cleanly; a dragged file over the sub-lane is refused and not imported. Fix the approach here
   if any fails.
3. **Playback** (§3) + table tests + the **measurement gate** (§3.3 a–g, recorded). Decide
   frame-stepped vs scheduled ramps on that evidence.
4. **Export** (§4) + builder tests incl. the PCM harness; **run the +6 trim measurement** and
   settle §4.4.
5. **Row geometry** (§6) with tests; verify reorder/marquee/lane-change with an expanded lane
   and with linked strips open and closed.
6. **Editor for real** (§5): well, both menus, transaction undo with redo, Set Level…, snapping,
   accessibility actions, shown-state persistence.
7. `FEATURES.md` entry (shape of "No Output (None) on a Lane", L1177-1220; includes §2.2
   compatibility, the WAV limitation, and the §4.4 trim contract), `KNOWLEDGE_BASE.md` notes
   (ramp maths, frame-stepped measurement results, +6 trim result, geometry index-space rule),
   `.claude/SESSION_STATE.md`.

joseph implements per step; clare reviews before each commit; gabriel/cecilia for the runtime
pass. Each step builds and passes tests before the next.

---

## 9. Acceptance criteria — runtime (user, Debug build)

- [ ] `A` well on every standalone lane header; none on linked strips.
- [ ] Click `A` → 48 pt sub-lane with a flat 0 dB line and "Volume +0.0 dB". Click → hides; well
      outlined; envelope still audible while hidden.
- [ ] Click adds a node; drag moves it; release applies **immediately at the current playhead**.
      Option-drag fine; snap to 0 dB; Set Level… exact. Double-click deletes an existing node; a
      double-click on empty space leaves one node. Menus as specified.
- [ ] ⌘Z / ⇧⌘Z after add / move / delete / Set Level / Reset / Remove Automation, two cycles;
      a no-op click adds no undo step.
- [ ] Nodes cannot cross neighbours or leave −60…0.
- [ ] Play across a −60 dip: ducks and returns; readout tracks the playhead; gate results (§3.3)
      recorded in `KNOWLEDGE_BASE.md`.
- [ ] Reorder across an expanded lane (incl. last row); marquee over an expanded lane (sub-lane
      only selects nothing; picture vs linked strips select independently); drag a clip
      vertically across an expanded lane; with linked strips open and closed.
- [ ] File drop on the lane strip imports; on the sub-lane it is refused.
- [ ] Trackpad scroll over the sub-lane scrolls the timeline.
- [ ] Create QT Demo with an automated lane: preview follows the envelope; trim and include
      change level without restarting the preview; exported file plays it in QuickTime Player;
      excluded lane silent; +6 trim behaves as measured in step 4.
- [ ] Save, quit, reopen: envelope and shown state restored; pre-feature project opens clean.
- [ ] Change frame rate and start timecode (including a shift that moves nodes before frame 0,
      then back): nodes keep their timecodes.
- [ ] Layout audit: header alignment, no hardcoded padding, light and dark.

Automated tests (§7) are the correctness bar; this list is the UX bar.

---

## 10. Resume instructions

Read `.claude/SESSION_STATE.md`, then `git status` / `git diff` to see which §8 step is in
progress. Steps depend on earlier ones: inspect the diff, keep unrelated changes, finish or
revert only the in-progress step. Plan: `~/.claude/plans/abstract-conjuring-crystal.md`.
Audit: `docs/audits/VOLUME_AUTOMATION_PLAN_AUDIT.md`.
