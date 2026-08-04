//
//  TimecodeFrameRate+Nearest.swift
//  Projector
//
//  Matching a measured frame rate to a timecode rate.
//

import Foundation
import SwiftTimecodeCore

extension TimecodeFrameRate {

    /// Widest gap, in frames per second, still counted as the same rate.
    ///
    /// Comfortably clears the NTSC pairs it has to tell apart - 24 against
    /// 23.976 is 0.024 - while refusing a rate the app has no case for, so a
    /// 15 fps file falls back to the timeline's own rate rather than silently
    /// becoming something it is not.
    private static let matchTolerance: Double = 0.5

    /// The timecode rate closest to a measured frame rate.
    ///
    /// ## Why not the first rate within a window
    ///
    /// Taking the first case within a tolerance is what made a true 24 fps reel
    /// import as 23.976: `allCases` begins at 23.976, which is 0.024 away, so
    /// the search stopped there and never reached the exact match sitting one
    /// case later. Every integer rate had the same problem for the same reason
    /// - 25 became 24.98, 30 became 29.97, 48 became 47.952 - because each one
    /// is preceded in the enum by its NTSC cousin.
    ///
    /// The result is a 1000/1001 error in every frame-to-seconds conversion the
    /// reel takes part in, so it does not look like a wrong setting. It looks
    /// like drift: picture and the position readout agree at the head of the
    /// reel and pull apart as it runs, reaching a frame after about a second of
    /// programme and 21 frames by fourteen minutes in. It also shortens the
    /// reel's own duration, since that is measured in frames too.
    ///
    /// ## Ties
    ///
    /// A tie goes to the non-drop rate. Drop frame describes how timecode is
    /// *counted*, not how fast the picture runs, so 29.97 and 29.97d measure
    /// identically here and nothing about a nominal frame rate can separate
    /// them. The file's own timecode track carries that flag if it matters.
    ///
    /// - Parameters:
    ///   - fps: Measured frame rate, typically a track's `nominalFrameRate`.
    ///   - tolerance: Widest acceptable gap. Defaults to ``matchTolerance``.
    /// - Returns: The nearest rate, or `nil` when nothing is within tolerance.
    static func nearest(to fps: Double, tolerance: Double = matchTolerance) -> TimecodeFrameRate? {
        allCases
            .filter { abs($0.fps - fps) <= tolerance }
            .min { lhs, rhs in
                let lhsGap = abs(lhs.fps - fps)
                let rhsGap = abs(rhs.fps - fps)
                if lhsGap != rhsGap { return lhsGap < rhsGap }
                return !lhs.isDrop && rhs.isDrop
            }
    }

    /// Timecode labels in one second at this rate: 23.976 counts 24, 29.97 counts 30.
    ///
    /// The number to divide a frame count by when turning it into an address or
    /// a duration. Dividing by ``fps`` instead measures *elapsed time*, which is
    /// a different quantity and 1000/1001 away on every NTSC rate - the reason a
    /// 90-minute reel once displayed a duration of 1:30:05:18.
    var labelsPerSecond: Int {
        Int(fps.rounded())
    }

    /// A frame count rendered as HH:MM:SS:FF at this rate.
    ///
    /// Counts labels, so it is exact for NTSC rates. Used for durations and any
    /// other span measured in frames.
    ///
    /// - Parameters:
    ///   - frameCount: Number of frames.
    ///   - forceHours: Show the hours field even when zero.
    /// - Returns: The formatted span.
    func timecodeString(forFrameCount frameCount: Int, forceHours: Bool = false) -> String {
        let perSecond = max(1, labelsPerSecond)
        let perMinute = perSecond * 60
        let perHour = perMinute * 60
        let frames = max(0, frameCount)

        let hours = frames / perHour
        let minutes = (frames % perHour) / perMinute
        let seconds = (frames % perMinute) / perSecond
        let remainder = frames % perSecond

        if hours > 0 || forceHours {
            return String(format: "%d:%02d:%02d:%02d", hours, minutes, seconds, remainder)
        }
        return String(format: "%02d:%02d:%02d", minutes, seconds, remainder)
    }
}
