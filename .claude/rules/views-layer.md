# Views Layer Rules

> **Path Pattern**: `Projector/Views/**/*.swift`

## Auto-Trigger

When editing files in `Views/`:
- **MUST use joseph** for implementation
- **MUST run clare** before committing changes
- **MUST run cecilia** if changes affect user-facing UI

## Layer Constraints

Files in this layer:
- ❌ CANNOT import CoreMIDI
- ❌ CANNOT import CoreAudio directly
- ✅ CAN use AVFoundation only for AVPlayerLayer
- ✅ MUST follow macOS HIG

## Performance Rules

- [ ] No computation in view body
- [ ] No tap gestures in ScrollView content
- [ ] Use .drawingGroup() for complex graphics
- [ ] Pre-sort data in ViewModel

## Pre-Commit Checklist

Before committing changes to Views/:
- [ ] No CoreMIDI imports
- [ ] View body is pure (no side effects)
- [ ] Accessibility labels present
- [ ] Keyboard navigation works
