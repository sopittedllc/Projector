# Playback Test Matrix

Comprehensive test matrix for systematic playback verification before v1.0 release.

**Test Date**: ___________
**Tester**: ___________
**Build Version**: ___________

---

## Video Playback Scenarios

### Basic Playback

- [ ] **Single reel playback (start → end)**
  - Load single video file
  - Press play
  - Let play to end naturally
  - **Expected**: Smooth playback, no stutters, reaches end frame

- [ ] **Multi-reel seamless transition (reel 1 → reel 2)**
  - Load 2 adjacent reels (e.g., 0-1000, 1000-2000)
  - Play through transition point (frame 1000)
  - **Expected**: No black frame, no pause, seamless transition

- [ ] **Gap playback (timer-based frame advancement)**
  - Create timeline with gap (e.g., reel at 0-1000, reel at 1500-2500)
  - Play from frame 900
  - **Expected**: Reaches gap at 1000, advances frames via timer, resumes video at 1500

- [ ] **Frame-accurate seeking (random frame positions)**
  - Seek to frame 0, 100, 500, 999, 1000, 5000
  - Verify timecode display matches frame
  - **Expected**: Seeks complete instantly, correct frame displayed

- [ ] **Seek during playback (no stutter)**
  - Start playback
  - Seek to frame 500 while playing
  - **Expected**: Playback continues smoothly after seek, no pause

- [ ] **Seek to reel boundary (0, last frame)**
  - Seek to frame 0
  - Seek to last frame of timeline (e.g., 10000)
  - **Expected**: Both seeks work correctly, no crash

- [ ] **Preloading verification (5-second lookahead)**
  - Play near reel boundary (4950 → 5000)
  - Check console logs for preload messages
  - **Expected**: Next reel preloads ~5 seconds before transition

---

## Video Edge Cases

### File Handling

- [ ] **Empty timeline (no reels)**
  - Clear timeline completely
  - Press play
  - **Expected**: Error alert "No reels to play" or play button disabled

- [ ] **Single-frame video clip**
  - Import 1-frame video
  - Play
  - **Expected**: Displays single frame, playback pauses immediately

- [ ] **Very long video (>2 hours)**
  - Import 2+ hour video file
  - Play, seek to end, seek to middle
  - **Expected**: No memory issues, seeks work, playback smooth

- [ ] **Mixed frame rates (24fps + 30fps reels)**
  - Import 24fps video (reel 1)
  - Import 30fps video (reel 2)
  - Place adjacent on timeline
  - **Expected**: Warning dialog or automatic conversion, or plays both correctly

- [ ] **Missing video file (broken bookmark)**
  - Import video
  - Save project
  - Move video file to different location
  - Reopen project
  - **Expected**: "Missing Files" alert, option to relocate

- [ ] **Corrupt video file**
  - Import deliberately corrupt .mov file
  - **Expected**: Import fails with clear error, no crash

- [ ] **Video with no audio track**
  - Import video without audio
  - Play
  - **Expected**: Video plays, no audio errors

- [ ] **Video with multiple audio tracks**
  - Import video with 3+ audio tracks
  - Play
  - **Expected**: Plays default track (track 0) or prompts for selection

---

## Audio Playback Scenarios

### Basic Audio

- [ ] **Single audio clip playback**
  - Add audio clip to lane
  - Play
  - **Expected**: Audio plays from correct output channels

- [ ] **Multiple simultaneous clips (10+ lanes)**
  - Create 10 audio lanes
  - Add clips to all lanes (same start time)
  - Play
  - **Expected**: All lanes play simultaneously, no dropouts

- [ ] **Audio sync with video (no drift)**
  - Import video with audio
  - Extract audio to lane
  - Play video + extracted audio
  - **Expected**: Perfect sync, no drift over time

- [ ] **Extracted audio playback (cached)**
  - Import video
  - Extract audio (cached to project)
  - Delete original video file
  - Play extracted audio
  - **Expected**: Cached audio plays correctly

- [ ] **Audio clip at exact reel boundary**
  - Add audio clip starting at frame 1000 (reel boundary)
  - Play through boundary
  - **Expected**: Audio starts precisely at frame 1000

- [ ] **Audio-only project (no video)**
  - Create project with only audio lanes (no video reels)
  - Play
  - **Expected**: Playhead advances, audio plays, timecode updates

---

## Audio Edge Cases

### File Handling

- [ ] **Missing audio file**
  - Import audio
  - Save project
  - Move audio file
  - Reopen project
  - **Expected**: "Missing Files" alert, option to relocate

- [ ] **Corrupt audio file**
  - Import deliberately corrupt .wav file
  - **Expected**: Import fails with clear error, no crash

- [ ] **Unsupported format**
  - Attempt to import .mp3, .flac, .ogg
  - **Expected**: Clear error "Unsupported format, use WAV or AIFF"

- [ ] **Very short clip (<100ms)**
  - Import 50ms audio clip
  - Play
  - **Expected**: Plays correctly, no audio pops

- [ ] **Mono, stereo, 5.1 formats**
  - Import mono WAV
  - Import stereo WAV
  - Import 5.1 surround WAV
  - Play all
  - **Expected**: All play correctly, correct channel routing

- [ ] **Sample rate mismatch (44.1kHz + 48kHz)**
  - Import 44.1kHz audio
  - Import 48kHz audio
  - Play both
  - **Expected**: Both play correctly (automatic resampling or warning)

---

## Transport Control Scenarios

### Commands

- [ ] **Play → Pause → Play (resume)**
  - Play from frame 0
  - Pause at frame 500
  - Play again
  - **Expected**: Resumes from frame 500, not frame 0

- [ ] **Play → Stop → Play (restart from 0)**
  - Play from frame 0
  - Stop at frame 500
  - Play again
  - **Expected**: Restarts from frame 0

- [ ] **Seek while paused**
  - Pause at frame 500
  - Seek to frame 1000
  - **Expected**: Seeks immediately, stays paused

- [ ] **Seek while playing (coalesced)**
  - Start playing
  - Rapidly drag timeline scrubber left/right
  - **Expected**: Seeks coalesce (not every frame), playback smooth

- [ ] **Rapid seek operations (stress test)**
  - Click timeline randomly 20+ times rapidly
  - **Expected**: No crash, seeks coalesce, final seek applied

- [ ] **Seek to end → play (wraps to start)**
  - Seek to last frame
  - Press play
  - **Expected**: Playback stops or wraps to frame 0 (configurable)

---

## Synchronization Scenarios

### MTC/MMC

- [ ] **MTC play command → playback starts**
  - Connect MIDI device
  - Send MTC play from DAW
  - **Expected**: Projector starts playing automatically

- [ ] **MTC stop command → playback pauses**
  - Playing via MTC
  - Send MTC stop from DAW
  - **Expected**: Projector pauses

- [ ] **MTC locate → seeks to frame**
  - Send MTC locate to 01:00:00:00
  - **Expected**: Projector seeks to frame 1440 (at 24fps)

- [ ] **MTC drift compensation (<0.2s threshold)**
  - Play synchronized with MTC
  - Let run for 5 minutes
  - Check drift indicator
  - **Expected**: Drift stays <0.5 frames (green)

- [ ] **MTC frame rate mismatch detection**
  - Set Projector to 24fps
  - Send MTC at 30fps
  - **Expected**: "Frame Rate Mismatch" warning, drift indicator red

---

## Performance Verification

### CPU Usage

- [ ] **Single 1080p reel playback: <10% CPU**
  - Play 1080p video
  - Check Activity Monitor
  - **Expected**: CPU <10% (varies by Mac model)

- [ ] **Multi-reel playback: <20% CPU**
  - Play project with 5 reels
  - Check Activity Monitor
  - **Expected**: CPU <20%

- [ ] **10-lane audio playback: <15% CPU**
  - Play 10 audio lanes simultaneously
  - Check Activity Monitor
  - **Expected**: CPU <15%

### Frame Drops

- [ ] **1080p 24fps: Zero dropped frames**
  - Play 1080p H.264 video for 1 minute
  - Check console for dropped frame warnings
  - **Expected**: No dropped frames

- [ ] **4K 24fps: Zero dropped frames (SSD)**
  - Play 4K ProRes video from SSD
  - **Expected**: No dropped frames

- [ ] **4K 24fps: Acceptable drops (HDD)**
  - Play 4K ProRes video from HDD
  - **Expected**: May drop frames, clear warning to user

---

## Error Handling

### Graceful Failures

- [ ] **Load reel from read-only volume**
  - Mount read-only disk image
  - Import video from it
  - **Expected**: Imports successfully (read-only OK)

- [ ] **Run out of disk space during playback**
  - Fill disk to <100MB free
  - Play video
  - **Expected**: Playback works (no writes during playback)

- [ ] **Disconnect external drive during playback**
  - Play video from external drive
  - Unplug drive mid-playback
  - **Expected**: Error alert, playback stops gracefully

- [ ] **System sleep during playback**
  - Start playback
  - Put Mac to sleep (⌘ ⌥ Eject)
  - Wake Mac
  - **Expected**: Playback paused, can resume

---

## Regression Tests (Known Fixed Issues)

- [ ] **Issue #42: Gap transitions cause black frame**
  - Create timeline with gap
  - Play through gap
  - **Expected**: No black frame at gap start

- [ ] **Issue #57: Seeking while loading causes crash**
  - Load very large reel (loading takes 5s)
  - Seek immediately during load
  - **Expected**: No crash, seek queued until load completes

- [ ] **Issue #81: MTC drift accumulates over time**
  - Sync with MTC
  - Play for 30 minutes
  - Check drift
  - **Expected**: Drift stays <1.0 frames (compensated)

---

## Test Results Summary

**Total Tests**: _____
**Passed**: _____
**Failed**: _____
**Blocked**: _____

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
