# MIDI Sync Setup

Projector supports MIDI Time Code (MTC) and MIDI Machine Control (MMC) for synchronization with external devices like DAWs, video switchers, and timecode generators.

## Overview

### What is MTC?

**MIDI Time Code (MTC)** transmits timecode position as MIDI messages. Projector receives MTC and synchronizes its playhead to the external source.

**Use Cases**:
- Sync with Pro Tools, Logic Pro, or other DAWs
- Follow timecode from a hardware timecode generator
- Lock to video switchers or broadcast equipment

### What is MMC?

**MIDI Machine Control (MMC)** transmits transport commands (play, stop, locate) via MIDI. Projector responds to these commands for remote control.

**Supported MMC Commands**:
- **Play** (0x02): Start playback
- **Stop** (0x01): Pause playback
- **Locate** (0x44): Seek to timecode position
- **Pause** (0x09): Pause playback
- **Rewind** (0x05): Rewind (currently pauses)
- **Fast Forward** (0x04): Fast forward (currently pauses)

## Hardware Setup

### Required Equipment

1. **USB MIDI Interface**: Connect your computer to MIDI devices
   - Examples: MOTU MicroLite, Roland UM-ONE, Yamaha UX16
2. **MTC Source** (optional): Device that transmits timecode
   - DAW (Pro Tools, Logic Pro, Cubase)
   - Timecode generator (Denecke TS-3, Ambient Lockit)
3. **MIDI Cables**: 5-pin DIN MIDI cables

### Physical Connections

```
┌─────────────┐       MIDI OUT       ┌──────────────────┐
│ MTC Source  │ ───────────────────→ │  USB MIDI        │
│ (DAW/TC Gen)│                      │  Interface       │
└─────────────┘                      └──────────────────┘
                                              │
                                              │ USB
                                              ↓
                                     ┌────────────────┐
                                     │   Your Mac     │
                                     │  (Projector)   │
                                     └────────────────┘
```

**Important**: Connect MIDI OUT from source to MIDI IN on interface.

## Projector Configuration

### 1. Select MIDI Input Device

1. Launch Projector
2. Click **Settings** (⚙️) → **MIDI**
3. Under **MIDI Input**, select your USB MIDI interface from the dropdown
   - Example: "USB MIDI Interface Port 1"
4. If your device doesn't appear, click **Refresh**

### 2. Set Frame Rate

**Critical**: Match Projector's frame rate to your MTC source.

1. In **Settings** → **MIDI**:
   - Set **Local Frame Rate** to match your source
   - Example: If Pro Tools is set to 29.97 fps, select **29.97 fps**

2. **Frame Rate Mismatch**:
   - If rates don't match, you'll see "Frame Rate Mismatch" status
   - Sync will not work until rates are aligned

### 3. Enable Auto-Play (Optional)

Under **Settings** → **MIDI**:
- **Auto-Play on MTC Sync**: When enabled, Projector starts playing automatically when MTC locks
- **Auto-Pause on MTC Stop**: When enabled, Projector pauses when MTC stops

## Using MTC Sync

### Sync Workflow

1. **Start MTC Source**: Begin playback on your DAW or timecode generator
2. **Watch Sync Status**: The sync indicator (top-right) shows:
   - **🔴 No MTC**: Not receiving timecode
   - **🟡 Locking...**: Receiving quarter-frames, building timecode
   - **🟢 Synced**: Locked to MTC, following timecode

3. **Playback Behavior**:
   - Projector's playhead follows the MTC position
   - Video/audio play synchronized to the external source
   - Transport controls are overridden (MTC drives playback)

### Sync Indicators

The **Sync Status Indicator** (top-right) displays:

```
[🟢 Synced] [+0.2 frames] [00:05:23 locked]
            ↑ Drift        ↑ Lock duration
```

- **Status Icon**:
  - 🔴 Red: No MTC
  - 🟡 Yellow: Locking
  - 🟢 Green: Synced

- **Drift Display** (when synced):
  - Shows difference between MTC and local playback in frames
  - **Green** (<0.5 frames): Excellent sync
  - **Yellow** (1-2 frames): Fair sync, may need adjustment
  - **Red** (>2 frames): Poor sync, check configuration

- **Lock Duration**: How long sync has been maintained

### Manual Transport Control

While MTC is active:
- **Stop Button**: Overrides MTC and stops playback
- **Manual Seek**: Temporarily pauses sync until MTC catches up
- To re-enable MTC control: Press **Play** or wait for MTC to restart

## Using MMC Commands

MMC commands work independently of MTC and can be used for remote control:

### Receiving MMC Commands

1. Ensure MIDI input is selected (Settings → MIDI)
2. Your MMC controller sends commands
3. Projector responds:
   - **Play**: Starts playback
   - **Stop**: Pauses playback
   - **Locate**: Seeks to specified timecode

### Sending MMC from a DAW

**Pro Tools**:
1. Setup → Peripherals → MIDI Controllers
2. Add your MIDI interface
3. Enable "MMC" and set device ID
4. Transport commands will send to Projector

**Logic Pro**:
1. Preferences → MIDI → Sync
2. Enable "Transmit MMC"
3. Select your MIDI output device

**Cubase**:
1. Transport → Project Synchronization Setup
2. Enable "MIDI Machine Control Master"
3. Select MIDI output

## Troubleshooting

### Not Receiving MTC

**Symptom**: Sync status shows "No MTC"

**Solutions**:
1. **Check MIDI Cable**: Ensure MIDI OUT (source) → MIDI IN (interface)
2. **Refresh MIDI Devices**: Settings → MIDI → Refresh
3. **Verify Source is Transmitting**: Check DAW/generator is sending MTC
4. **Test with MIDI Monitor**: Use Audio MIDI Setup to verify MIDI is arriving

### Frame Rate Mismatch

**Symptom**: Status shows "Frame Rate Mismatch"

**Solution**:
1. Check your MTC source's frame rate
2. In Projector Settings → MIDI, set **Local Frame Rate** to match
3. Common rates:
   - **23.976 fps**: Film/video pulldown
   - **24 fps**: Film standard
   - **25 fps**: PAL video
   - **29.97 fps**: NTSC video (drop-frame)
   - **30 fps**: Non-drop-frame video

### Playback Stutters

**Symptom**: Video playback is choppy during MTC sync

**Possible Causes**:
1. **High Drift**: Check drift indicator (>2 frames = poor)
2. **CPU Overload**: Close other applications
3. **Disk Speed**: Use SSD for video files
4. **Buffer Settings**: Settings → Audio → Increase buffer size

**Solutions**:
- Reduce drift threshold (Settings → MIDI → Drift Tolerance)
- Use optimized/proxied media (lower bitrate)
- Close background applications

### Sync Drifting Over Time

**Symptom**: Drift indicator shows increasing offset

**Solutions**:
1. **Check Frame Rate Match**: Must be exact (not just similar)
2. **Audio Buffer Settings**: Large buffers can cause latency
3. **Clock Drift**: Some MIDI interfaces have slight clock drift
   - Use a hardware word clock if available
   - Restart devices to reset clocks

### MMC Commands Not Working

**Symptom**: DAW sends MMC but Projector doesn't respond

**Solutions**:
1. **Check MIDI Input**: Settings → MIDI → Ensure input is selected
2. **Verify MMC Device ID**: Most devices use ID 127 (all-call)
3. **Test with Simple Command**: Try Stop/Play first, then Locate

## Advanced Configuration

### Drift Compensation Settings

Settings → MIDI → Advanced:

- **Drift Threshold**: How much drift to tolerate before seeking (default: 0.2 frames)
- **Drift Smoothing**: Whether to gradually adjust or jump to position

### Multiple MIDI Devices

If you have multiple MIDI interfaces:
1. Use **Audio MIDI Setup** to create a **MIDI Configuration**
2. Combine inputs into a single virtual device
3. Select the virtual device in Projector

---

## Common Setups

### Pro Tools + Projector

1. Pro Tools: Setup → Session → Frame Rate (e.g., 29.97)
2. Pro Tools: Setup → Peripherals → Synchronization → Enable MTC Generate
3. Pro Tools: Select MIDI output device
4. Projector: Settings → MIDI → Select MIDI input, set frame rate to 29.97
5. Play Pro Tools → Projector syncs automatically

### Logic Pro + Projector

1. Logic: Preferences → Synchronization → Enable "MIDI Time Code"
2. Logic: Select MIDI output
3. Projector: Settings → MIDI → Select MIDI input
4. Match frame rates
5. Play Logic → Projector follows

---

[← Getting Started](getting-started.md) | [Audio Routing Guide →](audio-routing-guide.md)
