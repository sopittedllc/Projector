# Managers Layer Rules

> **Path Pattern**: `Projector/Managers/**/*.swift`

## Auto-Trigger

When editing files in `Managers/`:
- **MUST use joseph** for implementation
- **MUST run clare** before committing changes
- **SHOULD run thomas** if touching MIDI/MTC/MMC code

## Layer Constraints

Files in this layer:
- ❌ CANNOT import SwiftUI
- ❌ CANNOT use @MainActor for MIDI processing
- ✅ MUST use Swift Actors for state
- ✅ MUST have DocC documentation

## Pre-Commit Checklist

Before committing changes to Managers/:
- [ ] No SwiftUI imports
- [ ] State in actors (not classes)
- [ ] Real-time callbacks don't block
- [ ] Error handling for all throws
- [ ] DocC on public APIs
