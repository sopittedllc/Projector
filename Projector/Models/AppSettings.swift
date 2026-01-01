import Foundation
import SwiftUI
import SwiftTimecodeCore

/// Application-wide settings with persistence
final class AppSettings: ObservableObject {
    // MARK: - Singleton

    static let shared = AppSettings()

    // MARK: - MIDI Settings

    /// Selected MIDI input source name
    @AppStorage("selectedMIDIInput") var selectedMIDIInput: String = ""

    /// Whether to respond to MMC commands
    @AppStorage("respondToMMC") var respondToMMC: Bool = true

    // MARK: - Audio Settings

    /// Selected audio output device UID (empty = system default)
    @AppStorage("selectedAudioOutput") var selectedAudioOutput: String = ""

    // MARK: - Display Settings

    /// Whether to show the timecode overlay on video
    @AppStorage("showTimecodeOverlay") var showTimecodeOverlay: Bool = true

    /// Timecode overlay position
    @AppStorage("timecodeOverlayPosition") var timecodeOverlayPosition: TimecodeOverlayPosition = .bottomRight

    /// Timecode overlay opacity (0-1)
    @AppStorage("timecodeOverlayOpacity") var timecodeOverlayOpacity: Double = 0.8

    // MARK: - Sync Settings

    /// Number of frames drift before re-syncing to MTC
    @AppStorage("syncDriftThreshold") var syncDriftThreshold: Int = 2

    /// Whether to auto-play when MTC starts
    @AppStorage("autoPlayOnMTC") var autoPlayOnMTC: Bool = true

    /// Whether to auto-pause when MTC stops
    @AppStorage("autoPauseOnMTCStop") var autoPauseOnMTCStop: Bool = true

    // MARK: - Frame Rate Settings

    /// Default frame rate for videos without detected frame rate
    @AppStorage("defaultFrameRate") var defaultFrameRateRaw: String = TimecodeFrameRate.fps24.stringValue

    var defaultFrameRate: TimecodeFrameRate {
        get {
            TimecodeFrameRate(stringValue: defaultFrameRateRaw) ?? .fps24
        }
        set {
            defaultFrameRateRaw = newValue.stringValue
        }
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Reset

    func resetToDefaults() {
        selectedMIDIInput = ""
        selectedAudioOutput = ""
        showTimecodeOverlay = true
        timecodeOverlayPosition = .bottomRight
        timecodeOverlayOpacity = 0.8
        syncDriftThreshold = 2
        autoPlayOnMTC = true
        autoPauseOnMTCStop = true
        respondToMMC = true
        defaultFrameRateRaw = TimecodeFrameRate.fps24.stringValue
    }
}

// MARK: - Timecode Overlay Position

enum TimecodeOverlayPosition: String, CaseIterable, Identifiable {
    case topLeft = "Top Left"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"

    var id: String { rawValue }
}

// MARK: - TimecodeFrameRate String Conversion

extension TimecodeFrameRate {
    var stringValue: String {
        switch self {
        case .fps23_976: return "23.976"
        case .fps24: return "24"
        case .fps24_98: return "24.98"
        case .fps25: return "25"
        case .fps29_97: return "29.97"
        case .fps29_97d: return "29.97d"
        case .fps30: return "30"
        case .fps30d: return "30d"
        case .fps47_952: return "47.952"
        case .fps48: return "48"
        case .fps50: return "50"
        case .fps59_94: return "59.94"
        case .fps59_94d: return "59.94d"
        case .fps60: return "60"
        case .fps60d: return "60d"
        case .fps90: return "90"
        case .fps95_904: return "95.904"
        case .fps96: return "96"
        case .fps100: return "100"
        case .fps119_88: return "119.88"
        case .fps119_88d: return "119.88d"
        case .fps120: return "120"
        case .fps120d: return "120d"
        @unknown default: return "24"
        }
    }

    init?(stringValue: String) {
        switch stringValue {
        case "23.976": self = .fps23_976
        case "24": self = .fps24
        case "24.98": self = .fps24_98
        case "25": self = .fps25
        case "29.97": self = .fps29_97
        case "29.97d": self = .fps29_97d
        case "30": self = .fps30
        case "30d": self = .fps30d
        case "47.952": self = .fps47_952
        case "48": self = .fps48
        case "50": self = .fps50
        case "59.94": self = .fps59_94
        case "59.94d": self = .fps59_94d
        case "60": self = .fps60
        case "60d": self = .fps60d
        case "90": self = .fps90
        case "95.904": self = .fps95_904
        case "96": self = .fps96
        case "100": self = .fps100
        case "119.88": self = .fps119_88
        case "119.88d": self = .fps119_88d
        case "120": self = .fps120
        case "120d": self = .fps120d
        default: return nil
        }
    }
}
