# Getting Started with Projector

This guide will walk you through installing Projector and creating your first playback project.

## Installation

### Download and Install

1. Download the latest Projector DMG from the releases page
2. Open the DMG file
3. Drag **Projector.app** to your **Applications** folder
4. Eject the DMG

### First Launch

1. Open **Projector.app** from Applications
2. macOS may show a security prompt: "Projector.app can't be opened because it is from an unidentified developer"
   - Right-click on Projector.app and select **Open**
   - Click **Open** in the security dialog
   - This only needs to be done once

3. Grant permissions when prompted:
   - **Files and Folders**: Required to access your video/audio files
   - **Audio**: Required for playback

## Creating Your First Project

### 1. Set Project Frame Rate

When Projector launches, you'll see an empty timeline.

1. Click **Settings** (⚙️) in the top toolbar
2. Under **Timeline**, set your project frame rate:
   - **24 fps**: Film standard
   - **25 fps**: PAL video
   - **29.97 fps**: NTSC video (drop-frame)
   - **30 fps**: Non-drop-frame video
3. Click **Done**

**Important**: Match your project frame rate to your video files for accurate playback.

### 2. Import Media Files

#### Method 1: Drag and Drop

1. Open Finder and navigate to your video/audio files
2. Drag files directly onto the **Media Library** panel (bottom of window)
3. Projector will import the files and extract metadata

#### Method 2: Import Dialog

1. Click the **+** button in the Media Library header
2. Select files in the open dialog
3. Click **Import**

**Supported Formats**:
- **Video**: MOV, MP4, M4V, AVI, MKV, MXF, MPG, MPEG
- **Audio**: WAV, AIF, AIFF, MP3, M4A, AAC, FLAC, OGG

### 3. Build Your Timeline

1. **Add Video Reels**:
   - Drag a video file from the Media Library to the **Timeline** panel
   - The first reel starts at frame 0
   - Drag additional reels to position them sequentially

2. **Position Reels**:
   - Drag reels left/right to adjust their timeline position
   - Reels cannot overlap (validation enforced)
   - The timeline automatically extends to fit all content

3. **Add Audio Clips** (optional):
   - If video files have audio, Projector extracts it automatically
   - Audio clips appear on **Audio Lane 1** by default
   - Create additional lanes using **+ Audio Lane** button

### 4. Configure Playback

#### Video Player

The video player (center of window) shows:
- Current frame video
- Timecode overlay (HH:MM:SS:FF)
- Transport controls (Play, Pause, Stop)

#### Transport Controls

Located at the top of the window:

- **⏮ Step Backward**: Move back one frame
- **▶️ Play/Pause**: Start/stop playback (Spacebar)
- **⏭ Step Forward**: Move forward one frame
- **⏹ Stop**: Stop and return to start

#### Timeline Navigation

- **Zoom**: Use the zoom slider (bottom-right of timeline)
- **Scroll**: Drag the timeline horizontally
- **Click to Seek**: Click anywhere on the timeline to jump to that frame

### 5. Audio Configuration (Optional)

If you have a multi-channel audio interface:

1. Click **Settings** → **Audio**
2. Select your **Output Device**
3. Click **Output Mapping**
4. Assign each audio lane to specific output channels:
   - **Lane 1** → Outputs 1-2 (stereo)
   - **Lane 2** → Outputs 3-4
   - etc.
5. Click **Done**

### 6. Save Your Project

1. Click **File** → **Save** (⌘S)
2. Choose a location and name for your project
3. Projector creates a **.projector** package containing:
   - Project data (timeline, settings)
   - Security-scoped bookmarks (for sandbox access)

**Note**: The .projector file references your media files - it does NOT contain the video/audio data itself. To bundle media with your project, use **File → Consolidate Media**.

## Basic Playback

### Play from Current Position

1. Click on the timeline to set the playhead position
2. Press **Spacebar** to start playback
3. Press **Spacebar** again to pause

### Frame-Accurate Positioning

- **Arrow Keys**: Step forward/backward one frame at a time
- **Home**: Jump to timeline start (frame 0)
- **End**: Jump to timeline end

### Playback Behavior

- **On Reel**: Video plays from the reel file
- **In Gap**: Playhead advances via timer (no video shown)
- **Seamless Transitions**: Reels preload for smooth transitions

## Next Steps

- **MIDI Sync**: Configure MTC/MMC for external sync ([MIDI Sync Setup](midi-sync-setup.md))
- **Audio Routing**: Set up multi-channel output ([Audio Routing Guide](audio-routing-guide.md))
- **Keyboard Shortcuts**: Learn all shortcuts ([Keyboard Shortcuts](keyboard-shortcuts.md))
- **Troubleshooting**: Resolve common issues ([Troubleshooting](troubleshooting.md))

---

## Tips

- **Waveforms**: Audio waveforms generate asynchronously - wait 5-10 seconds for large files
- **Thumbnails**: Video thumbnails generate on-demand as you zoom/scroll
- **Project Documents**: .projector files use macOS document icons (may not appear immediately in Finder)
- **Sandbox Access**: If files become inaccessible, use **File → Locate Missing Files** to re-grant access

---

[← Back to User Guide](README.md) | [MIDI Sync Setup →](midi-sync-setup.md)
