# Session State

> **Last Updated**: 2026-08-10
> **Status**: ACTIVE — 25 fps import fixed, built and launched, awaiting user verification
> **Branch**: main

---

## In progress — a 25 fps reel landed 2:23:15 early

**Report**: a 25 fps file imported with its timecode "way off throughout".

**Measured**: the file carries a `tmcd` track reading 00:59:52:00, 25 fps,
2768.72s (69218 frames). Nothing wrong with the file, and rate detection was
correct - the reel was placed against the wrong clock.

**Cause, two halves of the same mistake — a frame count is not a time.**

1. Adopting the reel's rate carried the timeline's bounds across as *frame
   counts* (`ContentView+Timeline.swift`, `MultiTrackTimelineView.swift`). The
   default start, 86160 frames = 00:59:50:00 at 24 fps, becomes 00:57:26:10 when
   the same 86160 frames are counted at 25. Every timecode the timeline reported
   was then 2:23:15 early, for the whole reel - which is why it reads as a bad
   file rather than a bad setting.
2. Placement was resolved *before* the timeline adopted the rate, so the reel's
   00:59:52:00 was converted onto the outgoing 24 fps grid (89800 -> 86208) and
   landed 48 frames past a start that had itself moved.

**Fix**:
- `TimelineConfig.setFrameRate(_:)` (new) re-expresses the bounds by their
  components, so 00:59:50:00 stays 00:59:50:00 at any rate. All four sites that
  changed the rate now go through it, including the previously uncalled
  `TimelineManager.setFrameRate`.
- Import holds what the file said (`PendingVideoPlacement`) and resolves it to a
  frame only once the rate is settled - including across the FPS-conflict dialog,
  which now carries the unresolved placement rather than a stale frame number.

**Tests**: `ProjectorTests/TimelineConfigFrameRateTests.swift` (new, 6 cases,
covers the exact 25 fps arithmetic). Full suite green.

**Verified at runtime by the user** against the 25 fps delivery. Committed
(505df8d) and pushed. Ship held at the user's request to check the other rates
first - see below.

## In progress — verifying 23.976 / 24 / 25

Asked before shipping. Walked all three through detection, adoption, placement,
grid conversion, label rendering, MTC receive and MMC locate.

**24 and 25: clean.** Every conversion checked out, and the paths are now
covered by `ProjectorTests/SupportedFrameRatesTests.swift`.

**23.976: found a second bug, in the sync readout.** MTC carries a *family*, not
a rate - 23.976 and 24 both transmit as MTC 24, 29.97 and 30 both as MTC 30, and
nothing on the wire separates them. `MIDISyncActor` named the family's integer
member as the incoming rate (`directEquivalentFrameRate`), so a correctly
configured 23.976 session receiving its own DAW went **red** and read
"24 ≠ 23.976", with a tooltip instructing the user to change the project to 24 -
which would have been the actual error, on the commonest rate for picture.

**Fix**: `MTCFrameRate.reportedRate(forProject:)` reports the project's rate
whenever it transmits on the arriving base, which is exactly as much as MTC
knows. A genuine mismatch (25 against a 24 family) still resolves to a different
rate and still shows red.

**Checked and sound, no change needed**: MTC full-frame and MMC locate build
their timecode at the wire rate, but 23.976 and 24 share a counting grid so the
frame count is identical either way. The app receives MTC only - it has no
generator - so there is no transmit path to get wrong.

**Not verified at runtime**: the 23.976 readout needs a DAW running at 23.976.
The fix is unit-tested; the red-dot behaviour is the user's to confirm.

## Shipped 2026.08.10.2 — clips drew wider than they are, at low zoom

**Report**: zoomed out, the playhead appeared to be sitting over clip activity
that was not actually there; zoom in and the content jumped back.

**Cause**: `TimelineLayout.minimumClipWidth` floored every clip at 44pt
(`AudioClipView.swift:167`, `VideoReelClipView.swift:243`). Below that zoom a
clip was drawn longer than it is, and the waveform stretched to fill the space.
The old doc comment recorded the overstatement as an accepted cost.

**It is not an edge case.** At fit zoom on the default timeline a nine-minute
reel is about 30pt, so it was drawn at 44 - claiming to run to 01:12:49 when it
ended at 01:08:44. The user's screenshot shows the clips at exactly 44pt (88px
at 2x) with the playhead parked at 01:10:28, inside four minutes of clip that
does not exist.

**Fix**: floor lowered to 2pt - a hairline, below which a clip would vanish
entirely. Width is now duration x zoom at every scale. Rejected: widening the
*hit* area to keep short clips grabbable, because clips sit shoulder to
shoulder and an oversized target selects the neighbour. Zooming in is the way
to grab a narrow clip.

**Left alone, deliberately**: the drag-preview ghosts
(`AudioLaneView.swift:373,397`, `VideoTrackView.swift:313`) still floor at 12pt.
They are transient drop feedback rather than a claim about existing content.

Full suite green. **Not verified visually** - screen recording is not permitted
to the agent, so how a hairline clip reads on screen is the user's call.

## Shipped 2026.08.10.1 — Finder double-click opened a second window

**Report**: with a project already open, double-clicking another `.projector` in
the Finder left two full copies of the interface on screen.

**Measured, not assumed.** One process the whole time (`pid 6223`,
`/Applications/Projector.app`, which is also the Launch Services default handler
for the type, so a double-click can never start a second process). Enumerating
`CGWindowListCopyWindowInfo` before and after the open showed a *second* main
window appear under the same pid: 1440x923 and 1076x635 side by side. Two
windows, each a `ContentView` with its own state — reads as two instances.

**Cause**: `WindowGroup` declared `.handlesExternalEvents(matching:)` at the
scene, and nothing inside it claimed those events. That combination is a licence
to open a *new* window for each incoming open, which is what SwiftUI did.

**Fix** (`Projector/ProjectorApp.swift`): the window now claims them, with
`.handlesExternalEvents(preferring: ["projector", "file"], allowing: ["*"])` on
`ContentView`. The open routes to the window already on screen and
`AppDelegate.application(_:open:)` loads it there, as File > Open does.

**Verified at runtime** against a Debug build, window counts from
`CGWindowListCopyWindowInfo` and load counts from the unified log
(`subsystem == "com.keegandewitt.projector"`):

| Scenario | Windows | Loads |
|---|---|---|
| Cold launch by opening a project | 1 main | 1 |
| Open a different project while running | 1 main | 1 |
| Open the same project again | 1 main | 1 |

Re-verified after shipping, against the installed `2026.08.10.1` binary rather
than a Debug build: one main window across a cold open and a second open, and
the player window resizing 1280x720 -> 1880x1058 as the second project's video
took over — the timeline swapped in the window that was already there.

**The first attempt at verification was wasted** and the lesson is worth
keeping: a Finder double-click always routes to the Launch Services default
handler, which is `/Applications/Projector.app`. A fix sitting in DerivedData
cannot be tested that way, and testing it that way reports the *old* build's
behaviour as if the fix had failed.

**Left for the user**: the click-through in the checklist below.

**Aside, unrelated to the fix**: `lsregister` lists ~40 registered copies of
`Projector.app` — DerivedData, `release-build/`, stale `/Volumes/dmg.*` mounts.
Harmless today (the `/Applications` copy wins) but worth a clean-up.

## Shipped 2026.08.10 — identity, Settings, demo defaults, permanent links

Six pieces, written 2026-08-08 evening and left uncommitted for two days; the
session file above them was never updated, which is why the tree and the record
disagreed until now. **Recorded from the diff, not from memory.** Full suite
green before shipping.

### 1. The company is So Pitted LLC

`Musique LA` → `So Pitted LLC` in the copyright, which lives in **two** places
that must agree: `Info.plist`'s `NSHumanReadableCopyright` and
`INFOPLIST_KEY_NSHumanReadableCopyright` in all four build configurations. The
build setting wins where both apply, so changing only the plist looks correct in
the repo and ships the old name.

### 2. About panel, retargeted rather than rebuilt

The system About item now points at `AppDelegate.showAboutPanel`, which calls
`orderFrontStandardAboutPanel(options: [.credits:])`. macOS already reads name,
version and copyright out of the bundle — only the credit line was missing, so a
hand-built window would have had to re-earn all of it. The credit is an
`NSAttributedString` because the link has to be clickable: a `.link` attribute
makes the panel's own text view open the browser, with no action to wire up.

### 3. The Updates section is gone from Settings

It offered an installed version, an automatic-check toggle and a Check Now
button for a mechanism that schedules and runs itself — and in a Debug build,
which cannot update at all, three rows explaining there was nothing to do.
Updating is now reached only from the application menu.

`EnvironmentValues.updateService` went with it, and **its hard-won comment was
deliberately preserved** on `AppDelegate.updateService`: `NSApp.delegate` is
`SwiftUI.AppDelegate`, never ours, so `NSApp.delegate as? AppDelegate` is always
nil. That is what made the old section permanently invisible while the menu item
worked. If a section ever returns, publish the delegate's property into the
environment from the scene body — do not hunt for the delegate.

### 4. Settings sizes itself to its content

`SettingsContentHeightKey` measures the scrolling content at a **fixed width**
and the window takes that plus a constant `SettingsLayout.chromeHeight` (132pt),
capped at `maxScreenFraction` (0.9) of the screen's `visibleFrame` with
`maxHeight` (900pt) as the fallback. The chrome is a constant on purpose: the
outer stack's height *is* the window height, so measuring it to decide the
window height is exactly the sizing loop this avoids. Nothing feeds back.

### 5. The QT demo remembers its setup, across projects

`QuickTimeDemoDefaults` in `AppSettings`, saved from `rebuild()` and
`applyLevels()` rather than from the export — the balance is found by ear long
before anyone commits to writing a file, so a setup arrived at and abandoned is
still offered next time. Lanes are **merged**, so a music-only project does not
forget a dialogue setting.

Two decisions worth keeping:

- **Lanes are keyed by name, not by id.** A lane's `id` is a fresh `UUID` per
  project, so keying on it would store something that could never match. Names
  recur because stems are named by convention. Cost: renaming a lane loses its
  setting, and two lanes sharing a name share one.
- **`init(from:)` is written by hand**, every field `decodeIfPresent`. The
  synthesised one uses `decode` even where properties have defaults, so a payload
  missing any key throws — and *every* stored setup predates whatever field is
  added next. The first release to add one would have silently discarded every
  saved setup and looked exactly like the feature not working, one version late.

5 unit tests, including the partial-payload case.

### 6. Permanent download links

`build-release.sh` now uploads the DMG **twice**: the versioned name the appcast
points at, and a constant `${DMG_NAME}.dmg`. GitHub serves
`/releases/latest/download/<name>` by **filename**, so the name must be identical
in every release — which the versioned one never is. The versioned asset stays
because Sparkle needs each entry to name its own build; a moving enclosure would
let an installed copy download something other than what it was offered.

Drive uses `rclone copyto`, which **updates the existing file** rather than
replacing it, so the file id — and therefore the share link — survives. Measured
before relying on it: two uploads of different content to the same destination
returned the same id. A plain `rclone copy` cannot do this.

### Not eyeballed

All of it, plus everything still listed further down. Specifically new here:
About (menu item, credit, link opens `sopitted.llc`), Settings at its new height
on a small display, and the demo sheet restoring a setup on second open.

---

## RESOLVED: the coreaudiod leak was the HAL plug-ins, not Projector

Measured after the restart, on a fresh boot, with the user having removed four
HAL plug-ins beforehand (**SoundID Reference**, **Jump** ×2, **BlackHole 2ch**),
leaving five: ARK, Audiomovers InjectIO, BlackHole 16ch, Parrot, Pro Tools Audio
Bridge.

A three-phase A/B, with a near-silent 15-minute tone as a constant driven load so
phases B and C differ only by Projector:

| Phase | Condition | RSS | Rate | Overloads |
|---|---|---|---|---|
| A | idle, no audio client | 98.2 → 99.5 MB | settling only | 0 |
| B | tone, **no** Projector | 113.5 → 114.6 MB (4.5 min) | 0.24 MB/min | 0 |
| C | tone **+ Projector playing 3 lanes** | 115.2 → 115.6 MB (6.5 min) | **0.06 MB/min** | 0 |

Against the prior session's **22.4 MB/min with Projector and 16.8 without** — a
~70× reduction. Projector's entire cost is a **~1 MB attach, then flat**; it grew
*less* than the idle case, which is noise rather than a real difference.

**Zero overload messages throughout**, from both the instrument and system-wide
(`log show --predicate 'process == "coreaudiod"' | grep -ci overload`). Since
queued overload reports were 92% of the memory in the 2.8 GB sample, no overloads
means no mechanism.

`coreaudiod` also now **gives memory back** when clients detach (113.0 → 109.4 MB
when Spotify/Safari quit), where before it climbed monotonically to 26 GB.

### The earlier "Projector is ~30% of the growth" was wrong

That attribution was an artifact of measuring while SoundID was driving the
overload storm: Projector was being charged for load it did not create. With the
plug-ins gone it contributes nothing measurable. The instrument stays anyway —
it is what turned a suspicion into a number, and it is the only way to judge a
future regression.

**The user does not intend to reinstall SoundID**, so no further bisection: we do
not need to name which of the four it was.

### Correction: `log show --info` does not reliably persist these

The instruction below to use `log show --info --predicate 'subsystem == …'`
**does not work** — info-level messages are memory-only and the query comes back
empty, which makes a working instrument look dead. It cost some time here. Use a
live stream instead, from a script to dodge shell quoting:

```
log stream --info --predicate 'subsystem == "com.keegandewitt.projector"' --style compact
```

That caught both `Overload monitor watching device 167` and `Audio engine
released on teardown`. Note the device id is **167** this boot, not 194 — it
changes across reboots, so confirm it against the default output every time.

### Reusable harness

`scratchpad/sample-coreaudiod.sh` samples RSS/CPU/Projector-running every 30s to
a TSV. Fixtures regenerated at `~/Movies/ProjectorDropTest` (5-min 24fps reel
with a real timecode track, two sine stems) — **must** live under `~/Movies` for
the sandbox to read them. Delete when finished.

---

## REGRESSION: drag-to-reorder lanes was dead in 2026.08.08.1 (fixed, uncommitted)

Reported by the user during verification. **Self-inflicted, in `2f29e8b`** — the
same commit that fixed right-click-to-delete broke reordering, and both shipped.

Fixing the right-click meant hanging a `.contextMenu` on the invisible drag
handle. On macOS that **wraps** the view, so it received mouse events before the
gesture did and swallowed the whole stream. The tell was that the closed-hand
cursor never appeared: the `LongPressGesture` never even reached `.first(true)`,
so it was not the drag half or the commit — the gesture was entirely dead.

`LaneReorder`'s arithmetic was **not** at fault (traced: 0.68 rows ≈ 56pt to
trigger the first swap, holds correctly either side). The hysteresis work was
fine; only the modifier order was wrong.

**Fix**: apply `.highPriorityGesture` *after* `.contextMenu`, so the gesture sits
outside it and sees events first. The two coexist only because a long press and a
drag are primary-button gestures, so a right-click still falls through. Marked
ORDER IS LOAD-BEARING at the call site.

**Both behaviours must be tested together** — a change that restores one can kill
the other, which is exactly how this shipped. **User verified both.**

## And the shaking was never the hysteresis (fixed, uncommitted)

With reordering working again the user still reported shaking when hesitating near
a swap point — the symptom the previous session had already "fixed" twice with
hysteresis. It was neither the arithmetic nor the animation.

**Measured, not reasoned.** A temporary trace logged `dy / rows / held / target`
per gesture update. Across **377 samples the target never flipped once** — the
`LaneReorder` rule was innocent, as was `AppAnimations.quick` (a plain easeOut,
no spring overshoot) and the insertion indicator (defined at
`MultiTrackTimelineView.swift:3155`, never used — dead code).

What shook was `drag.translation.height` itself, alternating between two values
every frame while the mouse was **held still**, with the gap *growing*: 3.6pt,
4.1, 5.1, 5.9 … 8.9pt.

**Cause: a positive feedback loop through the coordinate space.** The row is
displaced by `.offset(y: draggingLaneOffset)`, and `draggingLaneOffset` *is* the
gesture's own `translation.height`. `DragGesture` defaults to `.local`, so the
translation was measured against a frame the offset was moving. Offset fed the
gesture, gesture fed the offset, and hesitating gave the oscillator time to wind
up — which is exactly why holding still made it worse.

**Fix**: `DragGesture(minimumDistance: 0, coordinateSpace: .global)`. The global
space does not move when the row is offset, so the loop is broken.

Verified with the trace still running: direction reversals fell from *every
sample* to **3 of 142 (2.1%)** — the hand changing direction — `dy` climbed
monotonically, and the target flipped once at `rows=0.684`, right on the 0.68
threshold, then held. Instrumentation since removed.

**The lesson worth keeping**: two previous passes tuned the hysteresis constant
because the symptom looked like target flip-flop. It never was. Any future "feels
jumpy" report here should trace the raw gesture input *before* touching the rule —
the rule was correct all along and was being fed a corrupted signal.

---

## Shipped 2026.08.08.2, and the dead drop subsystem is gone

`2026.08.08.2` is on the feed, on the GitHub release (correctly marked Latest),
on Drive and in `/Applications`. It carries the lane-reorder fix, the drag-shake
fix, the mixed-drop fix and the Debug-only overload monitor.

**Version trap, for next time**: `build-release.sh` defaults to today's date and
does *not* auto-increment past a version already used today. `2026.08.08` and
`2026.08.08.1` had already shipped, so the default collided and replaced the
`v2026.08.08` asset before being re-released correctly as `2026.08.08.2`. **Pass
the version explicitly whenever anything has already shipped that day.** Residue:
the `v2026.08.08` release and its appcast entry now point at a newer build than
their label claims. Harmless — outranked by `.1530` — and deliberately left.

**Dead code removed** (~290 lines, 3 files): the entire orphaned NSItemProvider
drop subsystem, plus the write-only `emptyAudioDropLocation` and the then-unused
`mediaLibrary` dependency of `MultiTrackTimelineView`/`TimelineAccordionView`.
The live `DragCaptureView`/`NSDraggingInfo` path is untouched and is now the only
one. Swift does not warn on unused private methods, so every boundary was
asserted before cutting and the compiler used as the check.

**The `os_unfair_lock` contradiction is reconciled** in `PlaybackEngine.swift`:
the overload monitor takes no lock while `MeterLevelStore` takes one per buffer,
and the comment now explains why that difference is deliberate rather than
reading as an inconsistency.

---

## FIXED: a mixed drop on the audio area silently discarded the video

### First attempt went into dead code — caught by clare, not by the build

The fix was first written into `handleEmptyAudioDrop`, which **nothing calls**.
Its name appears exactly once in the repo: its own definition. `xcodebuild`
raises no warning for an unused private method, so a clean build proved nothing,
and the user's runtime check passed because *once a lane exists*
`AudioLaneView.routeDroppedMedia` handles the drop and already routes mixed
batches correctly. Only the **first** drop into an empty project was ever broken,
so retesting on a timeline with content could never reproduce it.

**The live path** is `DragCaptureView.onPerform`
(`MultiTrackTimelineView.swift:2170`, `2247`) → `handleNewLanePerformDrop`
(`:2275`) → `audioURLs(from:)` → `audioCandidate(from:)` (`:2340`), which filters
the pasteboard to `.audio` — throwing the picture away before the handler runs.

**Real fix**: a new `videoURLs(from:)` beside the existing `audioURLs(from:)`, and
`handleNewLanePerformDrop` routes to `onDropMixedMedia` when a batch carries both.
Audio-only and video-only behaviour deliberately unchanged, matching
`AudioLaneView`.

**Lesson**: a passing build and a passing runtime check together still did not
show that the edited function was unreachable. When a fix "works", confirm the
edited code is on the path that ran — `grep -c` for the function name is enough.

### Still open: the orphaned drop subsystem around it

`handleEmptyAudioDrop`, `beginEmptyAudioDrop`, `loadURL(from: NSItemProvider)`,
`mediaItem(from:)` and `quickMediaType(from:)` are called only by each other —
~200 lines reachable from nothing. Awaiting a decision to delete or reconnect.
Leaving it is what caused the wrong fix above.

### The original report

Found during verification. Reproduced from the log:

```
handleAudioDropOnTimeline: ENTRY - laneIndex=0, urls=["Stem_Dx.wav", "Stem_Mx.wav"]
```

A reel and two stems were dropped; the `.mov` is already gone at ENTRY. The audio
lane's drop handler in `MultiTrackTimelineView.swift` filters to audio and returns
without a word:

```swift
let audioURLs = urls.filter { ProjectMediaLibrary.mediaType(for: $0) == .audio }
guard !audioURLs.isEmpty else { return }
```

No alert, no partial-import notice — the same silent-loss class as the 08.07
frame-rate batch bug, which was fixed by naming the skipped files in one **Not
Imported** alert. The same answer probably applies here.

Worth noting: `onDropMixedMedia` is already wired into that view
(`MultiTrackTimelineView.swift:1192`) and this path does not call it, so the fix
may be routing rather than a new alert.

**Not a bug, checked**: two stems landing on *one* lane is by design when the drop
targets a specific lane ("Each file goes to its own timecode, or after the last
one", `ContentView+Timeline.swift:98`). They were placed sequentially only because
the first test fixtures carried no BWF timecode. Fixtures now carry
`time_reference=172800000` (01:00:00:00 @ 48 kHz), matching the reel's tmcd.

---

## Remaining UI verification (unchanged, still not eyeballed)

**Shipped**: `2026.08.08.1`, in `/Applications`, on the feed.

**Uncommitted**: `PlaybackEngine.swift` (the overload monitor + the `[weak self]`
removal), `MultiTrackTimelineView.swift` (the reorder-order fix) and this file.

### Still not eyeballed

All of it is in the shipped build already:

- **Create QT Demo** - pick a bounce, check the detected timecode, toggle a lane,
  ride a fader (the preview must keep playing, not restart), set handles, export.
  The biggest untested surface; nobody has ever clicked the button.
- **Undo** - drop files, Cmd-Z. Then Cmd-Shift-Z. If Cmd-Z does nothing, the first
  thing to check is whether `@Environment(\.undoManager)` is non-nil at all; if it
  is nil, own an `UndoManager` explicitly rather than reading the environment.
- **Lane right-click** *and* **lane reorder** - always together, see the regression
  above. Reorder: drag slowly and hold near the swap point; it should commit once
  and stay, not shake.
- **Header** - Export Cue List should sit beside Settings and Report a Bug.
- **Head of timeline** - after an import, frame 0 should be the first region.
- **Update install** - the next real update either relaunches cleanly or reproduces
  the original "Install and Relaunch does nothing". Not testable on a Debug build,
  where the update service is deliberately inert.

### Standing constraints

- Run the app from a terminal to see `debugPrint`. `diagnosticLog` goes to `os_log`
  and needs a **live `log stream`** — `log show` does not persist info-level
  messages and comes back empty, which reads as a broken instrument.
- A locked screen creates no window, so `-test-drop-urls` probes launch and do
  nothing. Keep the screen awake for any runtime check.
- Do not kill the app with `pkill` when testing teardown - `SIGKILL` runs no
  cleanup. Use Quit (`osascript -e 'tell application "Projector" to quit'`), which
  is confirmed to log `Audio engine released on teardown`.
- The Debug build's app code lives in `Projector.debug.dylib`, not in the 60 KB
  `Projector` stub — `strings` on the stub finds nothing and looks like a failed
  build. Check the dylib.

---

## CoreAudio overload instrumentation (2026-08-08, uncommitted)

Acting on a handoff from a separate investigation session. Its headline
correction, which supersedes anything below implying otherwise: **Projector is
about 30% of the growth, not the cause.** `coreaudiod` grew to ~26 GB and hung the
Mac; 92% of its memory in a 2.8 GB sample was *queued overload reports*, at ~82/sec
against a device running 93.75 IO cycles/sec. The dominant source is still
unidentified; `SoundID Reference.driver` is the leading external suspect among nine
installed HAL plug-ins.

### The instrument (the point of this work)

`ProcessorOverloadMonitor` in `PlaybackEngine.swift`, `#if DEBUG`. Counts
`kAudioDeviceProcessorOverload` on the active output device and logs a rate every
five seconds, only when non-zero.

**The header dictated the design.** `kAudioDeviceProcessorOverload` is one of
exactly two properties CoreAudio dispatches *synchronously from the IO context*:

> All listener blocks will be dispatched asynchronously save for those dispatched
> from the IO context (of which `kAudioDevicePropertyDeviceIsRunning` and
> `kAudioDeviceProcessorOverload` are the only examples) which will be dispatched
> synchronously.

So **the listener runs on the render thread**. At the observed rate that is ~82
render-thread callbacks a second: instrumenting this with a lock, a `Task`, a log
line or any `self` access would have added 82 hazards/sec to the thread being
investigated. The block increments one `Int64` through an
`UnsafeMutablePointer` and returns. Non-atomic on purpose - one writer, one
reader, a rate is wanted, and a lost increment is cheaper than a lock here.

The counter is **never freed**. Removal is documented to stop future dispatches,
not to wait for one already running, so freeing in `deinit` risks a
use-after-free on the render thread. Eight bytes for the process lifetime in Debug
only is the better trade. (Raised by clare as the one theoretical concern in her
review; closed structurally rather than by asking Apple.)

Verified: attaches to device 194 = **MacBook Pro Speakers**, which is both the
default output and the device the handoff names. Reported 0 overloads in 35s - and
that zero means nothing yet, because `coreaudiod` had just been restarted and sat
at 0.0% CPU / 38 MB (from 124% / 2.66 GB). The instrument is proven to attach and
report; it has not yet seen a real overload.

### Render-thread sweep

The whole app has **one** render-thread closure: the meter tap. Plus the new
listener. The other two property listeners watch non-IO-context properties
(`kAudioDevicePropertyNominalSampleRate`, `kAudioHardwarePropertyDevices`) and are
dispatched asynchronously onto our own queues. No `AVAudioSourceNode`, no
`AURenderCallback`, no `AudioUnitAddRenderNotify`; the single `scheduleSegment` has
no completion handler and is a control-plane call.

### `[weak self]` removed from the tap

A weak load takes the Swift runtime's side-table lock - not real-time safe, once
per buffer. The tap now captures the `MeterLevelStore` strongly and calls a static
`measure(_:into:)`, so the closure touches no reference counting. No cycle: the
store holds nothing.

### Teardown: nothing to fix, and why

Xcode's Stop sends `SIGKILL`, so no in-process code can run - that is not
fixable from inside. What survives is only the aggregate device, which is
deliberate: a public aggregate outlives its creator by design and is removed
solely by the ✕ in Settings. Taps, listeners and the IOProc die with the process.
Graceful quit does run cleanup (`Audio engine released on teardown`).

### How to judge a fix

Baseline from a fresh `coreaudiod` (`sudo killall coreaudiod`), then sample
`ps -o rss= -p $(pgrep coreaudiod)` each minute. **A fix is real only if it lowers
the overload rate** - memory is the symptom, the report queue is the mechanism.

## CoreAudio audit (2026-08-08, uncommitted)

Prompted by the machine crashing under CoreAudio overloads, suspected to be us.

### The system's state, which is not us

`coreaudiod` measured at **114-124% CPU and 2.5-2.7 GB RSS, still climbing, with
Projector not running at all**. Nine third-party HAL drivers are installed (ARK,
Audiomovers InjectIO, BlackHole 2ch + 16ch, Jump x2, Parrot, Pro Tools Audio
Bridge, SoundID) across 18 devices. A wedged `coreaudiod` holding that much memory
is the likely crash cause, and `sudo killall coreaudiod` is the relief.

**Note on measurement**: `ps -o %cpu` is a *lifetime average*, not current. The
first reading was taken that way and over-claimed; `top -l 2` gives the
instantaneous figure. Use `top`.

### Fixed: a real-time thread violation, Debug builds only

`installOutputMeterTap()` in `PlaybackEngine` was a diagnostic tap on
`mainMixerNode` bus 0 that, per audio buffer, looped channels x frames
(32 x 4096 = 131,072 samples on the aggregate device), then allocated
(`String(format:)`, array append) and called `debugPrint` - which is `NSLog`, a
lock and file I/O - **inside the render callback**. That is the textbook cause of
the message CoreAudio was logging:
`HALS_OverloadMessage: Overload possibly due to client timeout`.

It was `#if DEBUG`, so it was in every build used for testing and in none that
shipped. Deleted, with a comment where it lived saying why it must not return in
that form.

It also collided with the real meter: **a node allows one tap per bus** and both
targeted `mainMixerNode` bus 0, so they clobbered each other while
`removeMeterTap()` cleared only one of two flags.

### Fixed: the surviving meter tap allocated on the audio thread too

It started a `Task { @MainActor }` per buffer, ~50/sec. Now it writes two floats
into `MeterLevelStore` under an `os_unfair_lock` - no allocation, no hop - and a
30 Hz timer on the main actor drains and decays it. Side benefit: decay is now a
function of elapsed time rather than of how many buffers arrived.

### Fixed: teardown never ran

`PlaybackEngine.cleanup()` - which removes the tap, removes the sample-rate
property listener and stops the engine - had **zero callers**, despite its own doc
saying to call it before deallocation. `applicationWillTerminate` now posts
`.projectorWillTerminate`, and `ContentView` calls `playbackEngine.cleanup()` and
`audioManager.cleanup()`. Verified in the log: `Audio engine released on teardown`.

Adding that observer pushed `ContentView`'s body past the type-checker again, so
both app-wide notifications now go through one `AppLifecycleObservers` modifier.

### Corrected: the device listener was *not* unbalanced

First reported as a leak. `AudioOutputManager` does remove its
`kAudioHardwarePropertyDevices` listener - in `deinit`. The real problem is that
`deinit` on a `@StateObject` is not a reliable moment, since a process exiting need
not deinitialise anything. It now also has an explicit, idempotent `cleanup()` on
the terminate path, with `deinit` kept as the backstop.

### Clean

No aggregate device leak (none present on the system; create/destroy balanced), no
`AudioDeviceCreateIOProcID` anywhere, node `attach`/`detach` balanced,
`audioPlayers` cleared.

## Undo, lane right-click, lane reorder (2026-08-08, uncommitted, NOT eyeballed)

Three housekeeping items. All three had a specific cause worth keeping.

### 1. Cmd-Z did nothing, even where undo *was* registered

`MultiTrackTimelineView` gated `.editUndo` and `.editRedo` on
`guard isTimelineFocused`. A drop lands without giving the timeline focus, so
Cmd-Z after an import did nothing and did it silently - which reads as "no undo"
rather than "click the timeline first". The gate is gone for undo/redo and kept
for Delete and Select All, where which panel has focus decides what the key means.

Undo was already registered for: delete clips, delete lane, delete video file,
move clip, move reel, reorder lane, split hard-panned, remove media item. Now also
**imports** and **add audio lane**.

Imports use a snapshot pair: `beginImportUndo()` at the top of each drop handler
records the timeline, and `frameImportedContent()` - which every import path
already ends with - turns it into one step. A new import route therefore gets undo
by using the same ending. Registered only when the timeline actually changed, so a
drop of duplicates does not consume a press. **The media panel is deliberately not
reversed** - the panel has its own undoable removal, and unpicking files copied
into the project folder is a different job.

### 2. Right-click to delete a lane

An invisible reorder handle - `Color.white.opacity(0.001)`, 40pt tall, full header
width, `highPriorityGesture` - lies over the lane *name*, which is exactly where
you right-click a lane. A transparent Color with no menu swallowed the click and
the lane's own `.contextMenu` underneath never saw it. It broke when that handle
arrived. The handle now carries the same menu, and the wording moved to
`AudioLane.deleteMenuTitle` so both places say the same thing.

### 3b. Cmd-Shift-Z did nothing (second pass)

The Redo menu item had `keyEquivalent: "Z"` **and** `.shift` in the modifier mask.
AppKit then wants Shift applied twice and the shortcut matches nothing, while the
menu item looks perfectly correct. Lowercase `"z"` with `[.command, .shift]` is the
only combination that works.

### 3. Reorder jumpiness

Two passes, because the first fixed the wrong half.

**Pass 1.** `calculateLaneReorderTarget` fired at a fixed 20pt and *then* counted
whole rows on top of it: the first swap needed 20pt, every later one a full 81pt row
- four times less sensitive after the first step. Replaced with
`round(dragOffset / rowHeight)`, and the row height became one named constant shared
with the displacement maths, which had its own `+ 1 // Include divider`.

**Pass 2 - the actual jumpiness**, still present after pass 1 and reported as worst
"when a lane is close to being locked in". Rounding alone flips the target the
instant the drag sits on a midpoint, which is exactly what a hand does while
deciding, and **every flip re-animates the lanes being pushed aside** - the shake
was those lanes, not the lane in hand. Fixed with hysteresis: a chosen target has to
be dragged clear of the boundary (0.18 of a row, ~15pt) before it changes.

The rule now lives in `LaneReorder` in `Models/Timeline/Timeline.swift` - a pure
value type with 8 unit tests, including one that jitters across the boundary and
asserts the target holds. It was extracted precisely because this arithmetic has
been wrong twice and cannot be judged by eye: the failures are a few points wide and
the only symptom a person can report is "it feels jumpy".

Two new unit tests pin snapshot-restore as a faithful inverse (including the start
timecode an import snaps). **Not verified on screen**: needs a click. The undo
probe could not run - screen locked, no window, so `-test-drop-urls` launches and
does nothing. Whether `@Environment(\.undoManager)` is even non-nil in this app is
therefore still unconfirmed; if undo does nothing after this, that is the first
thing to check.

## "Install and Relaunch" did nothing (2026-08-08, uncommitted)

Reported after 2026.08.08 shipped. The user's guess was right, and AppKit says so
itself:

```
Checking whether app should terminate
App termination blocked by modal sheet
```

**AppKit refuses to terminate behind a modal sheet**, before
`applicationShouldTerminate` is even consulted - so with the QT Demo sheet open the
install was ready and the quit request was simply denied, silently. Fixed via
Sparkle's `shouldPostponeRelaunchForUpdate` hook + `UpdateRelaunchHandoff` (see
FEATURES.md). **Not verified end to end**: needs a real pending update on a release
build.

### Two things I got wrong here, recorded so they are not repeated

1. **Sparkle does not refuse a development build.** I asserted it would reject an
   ad-hoc/Debug copy on signature grounds. It installed the release build straight
   over the app inside `DerivedData` - the Debug configuration carries the same
   Developer ID team. Consequence to know: after that happens, `xcodebuild` fails
   with "Embedded binary is not signed with the same certificate as the parent app"
   until `Build/Products/Debug/Projector.app` is deleted.
2. **So the debug gate is `#if DEBUG`, not the code signature.** A signature check
   was the wrong discriminator because the signature does not differ.

Both now in `SparkleUpdateService`; verified at runtime:
`Update service inert: debug build.`

Also worth knowing: `diagnosticLog` goes to `os_log`, not NSLog, so it needs
`log show --info --predicate 'subsystem == "com.keegandewitt.projector"'` - a plain
`log show` filters info-level messages out and looks empty.

## Create QT Demo (2026-08-08, uncommitted, UI NOT eyeballed)

New feature, built after 2026.08.08 shipped. Prints a review QuickTime: timeline
picture + a supplied stereo mix (placed by its own BWF timecode) + chosen lanes at
chosen levels, with head/tail handles. See the FEATURES.md entry for the design
and the decisions; the essentials:

- One `AVMutableComposition` is both the preview and the encode.
- Level changes rebuild only the `AVAudioMix` so the preview keeps playing; lane
  inclusion and handles rebuild the composition.
- `AVAssetExportPreset1920x1080` - H.264 `.mov`, capped at 1080p, **source frame
  rate**. Do not reuse the optimisation preset: it caps at 30fps and would wreck
  a 23.976 sync judgement.

**Verified numerically, headlessly** (see FEATURES.md for the table): 15.000s
output, mix exactly in its timecode window, handles carrying picture+stem only,
stem 6.00 dB under the mix matching the -6 dB lane gain. Span maths has 7 unit
tests. Full suite green.

**Not verified: the sheet.** Nobody has clicked the button, used the file panel,
watched the preview or moved a fader. The screen kept locking, and a locked
session never creates the window - so `-test-drop-urls`-style probes launch and do
nothing. That is why the verification above was moved into a headless probe
against a synthetic timeline in `AppDelegate` (since removed).

Two new files, registered in `project.pbxproj` **by hand** (Managers/ and Views/
are explicit groups): `Managers/QuickTimeDemoBuilder.swift`,
`Views/QuickTimeDemoSheet.swift`. Anchored on the ProVideoFormats/Sparkle entries;
`plutil -lint` passes.

## Head of timeline + header grouping (2026-08-08, uncommitted, NOT eyeballed)

1. **The timeline starts where the content starts.** An import snaps the start to
   the earliest reel or clip (`Timeline.earliestContentFrame` +
   `setTimelineStart(toFrame:)`, the "Set Timeline Start to Region" shift). The
   default start is 00:59:50:00 for pre-roll and placement never moved it, so a
   reel delivered at 00:59:52:00 left two seconds of dead head to scroll through
   at high zoom. Idempotent — placement clamps at frame 0, so a later import
   landing further along does not drag the project back.
   All nine import paths now call `frameImportedContent()`, which snaps *then*
   frames (order matters: the snap changes what frame content sits on).
2. **Export Cue List moved** to sit with Settings and Report a Bug, after the
   zoom controls. It used to lead the header, putting one button far left and two
   far right with every readout between them.

Five new unit tests cover the snap (empty / reel / audio-before-video / no dead
head / idempotent). Suite green. **Not verified on screen** - the machine locked,
and a locked session never creates the window, so `-test-drop-urls` runs launch
and do nothing (a 4-line log ending at `setupMenus` is that, not a crash).

## Zoom now anchors the playhead (2026-08-08, uncommitted)

User verified the two bug fixes below, then asked for zoom to be brought in line
with standards. Researched Pro Tools / Premiere / Resolve; the gap that mattered
was that our zoom anchored to **nothing** — offset held in points while the scale
changed, so zooming in walked the view back towards frame 0.

Scoped by the user to *the anchor only*: no pinch/⌘-scroll, no keyboard shortcuts,
no zoom-to-region, no presets. Anchor is the **playhead** (Pro Tools / Resolve
behaviour, not Premiere's pointer), centring it when it is already off screen.

The trap, measured: a zoom step is animated, so `zoomLevel` arrives as ~32
interpolated values per click, some out of order. Anchoring per value drifted the
playhead 629pt → 204pt across one zoom-out, because each value read an offset the
previous one had not applied yet. Fix: capture the anchor **once per burst**
(`pendingAnchorX`) and drop superseded scrolls with a token. Verified: six steps
held the playhead at 655.79pt ± 0.2pt; at fit zoom it clamps, which is the only
possible answer since the document equals the viewport.

Also refactored: `afterZoomLayout(expectedDocumentWidth:attempt:_:)` and
`setScrollOriginX(_:in:documentWidth:)` are now shared by framing and anchoring,
and `pixelsPerFrame(atZoom:)` mirrors `pixelsPerFrame(for:)` — **if one changes the
other must too**, the anchor is only correct while they agree.

Full unit suite green.

---

## Two bugs from the 2026.08.07 release, both fixed (uncommitted)

Reported as "the upgrade in settings did not work" and "zoom to region on drop
broke multi file drop ins". Neither cause was what it looked like, and both were
found by measurement rather than by reading.

### 1. Settings had no Updates section — `NSApp.delegate` is not the app delegate

`ContentView` fetched the updater with `(NSApp.delegate as? AppDelegate)?.updateService`.
That cast **always** fails: `@NSApplicationDelegateAdaptor` installs SwiftUI's own
delegate as the application delegate and forwards callbacks to ours. Probed:

```
runtime=SwiftUI.AppDelegate  expected=Projector.AppDelegate  isKind=false  service=nil
```

Both classes are named `AppDelegate`, so `type(of:)` prints "AppDelegate" either
way — which is why this looked right. The section was therefore invisible from
the day it shipped, and the earlier "it's below the fold" diagnosis (and the
comment written for it) was wrong. **Check for Updates** in the app menu was
never affected: it reaches the updater through `self`.

Fixed by publishing the service into the environment from the scene body, where
the adaptor's property is the real instance:
`EnvironmentValues.updateService` in `ProjectorApp.swift`.

Verified at runtime: same probe now reports `service=present enabled=true`, and
the section renders with `Installed 1.4 (4)`, the automatic-check toggle, Check
Now and "Last checked 7 minutes ago". Kept **first and collapsed** — measured,
Audio and Display are expanded by default and together overflow the 650pt panel
(Display's own rows are cut off), so a section below them can only be found by
scrolling a panel that gives no sign there is more.

### 2. "Only one file lands" — the FPS dialog, not the zoom

Reproduced exactly, and it is **not** the zoom feature. A batch of videos whose
frame rates differ imports only the first. `addVideoFilesSequentially` did not
wait for the per-file `fpsConflict` dialog, and that dialog is driven by one slot
of pending state, so on a 24/25/30 fps drop: one reel imported, the dialog read
"This video is 25 fps" while pointing at the 30 fps file (its Change Project FPS
button would have deleted the reel just imported), and the third file vanished
silently.

Fixed by settling the rate for the whole batch first — read every file's rate,
decide the project's, import the ones that match, and name the rest in one
**Not Imported** alert. Single-file imports keep the existing offer. New
`AlertCoordinator.AlertType.batchFrameRateMismatch`.

Verified: the 24 fps reel imports and the alert names `MixB_25.mov` and
`MixC_30.mov`. Same-rate batch unaffected — 3 reels + 2 stems all land.

### 3. Framing measured the wrong width (the real "view is wrong")

`zoomToFitContent` used one width for two jobs. The **curve** must be inverted
with the width `pixelsPerFrame(for:)` was given (the track area's geometry); the
**target** is what is actually visible, which is less — geometry reported 1416pt
while the clip view was 1399pt, and an import that adds lanes brings the vertical
scroller in *after* the fit runs.

Measured before: visible span 176,085 frames against a framed span of 178,355 —
the entire 3% margin gone, last reel ~21pt from the edge with a 17pt scroller
over it. After: visible span 178,433, reel ~37pt clear. New `trackAreaWidth`
state records the curve's width (recorded, never fed back — no sizing loop). The
scroll offset is now derived after layout from the settled document and clip view
rather than converted with the pre-layout scale.

### Verification harness used (reusable)

`-ui-testing -test-drop-urls <paths>` drives a real `handleMixedBatchDrop`.
**Files must live somewhere the sandbox can read** — `~/Movies/...` works via
`com.apple.security.assets.movies.read-write`; a scratchpad path fails every read
with "you don't have permission" and makes every import look broken. Neutral
fixtures built with ffmpeg (test-pattern reels with real timecode tracks, sine
WAVs) in `~/Movies/ProjectorDropTest` — delete when finished.

`debugPrint` is `NSLog`, so a Debug build launched from the terminal puts the whole
drop trace on stderr. Screenshots: `scratchpad/winrect.swift` prints the window id
for `screencapture -l`, because the app opens on a second display and a fixed
`-R` rect breaks the moment the display arrangement changes. **Do not capture the
whole screen** — the first attempt caught the user's Messages and a Finder window
full of client folder names, and was deleted.

### ~~Pre-existing, NOT touched: three red tests~~ (RESOLVED 2026-08-08)

**No longer true — do not act on the section below.** All three pass as of
`3863d65` ("test(aggregate): address sub-devices by UID, not by position"), which
addressed the sub-devices by UID rather than by position and so stopped encoding
the old order. Full suite is **257 passing, 0 failures**. Kept for the reasoning
only.

### Historical: three red tests

`AggregateDeviceTests.testOnlyTheVirtualDeviceIsDriftCompensated`,
`testDriftQualityIsSetOnTheVirtualDevice` and `testInterfaceCarriesNoDriftQuality`
fail on a **clean tree** as well (confirmed by stashing). They still assert the
old sub-device order — `subDevices().first` as the interface and `.last` as the
virtual device — but the order was deliberately reversed so the stems land on the
DAW's inputs 1-4, and `description()` now puts the loopback first. Production is
right; the assertions are stale. Reported rather than fixed, per no-scope-creep.
The fix is to swap `first`/`last` in those three.

Rest of the suite green, no new failures.

---

## Software update via Sparkle (2026-08-07, uncommitted, builds + launches clean)

The app checks a signed appcast on launch and offers to install a newer build.

**Remaining human step: generate the EdDSA key pair** (`generate_keys`) and paste the
public half into `Info.plist` as `SUPublicEDKey`, which is still empty. Back the private
key up; losing it strands every installed copy.

Until that key exists the service is **inert by design**: no menu item, no Settings
section, one warning line. Confirmed at runtime -
`Update service inert: no SUPublicEDKey in Info.plist`, no dialog, app launches normally.
Verified from Sparkle's source that the naive alternative is much worse: `startUpdater`
*fails* without a key and `SPUStandardUpdaterController` answers that with a modal
"Unable to Check For Updates" alert - an error dialog at every launch.

Package resolution was blocked for a while on a keychain prompt for github.com
credentials (`BinaryArtifactsManager.download → KeychainAuthorizationProvider.get`),
which the user cleared by approving it. If it recurs on another machine, that is the
cause - not the network.

Design: `UpdateServiceProtocol` (Contracts) ← `SparkleUpdateService` (Managers). The
protocol exists for one reason - the two `-spks`/`-spki` temporary-exception entitlements
a sandboxed app needs to replace itself are **not accepted on the Mac App Store**, so a
future MAS build swaps the implementation rather than unpicking call sites. Flagged in
`docs/app-store/entitlements-audit-checklist.md` so an audit cannot pass a build carrying
a disqualifying entitlement without seeing it.

Release pipeline now also: stamps `MARKETING_VERSION` (every build called itself 1.4
while being published as a date - the update dialog would have offered 1.4 over 1.4),
signs the notarized DMG with `sign_update`, adds an entry to `appcast.xml` via
`scripts/appcast.py`, and commits+pushes that file by path. Prints
`Appcast: NOT published` whenever any of that is skipped.

Checks are on by default, hourly at most (Sparkle's floor), never silent
(`SUAutomaticallyUpdate` NO). No launch-time check racing Sparkle's own scheduler.

Verified: builds clean; `Installer.xpc` + `Downloader.xpc` present in the embedded
framework; entitlements expanded to `com.projector.app-spks`/`-spki` in the signed
bundle; all six `SU*` keys in the built Info.plist; launch takes the inert path with no
dialog; `appcast.py` round-trips including same-version rebuild dedupe and XML escaping;
`bash -n` on the release script.

Reading Sparkle's headers caught two bugs before they shipped: `SPUUpdater` has **no
settable delegate** (init-only, so the controller is built after `super.init()`), and the
missing-key alert above. Three main-actor isolation errors also had to be fixed -
`AppDelegate` is not inferred `@MainActor`, so all four uses of the service go through
`MainActor.assumeIsolated`, matching the pin-observer already in that file.

**Not yet exercised: an actual update.** Needs the key, a published release, and a
Developer ID-signed build (the Debug build is ad-hoc signed).

Files: `Contracts/UpdateServiceProtocol.swift` (new), `Managers/SparkleUpdateService.swift`
(new), `ProjectorApp.swift`, `Views/SettingsView.swift`, `Views/ContentView.swift`,
`Projector/Info.plist`, `Projector/Projector.entitlements`, `Projector.xcodeproj`,
`appcast.xml` (new), `scripts/appcast.py` (new), `scripts/build-release.sh`,
`docs/software-update.md` (new), `docs/app-store/entitlements-audit-checklist.md`,
`FEATURES.md`.

## Timeline frames its content on import (2026-08-07, uncommitted, awaiting user verification)

An import now zooms and scrolls the timeline so every reel and clip is on screen,
replacing the fit-to-timeline zoom that drew one reel as a sliver of a two-hour field.

- `TimelineViewModel.requestZoomToFitContent()` bumps `zoomToFitContentRequest`. The
  viewmodel cannot compute the zoom — it depends on the track area's width — so the
  counter is the request and `MultiTrackTimelineView` does the measuring.
- `MultiTrackTimelineView.zoomToFitContent()` inverts the geometric zoom curve in
  `pixelsPerFrame(for:)`: solve for the slider position whose scale makes the content
  span fill the track area, 3% margin either side, clamped to 0…1.
- `scrollFramedContentIntoView` defers the scroll and retries (max 20 run-loop turns)
  until the document view is as wide as the new zoom implies — scrolling in the same
  turn clamps against the old, narrower document and lands short.
- Content too short to fill the viewport at max zoom (4pt/frame) is centred.

Requested from every import path in `ContentView+Timeline.swift`: video drop (single and
batch), audio drop (single and batch), mixed batch, add-to-lane from the media panel, and
the video insert sheet. **Not** on project open — deliberate, not yet asked for.

Files: `ViewModels/TimelineViewModel.swift`, `Views/Timeline/MultiTrackTimelineView.swift`,
`Views/TimelineAccordionView.swift`, `Views/ContentView+Timeline.swift`, `FEATURES.md`.
Builds clean. No clare review yet; no runtime verification yet.

## Crash on zoom, Intel — diagnosed and fixed (2026-08-06, uncommitted)

Four crash reports from a tester on a **Mac Pro 7,1, macOS 12.6.8, AMD GPU**, app 1.4.
All four identical:

```
Metal  -[MTLTextureDescriptorInternal validateWithDevice:]   ← descriptor rejected
Metal  MTLReportFailure → __assert_rtn → abort → SIGABRT
RenderBox  RB::DisplayList::RootTexture::make_texture(…)     ← SwiftUI drawingGroup
AMDMTLBronzeDriver  -[BronzeMtlDevice newTextureWithDescriptor:iosurface:plane:]
```

`AudioClipView` rasterized its waveform with `.drawingGroup()` across the **whole clip**,
whose width is duration × zoom. Zoom tops out at 4 points per frame, so at 24fps a clip
crosses 16384 pixels after ~85 seconds on a Retina display, and 8192 after ~43. Metal
rejects the descriptor and `abort()`s — a crash, not a dropped frame.

`VideoReelClipView` had already solved this: it slices to `visibleXRange` *before*
rasterizing, with a comment reading "a drawingGroup over the full zoomed clip is a request
for a half-million-point texture". The audio path never got the same treatment. Checked:
`VideoTrackView` always receives a real `visibleContentX` in production, so the video half
was never exposed — audio was the only unbounded rasterization.

**Fix**: `View.rasterized(pointWidth:scale:limit:)` in `AudioClipView.swift` applies
`drawingGroup()` only while the texture would be within 4096 pixels, and draws
unrasterized above that. Bound is in pixels, not points, because a Retina display doubles
the texture for the same clip.

**Viewport slicing, done 2026-08-07**: `visibleXRange` now runs
`MultiTrackTimelineView → AudioLaneView → AudioClipView`, mirroring the video path. The
waveform draws only the visible span (widened 64pt either side so a small scroll cannot
expose a gap), sliced from the levels by fraction and offset into place, so the rasterized
width is the window rather than the clip. Rasterization therefore stays *on* at every
zoom, and the 4096 bound became a safety net rather than the mechanism.

`WaveformCache.clampedTargetWidth(_:)` added: requests were `Int(clipWidth)` on an
unbounded CGFloat, which resolves to the widest bucket anyway and traps outright if the
width is ever non-finite. Resolution still follows the whole clip, not the drawn slice, so
panning does not re-request a different level on every scroll.

`linkedAudioStrip(lane:index:ppf:width:)` in `MultiTrackTimelineView` is **dead code** —
defined, never called. Wired anyway so it stays correct if revived.

**Unverifiable here**: no Intel Mac. Rosetta would not settle it either — it translates the
CPU and keeps this machine's GPU and its higher limit.

## Audio settings panel, tightened (2026-08-06, uncommitted)

Verified on screen, not just built:

- **DAW Routing row is gone once the aggregate is the selected device.** Its content was
  a value restating the Device row and a clear button; both now live on the Device row as
  a ✕ and the ?. The row still appears when there is an offer to make — "Set Up…" when no
  device exists, "Switch To It" when one does but is not selected (which selects it rather
  than rebuilding it under a DAW that is already listening).
- **One numbering system, the aggregate's.** `AggregateChannelOrigin.label` no longer
  converts to sub-device numbering, so Stereo Out reads "1: Aurora(n)-TB3 17-18" — the
  port number Cubase prints. Previously the row said 1-2 and the summary said 17-18 for
  the same pair.
- **`AggregateRoutingSummary` is a port list**, one row per output sorted by channel:
  icon, destination, output name, channels. "Your DAW" as a grouping label is gone; each
  stem names itself. Shared with the setup sheet, so both read alike.
- **"How to use this in your DAW" removed** — it opened the generic Setup Guide, which
  says nothing about any of this. `onShowWalkthrough` plumbing deleted with it.

Not done, worth raising: the output rows are ordered Stereo Out, MX, DX/SFX, so the
channel column now reads 17-18, 3-4, 1-2. Pre-existing order, newly visible.

## Earlier — three DAW routing UI changes (committed in 43ba270)

Built and unit-tested; **not yet verified at runtime by the user**.

1. **`?` help button** on the DAW Routing row. Tooltip "What is this?", click opens a
   popover explaining why an aggregate has to exist. New `SettingsHelpButton` component
   and `SettingsDesign.popoverWidth`.
2. **Device renamed** to `Projector Aggregate Device`. `aggregateName` went from a
   function of the interface name to a constant, so the string a user hunts for in their
   DAW is the same every rebuild. `createAggregate` lost its now-unused `interfaceName:`.
3. **Channel picker names its origin** — "Aurora(n)-TB3 1-2", "Projector Virtual 1-2"
   instead of "1-2" and "33-34". New `AggregateChannelOrigin`, fed by
   `AggregateDeviceManager.subDeviceUIDs()` reading
   `kAudioAggregateDevicePropertyFullSubDeviceList` (verified against the SDK header:
   CFArray of CFString, order significant, caller releases). Only applied on the
   aggregate; an ordinary interface keeps bare numbers.

4. **Origin shown on the Audio page too**, not just in the picker — the assigned-output
   rows read "Projector Virtual 1-2" instead of "Out 33-34". The "stereo"/"mono"
   qualifier is dropped when an origin is shown, because the two together overflow the
   fixed 200pt control; the range says the same thing. `SettingsValue` now truncates
   rather than pushing its clear button out of the row.
5. **Every DAW-facing port named** — new `Managers/VirtualPortLabels.swift`. Channels
   carrying a stem read "DX/SFX L"; every other channel reads its device and number
   ("1: Aurora(n)-TB3 7", "Projector Virtual 8"), the same string the settings rows use.
   Published from `AudioOutputManager` on both `saveMappedOutputs` (every change) and
   `loadMappedOutputs` (launch, device switch, rebuilt aggregate).

Files: `Managers/AggregateDeviceManager.swift`, `Managers/VirtualPortLabels.swift` (new,
**registered in project.pbxproj by hand** — `Managers/` is an explicit group, not a
synchronized one, so new files there are not picked up automatically),
`Managers/AudioOutputManager.swift`, `Views/SettingsView.swift`,
`Views/DAWRoutingSetupModel.swift`, `Views/DAWRoutingSetupSheet.swift`,
`ProjectorTests/AggregateDeviceTests.swift`. 224 unit tests pass.

### Measured: channel names can be published to the DAW

`kAudioObjectPropertyElementName` on a device's **input** elements:

| Question | Answer |
|---|---|
| Settable on BlackHole? | yes — `AudioObjectIsPropertySettable` true, write returns `noErr` |
| Visible to other processes? | yes — a second process reads back what the first wrote |
| Inherited by the aggregate from its sub-devices? | yes |
| **Settable on the aggregate itself?** | **yes** |
| Does a name set on the aggregate beat the inherited one? | **yes** |
| Writable from a sandboxed app? | yes — tested in a signed bundle with Projector's entitlements |

None of that is promised in the headers, which is why it was measured rather than assumed.

**Write on the aggregate, never on the devices underneath it.** The first version wrote
on BlackHole, which worked but renamed channels system-wide for every other application
using it. The last two rows above are what made the better version possible: the names
now live on the device Projector created and die with it, and the user's interface and
BlackHole are left alone — verified after the fact, both still report empty names.

### The stems now take channels 1-4 (sub-device order reversed)

Cubase ignores CoreAudio channel names outright — proven, not guessed: the aggregate
carried *two* independent name sources (the Lynx driver's own stream names, present since
creation, and Projector's element names) and Cubase displayed neither, generating
"Projector Aggregate Device 1…48" from the device name. A cache would explain ours being
absent; it cannot explain the Lynx's, which predate everything.

So the fix cannot rely on names at all. The loopback device is now the **first**
sub-device, which puts the stems on inputs **1-4** in every host, named or not:

```
ch 1-4    DX/SFX L/R, MX L/R        ← what the DAW records
ch 5-16   spare loopback
ch 17-48  the user's interface       ← "your interface's channels begin at 17"
```

**Order is not the clock.** `kAudioAggregateDeviceMainSubDeviceKey` still names the
interface, so it remains the time source wherever it sits in the list. Conflating the two
is what made this look unchangeable earlier; a test now pins them apart.

**Existing devices keep working.** `AggregateChannelOrigin.current(in:)` reads the real
sub-device order back rather than assuming it, so an aggregate built before this change is
still described and routed correctly until the user rebuilds it. Verified on the real
machine: the app labelled the old interface-first device correctly (interface on 1-32,
stems on 33-36) rather than mislabelling it under the new layout.

### A DAW lists every port, so every port needs a name

Cubase showed 48 rows reading "Projector Aggregate Device 1…48": the *interface* half
reports no channel names, and a DAW that finds none generates one from the device. Naming
only the four stem channels would still have left 32 generic rows above them. Hence
naming all of them. Confirmed on the real device with the app running:

```
ch 1-32   "1: Aurora(n)-TB3 1" … "1: Aurora(n)-TB3 32"
ch 33-36  "DX/SFX L"  "DX/SFX R"  "MX L"  "MX R"
ch 37-48  "Projector Virtual 5" … "Projector Virtual 16"
```

Open: the interface's own name carries a "1: " prefix from the Lynx driver, so those read
"1: Aurora(n)-TB3 7". Accurate, and identical to the Device dropdown, but awkward.

### The aggregate persists, and needs no code to do so

An earlier note in this file claimed the device was process-scoped. **That was wrong**,
and it was wrong because it rested on one uncontrolled observation: the device was gone
after Projector was killed, at a moment the user was also clicking through the Remove
button he had just been asked to test. Removal was attributed to the kill.

What was actually measured afterwards, twice, with a throwaway aggregate:

| Condition | Result |
|---|---|
| Public aggregate, unsandboxed creator exits | **survives** |
| Public aggregate, sandboxed creator exits (app bundle, same entitlements) | **survives** |
| `AudioHardwareDestroyAggregateDevice` | removed, config cleaned up |

CoreAudio writes a public aggregate into
`/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist`, which `coreaudiod`
reads at startup — so it outlives the process **and** a reboot. The header is explicit
that only a *private* aggregate is "not persistent across launches of the process that
created it"; Projector already passes `kAudioAggregateDeviceIsPrivateKey: 0`.

So a crash or an accidental quit leaves the user's DAW untouched. The only teardown path
is `removeAggregate()`, reached solely from the ✕ on the DAW Routing row.

The earlier claim also implied the setup had to be re-run every session. It does not.

### Also noticed, not changed

- `FEATURES.md` has no DAW routing entry at all, though CLAUDE.md requires one.
- Pre-existing warning at `SettingsView.swift:396` — `result of 'try?' is unused` in
  `removeDAWRouting()`.

---

## ✅ BlackHole install verified (2026-08-05, post-restart)

The restart did what it was for. `coreaudiod` now publishes both drivers:

```
BlackHole 16ch    16 in / 16 out, 48000 Hz, Virtual
BlackHole 2ch      2 in /  2 out, 44100 Hz, Virtual
```

No Projector aggregate device exists yet (only Pro Tools' own `Pro Tools Aggregate
I/O`), so the setup flow starts from a clean state. `VirtualAudioPorts.readiness`
should return `.ready` and Settings ▸ Audio ▸ DAW Routing ▸ Set Up… should go
straight to "Create Audio Device" with no download.

### Still to do — run the feature end to end

1. Settings ▸ Audio ▸ **DAW Routing ▸ Set Up…** → Create Audio Device
2. Audio MIDI Setup: `Projector + 1: Aurora(n)-TB3` exists, Lynx is clock master,
   drift compensation ticked on **BlackHole only**
3. Speakers still work (Stereo Out on Lynx 1-2); DX/SFX and MX silent in the room
4. Pro Tools on the same aggregate: DX/SFX on inputs 1-2, MX on 3-4
5. **Sync**: play a full reel with both apps running, confirm no drift at the tail
6. Remove tears the device down and restores the previous selection

---

## DAW routing via an aggregate device (2026-08-05)

Stems can reach a DAW as inputs. macOS cannot loop an output back to an input, and
Apple does not grant the DriverKit audio entitlement for virtual devices, so Projector
aggregates the user's interface with BlackHole and installs BlackHole when missing.

**The sandbox permits aggregate creation** — measured in the real signed app with only
`com.apple.security.device.audio-output`: create returned `noErr`, the device appeared
in Audio MIDI Setup, destroy returned `noErr`.

### Routing, as settled with the user

| Output | Where | DAW sees |
|---|---|---|
| Stereo Out | interface ch 1-2 | — (room monitoring) |
| DX/SFX | first loopback pair | inputs 1-2 |
| MX | second loopback pair | inputs 3-4 |
| added later | continues up loopback | inputs 5+ |

Sub-device order **is** the channel map: interface first as clock master, loopback
second with drift compensation. This went through two wrong versions first —
everything on the interface, then everything on the loopback — and the tests caught
both by failing on exactly the assertions that encoded the old layout.

### Traps paid for

- **A driver on disk is not a device.** `BlackHole16ch.driver` sat in
  `/Library/Audio/Plug-Ins/HAL` while the device list showed only the 2ch build.
  `Readiness.installedPendingRestart` exists for this; without it the setup sheet
  waited forever for a device that could not arrive, having just promised to continue
  on its own.
- **CoreAudio publishes its device list asynchronously.** Creation returns `noErr` and
  the device is plainly there, yet a lookup by UID milliseconds later finds nothing.
  The identifier from the create call is retained rather than re-derived — re-deriving
  it orphaned a device on a real machine.
- **`removeAggregate` returning `Void`** made "nothing to remove" and "removed it"
  indistinguishable, which is how that orphan survived a cleanup reporting success.
  It returns `Bool` now.
- **A readiness check that reads the filesystem is untestable.** `readiness(in:)` grew
  a `driverOnDisk` parameter defaulting to the real check, so tests pin both branches
  rather than depending on what the test machine happens to have installed.
- **Drift-quality constants are macOS 13+.** The keys are plain `#define`s with no
  availability limit; only the named enum values are annotated. The documented value
  is spelled out, since the app still supports macOS 12.

### Not built yet

Step 6 — the per-DAW walkthrough. `OnboardingView.DAWType.setupSteps` already covers
six DAWs and is the place for it. The setup sheet's "How to use this in your DAW" link
currently opens the generic Setup Guide, which says nothing about any of this.

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
