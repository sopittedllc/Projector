import SwiftUI
import SwiftTimecodeCore

// MARK: - Layout Constants
// Centralized layout constants to eliminate magic numbers (AP-004)
// All view files should import these instead of defining local constants

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

    /// Height when expanded
    static let expandedHeight: CGFloat = 140

    /// Grid cell thumbnail size
    static let gridThumbnailWidth: CGFloat = 64

    /// Grid cell thumbnail height
    static let gridThumbnailHeight: CGFloat = 48

    /// Grid cell label width
    static let gridLabelWidth: CGFloat = 80
}

/// Cue lane constants (timeline header area)
enum CueLaneLayout {
    /// Height of the cue lane
    static let laneHeight: CGFloat = 24

    /// Minimum width for cue markers
    static let markerMinWidth: CGFloat = 4

    /// Corner radius for cue markers
    static let markerCornerRadius: CGFloat = 2

    /// Minimum width to show title text in marker
    static let markerTextMinWidth: CGFloat = 40
}

/// Cues panel constants
enum CuesPanelLayout {
    /// Height when collapsed (header only)
    static let collapsedHeight: CGFloat = PanelLayout.headerHeight

    /// Height when expanded
    static let expandedHeight: CGFloat = 200

    /// Height of each row in the cue table
    static let rowHeight: CGFloat = 28

    /// Width of the cue number column
    static let numberColumnWidth: CGFloat = 40

    /// Width of the title column
    static let titleColumnWidth: CGFloat = 150

    /// Width of timecode columns (TC IN, TC OUT)
    static let timecodeColumnWidth: CGFloat = 100

    /// Width of the duration column
    static let durationColumnWidth: CGFloat = 80

    /// Width of the notes column (flexible)
    static let notesColumnMinWidth: CGFloat = 100
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
    /// Calculation: header(44) + ruler(24) + divider(1) + scrollContent(4+60+1+60+8=133) + footer(32) = 234
    static let defaultHeight: CGFloat = 234
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
