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
    static let accentGreen = Color(red: 0.4, green: 0.9, blue: 0.4)

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
}

// ============================================================================
// MARK: - Horizontal Layout Constants
// ============================================================================

/// Layout constants for the horizontal split layout (video left, panels right)
enum HorizontalLayoutConstants {
    /// Minimum width for the video player section
    static let minVideoWidth: CGFloat = 320

    /// Default width for the video player section
    static let defaultVideoWidth: CGFloat = 480

    /// Minimum width for the right panel section (timeline + media)
    static let minPanelWidth: CGFloat = 300

    /// Default width for the right panel section
    static let defaultPanelWidth: CGFloat = 400
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

    /// Height of the ruler/timecode display
    static let rulerHeight: CGFloat = 24

    /// Height of the toolbar area
    static let toolbarHeight: CGFloat = 40

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

    /// Height when expanded (header + content with comfortable padding)
    static let expandedHeight: CGFloat = 180

    /// Grid cell thumbnail size
    static let gridThumbnailWidth: CGFloat = 64

    /// Grid cell thumbnail height
    static let gridThumbnailHeight: CGFloat = 48

    /// Grid cell label width
    static let gridLabelWidth: CGFloat = 80
}

/// Timeline section constants (in ContentView)
enum TimelineSectionLayout {
    /// Height when collapsed
    static let collapsedHeight: CGFloat = PanelLayout.headerHeight

    /// Minimum height when expanded
    static let minHeight: CGFloat = 100

    /// Maximum height when expanded
    static let maxHeight: CGFloat = 500

    /// Default height - sized to show Video track + 1 Audio lane without scrolling
    /// Calculation: header(44) + ruler(24) + spacer(4) + videoTrack(60) + divider(1) + audioArea(60) + padding(8) + footer(44) = 245
    /// Adding extra padding for comfortable viewing
    static let defaultHeight: CGFloat = 260
}

/// Media panel constants
enum MediaPanelLayout {
    /// Default height
    static let defaultHeight: CGFloat = 200
}

/// Transport bar constants
enum TransportLayout {
    /// Height of control boxes
    static let controlBoxHeight: CGFloat = 48
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
