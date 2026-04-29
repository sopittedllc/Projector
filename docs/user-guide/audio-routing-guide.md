# Audio Routing Guide

Projector supports flexible multi-channel audio routing, allowing you to route each audio lane to specific output channels on your audio interface.

## Overview

### Audio Architecture

```
┌────────────────────────────────────────────────────────────┐
│                  Projector Timeline                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                │
│  │  Lane 1  │  │  Lane 2  │  │  Lane 3  │ ...             │
│  │ (Stereo) │  │  (Mono)  │  │ (Stereo) │                │
│  └──────────┘  └──────────┘  └──────────┘                │
└────────────────────────────────────────────────────────────┘
         │              │              │
         ↓              ↓              ↓
┌────────────────────────────────────────────────────────────┐
│               AVAudioEngine Matrix Mixer                   │
│   Lane 1 → Outputs 1-2 (channels 0-1)                     │
│   Lane 2 → Output 3    (channel 2)                        │
│   Lane 3 → Outputs 5-6 (channels 4-5)                     │
└────────────────────────────────────────────────────────────┘
         │              │              │
         ↓              ↓              ↓
┌────────────────────────────────────────────────────────────┐
│          Multi-Channel Audio Interface                     │
│  ┌────┬────┬────┬────┬────┬────┬────┬────┐              │
│  │ 1  │ 2  │ 3  │ 4  │ 5  │ 6  │ 7  │ 8  │ ...           │
│  └────┴────┴────┴────┴────┴────┴────┴────┘              │
└────────────────────────────────────────────────────────────┘
```

### Key Concepts

- **Audio Lane**: A horizontal track in the timeline that can contain multiple audio clips
- **Output Channel**: A physical output on your audio interface (numbered 1, 2, 3, ...)
- **Routing**: Mapping a lane to specific output channels
- **Channel Offset**: Starting channel for a lane's output (0-based internally, 1-based in UI)

## Selecting Output Device

### 1. Built-In Output

By default, Projector uses your Mac's built-in speakers (stereo, 2 channels).

To change:
1. Click **Settings** (⚙️) → **Audio**
2. Under **Output Device**, select "Built-in Output"
3. Click **Done**

### 2. Multi-Channel Audio Interface

For professional multi-channel routing:

1. Connect your USB/Thunderbolt audio interface
2. Launch Projector
3. Click **Settings** → **Audio**
4. Select your interface from the **Output Device** dropdown
   - Example: "MOTU 828es" (8 channels)
   - Example: "Universal Audio Apollo x8" (16 channels)
5. Click **Done**

**Supported Interfaces**:
- Any CoreAudio-compatible interface
- USB Audio Class (UAC) devices
- Thunderbolt/AVB interfaces
- Aggregate devices (see Advanced)

## Configuring Lane Routing

### Default Routing

When you create an audio lane, it routes to the first available stereo pair:
- **Lane 1** → Outputs 1-2
- **Lane 2** → Outputs 3-4
- **Lane 3** → Outputs 5-6
- etc.

### Custom Routing

To assign lanes to specific outputs:

1. Click **Settings** → **Audio** → **Output Mapping**
2. The **Audio Output Mapping** dialog shows all lanes
3. For each lane:
   - **Lane Name**: The name of the audio lane
   - **Output Channels**: Current routing (e.g., "1-2")
   - **Offset**: Starting channel (0-based)

4. To change routing:
   - Click the **Output Channels** dropdown
   - Select new output pair:
     - **1-2** (stereo, channels 0-1)
     - **3-4** (stereo, channels 2-3)
     - **5-6** (stereo, channels 4-5)
     - **1** (mono, channel 0)
     - **2** (mono, channel 1)
     - **Custom** (manual offset)

5. Click **Done** to save

### Mono vs Stereo Routing

**Stereo Lanes** (most common):
- Route to a stereo pair (1-2, 3-4, 5-6, etc.)
- Pans left/right within the pair

**Mono Lanes**:
- Route to a single channel
- Useful for voice-over or individual instruments
- Select "1", "2", "3", etc. in the dropdown

**Custom Routing**:
- Enter a channel offset manually
- Example: Offset 8 → Output channel 9

## Lane Controls

Each audio lane has controls for playback behavior:

### Volume

- **Range**: 0% (silent) to 100% (unity gain)
- **Default**: 100% (no attenuation)
- **Adjust**: Drag the volume slider on the lane header

### Mute

- **Button**: 🔇 icon on lane header
- **Behavior**: Silences the lane output (no audio sent to interface)
- **Use Case**: Temporarily disable a lane without deleting clips

### Solo

- **Button**: 🎧 icon on lane header
- **Behavior**: Mutes all OTHER lanes (only soloed lanes play)
- **Multiple Solo**: You can solo multiple lanes simultaneously

**Solo Priority**: If any lane is soloed, non-soloed lanes are muted.

## Common Routing Scenarios

### Scenario 1: Stereo Playback (2-Channel Interface)

**Setup**: Built-in speakers or simple USB interface

**Configuration**:
- **Lane 1**: Outputs 1-2 (default)
- All other lanes: Outputs 1-2 (mixed to stereo)

**Steps**:
1. No configuration needed (default behavior)
2. All audio routes to stereo output

---

### Scenario 2: Quad Output (4-Channel Interface)

**Setup**: 4-channel interface (e.g., Focusrite Scarlett 4i4)

**Configuration**:
- **Lane 1** (Dialog): Outputs 1-2
- **Lane 2** (Music): Outputs 3-4

**Steps**:
1. Settings → Audio → Output Mapping
2. Lane 1: Select "1-2"
3. Lane 2: Select "3-4"
4. Done

**Result**: Dialog to front speakers (1-2), music to rear speakers (3-4)

---

### Scenario 3: 5.1 Surround (6-Channel Interface)

**Setup**: 6-channel interface (e.g., MOTU UltraLite)

**Configuration**:
- **Lane 1** (Front L/R): Outputs 1-2
- **Lane 2** (Center): Output 3 (mono)
- **Lane 3** (LFE): Output 4 (mono)
- **Lane 4** (Rear L/R): Outputs 5-6

**Steps**:
1. Settings → Audio → Output Mapping
2. Lane 1: Select "1-2" (Front L/R)
3. Lane 2: Select "3" (Center mono)
4. Lane 3: Select "4" (LFE mono)
5. Lane 4: Select "5-6" (Rear L/R)
6. Done

---

### Scenario 4: Multi-Track Stems (8+ Channels)

**Setup**: 8+ channel interface (e.g., MOTU 828es, Universal Audio Apollo)

**Configuration**:
- **Lane 1** (Dialog): Outputs 1-2
- **Lane 2** (Music): Outputs 3-4
- **Lane 3** (SFX): Outputs 5-6
- **Lane 4** (Ambience): Outputs 7-8

**Steps**:
1. Settings → Audio → Output Mapping
2. Assign each lane to a unique stereo pair
3. Done

**Use Case**: Send stems to mixing console or recording device for live mix

---

## Device Hot-Swapping

### Connecting a New Device

1. Connect your audio interface (USB/Thunderbolt)
2. Projector automatically detects the new device
3. Go to Settings → Audio → Output Device
4. Select the new device

**Note**: Existing lane mappings are preserved. Verify they match the new device's channel count.

### Disconnecting a Device

1. If device is disconnected during playback, Projector falls back to **Built-in Output**
2. A notification will alert you: "Audio device disconnected"
3. Reconnect the device or select a new one in Settings

## Advanced Topics

### Aggregate Devices

Combine multiple audio interfaces into a single virtual device:

1. Open **Audio MIDI Setup** (Applications → Utilities)
2. Click **+** (bottom-left) → **Create Aggregate Device**
3. Select the interfaces to combine
4. Set **Clock Source** (usually the first device)
5. Name it (e.g., "Combined Audio")
6. In Projector, select "Combined Audio" as output device

**Use Case**: Route to both built-in speakers and external interface simultaneously.

### Sample Rate Configuration

Projector uses the device's native sample rate. To change:

1. Open **Audio MIDI Setup**
2. Select your audio interface
3. Set **Format** → Sample Rate (44.1 kHz, 48 kHz, 96 kHz, etc.)
4. Restart Projector

**Recommendation**: Use 48 kHz for video work (standard for broadcast/film).

### Latency and Buffer Size

Projector's audio buffer size affects latency:

- **Small Buffer** (256 samples): Low latency, higher CPU usage
- **Large Buffer** (2048 samples): Higher latency, lower CPU usage

**Default**: 512 samples (good balance)

To change:
1. Settings → Audio → Buffer Size
2. Adjust slider
3. Click Done

**When to Increase**:
- Audio dropouts or crackling
- CPU spikes during playback

---

## Troubleshooting

### No Sound

**Symptom**: Playback is active but no audio

**Solutions**:
1. **Check Device**: Settings → Audio → Ensure correct device selected
2. **Check Volume**: Verify lane volumes are not at 0%
3. **Check Mute**: Ensure lanes are not muted
4. **Check Solo**: If any lane is soloed, others are muted
5. **Check System Volume**: macOS System Settings → Sound → Output volume

### Clicks and Pops

**Symptom**: Audio has crackling or popping sounds

**Solutions**:
1. **Increase Buffer Size**: Settings → Audio → Buffer Size → 1024 or 2048
2. **Close Background Apps**: Free up CPU resources
3. **Check Sample Rate**: Ensure Projector and device match (Audio MIDI Setup)

### Channels Mapping Incorrectly

**Symptom**: Audio comes out of wrong speakers

**Solutions**:
1. **Verify Output Mapping**: Settings → Audio → Output Mapping
2. **Check Device Channel Count**: Ensure interface supports the channels you're routing to
3. **Test with Known Audio**: Import a stereo test tone and verify channels 1-2

### Device Not Appearing

**Symptom**: Your audio interface doesn't show in Output Device list

**Solutions**:
1. **Reconnect Device**: Unplug and replug USB/Thunderbolt
2. **Restart Projector**: Quit and relaunch
3. **Check Audio MIDI Setup**: Verify device appears in macOS Audio MIDI Setup
4. **Install Drivers**: Some interfaces require manufacturer drivers

---

[← MIDI Sync Setup](midi-sync-setup.md) | [Keyboard Shortcuts →](keyboard-shortcuts.md)
