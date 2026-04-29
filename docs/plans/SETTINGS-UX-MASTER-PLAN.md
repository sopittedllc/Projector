# Settings UX Master Plan

**Status**: Ready for Review
**Date**: 2026-04-27
**Branch**: `feature/cue-sheet-from-audio`

---

## Executive Summary

Comprehensive audit identified **43 UX issues** across Settings, Optimization, and Channel Management. This plan addresses them in 4 phases, prioritized by user impact.

---

## Phase 1: Critical Fixes (Blocks Core Workflow)

### 1.1 Channel Grid Linking - Drag-to-Link Pattern

**Current**: Click to select → hover adjacent → look 200px below for "Link?" hint
**Target**: Click-drag from one channel to adjacent channel to link

**Implementation**:
```
User Flow:
1. Drag from Channel 1 toward Channel 2
2. During drag: Both channels glow green, dotted line connects them
3. Release on Channel 2: Channels snap together, show connected bracket
4. To unlink: Drag linked channel away OR right-click → "Unlink"
```

**Visual States**:
| State | Channel 1 | Channel 2 | Feedback |
|-------|-----------|-----------|----------|
| Idle | Gray | Gray | - |
| Drag started | Yellow (source) | - | Cursor: grabbing |
| Hover adjacent | Yellow | Green glow | Dotted line between |
| Invalid target | Yellow | Red flash | "Cannot link" tooltip |
| Linked | Green bracket | Green bracket | "L↔R" badge |

**Files**: `SettingsAccordionView.swift` (ChannelCellView, ChannelGridView)

---

### 1.2 Destructive Action Confirmation

**Current**: "Move to Trash" executes immediately
**Target**: Alert confirmation before permanent actions

**Implementation**:
```swift
.alert("Move Original Files to Trash?", isPresented: $showTrashConfirm) {
    Button("Move to Trash", role: .destructive) { executeTrash() }
    Button("Cancel", role: .cancel) { }
} message: {
    Text("\(fileCount) files (\(fileSize)) will be moved to Trash. Optimized files will remain in your project.")
}
```

**Apply to**:
- CleanupOriginalFilesDialog → "Move to Trash" option
- Any future delete operations

**Files**: `CleanupOriginalFilesDialog.swift`

---

### 1.3 Cleanup Flow - Two-Step Modal

**Current**: "Cleanup Originals..." button hidden in success banner
**Target**: Cleanup options presented as part of completion flow

**Implementation**:
```
Optimization Flow:
1. Progress Sheet: "Optimizing 3 files..."
2. ↓ (completes)
3. Completion Dialog (replaces progress):
   ┌─────────────────────────────────────────┐
   │  ✓ Optimization Complete               │
   │                                         │
   │  3 files optimized, saving 2.4 GB       │
   │  Original files are still in library.  │
   │                                         │
   │  What would you like to do with the    │
   │  original files?                        │
   │                                         │
   │  ○ Keep originals where they are       │
   │  ○ Move to "Raw Files" folder          │
   │  ○ Move to Trash                        │
   │                                         │
   │  [Cancel]              [Continue]       │
   └─────────────────────────────────────────┘
```

**Files**: `OptimizationSheetView.swift`, `OptimizationViewModel.swift`

---

### 1.4 Timecode/Duration Fields - Editable

**Current**: Solid blue hover, no edit behavior
**Target**: Click to edit inline with format validation

**Implementation**:
```swift
TextField("Duration", text: $durationString)
    .textFieldStyle(.roundedBorder)
    .font(.system(.body, design: .monospaced))
    .frame(width: 100)
    .onChange(of: durationString) { _, newValue in
        durationString = formatAsTimecode(newValue)
    }
    .help("Format: HH:MM:SS:FF")
```

**Validation**:
- Accept raw numbers: `12345` → `00:01:23:45`
- Clamp frames to framerate (e.g., max 23 for 24fps)
- Red border for invalid input

**Files**: Create `TimecodeTextField.swift` component, apply in timeline views

---

## Phase 2: High Priority (Confusing UX)

### 2.1 Output Row Editing - Always-Visible TextField

**Current**: Pencil icon on hover, click to edit (hidden affordance)
**Target**: Always-visible text field with border

**Implementation**:
```swift
// BEFORE (hidden)
Text(outputName)
    .onTapGesture { startEditing() }

// AFTER (visible)
TextField("Output Name", text: $outputName)
    .textFieldStyle(.roundedBorder)
    .frame(width: 150)
```

**Files**: `SettingsAccordionView.swift` (OutputRowView)

---

### 2.2 Stereo Pair Auto-Lock Warning

**Current**: Clicking "Stereo" mode silently locks adjacent channel
**Target**: Inline warning before auto-lock

**Implementation**:
```
When user clicks Stereo mode on Channel 1:
┌─────────────────────────────────────────┐
│ ⚠️ This will pair Channel 1 with       │
│    Channel 2 as stereo.                 │
│                                         │
│    [Cancel]  [Create Pair]              │
└─────────────────────────────────────────┘
```

**Files**: `AudioOutputMappingView.swift`

---

### 2.3 Channel State Visual Distinction

**Current**: Mono=blue, Stereo=green (subtle opacity difference)
**Target**: Clear icons + stronger colors + badges

**Implementation**:
| State | Background | Border | Badge |
|-------|------------|--------|-------|
| Inactive | Gray 0.3 | Gray | - |
| Mono Active | Blue 0.5 | Blue solid | "M" |
| Stereo L | Green 0.5 | Green solid | "L" |
| Stereo R | Green 0.5 | Green solid | "R" |
| Selected | Yellow 0.5 | Yellow 2px | - |

**Files**: `SettingsAccordionView.swift` (ChannelCellView)

---

### 2.4 Select All Disambiguation

**Current**: "Select All" includes already-optimized files
**Target**: "Select All Optimizable" + clear labeling

**Implementation**:
```swift
Button("Select All Optimizable") {
    selectOnlyOptimizable()
}
.help("Selects files that can be optimized (skips already-optimized)")
```

**Files**: `OptimizationSheetView.swift`

---

### 2.5 Device Selection Feedback

**Current**: Silent when device has no channels
**Target**: Inline message explaining why "Map Interface" is disabled

**Implementation**:
```swift
if audioManager.selectedDeviceChannelCount == 0 {
    Text("Selected device has no configurable outputs")
        .font(.caption)
        .foregroundColor(.secondary)
}
```

**Files**: `SettingsAccordionView.swift` (audioSection)

---

## Phase 3: Medium Priority (Could Be Better)

### 3.1 Tooltips for Settings

Add `.help()` to all non-obvious settings:

| Setting | Tooltip |
|---------|---------|
| Auto-play on MTC | "Automatically start playback when receiving timecode" |
| Auto-pause on MTC Stop | "Pause when external timecode stops" |
| Respond to MMC | "Respond to Machine Control commands (play, stop, locate)" |
| Show Overlay | "Display timecode overlay on video" |

**Files**: `SettingsAccordionView.swift`

---

### 3.2 Progress Indication During Cleanup

**Current**: Buttons disable, spinner shows, no text
**Target**: "Moving files..." status text

**Implementation**:
```swift
if isProcessing {
    HStack {
        ProgressView()
            .controlSize(.small)
        Text("Moving \(processedCount)/\(totalCount) files...")
            .font(.caption)
    }
}
```

**Files**: `CleanupOriginalFilesDialog.swift`

---

### 3.3 File Size Context

**Current**: Shows "4.2 GB" with no context
**Target**: Add comparison to available space

**Implementation**:
```swift
Text("\(fileCount) files • \(fileSize)")
Text("Free up \(fileSize) of disk space")
    .font(.caption)
    .foregroundColor(.secondary)
```

**Files**: `CleanupOriginalFilesDialog.swift`

---

### 3.4 Truncation Tooltips

**Current**: Long names truncate silently
**Target**: Full text in tooltip

**Implementation**:
```swift
Text(deviceName)
    .lineLimit(1)
    .truncationMode(.tail)
    .help(deviceName) // Full text on hover
```

**Files**: Apply throughout Settings views

---

## Phase 4: Polish (Nice to Have)

### 4.1 Undo for Settings Changes

- Track changes per-section
- Add "Revert Section" button
- Register with system Undo manager

### 4.2 Animation Refinements

- Smooth channel linking animation
- Fade transitions between optimization states
- Scale effect on successful actions

### 4.3 Keyboard Navigation

- Tab between editable fields
- Arrow keys to adjust timecode
- Enter to confirm, Escape to cancel

### 4.4 Accessibility

- VoiceOver labels for all controls
- Keyboard-only operation support
- High contrast mode support

---

## Implementation Order

```
Week 1: Phase 1 (Critical)
├── 1.1 Channel drag-to-link
├── 1.2 Trash confirmation alert
├── 1.3 Cleanup two-step modal
└── 1.4 Timecode field editing

Week 2: Phase 2 (High Priority)
├── 2.1 Output row always-editable
├── 2.2 Stereo pair warning
├── 2.3 Channel state badges
├── 2.4 Select All Optimizable
└── 2.5 Device channel feedback

Week 3: Phase 3 + 4 (Polish)
├── 3.1-3.4 Tooltips, progress, context
└── 4.1-4.4 Undo, animations, a11y
```

---

## Files to Modify

| File | Phases | Changes |
|------|--------|---------|
| `SettingsAccordionView.swift` | 1,2,3 | Channel grid, output rows, tooltips |
| `CleanupOriginalFilesDialog.swift` | 1,3 | Confirmation, progress text |
| `OptimizationSheetView.swift` | 1,2 | Two-step modal, select all |
| `OptimizationViewModel.swift` | 1 | Cleanup flow state |
| `AudioOutputMappingView.swift` | 2 | Stereo warning |
| `TimecodeTextField.swift` | 1 | New component |
| `LayoutConstants.swift` | All | New constants |

---

## Acceptance Criteria

### Phase 1 Complete When:
- [ ] User can drag between channels to link them
- [ ] "Move to Trash" shows confirmation alert
- [ ] Optimization completion shows cleanup options inline
- [ ] Timecode fields are editable with format validation

### Phase 2 Complete When:
- [ ] Output names are always-visible text fields
- [ ] Stereo mode shows warning before locking adjacent channel
- [ ] Channel states show clear badges (M, L, R)
- [ ] "Select All Optimizable" button works correctly
- [ ] Device with no channels shows explanation text

### Phase 3 Complete When:
- [ ] All settings have helpful tooltips
- [ ] Cleanup shows "Moving files..." progress
- [ ] File sizes show disk space context
- [ ] Long names show full text in tooltip

---

## Open Questions for User

1. **Channel linking**: Should linked channels save to project or be session-only?
2. **Cleanup preference**: Should there be "Remember my choice" checkbox?
3. **Timecode framerate**: Should it auto-detect from project settings?

---

## Research Sources

- [Apple HIG - Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)
- [Apple HIG - Direct Manipulation](https://developer.apple.com/design/human-interface-guidelines/inputs)
- [Logic Pro X - Stereo Channels](https://support.apple.com/guide/logicpro/)
- [Final Cut Pro - Optimize Media](https://support.apple.com/guide/final-cut-pro/)
