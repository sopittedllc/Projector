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

    // MARK: - Audio Settings

    /// Selected audio output device UID (empty = system default)
    @AppStorage("selectedAudioOutput") var selectedAudioOutput: String = ""

    /// Stored audio output mappings (JSON)
    @AppStorage("audioOutputMappings") private var audioOutputMappingsJSON: String = ""

    // MARK: - Display Settings

    /// Whether to show the timecode overlay on video
    @AppStorage("showTimecodeOverlay") var showTimecodeOverlay: Bool = true


    /// Timecode overlay opacity (0-1)
    @AppStorage("timecodeOverlayOpacity") var timecodeOverlayOpacity: Double = 0.8

    /// Where the timecode overlay sits on the picture.
    @AppStorage("timecodeOverlayPosition") var timecodeOverlayPosition: TimecodeOverlayPosition = .bottomCenter


    // MARK: - Player Window

    /// Whether the standalone player window floats above all other apps,
    /// including fullscreen ones.
    @AppStorage("playerWindowPinnedToFront") var playerWindowPinnedToFront: Bool = false

    // MARK: - Sync Settings

    /// Number of frames drift before re-syncing to MTC
    /// Higher values reduce stuttering, lower values improve sync accuracy
    @AppStorage("syncDriftThreshold") var syncDriftThreshold: Int = 5

    // MARK: - Project Settings

    /// Last directory used to save a project (bookmark data for sandboxed access).
    ///
    /// Used by SaveProjectSheet to default to the user's preferred location
    /// instead of always falling back to Documents.
    @AppStorage("lastProjectSaveLocationBookmark") private var lastProjectSaveLocationBookmark: Data = Data()

    /// The last directory used to save a project, resolved from a security-scoped bookmark.
    var lastProjectSaveLocation: URL? {
        get {
            guard !lastProjectSaveLocationBookmark.isEmpty else { return nil }
            var isStale = false
            return try? URL(
                resolvingBookmarkData: lastProjectSaveLocationBookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
        set {
            if let url = newValue,
               let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
                lastProjectSaveLocationBookmark = bookmark
            } else {
                lastProjectSaveLocationBookmark = Data()
            }
        }
    }

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

    /// Saved output profiles, JSON-encoded.
    @AppStorage("audioOutputProfiles") private var audioOutputProfilesJSON: String = ""

    // MARK: - Audio Output Profiles

    /// Every saved profile, newest last.
    var audioOutputProfiles: [AudioOutputProfile] {
        guard !audioOutputProfilesJSON.isEmpty,
              let data = audioOutputProfilesJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([AudioOutputProfile].self, from: data)) ?? []
    }

    /// Insert or replace a profile, matched on id.
    func saveAudioOutputProfile(_ profile: AudioOutputProfile) {
        var profiles = audioOutputProfiles
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        writeAudioOutputProfiles(profiles)
    }

    func deleteAudioOutputProfile(id: UUID) {
        writeAudioOutputProfiles(audioOutputProfiles.filter { $0.id != id })
    }

    private func writeAudioOutputProfiles(_ profiles: [AudioOutputProfile]) {
        guard let data = try? JSONEncoder().encode(profiles),
              let json = String(data: data, encoding: .utf8) else { return }
        audioOutputProfilesJSON = json
    }

    // MARK: - Audio Output Mappings

    func mappedOutputs(for deviceUID: String?) -> [MappedAudioOutput] {
        let key = Self.mappingKey(for: deviceUID)
        let mappings = loadAudioOutputMappings()
        return mappings[key] ?? []
    }

    /// Whether this device has ever had its outputs decided by the user.
    ///
    /// Distinguishes "never seen this device" from "user cleared every output",
    /// which `mappedOutputs(for:)` alone cannot: both return an empty array. The
    /// difference is whether the key exists at all, so an absent key means
    /// untouched and a key holding `[]` means deliberately emptied.
    ///
    /// Without this, seeding a default output on an empty list would re-create
    /// it the instant the user cleared it, making the default impossible to
    /// remove. See `AudioOutputManager.loadMappedOutputs()`.
    func hasConfiguredOutputs(for deviceUID: String?) -> Bool {
        loadAudioOutputMappings()[Self.mappingKey(for: deviceUID)] != nil
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
        audioOutputProfilesJSON = ""
        showTimecodeOverlay = true
        timecodeOverlayOpacity = 0.8
        timecodeOverlayPosition = .bottomCenter
        syncDriftThreshold = 5
        defaultFrameRateRaw = TimecodeFrameRate.fps24.stringValue
    }
}

struct MappedAudioOutput: Identifiable, Codable, Hashable {
    /// Identifier for the built-in stereo role, shared by the seeding code in
    /// `AudioOutputManager` and the `OutputRole.stereoOut` UI case.
    ///
    /// Lives here, in the model layer, because both sides need the same string
    /// and `Managers` must not reach into `Views` to get it.
    static let stereoOutRoleId = "stereo-out"

    let id: UUID
    var name: String
    var channelStart: Int
    var channelCount: Int

    /// Which named role this fills, if any (`OutputRole.id`).
    ///
    /// Stored rather than inferred from `name`. Matching on the name looked
    /// fine until a mapping made before the roles existed - "DX" against a role
    /// called "DX/SFX" - failed to match, so the chooser stayed on screen *and*
    /// the output was listed again as an extra. Optional so older saved
    /// mappings still decode; `OutputRole.matches(_:)` falls back to the name
    /// for those.
    var roleId: String?

    init(
        id: UUID = UUID(),
        name: String,
        channelStart: Int,
        channelCount: Int,
        roleId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.channelStart = channelStart
        self.channelCount = channelCount
        self.roleId = roleId
    }
}

// MARK: - Audio Output Profile

/// A named set of outputs the user can recall.
///
/// Portable by design: it stores only names and channel numbers, so it applies
/// to whatever device is selected. The originating device is recorded purely so
/// the UI can warn that the channel layout was designed elsewhere - it never
/// prevents a profile being used, because moving a session between a studio
/// interface and a laptop is exactly what profiles are for.
struct AudioOutputProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var outputs: [MappedAudioOutput]

    /// Device this profile was saved from, for the mismatch warning. Optional so
    /// profiles saved before this existed still decode.
    var createdForDeviceUID: String?
    var createdForDeviceName: String?

    init(
        id: UUID = UUID(),
        name: String,
        outputs: [MappedAudioOutput],
        createdForDeviceUID: String? = nil,
        createdForDeviceName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.outputs = outputs
        self.createdForDeviceUID = createdForDeviceUID
        self.createdForDeviceName = createdForDeviceName
    }

    /// Highest channel the profile addresses - used to tell whether a device has
    /// enough outputs to satisfy it.
    var highestChannel: Int {
        outputs.map { $0.channelStart + $0.channelCount }.max() ?? 0
    }
}

// MARK: - Timecode Overlay Position

/// Where the timecode overlay is drawn on the video.
///
/// A 3x2 grid rather than the original four corners: bottom centre is the
/// default because it is the one cell that never shares space with the hover
/// controls (bottom right) or the frame-rate chip (bottom left).
enum TimecodeOverlayPosition: String, CaseIterable, Identifiable {
    case topLeft = "Top Left"
    case topCenter = "Top Center"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    case bottomCenter = "Bottom Center"
    case bottomRight = "Bottom Right"

    var id: String { rawValue }

    var isTop: Bool {
        self == .topLeft || self == .topCenter || self == .topRight
    }

    /// SwiftUI alignment for placing the overlay within the video frame.
    var alignment: Alignment {
        switch self {
        case .topLeft:      return .topLeading
        case .topCenter:    return .top
        case .topRight:     return .topTrailing
        case .bottomLeft:   return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight:  return .bottomTrailing
        }
    }
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

    /// Numerator for rational frame rate representation.
    ///
    /// For NTSC rates like 23.976fps, the true rate is 24000/1001.
    /// Using rational arithmetic avoids floating-point drift over time.
    var rationalNumerator: Int32 {
        switch self {
        case .fps23_976: return 24000
        case .fps24: return 24
        case .fps24_98: return 25000
        case .fps25: return 25
        case .fps29_97, .fps29_97d: return 30000
        case .fps30, .fps30d: return 30
        case .fps47_952: return 48000
        case .fps48: return 48
        case .fps50: return 50
        case .fps59_94, .fps59_94d: return 60000
        case .fps60, .fps60d: return 60
        case .fps90: return 90
        case .fps95_904: return 96000
        case .fps96: return 96
        case .fps100: return 100
        case .fps119_88, .fps119_88d: return 120000
        case .fps120, .fps120d: return 120
        @unknown default: return 24
        }
    }

    /// Denominator for rational frame rate representation.
    ///
    /// NTSC rates use 1001 (e.g., 24000/1001 = 23.976fps).
    /// Integer rates use 1.
    var rationalDenominator: Int32 {
        switch self {
        case .fps23_976, .fps24_98, .fps29_97, .fps29_97d,
             .fps47_952, .fps59_94, .fps59_94d, .fps95_904,
             .fps119_88, .fps119_88d:
            return 1001
        default:
            return 1
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
