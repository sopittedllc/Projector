# Projector UI Design System

**Version**: 1.0.0
**Last Updated**: 2026-03-30
**Status**: Foundation Complete, Enforcement In Progress

---

## Table of Contents

1. [Overview](#overview)
2. [Spacing System](#spacing-system)
3. [Layout Constants](#layout-constants)
4. [Liquid Glass Styling](#liquid-glass-styling)
5. [Button Styles](#button-styles)
6. [Panel Patterns](#panel-patterns)
7. [Drag-Drop Zones](#drag-drop-zones)
8. [Before/After Examples](#beforeafter-examples)
9. [Quick Reference](#quick-reference)

---

## Overview

The Projector design system enforces consistency across all 77 Swift files through:

- **LayoutConstants.swift** - Centralized spacing, dimensions, and layout values
- **LiquidGlassStyles.swift** - macOS Tahoe-compatible glass effects and button styles

**Goal**: Eliminate magic numbers and ensure visual consistency across the entire app.

**Current Status**: 167 violations detected. Target: <10 violations.

---

## Spacing System

### The 4pt Grid

All spacing follows a 4pt grid system for visual harmony.

| Constant | Value | Use Case | Example |
|----------|-------|----------|---------|
| `Spacing.xs` | 4pt | Tightly related items | Icon-to-label spacing |
| `Spacing.sm` | 8pt | Related controls | Button groups, control clusters |
| `Spacing.md` | 12pt | Standard content padding | Panel content padding |
| `Spacing.lg` | 16pt | Between sections | Separating major UI sections |
| `Spacing.xl` | 20pt | Major section breaks | Between transport and timeline |
| `Spacing.xxl` | 24pt | Panel margins | Outer margins for modals/panels |

### Usage Examples

**✅ CORRECT**:
```swift
VStack(spacing: Spacing.md) {
    Text("Title")
    Text("Subtitle")
}
.padding(Spacing.lg)
```

**❌ INCORRECT**:
```swift
VStack(spacing: 12) {  // Magic number!
    Text("Title")
    Text("Subtitle")
}
.padding(16)  // Magic number!
```

### When to Use Each Spacing

- **xs (4pt)**: Icon next to text, very compact UI elements
- **sm (8pt)**: Buttons in a toolbar, controls in a group
- **md (12pt)**: Default panel content padding, list item spacing
- **lg (16pt)**: Separating distinct sections within a panel
- **xl (20pt)**: Major vertical gaps (between transport bar and timeline)
- **xxl (24pt)**: Outer margins for sheets, modals, large panels

---

## Layout Constants

### Panel Layout

Standard dimensions for all collapsible panels (Timeline, Media Library, Settings).

| Constant | Value | Use Case |
|----------|-------|----------|
| `PanelLayout.headerHeight` | 44pt | **ALL** panel headers (consistent clickable area) |
| `PanelLayout.footerHeight` | 32pt | Panel footers (hint text, status bars) |
| `PanelLayout.minContentHeight` | 80pt | Minimum content area before scrolling |
| `PanelLayout.cornerRadius` | 8pt | All panel corners |
| `PanelLayout.borderWidth` | 1pt | Panel borders |
| `PanelLayout.borderOpacity` | 0.2 | Panel border transparency |

**Usage**:
```swift
// Panel header
HStack {
    Text("Timeline")
    Spacer()
    Button("Collapse") { }
}
.frame(height: PanelLayout.headerHeight)  // ✅ Standard header height
.padding(.horizontal, Spacing.md)
```

### Timeline Layout

Timeline-specific dimensions.

| Constant | Value | Use Case |
|----------|-------|----------|
| `TimelineLayout.headerWidth` | 120pt | Track/lane header width (Video, Audio lanes) |
| `TimelineLayout.playheadHeaderWidth` | 80pt | Playhead/ruler header width (narrower) |
| `TimelineLayout.videoTrackHeight` | 60pt | Height of video track |
| `TimelineLayout.audioLaneHeight` | 60pt | Height of each audio lane |
| `TimelineLayout.rulerHeight` | 24pt | Timecode ruler height |
| `TimelineLayout.toolbarHeight` | 40pt | Timeline toolbar (zoom controls, actions) |
| `TimelineLayout.videoClipHeight` | 42pt | Video reel clip height |
| `TimelineLayout.audioClipHeight` | 50pt | Audio clip height |
| `TimelineLayout.audioClipHeaderHeight` | 18pt | Audio clip filename bar |
| `TimelineLayout.thumbnailWidth` | 48pt | Video reel thumbnail width |

**Usage**:
```swift
// Video track
VStack(spacing: 0) {
    // Track content
}
.frame(height: TimelineLayout.videoTrackHeight)  // ✅ Standard track height
```

### File Manager Layout

Media library panel dimensions.

| Constant | Value | Use Case |
|----------|-------|----------|
| `FileManagerLayout.collapsedHeight` | 44pt | Collapsed (header only) |
| `FileManagerLayout.expandedHeight` | 140pt | Expanded with media grid |
| `FileManagerLayout.gridThumbnailWidth` | 64pt | Grid cell thumbnail width |
| `FileManagerLayout.gridThumbnailHeight` | 48pt | Grid cell thumbnail height |
| `FileManagerLayout.gridLabelWidth` | 80pt | Grid cell label width |

### Transport Layout

Transport bar dimensions.

| Constant | Value | Use Case |
|----------|-------|----------|
| `TransportLayout.controlBoxHeight` | 48pt | Height of transport control boxes |

---

## Liquid Glass Styling

### Panel Backgrounds

Use `.glassPanel()` for all major panels (Timeline, File Manager, Settings).

**✅ CORRECT**:
```swift
VStack {
    Text("Panel Content")
}
.padding(Spacing.lg)
.glassPanel()  // ✅ Applies Liquid Glass + border
```

**❌ INCORRECT**:
```swift
VStack {
    Text("Panel Content")
}
.padding(16)
.background(Color.gray.opacity(0.3))  // ❌ Custom background
.cornerRadius(8)
```

### Control Backgrounds

Use `.glassControl()` for small control groups (timecode displays, FPS indicators).

**✅ CORRECT**:
```swift
HStack {
    Text("TC:")
    Text("01:00:00:00")
        .font(.system(size: 12, design: .monospaced))
}
.padding(.horizontal, Spacing.sm)
.padding(.vertical, 6)
.glassControl()  // ✅ Subtle glass control style
```

### macOS 26+ vs Fallback

The design system automatically uses native `.glassEffect()` on macOS 26+ (Tahoe) and falls back to `NSVisualEffectView` on older versions. You don't need to handle this in your views—just use `.glassPanel()` and `.glassControl()`.

---

## Button Styles

### Standard Buttons

Use **one of four standard button styles** for all buttons:

| Style | Use Case | Visual |
|-------|----------|--------|
| `GlassButtonStyle` | General purpose buttons | Rounded rectangle, subtle glass |
| `GlassTransportButtonStyle` | Transport controls (play, stop) | Circular, active state tint |
| `GlassActionButtonStyle` | Action buttons (Import, Optimize) | Capsule shape, prominent tint |
| `GlassMenuButtonStyle` | (Future) Dropdown menus | TBD |

### GlassButtonStyle

**Use for**: General purpose buttons, settings toggles, non-critical actions

**✅ CORRECT**:
```swift
Button("Save Changes") {
    save()
}
.buttonStyle(GlassButtonStyle())
```

**With tint**:
```swift
Button("Delete") {
    delete()
}
.buttonStyle(GlassButtonStyle(tint: .red))
```

### GlassTransportButtonStyle

**Use for**: Play, pause, stop, seek, transport-related controls

**✅ CORRECT**:
```swift
Button(action: { play() }) {
    Image(systemName: "play.fill")
        .frame(width: 16, height: 16)
}
.buttonStyle(GlassTransportButtonStyle(isActive: isPlaying))
```

**Features**:
- Circular shape (not rounded rectangle)
- Active state shows accent color tint
- Spring animation on press (0.3s response)

### GlassActionButtonStyle

**Use for**: Primary actions (Import, Optimize, Batch Timecode, Consolidate)

**✅ CORRECT**:
```swift
Button("Import Media") {
    showImportSheet()
}
.buttonStyle(GlassActionButtonStyle(tint: .accentColor))
```

**With custom tint**:
```swift
Button("Optimize All") {
    optimizeAll()
}
.buttonStyle(GlassActionButtonStyle(tint: .green))
```

**Features**:
- Capsule shape (fully rounded ends)
- Medium font weight (11pt)
- Prominent tint for primary actions

---

## Panel Patterns

### Standard Panel Structure

All collapsible panels follow this structure:

```swift
VStack(spacing: 0) {
    // HEADER (44pt)
    HStack {
        Text("Panel Title")
            .font(.headline)
        Spacer()
        Button("Action") { }
            .buttonStyle(GlassActionButtonStyle())
    }
    .frame(height: PanelLayout.headerHeight)  // ✅ Standard header
    .padding(.horizontal, Spacing.md)
    .background(Color.black.opacity(0.2))  // Header background
    .overlay(  // Bottom border
        Rectangle()
            .frame(height: 1)
            .foregroundColor(.white.opacity(0.1)),
        alignment: .bottom
    )

    // CONTENT
    if isExpanded {
        contentView
            .frame(minHeight: PanelLayout.minContentHeight)
    }

    // FOOTER (optional, 32pt)
    HStack {
        Text("Status: Ready")
            .font(.caption)
            .foregroundColor(.secondary)
        Spacer()
    }
    .frame(height: PanelLayout.footerHeight)  // ✅ Standard footer
    .padding(.horizontal, Spacing.md)
}
.glassPanel()  // ✅ Liquid Glass background
```

### Panel Header Best Practices

1. **Always use `PanelLayout.headerHeight`** - Consistent clickable area
2. **Horizontal padding**: `Spacing.md` (12pt)
3. **Bottom border**: 1pt white at 0.1 opacity
4. **Background**: `Color.black.opacity(0.2)` to differentiate from content

### Accordion Panels

For expandable/collapsible panels:

```swift
@State private var isExpanded = true

VStack(spacing: 0) {
    // Header with chevron
    Button(action: { isExpanded.toggle() }) {
        HStack {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .foregroundColor(.secondary)
            Text("Timeline")
                .font(.headline)
            Spacer()
        }
    }
    .buttonStyle(.plain)
    .frame(height: PanelLayout.headerHeight)  // ✅ Standard
    .padding(.horizontal, Spacing.md)

    // Expandable content
    if isExpanded {
        contentView
    }
}
.glassPanel()
```

---

## Drag-Drop Zones

### Finder Drop Zones

For drop zones accepting files from Finder:

**✅ CORRECT**:
```swift
@State private var isTargeted = false

Rectangle()
    .fill(Color.clear)
    .frame(height: 100)
    .overlay(
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                lineWidth: 2,
                lineCap: .round,
                dash: [5, 5]
            )
    )
    .background(
        isTargeted ?
            Color.accentColor.opacity(0.1) :
            Color.clear
    )
    .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
        // Handle drop
        return true
    }
```

**Features**:
- Dashed border (5pt dash, 5pt gap)
- Accent color when targeted
- Subtle background tint (0.1 opacity) when targeted
- Corner radius: 8pt (matches panel corners)

### Internal Drag-Drop (Timeline Reordering)

For internal drag-drop (reordering clips, lanes):

**✅ CORRECT** (same styling as Finder):
```swift
// Use identical visual styling for consistency
.overlay(
    RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
            isTargeted ? Color.accentColor : Color.clear,
            lineWidth: 2
        )
)
.background(
    isTargeted ?
        Color.accentColor.opacity(0.1) :
        Color.clear
)
```

**Critical**: Finder and internal drop zones MUST use identical styling. This eliminates user confusion.

---

## Before/After Examples

### Example 1: Hardcoded Spacing

**❌ BEFORE**:
```swift
VStack(spacing: 16) {
    Text("Title")
    Text("Subtitle")
}
.padding(20)
```

**✅ AFTER**:
```swift
VStack(spacing: Spacing.lg) {  // 16pt named constant
    Text("Title")
    Text("Subtitle")
}
.padding(Spacing.xl)  // 20pt named constant
```

### Example 2: Custom Button Styling

**❌ BEFORE**:
```swift
Button("Import") {
    importFiles()
}
.padding(.horizontal, 12)
.padding(.vertical, 6)
.background(Color.blue.opacity(0.2))
.cornerRadius(16)
```

**✅ AFTER**:
```swift
Button("Import") {
    importFiles()
}
.buttonStyle(GlassActionButtonStyle(tint: .accentColor))
```

### Example 3: Panel Background

**❌ BEFORE**:
```swift
VStack {
    Text("Panel Content")
}
.padding(16)
.background(
    RoundedRectangle(cornerRadius: 8)
        .fill(Color.gray.opacity(0.3))
)
.overlay(
    RoundedRectangle(cornerRadius: 8)
        .stroke(Color.white.opacity(0.2), lineWidth: 1)
)
```

**✅ AFTER**:
```swift
VStack {
    Text("Panel Content")
}
.padding(Spacing.lg)  // 16pt spacing constant
.glassPanel()  // Applies all glass styling + border
```

### Example 4: Panel Header Height

**❌ BEFORE**:
```swift
HStack {
    Text("Timeline")
    Spacer()
}
.frame(height: 44)  // Magic number!
.padding(.horizontal, 12)  // Magic number!
```

**✅ AFTER**:
```swift
HStack {
    Text("Timeline")
    Spacer()
}
.frame(height: PanelLayout.headerHeight)  // Standard 44pt
.padding(.horizontal, Spacing.md)  // Standard 12pt
```

---

## Quick Reference

### Import Statement

```swift
// All view files should import:
import SwiftUI
// Layout constants are automatically available (no extra import needed)
```

### Most Common Patterns

```swift
// Panel with header
VStack(spacing: 0) {
    // Header
    HStack { /* ... */ }
        .frame(height: PanelLayout.headerHeight)
        .padding(.horizontal, Spacing.md)

    // Content
    content
}
.glassPanel()

// Action button
Button("Import") { }
    .buttonStyle(GlassActionButtonStyle())

// Control group
HStack {
    Text("TC: 01:00:00:00")
}
.padding(.horizontal, Spacing.sm)
.padding(.vertical, 6)
.glassControl()

// Standard spacing
VStack(spacing: Spacing.md) { }
HStack(spacing: Spacing.sm) { }
```

### Checklist for New Views

Before committing a new view, verify:

- [ ] All spacing uses `Spacing.*` constants (no raw numbers)
- [ ] All panel headers use `PanelLayout.headerHeight`
- [ ] All buttons use Glass*ButtonStyle
- [ ] All panel backgrounds use `.glassPanel()`
- [ ] All control groups use `.glassControl()`
- [ ] All timeline elements use `TimelineLayout.*` constants
- [ ] No hardcoded colors (use semantic colors or design system tints)
- [ ] Drag-drop zones use standard styling

### Running the Audit

To check for violations:

```bash
cd ~/Projector
./scripts/ui-audit.sh
```

Target: <10 violations for production readiness.

---

## Roadmap

### Current Status (v1.0)
- ✅ Design system defined (LayoutConstants.swift, LiquidGlassStyles.swift)
- ✅ Audit script created
- ✅ Documentation complete
- ⚠️ 167 violations detected (systematic refactor needed)

### Next Steps (Phase 0.2)
1. Systematically refactor all views (priority order):
   - TransportBarView
   - Timeline views (MultiTrackTimelineView, AudioLaneView, VideoTrackView)
   - Settings panels
   - Modals/sheets
   - File Manager
2. Re-run audit → target <10 violations
3. Create Component Catalog (optional, Phase 0.3)

---

## Questions?

If you're unsure which constant to use:
1. Check this document's examples
2. Look at `LayoutConstants.swift` for available options
3. Run `./scripts/ui-audit.sh` to identify violations
4. Refer to existing "good" examples (files with 0 violations)

---

**Last Updated**: 2026-03-30
**Audit Status**: 167 violations → Target: <10
