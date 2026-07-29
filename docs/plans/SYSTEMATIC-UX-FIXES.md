# Systematic UX Fixes Plan

**Status**: Ready for Implementation
**Date**: 2026-04-28
**Branch**: `feature/cue-sheet-from-audio`

---

## Executive Summary

This plan addresses 6 UX issues identified through comprehensive audit and research, organized into 3 phases by priority. The fixes ensure TextField keyboard shortcuts work correctly, labels match functionality, and user interactions are discoverable.

---

## Problem Summary

| # | Issue | Impact | Root Cause |
|---|-------|--------|------------|
| 1 | TextField keyboard shortcuts broken | Critical | Edit menu items target AppDelegate instead of using NSResponder chain |
| 2 | "Optimize" button opens consolidation | High | Mislabeled button in ConsolidateMediaButton.swift |
| 3 | Mono channel activation hidden | High | Only available in context menu; double-click undiscoverable |
| 4 | Channel name doesn't save on blur | Medium | Missing onFocusChange handler |
| 5 | Optimization file selection not discoverable | Medium | No hover states, no alternating rows |
| 6 | Project save overwrite is binary | Low | Works but could use NSSavePanel directly |

---

## Phase 1: Critical Fixes

### 1.1 Fix TextField Keyboard Support via NSResponder Chain

**Problem**: CMD+C/V/X/A/Z do not work in TextFields across 10+ views.

**Root Cause**: In `ProjectorApp.swift` (lines 221-305), the Edit menu items set `target = self`, forcing ALL keyboard shortcuts to route to AppDelegate even when a TextField has focus.

**Solution**: Use standard NSResponder selectors without explicit target - responder chain routes to first responder (TextField if focused).

**Files to Modify**:
- `Projector/ProjectorApp.swift` - Lines 217-305

**Acceptance Criteria**:
- [ ] CMD+C copies selected text from any TextField
- [ ] CMD+V pastes into any focused TextField
- [ ] CMD+X cuts selected text
- [ ] CMD+A selects all text in focused TextField
- [ ] CMD+Z undoes text changes in TextField
- [ ] CMD+S still saves the project (unchanged behavior)

---

### 1.2 Fix "Optimize" Button Label (Should be "Consolidate")

**Problem**: Button in FileManagerView header says "Optimize" but opens ConsolidationSheetView.

**Files to Modify**:
- `Projector/Views/FileManager/ConsolidateMediaButton.swift`

**Changes**:
- Label: "Optimize" → "Consolidate"
- Icon: `bolt.fill` → `arrow.down.doc.fill`
- Help text: Update to describe consolidation

**Acceptance Criteria**:
- [ ] Button label says "Consolidate"
- [ ] Icon matches consolidation concept
- [ ] Help tooltip describes consolidation

---

### 1.3 Add Visible Mono Channel Activation

**Problem**: Creating a mono channel requires finding the hidden context menu.

**Files to Modify**:
- `Projector/Views/SettingsAccordionView.swift` - ChannelCellView

**Solution**: Add a visible "M" button that appears on hover for inactive channels.

**Acceptance Criteria**:
- [ ] Hovering over inactive channel shows activation option
- [ ] Clicking the option activates channel as mono
- [ ] Double-click still works (preserve existing behavior)
- [ ] Context menu still works (preserve existing behavior)

---

## Phase 2: Save Flow Improvements

### 2.1 Keep SaveProjectSheet (No Changes)

**Decision**: Keep custom SaveProjectSheet because:
1. The folder structure (`ProjectName/ProjectName.projector`) is intentional
2. Custom UI allows showing preview of what will be created
3. Current overwrite handling works correctly

---

## Phase 3: UX Polish

### 3.1 Channel Name Save-on-Blur

**Problem**: Editing a name requires pressing Enter to save. Clicking away loses changes.

**Files to Modify**:
- `Projector/Views/Timeline/AudioLaneView.swift`
- `Projector/Views/SettingsAccordionView.swift` - OutputRowView

**Solution**: Add `.onChange(of: isNameFieldFocused)` to commit on blur.

**Acceptance Criteria**:
- [ ] Editing lane name and clicking away saves the name
- [ ] Editing output name and clicking away saves the name
- [ ] Pressing Escape still cancels
- [ ] Pressing Enter still commits

---

### 3.2 Improve Optimization File Selection Visibility

**Problem**: File selection checkboxes are not visually discoverable.

**Files to Modify**:
- `Projector/Views/Optimization/OptimizationSheetView.swift` - FileAnalysisRow

**Solution**: Add hover states, alternating rows, cursor changes.

**Acceptance Criteria**:
- [ ] Rows have alternating backgrounds
- [ ] Hovering over a row highlights it
- [ ] Cursor changes to pointer on hover
- [ ] Clicking anywhere on row toggles selection

---

## Implementation Order

```
Phase 1: Critical (Do First)
├── 1.1 Fix NSResponder chain in ProjectorApp.swift
├── 1.2 Fix ConsolidateMediaButton label
└── 1.3 Add mono activation button

Phase 3: Polish (Do Second)
├── 3.1 Add save-on-blur to AudioLaneView
├── 3.1 Add save-on-blur to OutputRowView
└── 3.2 Add selection affordances to OptimizationSheetView
```

---

## Files Summary

| File | Changes |
|------|---------|
| `ProjectorApp.swift` | Edit menu NSResponder chain fix |
| `ConsolidateMediaButton.swift` | Label and icon fix |
| `SettingsAccordionView.swift` | Mono button + output name save-on-blur |
| `AudioLaneView.swift` | Lane name save-on-blur |
| `OptimizationSheetView.swift` | Selection affordances |

---

## Testing Checklist

### TextField Keyboard Shortcuts
- [ ] Start app, click in any TextField
- [ ] CMD+A selects all text
- [ ] CMD+C copies text
- [ ] CMD+V pastes text
- [ ] CMD+X cuts selection
- [ ] CMD+Z undoes
- [ ] CMD+S still saves project

### Consolidate Button
- [ ] Button says "Consolidate" (not "Optimize")
- [ ] Opens ConsolidationSheetView

### Mono Channel Activation
- [ ] Hover over inactive channel shows "M" button
- [ ] Clicking creates mono output
- [ ] Double-click and right-click still work

### Save-on-Blur
- [ ] Edit lane name, click away → saved
- [ ] Edit output name, click away → saved
- [ ] Escape cancels edit

### Optimization Selection
- [ ] Rows have alternating backgrounds
- [ ] Hover shows highlight
- [ ] Cursor changes on selectable rows
