import Foundation

/// The per-lane level control: a gain stage over a lane's automation.
///
/// `AudioLane.volume` stores the level as a linear scalar, where `1.0` is
/// 0 dB. The control the user sees is in decibels, from silence up to
/// ``maxDB``, so everything that converts between the two lives here - the
/// header knob, playback, export and the model's clamp all read the same
/// numbers.
///
/// Silence is not a very small number. A level at or below ``floorDB`` is
/// exactly zero gain and reads as "-infinity", the way a console fader's
/// bottom stop does.
public enum LaneLevel {
    /// Unity, 0 dB: the lane plays at its recorded level.
    public static let unityDB: Float = 0

    /// Loudest level the control reaches, in decibels.
    public static let maxDB: Float = 12

    /// The level at or below which the lane is silent, in decibels.
    ///
    /// Matches the bottom of the automation envelope's range, so the two
    /// faders agree about how far down "down" goes.
    public static let floorDB: Float = VolumeAutomation.gainRange.lowerBound

    /// Resolution the knob rounds to, in decibels.
    ///
    /// Without it a drag lands on values like 0.0037 dB and unity is
    /// effectively unreachable; at a tenth of a decibel the readout shows
    /// exactly what is applied and 0 dB can be hit by hand.
    public static let stepDB: Float = 0.1

    /// Linear scalar for ``maxDB``, the largest value `AudioLane.volume` takes.
    public static let maxLinear: Float = VolumeAutomation.linearVolume(fromDB: maxDB)

    /// Linear scalar below which a stored level is treated as silent.
    private static let silentLinearThreshold: Float = VolumeAutomation.linearVolume(fromDB: floorDB)

    /// How far above unity gain the playback chain's player node can go.
    ///
    /// `AVAudioPlayerNode.volume` is documented 0...1 only, so anything above
    /// unity is handed to a per-clip EQ's `globalGain` instead (documented
    /// -96...+24 dB). This is that stage's ceiling.
    public static let maxBoostDB: Float = 24

    /// Text shown for a silent level.
    public static let silentReadout = "\u{2212}\u{221E}"

    /// Linear scalar for a level in decibels.
    ///
    /// - Parameter dB: Level in decibels. At or below ``floorDB`` (or not a
    ///   number) the result is `0`; above ``maxDB`` it is clamped to it.
    /// - Returns: Linear gain, `1.0` at 0 dB, `0` for silence.
    public static func linear(fromDB dB: Float) -> Float {
        guard !dB.isNaN, dB > floorDB else { return 0 }
        return VolumeAutomation.linearVolume(fromDB: min(dB, maxDB))
    }

    /// Level in decibels for a linear scalar.
    ///
    /// - Parameter linear: Linear gain as stored in `AudioLane.volume`.
    /// - Returns: Decibels, clamped to ``maxDB``; `-infinity` for a silent
    ///   level.
    public static func dB(fromLinear linear: Float) -> Float {
        guard !linear.isNaN, linear > silentLinearThreshold else { return -.infinity }
        return min(maxDB, 20 * log10(linear))
    }

    /// Clamps a linear level to what the control can express.
    ///
    /// - Parameter linear: Any proposed `AudioLane.volume`.
    /// - Returns: A value in `0...maxLinear`. A non-number becomes unity,
    ///   rather than silencing a lane by accident.
    public static func clampedLinear(_ linear: Float) -> Float {
        guard !linear.isNaN else { return 1 }
        return min(max(linear, 0), maxLinear)
    }

    /// Knob position (0 at the bottom stop, 1 at ``maxDB``) for a linear
    /// level. The scale is linear in decibels between ``floorDB`` and
    /// ``maxDB``, not in amplitude.
    ///
    /// - Parameter linear: Linear gain as stored in `AudioLane.volume`.
    /// - Returns: A position in `0...1`.
    public static func position(fromLinear linear: Float) -> Double {
        let dB = dB(fromLinear: linear)
        guard dB.isFinite else { return 0 }
        return Double((dB - floorDB) / (maxDB - floorDB))
    }

    /// Linear level for a knob position, rounded to ``stepDB``.
    ///
    /// - Parameter position: Knob position, clamped to `0...1`. `0` is
    ///   silence.
    /// - Returns: Linear gain suitable for `AudioLane.volume`.
    public static func linear(fromPosition position: Double) -> Float {
        let clamped = Float(min(max(position, 0), 1))
        return linear(fromSteppedDB: floorDB + clamped * (maxDB - floorDB))
    }

    /// Linear level for a decibel value rounded to ``stepDB``.
    ///
    /// - Parameter dB: Any level; at or below ``floorDB`` is silence, above
    ///   ``maxDB`` is clamped.
    /// - Returns: Linear gain suitable for `AudioLane.volume`.
    public static func linear(fromSteppedDB dB: Float) -> Float {
        linear(fromDB: (dB / stepDB).rounded() * stepDB)
    }

    /// The readout text for a level.
    ///
    /// - Parameter linear: Linear gain as stored in `AudioLane.volume`.
    /// - Returns: "−∞" for silence, otherwise one decimal place and a "dB"
    ///   unit, signed above unity ("+3.0 dB", "−6.0 dB", "0.0 dB").
    public static func readout(fromLinear linear: Float) -> String {
        let dB = dB(fromLinear: linear)
        guard dB.isFinite else { return silentReadout }
        let rounded = (dB / stepDB).rounded() * stepDB
        if abs(rounded) < stepDB / 2 { return "0.0 dB" }
        return String(format: "%+.1f dB", rounded).replacingOccurrences(of: "-", with: "\u{2212}")
    }

    /// Splits a total playback gain between the player node and a boost stage.
    ///
    /// - Parameter totalLinear: The clip's whole gain: clip volume x lane
    ///   level x automation, with mute/solo already folded in.
    /// - Returns: `playerVolume` in `0...1` for `AVAudioPlayerNode.volume`
    ///   and `boostDB` (zero or positive, at most ``maxBoostDB``) for the
    ///   clip's EQ `globalGain`. Their product is `totalLinear`.
    public static func splitPlaybackGain(totalLinear: Float) -> (playerVolume: Float, boostDB: Float) {
        guard totalLinear.isFinite, totalLinear > 0 else { return (0, 0) }
        guard totalLinear > 1 else { return (totalLinear, 0) }
        return (1, min(maxBoostDB, 20 * log10(totalLinear)))
    }
}
