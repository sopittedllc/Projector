//
//  ImportHoldBackReport.swift
//  Projector
//
//  What to say about the files an import did not put on the timeline.
//

import Foundation

/// Why an import left a file in the media panel instead of placing it.
enum ImportHoldBackReason: Hashable, Sendable, CaseIterable {

    /// The file carries no timecode, so there is nothing to place it against.
    case noTimecode

    /// The file's timecode is already taken on the lane its stem owns.
    ///
    /// Only reachable when two files declaring the *same* stem claim
    /// overlapping time, because a batch puts one lane under each stem. Two
    /// reels of one stem cannot both play at 01:00:00:00, so this is always a
    /// disagreement inside the delivery rather than a decision Projector can
    /// make.
    case timecodeAlreadyOccupied

    /// The sentence introducing this reason's list of files.
    ///
    /// - Parameter count: How many files are being reported for this reason.
    /// - Returns: A sentence ending in a colon.
    func heading(count: Int) -> String {
        let subject = count == 1 ? "This file" : "These files"
        switch self {
        case .noTimecode:
            let verb = count == 1 ? "carries" : "carry"
            let belong = count == 1 ? "it belongs" : "they belong"
            return "\(subject) \(verb) no timecode, so Projector has no way to know where \(belong):"
        case .timecodeAlreadyOccupied:
            let verb = count == 1 ? "claims" : "claim"
            return "\(subject) \(verb) a timecode another file of the same stem already occupies:"
        }
    }
}

/// One file an import held back, and why.
struct HeldBackFile: Hashable, Sendable {

    /// The file's name, as the media panel shows it.
    let name: String

    /// Why it was not placed.
    let reason: ImportHoldBackReason
}

/// The report shown when an import places some files and holds others back.
///
/// ## Why a file is held back rather than placed
///
/// The alternatives are all guesses, and a guess here produces a timeline that
/// looks finished and is quietly wrong. A file with no timecode has to be put
/// *somewhere* - the drop position, or after whatever landed last - and a stem
/// shorter than its reel then drags every later reel on its lane early with
/// nothing on screen to say so. A file whose timecode is already taken has to
/// either hide under the clip that is there or be given a lane of its own,
/// which is how a two-stem delivery grew a lane per file.
///
/// Neither is Projector's decision to make. The delivery has a real problem, and
/// the import is the moment to say so - guessing hides it until someone is
/// mixing against it.
enum ImportHoldBackReport {

    /// How many names to print per reason before summarising the rest.
    ///
    /// A reel delivery can run to dozens of files, and an alert taller than the
    /// screen cannot be read or dismissed.
    static let maxListedNames = 10

    /// The alert's title. Deliberately not "Nothing Placed": the hold-back is
    /// per file, so a drop can place some and hold others.
    static let title = "Not Placed"

    /// The alert body, grouped by reason.
    ///
    /// - Parameter files: The held-back files, in the order they were dropped.
    /// - Returns: The message, or `nil` when nothing was held back - the caller
    ///   should raise no alert at all in that case.
    static func message(for files: [HeldBackFile]) -> String? {
        guard !files.isEmpty else { return nil }

        // Reasons appear in the order `ImportHoldBackReason` declares them, so
        // the same drop always reads the same way round.
        let sections: [String] = ImportHoldBackReason.allCases.compactMap { reason in
            let names = files.filter { $0.reason == reason }.map(\.name)
            guard !names.isEmpty else { return nil }

            let listed = names.prefix(maxListedNames).map { "• \($0)" }
            var body = listed.joined(separator: "\n")
            let remaining = names.count - listed.count
            if remaining > 0 {
                body += "\n• …and \(remaining) more"
            }
            return reason.heading(count: names.count) + "\n\n" + body
        }

        let closing = files.count == 1
            ? "It was added to Media. Drag it onto a lane to place it."
            : "They were added to Media. Drag one onto a lane to place it."

        return sections.joined(separator: "\n\n") + "\n\n" + closing
    }
}
