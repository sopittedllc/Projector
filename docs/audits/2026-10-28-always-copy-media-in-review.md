# Review: Always Copy Media In (clare, 2026-10-28)

**Verdict**: FAIL — 2 blockers, 8 warnings. Plan: `docs/plans/ALWAYS-COPY-MEDIA-IN-PLAN.md`.

## Blockers

1. **Optimize overlapping a copy acts on the user's outside file.**
   `OptimizationResult.originalURL` is captured at analysis time; nothing blocks
   Optimize while a copy is queued. "Move originals aside" / "Delete originals"
   can then move or trash the file on the external drive; `updateReferences`
   (exact-URL match) can leave reels on the unoptimized copy; a copy landing
   after optimize is orphaned and the item loses `originalURL`.
2. **Stale `.partial` sweep races live copies and matches user files.**
   `projectOpened()` starts the sweep in a Task and enqueues immediately; the
   sweep can unlink an in-flight `.partial`. `isPartialName` matches any
   `.*.partial`, including a user file copied under that name.

## Warnings

3. Same-path re-export (re-bounced mix) is treated as a duplicate and reels are
   repointed to the stale copy — match on path only.
4. `existingCopy` (name + size) can bind equal-size same-named files from
   different folders.
5. `reconcileReferences` rescans every item/reel/clip on every timeline change.
6. Playback engine is not synced after a repoint; it may keep reading the
   outside file.
7. Project switch / Save As mid-copy orphans the copy; Save As doesn't re-enqueue.
8. Clone can't be cancelled; a cancelled clone lands unreferenced in `Media/`.
9. `recordCopy` keeps the first `originalURL`.
10. `attributesOfItem` / `isReachable` run on the main actor (slow volumes).

## Nits

- `MediaItem.originalURL` vs `OptimizationResult.originalURL` name clash.
- Magic number at `MediaCopyInCoordinator.swift:471`.
- Missing DocC on `isPartialName`, thin doc on `MediaCopyFailure.summary`.
- Tests missing: optimize overlap, project switch, cancel, user `.partial`, wrong bind.

## Checked OK

Copy destinations confined to `Media/`; `moveItem` never overwrites; sources
never written; untitled gate covers every external entry point and Cancel
imports nothing; legacy `project.json` decodes; layer rules, Spacing tokens,
no client material.

## Re-review

**Verdict**: PASS with 1 warning. Both blockers and warnings 3-8, 10 are fixed (9 accepted). Build not confirmed: my xcodebuild (separate derivedData) printed no result before the timeout. Read-only review.

**Blockers**: 1 and 2 fixed.
- 1: `OptimizationViewModel.canOptimize` includes `!isMediaCopying` (fed from `$status`), sheet button and FileManagerView gate it, `isInsideProject` guards trash and move, `updateReferences` matches by path against both the analysis URL and the item's current URL.
- 2: sweep is awaited before enqueue in `projectOpened`, skips `activePartialPaths`, and `isPartialName` requires the `.projector-copy-<UUID>.partial` shape. No actor deadlock: sweep is a plain actor method and `copyIn` suspends in its detached task.

**New findings**
1. WARNING - `MediaCopyInCoordinator.swift:233-238,509-515` plus `ContentView+Timeline.swift:691`: the late-reel watch list is bypassed by duplicates. `importFile` returns the existing item without calling `onItemImported` (`ProjectMediaLibrary.swift:324`), yet `addVideoReel(from: url)` still names the dropped outside URL. A file dropped a second time, or after the 30 s expiry (a long timecode sheet), gets a reel on the outside file. Nothing repoints it until the next open, Save As or relink. The project saves with that path and loses the "project is self-contained" guarantee. Not destructive, because `ProjectFolders` guards the destructive actions. Fix: create reels from `mediaItem.url`, or watch an item whenever an import resolves to one with `importedFromURL`. Replace the timer with that rule.
2. SUGGESTION - `MediaCopyInCoordinator.swift:271,326`: `isQueued` dedups by source path, so a second item with the same source gets no job. `repoint` filters by `itemID`, so that item stays outside until reopen. Rare; `existingItem` makes it hard to reach.
3. SUGGESTION - after Save As, `ProjectDocument.save(to:)` does not move `Media/`. Old-folder items are queued as external and copied again, which is intended. A copy that lands mid-Save-As is deleted and re-copied, which costs double I/O for large files. No data risk.
4. SUGGESTION - `ProjectMediaLibrary.existingItem` calls `MediaFingerprint.of` on the main actor, but only on an origin-path hit.
5. SUGGESTION - `isInsideProject` logs only. If a copy failed, "Delete or Move originals" silently skips that item. Consider telling the user.

**Save As delete path** (`:403-411`, `discardLanded` at `:430`): SAFE.
- `copyIn` never overwrites. `uniqueDestination` plus `moveItem` guarantee the file is new, and it is removed only if `copyURL != job.source`.
- No saved `project.json` can reference it: `apply` was not called.
- It cannot delete a pre-existing in-project item. A source already inside the old project returns `url` itself and `discardLanded` skips it.
- The `generation` branch (`:397`) is equally safe.

**Ordering**
- `reset()` runs before open. The `projectOpened` and `enqueueExternalMedia` generation and `fileURL` guards make stale tasks stand down.
- `isQueued` makes `onProjectDidSaveAs` plus the re-add idempotent.
- `drain` cannot spin.

**Checked OK**: DocC on `isPartialName` and `summary`, `reconcileGracePeriod` constant (magic-number nit fixed), `originalPath` decode compatibility, `importedFromURL` rename.

## Delta review

**Verdict**: PASS with 2 warnings. Re-review finding 1 (duplicate/late drops land on the outside file) is fixed by placing on `importFile(...).url` plus `settle`. Read-only; build and tests not run.

**Checked OK**
- Single, batch, mixed and held-back paths. Held-back files never import or place, so no reel exists to miss. Mixed audio goes through `addAudioToTimeline`, which settles at `ContentView+Timeline.swift:891`.
- `settle` (`MediaCopyInCoordinator.swift:514`) is synchronous. After `addVideoReel` returns (`:702`) and after `prepareAudioLanesForAllTracks` returns (`:728`) there is no `await` before the call. A copy that lands inside `addVideoReel` or the audio-lane `await` is repointed by `apply`'s path match, and `settle` becomes a harmless no-op. Clips built from the stale `reel` value are fixed by the second `settle`.
- `performChannelSplits` re-reads the reel by id (`:1203`), so line 1219's `reel.sourceURL` match sees the repointed URL.
- Extracted tracks 1+ key on `clipId` (`:759-766`), not the URL, so a repoint does not orphan them.
- `applyNamedOutputToVideoAudio` receives the settled URL (`:728-731`).
- Sites 31, 204, 215, 834, 1316 and 1344 match on dropped path OR item URL, so they do not miss. I found no double-match: a path equal to both is the same reel.

**Warnings**
1. `ContentView+Timeline.swift:676-678` (called inside `contains`/`last(where:)` at 31, 204, 215, 834, 1316, 1344): `existingItem(for:)` runs once per reel or clip. On an origin-path hit it calls `MediaFingerprint.of` on the main actor (`ProjectMediaLibrary.swift:462-465`), so a drop of N files onto M reels can fingerprint N x M times. Hoist `let placed = mediaLibrary.existingItem(for: url)?.url` out of the closure. Also, `existingItem` compares symlink-resolved paths but `isPlacedFile` compares raw `sourceURL ==`, so a symlinked or non-standardized reel path can miss.
2. `ContentView+Timeline.swift:758, 780`: the background extraction (tracks 1+) and the hard-pan analysis read the stale `reel.sourceURL`, which is the original even after the copy lands. They work while the original exists, but fail silently with only a `debugPrint` if the user has deleted or moved originals by then (extraction at `:773`). Re-read `timelineManager.timeline.videoReels.first { $0.id == reel.id }?.sourceURL` when the task starts.

**Suggestions**
- `:474, :487` compare against `item.url` exactly. That is right now that placement uses the item URL, but a pre-existing project whose reel still names the original, with an item already repointed, will not show "already in timeline" until reopen repoints it.
- `extraItemIDs` handling (re-review suggestion 2): `apply` (`:456-466`) now loops all ids, and `repoint` filters by owner, which looks correct. I did not trace where the jobs are built.
