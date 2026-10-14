//
//  PlacedWithoutTimecodeReport.swift
//  Projector
//
//  What to say about files placed on the timeline with no timecode of their own.
//

import Foundation

/// One file an import placed without any timecode of its own, because it said
/// nothing about where it belongs.
struct PlacedWithoutTimecodeFile: Hashable, Sendable {

    /// The file's name, as the media panel shows it.
    let name: String

    /// The timecode it was placed at, as the user reads it on the timeline.
    let timecode: String
}

/// A reel or clip an import flagged, waiting to be reported.
///
/// Holds the identity rather than the position: the report is raised when the
/// import finishes, and the timecode printed should be where the file ended up
/// then - after overlap avoidance and any timeline-start shift - not where the
/// import first aimed.
struct PendingUntimecodedPlacement: Hashable, Sendable {

    /// Whether the flagged item is a video reel or an audio clip.
    enum Kind: Hashable, Sendable {
        case reel
        case clip
    }

    /// The reel or clip's identifier.
    let id: UUID

    /// Which of the two it is.
    let kind: Kind

    /// The file's name.
    let name: String
}

/// The alert shown when an import places files that carry no timecode.
///
/// ## Why this alerts instead of staying quiet
///
/// A targeted drop - onto a frame or a lane the user chose - is an instruction,
/// so the file is placed. But the file's position then comes from the import
/// (the drop position, or the start or end of the timeline), not from the
/// file, and a timeline built that way looks identical to one built from
/// real timecode. Timecode from the DAW then fails to line up with nothing on
/// screen to say why. One alert per import names each file and where it went.
enum PlacedWithoutTimecodeReport {

    /// How many files to list before summarising the rest.
    static let maxListedFiles = 10

    /// The alert's title.
    static let title = "No Embedded Timecode"

    /// Whether a freshly imported file should be flagged and reported.
    ///
    /// A file is flagged only when it said nothing at all about where it
    /// belongs: neither embedded timecode nor a timecode in its name. Every
    /// placement decision goes through here, so the rule has one definition.
    ///
    /// - Parameters:
    ///   - metadata: Embedded timecode read from the file, if any.
    ///   - filenameTimecode: Timecode parsed from the file's name, if any.
    /// - Returns: `true` when the file carries no timecode by either route.
    static func shouldFlag(metadata: EmbeddedTimecodeResult?, filenameTimecode: String?) -> Bool {
        metadata == nil && filenameTimecode == nil
    }

    /// The alert body.
    ///
    /// - Parameter files: The placed files, in the order they were imported.
    /// - Returns: The message, or `nil` when there is nothing to report - the
    ///   caller should raise no alert in that case.
    static func message(for files: [PlacedWithoutTimecodeFile]) -> String? {
        guard let first = files.first else { return nil }

        if files.count == 1 {
            return "\"\(first.name)\" carries no timecode, so Projector had nothing to place it by. "
                + "It was placed at \(first.timecode).\n\nIf it belongs somewhere else, use Set Timecode Position… on its menu."
        }

        let listed = files.prefix(maxListedFiles).map { "• \($0.name) - \($0.timecode)" }
        var body = listed.joined(separator: "\n")
        let remaining = files.count - listed.count
        if remaining > 0 {
            body += "\n• …and \(remaining) more"
        }
        return "These files carry no timecode, so Projector had nothing to place them by. "
            + "Each was placed at the timecode shown:\n\n"
            + body
            + "\n\nIf any belong somewhere else, use Set Timecode Position… on their menus."
    }
}
