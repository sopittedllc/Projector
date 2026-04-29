# Pre-Commit Testing Checklist

**Branch**: `feature/cue-sheet-from-audio`
**Date**: 2026-04-27

Run through each test. Mark with ✓ or ✗. Report any failures.

---

## 1. Settings UI (Already Verified)

- [x] Labels left-aligned, consistent spacing
- [x] Channel linking sublabel appears
- [x] Green glow on adjacent channels when selected

---

## 2. Timecode Preservation During Optimization

**Setup**: Need a video file with embedded timecode (e.g., ProRes with TC track)

**Test Steps**:
1. Import a video with embedded timecode into Projector
2. Check the timecode is recognized (shows in timeline position)
3. Right-click the file in Media Library → Optimize
4. Wait for optimization to complete
5. Check the optimized file:
   - [ ] Output is `.mov` (not `.mp4`)
   - [ ] Timecode is preserved (check in QuickTime Player → Window → Show Movie Inspector, or use `ffprobe`)

**Verify TC with ffprobe** (optional):
```bash
ffprobe -show_entries stream=codec_type,codec_tag_string -of compact /path/to/optimized.mov
```
Look for `codec_type=data|codec_tag_string=tmcd` (timecode track)

---

## 3. Cleanup Original Files Dialog

**Test Steps**:
1. Import a video file
2. Optimize it
3. After optimization completes, look for "Cleanup Originals..." button
4. Click it - dialog should appear with 3 options:
   - [ ] "Keep originals where they are" (default)
   - [ ] "Move originals to Raw Files folder"
   - [ ] "Move originals to Trash"
5. Test each option:
   - [ ] Keep: Files stay in place
   - [ ] Raw Files: Creates folder next to .projector, moves originals there
   - [ ] Trash: Moves originals to system Trash

---

## 4. Timeline Auto-Extend on Drag

**Test Steps**:
1. Open a project with clips on the timeline
2. Note the current timeline end position
3. Drag a clip PAST the timeline end
4. [ ] Timeline extends automatically
5. [ ] Clip lands at the dragged position (not clamped)

**Test for both**:
- [ ] Video clips (VideoTrackView)
- [ ] Audio clips (AudioLaneView)

---

## 5. File > Import Batch Handling

**Test Steps**:
1. Prepare 3 video/audio files
2. Go to File > Import Files (or Cmd+I)
3. Select all 3 files
4. [ ] Only ONE dialog appears for batch placement (not 3 separate dialogs)
5. [ ] All files are imported and placed

---

## 6. Command+A in Media Library

**Test Steps**:
1. Import several files into the Media Library
2. Click inside the Media Library panel to focus it
3. Press Command+A
4. [ ] All items in the library are selected
5. Press Command+Shift+A (or Escape)
6. [ ] All items are deselected

---

## 7. Channel Linking UX (Settings)

**Test Steps**:
1. Open Settings panel → Audio Output
2. Read the sublabel under "Channels":
   - [ ] Shows "Click channels to create linked pairs."
3. Click an inactive channel:
   - [ ] Channel highlights yellow (selected)
   - [ ] Adjacent inactive channels glow green
4. Click a glowing green channel:
   - [ ] Stereo pair is created
5. Hover over the stereo pair:
   - [ ] Shows pink glow (unlink affordance)
6. Click to unlink:
   - [ ] Pair separates back to individual channels

---

## Summary

| Test | Pass/Fail | Notes |
|------|-----------|-------|
| Settings UI | | |
| Timecode Preservation | | |
| Cleanup Dialog | | |
| Timeline Auto-Extend | | |
| File > Import Batch | | |
| Command+A | | |
| Channel Linking UX | | |

---

## After Testing

If all tests pass:
```
Let me know "all tests pass" and I'll run Clare + commit
```

If any test fails:
```
Report which test failed and what happened
```
