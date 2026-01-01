# Projector - Claude Code Instructions

## UI Change Checklist

Before declaring a UI change complete:

1. **Check all view states** - Look for `if/else` branches in the view (editing, loading, hasVideo, etc.) and verify each one
2. **Search for hardcoded sizes** - Look for `.frame(width:)`, `.frame(height:)` and verify they still make sense
3. **Build, launch, and visually verify** - Don't just build; actually look at the result
4. **Test interactions** - If the component has tap/click/edit behavior, test those states too

## SwiftUI Layout Rules

### Padding and Margins

1. **Padding is INSIDE the view's allocated space, not outside it**
   - Adding `.padding()` to a child view does NOT expand its parent container
   - The padding creates space within the child's already-allocated frame
   - Content can get clipped if the parent doesn't allocate enough space

2. **GeometryReader with hardcoded heights**
   - When using `GeometryReader` with calculated heights like `let transportHeight: CGFloat = 120`, any padding added to child views must be accounted for in these calculations
   - If you add 16px padding around a view, increase the height constant accordingly

3. **To add margin around a component**:
   - Add `.padding()` to the component in its PARENT view (e.g., ContentView), not inside the component itself
   - Update any hardcoded height calculations to accommodate the padding
   - Example: TransportBarView margin is set in ContentView, not in TransportBarView.swift

4. **Background and padding order matters**:
   - `.padding().background()` - background fills the padded area
   - `.background().padding()` - background only fills original content, padding is outside

### Current Layout Structure

```
ContentView (GeometryReader)
└── VStack(spacing: 0)
    ├── VideoContentView (height: calculated)
    ├── Divider
    └── HStack (padding: 16) ← margin from window edges
        └── TransportBarView (padding: 12, rounded background)
            └── HStack (content)
```

- `transportHeight = 120` accounts for TransportBarView content + internal padding (12) + external margin (16)
