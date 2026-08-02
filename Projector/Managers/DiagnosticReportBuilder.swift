//
//  DiagnosticReportBuilder.swift
//  Projector
//
//  Turns collected facts plus the diagnostic log into a readable report.
//

import Foundation

/// Where to send finished bug reports.
public enum SupportContact {
    /// Recipient for the pre-filled report email.
    ///
    /// - Note: This ships inside the binary and is visible to anyone who
    ///   receives the app. Point it at an address that can absorb that.
    public static let email = "support@sopitted.llc"
}

/// Unit conversions used when reporting machine facts.
public enum DiagnosticUnits {
    /// Bytes in a gigabyte, for turning `physicalMemory` into something a
    /// person recognises.
    public static let bytesPerGigabyte: Double = 1_073_741_824
}

/// A point-in-time picture of the app, gathered when a report is opened.
///
/// A plain value rather than a reference to the managers, so the report can be
/// built off the main actor and the Logic layer never has to know the
/// Presentation layer's types.
public struct DiagnosticSnapshot: Sendable {
    // App
    public var appVersion: String
    public var appBuild: String
    public var bundleIdentifier: String

    // System
    public var osVersion: String
    public var hardwareModel: String
    public var architecture: String
    public var physicalMemoryGB: Double
    public var uptime: TimeInterval

    // Audio
    public var audioOutputs: [String]

    // MIDI
    public var midiInputs: [String]
    public var selectedMIDIInput: String?
    public var midiSyncState: String

    // Project
    public var projectPath: String?
    public var hasUnsavedChanges: Bool
    public var videoReelCount: Int
    public var audioLaneCount: Int
    public var audioClipCount: Int
    public var timelineFrameRate: String
    public var timelineDurationFrames: Int
    public var mediaPaths: [String]

    public init(
        appVersion: String,
        appBuild: String,
        bundleIdentifier: String,
        osVersion: String,
        hardwareModel: String,
        architecture: String,
        physicalMemoryGB: Double,
        uptime: TimeInterval,
        audioOutputs: [String],
        midiInputs: [String],
        selectedMIDIInput: String?,
        midiSyncState: String,
        projectPath: String?,
        hasUnsavedChanges: Bool,
        videoReelCount: Int,
        audioLaneCount: Int,
        audioClipCount: Int,
        timelineFrameRate: String,
        timelineDurationFrames: Int,
        mediaPaths: [String]
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.bundleIdentifier = bundleIdentifier
        self.osVersion = osVersion
        self.hardwareModel = hardwareModel
        self.architecture = architecture
        self.physicalMemoryGB = physicalMemoryGB
        self.uptime = uptime
        self.audioOutputs = audioOutputs
        self.midiInputs = midiInputs
        self.selectedMIDIInput = selectedMIDIInput
        self.midiSyncState = midiSyncState
        self.projectPath = projectPath
        self.hasUnsavedChanges = hasUnsavedChanges
        self.videoReelCount = videoReelCount
        self.audioLaneCount = audioLaneCount
        self.audioClipCount = audioClipCount
        self.timelineFrameRate = timelineFrameRate
        self.timelineDurationFrames = timelineDurationFrames
        self.mediaPaths = mediaPaths
    }
}

/// Facts about the machine that do not depend on app state.
///
/// Split out so the values can be read once without touching any manager.
public enum SystemFacts {
    /// When this launch began, used to report how long the session had been
    /// running when the problem showed up.
    ///
    /// Touched from `applicationDidFinishLaunching` so the lazy initialisation
    /// happens at launch rather than whenever the first report is opened.
    public static let launchDate = Date()

    /// The marketing-ish model identifier, e.g. `Mac14,6`.
    public static var hardwareModel: String {
        sysctlString("hw.model") ?? "unknown"
    }

    /// The architecture the process is actually running as, which on Apple
    /// silicon distinguishes a native launch from one under Rosetta.
    public static var architecture: String {
        #if arch(arm64)
        return isTranslated ? "arm64 (running x86_64 under Rosetta)" : "arm64"
        #elseif arch(x86_64)
        return isTranslated ? "x86_64 (Rosetta)" : "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Whether the process is being translated by Rosetta.
    ///
    /// A missing key means the kernel does not publish it, which is itself an
    /// answer: the process is native.
    private static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 else {
            return false
        }
        return value == 1
    }

    /// Reads a string-valued sysctl, or nil if the key is absent.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Formats a ``DiagnosticSnapshot`` and a log into the text a user sends.
///
/// Plain text on purpose. The user is shown exactly this before it leaves the
/// machine, so it has to be readable by someone who is not a programmer, and it
/// has to be greppable by whoever receives it.
public enum DiagnosticReportBuilder {
    /// Bytes of report text past which the log is trimmed rather than the
    /// report being sent at a size mail clients start refusing.
    private static let maxReportBytes = 900_000

    /// Width of the `=` rules that separate sections.
    private static let ruleWidth = 60

    /// Column the values line up in, so a section reads as two columns.
    private static let labelColumnWidth = 16

    /// Builds the report.
    ///
    /// - Parameters:
    ///   - description: What the user typed. Placed first, because it is the
    ///     only part no amount of instrumentation can reconstruct.
    ///   - snapshot: The state gathered when the report was opened.
    ///   - log: Entries from ``DiagnosticLogService/snapshot()``, oldest first.
    ///   - overwritten: Entries already lost to the ring, reported so a
    ///     truncated log is never read as a quiet one.
    /// - Returns: The full report as plain text.
    public static func build(
        description: String,
        snapshot: DiagnosticSnapshot,
        log: [DiagnosticEntry],
        overwritten: Int
    ) -> String {
        var out = section("WHAT HAPPENED")
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        out += trimmed.isEmpty ? "(no description given)\n" : "\(trimmed)\n"
        return out + diagnosticSections(
            snapshot: snapshot,
            log: log,
            overwritten: overwritten
        )
    }

    /// Everything the app collected on its own, without the user's description.
    ///
    /// This is what the review pane shows. Rebuilding the whole report on every
    /// keystroke would mean re-laying out a log that can run to a hundred
    /// kilobytes or more, so the user's own words are left out here and the
    /// sheet says so - rather than the pane claiming no description was given
    /// while the user is looking at the one they just typed.
    public static func diagnosticSections(
        snapshot: DiagnosticSnapshot,
        log: [DiagnosticEntry],
        overwritten: Int
    ) -> String {
        var out = ""

        out += section("APPLICATION")
        out += line("Version", "\(snapshot.appVersion) (build \(snapshot.appBuild))")
        out += line("Bundle", snapshot.bundleIdentifier)
        out += line("Reported", Self.timestampFormatter.string(from: Date()))
        out += line("Session length", duration(snapshot.uptime))

        out += section("SYSTEM")
        out += line("macOS", snapshot.osVersion)
        out += line("Model", snapshot.hardwareModel)
        out += line("Architecture", snapshot.architecture)
        out += line("Memory", String(format: "%.0f GB", snapshot.physicalMemoryGB))

        out += section("AUDIO OUTPUTS")
        out += list(snapshot.audioOutputs, empty: "(none configured)")

        out += section("MIDI")
        out += line("Sync state", snapshot.midiSyncState)
        out += line("Selected input", snapshot.selectedMIDIInput ?? "(none)")
        out += "Available inputs:\n"
        out += list(snapshot.midiInputs, empty: "(none)")

        out += section("PROJECT")
        out += line("File", snapshot.projectPath ?? "(unsaved)")
        out += line("Unsaved changes", snapshot.hasUnsavedChanges ? "yes" : "no")
        out += line("Video reels", "\(snapshot.videoReelCount)")
        out += line("Audio lanes", "\(snapshot.audioLaneCount)")
        out += line("Audio clips", "\(snapshot.audioClipCount)")
        out += line("Frame rate", snapshot.timelineFrameRate)
        out += line("Duration", "\(snapshot.timelineDurationFrames) frames")

        out += section("MEDIA")
        out += list(snapshot.mediaPaths, empty: "(no media imported)")

        out += section("LOG")
        if overwritten > 0 {
            out += "(\(overwritten) earlier entries dropped - the log holds the most recent "
            out += "\(DiagnosticLogConstants.capacity))\n\n"
        }
        out += log.isEmpty ? "(no entries)\n" : formatted(log, budget: maxReportBytes - out.utf8.count)

        return out
    }

    // MARK: - Formatting

    /// Renders log entries newest-last, dropping the oldest if the report would
    /// otherwise be too large to send.
    private static func formatted(_ log: [DiagnosticEntry], budget: Int) -> String {
        var lines: [String] = []
        var bytes = 0

        // Built back to front so that when the budget runs out it is the oldest
        // entries that go, not the ones nearest the problem.
        for entry in log.reversed() {
            let line = "\(logTimestampFormatter.string(from: entry.timestamp))  "
                + "\(entry.level.tag)  "
                + "[\(entry.category.rawValue)] \(entry.message)"
            let cost = line.utf8.count + 1
            if bytes + cost > budget { break }
            lines.append(line)
            bytes += cost
        }

        let dropped = log.count - lines.count
        var out = lines.reversed().joined(separator: "\n") + "\n"
        if dropped > 0 {
            out = "(\(dropped) further entries omitted to keep the report sendable)\n\n" + out
        }
        return out
    }

    private static func section(_ title: String) -> String {
        "\n" + String(repeating: "=", count: ruleWidth) + "\n\(title)\n"
            + String(repeating: "=", count: ruleWidth) + "\n"
    }

    private static func line(_ label: String, _ value: String) -> String {
        "\(label.padding(toLength: max(label.count, labelColumnWidth), withPad: " ", startingAt: 0))  \(value)\n"
    }

    private static func list(_ values: [String], empty: String) -> String {
        values.isEmpty ? "\(empty)\n" : values.map { "  - \($0)\n" }.joined()
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%dh %02dm %02ds", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter
    }()

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
