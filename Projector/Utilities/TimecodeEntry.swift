//
//  TimecodeEntry.swift
//  Projector
//
//  Shared formatting and parsing for typed timecode fields.
//

import Foundation
import SwiftTimecodeCore

/// Formatting and parsing for the app's editable timecode fields.
///
/// Every field that takes a typed timecode - the playhead position, the
/// timeline start, the region timecode dialog - reads its input through here,
/// so a partial entry means the same thing everywhere.
///
/// ## Entry fills from the left
///
/// The field formats digits as they are typed by inserting a colon after each
/// pair, left to right: typing `012100` shows `01:21:00`. Parsing reads them
/// the same way - hours first - with any field the user did not reach left at
/// zero, so `01:21:00` is `01:21:00:00` and `0121` is also `01:21:00:00`.
///
/// Each field previously padded on the *left* instead, which read `01:21:00`
/// as `00:01:21:00`. The field displayed one timecode and seeked to another an
/// hour and twenty minutes earlier, and on a reel starting at 01:00:00:00 that
/// landed before the timeline start, where the seek was discarded without a
/// word. Hours-first is also what the surrounding app shows: cue sheets, the
/// ruler and the position readout are all written HH:MM:SS:FF.
enum TimecodeEntry {

    // MARK: - Constants

    /// Digits in a complete timecode - two each of hours, minutes, seconds, frames.
    private static let digitCount = 8

    /// Digits in one timecode field.
    private static let digitsPerField = 2

    // MARK: - API

    /// Format a partial entry for display, separating each field with a colon.
    ///
    /// Digits past a full timecode are dropped, so the field cannot run past
    /// `HH:MM:SS:FF` however long the user keeps typing.
    ///
    /// - Parameter input: Raw contents of the text field.
    /// - Returns: The same digits, punctuated.
    static func formatted(_ input: String) -> String {
        let digits = Array(entryDigits(of: input))
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && index % digitsPerField == 0 {
                result += ":"
            }
            result.append(digit)
        }
        return result
    }

    /// Parse a typed entry into a timecode.
    ///
    /// Digits fill the fields from the left; fields the user did not reach are
    /// zero. Values too large for their field are clamped rather than rejected,
    /// matching how the timecode type handles every other input in the app.
    ///
    /// - Parameters:
    ///   - input: Raw contents of the text field. Punctuation is ignored, so
    ///     `01:21` and `0121` parse alike.
    ///   - frameRate: Rate the resulting timecode is expressed at.
    /// - Returns: The timecode, or `nil` when the entry holds no digits at all.
    ///   Callers must tell the user when this happens rather than returning
    ///   quietly - a field that ignores Return reads as a broken field.
    static func parse(_ input: String, at frameRate: TimecodeFrameRate) -> Timecode? {
        let digits = entryDigits(of: input)
        guard !digits.isEmpty else { return nil }

        // Missing fields trail the entry rather than lead it, so what the user
        // typed keeps the significance the field showed it having.
        let padded = digits + String(repeating: "0", count: digitCount - digits.count)
        let fields = stride(from: 0, to: digitCount, by: digitsPerField).map { offset -> Int in
            let start = padded.index(padded.startIndex, offsetBy: offset)
            let end = padded.index(start, offsetBy: digitsPerField)
            return Int(padded[start..<end]) ?? 0
        }

        return Timecode(
            .components(h: fields[0], m: fields[1], s: fields[2], f: fields[3]),
            at: frameRate,
            by: .clamping
        )
    }

    // MARK: - Helpers

    /// The digits of an entry, capped at one full timecode.
    ///
    /// Restricted to ASCII so that every character kept is one `Int` can read.
    /// A wider test would let a digit through that parses as nothing, and the
    /// field it landed in would silently become zero.
    private static func entryDigits(of input: String) -> String {
        String(input.filter { $0.isASCII && $0.isNumber }.prefix(digitCount))
    }
}
