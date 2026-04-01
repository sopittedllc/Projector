# Audio Routing Test Matrix

Comprehensive test matrix for multi-channel audio routing verification before v1.0 release.

**Test Date**: ___________
**Tester**: ___________
**Build Version**: ___________
**Audio Interface**: ___________  (e.g., "Built-in Output", "MOTU 828es", "Apollo x8")

---

## Device Configuration Tests

### Device Enumeration

- [ ] **Get available output devices**
  - Open Settings → Audio → Output Device dropdown
  - **Expected**: Shows all connected audio devices (built-in + interfaces)

- [ ] **Built-in Output present**
  - Check device list
  - **Expected**: "Built-in Output" always appears (fallback)

- [ ] **USB audio interface detected**
  - Connect USB audio interface
  - Refresh device list
  - **Expected**: Interface appears in list with correct name

- [ ] **Thunderbolt/AVB interface detected**
  - Connect Thunderbolt/AVB interface
  - **Expected**: Interface appears in list

- [ ] **Aggregate device support**
  - Create aggregate device in Audio MIDI Setup (built-in + USB)
  - Check device list
  - **Expected**: Aggregate device appears, usable

### Device Selection

- [ ] **Select Built-in Output**
  - Select "Built-in Output" from dropdown
  - **Expected**: Selected device updates, 2 channels available

- [ ] **Select 4-channel interface**
  - Select Focusrite Scarlett 4i4 (or similar)
  - **Expected**: Selected device updates, 4 channels available

- [ ] **Select 8+ channel interface**
  - Select MOTU 828es (or similar)
  - **Expected**: Selected device updates, 8+ channels available

- [ ] **Device channel count correct**
  - Check Settings → Audio → Output Mapping
  - **Expected**: Max channel dropdown matches device (e.g., 1-8 for 8-channel)

---

## Routing Configuration Tests

### Lane-to-Channel Mapping

- [ ] **Default routing (sequential stereo pairs)**
  - Create 3 audio lanes
  - Check default routing
  - **Expected**:
    - Lane 1 → Outputs 1-2
    - Lane 2 → Outputs 3-4
    - Lane 3 → Outputs 5-6

- [ ] **Map lane to stereo output (1-2)**
  - Create lane
  - Settings → Audio → Output Mapping → Select "1-2"
  - **Expected**: Lane routes to channels 0-1 (displayed as 1-2)

- [ ] **Map lane to custom channels (5-6)**
  - Create lane
  - Settings → Audio → Output Mapping → Select "5-6"
  - **Expected**: Lane routes to channels 4-5

- [ ] **Map mono lane to single channel**
  - Create lane
  - Settings → Audio → Output Mapping → Select "3" (mono)
  - **Expected**: Lane routes to channel 2 only

- [ ] **Map lane to invalid channels (beyond device)**
  - Select Built-in Output (2 channels)
  - Attempt to route lane to outputs 5-6
  - **Expected**: Validation error or grayed-out option

---

## Playback Routing Tests

### Stereo Output (2-Channel Device)

**Device**: Built-in Output (2 channels)

- [ ] **Single lane → Outputs 1-2**
  - Add audio clip to Lane 1
  - Play
  - **Expected**: Audio from both L/R speakers

- [ ] **3 lanes → All mixed to Outputs 1-2**
  - Add clips to lanes 1, 2, 3
  - Route all to outputs 1-2
  - Play
  - **Expected**: All 3 lanes mixed, heard from L/R speakers

### Quad Output (4-Channel Interface)

**Device**: Focusrite Scarlett 4i4 (4 channels)

- [ ] **Lane 1 (Dialog) → Outputs 1-2**
  - Route Lane 1 to outputs 1-2
  - Play
  - **Expected**: Dialog from outputs 1-2 only

- [ ] **Lane 2 (Music) → Outputs 3-4**
  - Route Lane 2 to outputs 3-4
  - Play
  - **Expected**: Music from outputs 3-4 only, not 1-2

- [ ] **Both lanes playing simultaneously**
  - Play lanes 1 and 2 together
  - **Expected**: Dialog from 1-2, Music from 3-4, no crosstalk

### 5.1 Surround (6-Channel Interface)

**Device**: MOTU UltraLite (6 channels)

- [ ] **Lane 1 (Front L/R) → Outputs 1-2**
  - Route to 1-2
  - Play
  - **Expected**: Audio from front L/R speakers

- [ ] **Lane 2 (Center) → Output 3 (mono)**
  - Route to output 3 (mono)
  - Play
  - **Expected**: Audio from center speaker only

- [ ] **Lane 3 (LFE) → Output 4 (mono)**
  - Route to output 4 (mono)
  - Play
  - **Expected**: Audio from subwoofer/LFE only

- [ ] **Lane 4 (Rear L/R) → Outputs 5-6**
  - Route to 5-6
  - Play
  - **Expected**: Audio from rear L/R speakers

- [ ] **All lanes playing (full 5.1 mix)**
  - Play all 4 lanes simultaneously
  - **Expected**: Correct 5.1 surround mix, no crosstalk

### Multi-Track Stems (8+ Channels)

**Device**: MOTU 828es or Apollo x8 (8+ channels)

- [ ] **Lane 1 (Dialog) → Outputs 1-2**
- [ ] **Lane 2 (Music) → Outputs 3-4**
- [ ] **Lane 3 (SFX) → Outputs 5-6**
- [ ] **Lane 4 (Ambience) → Outputs 7-8**
  - Play all lanes
  - **Expected**: Each stem routes to correct output pair, no bleed

---

## Volume/Mute/Solo Tests

### Volume Control

- [ ] **Lane volume at 100% (unity gain)**
  - Set lane volume slider to 100%
  - Play
  - **Expected**: Full volume, no clipping

- [ ] **Lane volume at 0% (silent)**
  - Set lane volume to 0%
  - Play
  - **Expected**: No audio from that lane

- [ ] **Lane volume at 50% (half gain)**
  - Set lane volume to 50%
  - Play
  - **Expected**: Quieter audio (~6dB attenuation)

- [ ] **Volume changes during playback**
  - Start playback
  - Drag volume slider up/down
  - **Expected**: Volume changes smoothly in real-time

### Mute

- [ ] **Mute lane (🔇 icon)**
  - Click mute button on lane
  - Play
  - **Expected**: Lane is silent, mute icon highlighted

- [ ] **Unmute lane**
  - Click mute button again
  - **Expected**: Audio returns, mute icon unhighlighted

- [ ] **Mute multiple lanes**
  - Mute lanes 1 and 3 (keep lane 2 unmuted)
  - Play
  - **Expected**: Only lane 2 audible

### Solo

- [ ] **Solo single lane**
  - Click solo button (🎧) on Lane 2
  - Play
  - **Expected**: ONLY Lane 2 audible, all others muted

- [ ] **Solo multiple lanes**
  - Solo lanes 1 and 3
  - Play
  - **Expected**: Lanes 1 and 3 audible, lane 2 muted

- [ ] **Solo overrides mute**
  - Mute lane 1
  - Solo lane 1
  - Play
  - **Expected**: Lane 1 audible (solo wins over mute)

- [ ] **Unsolo all lanes**
  - Unsolo all lanes
  - **Expected**: All lanes return to pre-solo state

---

## Device Change Tests

### Hot-Swapping

- [ ] **Connect device during playback**
  - Play audio on Built-in Output
  - Connect USB interface mid-playback
  - **Expected**: Interface appears in device list, playback continues on Built-in

- [ ] **Disconnect device during playback**
  - Play audio on USB interface
  - Unplug interface mid-playback
  - **Expected**: Falls back to Built-in Output, playback continues, no crash

- [ ] **Switch device during playback**
  - Play audio on USB interface
  - Settings → Audio → Select Built-in Output
  - **Expected**: Audio switches to Built-in immediately

### Sample Rate Changes

- [ ] **44.1kHz device**
  - Select device set to 44.1kHz in Audio MIDI Setup
  - Play 48kHz audio file
  - **Expected**: Audio plays (automatic resampling) OR warning dialog

- [ ] **48kHz device**
  - Select device set to 48kHz
  - Play 44.1kHz audio file
  - **Expected**: Audio plays correctly

- [ ] **96kHz device**
  - Select device set to 96kHz
  - Play 48kHz audio file
  - **Expected**: Audio plays correctly

---

## Edge Cases

### Channel Validation

- [ ] **Route to non-existent output (outputs 7-8 on 6-channel device)**
  - Select 6-channel device
  - Attempt to route lane to outputs 7-8
  - **Expected**: Validation error or option disabled

- [ ] **Very high channel counts (>16 channels)**
  - Select 24-channel interface (if available)
  - Route lanes to channels 20-21, 22-23
  - **Expected**: Routing works correctly

- [ ] **Zero-channel device (should not exist)**
  - **Expected**: Device should not appear in list

- [ ] **Odd channel count device (3, 5, 7 channels)**
  - Select device with odd channel count
  - **Expected**: Routing works, max channel reflects device

### Latency and Buffer Size

- [ ] **Small buffer (256 samples) - Low latency**
  - Settings → Audio → Buffer Size → 256
  - Play audio
  - **Expected**: Low latency, possible dropouts on weak CPU

- [ ] **Large buffer (2048 samples) - Stable**
  - Settings → Audio → Buffer Size → 2048
  - Play audio
  - **Expected**: Higher latency, stable playback

- [ ] **Buffer size change during playback**
  - Play audio
  - Change buffer size
  - **Expected**: Audio restarts with new buffer, no crash

### Audio Dropouts

- [ ] **10 simultaneous lanes - No dropouts**
  - Play 10 audio lanes at once
  - **Expected**: No audio pops, clicks, or dropouts

- [ ] **High CPU load - Graceful degradation**
  - Start heavy background task (e.g., video export)
  - Play audio
  - **Expected**: Audio may dropout but recovers, no crash

---

## Consistency Tests (Finder vs Internal)

- [ ] **Drag audio from Finder to timeline - Correct routing**
  - Drag WAV from Finder to timeline
  - Check routing
  - **Expected**: Uses default routing (next available stereo pair)

- [ ] **Drag audio from Media Library to timeline - Same routing**
  - Import WAV to library
  - Drag from library to timeline
  - **Expected**: Same routing behavior as Finder drag

---

## Performance Tests

### CPU Usage

- [ ] **1 lane playback: <2% CPU**
  - Play single audio lane
  - Check Activity Monitor
  - **Expected**: CPU <2%

- [ ] **10 lane playback: <10% CPU**
  - Play 10 lanes simultaneously
  - Check Activity Monitor
  - **Expected**: CPU <10%

- [ ] **MatrixMixer overhead: <5% CPU**
  - Play complex routing (8 lanes → 8 different outputs)
  - Check AVAudioEngine CPU usage
  - **Expected**: Minimal overhead from routing

---

## Regression Tests (Known Fixed Issues)

- [ ] **Issue #34: Audio clicks on lane solo**
  - Solo a lane while playing
  - **Expected**: No click/pop when solo engages

- [ ] **Issue #56: Volume changes lag during playback**
  - Play audio
  - Drag volume slider rapidly
  - **Expected**: Volume changes immediately, no lag

- [ ] **Issue #72: Device change causes crash**
  - Switch devices during playback
  - **Expected**: No crash, smooth transition

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
