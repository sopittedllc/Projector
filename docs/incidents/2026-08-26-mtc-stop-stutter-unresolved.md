# Incident: MTC stop stutter — seven failed fixes, unresolved

**Date**: 2026-08-26
**Severity**: HIGH (core workflow: chasing a DAW)
**Status**: UNRESOLVED — sync work to be reverted, symptom still present

## Summary

Reported: pressing play in the DAW has a lag before picture rolls, and stopping
produces "a stutter where it replays a short amount". Seven substantially
different changes were made to the MTC chase path over one session. Each removed
a real, demonstrable defect. **None changed the reported symptom.** The user's
description after the seventh was "exact same behavior".

This document exists so the next attempt does not repeat the session.

## The most important thing in this document

**The instrumentation was wrong for the entire session.**

`DispatchTime.rawValue` is in `mach_absolute_time` units, not nanoseconds. On this
machine `mach_timebase_info` reports numer 125 / denom 3, so one unit is 41.667ns.
Lead times were computed as `(rawValue difference) / 1_000_000` and therefore
reported **41x shorter than reality**:

| logged | actual |
|--------|--------|
| "2ms"  | 83ms   |
| "0ms"  | 0–41ms |

Decisions were made on those numbers, including cutting `lockFrames` from 8 to 2
to reduce a lag that was never measured correctly. Any conclusion in this session
that rested on a lead-time reading should be treated as unverified.

Verify the timebase before trusting any host-time arithmetic:

```swift
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
// 1 unit = Double(tb.numer)/Double(tb.denom) ns
```

`CMClockMakeHostTimeFromSystemUnits` takes mach units, so *that* conversion was
correct — only the logging was wrong.

## What the traces did establish

Captured by launching the binary directly with stderr redirected (see
**Instrumentation** below) while the user hit play/stop in their DAW.

1. **The DAW sends no MMC Stop.** It sends `MMC Locate` to the play-start and
   simply ceases timecode. A stop is only knowable to Projector as an absence.
2. **Stopping delivers three conflicting positions in ~18ms**: the Locate, then
   the receiver draining its *pre-stop* position (29 frames away), then timecode
   from the located position.
3. **A seek does not stop a rolling player.** `resumeAfterSeek: false` only means
   "do not call `play()` in the completion". A locate arriving mid-playback
   repositioned picture and let it roll on from there.
4. **Picture free-ran past the stop** for the whole dropout window before the
   transport was declared stopped, then the settle snapped it back.
5. **MIDIKit's `preSync` payload was discarded.** `convertMTCState` flattened the
   state for display, losing the predicted lock time and lock timecode.
6. **Playback was started at `.sync`.** MIDIKit's own reference receiver
   (`Examples/Advanced/MTCExample/Receiver/MTCRecHost.swift`) schedules playback
   on `.preSync` for the predicted lock instant and does **nothing** at `.sync`.
   `.sync` means the lock instant has already passed, so starting there is late by
   construction — no `lockFrames` value fixes it.
7. **`AVPlayer.setRate(_:time:atHostTime:)` was never used.** Per `AVPlayer.h`:
   "the timebase will immediately start running at the requested rate from an
   earlier time so that it will reach the requested itemTime at the requested
   hostClockTime". That is a chase, described exactly. Requires
   `automaticallyWaitsToMinimizeStalling == false` (already true) or it raises
   `NSInvalidArgument`.

## Why the documented fix did not land either

`setRate(atHostTime:)` was implemented and **did fire** — six times per test — but
with effectively zero usable lead. The predicted lock has an ~83ms shelf life at
`lockFrames: 2`, and the delivery path is four async hops:

```
MIDIKit timer thread
  → Task → MIDISyncActor.handleMTCStateChange   (actor hop)
  → emitState → AsyncStream
  → MIDISyncViewModel @Published                (MainActor hop)
  → Combine sink → PlaybackEngine
```

Measured: the actor saw ~83ms of lead, the engine saw 0–41ms. Delivery consumed
half to all of it, so `setRate` received a host time that had already passed and
degraded to a plain `play()`.

**This is the most promising unexplored lead.** Either deliver the lock straight
from the `MTCReceiver` `stateChanged` callback to `@MainActor` (one hop), or raise
`lockFrames` so lead survives — noting the trade-off below.

### The lockFrames trade-off, correctly stated

With *scheduled* locking, more lock frames does **not** delay playback the way it
did with `play()`-at-`.sync`. Per the header, picture "will not jump backwards,
but instead will sit at itemTime until the timebase reaches that time" — so
picture holds the lock timecode and begins moving precisely at the lock instant.

But it holds a frame `lockFrames` *ahead* of where the DAW currently is, for the
lead duration. At `lockFrames: 8` / 24fps that is a frozen, one-third-second-ahead
frame for 333ms. Cutting delivery latency is therefore preferable to raising
`lockFrames`.

## Structural finding (independent of the symptom)

The playback path has no single owner of "where are we, and are we rolling":

- **21** `play()`/`pause()` call sites
- **14** seek call sites
- **5** writers to `currentFrame`
- audio scheduling scattered across ~20 places

Every fix in this session had to be made in several of them at once, and each new
mechanism could be undone by an older one it did not know about. Until position
and roll state have one owner, fixes here will keep behaving like this.

## Also found, NOT fixed

**During MTC chase, audio is never re-synced.** `handleTimeUpdate` returns inside
the `isMTCSynced` branch before reaching `syncAudioClips()`, so audio is scheduled
once at lock and left to free-run while video is corrected by seeks. Video and
audio can separate over a long take.

This was never investigated as a cause of the reported symptom. **Every fix this
session was to picture.** If what the user perceives as a stutter is audio
restarting or dropping, none of this session's work would have touched it —
`startActiveAudioClips()` / `stopAllAudioClips()` fire on every sync transition.
**Start here next time.**

## Instrumentation (keep this — it is the only thing that worked)

`open -a` does **not** capture stderr. The unified log does not capture it either
(`log show --predicate 'process == "Projector"'` returned nothing). Launch the
binary directly:

```bash
pkill -x Projector
APP=~/Library/Developer/Xcode/DerivedData/Projector-*/Build/Products/Debug/Projector.app
nohup "$APP/Contents/MacOS/Projector" > trace.log 2>&1 &
```

`syncTrace` / `midiLog` use `NSLog` deliberately: stdout is fully buffered when
redirected, so `print` output disappears exactly when it is being collected.

Two rounds of reasoning from the code alone found nothing. Every defect listed
above came from a trace.

## What is good and what should be reverted

Nothing pushed, no DMG built. History as it stands:

```
HEAD     docs: write up the unresolved MTC stop stutter        <- this file
9753f3c  docs: launch page, and a Dropbox mirror alongside Drive
c706501  fix(sync): tighten the chase, and name the MIDI ports
a2d34fd  fix(timeline): one lane per stem across drops, ...
dbd316f  (base, already released as 2026.08.25)
```

| Commit | Verdict |
|---|---|
| `a2d34fd` | **Keep.** Timeline fixes, 7 new unit tests, independent of sync. Runtime verification still owed. |
| `c706501` | **Split.** See below. |
| `9753f3c` | **Keep.** Launch page and Dropbox mirror, unrelated to sync. |
| `HEAD` | **Keep.** This document. |

Plus **uncommitted working-tree changes**, all of them chase work and all of them
to be discarded: the park model, the scheduled chase lock, the `MTCChaseLock`
contract addition, and the frame-by-frame tracing.

```bash
git checkout -- Projector/          # discard the uncommitted chase work
```

### Splitting c706501

It mixes two unrelated things:

- **MIDI port rename** (`Projector MTC IN` / `MMC IN` / `MMC OUT`) — verified at
  the CoreMIDI layer with `MIDIGetDestination` / `MIDIGetSource`. **Keep.**
- **All chase changes** — lock preroll, Full Frame locates, backwards locates,
  drift staleness, locate authority, dropout window, decoder preroll. **Revert.**

A plain `git revert c706501` removes both. To keep the rename, revert into the
index and re-stage only the rename:

```bash
git revert --no-commit c706501
git checkout c706501 -- Projector/Views/SettingsView.swift \
                        Projector/Views/OnboardingView.swift \
                        Projector/Views/WelcomeOverlayView.swift
# then hand-restore in MIDISyncActor.swift: the port name/tag constants,
# setupVirtualInput/addVirtualInput, refreshAvailableInputs, reconnectInput,
# and in MIDISyncViewModel.swift the doc-comment port names.
git commit
```

`MIDISyncActor.swift` needs hand-editing because the rename and the chase changes
touch the same file. The chase parts of it are `lockFramesRequired`,
`dropoutFramesAllowed`, the `syncPolicy` construction, and the locate-raising in
`handleMTCFullFrame` / `handleMTCFullFrameFromUniversal`.

A `git reset --hard a2d34fd` is simpler but loses the port rename, the launch
page and this document.

## Process failure

The user's own `CLAUDE.md` puts **RESEARCH (thomas)** first in the automation
chain and carries an explicit Anti-Hallucination Protocol requiring API behaviour
to be verified against official documentation.

That step was skipped. Seven rounds of trace-driven patching happened before
anyone read MIDIKit's reference implementation or `AVPlayer.h` — both of which
were on disk the entire time, and both of which described the correct
architecture. The user had to say *"there has got to be PLENTY of documentation
about playhead implementation, we don't need to be improvising"* to get the
research done.

**Read the reference implementation before writing the first patch.**

## Next steps, in order

1. **Determine whether the symptom is audio or picture.** It has never been
   established. The frame-by-frame trace (`pic N | mtc N | rate R | parked B`)
   settles the picture side; nothing equivalent exists for audio yet.
2. **If picture:** cut the four-hop delivery latency so `setRate(atHostTime:)` gets
   real lead, and follow MIDIKit's reference — schedule on `.preSync`, do nothing
   at `.sync`.
3. **If audio:** investigate `syncAudioClips()` never running during chase.
4. **Before either:** give position and roll state a single owner.
