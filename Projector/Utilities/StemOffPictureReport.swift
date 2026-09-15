//
//  StemOffPictureReport.swift
//  Projector
//
//  What to say when a stem's timecode puts it where no picture plays.
//

import Foundation

/// A stem placed by its own timecode that overlaps no reel at all.
///
/// A delivery in which the picture is stamped correctly and the stem is not is
/// an ordinary mistake - a bounce made from a session whose start timecode
/// was never set to the picture's. Projector places the stem where its stamp
/// says, because the stamp is the only thing the file says about itself, but a
/// stem that plays against nothing is worth pointing out, and the reel it
/// most likely belongs to is worth naming.
struct StemOffPictureReport: Hashable, Sendable {

    /// The stem's file name, as the lane shows it.
    let stemName: String

    /// Where the stem's own timecode put it.
    let stemTimecode: String

    /// The reel whose start is nearest the stem's start.
    let reelName: String

    /// Where that reel starts.
    let reelTimecode: String

    /// How far the reel's start is from the stem's, as a duration.
    let offset: String

    /// Whether the reel starts before the stem (true) or after it.
    let reelIsEarlier: Bool

    /// Whether the stem and the reel run the same length, to within a second.
    ///
    /// A full-length bounce is the same length as the picture it was made
    /// against, so when the two match the stem almost certainly belongs at the
    /// reel's start and the stamp is the error.
    let sameLength: Bool

    /// The alert title.
    static let title = "Stem Is Off Picture"

    /// The alert body.
    var message: String {
        let direction = reelIsEarlier ? "earlier" : "later"
        var text = "\u{201C}\(stemName)\u{201D} is stamped \(stemTimecode), but no picture plays there. "
            + "The nearest reel, \u{201C}\(reelName)\u{201D}, starts at \(reelTimecode) - "
            + "\(offset) \(direction)."
        if sameLength {
            text += " Both run the same length, so the stem's timestamp is almost certainly the mistake."
        }
        text += "\n\nMove to Picture puts the stem at the reel's start. Leave It keeps it where it "
            + "is stamped; Set Timecode Position on the region's menu can move it later."
        return text
    }
}
