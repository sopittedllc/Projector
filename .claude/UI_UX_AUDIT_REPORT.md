# UI/UX Audit Report - Projector

> **Date**: 2026-01-02
> **Auditor**: qa-auditor + ui-specialist agents
> **Scope**: Transport controls, timeline behavior, keyboard shortcuts, industry conventions

---

## Executive Summary

This audit compares Projector's UI/UX patterns against professional video/audio editing applications (Final Cut Pro, Logic Pro, DaVinci Resolve).

**Design Decision**: Projector prioritizes timeline-click navigation over complex keyboard shortcuts. Users click the timeline to position the playhead, making J/K/L shuttle controls unnecessary. This is a simpler, more approachable design.

| Priority | Issue | Status |
|----------|-------|--------|
| **Fixed** | Waveform zoom resize bug | `.id(clipWidth)` fix applied |
| **Fixed** | Transport button order | Now: Backward → Play → Stop → Forward |
| **Deferred** | J/K/L shuttle controls | Not needed - use timeline click |
| **Deferred** | Arrow key frame stepping | Nice-to-have, not critical |
| **Deferred** | Additional keyboard shortcuts | May add based on user feedback |

---

## Findings

### 1. Transport Controls - Keyboard Shortcuts

#### Industry Standard: JKL Shuttle
**This is the most critical missing feature.**

Every professional video/audio application uses J/K/L for transport:

| Key | Action | Pro App Behavior |
|-----|--------|------------------|
| **J** | Play Reverse | Multi-press increases speed (1x, 2x, 4x, 8x) |
| **K** | Stop | Immediate stop at current position |
| **L** | Play Forward | Multi-press increases speed (1x, 2x, 4x, 8x) |
| **J+K** | Slow Reverse | Hold both for slow-motion reverse |
| **K+L** | Slow Forward | Hold both for slow-motion forward |

**Current State**: NOT IMPLEMENTED

**Impact**: Professional editors will immediately try J/K/L and find the app unusable.

#### Industry Standard: Frame Stepping

| Key | Action | Status |
|-----|--------|--------|
| **Left Arrow** | Previous frame | NOT IMPLEMENTED |
| **Right Arrow** | Next frame | NOT IMPLEMENTED |
| **Shift+Left** | Back 10 frames | NOT IMPLEMENTED |
| **Shift+Right** | Forward 10 frames | NOT IMPLEMENTED |

**Current State**: Arrow keys have no function.

#### Industry Standard: Navigation

| Key | Action | Status |
|-----|--------|--------|
| **Home** (Fn+Left) | Go to beginning | NOT IMPLEMENTED |
| **End** (Fn+Right) | Go to end | NOT IMPLEMENTED |
| **; (semicolon)** | Previous edit point | NOT IMPLEMENTED |
| **' (apostrophe)** | Next edit point | NOT IMPLEMENTED |

### 2. Current Keyboard Shortcuts (Complete List)

| Shortcut | Action | Location |
|----------|--------|----------|
| **Space** | Play/Pause | VitalControlsBar, TransportBarView, MultiTrackTimelineView |
| **Escape** | Exit full screen | ContentView |
| **Return** | Submit settings | SettingsView |
| **Cmd+.** | Cancel action | MultiTrackTimelineView |
| **Return** | Default action | MultiTrackTimelineView |

**Total: 5 shortcuts** (vs 200+ in Final Cut Pro)

### 3. Transport Button Layout

#### Current Implementation (VitalControlsBar.swift)
```
[Step Back] [Play/Pause] [Step Forward] [Stop]
```

#### Industry Convention (Final Cut Pro, Logic Pro)
```
[Go to Start] [Step Back] [Play/Pause] [Step Forward] [Go to End]
```
or with Record:
```
[Go to Start] [Step Back] [Stop] [Play] [Record] [Step Forward] [Go to End]
```

**Issues Identified**:
1. Missing "Go to Start" button
2. Missing "Go to End" button
3. Stop button is at the end (unusual placement)
4. No loop/cycle button

### 4. Range Selection (In/Out Points)

#### Industry Standard

| Key | Action | Status |
|-----|--------|--------|
| **I** | Set In point (range start) | NOT IMPLEMENTED |
| **O** | Set Out point (range end) | NOT IMPLEMENTED |
| **X** | Select clip range | NOT IMPLEMENTED |
| **Option+X** | Clear range | NOT IMPLEMENTED |

**Current State**: No keyboard-driven range selection workflow.

### 5. Zoom Controls

#### Industry Standard

| Key | Action | Status |
|-----|--------|--------|
| **Cmd++** | Zoom in | NOT IMPLEMENTED |
| **Cmd+-** | Zoom out | NOT IMPLEMENTED |
| **Shift+Z** | Zoom to fit | NOT IMPLEMENTED |
| **Ctrl+Z** | Zoom to samples | NOT IMPLEMENTED |

**Current State**: Zoom only via slider in VitalControlsBar.

### 6. Waveform Zoom Bug (FIXED)

**Issue**: When zoom level changes, waveforms in audio clips didn't resize.

**Root Cause**: DSWaveformImage's `WaveformView` caches renders and doesn't respond to frame changes.

**Fix Applied**: Added `.id(clipWidth)` to force re-render on zoom.

```swift
// AudioClipView.swift:153
WaveformView(audioURL: clip.sourceURL, configuration: config)
    .id(clipWidth)  // Force re-render when zoom changes
    .drawingGroup()
```

---

## Recommendations

### Priority 0 (Must Fix)

#### 1. Implement J/K/L Shuttle Controls

Add to ContentView or a dedicated KeyboardHandler:

```swift
.onKeyPress("j") {
    playbackEngine.shuttleReverse()
    return .handled
}
.onKeyPress("k") {
    playbackEngine.stop()
    return .handled
}
.onKeyPress("l") {
    playbackEngine.shuttleForward()
    return .handled
}
```

PlaybackEngine needs:
- `shuttleReverse()` with speed multiplier
- `shuttleForward()` with speed multiplier
- Speed increases on repeated presses

#### 2. Implement Arrow Key Frame Stepping

```swift
.onKeyPress(.leftArrow) {
    playbackEngine.stepBackward()
    return .handled
}
.onKeyPress(.rightArrow) {
    playbackEngine.stepForward()
    return .handled
}
.onKeyPress(.leftArrow, modifiers: .shift) {
    playbackEngine.step(frames: -10)
    return .handled
}
.onKeyPress(.rightArrow, modifiers: .shift) {
    playbackEngine.step(frames: 10)
    return .handled
}
```

### Priority 1 (Should Fix)

#### 3. Home/End Navigation

```swift
.onKeyPress(.home) {
    playbackEngine.goToBeginning()
    return .handled
}
.onKeyPress(.end) {
    playbackEngine.goToEnd()
    return .handled
}
```

#### 4. I/O Range Selection

```swift
.onKeyPress("i") {
    timelineManager.setInPoint(at: playbackEngine.currentFrame)
    return .handled
}
.onKeyPress("o") {
    timelineManager.setOutPoint(at: playbackEngine.currentFrame)
    return .handled
}
```

### Priority 2 (Nice to Have)

#### 5. Zoom Keyboard Shortcuts

```swift
.onKeyPress("+", modifiers: .command) {
    timelineViewModel.zoomIn()
    return .handled
}
.onKeyPress("-", modifiers: .command) {
    timelineViewModel.zoomOut()
    return .handled
}
.onKeyPress("z", modifiers: .shift) {
    timelineViewModel.zoomToFit()
    return .handled
}
```

#### 6. Transport Button Reordering

Current: `[<<] [Play] [>>] [Stop]`

Recommended: `[|<] [<<] [Play/Pause] [>>] [>|]`

With buttons for:
- Go to Start (`|<`)
- Step Back (`<<`)
- Play/Pause (toggle icon)
- Step Forward (`>>`)
- Go to End (`>|`)

---

## Implementation Effort Estimate

| Task | Effort | Owner |
|------|--------|-------|
| J/K/L shuttle controls | 4h | backend-logic + ui-specialist |
| Arrow key frame stepping | 1h | ui-specialist |
| Home/End navigation | 30m | ui-specialist |
| I/O range selection | 2h | backend-logic |
| Zoom shortcuts | 30m | ui-specialist |
| Transport button reorder | 1h | ui-specialist |

**Total: ~9 hours** for professional-grade keyboard navigation

---

## Appendix: Reference Materials

### Final Cut Pro Transport Shortcuts
- Space: Play/Pause
- J: Play Reverse (multi-press faster)
- K: Stop
- L: Play Forward (multi-press faster)
- Left Arrow: Previous frame
- Right Arrow: Next frame
- Shift+Left: Back 10 frames
- Shift+Right: Forward 10 frames
- Home: Go to beginning
- End: Go to end
- ;: Previous edit point
- ': Next edit point

### Logic Pro Transport Shortcuts
- Space: Play/Stop
- Enter (numpad): Play from beginning
- 0 (numpad): Stop and return to start
- , (comma): Rewind
- . (period): Forward

---

*Report generated by qa-auditor agent. Findings validated against Apple Final Cut Pro and Logic Pro documentation.*
