import SwiftUI
import SwiftTimecodeCore

// MARK: - Design System
// Centralized design tokens to eliminate magic numbers and ensure consistency.
// All view files should import these instead of defining local values.

// ============================================================================
// MARK: - Typography System
// ============================================================================

/// Semantic typography scale for consistent text styling across the app.
///
/// ## Usage
/// ```swift
/// Text("Timeline")
///     .font(Typography.heading)
///
/// Text("00:00:00:00")
///     .font(Typography.mono)
/// ```
enum Typography {
    // MARK: - Display (Onboarding, Welcome, Large UI)

    /// Hero display text for onboarding (28pt bold rounded)
    static let displayTitle = Font.system(size: 28, weight: .bold, design: .rounded)

    /// Display subtitle for onboarding steps (20pt regular)
    static let displaySubtitle = Font.system(size: 20, weight: .regular)

    /// Display body for onboarding descriptions (18pt regular)
    static let displayBody = Font.system(size: 18, weight: .regular)

    /// Large icon/placeholder text (48pt regular)
    static let displayLarge = Font.system(size: 48, weight: .regular)

    /// Extra large icon text (64pt regular)
    static let displayIcon = Font.system(size: 64, weight: .regular)

    /// Badge text for onboarding (14pt bold rounded)
    static let badge = Font.system(size: 14, weight: .bold, design: .rounded)

    // MARK: - Headings

    /// Large title for modal headers (16pt semibold)
    static let title = Font.system(size: 16, weight: .semibold)

    /// Section headings in panels (13pt medium)
    static let heading = Font.system(size: 13, weight: .medium)

    /// Subsection headings (12pt medium)
    static let subheading = Font.system(size: 12, weight: .medium)

    // MARK: - Body Text

    /// Primary body text (12pt regular)
    static let body = Font.system(size: 12, weight: .regular)

    /// Secondary body text (11pt regular)
    static let bodySmall = Font.system(size: 11, weight: .regular)

    // MARK: - Labels & Captions

    /// Control labels like "Start TC:", "FPS:" (10pt medium)
    static let label = Font.system(size: 10, weight: .medium)

    /// Small labels and badges (9pt medium)
    static let labelSmall = Font.system(size: 9, weight: .medium)

    /// Tiny labels for clips (8pt semibold)
    static let labelTiny = Font.system(size: 8, weight: .semibold)

    /// Caption text for hints and metadata (10pt regular)
    static let caption = Font.system(size: 10, weight: .regular)

    /// Small caption for timestamps (9pt regular)
    static let captionSmall = Font.system(size: 9, weight: .regular)

    // MARK: - Monospace (Timecode & Data)

    /// Primary monospace for timecode display (12pt medium)
    static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)

    /// Large monospace for prominent timecode (16pt medium)
    static let monoLarge = Font.system(size: 16, weight: .medium, design: .monospaced)

    /// Extra large monospace for video overlay timecode (24pt medium)
    static let monoXLarge = Font.system(size: 24, weight: .medium, design: .monospaced)

    /// Display monospace for timeline position (14pt medium)
    static let monoDisplay = Font.system(size: 14, weight: .medium, design: .monospaced)

    /// Small monospace for metadata (10pt regular)
    static let monoSmall = Font.system(size: 10, weight: .regular, design: .monospaced)

    /// Tiny monospace for clip duration badges (9pt medium)
    static let monoTiny = Font.system(size: 9, weight: .medium, design: .monospaced)

    // MARK: - Buttons & Actions

    /// Large button text for primary actions (14pt medium)
    static let buttonLarge = Font.system(size: 14, weight: .medium)

    /// Button text (11pt medium)
    static let button = Font.system(size: 11, weight: .medium)

    /// Small button text (10pt medium)
    static let buttonSmall = Font.system(size: 10, weight: .medium)

    // MARK: - Icons

    /// Standard icon size (12pt)
    static let icon = Font.system(size: 12, weight: .medium)

    /// Small icon size (10pt)
    static let iconSmall = Font.system(size: 10, weight: .semibold)

    /// Tiny icon size (8pt)
    static let iconTiny = Font.system(size: 8, weight: .medium)

    /// Secondary icon on the macOS HIG scale (16pt)
    static let iconMedium = Font.system(size: 16)

    /// Prominent icon on the macOS HIG scale (20pt)
    static let iconLarge = Font.system(size: 20)

    /// Large icon on the macOS HIG scale (24pt)
    static let iconXLarge = Font.system(size: 24)

    /// Decorative glyph for empty states and placeholders (48pt).
    ///
    /// Deliberately outside the HIG control scale - these are illustrative
    /// artwork rather than interactive controls.
    static let iconEmptyState = Font.system(size: 48)

    // NOTE: An icon rendered inline beside a text label should use that label's
    // text token (`caption`, `bodySmall`, ...) so the two stay the same size if
    // the text scale is retuned. The icon tokens above are for standalone icons.
}

// ============================================================================
// MARK: - Color System
// ============================================================================

/// Semantic color palette for consistent styling across the app.
///
/// ## Usage
/// ```swift
/// RoundedRectangle(cornerRadius: 4)
///     .stroke(AppColors.borderSubtle, lineWidth: 1)
///
/// Text("Hint text")
///     .foregroundColor(AppColors.textTertiary)
/// ```
enum AppColors {
    // MARK: - Borders

    /// Very subtle border (10% white) - for inactive elements
    static let borderSubtle = Color.white.opacity(0.1)

    /// Light border (15% white) - for controls and cards
    static let borderLight = Color.white.opacity(0.15)

    /// Standard border (20% white) - for panels
    static let borderMedium = Color.white.opacity(0.2)

    /// Prominent border (30% white) - for focused/hovered elements
    static let borderStrong = Color.white.opacity(0.3)

    // MARK: - Surfaces & Overlays

    /// Subtle surface overlay (5% white)
    static let surfaceSubtle = Color.white.opacity(0.05)

    /// Light surface overlay (10% white)
    static let surfaceLight = Color.white.opacity(0.1)

    /// Medium surface overlay (12% white) - for focused fields
    static let surfaceMedium = Color.white.opacity(0.12)

    /// Strong surface overlay (15% white) - for selection
    static let surfaceStrong = Color.white.opacity(0.15)

    /// Dark overlay for contrast (20% black)
    static let overlayDark = Color.black.opacity(0.2)

    /// Darker overlay (40% black)
    static let overlayDarker = Color.black.opacity(0.4)

    /// Darkest overlay for modals (60% black)
    static let overlayDarkest = Color.black.opacity(0.6)

    // MARK: - Text Colors

    /// Primary text - use sparingly, prefer Color.primary
    static let textPrimary = Color.primary

    /// Secondary text - use sparingly, prefer Color.secondary
    static let textSecondary = Color.secondary

    /// Tertiary text (60% secondary) - for hints
    static let textTertiary = Color.secondary.opacity(0.6)

    /// Muted text (50% secondary) - for disabled states
    static let textMuted = Color.secondary.opacity(0.5)

    // MARK: - Status Colors

    /// Success/active state
    static let success = Color.green

    /// Warning state
    static let warning = Color.yellow

    /// Error/destructive state
    static let error = Color.red

    /// Info/accent state
    static let info = Color.accentColor

    // MARK: - Glass Fallback

    /// Background color for glass effect fallback on pre-macOS 26
    static let glassFallback = Color(red: 30.0 / 255.0, green: 30.0 / 255.0, blue: 30.0 / 255.0)

    // MARK: - Selection

    /// Selection highlight for clips
    static let selectionHighlight = Color.yellow

    /// Selection glow
    static let selectionGlow = Color.white.opacity(0.5)

    /// Multi-select marquee fill
    static let marqueeFill = Color.accentColor.opacity(0.2)

    /// Multi-select marquee border
    static let marqueeBorder = Color.accentColor

    // MARK: - Brand Palette (Logic Pro-inspired)

    /// Primary brand accent - warm magenta/hot pink
    static let accentPink = Color(red: 1.0, green: 0.2, blue: 0.55)

    /// Secondary brand accent - warm blue
    static let accentBlue = Color(red: 0.3, green: 0.5, blue: 1.0)

    /// Tertiary - vibrant green (for success/active states)
    static let accentGreen = Color(red: 0.25, green: 0.7, blue: 0.35)

    /// Tertiary - warm yellow (for warnings/highlights)
    static let accentYellow = Color(red: 0.95, green: 0.85, blue: 0.2)

    /// Tertiary - purple (for special states)
    static let accentPurple = Color(red: 0.7, green: 0.3, blue: 1.0)

    /// Primary accent (defaults to pink)
    static let accent = accentPink

    /// Subtle accent background
    static let accentSubtle = accent.opacity(0.15)

    /// Accent for borders
    static let accentBorder = accent.opacity(0.4)
}

// ============================================================================
// MARK: - Animation System
// ============================================================================

/// Standardized animation curves and durations for consistent motion.
///
/// ## Usage
/// ```swift
/// withAnimation(AppAnimations.standard) {
///     isExpanded.toggle()
/// }
///
/// .animation(AppAnimations.quick, value: isHovered)
/// ```
enum AppAnimations {
    // MARK: - Durations

    /// Instant feedback (0.1s)
    static let durationInstant: Double = 0.1

    /// Quick transitions (0.15s)
    static let durationQuick: Double = 0.15

    /// Standard transitions (0.2s)
    static let durationStandard: Double = 0.2

    /// Slow transitions (0.3s)
    static let durationSlow: Double = 0.3

    // MARK: - Pre-built Animations

    /// Instant feedback animation
    static let instant = Animation.easeOut(duration: durationInstant)

    /// Quick animation for hover/press states
    static let quick = Animation.easeOut(duration: durationQuick)

    /// Standard animation for most UI transitions
    static let standard = Animation.easeInOut(duration: durationStandard)

    /// Slow animation for panel expand/collapse
    static let slow = Animation.easeInOut(duration: durationSlow)

    /// Spring animation for playful interactions
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.6)

    /// Smooth spring for subtle bouncy effects
    static let smoothSpring = Animation.spring(response: 0.4, dampingFraction: 0.8)

    // MARK: - Linear (for meters/progress)

    /// Linear animation for continuous updates (meters, progress)
    static let linear = Animation.linear(duration: 0.05)
}

// ============================================================================
// MARK: - Settings Layout
// ============================================================================

/// Layout constants for the Settings panel.
enum SettingsLayout {
    /// Settings window width
    static let width: CGFloat = 450

    /// Settings window height
    static let height: CGFloat = 650

    /// Settings window size as CGSize
    static let size = CGSize(width: width, height: height)

    /// Fixed width for setting row labels (for alignment)
    static let labelWidth: CGFloat = 100

    /// Size of channel cells in the audio grid
    static let channelCellSize: CGFloat = 48

    /// Spacing between channel cells
    static let channelCellSpacing: CGFloat = 4

    /// Spacing between form label and control in Grid
    static let formRowSpacing: CGFloat = Spacing.sm  // 8pt

    /// Vertical spacing between form rows
    static let formRowVerticalSpacing: CGFloat = Spacing.sm  // 8pt

    /// macOS HIG form spacing: 6pt between trailing labels and leading controls
    static let formLabelControlGap: CGFloat = 6

    /// Window edge margins for settings content
    static let windowMargin: CGFloat = Spacing.xl  // 20pt

    /// Space from section header to content
    static let headerToContentSpacing: CGFloat = 14

    /// Space between sections
    static let sectionSpacing: CGFloat = Spacing.md  // 12pt

    /// Fixed width for form sections (ensures consistent label-control spacing)
    static let formSectionWidth: CGFloat = 240
}

// ============================================================================
// MARK: - Horizontal Layout Constants
// ============================================================================

/// Layout constants for the horizontal split layout (video left, panels right)
enum HorizontalLayoutConstants {
    /// Minimum width for the panel section (transport + timeline + media).
    static let minPanelWidth: CGFloat = 300

    /// Minimum width of the main window.
    ///
    /// Covers the video column plus enough panel width to keep the media
    /// panel's full (non-compact) header controls on screen, plus chrome. The
    /// video term returned when the video moved back into the main window,
    /// beside the accordions rather than above them.
    /// The wider of the two rows decides it: the top row (video column beside
    /// the media panel's full header) or the full-width timeline header.
    static let mainWindowMinWidth: CGFloat = max(
        MainWindowLayout.videoColumnWidth
            + Spacing.md
            + FileManagerLayout.headerFullControlsMinWidth
            + Spacing.md * 2,
        TimelineSectionLayout.headerMinWidth + Spacing.md * 2
    )

    /// Minimum height of the main window.
    static let mainWindowMinHeight: CGFloat = 500

    // NOTE: minVideoWidth / defaultVideoWidth / defaultPanelWidth were removed
    // with the embedded video pane (2026-07-24). All had zero call sites.
}

/// Layout constants for the main app window's grow-on-import behavior.
///
/// The window opens small (see `ContentView`'s `.frame(minWidth:minHeight:)`) before any
/// media exists. Once the timeline and media panels expand to show imported content, the
/// window is grown to these dimensions so the expanded panels aren't squeezed into the
/// original small frame.
enum MainWindowLayout {
    /// Default width on first launch, before the user has resized or a project
    /// has supplied a saved frame. Sized so an empty project shows Settings,
    /// Timeline, and Media with comfortable margins.
    static let defaultWidth: CGFloat = 1440

    /// Size of the video column beside the accordions.
    ///
    /// Fixed, not proportional: the video sits to the left of the panels and
    /// keeps this size as the window grows taller with added lanes, leaving
    /// empty space beneath it rather than stretching. 16:9 at a size that keeps
    /// the whole window inside a 13" laptop's 1470pt width once the panels take
    /// their share.
    ///
    /// The video letterboxes within it (`videoGravity` is `.resizeAspect`), so
    /// these are budgets rather than an aspect commitment - portrait and 4:3
    /// media pillarbox instead.
    static let videoColumnWidth: CGFloat = 480
    /// Height of the picture itself. The controls are a separate section
    /// beneath it, so this is all picture - they used to sit inside this box
    /// and shrink it.
    ///
    /// Height of the picture. Derived: whatever the top row is, less the
    /// controls strip directly beneath it. 480x270 is exactly 16:9, so the
    /// picture fills the column edge to edge with no letterboxing.
    static var inlineVideoHeight: CGFloat { topRowHeight - videoControlsBarHeight }

    /// Height of the control strip beneath the inline picture. No padding
    /// around it - every point spent here is a point off the picture.
    static let videoControlsBarHeight: CGFloat = 36

    /// Height of the whole top row: the video column and the Media panel beside
    /// it are both exactly this tall, which is what makes their bottoms line up
    /// without either being computed from the other's internals.
    static let topRowHeight: CGFloat = 306

    /// Ceiling for the top row (video beside Settings + Media).
    ///
    /// Settings expands to a channel-mapping grid and Media to a thumbnail row
    /// with an optimization banner - together they can run to several hundred
    /// points, which pushed the timeline off the bottom of the screen. Bounded
    /// here and scrolled internally instead, leaving the timeline a predictable
    /// share of the window.
    ///
    /// Sized so the top row, the timeline and window chrome all fit a 13"
    /// laptop's ~900pt of visible height.
    static let topRowMaxHeight: CGFloat = topRowHeight

    /// Default height on first launch.
    ///
    /// Close to what the default layout actually measures (video 240 + panels
    /// ~512 + window chrome 32 = ~784), so the window opens at roughly its
    /// final size instead of coming up short and visibly growing once the
    /// panels report in.
    static let defaultHeight: CGFloat = 800

    /// Height the window's titlebar takes above the content.
    static let titleBarAllowance: CGFloat = 32

    /// Smallest height the window is allowed to shrink to.
    ///
    /// Separate from `defaultHeight`, which used to serve as both. That single
    /// constant could not do both jobs: raising it so the window opened at a
    /// sensible size would also have stopped it shrinking when panels collapse.
    /// This is the fully-collapsed layout - video area plus three panel headers
    /// and their spacing.
    static let minimumHeight: CGFloat = 420

    /// Width the window grows to after the first media import.
    static let expandedWidth: CGFloat = 1400

    /// Height the window grows to after the first media import.
    static let expandedHeight: CGFloat = 900
}

// ============================================================================
// MARK: - Layout Constants
// ============================================================================

/// Timeline layout constants
enum TimelineLayout {
    /// Width of track/lane headers (video track, audio lanes)
    static let headerWidth: CGFloat = 120

    /// Width of playhead/ruler header (narrower than track headers)
    static let playheadHeaderWidth: CGFloat = 80

    /// Height of the video track
    static let videoTrackHeight: CGFloat = 60

    /// Height of each audio lane
    static let audioLaneHeight: CGFloat = 60

    /// Height of the video file's baked-in audio strip.
    ///
    /// A third of a normal lane: it is part of the Video File track, not an
    /// audio lane the user arranges, so it reads as an attachment to the video
    /// rather than a peer of Dialogue, Music and Effects.
    static let linkedAudioStripHeight: CGFloat = 20

    /// Height of the ruler/timecode display
    static let rulerHeight: CGFloat = 24

    /// Height of the toolbar area
    static let toolbarHeight: CGFloat = 40

    /// Height of the new-lane drop zone strip when no drag is in progress
    static let newLaneDropZoneInactiveHeight: CGFloat = 20

    /// Height of video reel clips
    static let videoClipHeight: CGFloat = 42

    /// Height of audio clips
    static let audioClipHeight: CGFloat = 50

    /// Height of audio clip headers (filename bar)
    static let audioClipHeaderHeight: CGFloat = 18

    /// Width of thumbnails in video reels
    static let thumbnailWidth: CGFloat = 48

    /// Spacing between ruler markings
    static let rulerSpacing: CGFloat = 5

    /// Target pixels per major ruler marking
    static let targetPixelsPerMajor: CGFloat = 100

    /// Playhead triangle width
    static let playheadTriangleWidth: CGFloat = 10

    /// Playhead triangle height
    static let playheadTriangleHeight: CGFloat = 8

    /// Margin kept between the playhead and the edge of the visible timeline
    /// before the view scrolls to follow it.
    ///
    /// Acts as a deadband: without it the view would re-scroll on every frame
    /// once the playhead reached an edge, which reads as continuous judder.
    static let playheadFollowInset: CGFloat = 80

    /// Default padding in minutes added to timeline end for workspace
    ///
    /// This provides extra space at the end of the timeline for easier editing
    /// and ensures the last clip isn't flush against the edge.
    static let defaultPaddingMinutes: Double = 20.0
}

// MARK: - Panel Layout Best Practices
// Standard dimensions for collapsible panels (Timeline, Media, etc.)
// These ensure consistent visual rhythm across the app

/// Standard panel layout constants - USE THESE for all collapsible panels
enum PanelLayout {
    /// Standard header height for all collapsible panels
    /// Provides enough vertical space for buttons without crowding
    static let headerHeight: CGFloat = 44

    /// Standard footer height for hint text or status bars
    static let footerHeight: CGFloat = 32

    /// Minimum content area height
    static let minContentHeight: CGFloat = 80

    /// Standard corner radius for panels
    static let cornerRadius: CGFloat = 8

    /// Standard border width
    static let borderWidth: CGFloat = 1

    /// Standard border opacity
    static let borderOpacity: CGFloat = 0.2
}

/// Zoom control constants
enum ZoomConstants {
    /// Minimum zoom level
    static let minZoom: CGFloat = 1.0

    /// Maximum zoom level
    static let maxZoom: CGFloat = 10.0

    /// Default zoom level
    static let defaultZoom: CGFloat = 1.0
}

/// File manager panel constants
enum FileManagerLayout {
    /// Height when collapsed (header only)
    static let collapsedHeight: CGFloat = PanelLayout.headerHeight

    /// Minimum header-bar width for the full (icon + label) header controls.
    /// Below this the header switches to compact icon-only buttons.
    ///
    /// Approximates the measured natural width of the full control set (title
    /// area + filters + prepare media + import + spacing), rounded up so the
    /// switch to compact happens before anything clips. Deliberately left at
    /// its original figure after the search field and sort menu were removed:
    /// erring wide only makes the compact switch happen sooner.
    static let headerFullControlsMinWidth: CGFloat = 720

    /// Grid cell thumbnail size
    static let gridThumbnailWidth: CGFloat = 64

    /// Grid cell thumbnail height
    static let gridThumbnailHeight: CGFloat = 48

    /// Grid cell label width
    static let gridLabelWidth: CGFloat = 80

    /// Height of the filename label under each thumbnail (two lines at 9pt).
    static let gridLabelHeight: CGFloat = 24

    /// Full height of one grid cell: thumbnail, label, and the cell's own padding.
    static let gridCellHeight: CGFloat =
        gridThumbnailHeight + Spacing.xs + gridLabelHeight + (Spacing.xs * 2)

    /// Height reserved for the horizontal scroll indicator, which is always
    /// shown (`.scrollIndicators(.visible)`) and would otherwise overlap the
    /// bottom row of cells.
    static let scrollIndicatorHeight: CGFloat = 15

    /// Height when expanded.
    ///
    /// Derived from the content rather than fixed, so the panel keeps fitting
    /// its cells if the thumbnail or label size is ever changed. The grid
    /// scrolls horizontally, so this does not grow with the number of files -
    /// two rows is the floor, and everything beyond scrolls sideways.
    static let expandedHeight: CGFloat =
        PanelLayout.headerHeight
        + 1  // divider
        + (gridCellHeight * 2) + Spacing.sm  // two rows and the gap between them
        + (Spacing.sm * 2)  // scroll content padding
        + scrollIndicatorHeight
}

/// Timeline section constants (in ContentView)
enum TimelineSectionLayout {
    /// Height when collapsed
    static let collapsedHeight: CGFloat = PanelLayout.headerHeight

    /// Minimum height when expanded
    static let minHeight: CGFloat = 100

    /// Maximum height when expanded
    ///
    /// A floor, not the real ceiling: `TimelineViewModel.maxExpandedHeight`
    /// extends this on displays with room to spare, so the panel can grow to
    /// show more lanes on a large screen instead of always clamping at 500.
    static let maxHeight: CGFloat = 500

    /// Width the expanded timeline header needs before its controls clip.
    ///
    /// Title + MTC IN + Start TC + Duration + divider + zoom controls, plus the
    /// header's own horizontal padding. Still the widest thing in the panel
    /// column, so it - not the media panel - sets the window's minimum width.
    /// Measured at runtime rather than estimated - the estimates were wrong
    /// twice, and 20pt short is enough to break "Timeline" into "Tim/eli...".
    /// 770pt is the header's intrinsic width; the rest is the panel column's
    /// own horizontal padding.
    static let headerMinWidth: CGFloat = 770 + Spacing.md * 2

    /// Vertical space reserved for everything that is not the timeline panel
    /// when sizing it against the display: settings header (44), the expanded
    /// media panel with its optimization banner (~250), inter-panel spacing
    /// and window margins (~90).
    /// Derived, not a constant, because a hardcoded figure goes stale the
    /// moment the layout above the timeline changes - and it did. The 384 this
    /// replaces enumerated the settings header, the media panel and margins,
    /// but predated the inline video area, so ~240pt of video went unreserved.
    /// The timeline was then allowed to grow past what the screen could hold:
    /// expanding it with four lanes produced 1163pt of content on a 1001pt
    /// display, pushing the video and settings off the top.
    static var reservedVerticalChrome: CGFloat {
        // The timeline now has its own full-width row beneath the top row, so
        // what it must leave clear is that row's height - whichever of the video
        // column or the Settings/Media stack is taller - plus margins.
        // The top row is capped, so this is a constant rather than a function
        // of whatever Settings and Media happen to be showing.
        return MainWindowLayout.topRowMaxHeight
            + Spacing.md          // gap between the top row and the timeline
            + Spacing.md * 2      // window margins
            + MainWindowLayout.titleBarAllowance
    }

    /// Default height: the combined Video File track plus three audio lanes.
    ///
    /// Derived rather than tuned, so it keeps meaning that if any row height
    /// changes. Anything past three lanes scrolls inside the panel instead of
    /// growing it - the window has a screen to fit inside.
    static var defaultHeight: CGFloat {
        let tracks = 4                                              // top padding
            + TimelineLayout.videoTrackHeight + 1                   // picture + divider
            + TimelineLayout.linkedAudioStripHeight                 // its baked-in audio
            + (TimelineLayout.audioLaneHeight + 1) * 3              // three audio lanes
            + TimelineLayout.newLaneDropZoneInactiveHeight
        return PanelLayout.headerHeight
            + TimelineLayout.rulerHeight + 1
            + CGFloat(tracks)
            + Spacing.sm
            + PanelLayout.footerHeight + Spacing.md
    }
}

/// Media panel constants
enum MediaPanelLayout {
    /// Default height
    static let defaultHeight: CGFloat = 200
}

/// Transport bar constants
/// One type scale for the transport bar.
///
/// The bar previously mixed six sizes for the same class of information -
/// `monoDisplay` (14pt), `mono` (12pt), `monoSmall` (10pt), a bare 8pt system
/// font, `label` and `subheading` - which read as inconsistent and, more
/// practically, made the bar wider than the default window. Everything in it is
/// one of three things: a label, a value, or a status line, so it gets three
/// tokens sized to fit all of them at full length.
enum TransportTypography {
    /// Monospaced values: timecodes, frame rates.
    static let value = Font.system(size: 11, weight: .medium, design: .monospaced)

    /// Field labels: "POS:", "Start TC:", "Duration:", "FPS:".
    static let label = Font.system(size: 10, weight: .medium)

    /// Secondary status line under the incoming-MIDI readout.
    static let caption = Font.system(size: 9, weight: .regular)

    /// Emphasised variant of `caption`, for the frame-rate mismatch warning.
    static let captionStrong = Font.system(size: 9, weight: .semibold)
}

enum TransportLayout {
    /// Height of control boxes
    static let controlBoxHeight: CGFloat = 48

    /// Uniform height for every box in the transport bar.
    ///
    /// Set by the tallest content in the bar - the incoming-MIDI readout's two
    /// lines, an 11pt value over a 9pt status line. Every other box holds a
    /// single line and centres within it, so they all present as one component
    /// instead of each sizing itself to its own contents.
    static let controlHeight: CGFloat = 34

    /// Fixed width for the run/stop state glyph.
    ///
    /// `play.fill` and `stop.fill` are not the same width, so without a fixed
    /// frame the surrounding control resizes every time the transport changes
    /// state - and in a bar whose contents are already tight, that shifts its
    /// neighbours too.
    static let stateGlyphWidth: CGFloat = 14
}

/// Common spacing and padding - Best Practices
/// Follow the 4pt grid system (4, 8, 12, 16, 20, 24...)
enum Spacing {
    /// Extra small spacing (4pt) - between tightly related items
    static let xs: CGFloat = 4

    /// Small spacing (8pt) - between related controls
    static let sm: CGFloat = 8

    /// Medium spacing (12pt) - standard content padding
    static let md: CGFloat = 12

    /// Large spacing (16pt) - between sections
    static let lg: CGFloat = 16

    /// Extra large spacing (20pt) - major section breaks
    static let xl: CGFloat = 20

    /// 2X large spacing (24pt) - panel margins
    static let xxl: CGFloat = 24

    // Legacy aliases (for backward compatibility)
    static let contentPadding: CGFloat = md
    static let controlSpacing: CGFloat = xs
    static let medium: CGFloat = sm
    static let large: CGFloat = lg
}

// MARK: - TimecodeFrameRate Extension

extension TimecodeFrameRate {
    /// Human-readable display name for the frame rate.
    ///
    /// Returns a formatted string like "23.976", "24", "29.97 DF", etc.
    var displayName: String {
        switch self {
        case .fps23_976: return "23.976"
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps29_97: return "29.97"
        case .fps29_97d: return "29.97 DF"
        case .fps30: return "30"
        default: return "\(fps)"
        }
    }
}
