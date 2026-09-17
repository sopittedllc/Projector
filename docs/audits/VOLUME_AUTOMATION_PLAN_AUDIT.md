# Volume automation plan audit

Date: 2026-09-16  
Reviewed against: Projector commit `8c14034`, clean working tree before this audit  
Plan: `/Users/keegandewitt/.claude/plans/abstract-conjuring-crystal.md`

## Revision 2 review — current verdict

Reviewed the revised plan on 2026-09-16 against the same commit. **Substantially improved, but still needs the corrections below before implementation.** The original review remains below as historical context; its +6 dB envelope and six-frame segmentation objections refer to revision 1. This review accepts the revised plan's stated attenuation-only, apply-on-release, and separate-ducker scope as its design inputs.

Resolved at the planning level: source-WAV limitation, width accounting, ID-based row lookup, both lane menus, hidden-envelope indication, exact level entry, snapshot propagation, explicit compatibility behavior, and an early editor prototype. The new subdivision bound is numerically sound. Runtime validation remains outstanding.

### R2-1. Attenuation-only automation does not fix positive export trim

§1 says every value stays within AVFoundation's 0…1 range, but §4 still passes `linear(trimDB + envelopeDB)`. At +6 dB trim and 0 dB automation this is 1.995262; at −3 dB automation it is 1.412538. Thus an automated fade can cross from unsupported to supported values. Retaining the old slider does not isolate the issue to unautomated exports. Apple specifies 0…1 for [ramp endpoints](https://developer.apple.com/documentation/avfoundation/avmutableaudiomixinputparameters/setvolumeramp(fromstartvolume:toendvolume:timerange:)).

**Required correction:** remove the claim that all exported values are supported and decide how positive trim is handled for automated lanes. A supported amplification/render path is needed to preserve positive trim correctly. Alternatively, explicitly narrow the feature's trim contract; do not silently clamp or claim correctness for combinations left unresolved. Add a +6 dB trim test across a 0→−12→0 envelope. Keeping the supplied WAV's existing behavior out of scope is distinguishable from promising correct positive trim on the newly automated tracks.

### R2-2. Ramp math passes; complete the render boundary contract

For a ramp spanning 2.5 dB, I independently calculated the maximum interpolation error as **0.0898414312 dB**, at normalized position **0.47604779** for an ascending ramp. Midpoint error is 0.0896359668 dB; their difference is 0.0002054644 dB. The plan's ≤0.09 dB statement is correct. Descending ramps have the mirrored error profile.

An analytic check avoids treating 100 samples as proof: with `q = ln(10) * abs(deltaDB) / 20`, the maximum is at `u = 1/q - 1/expm1(q)`, and error is `20/ln(10) * (log1p(u*expm1(q)) - q*u)`. Handle zero separately. Use this or a conservative bound in tests; sampled tests are useful additional coverage.

`CMTimeMultiplyByRatio(duration, multiplier: k, divisor: n)` is an appropriate construction: Apple documents [exact rational preservation unless overflow occurs](https://developer.apple.com/documentation/coremedia/cmtimemultiplybyratio(_:multiplier:divisor:)). Compute each boundary once and derive durations by subtracting adjacent boundaries. Use composition-relative start time, checked Int32 conversions, finite/numeric times, strictly increasing boundaries, and exact final span endpoints. Do not later convert to a coarse timescale such as 600. At 24 fps, dividing a one-frame 60 dB transition into 24 ramps gives 1/576-second subdivisions; at 23.976 it gives 1001/576000 seconds.

Two missing contracts matter:

- `segments(from:to:)` must include constant leading/trailing holds over the requested span, including a **single non-unity point**, or the builder needs an explicit no-segments initial setter. As written, “node-to-node segments” plus `first segment` logic can leave a one-point −12 dB envelope with no mix instructions and therefore unity.
- `rampCount` advertises arbitrary `toleranceDB`, but the fixed 2.5 dB cap only establishes the stated 0.1 dB policy. Either support valid positive tolerances mathematically or make the API fixed-policy. Specify zero delta, invalid/nonfinite tolerance, and count overflow behavior.

### R2-3. Undo transaction rules still have concrete holes

`MultiTrackTimelineView.swift:2831` captures a timeline and registers a closure that only assigns that snapshot. `TimelineManager.timeline`'s observer (`:79`) only marks dirty. **Neither registers the inverse while undoing.** Therefore §5.5's statement that redo is symmetric because a whole snapshot is restored is incorrect. Register the inverse explicitly during undo/redo, and test edit→undo→redo plus a second cycle.

Capture the pre-edit envelope **before insertion**. §5.4 currently says insert, then begin the transaction; that order can make a newly added point appear unchanged and prevent its commit/undo. Capture before any preview mutation, compare on commit, then register undo immediately before the persistent mutation.

Also cover:

- No-op Reset and setting the existing numeric value: register nothing, just like no-op drags.
- Double-click existing node: first click may be unchanged. Double-click empty space: the first click **adds and commits** a node, so the second click is not automatically one clean deletion transaction. Specify whether this creates then deletes in two edits, is suppressed, or is handled as a distinct double-click action.
- External timeline changes/undo while a drag or level popover is active: cancel stale edits using document identity and lane/envelope revision checks. A lane UUID alone is not sufficient. Capture the current whole-timeline snapshot at commit if using snapshot undo, so unrelated changes during a visual preview are not rolled back.
- Numeric popover Cancel, view teardown, and removal while editing must clear transient preview state. Keep undo registration and mutation together; do not register after overwriting the old state.

### R2-4. Dropping shifted negative points corrupts surviving fades

`shiftAllContent(by:)` (`TimelineManager.swift:316`) retains negative clip positions. The proposed point transform drops negative frames. Example: nodes `(0, 0 dB)` and `(100, −60 dB)`, shift timeline content by −50. The audible envelope should start at **−30 dB** and reach −60 dB at new frame 50. Dropping the first shifted node leaves a single −60 dB point, incorrectly making the entire remaining envelope −60 dB.

**Required correction:** prefer preserving signed internal node positions during timeline shifts, while limiting interactive placement to nonnegative frames. This keeps the operation reversible and matches retained clip positions. If the nonnegative model is retained, insert a boundary point at frame zero evaluated from the old envelope before dropping points; document that shifting the timeline back cannot recover discarded history. Add this specific regression test. A generic `mapFrames` that drops negatives cannot preserve both audible shape and reversibility.

§2.4 also contradicts §4.2: a lane reclassified as linked is still automated in playback, cannot be edited via guarded mutations, and is excluded from the export automation snapshot. Pick one policy. Recommended: retain stored data but bypass it whenever the lane is outside standalone membership, consistently in playback and export. This avoids inaccessible active automation.

### R2-5. Geometry mapping is much better, but not complete

The ordinal→ID→model-index contract addresses the previously listed index-space errors. Complete these remaining details:

- Marquee must have separate bounds for the picture and expanded linked-audio strips. “Video row uses its actual height” can incorrectly select picture when dragging over a linked strip; walking standalone `laneRows` alone also omits linked clips. Use the total video group height to place following lanes, and individual child bounds for selection.
- The new centre-count reorder rule changes the interaction threshold. For equal 81-point rows, dragged centre must travel about **81 points plus hysteresis** to pass the next centre; the old rule triggers at `(0.5 + 0.18) * 81 = 55.08` points. This may be a valid redesign, but is not equivalent behavior. Specify whether centres are original or displaced; using animated/displaced geometry can feed back into targeting. Freeze baseline geometry for a gesture or cancel/rebase on layout changes.
- If the divider is absent after the last row, define how row displacement handles swapping that row. Blindly adding a divider to every dragged row does not match the table's stated convention. Test resulting slot positions, not only returned ordinals.
- `LaneReorder` is in the model layer, but `LaneRowGeometry` is currently described as view-built geometry containing CGRects. Put shared pure geometry types in an appropriate non-SwiftUI location or pass a small pure reorder metric type. Do not make the model depend on a view declaration.

### R2-6. Frame-stepped live playback is a conditional v1 choice

I would not require AudioUnit ramps solely from source review, but I also would **not approve the unverified claim** that AVAudioEngine smoothing makes several-dB steps click-free. The cited plan supplies no documented smoothing guarantee for the actual player→rate-converter→matrix-mixer graph. A render-cycle transition would not make main-queue frame updates track a continuous envelope accurately in any case.

Keep the listening/measurement gate, and expand it beyond the two-second fade: one-frame steep nodes are explicitly allowed, and seeks, main-thread load, MTC discontinuities, routing changes, and restart must also be exercised. Compare recorded gain trajectories with the intended envelope, separate from listening for clicks. Frame stepping can be accepted as an explicit preview compromise only if these checks support that decision.

The fallback is not a drop-in main-thread setter. Apple's [AudioUnitScheduleParameters documentation](https://developer.apple.com/documentation/audiotoolbox/audiounitscheduleparameters(_:_:_:)) describes events for the current render call, scheduled through a pre-render callback, with ramps scheduled across successive renders. Verify the matrix parameter supports scheduled events and define render-time state delivery, seek cancellation, and routing-reset restoration. Keep allocation, locks, UI work, and timeline traversal out of that callback.

The new cache also needs the base mute/solo/output-enabled and clip/lane gain product, not only `laneOfClip`: the frequent hook must never overwrite a muted player with the raw envelope gain. Test solo/mute/None at a frame transition, removing the last envelope, and moving a loaded clip between lanes.

### R2-7. Numerical tests need a correct reference signal

The proposed 50 ms RMS windows cannot reliably validate a 41.7 ms adjacent-frame transition while excluding ramp edges. Nor does the envelope's midpoint dB equal the RMS of an amplitude-modulated signal over a changing window. Compute the expected samples or window energy from the generated input and the same time interval; compare against that independent reference.

Use lossless PCM mix output for the precise envelope test, including samples within slopes and short transitions. Keep M4A and actual QuickTime exports as separate end-to-end tests with appropriate codec tolerance, alignment, and edge handling. A −20 dBFS tone attenuated by −60 dB reaches −80 dBFS, where lossy encoding behavior should not be mistaken for a ramp-math failure. Add sequential trim/include changes, one-point holds, span wholly before/after points, and nonzero export start.

Minor corrections: 48 points minus two 8-point insets leaves **32 editable points**, or 1.875 dB/point, not approximately 40. Fine drag and numeric entry address precision, but adjust the comment. Accessibility needs operable value/delete actions and a path to adding nodes, not just labeled elements. The acceptance phrase “heard on the next pass” should say the committed gain applies immediately at the current playhead position; it should not require looping back.

### Revision 2 recommendation

Keep the revised overall design. Correct positive trim, redo, negative-frame transforms, and empty/held-segment rendering before coding those paths. Resolve the linked-lane policy and geometry details in the same plan update. The rational subdivision approach is approved at the design level; the frame-stepped playback and NSView editor remain subject to the explicitly required prototypes and measurements. No application changes, builds, audio renders, or runtime UI checks were performed in this second review; verification consisted of source inspection, official API documentation, and an independent numerical calculation.

---

## Original revision 1 review

### Recommendation

Keep the standalone-lane envelope model, project persistence, automation sub-row, and export snapshot approach. Revise the audio design before implementation: the proposed export accuracy guarantee is false, positive gain is unresolved in **both** audio paths, and display-frame updates do not establish smooth playback. These are material to the user's objective of trustworthy music-against-picture references.

This is a source and API audit, not a runtime certification. No application code was changed, no audio was rendered, and no build or UI tests were run. The revisions below are recommendations, not newly approved product decisions.

## 1. Resolve gain support for export as well as playback — blocking

Plan §3.4 correctly questions `AVAudioPlayerNode.volume`, but treats the existing export slider as evidence that amplification works. `QuickTimeDemoBuilder.swift:186,528` only proves that Projector passes a value greater than one to AVFoundation. It does not establish that the result is amplified correctly.

Apple documents the supported range as 0…1 for both [AVAudioMixing.volume](https://developer.apple.com/documentation/avfaudio/avaudiomixing/volume) and [setVolume(_:at:)](https://developer.apple.com/documentation/avfoundation/avmutableaudiomixinputparameters/setvolume(_:at:)). Apple also documents 0…1 for [ramp endpoints](https://developer.apple.com/documentation/avfoundation/avmutableaudiomixinputparameters/setvolumeramp(fromstartvolume:toendvolume:timerange:)). A successful Debug experiment outside that range is implementation evidence, not a supported API contract.

**Revision:** make the first milestone a three-path test: timeline engine output, demo preview output, and decoded exported audio. Use a quiet calibrated signal, measure RMS/peak ratios for 0 and +6 dB, and test +6 dB automation combined with +6 dB trim: that is **+12 dB total**, approximately 3.981 times amplitude. Do not clamp the combined dB value to the envelope's +6 limit.

Choose an explicitly supported gain stage for live amplification and a supported export strategy. If AVAudioMix cannot meet the requirement, evaluate rendering an automated intermediate PCM mix, then muxing it with picture; reuse that rendered audio in preview to preserve agreement. This has cache invalidation and slider-latency implications, so the promise that every trim change is only an AVAudioMix rebuild must remain conditional until the spike is complete. Do not silently drop positive gain to preserve the current design.

The proposed matrix fallback needs parameter capability verification too. `configureMatrixMixerRouting` resets global volume to unity (`PlaybackEngine.swift:2328`), including when output mapping changes. If automation uses that parameter, every routing/restart path must restore automation **after** routing. Centralize gain application rather than leaving three callers assigning only `player.volume`.

Define clipping behavior when summing the supplied WAV and included lanes. Use signals with headroom for amplification tests, and separately test overloaded sums. Do not silently normalize exports or introduce a limiter without deciding that product behavior.

## 2. Replace the six-frame accuracy claim — blocking

Plan §4.1 claims that six-frame linear-amplitude ramps stay well under 0.5 dB from a dB-linear envelope even for a −60→+6 sweep. Duration alone cannot provide that guarantee: error depends on **dB change within each ramp**.

Counterexample: put −60 and +6 nodes six frames apart. At the midpoint, the desired gain is −27 dB. Linear interpolation between endpoint amplitudes 0.001 and 1.995262 yields amplitude 0.998131, or approximately −0.016 dB. Error is approximately **26.98 dB**. Even a 6.6 dB change within one ramp has about 0.61 dB midpoint error.

**Revision:** choose and test a numerical error tolerance, then subdivide according to gain change/error as well as time. For endpoint difference Δ dB, midpoint error is `20 * log10(cosh(ln(10) * abs(Δ) / 40))`; validate the maximum across the interval, not just endpoints or midpoint. A conservative small dB span per ramp is another practical policy.

Integer-frame ramp boundaries cannot approximate a steep transition between adjacent frame nodes by further subdivision. Keep editable points in timeline frames, but allow render subdivisions at rational sub-frame/sample times, or use a renderer that evaluates the envelope per sample. An alternative is to restrict slopes explicitly; that would change the proposed editing behavior.

Avoid subdividing long constant holds every six frames. Benchmark mix construction and slider updates with long, dense projects, and cache reusable segment/time data where appropriate.

## 3. Export time semantics are largely correct

The code confirms one composition track per lane (`QuickTimeDemoBuilder.swift:246`), `span.startFrame` becoming composition zero, and exact rational frame conversion (`:569`). Clipping envelope evaluation to the export span while holding outside its points is appropriate for handles, including exports beyond timeline duration.

The installed SDK `AVAudioMix.h:82–91` confirms default unity before the first setting, interpolation within a ramp, and holding the final value afterward. Because these parameters target composition tracks, use composition-relative time. See also Apple's [audio mix parameter API](https://developer.apple.com/documentation/avfoundation/avmutableaudiomixinputparameters).

Use one initial setting and chronologically ordered, non-overlapping positive-duration ramps with matching neighboring endpoint gains. Split at every envelope node and span boundary. Avoid a redundant initial setter when a ramp begins at zero if it complicates operation ordering. Test exact boundaries using `getVolumeRamp(for:...)`, and account for its documented behavior of returning the next ramp when queried before one.

Snapshotting rate and envelopes on `QuickTimeDemo` is sound. **Missing plumbing:** preserve both fields in `replacingAudioMix(_:)` (`QuickTimeDemoBuilder.swift:106`), every initializer, and test fixtures. Verify sequential include/exclude and trim changes do not lose the snapshot. Exclusion must bypass automation; exact linear zero is preferable if the criterion literally promises silence, since today's −120 dB is nonzero.

## 4. A currentFrame hook covers transport changes, not smooth audio

`currentFrame` is assigned by seeks, MTC handling, the gap timer, and periodic video updates. A centralized hook is a reasonable way to restore the correct gain on discontinuities. Keeping gain updates out of the 30-frame rescheduling throttle is correct. Including automation in `MixState` also correctly detects changes while stopped and restores unity when the last envelope is removed.

However, the normal observer runs on the **main queue at video-frame cadence** (`PlaybackEngine.swift:3026–3028`), and the gap timer is also frame based (`:1757`). At 24 fps, gain can step every 41.7 ms; UI work can delay that further. A smooth exported ramp and stepped timeline playback are not equivalent and may produce audible artifacts.

**Revision:** specify the required playback accuracy and implement audio-time gain interpolation/smoothing if the rendered signal demonstrates stepping. Use the frame hook for seek/reconciliation and the readout; do not label it sample-accurate automation. Cover transport restarts, seeks into a slope, MTC jumps, gaps, main-thread load, and output-device/mapping changes.

The claimed O(loaded players) cost also needs implementation detail: current `applyMixToLoadedPlayers` walks every lane and clip (`:2003`). Iterating the player dictionary while repeatedly searching the timeline does not fix that. Cache clip/lane lookup information and evaluate the envelope once per relevant lane per update. Rebuild caches on timeline replacement and undo. Do not perform file work or routing resets in the frequent gain path.

## 5. Row geometry audit: §6 misses several dependencies

Use a row description keyed by lane ID, containing visible ordinal, model index, row origin, clip region, automation region, and divider. Share it between layout and interaction. A bare height array is insufficient if callers mix index spaces.

| Site | Required correction |
| --- | --- |
| `MultiTrackTimelineView.swift:1133`, `baseTracksHeight` | Also use the actual expanded video-track height. Updating only `audioLanesHeight` still mis-sizes the new-lane drop region when linked strips are open. |
| `:2897–2910`, reorder target | Current source/held indices and count refer to `audioLanes`, whereas the proposed heights refer to `standaloneAudioLanes`. Map into visible ordinals, calculate there, then resolve IDs/model positions for commit. Do not preserve the existing assumption that stems are contiguous at the end. |
| `:2884`, lane-change target; `:1273,1302`, commit/preview | A visible-row delta cannot simply be added to an `audioLanes` index. Resolve a target lane ID with the same geometry for preview and commit. Reject linked video audio using standalone membership, including inferred legacy linked lanes. |
| `:1368,1388,1393`, last-row border/divider/placeholder | These still use model indices/count/emptiness. Make visual decisions from visible standalone rows and adopt one explicit last-divider convention. Preserve intentional model append indices for actual mutations. |
| `:1347`, reorder-handle context menu | There is a second lane menu on the header overlay. Add automation commands there too, preserving the documented context-menu/gesture modifier order. |
| `:3080–3118`, marquee | Advance by full expanded row height, but intersect clips only with their clip region; a marquee through automation alone must not select the lane's clips. Model expanded linked strips separately if preserving their selection behavior. |

Keeping `AudioLaneView` at 80 points and moving the entire expanded lane as one reorder unit is appropriate. The displacement of intervening lanes is the dragged lane's full height. Specify asymmetric-height reorder thresholds and test upward, downward, reversal, and multi-row jumps; “cross the slot centre” needs a precise definition of the dragged anchor and insertion position.

The new sub-row's proposed width is wrong if copied literally: `totalContentWidth` already includes the header, as shown by `AudioLaneView`'s outer frame (`:1325`) and `videoFileTrack`'s subtraction (`:1667`). Envelope width should be `totalContentWidth - headerWidth`, with the whole HStack framed to the total. Reuse horizontal scroll offsets and timeline-frame coordinates for drawing, hit-testing, and the pinned header.

## 6. NSView is reasonable, with an explicit interaction prototype

AppKit offers useful node hit-testing, double-click, context-menu, and drawing control. Existing capture wrappers make it a defensible choice. They do not prove that returning `self` from `hitTest` will exclude every ancestor SwiftUI gesture. Validate an actual editor inside this ScrollView before committing to the architecture.

Required prototype checks: node dragging never starts marquee/reorder; horizontal and vertical trackpad scrolling work; right-click resolves to the correct menu; dragging outside the row terminates cleanly; and drops do not bubble into a parent media-import handler. No drop handler on the sub-row alone does not prove rejection.

Declare a flipped coordinate system or convert AppKit's upward-positive Y coordinates explicitly. Inset the editable area so +6/−60 nodes remain visible and selectable. Draw visible segments and nearby nodes using dirty/visible bounds rather than scanning and drawing the entire envelope on every playhead tick.

**40-point precision issue:** 66 dB over 40 points is 1.65 dB per point even before edge insets; 0 dB is only about 3.6 points below the top. Add an exact-value entry or fine adjustment mechanism and unity snapping, or validate a taller editor. A decimal readout alone does not make a precise value achievable. A custom NSView also needs accessibility elements/actions for nodes; this is separate from deferring keyboard nudging.

## 7. Editing, persistence, and scope need tighter contracts

- **Undo:** register one operation for a changed edit at commit, with the pre-edit value captured at begin. Registering snapshot undo on every mouseDown creates empty undo entries for clicks and cancellation. Specify cancellation on view teardown, lane removal, or document replacement. Test double-click removal so the first click's drag transaction does not add an extra undo step. Reset, context-menu delete, and removal all need undo/redo coverage.
- **Drag audition:** the proposed `@State` preview updates the drawing only; playback continues using the committed timeline. State this explicitly as commit-only audition, or add a transient engine envelope override cleared on commit/cancel. Do not promise audible live riding with the proposed callback wiring.
- **Decoded invariants:** synthesized Codable bypasses insert/move validation. Validate or normalize sorted unique frames, unique IDs, nonnegative frames, finite gains, and gain bounds on decode and construction. Define deterministic same-frame replacement, including whether ID is retained. Guard invalid segment limits and empty/reversed ranges. Rename `isFlat` to `isUnity`/`isIdentity`: a constant −12 dB envelope is flat but must still apply gain.
- **Scope enforcement:** manager mutations, engine evaluation, and export snapshot capture should restrict automation to standalone membership, rather than relying only on absence of the button. Define what happens if lane classification later changes.
- **Timeline edits:** document that lane automation stays at absolute timeline frames when clips move, trim, split, or change lanes; it travels with a reordered lane. Specify behavior for frame-rate changes, duration shortening, and points beyond content. This is especially relevant to replacing a music cue with a revised version.
- **Hide versus disable:** hiding must leave automation active. Consider a persistent header indication for an automated but collapsed lane. Do not conflate absence of a visible editor with bypass.
- **Project compatibility:** optional fields with defaults correctly support old projects in the new app. “Version is never read” is imprecise: it is decoded, but not used to select a migration. Older builds can ignore and then discard new automation on save; distinguish backward loading compatibility from old-app round-trip preservation.

## 8. Scope insight: which music receives automation?

The externally supplied stereo WAV is inserted separately (`QuickTimeDemoBuilder.swift:227`); it is not one of the automated timeline lanes. This feature can duck included standalone lanes against that WAV, but cannot automate the supplied primary music WAV itself unless the workflow changes.

Make this limitation explicit in the feature description and validate the intended reference workflow before expanding implementation scope. If the user's target is to ride the primary supplied music against dialogue, standalone-lane automation alone may not satisfy it. Also explain that export trim is added to automation while legacy lane/clip volume and timeline monitoring decisions retain their current export behavior; “playback and export match” must refer to the same source and gain conditions.

## 9. Revised validation and implementation sequence

1. Define the supplied-WAV scope, render accuracy tolerance, clipping behavior, and whether drag audition occurs during movement or at commit.
2. Prove supported gain and smoothness through engine, preview, and export, including combined +12 dB. Choose the audio architecture before investing in the editor.
3. Implement validated envelope evaluation and the render representation. Test steep adjacent nodes, holds, span clipping, fractional rates such as 23.976/29.97, and numerical error inside each segment.
4. Implement live/export integration, snapshot propagation, and reset/restart behavior. Use a generated low-level tone and decode PCM output to measure gain over time; an AVAssetExportSession test harness is feasible even though the repository lacks one today. Keep numerical render checks distinct from UI listening checks.
5. Implement the shared visible-row geometry and test mixed heights plus linked lanes both expanded and collapsed, interleaved model order, first/last rows, and no standalone rows.
6. Prototype the editor in the real timeline, then finish commands, transaction undo, persistence, accessibility, and performance checks.
7. Run the manual user workflow with preview trim/include changes, export handles, QuickTime playback, save/reopen, and undo/redo after reopening or timeline replacement as applicable.

The proposed `PlaybackEngineTests` assertion cannot directly access `MixState`: it is private (`PlaybackEngine.swift:3299`). Test observable/applied gain through a narrow internal seam or extract a pure internal mix signature/evaluator. Equality changing is useful but does not prove the audio output changed. Likewise, “audibly louder” and a V-shaped dip are useful smoke checks, not calibrated correctness tests.

Most cited source locations are current, with minor line drift. The important inaccuracies are behavioral assumptions above, rather than stale filenames. The acceptance criteria are testable once tolerances and editing semantics are specified; several persistence, geometry, and envelope criteria are automatable despite §9's blanket runtime-only wording.

Finally, replace §10's blanket `git checkout -- <files>` recovery advice with inspection of the working diff and preservation of unrelated changes. Implementation steps depend on each other and should not be discarded indiscriminately. Keep the original plan intact and apply these revisions to the implementation plan before coding.
