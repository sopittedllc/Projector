# UX User-Ready Gameplan

**Date**: 2026-07-24
**Source**: Full static UI/UX audit of `Projector/Views/` (33 view files, 88 Swift files total) plus drag-drop pipeline trace.
**Status of branch**: `codex/repair-sync-core` has uncommitted WIP that already targets Phase 0 below.

Per CLAUDE.md: code audit finds issues; **no fix is complete until the user runs the app and verifies**. Each phase ends with a runtime verification checklist.

---

## Root-Cause Findings

### F1. Multi-file drop collapses to one file (P0 — reported bug)

The internal drag pipeline carries the full selection in `DragContext`, but the
`NSItemProvider` returned from `.onDrag` carries **only one file URL**
(`MediaDragProvider.provider(for: item)` — `FileManagerView.swift:851`). Any drop
handler that misses `DragContext` falls back to the pasteboard and sees exactly one
file. Three ways `DragContext` gets missed:

1. **5-second self-destruct mid-drag** — `DragContext.scheduleCleanup()`
   (`Models/MediaItem.swift:56-66`) starts a 5s timer **when the drag begins**, not
   when it ends. Hover/position for >5s and the multi-selection silently clears;
   the drop lands via the single-file pasteboard fallback. This is the primary
   suspect for "drag 3, get 1."
2. **Data race on external drops** — `handleEmptyAudioDrop`
   (`MultiTrackTimelineView.swift:1857-1874`) appends to `urls` from concurrent
   provider callbacks with **no lock**. `AudioLaneView.swift:611` does the same
   collection *with* an `NSLock` — the unlocked copy can drop entries or crash.
3. **Competing drop targets calling `dragContext.end()`** — multiple overlapping
   `DragCaptureView`s; the first handler that runs ends the context for everyone.

Related defects found in the same pipeline:

- `Array(Set(urls))` (`MultiTrackTimelineView.swift:1881`) — destroys drop order;
  batch files place in random sequence.
- `handleMultiFileDropNative` (`MultiTrackTimelineView.swift:1353-1405`) hard-codes
  `atFrame: 0`, ignoring drop location for multi-drops.
- `MediaItemRow.onDrag` uses single-item `dragContext.begin(item)`
  (`MediaItemRow.swift:107`) — currently preview-only dead code, but a live trap.

### F2. Containers don't expand when content is added (P0 — reported bug)

- **`resizeToFitLanes()` is never called.** `TimelineViewModel.swift:331` contains a
  correct content-based height calculation (header + ruler + video track + N lanes +
  footer, clamped) — and has **zero call sites**. Timeline height only changes via
  the manual resize handle, so added lanes get squeezed/clipped.
- `FileManagerView.calculateMinHeight()` (`FileManagerView.swift:39-46`) returns a
  fixed constant regardless of content rows.
- WIP on this branch (uncommitted): window grows on first import
  (`growWindowForFirstImport()` in `ContentView+Helpers.swift`), header collapses
  gracefully via `ViewThatFits`. Needs finishing + runtime verification.

### F3. Tooltip / accessibility coverage is ~23% (P1 — reported bug)

36 `.help()` calls across 155 buttons. Per-file audit (buttons | help | a11y labels | kbd):

| File | Buttons | .help | a11y | kbd |
|---|---|---|---|---|
| OptimizationSheetView | 19 | 1 | 0 | 10 |
| FileManagerView | 14 | 6 | 0 | 2 |
| SettingsView | 14 | 1 | 8 | 1 |
| MultiTrackTimelineView | 12 | 0 | 2 | 3 |
| SettingsAccordionView | 11 | 5 | 0 | 0 |
| SpotMediaSheet | 7 | 0 | 2 | 2 |
| ConsolidationSheetView | 7 | 0 | 0 | 6 |
| SaveProjectSheet | 6 | 0 | 0 | 2 |
| CleanupOriginalFilesDialog | 6 | 0 | 0 | 2 |
| EmbeddedTimecodeSheetView | 4 | 0 | 0 | 2 |
| BatchTimecodeSheetView | 4 | 0 | 0 | 2 |
| AudioLaneView | 4 | 0 | 0 | 0 |
| OnboardingView | 4 | 0 | 0 | 0 |
| TransportBarView ✅ | 6 | 6 | 9 | 1 |
| VitalControlsBar ✅ | 2 | 4 | 3 | 1 |

TransportBarView / VitalControlsBar are the gold standard; sheets and timeline views
are near-zero. The Views-layer rule ("Accessibility labels present") is currently
failing its own pre-commit checklist in most files.

### F4. Inconsistent feedback & error surfacing (P1)

- `addVideoToTimeline` failure only `debugPrint`s (`ContentView+Timeline.swift:530-532`)
  — the user sees a silent no-op. Background audio extraction failure likewise
  (`:770-772`). Other paths correctly use `alerts.show(.error(...))`.
- Empty states exist only in `FileManagerView` and `PanelComponents`; timeline lanes
  and other panels have none.
- Undo appears in only 3 files — coverage of destructive operations (media delete,
  clip removal) unverified.

### F5. Design-token drift (P2)

- 43 hardcoded `.padding(N)` values in Views (rule: `Spacing.*` only).
- 106 hardcoded `.font(.system(size:))` vs 152 `Typography.*` usages (~40% bypass).
- Icon sizes not audited against the HIG scale (16/18/20/24pt) — spot checks found
  9, 10, 14pt one-offs.

---

## Gameplan

### Phase 0 — Land the in-flight work (this branch)
1. Finish + build the uncommitted changes (window growth, ViewThatFits header,
   ConsolidateMediaButton compact mode).
2. **Runtime verify**: fresh launch → import first file → window grows anchored
   top-left, never off-screen; narrow the media panel → header flips to compact
   icons with tooltips; nothing half-clips.
3. Commit on `codex/repair-sync-core`.

### Phase 1 — P0 correctness (multi-drop + expansion)
1. **DragContext lifetime**: remove the drag-begin timeout; refresh it from
   `draggingUpdated` (or clear only on `draggingExited`-without-drop + Esc). A drag
   in progress must never self-clear.
2. **Locking**: give `handleEmptyAudioDrop` the same `NSLock` collection pattern as
   `AudioLaneView.handleDrop` — or better, extract ONE shared
   `loadAllURLs(from:completion:)` utility and delete the four duplicated copies
   (MultiTrackTimelineView ×2, AudioLaneView, MediaImportCoordinator).
3. **Order**: replace `Array(Set(urls))` with order-preserving dedupe.
4. **Drop position**: thread the real target frame through `handleMultiFileDropNative`.
5. **Wire `resizeToFitLanes()`**: call from `setupObservers` when lane count grows;
   respect the user's manual resize as a floor, never shrink automatically.
6. Make `calculateMinHeight()` content-aware (rows × rowHeight, clamped).
7. Delete or fix `MediaItemRow` dead code (single-item drag trap).

**Runtime verify**: drag 3 audio files from Finder → existing lane, empty lane area,
and new-lane zone: all 3 appear, in order, at the cursor frame. Same from the media
panel with 3 selected — including after hovering 10+ seconds before dropping. Add
4 lanes → timeline grows to fit without manual resize. Mixed video+audio drop of 5
files → all placed.

### Phase 2 — P1 discoverability (tooltips, a11y, keyboard)
1. Tooltip pass over the F3 table, worst-first: every interactive control gets
   `.help()` with verb-first copy ("Import media files…", not "Import button").
2. Accessibility labels on all icon-only buttons (Views-layer pre-commit rule).
3. Keyboard shortcuts audit: every sheet needs Return/Esc defaults; document global
   shortcuts in one place.
4. Acceptance: per-file grep shows help ≥ icon-only-button count; VoiceOver reads
   every control meaningfully.

**Runtime verify**: hover every toolbar/sheet control → tooltip appears; tab-navigate
each sheet; Esc dismisses; VoiceOver spot-check on timeline + media panel.

### Phase 3 — P1 feedback (errors, progress, empty states)
1. Route every user-triggered failure through `AlertCoordinator`
   (`alerts.show(.error(...))`) — start with `addVideoToTimeline` and audio
   extraction. debugPrint-only failure handling is forbidden for user actions.
2. Empty states for: timeline with no media (beyond welcome overlay), audio lane
   with no clips, search-with-no-results in media panel.
3. Progress feedback for operations >500ms (waveform generation, optimization,
   consolidation) — verify existing ProgressViews actually appear.
4. Undo coverage for destructive ops: media delete, clip delete, lane delete.

**Runtime verify**: import a corrupt/unsupported file → visible alert, not silence;
search for gibberish in media panel → "no results" state; delete a clip → Cmd+Z
restores it.

### Phase 4 — P2 polish (token sweep)
1. Replace the 43 hardcoded paddings with `Spacing.*`; the 106 hardcoded font sizes
   with `Typography.*` (add missing scale steps rather than keeping one-offs).
2. Icon sizes onto the 16/18/20/24pt HIG scale.
3. Re-run CLAUDE.md audit greps until clean; add them as a CI/script check
   (`scripts/`) so drift can't return.

**Runtime verify**: full visual pass per CLAUDE.md checklist — symmetric padding,
aligned headers, breathing room, uniform section gaps.

---

## Sequencing & rationale

Phases 1→3 are ordered by user pain: broken interactions first, invisible affordances
second, silent failures third, cosmetics last. Phase 0 exists because half-landed
layout work on this branch would conflict with Phase 1 items 5–6.

Suggested per-phase workflow (per CLAUDE.md): joseph implements from this plan →
clare reviews → user runtime-verifies against the checklist → commit. Phases are
independent commits; do not batch phases into one commit.
