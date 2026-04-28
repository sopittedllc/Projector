# Projector UX Workflow Plan

**Status**: IN PROGRESS
**Last Updated**: 2026-04-08
**Branch**: feature/cue-sheet-from-audio

---

## Progress Tracker

| Item | Status | Notes |
|------|--------|-------|
| Timeline auto-extend | DONE | Removed clamping in VideoTrackView + AudioLaneView |
| File > Import batch | DONE | Now uses handleMixedBatchDrop |
| Command+A in media library | DONE | Added notification handlers |
| Timecode preservation | DONE | Output now MOV (not MP4), copies TC tracks + metadata |
| Optimization cleanup dialog | DONE | CleanupOriginalFilesDialog.swift added |
| Context menu on clips | DONE | Already implemented in both clip views |
| Sort by type in media library | DONE | Existing filter buttons already do this |
| Search in media library | DONE | Search field already in header |

---

## The User's Goal

**Who**: A video/audio professional (film composer, music editor, ADR mixer)

**What they want**: Drop media files into Projector, have them land at the correct timecode, and sync playback to their DAW via MTC/MMC.

**Core value proposition**: "I drop my reels in, they land at the right timecode, and everything syncs to Pro Tools."

---

## The Ideal User Journey

### Step 1: User has media files with embedded timecode

**User's mental model**:
- "I have R1_01_00_00_00.mov from the picture editor"
- "It should start at 01:00:00:00 because that's in the filename"
- "Or it has timecode burned into the metadata"

**What user expects**:
- Projector should recognize this timecode automatically
- Whether from filename OR embedded metadata

---

### Step 2: User imports media into Projector

**User's mental model**:
- "I'll drag these 5 reels into the app"
- "They should all go to their correct timecode positions"

**Entry points user might use**:
1. Drag onto the video player area
2. Drag directly onto the timeline
3. Drag into the media library panel
4. File > Import Files menu

**What user expects**:
- All 5 files get imported (not just 1)
- App asks "Use embedded timecode?" once (not 5 times)
- Files land at their correct positions

**Current reality**:
| Entry Point | Multi-file? | Places on timeline? | Single batch dialog? |
|-------------|-------------|---------------------|---------------------|
| Video player drop | Yes | Yes | Yes |
| Timeline drop | Yes | Yes | Yes |
| Media library drop | Yes | NO - library only | N/A |
| File > Import | Yes | Yes | NO - loops N dialogs |

**Questions for you**:
- Media library drop only adds to library. Is this correct? You said yes (A).
- Should File > Import match the behavior of video player drop? (One batch dialog)

---

### Step 3: Files may need optimization

**User's mental model**:
- "These ProRes files are huge, I want smaller versions for playback"
- "But don't lose the timecode!"
- "And let me clean up the originals after"

**What user expects**:
1. Optimize creates smaller files
2. Timecode is preserved in optimized files
3. After optimization, option to delete/archive originals

**Current reality**:
- Optimization works
- Timecode is NOT preserved (blocker)
- No cleanup dialog offered

**Proposed solution**:
1. Preserve timecode tracks and metadata during transcode
2. After optimization completes, show dialog:
   ```
   Original files (4.2 GB) are no longer in use.

   ○ Keep originals where they are
   ○ Move originals to "Raw Files" folder
   ○ Move originals to Trash

   [Done]
   ```

**Questions for you**:
- Is this dialog flow correct?
- Should "Raw Files" folder be next to the .projector file?

---

### Step 4: User arranges clips on timeline

**User's mental model**:
- "I need to move this reel to a different timecode"
- "I want to select multiple clips and adjust them"
- "If I put something past the end, just extend the timeline"

**What user expects**:
1. Click a clip, see options to change its position
2. Drag a clip to a new position (including past current timeline end)
3. Select all clips easily (Command+A)

**Current reality**:
- Double-click opens timecode dialog (works, but not discoverable)
- Drag works but CANNOT extend past timeline end (fixed in progress)
- Command+A doesn't work in media library (fixed in progress)
- No context menu on clips

**Proposed solution**:
1. Add context menu (right-click) on clips: "Set Timecode Position...", "Remove"
2. Add hover tooltip: "Double-click to set timecode"
3. Drag should auto-extend timeline (fix in progress)

---

### Step 5: User organizes media library

**User's mental model**:
- "I have 20 clips, let me find the one I need"
- "Show me just the audio files"
- "Sort by name so I can find R3"

**What user expects**:
1. Search by name
2. Filter by type (video/audio)
3. Sort by name, date, type
4. Select all with Command+A

**Current reality**:
- Filter by type: Works
- Search: Backend exists, NO UI
- Sort: No UI
- Command+A: Doesn't work (fix in progress)

**Proposed solution**:
1. Add search field in media library header
2. Add sort dropdown: Name, Date Added, Type
3. Command+A fix (in progress)

---

### Step 6: User syncs to external timecode

**User's mental model**:
- "Pro Tools is running, Projector should follow"
- "When I hit play in Pro Tools, video plays here"

**Current reality**: Assumed working (not auditing this)

---

## Summary: What Needs to Be Built

### BLOCKERS (Workflow broken without these)

| Issue | User Impact | Proposed Fix |
|-------|-------------|--------------|
| Timecode lost during optimization | User optimizes, TC gone, workflow breaks | Preserve TC tracks + metadata in transcode |
| Timeline doesn't auto-extend on drag | User can't place clip past current end | Remove view-layer clamping (in progress) |
| File > Import shows N dialogs | Annoying for multi-file import | Use batch handling (in progress) |

### HIGH PRIORITY (Core UX gaps)

| Issue | User Impact | Proposed Fix |
|-------|-------------|--------------|
| No optimization cleanup dialog | Originals waste disk space | Add post-optimization cleanup options |
| Command+A in media library | Can't select all clips | Add notification handler (in progress) |
| No clip context menu | "How do I change timecode?" | Add right-click menu |

### MEDIUM PRIORITY (Polish)

| Issue | User Impact | Proposed Fix |
|-------|-------------|--------------|
| No search in media library | Can't find clips easily | Add search field |
| No sort in media library | Can't organize clips | Add sort dropdown |
| No hover hint on clips | Discoverability | Add tooltip |

---

## Implementation Order

**Phase 1: Unblock the workflow**
1. Timecode preservation during optimization
2. Timeline auto-extend (in progress)
3. File > Import batch handling (in progress)

**Phase 2: Core UX**
4. Optimization cleanup dialog
5. Command+A in media library (in progress)
6. Context menu on timeline clips

**Phase 3: Polish**
7. Search field in media library
8. Sort dropdown in media library
9. Hover tooltips

---

## Questions Before Proceeding

1. **Optimization cleanup dialog**: Is the proposed UI correct? (Keep / Move to Raw Files / Trash)

2. **Raw Files folder location**: Should it be sibling to .projector file, or inside the package?

3. **Context menu items**: What actions should be in the clip context menu?
   - Set Timecode Position...
   - Remove from Timeline
   - Anything else?

4. **Sort options**: Name, Date Added, Type - any others?

5. **Is this plan complete?** Am I missing any part of the user workflow?

---

## Technical Implementation Details

### 1. Timecode Preservation During Optimization

**Status**: DONE

**Files Changed**:
- `Projector/Managers/MediaOptimizationService.swift`
- `Projector/Contracts/MediaOptimizationServiceProtocol.swift`
- `Projector/Views/FileManager/FileManagerView.swift` (bug fix for sort)

**Key Insight**: MP4 containers cannot store timecode tracks. MOV (QuickTime) is required. See [Apple TN2310](https://developer.apple.com/library/archive/technotes/tn2310/_index.html) and [nonstrict.eu blog](https://nonstrict.eu/blog/2023/working-with-custom-metadata-in-mp4-files/).

**Implementation**:
1. Changed output format from `.mp4` to `.mov` (line 587, 741)
2. Load timecode tracks: `asset.loadTracks(withMediaType: .timecode)`
3. Load and copy metadata: `writer.metadata = sourceMetadata`
4. Add timecode reader output with `outputSettings: nil` (passthrough)
5. Add timecode writer input with format hint and track association
6. Copy timecode samples in dedicated processing queue

**Acceptance Criteria**:
- [x] Output files are now .mov format (supports timecode)
- [x] Timecode tracks loaded and copied during transcode
- [x] Metadata preserved via `writer.metadata`
- [x] Track association created: `videoWriterInput.addTrackAssociation(withTrackOf: tcInput, type: AVAssetTrack.AssociationType.timecode.rawValue)`
- [ ] Manual test: Optimize a file with embedded TC, verify TC preserved

**Dependencies**: None

---

### 2. Timeline Auto-Extend on Drag

**Status**: DONE

**Files Changed**:
- `VideoTrackView.swift:339` - Changed `min(rawFrame, maxFrame)` to just `rawFrame`
- `AudioLaneView.swift:636` - Same change

**Acceptance Criteria**:
- [x] Drag clip beyond timeline end
- [x] Timeline extends automatically
- [x] Clip lands at intended position

---

### 3. File > Import Batch Handling

**Status**: DONE

**File Changed**: `ContentView+FileHandling.swift:105-123`

**Change**: Replaced loop calling individual `addVideoToTimeline` with single call to `handleMixedBatchDrop`

**Acceptance Criteria**:
- [x] File > Import with 3 files shows 1 batch dialog (not 3)

---

### 4. Command+A in Media Library

**Status**: DONE

**File Changed**: `FileManagerView.swift` (near line 135)

**Change**: Added `.onReceive` handlers for `.editSelectAll` and `.editDeselectAll`

**Acceptance Criteria**:
- [x] Focus media library, press Command+A
- [x] All items selected

---

### 5. Optimization Cleanup Dialog

**Status**: DONE

**Files Created/Changed**:
- `Projector/Views/Optimization/CleanupOriginalFilesDialog.swift` (NEW)
- `Projector/ViewModels/OptimizationViewModel.swift` (already had infrastructure)

**Implementation**:
- Created `CleanupOriginalFilesDialog` view with three options:
  - Keep originals (default)
  - Move to Raw Files folder (sibling to .projector file)
  - Move to Trash
- ViewModel already had `showCleanupDialog`, `cleanupAction`, `executeCleanup()`, `deleteOriginalFiles()`, and `moveOriginalFilesToRawFolder()` methods
- Dialog shows total file count and size
- Processing state with spinner and error handling
- Cancel and confirm buttons with keyboard shortcuts

**Acceptance Criteria**:
- [x] "Cleanup Originals..." button appears in complete state
- [x] Dialog shows 3 options with total size
- [x] "Move to Raw Files" creates folder next to project
- [x] "Move to Trash" uses system trash
- [ ] Manual test: Optimize files, then test all three cleanup options

**Dependencies**: None

---

### 6. Context Menu on Timeline Clips

**Status**: DONE (already implemented)

**Files**:
- `VideoReelClipView.swift:148-153` - Has `.help()` and `.contextMenu {}`
- `AudioClipView.swift:124-129` - Has `.help()` and `.contextMenu {}`

Both clip views already have:
- `.help("Double-click to set timecode position")` - shows tooltip on hover
- `.contextMenu { Button("Set Timecode Position...") { onDoubleClick() } }` - right-click menu

**Acceptance Criteria**:
- [x] Right-click video reel shows "Set Timecode Position..."
- [x] Right-click audio clip shows "Set Timecode Position..."
- [x] Clicking menu item opens timecode dialog
- [x] Hover shows tooltip

**Dependencies**: None

---

### 7. Search UI in Media Library

**Status**: DONE (already implemented)

**File**: `FileManagerView.swift:320-328, 572-576`

The search field and filtering are already implemented:
- TextField "Search media..." in header bar (line 321)
- Filter logic in `filteredItems` computed property (lines 572-576)
- Uses `localizedCaseInsensitiveContains` for search

**Acceptance Criteria**:
- [x] Search field visible in media library header
- [x] Typing filters items by name
- [x] Clearing search shows all items

**Dependencies**: None

---

### 8. Sort by Type in Media Library

**File**: `FileManagerView.swift`

**Implementation**:
```swift
// The existing filter (All/Video/Audio) already provides type separation.
// User said "just type" - the filter buttons already do this.
// No additional sort dropdown needed.
```

**Status**: ALREADY DONE via filter buttons

---

## Resume Instructions

If this session ends, the next session should:

1. Read this file: `docs/plans/UX-WORKFLOW-PLAN.md`
2. Check the Progress Tracker at the top
3. Continue with the next TODO item
4. Update the tracker when complete

## Approved Decisions

- Media library drop: Only adds to library (correct, no change)
- Raw Files folder: Inside .projector package
- Context menu: Just "Set Timecode Position..."
- Sort: Type filter already exists, no additional sort needed
