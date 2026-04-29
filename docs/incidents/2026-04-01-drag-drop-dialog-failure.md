# Incident: Drag-and-Drop Dialog Failure

**Date**: 2026-04-01
**Severity**: CRITICAL
**Status**: RESOLVED

## Summary

Dragging files from Finder onto the timeline showed a broken dialog with only "OK" button and no message. The intended sheet (SpotMediaSheet) would either never appear or flash briefly and disappear.

## Impact

- Core user workflow completely broken
- Drag-and-drop video to timeline unusable
- Affected all sheet-type dialogs: spotMedia, embeddedTimecode, videoInsert, batchTimecode

## Root Cause

The `AlertCoordinatorModifier` in `AlertCoordinator.swift` had a design flaw where the `.alert(item:)` modifier received ALL alert types (including sheet types). When a sheet type was set, the alert modifier matched it and returned:

```swift
case .embeddedTimecode, .videoInsert, .batchTimecode, .spotMedia, .saveProject, .settings:
    // These are sheets, handled below
    return Alert(title: Text(""))  // EMPTY ALERT!
```

This empty alert:
1. Appeared with only an "OK" button
2. Blocked the UI before the intended sheet could display
3. When dismissed, cleared `activeAlert`, preventing the sheet from showing

## 5 Whys Analysis

1. **Why did an empty dialog appear?** → The `.alert()` modifier returned `Alert(title: Text(""))` for sheet types
2. **Why did it return an empty alert?** → Sheet types were included in the switch statement with a fallback empty alert
3. **Why were sheet types in the alert switch?** → The binding passed ALL types to `.alert()`, not just alert types
4. **Why did it pass all types?** → The binding was `$coordinator.activeAlert` directly, without filtering
5. **Why wasn't there filtering?** → The `.sheet()` modifier had filtering, but `.alert()` was overlooked

## Fix Applied

Wrapped the `.alert(item:)` binding in a filter that only returns actual alert types:

```swift
.alert(item: Binding(
    get: {
        guard let alert = coordinator.activeAlert else { return nil }
        switch alert {
        case .error, .videoAlreadyInTimeline, .audioAlreadyInTimeline,
             .duplicateMedia, .missingFile, .fpsConflict:
            return alert  // These are alerts
        case .embeddedTimecode, .videoInsert, .batchTimecode,
             .spotMedia, .saveProject, .settings:
            return nil    // These are sheets, don't show as alerts
        }
    },
    set: { coordinator.activeAlert = $0 }
))
```

## Files Modified

- `Projector/Coordinators/AlertCoordinator.swift` (lines 150-215)

## Why Was This Missed by Audits?

Code audits check for:
- Syntax errors
- Type safety
- Layer violations
- Documentation

They do NOT check:
- Runtime behavior
- SwiftUI modifier interactions
- Dialog flow timing

**Lesson**: Runtime testing (Cecilia) must be done, not just code review (Clare).

## Prevention

1. Added this incident to `docs/incidents/` for future reference
2. Clare agent should flag any `.alert(item:)` with mixed types
3. Cecilia testing is mandatory before declaring features complete
