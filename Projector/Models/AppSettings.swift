import Foundation
import SwiftUI
import SwiftTimecodeCore

/// Application-wide settings with persistence
final class AppSettings: ObservableObject {
    // MARK: - Singleton

    static let shared = AppSettings()

    // MARK: - Onboarding

    /// Whether the user has completed the welcome overlay
    @AppStorage("hasCompletedWelcome") var hasCompletedWelcome: Bool = false

    // MARK: - MIDI Settings

    /// Selected MIDI input source name
    @AppStorage("selectedMIDIInput") var selectedMIDIInput: String = ""

    /// Whether to respond to MMC commands
    @AppStorage("respondToMMC") var respondToMMC: Bool = true

    // MARK: - Audio Settings

    /// Selected audio output device UID (empty = system default)
    @AppStorage("selectedAudioOutput") var selectedAudioOutput: String = ""

    /// Stored audio output mappings (JSON)
    @AppStorage("audioOutputMappings") private var audioOutputMappingsJSON: String = ""

    // MARK: - Display Settings

    /// Whether to show the timecode overlay on video
    @AppStorage("showTimecodeOverlay") var showTimecodeOverlay: Bool = true

    /// Timecode overlay position
    @AppStorage("timecodeOverlayPosition") var timecodeOverlayPosition: TimecodeOverlayPosition = .bottomRight

    /// Timecode overlay opacity (0-1)
    @AppStorage("timecodeOverlayOpacity") var timecodeOverlayOpacity: Double = 0.8

    // MARK: - Sync Settings

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

    // MARK: - Audio Output Mappings

    func mappedOutputs(for deviceUID: String?) -> [MappedAudioOutput] {
        let key = Self.mappingKey(for: deviceUID)
        let mappings = loadAudioOutputMappings()
        return mappings[key] ?? []
    }

    func setMappedOutputs(_ outputs: [MappedAudioOutput], for deviceUID: String?) {
        let key = Self.mappingKey(for: deviceUID)
        var mappings = loadAudioOutputMappings()
        mappings[key] = outputs
        saveAudioOutputMappings(mappings)
    }

    private func loadAudioOutputMappings() -> [String: [MappedAudioOutput]] {
        guard !audioOutputMappingsJSON.isEmpty,
              let data = audioOutputMappingsJSON.data(using: .utf8) else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: [MappedAudioOutput]].self, from: data)
        } catch {
            return [:]
        }
    }

    private func saveAudioOutputMappings(_ mappings: [String: [MappedAudioOutput]]) {
        guard let data = try? JSONEncoder().encode(mappings),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        audioOutputMappingsJSON = json
    }

    private static func mappingKey(for deviceUID: String?) -> String {
        if let uid = deviceUID, !uid.isEmpty {
            return uid
        }
        return "system_default"
    }

    // MARK: - Reset

    func resetToDefaults() {
        selectedMIDIInput = ""
        selectedAudioOutput = ""
        audioOutputMappingsJSON = ""
        showTimecodeOverlay = true
        timecodeOverlayPosition = .bottomRight
        timecodeOverlayOpacity = 0.8
        autoPlayOnMTC = true
        autoPauseOnMTCStop = true
        respondToMMC = true
        defaultFrameRateRaw = TimecodeFrameRate.fps24.stringValue
    }
}

struct MappedAudioOutput: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var channelStart: Int
    var channelCount: Int

    init(id: UUID = UUID(), name: String, channelStart: Int, channelCount: Int) {
        self.id = id
        self.name = name
        self.channelStart = channelStart
        self.channelCount = channelCount
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

// MARK: - TimecodeFrameRate Extensions

extension TimecodeFrameRate {
    /// Frames per second as a Double value
    var fps: Double {
        switch self {
        case .fps23_976: return 24000.0 / 1001.0  // 23.976...
        case .fps24: return 24.0
        case .fps24_98: return 25000.0 / 1001.0  // 24.975...
        case .fps25: return 25.0
        case .fps29_97: return 30000.0 / 1001.0  // 29.97...
        case .fps29_97d: return 30000.0 / 1001.0  // 29.97... (drop frame)
        case .fps30: return 30.0
        case .fps30d: return 30.0  // 30 drop frame
        case .fps47_952: return 48000.0 / 1001.0  // 47.952...
        case .fps48: return 48.0
        case .fps50: return 50.0
        case .fps59_94: return 60000.0 / 1001.0  // 59.94...
        case .fps59_94d: return 60000.0 / 1001.0  // 59.94... (drop frame)
        case .fps60: return 60.0
        case .fps60d: return 60.0  // 60 drop frame
        case .fps90: return 90.0
        case .fps95_904: return 96000.0 / 1001.0  // 95.904...
        case .fps96: return 96.0
        case .fps100: return 100.0
        case .fps119_88: return 120000.0 / 1001.0  // 119.88...
        case .fps119_88d: return 120000.0 / 1001.0  // 119.88... (drop frame)
        case .fps120: return 120.0
        case .fps120d: return 120.0  // 120 drop frame
        @unknown default: return 24.0
        }
    }

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
