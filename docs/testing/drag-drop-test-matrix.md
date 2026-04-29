# Drag-Drop Consistency Test Matrix

Comprehensive test matrix for drag-drop behavior verification (Finder vs internal sources).

**Test Date**: ___________
**Tester**: ___________
**Build Version**: ___________

---

## Finder → Timeline Tests

### Video Files

- [ ] **Single video file → Creates video reel**
  - Drag single .mov file from Finder to timeline
  - **Expected**: Creates reel at drop position, correct duration

- [ ] **Multiple video files → Creates multiple reels (sequential)**
  - Drag 3 .mov files from Finder to timeline
  - **Expected**: Creates 3 reels sequentially (no gaps)

- [ ] **Video file to specific frame position**
  - Drag .mov to frame 1000 on timeline
  - **Expected**: Reel inserted at frame 1000

- [ ] **Video file to empty timeline → Inserts at frame 0**
  - Clear timeline
  - Drag .mov to empty timeline
  - **Expected**: Reel inserted at frame 0

- [ ] **Drop zone highlighting - Blue outline**
  - Hover .mov file over timeline
  - **Expected**: Timeline shows blue outline highlight

- [ ] **Invalid drop (non-media file) → Rejected**
  - Drag .txt file to timeline
  - **Expected**: Red X cursor, file rejected, error message

### Audio Files

- [ ] **Single audio file → Creates audio clip on new lane**
  - Drag .wav file from Finder to timeline
  - **Expected**: Creates new audio lane, adds clip to it

- [ ] **Multiple audio files → Creates clips on new lanes**
  - Drag 3 .wav files from Finder to timeline
  - **Expected**: Creates 3 new lanes (or adds to existing lanes)

- [ ] **Audio file to existing lane**
  - Drag .wav to existing audio lane at frame 500
  - **Expected**: Clip inserted at frame 500 on that lane

- [ ] **Audio file to specific frame on timeline**
  - Drag .wav to frame 1000
  - **Expected**: Clip inserted at frame 1000 on new/selected lane

### Mixed Media

- [ ] **Mixed media (video + audio) → Creates reel + clip**
  - Drag .mov + .wav files together to timeline
  - **Expected**: Video reel + audio clip created

- [ ] **Drop on empty timeline → Inserts at frame 0**
  - Clear timeline
  - Drag mixed media
  - **Expected**: Both start at frame 0

- [ ] **Drop on existing content → Inserts after last content**
  - Drag to timeline with existing content
  - **Expected**: Inserts sequentially after last item

---

## Finder → Media Library Tests

### Single Files

- [ ] **Single file → Adds to library (doesn't add to timeline)**
  - Drag .mov to Media Library panel
  - **Expected**: File appears in library grid, NOT on timeline

- [ ] **Multiple files → Adds all to library**
  - Drag 5 .mov files to Media Library
  - **Expected**: All 5 appear in library grid

- [ ] **Folder of files → Recursively adds all media**
  - Drag folder containing 10+ media files
  - **Expected**: All media files imported (recursive scan)

- [ ] **Non-media file → Rejected with error message**
  - Drag .txt file to Media Library
  - **Expected**: Red X cursor, error: "Unsupported file type"

### Drop Zone Consistency

- [ ] **Drop zone highlighting matches timeline style**
  - Hover file over Media Library
  - **Expected**: Same blue outline as timeline drop zone

- [ ] **Drag preview image consistent**
  - Start dragging file
  - Check preview image
  - **Expected**: Thumbnail + filename, same style as internal drags

---

## Media Library → Timeline Tests

### Video Items

- [ ] **Drag existing item to timeline → Creates reel**
  - Drag item from Media Library to timeline
  - **Expected**: Creates reel at drop position

- [ ] **Drag multiple items → Creates multiple reels**
  - Multi-select 3 items in library
  - Drag to timeline
  - **Expected**: Creates 3 reels sequentially

- [ ] **Drag to specific frame → Inserts at frame**
  - Drag item to frame 2000
  - **Expected**: Reel inserted at frame 2000

- [ ] **Re-drag same item → Creates duplicate instance**
  - Drag item to timeline (creates reel 1)
  - Drag same item again to different position
  - **Expected**: Creates reel 2 (separate instance, same source)

### Audio Items

- [ ] **Drag audio item to timeline → Creates clip**
  - Drag audio item from library to timeline
  - **Expected**: Creates clip on new/selected lane

- [ ] **Drag to specific lane**
  - Drag audio item to existing lane
  - **Expected**: Clip added to that lane

---

## Timeline → Timeline Tests (Reorder)

### Video Reels

- [ ] **Drag reel to new position → Reorders**
  - Drag reel from frame 0 to frame 2000
  - **Expected**: Reel moves to frame 2000, no duplicate

- [ ] **Drag reel between other reels**
  - Drag reel 1 between reels 2 and 3
  - **Expected**: Reordered correctly, no gaps/overlaps

- [ ] **Drag to invalid position (overlap) → Snaps to nearest valid**
  - Drag reel to position that would overlap another reel
  - **Expected**: Snaps to nearest non-overlapping position OR rejected

### Audio Clips

- [ ] **Drag clip to different lane → Moves to lane**
  - Drag clip from Lane 1 to Lane 3
  - **Expected**: Clip moves to Lane 3 at same frame position

- [ ] **Drag clip within same lane → Reorders**
  - Drag clip from frame 500 to frame 1500 on same lane
  - **Expected**: Clip repositioned, no duplicate

- [ ] **Drag to invalid position (overlap) → Rejected or snapped**
  - Drag clip to position overlapping existing clip
  - **Expected**: Rejected with error OR snaps to nearest valid

---

## Visual Consistency Tests

### Drop Zone Highlighting

- [ ] **Finder drag - Blue outline + background tint**
  - Drag from Finder
  - **Expected**: Timeline shows blue `RoundedRectangle` stroke + 0.1 opacity fill

- [ ] **Internal drag - Same blue outline + background tint**
  - Drag from Media Library
  - **Expected**: IDENTICAL styling to Finder drag

- [ ] **Invalid drag - Red outline + background tint**
  - Drag unsupported file
  - **Expected**: Red outline + red background tint

### Drag Preview

- [ ] **Finder drag - Thumbnail + filename**
  - Start dragging .mov from Finder
  - **Expected**: Shows video thumbnail + filename

- [ ] **Internal drag - Same thumbnail + filename**
  - Start dragging from Media Library
  - **Expected**: IDENTICAL preview to Finder drag

- [ ] **Consistency - Same fonts, sizes, colors**
  - Compare Finder vs Internal drag previews
  - **Expected**: No visual difference

### Drop Feedback

- [ ] **Successful drop - Brief green flash**
  - Drop file on timeline
  - **Expected**: Timeline briefly flashes green on success

- [ ] **Failed drop - Red flash + error dialog**
  - Drop invalid file
  - **Expected**: Red flash + error alert

- [ ] **Consistency - Same animation for Finder and internal**
  - Test both sources
  - **Expected**: Identical feedback animation

---

## Edge Cases

### Large Files

- [ ] **Drag very large file (>10GB)**
  - Drag 15GB ProRes file to timeline
  - **Expected**: Shows progress indicator, completes without crash

- [ ] **Multiple large files**
  - Drag 5x 10GB files to timeline
  - **Expected**: Progress for each, all complete

### Unsupported Formats

- [ ] **Drag .mp3 file**
  - Drag .mp3 audio to timeline
  - **Expected**: Error: "Unsupported format, use WAV or AIFF"

- [ ] **Drag .mkv video file**
  - Drag .mkv to timeline
  - **Expected**: Error: "Unsupported format, use MOV or MP4"

- [ ] **Drag .txt, .pdf, .zip**
  - Drag non-media files
  - **Expected**: Rejected with clear error message

### Permissions

- [ ] **Drag from read-only location**
  - Mount read-only disk image
  - Drag file from it to timeline
  - **Expected**: Import succeeds (read-only OK for source)

- [ ] **Drag to read-only project**
  - Make project file read-only
  - Attempt to drag file to timeline
  - **Expected**: Error: "Project is read-only"

### Concurrent Operations

- [ ] **Drag while playing**
  - Start playback
  - Drag file to timeline
  - **Expected**: Playback pauses OR continues, drag succeeds

- [ ] **Multiple simultaneous drags**
  - Drag file A to timeline
  - Before it completes, drag file B
  - **Expected**: Queued OR rejected (clear feedback)

---

## Interaction Tests

### Keyboard Modifiers

- [ ] **Hold ⌘ while dragging - Snap to grid**
  - Hold Command key while dragging reel on timeline
  - **Expected**: Reel snaps to frame grid (e.g., every 100 frames)

- [ ] **Hold ⇧ while dragging - Multi-select**
  - Shift-click multiple items in Media Library
  - Drag all to timeline
  - **Expected**: All selected items dragged together

- [ ] **Hold ⌥ while dragging - Duplicate**
  - Hold Option while dragging reel on timeline
  - **Expected**: Creates duplicate reel instead of moving original

### Cancel Drag

- [ ] **Esc to cancel drag**
  - Start dragging file
  - Press Esc
  - **Expected**: Drag cancelled, file not added

- [ ] **Drag outside valid area - Cancel**
  - Drag file away from timeline/library
  - Release mouse
  - **Expected**: Drag cancelled, no changes

---

## Performance Tests

### Responsiveness

- [ ] **Drag 10 files - Completes in <5s**
  - Drag 10 video files from Finder to timeline
  - Time until all reels appear
  - **Expected**: <5 seconds total

- [ ] **Drag during high CPU - No UI freeze**
  - Start heavy background task
  - Drag file to timeline
  - **Expected**: UI responsive, drag completes

---

## Regression Tests (Known Fixed Issues)

- [ ] **Issue #23: Finder drag shows different drop zone color**
  - Drag from Finder vs Media Library
  - **Expected**: Both show identical blue outline

- [ ] **Issue #45: Drag preview image different size**
  - Compare Finder vs Internal drag preview
  - **Expected**: Same thumbnail size (128x128)

- [ ] **Issue #67: Drop feedback animation missing for internal drag**
  - Drag from Media Library to timeline
  - **Expected**: Green flash on success (same as Finder drag)

---

## Test Results Summary

**Total Tests**: _____
**Passed**: _____
**Failed**: _____
**Blocked**: _____

### Visual Inconsistencies Found

| Inconsistency | Finder Behavior | Internal Behavior | Priority |
|--------------|----------------|-------------------|----------|
| ____________ | ______________ | _________________ | ________ |
| ____________ | ______________ | _________________ | ________ |
| ____________ | ______________ | _________________ | ________ |

### Critical Failures (P0 - Must Fix Before Release)

1. _____________________________________________________
2. _____________________________________________________
3. _____________________________________________________

### High-Priority Issues (P1 - Should Fix Before Release)

1. _____________________________________________________
2. _____________________________________________________
3. _____________________________________________________

### Low-Priority Issues (P2 - Can Defer to v1.1)

1. _____________________________________________________
2. _____________________________________________________
3. _____________________________________________________

---

## Notes

_Use this space for additional observations, unexpected behaviors, or suggestions._

_______________________________________________________________
_______________________________________________________________
_______________________________________________________________
_______________________________________________________________
_______________________________________________________________
