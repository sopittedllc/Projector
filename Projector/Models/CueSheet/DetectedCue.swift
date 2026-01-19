import Foundation
import SwiftTimecodeCore

/// A detected audio activity segment
struct DetectedCue: Identifiable, Sendable {
    let id: UUID
    let number: Int
    let startFrame: Int
    let endFrame: Int
    let timecodeIn: Timecode
    let timecodeOut: Timecode

    var durationFrames: Int {
        endFrame - startFrame
    }

    func durationTimecode(at frameRate: TimecodeFrameRate) -> Timecode {
        Timecode(.frames(durationFrames), at: frameRate, by: .clamping)
    }
}
