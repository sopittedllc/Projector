# Troubleshooting Guide

Common issues and their solutions for Projector.

## Table of Contents

- [Installation & Startup Issues](#installation--startup-issues)
- [File Access Problems](#file-access-problems)
- [Playback Issues](#playback-issues)
- [Audio Problems](#audio-problems)
- [MIDI Sync Issues](#midi-sync-issues)
- [Performance Issues](#performance-issues)
- [UI and Display Problems](#ui-and-display-problems)
- [Project File Issues](#project-file-issues)

---

## Installation & Startup Issues

### "Projector.app can't be opened because it is from an unidentified developer"

**Cause**: macOS Gatekeeper security blocking unsigned apps

**Solution**:
1. Right-click on **Projector.app** in Finder
2. Select **Open**
3. Click **Open** in the security dialog
4. This only needs to be done once

**Alternative**:
1. System Settings → Privacy & Security
2. Scroll to "Allow applications downloaded from"
3. Click **Open Anyway** next to Projector

---

### Projector Crashes on Launch

**Symptoms**:
- App opens then immediately quits
- "Projector quit unexpectedly" dialog

**Solutions**:

**1. Check macOS Version**:
- Projector requires macOS 14.0 (Sonoma) or later
- Check: Apple menu → About This Mac
- Update if needed: System Settings → General → Software Update

**2. Reset Preferences**:
```bash
# Close Projector first
rm ~/Library/Preferences/com.keegandewitt.Projector.plist
rm -rf ~/Library/Application\ Support/Projector
```

**3. Check Console for Errors**:
1. Open **Console.app** (Applications → Utilities)
2. Search for "Projector"
3. Look for crash logs or error messages
4. Report errors to GitHub Issues

---

### Permission Dialogs Keep Appearing

**Symptom**: Projector repeatedly asks for file access permissions

**Solution**:
1. Open **System Settings** → **Privacy & Security** → **Files and Folders**
2. Find **Projector** in the list
3. Enable all checkboxes (Documents, Downloads, Desktop, Removable Volumes)
4. Restart Projector

---

## File Access Problems

### "File Not Found" Error When Opening Project

**Cause**: Security-scoped bookmarks expired or file moved

**Solution**:

**Option 1: Locate Missing Files**:
1. Projector will show "Missing Files" alert on project open
2. Click **Locate** for each missing file
3. Navigate to the new file location
4. Projector updates the bookmark

**Option 2: Manual Relocation**:
1. File → Locate Missing Files
2. Select the first missing file in the list
3. Click **Choose File** and navigate to its location
4. Repeat for remaining files

**Option 3: Consolidate Media**:
1. File → Consolidate Media
2. Copies all media into the project package
3. Eliminates bookmark issues

---

### Cannot Import Files from External Drive

**Symptom**: Drag-drop from external drive fails, or "Permission Denied" error

**Solutions**:

**1. Grant Access to Removable Volumes**:
1. System Settings → Privacy & Security → Files and Folders
2. Enable **Removable Volumes** for Projector
3. Restart Projector

**2. Copy Files to Mac First**:
1. Copy video files to ~/Movies or ~/Documents
2. Import from local drive
3. This avoids sandbox restrictions

**3. Use Consolidate Media**:
1. After importing, use File → Consolidate Media
2. Copies files into project package
3. Project becomes self-contained

---

### Waveforms Not Displaying

**Symptom**: Audio clips show blank waveforms

**Solutions**:

**1. Wait for Generation**:
- Waveforms generate asynchronously
- Large files (>1 GB) may take 10-30 seconds
- Progress indicator shows in top-right

**2. Check Console for Errors**:
```bash
log stream --predicate 'process == "Projector"' | grep -i waveform
```
- Look for errors like "Failed to generate waveform"
- Report errors to GitHub Issues

**3. Re-import Audio**:
1. Remove clip from timeline
2. Remove file from Media Library
3. Re-import the file
4. Drag back to timeline

---

## Playback Issues

### Video Playback Stutters or Lags

**Symptoms**:
- Video drops frames during playback
- Stuttering or choppy motion

**Solutions**:

**1. Check CPU Usage**:
1. Open **Activity Monitor** (Applications → Utilities)
2. Look for high CPU usage (>80%)
3. Close background applications

**2. Use Optimized Media**:
1. File → Optimize Media
2. Select **Good** or **Better** quality
3. Projector creates ProRes proxy files
4. Playback will use optimized versions

**3. Check Disk Speed**:
- **SSD Required**: 4K video requires SSD storage
- **HDD**: Use lower resolution or optimize media

**4. Reduce Timeline Zoom**:
- Zooming in requires more thumbnail/waveform rendering
- Zoom out for smoother playback

---

### Reel Transitions Have Gaps

**Symptom**: Black frame or pause between video reels

**Causes**:
- Reels positioned with gap on timeline
- Preloading failed due to file error

**Solutions**:

**1. Check Timeline Positioning**:
1. Zoom in on the transition point
2. Verify reels are adjacent (no gap in frames)
3. Drag reel to close any gaps

**2. Enable Preloading**:
- Preloading happens automatically within 5 seconds of transition
- Check console for preload errors

**3. Optimize Source Files**:
- Some codecs (H.264, H.265) seek slowly
- Use File → Optimize Media for ProRes

---

### Playback Position Drifts from Timeline

**Symptom**: Playhead position doesn't match video content

**Cause**: Frame rate mismatch or timecode interpretation

**Solutions**:

**1. Check Project Frame Rate**:
1. Settings → Timeline → Frame Rate
2. Verify it matches your video files
3. Common mismatch: 29.97 fps vs 30 fps

**2. Check Timecode Interpretation**:
- Some files have embedded timecode that differs from metadata
- Use File → Detect Embedded Timecode to verify

---

## Audio Problems

### No Audio During Playback

**Symptoms**:
- Video plays but no sound
- VU meters show no activity

**Solutions**:

**1. Check Output Device**:
1. Settings → Audio → Output Device
2. Verify correct device selected
3. Try **Built-in Output** to test

**2. Check Lane Volume/Mute**:
1. Look at timeline audio lanes
2. Verify lanes are not muted (🔇 icon)
3. Check volume slider is >0%

**3. Check Solo State**:
- If any lane is soloed, other lanes are muted
- Un-solo all lanes to hear all audio

**4. Check System Volume**:
1. macOS System Settings → Sound
2. Verify Output volume is not at 0
3. Check Mute checkbox is not enabled

---

### Audio Clicks, Pops, or Crackling

**Symptoms**:
- Intermittent pops during playback
- Crackles on audio start/stop

**Solutions**:

**1. Increase Buffer Size**:
1. Settings → Audio → Buffer Size
2. Increase to 1024 or 2048 samples
3. Higher buffers = more latency but fewer dropouts

**2. Close Background Apps**:
- Audio processing is CPU-intensive
- Close web browsers, video calls, etc.

**3. Check Sample Rate**:
1. Open **Audio MIDI Setup** (Applications → Utilities)
2. Select your audio interface
3. Ensure Format is 44.1 kHz or 48 kHz (not 96 kHz)
4. Restart Projector

**4. Update Interface Drivers**:
- Some interfaces require manufacturer drivers
- Check your interface manufacturer's website

---

### Audio Routing to Wrong Channels

**Symptom**: Sound comes out of unexpected speakers

**Solutions**:

**1. Verify Output Mapping**:
1. Settings → Audio → Output Mapping
2. Check each lane's output assignment
3. Example: Lane 1 → Outputs 1-2 (not 3-4)

**2. Check Device Channel Count**:
1. Verify your interface has the channels you're routing to
2. Example: 4-channel interface can't route to outputs 5-6

**3. Test with Stereo**:
1. Set all lanes to **Outputs 1-2**
2. If that works, the issue is routing configuration

---

## MIDI Sync Issues

### "Not Receiving MTC"

**Symptom**: Sync indicator shows red "No MTC"

**Solutions**:

**1. Check Physical Connections**:
- MIDI OUT (source) → MIDI IN (interface)
- Verify MIDI cable is securely connected

**2. Verify Source is Transmitting**:
- Pro Tools: Setup → Peripherals → Synchronization → MTC Generate
- Logic: Preferences → Synchronization → Enable MIDI Time Code
- Check DAW is playing (not paused)

**3. Select Correct MIDI Input**:
1. Settings → MIDI → MIDI Input
2. Choose your MIDI interface
3. Click **Refresh** if device doesn't appear

**4. Use MIDI Monitor**:
1. Open **Audio MIDI Setup** (Applications → Utilities)
2. Window → Show MIDI Studio
3. Double-click your MIDI interface
4. Check "Test MIDI" tab for incoming messages

---

### "Frame Rate Mismatch"

**Symptom**: Sync status shows "Frame Rate Mismatch"

**Solution**:
1. Check your MTC source's frame rate (DAW project settings)
2. Settings → MIDI → Local Frame Rate
3. Set to exact same rate as source
4. Common rates:
   - **23.976 fps**: Film pulldown
   - **24 fps**: Film
   - **25 fps**: PAL
   - **29.97 fps**: NTSC drop-frame
   - **30 fps**: NTSC non-drop

**Note**: Frame rates must match EXACTLY. 29.97 ≠ 30 fps.

---

### MTC Sync Drifts Over Time

**Symptom**: Drift indicator shows increasing offset (>2 frames)

**Solutions**:

**1. Check Frame Rate**:
- Even slight frame rate mismatch causes cumulative drift
- Double-check Settings → MIDI → Local Frame Rate

**2. Reduce Drift Threshold**:
1. Settings → MIDI → Advanced → Drift Threshold
2. Lower to 0.1 frames (more aggressive correction)

**3. Check Audio Buffer**:
- Large audio buffers cause latency
- Settings → Audio → Buffer Size → Try 512 samples

**4. Hardware Clock Drift**:
- Some MIDI interfaces have slight clock drift
- Solution: Restart devices to reset clocks
- Or: Use word clock sync if available

---

## Performance Issues

### High CPU Usage

**Symptom**: Activity Monitor shows Projector using >80% CPU

**Causes**:
- Many audio lanes
- High-resolution video (4K+)
- Waveform generation

**Solutions**:

**1. Optimize Media**:
- File → Optimize Media
- Creates ProRes proxies (lower CPU)

**2. Reduce Timeline Zoom**:
- Zoomed-in views require more rendering
- Zoom out when not editing

**3. Close Unused Lanes**:
- Remove empty audio lanes
- Fewer lanes = less processing

**4. Limit Waveform Resolution**:
- Waveforms render at multiple resolutions
- This is automatic, but zooming out helps

---

### Slow UI Response

**Symptom**: UI feels sluggish, buttons slow to respond

**Solutions**:

**1. Reduce Timeline Complexity**:
- Fewer reels/clips = faster UI
- Split large projects into scenes

**2. Clear Waveform Cache**:
```bash
rm -rf ~/Library/Caches/com.keegandewitt.Projector/Waveforms
```
- Restart Projector
- Waveforms will regenerate

**3. Restart Projector**:
- Long sessions can accumulate memory
- Quit and relaunch periodically

---

## UI and Display Problems

### Document Icon Not Showing

**Symptom**: .projector files show generic document icon in Finder

**Solution**:
1. Log out and log back in (or restart Mac)
2. This refreshes Launch Services cache
3. Known macOS issue with new document types

**Alternative**:
```bash
# Force Launch Services to update
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user
```

---

### Waveforms or Thumbnails Not Updating

**Symptom**: UI shows old waveform/thumbnail after editing

**Solution**:
1. Seek playhead to different position
2. Wait 2-3 seconds for regeneration
3. Zoom in/out to force redraw

---

### Settings Window Won't Open

**Symptom**: Clicking Settings does nothing

**Solution**:
1. Check if Settings window is open on another Space (⌃ + arrow keys)
2. Window → Bring All to Front
3. If still missing, quit and restart Projector

---

## Project File Issues

### "Project File Corrupted"

**Symptom**: Cannot open .projector file, error message

**Solutions**:

**1. Check File Size**:
```bash
ls -lh ~/path/to/project.projector
```
- If file is 0 bytes, it's corrupted (likely incomplete save)
- Restore from backup (Time Machine)

**2. Validate Package Structure**:
```bash
cd ~/path/to/project.projector
ls -la
```
- Should contain: `project.json`, `Media/`, `Bookmarks/`
- If missing, project is incomplete

**3. Restore from Auto-Save**:
1. Right-click .projector file
2. Show Package Contents
3. Look for `AutoSave/` folder
4. Copy most recent backup

---

### Changes Not Saving

**Symptom**: Edits are lost when reopening project

**Solutions**:

**1. Verify Save Completes**:
- Watch for save progress indicator (top-right)
- Wait for "Saved" confirmation

**2. Check Disk Space**:
```bash
df -h ~
```
- Ensure enough free space (>1 GB recommended)

**3. Check Permissions**:
```bash
ls -la ~/path/to/project.projector
```
- Verify you have write permissions
- If not: `chmod u+w project.projector`

---

## Getting More Help

### Console Logs

To capture diagnostic logs:

```bash
# Open Terminal
log stream --predicate 'process == "Projector"' > ~/Desktop/projector.log

# In another Terminal window, reproduce the issue
# Then stop the first Terminal with Ctrl+C
```

Include the log file when reporting issues.

---

### Reporting Bugs

If you encounter an issue not covered here:

1. **GitHub Issues**: https://github.com/musiquela/Projector/issues
2. **Include**:
   - macOS version
   - Projector version (Projector → About Projector)
   - Steps to reproduce
   - Console logs (if applicable)
   - Screenshots (if UI-related)

---

### Reset Projector Completely

If all else fails:

```bash
# Close Projector first

# Remove preferences
rm ~/Library/Preferences/com.keegandewitt.Projector.plist

# Remove caches
rm -rf ~/Library/Caches/com.keegandewitt.Projector

# Remove application support
rm -rf ~/Library/Application\ Support/Projector

# Restart Projector (will be like first launch)
```

**Warning**: This deletes all settings and caches. Projects are NOT affected.

---

[← Keyboard Shortcuts](keyboard-shortcuts.md) | [Back to User Guide](README.md)
