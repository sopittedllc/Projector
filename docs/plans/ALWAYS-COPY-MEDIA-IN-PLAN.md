# Always Copy Media Into the Project (replaces Consolidate Media)

**Status**: Plan, awaiting approval
**Date**: 2026-10-28

## Decision (user, 2026-10-28)

- Every imported media file is copied into the project's `Media/` folder. The
  user is told it happened; they are not asked.
- "Consolidate Media" is removed: the button, the sheet, the alert flow, and the
  relink "Copy to Project Folder?" prompt.
- **Untitled projects**: importing requires a save first. Any import into an
  untitled project raises the Save Project sheet; on save the import continues;
  on cancel nothing is imported.
- **Existing projects**: on open, outside media is copied into `Media/` in the
  background, with a note saying how many files were brought in.

## Why the old path was not enough

`consolidateMedia(projectURL:)` repointed only `ProjectMediaLibrary.items`.
Timeline reels (`VideoReel.sourceURL`) and audio clips (`AudioClip.sourceURL`)
kept the outside paths, so a "consolidated" project still depended on them.
The new copy step repoints all three, the same way
`OptimizationViewModel.updateReferences` does.

## Design

### 1. One copy service (Logic layer)

New `Managers/ProjectMediaCopier.swift`, an `actor` with no SwiftUI import.

- `copyIn(_ url: URL, projectURL: URL) async throws -> URL`:
  - Returns `url` unchanged if `ProjectFolders.contains(url, projectURL:)`.
  - Destination is `ProjectFolders.mediaFolder(forProjectAt:)`, with the same
    `name_1.ext` collision rule as today.
  - Clone when on the same APFS volume (instant, no extra space). Otherwise a
    byte copy with progress and cancellation. API choice per thomas's
    research (below).
  - Checks free space on the destination volume first and throws a named
    error if the file will not fit.
  - Writes to a temporary name in `Media/` and renames once done, so a
    half-copied file is never treated as finished.
- Publishes progress (files done/total, bytes) as an `AsyncStream` so the UI
  can show it without importing the actor's internals.

### 2. Repointing after a copy (one function)

`MediaCopyInCoordinator` (`@MainActor`, Coordinators/) owns the queue. When a
file finishes copying it:
1. `mediaLibrary.updateItemURL(id:newURL:)`
2. `timelineManager.updateVideoReelURL` for every reel whose `sourceURL`
   equals the original
3. `timelineManager.updateAudioClipURL` for every clip (including
   video-track audio) whose `sourceURL` equals the original
4. Marks the document dirty and saves it once the queue drains, so the new
   paths survive a quit.

Import stays instant: the file is placed and plays from the original
straight away and is repointed when its copy finishes. The repoint and
playback reload follow the existing optimize swap.

### 3. Remembering where a file came from

`MediaItem` gains `originalURL: URL?` (optional, decoded with a default so
existing `project.json` files still load). Duplicate detection
(`existingItem(for:)`, `partitionDuplicateMediaURLs`) matches on the current
URL or on `originalURL`. Without this, dropping the same file a second time
would copy it again, because the library now holds the copy's path.

### 4. Hooking into import

- `ProjectMediaLibrary.importFile(from:)` stays as it is (metadata and
  bookmark). Every caller imports through it, so the coordinator enqueues
  the copy right after a successful import. That covers timeline drops,
  playback-area drops, media bay drop and Import button, and held-back files.
- **Untitled gate**: `ContentView` gets
  `requireSavedProject(then:)`. Every external-file entry point
  (`handleVideoDropOnTimeline`, `handleAudioDropOnTimeline`, the mixed drop,
  `handlePlaybackAreaDrop`, `mediaImportCoordinator.handleDrop`,
  FileManagerView Import/drop) goes through it. Internal drags from the
  media bay are not imports and skip the gate.
- **Relink** (`MissingFileResolutionService.locateMissingFile`): drop the
  prompt; a located outside file is copied in through the same coordinator.

### 5. On open

After `openProject` loads, `externalMediaItems(projectURL:)` plus any reel or
clip whose `sourceURL` is outside the project go into the queue. Missing
files are skipped; the existing missing-file flow handles those.

### 6. Telling the user

- One non-modal note in the media bay header while copying:
  "Copying 3 files into the project's Media folder…" with a progress bar,
  then "Copied 3 files into Media" for a few seconds.
- On failure (out of space, unreadable), an alert lists the files left
  outside and why, using the existing `AlertCoordinator`.

### 7. Removal (FEATURES.md "Project Session Folder")

Delete `Views/FileManager/ConsolidateMediaButton.swift` and
`ConsolidationSheetView.swift`. Remove the FileManagerView state for them
(`showConsolidationSheet`, `pendingConsolidationAfterSave`,
`showConsolidateButton`, `startConsolidate`), `ProjectPersistenceService.consolidateMedia()`,
`ProjectMediaLibrary.consolidateMedia` / `ConsolidationResult`, and the
relink copy prompt. Update README, `docs/user-guide/troubleshooting.md`,
`docs/ui-design-system.md`, and FEATURES.md.

## Acceptance criteria

- [ ] Dropping a file from another folder on the same volume: a file appears
      in `<Project>/Media/` immediately; library, reel and clip paths point
      at it; the source file is untouched.
- [ ] Dropping a multi-GB file from an external drive: it plays right away,
      the note shows progress, and paths switch to `Media/` when done.
      Quitting and reopening keeps the new paths.
- [ ] Dropping into an untitled project raises the Save sheet; Save then
      imports into the new `Media/`; Cancel imports nothing.
- [ ] Opening an older project with outside media copies it in and shows
      the count.
- [ ] Dropping the same outside file twice is reported as a duplicate, not
      copied twice.
- [ ] Not enough space: alert names the files; the project still works from
      the originals.
- [ ] No "Consolidate" anywhere in the UI.
- [ ] Optimize still writes to `Optimized Media/`; "move originals aside"
      moves the `Media/` copies to `Raw Files/`.

## Tests

- `ProjectMediaCopier`: same-folder no-op, collision naming, temp-then-rename,
  repoint of item + reel + clip, `originalURL` duplicate detection,
  legacy `project.json` without `originalURL` decodes.
- Test host launches the app (memory: second instance blacks out picture),
  so ask before running.

## Resume

Read this file, then `.claude/SESSION_STATE.md`. Implementation order:
1 → 3 → 2 → 4 → 5 → 6 → 7.

## Research (thomas)

Checked against this Mac's `man copyfile` and the SDK's `copyfile.h`:

- Use `copyfile(src, tmp, state, COPYFILE_ALL | COPYFILE_CLONE)`: it clones on
  the same APFS volume and copies otherwise (man: "best try ... fallback to
  copying"). `COPYFILE_STATE_WAS_CLONED` reports which happened; log it.
  The documentation for `FileManager.copyItem` cloning rests on a single
  search snippet, so it is not relied on here.
- Progress comes from `COPYFILE_STATE_STATUS_CB` with `COPYFILE_COPY_DATA` /
  `COPYFILE_PROGRESS`, reading `COPYFILE_STATE_COPIED`. Callback type:
  `int (*)(int, int, copyfile_state_t, const char *, const char *, void *)`.
  **Open risk**: the man page says the status callback is "currently only
  used for recursive copies". Joseph must verify it fires on a single
  cross-volume file. If it doesn't, the cross-volume path falls back to a
  chunked `FileHandle` copy (read/write in fixed blocks, progress and cancel
  between blocks); the same-volume path still uses `COPYFILE_CLONE`.
- Cancel: return `COPYFILE_QUIT`; the partial file stays, so delete it.
- Free space: `volumeAvailableCapacityForImportantUsageKey`, read on the
  destination volume, and checked only when `.volumeIdentifierKey` differs
  from the source's (a clone costs no space). Add a named-constant margin.
- Atomicity: copy to `.<name>.partial` in `Media/`, then `moveItem` to the
  final name. Sweep stale `.partial` files when a project opens.
- Run `copyfile` on a detached task, not inside actor isolation (the call
  blocks for the whole copy); the cancel flag is lock-protected.
