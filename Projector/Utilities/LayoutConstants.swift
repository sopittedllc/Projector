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

    /// One width for every dropdown in Settings.
    ///
    /// The pickers sized themselves to their content, so the device menu was
    /// wide and the profile menu narrow - they read as unrelated controls
    /// rather than a column of settings.
    static let controlWidth: CGFloat = 240

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
    // The Media panel's minimum is `SectionLayout.minimumMediaWidth`, derived
    // from the width its header controls need. There is deliberately no second
    // figure here for the two to disagree about.

    /// Minimum width of the main window's content view.
    ///
    /// Both minimums now come from `SectionLayout`, which is the only thing that
    /// knows how small each section can go. Hand-picked figures could not do the
    /// job: too large and the sections never got to give ground; too small and
    /// they overflowed and clipped.
    ///
    /// These are the *view* minimums, not the window's - they are handed to
    /// SwiftUI's `.frame(minWidth:minHeight:)`, which constrains the content
    /// below the titlebar. `SectionLayout.minimumWindowSize` is the one to clamp
    /// an NSWindow frame against.
    static var mainWindowMinWidth: CGFloat { SectionLayout.minimumViewSize.width }

    /// Minimum height of the main window's content view.
    static var mainWindowMinHeight: CGFloat { SectionLayout.minimumViewSize.height }
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

    // The video column has no fixed size here: `SectionLayout` derives its
    // width from the top row's height, so the column is exactly 16:9 at any
    // window size. The video pillarboxes within it (`videoGravity` is
    // `.resizeAspect`) - the 16:9 is the column's shape, not the media's.

    /// Height of the control strip beneath the inline picture.
    /// Set to 0 because controls are now overlaid on the video.
    static let videoControlsBarHeight: CGFloat = 0

    /// Height of the top row at the reference window size.
    ///
    /// No longer the height the top row *has* - `SectionLayout` resolves that
    /// from whatever size the window currently is. This is the reference figure
    /// the proportions are struck from, and the height the row takes at the
    /// default window size.
    static let topRowHeight: CGFloat = 306

    /// Default height on first launch.
    ///
    /// Derived from the reference layout rather than tuned, so the window opens
    /// showing exactly the reference proportions - top row and timeline at their
    /// design heights, with no growing or settling once the first frame lands.
    static var defaultHeight: CGFloat { SectionLayout.defaultWindowSize.height }

    /// Height the window's titlebar takes above the content.
    static let titleBarAllowance: CGFloat = 32

    /// Smallest height the window is allowed to shrink to.
    ///
    /// The point at which every section is simultaneously at its own minimum -
    /// see `SectionLayout.minimumContentSize`. Derived, because a hand-picked
    /// figure either lets the window shrink past what the sections can honour
    /// (they overflow and clip) or stops it shrinking before they are done
    /// giving ground.
    static var minimumHeight: CGFloat { SectionLayout.minimumWindowSize.height }
}

// ============================================================================
// MARK: - Section Sizing Authority
// ============================================================================

/// A named region of the main window.
///
/// `everything` is the root - the window's content area less its outer margins -
/// and every other case is a division of it. Naming the whole app as a section
/// is the point: it means one calculation turns a window size into every
/// section's size, instead of each section carrying a constant that has to be
/// kept in step with the others by hand.
enum AppSection: String, CaseIterable, Sendable {
    /// The entire application content area. Parent of everything below.
    case everything
    /// Video column and Media panel, side by side.
    case topRow
    /// The picture with its controls strip beneath.
    case video
    /// The media panel, beside the video.
    case media
    /// The full-width timeline, beneath the top row.
    case timeline
}

/// Every section's size at one particular window size.
struct SectionSizes: Equatable, Sendable {
    var everything: CGSize
    var topRow: CGSize
    var video: CGSize
    var media: CGSize
    var timeline: CGSize

    subscript(section: AppSection) -> CGSize {
        switch section {
        case .everything: return everything
        case .topRow: return topRow
        case .video: return video
        case .media: return media
        case .timeline: return timeline
        }
    }

    /// Height of the picture itself: the video column less its controls strip.
    var videoPictureHeight: CGFloat {
        max(0, video.height - MainWindowLayout.videoControlsBarHeight)
    }
}

/// Turns the window's size into every section's size.
///
/// # Section Sizing Authority
///
/// The window used to be sized from its content: panels had fixed heights, they
/// reported what they measured, and the window was resized to fit. That cannot
/// coexist with a window size the user chose by dragging a corner - one of the
/// two has to be the input. This authority makes it the window, and the rules
/// below hold at every size:
///
///  1. EVERYTHING IS THE ROOT. `everything` is the window's content rect less
///     the outer margins. Every other section is carved out of it. No section
///     measures itself and reports back; sizes flow one way only, which is what
///     removed the feedback loop the old window-fits-content authority needed
///     a deadband and two deferred passes to keep stable.
///
///  2. VERTICAL SPACE IS SHARED, NOT ASSIGNED. The top row and the timeline
///     split the height by `topRowShare`, which defaults to their reference
///     proportion (306 : 409) and is what the splitter between them edits.
///     Because it is a fraction, a window resize preserves whatever balance the
///     user set instead of overwriting it.
///
///  3. THE PICTURE DECIDES THE VIDEO COLUMN'S WIDTH. The column is exactly 16:9
///     plus its controls strip, so the video grows in both directions at once
///     and never letterboxes inside its own column.
///
///  4. WIDTH CAN CAP THE TOP ROW. A tall narrow window would want a video wider
///     than the Media panel can spare, so the row is capped at the height that
///     width supports and the surplus goes to the timeline. Rule 3 stays true at
///     every window shape rather than only at wide ones.
///
///  5. MEDIA TAKES WHAT IS LEFT. It is the one section with no size of its own,
///     which is why it is the one that absorbs extra width.
///
///  6. THE MINIMUMS ARE THE WINDOW'S MINIMUM. `minimumContentSize` is the sum of
///     the section minimums, so the window cannot be dragged smaller than the
///     layout can honour. That is what lets the main content area do without a
///     scroll view: it is guaranteed to fit, at every legal window size.
enum SectionLayout {
    // MARK: - Reference layout

    /// Aspect of the picture. The inline video area is 16:9 exactly at every
    /// size; media of other shapes pillarboxes within it.
    static let videoAspect: CGFloat = 16.0 / 9.0

    /// Gap between the top row and the timeline, and between the video column
    /// and the Media panel.
    static var gap: CGFloat { Spacing.md }

    /// Margin between the content and the window's edges.
    static var margin: CGFloat { Spacing.md }

    /// Top row height at the reference window size.
    static var referenceTopRowHeight: CGFloat { MainWindowLayout.topRowHeight }

    /// Timeline height at the reference window size: the Video File track plus
    /// three audio lanes.
    static var referenceTimelineHeight: CGFloat { TimelineSectionLayout.defaultHeight }

    /// The share of the flexible height the top row takes when the user has not
    /// moved the splitter.
    static var defaultTopRowShare: CGFloat {
        referenceTopRowHeight / (referenceTopRowHeight + referenceTimelineHeight)
    }

    // MARK: - Minimums

    /// Smallest useful picture. Below this the transport overlay and the frame
    /// rate chip start colliding with the picture's own content.
    static let minimumPictureHeight: CGFloat = 180

    /// Smallest top row: a usable picture plus its controls strip.
    static var minimumTopRowHeight: CGFloat {
        minimumPictureHeight + MainWindowLayout.videoControlsBarHeight
    }

    /// Smallest video column, following from rule 3.
    static var minimumVideoWidth: CGFloat { minimumPictureHeight * videoAspect }

    /// Smallest Media panel: the width its full header controls need before
    /// they collapse to icons.
    static var minimumMediaWidth: CGFloat { FileManagerLayout.headerFullControlsMinWidth }

    /// Smallest timeline: the same derivation as `TimelineSectionLayout`'s
    /// default, with one audio lane instead of three. Everything beyond that
    /// scrolls inside the panel, so one lane is the floor rather than a guess.
    static var minimumTimelineHeight: CGFloat {
        let tracks = 4                                              // top padding
            + TimelineLayout.videoTrackHeight + 1                   // picture + divider
            + TimelineLayout.linkedAudioStripHeight                 // its baked-in audio
            + (TimelineLayout.audioLaneHeight + 1)                  // one audio lane
            + TimelineLayout.newLaneDropZoneInactiveHeight
        return PanelLayout.headerHeight
            + TimelineLayout.rulerHeight + 1
            + tracks
            + Spacing.sm
            + PanelLayout.footerHeight + Spacing.md
    }

    // MARK: - Derived sizes

    /// The content area at the reference window size.
    static var referenceContentSize: CGSize {
        CGSize(
            width: MainWindowLayout.defaultWidth - margin * 2,
            height: referenceTopRowHeight + gap + referenceTimelineHeight
        )
    }

    /// The smallest content area every section can still be honoured in.
    ///
    /// The width term takes the wider of the two rows: the top row (video beside
    /// the Media panel's full header) or the timeline header, which is the
    /// widest single thing in the app.
    static var minimumContentSize: CGSize {
        CGSize(
            width: max(
                minimumVideoWidth + gap + minimumMediaWidth,
                TimelineSectionLayout.headerMinWidth - margin * 2
            ),
            height: minimumTopRowHeight + gap + minimumTimelineHeight
        )
    }

    /// Window size that produces the reference content area.
    static var defaultWindowSize: CGSize {
        CGSize(
            width: MainWindowLayout.defaultWidth,
            height: referenceContentSize.height + margin * 2 + MainWindowLayout.titleBarAllowance
        )
    }

    /// Smallest size for the app's *view* - `minimumContentSize` plus its
    /// margins, and no titlebar.
    ///
    /// This is what SwiftUI's `.frame(minWidth:minHeight:)` takes: it constrains
    /// the hosted view, which sits below the titlebar. Handing it the window
    /// minimum instead put the floor a titlebar too high - measured, the window
    /// stopped shrinking at 603pt where the sections were still fine at 571.
    static var minimumViewSize: CGSize {
        CGSize(
            width: minimumContentSize.width + margin * 2,
            height: minimumContentSize.height + margin * 2
        )
    }

    /// Smallest *window* - `minimumViewSize` plus the titlebar. This is what
    /// NSWindow frames are clamped against.
    static var minimumWindowSize: CGSize {
        CGSize(
            width: minimumViewSize.width,
            height: minimumViewSize.height + MainWindowLayout.titleBarAllowance
        )
    }

    // MARK: - Resolution

    /// Resolve every section's size for the content area currently on screen.
    ///
    /// - Parameters:
    ///   - content: The area available to the app's content - the window's
    ///     content rect less `margin` on each side.
    ///   - topRowShare: Fraction of the flexible height given to the top row.
    ///     `defaultTopRowShare` unless the user has moved the splitter.
    static func resolve(content: CGSize, topRowShare: CGFloat) -> SectionSizes {
        // Rule 6 in reverse: the window should never get here undersized, but a
        // clamp costs nothing and keeps a mid-animation frame from handing a
        // section a negative height.
        let width = max(content.width, minimumContentSize.width)
        let height = max(content.height, minimumContentSize.height)

        // Rule 4: the widest the video column may be before the Media panel
        // would be squeezed below its own minimum, and the top row height that
        // width supports at 16:9.
        let widestVideo = max(minimumVideoWidth, width - gap - minimumMediaWidth)
        let topRowCeilingFromWidth =
            widestVideo / videoAspect + MainWindowLayout.videoControlsBarHeight

        // Rule 2.
        let flexible = height - gap
        var topRowHeight = flexible * min(max(topRowShare, 0), 1)
        topRowHeight = min(topRowHeight, flexible - minimumTimelineHeight)
        topRowHeight = min(topRowHeight, topRowCeilingFromWidth)
        topRowHeight = max(topRowHeight, minimumTopRowHeight)

        let timelineHeight = max(minimumTimelineHeight, flexible - topRowHeight)

        // Rule 3, then rule 5.
        let videoWidth = min(
            widestVideo,
            (topRowHeight - MainWindowLayout.videoControlsBarHeight) * videoAspect
        )
        let mediaWidth = max(minimumMediaWidth, width - gap - videoWidth)

        return SectionSizes(
            everything: CGSize(width: width, height: height),
            topRow: CGSize(width: width, height: topRowHeight),
            video: CGSize(width: videoWidth, height: topRowHeight),
            media: CGSize(width: mediaWidth, height: topRowHeight),
            timeline: CGSize(width: width, height: timelineHeight)
        )
    }

    /// The share that puts the boundary between the two rows at `topRowHeight`.
    ///
    /// The splitter drags a boundary but stores a fraction - see rule 2 - so it
    /// converts through here rather than writing a height anywhere.
    static func share(forTopRowHeight topRowHeight: CGFloat, in contentHeight: CGFloat) -> CGFloat {
        let flexible = max(1, max(contentHeight, minimumContentSize.height) - gap)
        return min(max(topRowHeight / flexible, 0), 1)
    }
}

// ============================================================================
// MARK: - Layout Constants
// ============================================================================

/// Timeline layout constants
enum TimelineLayout {
    /// Width of track/lane headers (video track, audio lanes)
    static let headerWidth: CGFloat = 140

    /// Width of playhead/ruler header (narrower than track headers)
    static let playheadHeaderWidth: CGFloat = 80

    /// Height of the video track (matches audio lane height for visual consistency)
    static let videoTrackHeight: CGFloat = 80

    /// Height of each audio lane.
    ///
    /// Sized from what a header holds rather than picked: a title, a row of
    /// controls and the output picker come to roughly 60pt stacked, which left
    /// the old height fully occupied and the content pressed against the
    /// separators above and below. This leaves room for real padding around it.
    static let audioLaneHeight: CGFloat = 80

    /// Height of the video file's baked-in audio strip.
    ///
    /// The same height as a normal lane, and defined from it so the two cannot
    /// drift apart. This audio carries as much information as any other lane -
    /// including a stereo waveform, which needs the room to be read at all - so
    /// sizing it down cost legibility to make a point about hierarchy.
    ///
    /// It was previously 36pt, about 60% of a lane, to read as an attachment to
    /// the video rather than a peer of Dialogue, Music and Effects. That
    /// distinction is now carried by its position inside the Video File track
    /// and by its lack of a lane header, not by being short.
    static let linkedAudioStripHeight: CGFloat = audioLaneHeight

    /// Height shared by every control in a lane header.
    ///
    /// One height for the M/S toggles and the output picker, so the two rows
    /// sit on a common rhythm instead of each control sizing itself to its own
    /// text.
    static let laneControlHeight: CGFloat = 18

    /// Corner radius shared by lane header controls.
    static let laneControlCornerRadius: CGFloat = 4

    /// Width of the colour stripe identifying a lane in its header.
    ///
    /// Ties a header to its clips: the stripe uses the same colour the lane's
    /// waveforms are drawn in, so a row is identifiable without reading it.
    static let laneAccentWidth: CGFloat = 3

    /// Hairline separating one track row from the next.
    ///
    /// The lane-height arithmetic elsewhere adds a bare `1` for this; naming it
    /// keeps the separator and the space reserved for it in step.
    static let laneSeparatorHeight: CGFloat = 1

    /// Height of the ruler/timecode display
    static let rulerHeight: CGFloat = 24

    /// Height of the toolbar area
    static let toolbarHeight: CGFloat = 40

    /// Height of the new-lane drop zone strip when no drag is in progress
    static let newLaneDropZoneInactiveHeight: CGFloat = 20

    /// Height of video reel clips.
    ///
    /// Fills the lane minus subtle padding (2pt top and bottom). Changed from
    /// 42pt so the video region occupies the lane similarly to audio clips.
    static let videoClipHeight: CGFloat = 76

    /// Height of audio clips.
    ///
    /// Fills the lane minus subtle padding (2pt top and bottom).
    static let audioClipHeight: CGFloat = 76

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
///
/// The timeline's *height* is no longer here - `SectionLayout` resolves it from
/// the window. What remains is the width its header needs and the reference
/// height the proportions are struck from.
///
/// `collapsedHeight`, `minHeight` and `maxHeight` were removed with the panel's
/// own height state: min and max are `SectionLayout.minimumTimelineHeight` and
/// whatever the window can give, and nothing has collapsed the timeline since it
/// stopped being an accordion.
enum TimelineSectionLayout {
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

    /// Reference height: the combined Video File track plus three audio lanes.
    ///
    /// Derived rather than tuned, so it keeps meaning that if any row height
    /// changes. This is what the timeline measures at the default window size;
    /// past three lanes it scrolls internally rather than demanding more room,
    /// and the window's own size decides the rest.
    ///
    /// `reservedVerticalChrome` lived here to stop the timeline growing past
    /// what the screen could hold. `SectionLayout` gives it a share of the
    /// window instead, so there is nothing left to reserve against.
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

// The Media panel has no height constants: it takes the top row's height,
// which `SectionLayout` resolves.

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

// ============================================================================
// MARK: - Lane Colours
// ============================================================================

/// The colour a timeline lane is drawn in.
///
/// Sequential by lane index so neighbouring lanes stay distinguishable. Held
/// here rather than inside a view because the clips and the lane header both
/// need the same answer - when the palette lived in `AudioClipView` the header
/// had no way to match the waveforms it labels.
enum LaneColor {
    private static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo
    ]

    static func color(forLaneIndex index: Int) -> Color {
        palette[abs(index) % palette.count]
    }
}
