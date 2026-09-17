# Volume automation implementation audit

Date: 2026-09-16  
Baseline: `8c14034`, with the uncommitted automation implementation  
Scope: model, persistence, manager mutations, timeline editor, playback gain, QuickTime preview/export wiring, and tests

## Codex implementation follow-through — current status (2026-09-16)

At the user's request, Codex implemented the remaining export-verification and stale-editor fixes. **The outstanding code and automated-test findings from the third review are addressed.** Earlier reviews below are historical.

### Changes made

- Replaced the print-only positive-trim test with assertions over flat plateaus at +6/−6/+6 dB. The lossless PCM tolerance is 0.05 dB, so unity clamping, silence, or failure to apply the envelope fails the test.
- Added a production-path QuickTime test that generates real picture and audio, calls `makeDemo`, changes trim and lane inclusion after assembly, calls the real `.mov` exporter, and decodes the exported file without attaching another mix. It verifies picture, one rendered audio track, five-second duration, +6 dB head/tail handles, and −6 dB at the automated dip. A loud excluded lane would cause these checks to fail. The codec tolerance is 0.3 dB.
- The numeric editor now captures the envelope when its popover opens. Submission rejects changed/deleted envelopes and non-finite values, preserves other nodes, clamps valid levels, and avoids no-op undo entries. Added regressions using the same edit helper as the UI.
- Added a document-session identity changed by project open/new, with editor view identity and transaction guards tied to it. Automation undo from an old project no longer changes a reopened project with matching IDs; reopening cancels old popover/gesture state. Added undo/session regressions. The undo helper explicitly runs on the main actor.

### Verification

The focused export/editor run passed, including a real movie export and read-back. After all changes, the full `ProjectorTests` bundle passed: **429 tests, zero failures**. `git diff --check` passed. Existing XCTest deployment-target linker warnings remain. The first full rebuild exposed a missing main-actor annotation on the updated undo helper; it was corrected before the successful final run.

Final result bundle: `/private/tmp/Projector-Automation-Fixes-Full-2.xcresult`.

Positive amplification is now enforced by both PCM and actual QuickTime-output tests on this machine. That is measured compatibility evidence; it does not change Apple's documented volume range or establish behavior on every supported OS release.

Remaining validation is interactive/runtime scope: actual gesture behavior and the formal live-playback seek/MTC/load/device-change measurements. No manual playback/gesture sign-off is claimed here. Changes remain uncommitted.

---

## Third implementation review (2026-09-16)

**The previously identified preview, scrolling, gain-refresh, and model defects are now addressed. The remaining major gap is export verification, not missing automation wiring.**

I independently reran the full unit-test bundle: **424 passed, 0 failed, 0 skipped**, confirmed by `xcresulttool`. The existing XCTest deployment-target linker warnings remain. `git diff --check` passed. No application source changes were made by this review.

### Fixes verified in source

- `VolumeAutomationLaneView.swift:149–152` clears preview on every end callback, including no-op drags and the existing teardown callback. The old preview-masking bug is addressed.
- `VolumeAutomationStripView.swift:36–44` now applies the horizontal header offset and stacking order, matching the expanded editor.
- `PlaybackEngine.swift:3394,3421` diffs **effective** automation using standalone membership. A classification change now changes the mix signature and triggers immediate gain reapplication. A dedicated loaded-player integration regression would still strengthen coverage, but the source-level cause is fixed.
- `VolumeAutomation` clamps stored frame bounds, interpolates using Double differences, rejects non-finite ramp deltas, and solves the subdivision limit against the true maximum error. These address the three previously reproduced model defects.
- `LaneReorder.displacement` now uses height plus a separator rather than the last row's separator-free original pitch, addressing the one-point preview discrepancy.

### Independent model verification

Compiled the latest model into a temporary harness and repeated the prior checks. Extreme-frame interpolation now returns −30 dB without trapping; NaN ramp delta returns zero without trapping; shifted fades remain reversible; single-point holds remain correct. A sweep of 6,000 deltas for each tolerance in `{0.01, 0.1, 1, 2, 3, 6, 10}` stayed within the requested error bounds using an independent analytic maximum-error calculation. The 2 dB case that previously exceeded tolerance now stays below it.

### Remaining findings

1. **Medium — positive-trim behavior is not asserted.** `ProjectorTests/QuickTimeDemoBuilderTests.swift:554–599` remains a print-only measurement test. If amplification regressed to unity or silence, this test could still pass. Replace prints-only validation with numerical assertions against expected window energy or plateau gain.
2. **Medium — final movie output remains unverified.** The suite still reads `AVAssetReaderAudioMixOutput`; it does not invoke `makeDemo`→`QuickTimeDemoBuilder.export` and decode the resulting `.mov`. Preview/mix wiring is confirmed, but a final-file correctness claim still needs that end-to-end check. The positive-gain API compatibility qualification in the original audit also remains applicable.
3. **Lower-priority editing policy — Set Level captures on submit.** `VolumeAutomationLaneView.swift:200–211` still starts the transaction when Return is pressed, not when the popover opens. An intervening change to the same surviving node is therefore not treated as a conflict. Either document that numeric submission deliberately edits the current node or capture/check the original envelope at popover opening. Envelope equality alone also does not establish document identity if a document is replaced with matching IDs/data. These are narrower caveats than the earlier missing undo/stale-drag implementation.

The formal live-playback measurement gate and interactive UI sign-off are still outstanding in session state. This review did not exercise the app's gestures, listen to playback, or open a rendered movie in QuickTime Player. No new blocker was found in the corrected core model or gain wiring within this review's scope.

**Recommendation:** the reviewed fixes are sound. Finish the export assertions and final-file check before claiming export has been fully verified; complete the remaining runtime gate separately. Do not continue treating the resolved findings in earlier sections as current defects.

Evidence: `/private/tmp/Projector-Automation-Review3-20260916.xcresult`; independent harness `/private/tmp/projector-model-review3-4zef_sjn`.

---

## Second implementation review (2026-09-16)

**The main geometry and undo implementation gaps have been addressed. Remaining findings prevent an unconditional completion sign-off.** QuickTime automation wiring remains present.

Fresh verification: the full `ProjectorTests` command completed successfully with **420 distinct passing tests, zero failed/skipped tests in the log**. This includes the new geometry and undo tests. `git diff --check` passed. The build emitted XCTest framework deployment-target linker warnings (test targets target macOS 12 while the linked frameworks target macOS 14); it was not warning-free. No application source was changed by this follow-up review.

### Resolved or substantially addressed

- **Finding 1, geometry:** `TrackGeometry` now accounts for both collapsed and expanded automation rows, separates picture/linked strips/clip bands, and maps visible rows to model indices. Marquee, height calculations, lane-change targeting, and reorder use this geometry. Reorder modifiers now wrap the whole lane and automation group. The previous broad fixed-height regression is addressed in source, with new tests. Interactive scroll/drag behavior still needs runtime verification.
- **Finding 2, undo:** add/edit/delete/reset/remove now register inverse automation operations through `AutomationUndo`, and undo/redo cycling has dedicated tests. Commit checks compare the persisted envelope with the captured one. This resolves the missing-undo finding and catches changed-envelope conflicts during a drag; it does not resolve all editing-state cleanup issues below.
- Numeric Set Level, fine drag, snapping, and accessibility work have been added. Their earlier complete absence is no longer a current finding.

### Still open, in priority order

1. **Medium — export verification remains incomplete.** `QuickTimeDemoBuilderTests.swift:554–599` is unchanged: the positive-trim test prints ratios but asserts neither. There is still no test invoking the real `.mov` export path. A green test run therefore still cannot confirm positive amplification or final-file output. Add enforceable gain assertions and a `makeDemo`→`export`→decode test; retain the distinction between observed above-unity behavior and documented API support.

2. **Medium — no-op drag leaves preview state authoritative.** `VolumeAutomationLaneView.swift:146–151` forwards `onEndEdit` unchanged and clears `previewAutomation` only inside `onCommit`. `VolumeAutomationEnvelopeView.mouseUp` omits commit when the gesture returns to its original value. Drag a node away and back, release, then change the stored envelope externally: the retained preview can mask that change. Always clear preview on end/cancel/no-op, separately from applying a mutation. The new undo-helper tests do not exercise this view-state sequence.

3. **Medium — collapsed header still scrolls away.** `VolumeAutomationStripView.swift:37–59` still has neither a `timelineHeaderScrollOffset` environment value nor the compensating header offset. The expanded editor has both. Pin the collapsed Add/Show header the same way and verify it while horizontally scrolled.

4. **Medium — classification changes can still leave live gain stale.** `PlaybackEngine.MixState.LaneMix` still stores raw automation without effective standalone eligibility. The cache correctly rebuilds, but the diff can remain equal and skip applying restored gain when a lane becomes linked. Original finding 4 and its requested loaded-player regression test remain applicable.

5. **Medium hardening — model edge cases are unchanged.** The integer subtraction and unchecked delta-to-count conversion, and the overly general tolerance guarantee, remain as described in original finding 6. These do not invalidate the normal default-tolerance path that passes tests, but the public model contract is still broader than its safe behavior.

Additional editing caveats: the stale check uses envelope equality, not document identity; reopening/replacing a document with matching lane IDs and envelope values can evade it if the editor remains mounted. Set Level captures its transaction on submission (`VolumeAutomationLaneView.swift:197`) rather than when the popover opens, so it does not detect changes made while that popover was open. Decide whether such a submission deliberately applies to the current node or should be canceled, and test that policy.

### Small geometry issue to finish

`LaneReorder.displacement` uses the dragged row's original `pitch`. The last row's pitch excludes a divider. When the last row moves upward, rows pushed down need the dragged row's **height plus the newly preceding separator**, not just its old last-row pitch. Conversely, moving the first row to last shifts that row's final origin by the total crossed content heights, with separator placement recalculated for the final order. Add a test comparing preview origins against recomputed final geometry for first↔last swaps; the present assertions about old pitch alone do not establish pixel alignment. This is a one-point preview discrepancy, distinct from the now-fixed broad geometry problem.

### Evidence and next gate

- Log: `/private/tmp/Projector-Automation-Reaudit-20260916.log`.
- Result bundle: `/private/tmp/Projector-Automation-Reaudit-20260916.xcresult`.
- Full unit-test invocation and scope match the original audit; this follow-up did not run UI tests, listen to playback, or export/open a final movie.
- Session state still acknowledges the live-gain measurement gate has not been formally recorded. The user's positive listening/UI feedback is useful but does not substitute for the remaining seek/MTC/load/device-change checks.

Recommendation: keep the geometry and undo changes; fix preview cleanup and collapsed-header pinning, make export tests enforce the claimed output, and complete the recorded runtime checks before marking the feature finished. The original findings below are retained as history; use the status above for what is still current.

---

## Original implementation audit

### Verdict

**Confirmed: standalone-lane automation is connected to QuickTime preview and export. Not confirmed: the entire feature is finished or ready to ship.** The renderer's attenuation path has useful passing PCM tests, but timeline geometry and editing transactions remain incomplete. The supplied primary mix WAV is intentionally not automated.

I independently ran the full `ProjectorTests` bundle: **396 passed, 0 failed, 0 skipped** on macOS 26.7, arm64. All eight `QuickTimeDemoBuilderTests` passed. This was a fresh build/test run, not a repetition of Claude's report. No application source was changed during this audit, and no commit was made.

The working tree changed during the earlier Step 1 inspection as editor work progressed. Findings below describe the implementation inspected during the final test run; the session state itself still lists geometry, production editor work, and the playback measurement gate as outstanding.

## Findings requiring follow-up

### 1. High: new rows break existing timeline hit-testing and reorder geometry

**Location:** `Projector/Views/Timeline/MultiTrackTimelineView.swift:1398–1431`, plus its unchanged fixed-height geometry helpers.

Every standalone lane now adds either an 18-point collapsed strip or a 48-point editor. Reorder, marquee, lane-change targeting, and remaining-height calculations still use the old row pitch. This affects projects even before users add any nodes, because every lane receives the collapsed strip. The source explicitly acknowledges the mismatch as future Step 5 work.

The reorder offset/z-index modifiers at lines 1394–1396 also apply before the automation sibling is added, so the clip/header row moves while its automation row stays behind.

**Correction:** implement the shared visible-row geometry before treating this as complete. Include collapsed strips as well as expanded editors; move the entire lane group during reorder; test preview and committed destinations with mixed row heights and linked video-audio strips open/closed.

### 2. High: automation edits have no undo or stale-edit protection

**Locations:** `MultiTrackTimelineView.swift:1413–1415,1423–1427`; `VolumeAutomationEnvelopeView.swift:464–471`; `VolumeAutomationLaneView.swift:137–140`.

The edit callbacks only set `isEditingAutomation` and call `timelineManager.setAutomation`. They register no undo for node add/move/delete/reset or adding an envelope. Pressing Undo after an automation edit can therefore undo an earlier unrelated operation while leaving the automation edit in place.

`mouseUp` compares the working envelope to its original, but never checks whether the underlying document/lane envelope changed during the gesture. A timeline replacement or undo can be overwritten by the stale drag when the NSView remains mounted.

There is also a preview cleanup hole: moving a node away and back to its original position sets `previewAutomation`, then `mouseUp` skips `onCommit` because the final envelope is unchanged. Only `onCommit` clears that preview. The leftover local copy can mask later external envelope changes.

**Correction:** implement lane-scoped inverse undo/redo; validate document identity and the current persisted envelope before committing; and clear preview on every end/cancel/no-op path independently of commit. Test add→undo→redo, delete/reset, a no-op drag followed by external changes, and undo/document replacement during a drag.

### 3. Medium: positive-trim test cannot detect incorrect gain, and actual QuickTime output is untested

**Locations:** `ProjectorTests/QuickTimeDemoBuilderTests.swift:554–599`; `QuickTimeDemoBuilder.swift:666–667,709–712`.

`testMeasurePositiveTrimOnAutomatedLane` reads PCM and prints ratios, but contains no gain assertions. A result of unity, an incorrect fade, or silence could still pass if reading succeeds. The session's measured ~1.994× amplitude is useful experimental evidence; the passing test does not enforce that behavior.

The new tests exercise `AVAssetReaderAudioMixOutput` and the mix parameter builder. None invokes `QuickTimeDemoBuilder.export` or decodes an exported `.mov`, and none exercises `makeDemo` end-to-end with real source placement. Consequently the suite verifies neither the final H.264/QuickTime export path nor positive gain through that path.

Additionally, the implementation still supplies ramp endpoints above unity for positive trim. Apple's documented supported interval remains [0…1](https://developer.apple.com/documentation/avfoundation/avmutableaudiomixinputparameters/setvolumeramp(fromstartvolume:toendvolume:timerange:)). Measured behavior on this machine is not a cross-version API guarantee. This is not evidence that amplification currently fails; it limits the strength of the compatibility claim.

**Correction:** turn measured ratios into assertions against the expected waveform/window energy, preferably with flat plateaus. Add an actual `.mov` export-and-decode test through `makeDemo` and `export`, covering a nonzero span start, handles, trim changes, and excluded lanes. Document the positive-trim compatibility decision separately from measured success on this OS.

### 4. Medium: live gain can remain stale when lane classification changes

**Location:** `Projector/Managers/PlaybackEngine.swift:3370–3464`, `MixState.LaneMix` and `updateTimelineProperties`.

`AutomationGainTable` correctly bypasses automation outside standalone membership. However, `MixState` does not record effective standalone membership, `splitChannel`, `ownerVideoReelId`, or the clip source classification used to infer legacy linked lanes. Merely including the raw stored envelope does not detect a classification change when that envelope remains identical, despite the new comment claiming it does.

On standalone→linked reclassification, the rebuilt cache drops that envelope but the mix comparison can remain equal, so loaded player gain is not restored immediately. The per-frame hook also stops visiting that lane; it cannot fix the stale attenuation. The reverse change can remain stale while stopped until playback advances or another mix change occurs.

**Correction:** diff effective automation eligibility/envelope (or effective gain-table state), then apply gain when eligibility changes. Add an engine integration test with an already-loaded clip, rather than only constructing a fresh gain table. This matters specifically because the plan promises consistent bypass for reclassified lanes.

### 5. Medium: collapsed automation controls do not stay with the pinned header

**Location:** `Projector/Views/Timeline/VolumeAutomationStripView.swift:37–59`.

The expanded editor header counter-shifts by `timelineHeaderScrollOffset`, as does the normal lane header. The collapsed strip header does not. Horizontal scrolling therefore moves its Add/Show control out of the pinned header column and can take it offscreen.

**Correction:** apply the same header offset and stacking behavior used by `VolumeAutomationLaneView`. Verify both collapsed and expanded states at nonzero horizontal scroll.

### 6. Medium hardening: the public model accepts values that can trap or violate its error contract

**Location:** `Projector/Models/Timeline/VolumeAutomation.swift:140–141,362–373`.

I compiled a copy of the actual model in a temporary standalone harness and reproduced:

- Points at `Int.min` and `Int.max`, then `gainDB(at: 0)`: integer subtraction traps before conversion to Float. The model and decoder accept these frames and document support for any signed Int. Normal timeline positions are not affected.
- `rampCount(forDeltaDB: .nan, toleranceDB: 0.1)`: the Float-to-Int conversion traps. The current envelope renderer produces finite bounded deltas, so this is a public-helper hardening issue, not a demonstrated failure in ordinary exporting.
- The 0.99 midpoint margin is sufficient for the default 0.1 dB tolerance but is not a general maximum-error guarantee. For delta ≈36.37 dB and tolerance 2 dB, the returned subdivision produces approximately **2.06028 dB** maximum error. A sweep of 6,000 deltas over 0.01…60 dB found maximum errors ≈0.0098035 at tolerance 0.01 and ≈0.0982613 at tolerance 0.1; those intended settings behaved correctly.

**Correction:** bound/reject unsafe model inputs or use overflow-safe interpolation; define invalid delta handling; and either restrict the supported tolerance interval or solve against the true maximum error. Preserve the current default path. Add targeted regressions rather than broad duplicated tests.

## Confirmed implementation paths

- `AudioLane` persists optional automation and shown state with defaults for legacy projects.
- Manager mutations store envelopes; frame-rate and timeline-start transforms now transform their points. Signed points preserve the shifted-fade shape. My independent shift-and-reverse check and single-point-hold check passed.
- `AutomationGainTable` incorporates mute, solo, output-disabled state, clip/lane gain, and standalone-only automation. The frequent gain hook uses that table rather than the rescheduling throttle.
- `makeDemo` captures standalone-lane envelopes and frame rate. Both initial mix creation and `makeAudioMix` use the envelope; excluded lanes bypass it.
- `replacingAudioMix` preserves frame rate, envelope snapshots, and media-access lifetimes.
- `QuickTimeDemoSheet` assigns the generated mix to preview, rebuilds it on level changes, and rebuilds the current mix again before export. `QuickTimeDemoBuilder.export` sets `session.audioMix = demo.audioMix`.
- Export ramps use composition-relative times and rational sub-frame boundaries. Tests cover 24 fps, a one-frame transition at 23.976, a nonzero span start, single-point holds, and successive mix replacements.

Those paths support the narrower conclusion that automation is included in QuickTime creation. They do not establish that the primary supplied WAV is automated; it explicitly passes a nil envelope.

## Test quality and remaining runtime checks

The PCM test is substantive: it compares rendered window energy with an independently generated reference waveform through holds and slopes. Its limits should remain visible:

- It measures 10 ms RMS windows, not per-sample error, despite some comments describing it as sample-accurate verification.
- It excludes ±15 ms around the end of the one-frame ramp and ±1 ms around other nodes. Preserve the measured transition artifact as a separate assertion/characterization instead of simply treating excluded samples as validated.
- The −60 dB hold puts the −20 dBFS peak tone near −83 dBFS RMS, below the harness's −80 dBFS threshold. Those windows are skipped. Assert coverage counts for each intended region and validate the deep hold using suitable absolute-amplitude checks or a more suitable floor.
- There is no recorded independent live-playback smoothing/seek/MTC/device-change measurement in this audit. The trace hook is instrumentation, not evidence that the gate passed.
- Fine adjustment, Set Level, accessible node actions, and production undo are still absent from the inspected prototype. Treat them as unfinished planned work, not runtime-confirmed features.

I did not run the five interactive NSView prototype checks or listen to a final movie in QuickTime Player. The session file records the user's earlier positive UI feedback, but that is distinct from this audit's evidence.

## Verification record and commit recommendation

Command: `xcodebuild test -quiet -project Projector.xcodeproj -scheme Projector -configuration Debug -destination 'platform=macOS' -only-testing:ProjectorTests`.

- Result: **396 passed, zero failed/skipped**, verified with `xcresulttool`.
- Result bundle: `/private/tmp/Projector-Automation-Audit-20260916-verified.xcresult`.
- Build/test log: `/private/tmp/Projector-Automation-Audit-20260916-verified.log`.
- Model edge-case harness: `/private/tmp/projector-step1-audit-weyt0zrp`.
- `git diff --check` passed for tracked changes.

One commit per coherent plan step is reasonable, but the working tree mixes those steps, including shared Xcode project registration changes. Stage by step and verify that each staged state builds; do not stage the entire project file as “Step 1” if it references editor files left out of that commit. No commit is authorized or performed by this audit.

The next completion gate is to fix the geometry and editing transactions, add enforceable positive-trim and final-movie checks, and finish the live/UI measurements. The existing green bundle is good evidence for the tested model and mix behavior; it is not a substitute for those missing checks.
