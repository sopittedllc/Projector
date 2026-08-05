# Session State

> **Last Updated**: 2026-08-05
> **Status**: MEDIA OFFERS TIED TO THE MEDIA — awaiting runtime verification
> **Branch**: main

---

## Optimize and consolidate only when there is work (2026-08-05)

Both media-housekeeping offers now answer to the media alone, and nothing marks
work that is already finished.

### What was wrong

- **The banner outlived the work.** It was `@State`, refreshed only when the
  *number* of media items changed — which optimizing does not do. Optimizing from
  the header button left it advertising a finished job. Only the banner's own
  Optimize button cleared it, by hand.
- **Consolidating reappeared after optimizing.** Optimized output is written to
  `ProjectFolder/Optimized Media/`, a sibling of the `.projector` package, but
  `externalMediaItems` tested the package path only. Every optimized file read as
  external media, so finishing an optimize pass raised the Consolidate button —
  offering to copy the app's own output back into the project.
- **Green "done" markers never left.** A checkmark in the media grid and a
  stopwatch on timeline clips marked completed work rather than anything actionable.

### What shipped

- `ProjectFolders` in `Managers/ProjectMediaLibrary.swift` — the project's folders
  (package, `Optimized Media`, `Raw Files`) and a component-wise containment test.
  Matched by folder name, not by claiming the enclosing directory, so a project
  saved to the Desktop does not consider the Desktop consolidated. String prefixes
  were wrong twice over: `Cut.projector` prefixes `Cut.projector.backup`, and the
  same file arrives spelled `/var/…` or `/private/var/…`.
- `OptimizationViewModel` takes its folder URLs from those constants, so the two
  spellings cannot drift apart and re-break the containment test.
- The banner is derived from the library, never stored — it appears when something
  qualifies and vanishes when nothing does. `evaluateOptimizationSuggestion` and
  `reevaluateOptimizationSuggestion` (two near-identical copies of the rules) gone.
- `OptimizationStatusHelper.isProductionCodec` — one rule shared by button, badge
  and banner.
- Removed: the optimized checkmark and stopwatch, the `isOptimized` plumbing that
  fed them, the now-unused `mediaLibrary` dependency of `VideoTrackView` and
  `AudioLaneView`, the never-used `OptimizationSuggestionManager` and
  `OptimizationSuggestionCompact`, and the two unreachable suggestion cases
  (`playbackStutter`, `largeProjectSize`) that only that manager could produce.

### Still to verify at runtime

Import heavy media, optimize from the **header** button (not the banner), and
confirm the banner clears itself and the Consolidate button does not reappear.

---

## Professional codec support (2026-08-05)

Projector now plays formats macOS has no decoder for on its own — Avid DNxHD/DNxHR,
AVC-Intra, DVCPRO HD, HDV, XDCAM, MPEG IMX, Apple Intermediate, Uncompressed 4:2:2.

### The finding

macOS ships decoders for ProRes, H.264, HEVC, AV1, JPEG and MPEG-4 only
(`/System/Library/Video/Plug-Ins`). Everything else lives in Apple's free **Pro Video
Formats** package and is unreachable until an app calls
`VTRegisterProfessionalVideoWorkflowVideoDecoders()` once per process — Apple's
instruction from WWDC20 session 10090. Projector had no VideoToolbox code at all, so a
DNxHD reel imported looking healthy (right duration, frame rate, timecode) and played
black with no explanation.

**The registration call is load-bearing.** Measured on a real DNxHD reel with the
package installed:

```
BEFORE registration: VTDecompressionSessionCreate = -12906 (codecNotFound)
AFTER  registration: status = 0, session = true
                     isPlayable=true, isDecodable=true, frame decoded 1920x1080
```

The package alone changes nothing. That one call is the whole feature.

### What shipped

- `Managers/ProVideoFormats.swift` — one-time registration, package detection, Apple URLs
- `Managers/VideoCodecSupport.swift` — codec identity, decodability, install eligibility
- `Managers/ProVideoFormatsInstaller.swift` — link discovery, host validation, download
- `Views/ProVideoFormatsInstallSheet.swift` — progress, installer hand-off, relaunch
- Registration at launch; codec probe at import; alert naming the codec; a
  codec-unavailable state replacing the black frame
- `com.apple.security.network.client` — **first networking in the app**

### Traps paid for

- **The install directory is not named after the package.** The installer is "Pro Video
  Formats"; its payload lands in `/Library/Video/Professional Video Workflow Plug-Ins`
  (holding `DNXDecoder.bundle`). Guessing the obvious name made
  `packageAppearsInstalled` permanently false. Harmless only because decodability is
  always decided by probing the file, never by looking for a directory.
- **Apple signs the package, not its disk image.** `ProVideoFormats.dmg` is
  `not signed at all`; `ProVideoFormats.pkg` is signed *Apple Software Update* and
  notarized. Trust rests on the download URL being HTTPS on `updates.cdn-apple.com`
  plus Gatekeeper inside macOS Installer. `SecAssessment` is not in the public SDK, so
  no local assessment is attempted.
- **Relaunch order matters.** Launching the replacement before calling
  `NSApp.terminate` leaves two instances whenever termination is interrupted — the
  unsaved-changes prompt sits behind the window just handed to the user. The
  replacement is now started from `applicationWillTerminate`, so it only happens once
  quitting is actually going ahead.
- **The generic error drowned the specific one.** `PlaybackEngineError.notPlayable`
  raised "The video file cannot be played." *first*, so the vague message was the one
  read. Now filtered by `showUnlessMissingDecoder`; every other error still surfaces.

### Verified / not verified

Verified: decode before-and-after (above); build clean; suite green; the user ran the
whole flow — alert named the codec, download, macOS installer, relaunch.

**Not runtime-verified**: the removed duplicate alert and the relaunch fix. With the
package installed neither path is reachable on this machine any more. Both build and
are covered by unit tests, but nobody has watched them behave.

### Test flake (pre-existing, unrelated)

`MIDISyncActorTests.testMIDISyncStateEmpty` and
`SplitOfferCoordinatorTests.testABatchWithNothingToOfferReleasesNothing` intermittently
do not report; the count alternates 154/155 across runs with **zero failures**. Neither
touches codec code. Matches the flake noted below from the earlier session.

---

## Timing: resolved and verified

The 90-minute drift test the user asked for is done, along with the
rolling-playback check that was left unfinished.

### Method

`scripts/make-reference-reel.swift` builds a reel that cannot disagree with
itself: true 23.976 (frame duration 1001/24000), a real timecode track, and
every frame's timecode drawn into the picture from the same number the track
starts from. A 90-minute one - 129,600 frames, tmcd 01:00:00:00, ending
02:29:59:23 - lives at `~/Desktop/ProjectorRefReel_90min.mov` (160 MB; delete
when done).

Testing against a generated reel rather than a delivery is the whole point: it
is the only way to tell an app bug from a file that drifts against its own
burn-in, and both were happening.

### Result: zero drift across 90 minutes

Seeked to seven positions, comparing the readout against the burned-in timecode
and the drawn frame index:

| Position | Burn-in | Frame | Expected |
|---|---|---|---|
| 01:00:00:00 | 01:00:00:00 | 0 | 0 |
| 01:15:00:00 | 01:15:00:00 | 21600 | 21600 |
| 01:30:00:00 | 01:30:00:00 | 43200 | 43200 |
| 01:45:00:00 | 01:45:00:00 | 64800 | 64800 |
| 02:00:00:00 | 02:00:00:00 | 86400 | 86400 |
| 02:15:00:00 | 02:15:00:00 | 108000 | 108000 |
| 02:29:59:23 | 02:29:59:23 | 129599 | 129599 |

Play/stop also agrees exactly now, tested at two run lengths (01:30:20:01 and
02:00:14:06).

## Fixed today

- `73e98a4` a detected timecode is carried by its counting **grid**, not the
  ratio of real rates. 23.976 and 24 count the same labels, so an address
  crosses unchanged. Rescaling put a reel 101 frames late.
- `c0795a4` seeks built from the rate's frame duration as a rational. A 600-tick
  CMTime cannot express a 23.976 frame boundary (25.025 ticks), which left every
  seek about a frame either way.
- `018b62a` a reel's duration counted in labels. Dividing by the real rate and
  taking the frames digit modulo `Int(23.976)` - which is 23 - displayed a
  90-minute reel as 1:30:05:18.
- `81d1d7e` readout and picture park on the same frame when stopped. Pausing now
  settles the picture onto the reported frame, and the periodic observer only
  drives the frame while playing - the player's clock is quantised to the item's
  timescale, and a parked 23.976 frame sits just under its own boundary in a 600
  timescale, so truncation named the frame before.

All four have unit tests. Full suite green: 133 cases.

## The remaining discrepancy is in the delivery, not the app

The reel the user was testing drifts against **its own** burned-in window -
measured outside the app with AVAssetImageGenerator at exact frame times, so it
is a property of the file:

| source frame | its timecode track | its burn-in |
|---|---|---|
| 0 | 01:10:12:03 | 01:10:12:03 |
| 1149 | 01:11:00:00 | 01:11:00:01 |
| 2787 (last) | 01:12:08:06 | 01:12:08:08 |

They agree at the head and separate at one frame per 1001 - the burn-in was
rendered on a 24 fps clock while the media runs 23.976. Projector follows the
timecode track, so it reads up to 2 frames "wrong" against those numbers on a
1:56 reel, and would be worse on a full one.

**Open product question for the user**: should Projector detect this and say so?
It needs OCR of the burn-in (Vision can do it) compared against the timecode
track at two distant frames. That is a new feature, not a bug fix, so it was not
built.

## Housekeeping

- `~/Desktop/ProjectorRefReel_90min.mov` (160 MB) and
  `ProjectorRefReel_23976.mov` (3 MB) are test assets - delete when finished.
- No app instance left running.

---





## Previous Task

**Task**: Three things, all uncommitted and all built + tested green:

1. **Output matching from file names.** DX/SFX/MX in a filename routes the lane, applied at
   placement rather than offered in a dialog — the asking step was removed at the user's call as
   "an unnecessary step". Two choke points (`addAudioToTimeline`, `addVideoToTimeline`) so routing
   no longer depends on which import path ran or whether a sheet appeared. The three import sheets
   are back to their original code (zero diff).
2. **Set Timeline Start to Region** on the region right-click menu.
3. **None** in the lane output menu — a routing-level silence, distinct from the M button.

**Files modified**:
- `Views/SettingsView.swift` — `OutputRole.named(in:)` + word splitting
- `Views/ContentView+Timeline.swift` — `outputNamedByFile`, `applyNamedOutput*`, lane-leak fix
- `Views/ContentView+Setup.swift` — `-test-drop-urls` hook (see below)
- `Managers/TimelineManager.swift` — routing off-by-one, `setTimelineStart(toFrame:)`,
  `disableLaneOutput(id:)`, authority Rule 5
- `Models/Timeline/AudioLane.swift` — `isOutputDisabled` (+ Codable)
- `Models/Timeline/Timeline.swift` — `activeAudioClips` skips silenced lanes
- `Views/Timeline/{AudioClipView,VideoReelClipView,AudioLaneView,VideoTrackView,MultiTrackTimelineView}.swift`
- `ProjectorTests/TimelineManagerTests.swift` — 15 new tests
- `FEATURES.md` — three entries

**Runtime evidence** (real drop of a PREV1 reel, 2026-07-27): `_Dx`/`_Fx` → DX/SFX, `_Mx` → MX,
and the video's own audio lane routed. User then tested the silent-import build end to end and
confirmed all three features work.

**Then removed as dead**: the three import placement sheets and everything that fed them — see
"Import Placement Dialogs" under Removed Features in FEATURES.md for the full list, including what
was deliberately kept (`detectTimecodeFromFilename`, `BatchTimecodeItem`, the video-insert and
FPS-conflict dialogs).

**Flake to watch**: one full-suite run failed once during the removal and did not reproduce in five
subsequent runs (3 full + 2 UI-only). Suspected `ProjectorUITests.testWaveformRendersAndSurvivesZoom`,
which launches the real app. Not diagnosed.

## Test hook in production code

`ContentView+Setup.swift` gained `handleUITestDropIfNeeded()` — `-ui-testing -test-drop-urls
<paths>` drives the real `handleMixedBatchDrop`. Added because the existing `-ui-testing` harness
calls `addAudioClipForTesting` directly and never opens the import dialogs, so they could not be
reached without a mouse. **Caveat: a command-line path grants no security-scoped access**, so BWF
timecode reads fail and placement behaves differently than a real drag. Use it for reaching UI,
not for judging import behaviour.

## Also fixed: empty lanes left behind by every drop

`discardLanesCreatedForCancelledDrop()` was misnamed and unreachable on success — the confirm path
cleared `batchCreatedLaneIds` one line *before* the cleanup that reads it, so it only ever worked
on cancel. A batch pre-creates one lane per audio file and one per video, and several routinely go
unused. Renamed `discardEmptyLanesCreatedForDrop()` and reached from all four teardown paths plus
the no-timecode branch. Only empty lanes are removed.

**Done**: builds clean; full test suite green; name matching verified against 21 cases
(matches, near-misses, ambiguous).
**Not done**: app has not been run yet. No commit.

## Fixed alongside it: the routing off-by-one

`TimelineManager.setLaneOutputMapping` set `outputChannelOffset = max(0, mapping.channelStart - 1)`,
but `channelStart` is already a 0-based buffer offset (`addOrReplaceOutput` stores
`firstChannelNumber - 1`, `SettingsView.outputChannelLabel` prints `channelStart + 1`) and
`PlaybackEngine`'s `outputOffset` is 0-based too ("2 for outputs 3-4"). Every output that did not
start on channel 1 played one channel low - MX on "Out 3-4" reached hardware 2-3. Out 1-2 looked
right only because `max(0, -1)` clamps to 0. `reconcileOutputMappings` repeated the same `- 1`,
so it was internally consistent and invisible in review.

Both now pass `channelStart` through unchanged. **The convention: `channelStart`,
`outputChannelOffset` and `outputOffset` are all 0-based; only the UI adds 1.**

Pinned by four tests in `TimelineManagerTests` ("Audio Routing Tests"), two of which were
confirmed to fail against the old arithmetic before the fix was restored.

---

## Where we left off

A long UI/UX session. The main window was reorganised into a two-row layout, MTC sync was
debugged end to end, the video's baked-in audio became part of a combined "Video File" track,
Audio Settings was rebuilt around output roles and profiles, and the layout was inverted so the
window's size drives the sections rather than the other way round. Everything below builds and
the test suite is green. Nothing is half-applied.

---

## The two authorities (read before touching layout or routing)

Both are written as numbered rules in code comments. They exist because the same class of bug
kept returning one instance at a time. **Extend the rules rather than adding a special case.**

### 1. Section sizing - `LayoutConstants.swift`, `SectionLayout`

**The window's size is an input, not an output.** `SectionLayout.resolve(content:topRowShare:)`
turns the window's content area into every section's size. Six rules, summarised: `everything`
is the root and every section is carved out of it; the top row and timeline **share** the
flexible height by a fraction (`topRowShare`), so a window resize preserves the balance instead
of overwriting it; the video column's width is derived from the picture's height so it is
exactly 16:9 at any size; a narrow window caps the top row at the height its width supports and
gives the surplus to the timeline; Media absorbs the leftover width; and the window's minimum is
the sum of the section minimums, which is what guarantees the content always fits.

Verified by measurement, not inspection:

```
win   1440x783   | top  306.0  timeline  409.0  | video  480.0x270.0  16:9  | media  924.0  rows 2
win   1440x900   | top  356.1  timeline  475.9  | video  569.0x320.1  16:9  | media  835.0  rows 3
win  2560x1400   | top  570.1  timeline  761.9  | video  949.4x534.1  16:9  | media 1574.6  rows 5
win  1100x1200   | top  229.5  timeline  902.5  | video  344.0x193.5  16:9  | media  720.0  rows 2   <- rule 4
win   1076x571   | top  216.0  timeline  287.0  | video  320.0x180.0  16:9  | media  720.0  rows 2   <- every minimum
```

The last two rows are the ones worth keeping: rule 4 fires on a tall narrow window, and the
minimum window puts every section on its floor simultaneously with the heights still summing
exactly to the content.

Traps already paid for:

- **`.frame(minWidth:minHeight:)` takes the *view* minimum, not the window's.** SwiftUI
  constrains the content below the titlebar, so passing `minimumWindowSize` put the floor a
  titlebar too high - measured, the window stopped shrinking at 603pt where the sections were
  still fine at 571. `minimumViewSize` (no titlebar) is for SwiftUI; `minimumWindowSize` is for
  clamping an NSWindow frame.
- **A fixed `.frame` on a child beats the parent's frame.** `InlineVideoArea` named
  480x270 internally, so the column grew with the window while the picture inside it did not.
  Children of a resolved section fill (`maxWidth/maxHeight: .infinity`); they never name a size.
- **The GeometryReader has to be outside anything that scrolls.** Inside a ScrollView it
  reports the content's height, which is the height it is being asked to decide.

#### What this replaced, and why it cannot come back

The previous authority did the opposite: panels had fixed heights, measured themselves, and the
window was resized to fit. It needed a 2pt deadband, two deferred normalization passes, and a
"has the scroller been earned" test that had to read the window rather than the content to avoid
being circular. All of that was the cost of a feedback loop. It also silently undid every manual
window resize the moment a lane was added, which is what made proportional sizing impossible.

Deleted with it: the panel stack's `ScrollView` and `PanelScrollCapture`, `panelsCanScroll` /
`panelsContentHeight` / `normalizePanelScroll()`, `idealMainWindowContentHeight`,
`syncWindowToContent()`, `videoAreaHeight`, `normalViewHeight`, `TimelineViewModel.expandedHeight`
and its min/max/clamp, `TimelineSectionLayout.reservedVerticalChrome`, `MediaPanelLayout`,
`PlaybackResizeHandle` and the `playbackHeight` cluster. **If a section starts measuring itself
and reporting back, the loop is being rebuilt.**

#### The splitter

The one draggable boundary is `ContentView.sectionSplitter`, in the 12pt gap between the two
rows. It writes a **share**, never a height. It used to be a handle along the timeline's bottom
edge, which worked only because the drag resized the window; with the window fixed, whatever the
timeline gains the top row gives up, so the edge that moves is the timeline's *top* edge - a
bottom handle would have stayed still while the panel grew out from under the cursor.

Persisted as `ProjectUIState.topRowShare`. The legacy `timelineExpandedHeight` is read once, on
open, to reconstruct a share for projects saved before the split existed; nothing writes it.

### 2. Audio routing — `TimelineManager.swift`, `reconcileOutputMappings(with:)`

Names are never copied (the menu reads the current name from Settings, so renaming a mapping
retitles every lane using it); a lane keeps its mapping while it exists; if a mapping
disappears, re-bind by **channel range** — this is what survives an interface change;
otherwise clear it rather than silently routing somewhere the user did not choose.

---

## Layout model (every size is resolved, not declared)

```
+---------------------+----------------------------+
|  video 16:9         |  Media (rows fill height)  |   topRow    - share of the window
|  -----------------  |                            |
|  [Settings] [FPS][stop][full][popout]  36pt      |
+========== section splitter (12pt gap) ===========+
|  Timeline - full width, scrolls internally       |   timeline  - the rest
+--------------------------------------------------+
```

At the default 1440x783 window this measures exactly the old fixed layout: top row 306, timeline
409, video 480x270. Those figures now live in `SectionLayout` as the *reference* the proportions
are struck from, not as the sizes anything is given.

- Both top-row columns are framed by `SectionLayout`, so their bottoms align because they are
  told the same number. Deriving one from the other's internals broke the moment the
  optimization banner appeared.
- The Media grid's **row count** follows the panel's height (`mediaGridRows(forHeight:)`), two
  rows minimum. Cells stay a fixed size, so a taller panel earns more rows rather than bigger
  thumbnails - without this the top row growing with the window was just dead space.
- The timeline scrolls internally past what its height shows. `resizeToFitLanes` was **removed**
  earlier for making the panel *shorter* with fewer than three lanes; nothing sizes the panel
  from its contents now.
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

## Audio routing settings + the Settings design system (2026-07-26, later)

Audio Settings was rebuilt: pick a device, then fill named output roles, and save
the result as a recallable profile.

- `MappedAudioOutput` gained `roleId`. Roles are **stored, not inferred from the
  name** - matching on the name looked fine until a mapping made before the roles
  existed ("DX" against a role called "DX/SFX") failed to match, so the chooser
  stayed on screen *and* the output was listed again as an extra.
  `OutputRole.matches(_:)` still falls back to legacy names so old mappings are
  adopted rather than orphaned.
- `AudioOutputProfile` is portable: names and channel numbers only, applying to
  whatever device is selected. It records its origin device solely to warn
  ("created for X, we recommend you check your outputs") and never blocks -
  moving between a studio interface and a laptop is the point. Applying one mints
  fresh output identities so the routing authority re-binds lanes by channel
  range rather than matching stale ids.
- Channel numbers are 1-based everywhere the user sees them. `channelStart` is a
  0-based buffer offset; printing it raw labelled the first pair "Out 0-1" while
  the chooser that set it offered "1-2".
- The old channel-mapping grid, `AudioOutputMappingView` and `OutputChannelRow`
  are gone, superseded by the guided flow.

### SETTINGS DESIGN SYSTEM - read before touching any Settings view

`SettingsDesign` in SettingsView.swift holds every size and text style; build rows
from its components and never pick a font, width or button style at the call site.
Seven rules are written above it. This exists because the alternative was tried
and failed inside one session: two dropdown widths, three clear buttons, a
prominent button beside a bordered one, and a window where Audio used
label-beside-control while Display used label-above-control.

Hard-won specifics:

- **`SettingsMenu`, not `Picker(.menu)`.** SwiftUI's menu picker renders an
  NSPopUpButton whose bezel is sized by its widest item; it ignores a proposed
  width, and widening the items does not reach the closed-state button either.
  Two rounds were lost to this. The design system draws the control itself so the
  column has one width and one chrome.
- **`.frame(maxWidth: .infinity)` centres by default.** Every "control is
  centred for no reason" report traced to this - it centred the control inside
  its own frame before any outer alignment applied. `settingsControlWidth()`
  carries `alignment: .leading` on *both* frames.
- **Yellow pending / green set.** A chooser and a chosen value are the same
  geometry in two colours, so a column reads as "still to do" and "done" without
  reading the labels.
- Sizing complaints are not always sizing: the video column and Media panel
  measured identical rectangles (global maxY 633 each) while looking misaligned,
  because a hard-clipped fill and a 1pt stroke do not resolve to the same pixels
  at a rounded corner. Measure before adjusting constants.

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
- The section splitter has no visible affordance until it is being dragged - only the cursor
  changes on hover. Worth a hairline on hover if it turns out to be hard to find.
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
