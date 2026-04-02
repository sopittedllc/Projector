# Incident: UI Issues Batch Fix

**Date**: 2026-04-01
**Severity**: HIGH
**Status**: RESOLVED

## Summary

Multiple UI issues were identified after the drag-drop dialog fix that were not caught by static code audits:

1. Settings icon showing "OK" dialog then flashing another
2. Transport control icons (circular play/stop) looking unprofessional
3. Double lines at bottom of timeline area
4. "Double click regions" text not vertically centered
5. Duplicate "Heavy Media Detected" optimization banners

## Why Static Audits Missed These

Static code audits (Clare, etc.) check:
- Syntax errors
- Type safety
- Layer violations
- Documentation coverage

They do NOT:
- Run the actual application
- Click UI elements
- Observe visual layout
- Test user flows

**Lesson**: Runtime UI testing is mandatory. No feature is complete until someone actually uses it.

## Fixes Applied

### 1. Settings Dialog Conflict

**Root Cause**: ContentView had TWO sheet mechanisms for settings:
- `AlertCoordinator.swift` handled `.settings` in its `.sheet(item:)` binding
- `ContentView.swift` had a separate `.sheet(isPresented:)` for settings

Both fired simultaneously, showing EmptyView then SettingsView.

**Fix**: Removed `.settings` from AlertCoordinator's sheet binding, letting ContentView's dedicated sheet handle it.

**File**: `Projector/Coordinators/AlertCoordinator.swift` (lines 219-232)

### 2. Transport Control Icons

**Root Cause**: `GlassTransportButtonStyle` used `Circle()` for button backgrounds, which looked unprofessional for play/stop controls.

**Fix**: Changed to `RoundedRectangle(cornerRadius: 6)` for a cleaner look.

**File**: `Projector/Views/LiquidGlassStyles.swift` (lines 125-160)

### 3. Double Lines at Timeline Bottom

**Root Cause**:
- `.glassPanel()` modifier adds a border around the panel
- `timelineResizeHandle` added another visible line

**Fix**: Changed resize handle to only show the accent color line when actively resizing, otherwise relying on the glass panel border.

**File**: `Projector/Views/TimelineAccordionView.swift` (lines 204-220)

### 4. Text Vertical Centering

**Root Cause**: The `timelineHint` view's HStack didn't have explicit vertical alignment, and `.padding(.bottom:)` after `.frame()` shifted the frame, not the content.

**Fix**: Added `alignment: .center` to HStack and combined the footer height with padding into a single frame.

**File**: `Projector/Views/TimelineAccordionView.swift` (lines 81-93)

### 5. Duplicate Optimization Banners

**Root Cause**: The `evaluateOptimizationSuggestion()` function ran on every `mediaLibrary.items.count` change. When user dismissed the banner, if items.count changed again, the banner reappeared.

**Fix**: Added session-level dismissal tracking (`dismissedSuggestionTypes` Set) that prevents re-showing dismissed suggestion types during the current session.

**File**: `Projector/Views/FileManager/FileManagerView.swift` (lines 55-57, 75-99, 670-680)

## Prevention

1. **Runtime testing before declaring complete**: Every UI feature must be manually tested
2. **Document visual expectations**: Screenshots or mockups should be reviewed
3. **Test user flows end-to-end**: Don't just verify code compiles - use the feature
