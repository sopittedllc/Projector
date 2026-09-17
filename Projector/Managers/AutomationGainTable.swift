import Foundation

/// Precomputed gain lookup so the live-playback per-frame hook never has to
/// walk the timeline or read a raw envelope value.
///
/// ## Why this exists
///
/// ``PlaybackEngine`` gains a `currentFrame` `didSet` (plan §3.3) that fires
/// on every scrub tick and every frame of playback. That hook must be cheap:
/// no timeline traversal, no allocation beyond the dictionary it hands back,
/// no repeated envelope evaluation for clips that share a lane. This type is
/// built once per ``Timeline`` assignment (`PlaybackEngine.updateTimelineProperties()`,
/// which already runs on every timeline mutation because `Timeline` is a
/// value type) and answers every subsequent lookup from plain dictionaries.
///
/// ## What it folds in
///
/// `baseGain` is exactly what `PlaybackEngine.playbackGain(for:lane:)`
/// computed before automation existed - mute, solo, "None" output and the
/// clip/lane volume sliders, via `Timeline.isLaneAudible(_:)` - so adding
/// automation never changes what silences a clip, only what attenuates an
/// already-audible one.
///
/// `automatedLanes` holds only lanes that are both in
/// `Timeline.standaloneAudioLanes` and carry a non-unity envelope (plan
/// §2.5): a linked lane's automation is retained in the model but never
/// evaluated here, and a unity envelope is indistinguishable from "no
/// automation" for playback purposes, so it is left out rather than
/// evaluated to `1.0` on every frame.
struct AutomationGainTable: Sendable {
    /// The lane each clip belongs to, so a clip id can find its lane's
    /// envelope (if any) without a timeline lookup.
    private let laneOfClip: [UUID: UUID]

    /// `clip.volume * lane.volume` with mute/solo/"None" already folded in
    /// (`0` for an inaudible clip), keyed by clip id. This is the base the
    /// envelope multiplies, never the other way around, so automation can
    /// only ever attenuate further - matching the attenuation-only range.
    private let baseGain: [UUID: Float]

    /// Non-unity envelopes on standalone lanes only, keyed by lane id.
    private let automatedLanes: [UUID: VolumeAutomation]

    /// Clips on automated lanes, computed once here rather than on every
    /// frame: the per-frame hook asks for this list at frame rate, and a
    /// walk over every clip on the timeline per tick is exactly the cost the
    /// table exists to avoid.
    private let automatedClips: [UUID]

    /// Builds the table from a snapshot of the timeline.
    ///
    /// - Parameter timeline: The timeline to derive gains and envelopes
    ///   from. A later timeline mutation requires a new table; this type
    ///   holds no reference back to `timeline` and does not observe it.
    init(timeline: Timeline) {
        var laneOfClip: [UUID: UUID] = [:]
        var baseGain: [UUID: Float] = [:]
        var automatedLanes: [UUID: VolumeAutomation] = [:]

        let standaloneLaneIds = Set(timeline.standaloneAudioLanes.map(\.id))

        for lane in timeline.audioLanes {
            let laneAudible = timeline.isLaneAudible(lane)
            for clip in lane.clips {
                laneOfClip[clip.id] = lane.id
                baseGain[clip.id] = (laneAudible && !clip.isMuted) ? clip.volume * lane.volume : 0
            }

            if standaloneLaneIds.contains(lane.id), let automation = lane.automation, !automation.isUnity {
                automatedLanes[lane.id] = automation
            }
        }

        self.laneOfClip = laneOfClip
        self.baseGain = baseGain
        self.automatedLanes = automatedLanes
        self.automatedClips = laneOfClip.compactMap { clipId, laneId in
            automatedLanes[laneId] != nil ? clipId : nil
        }
    }

    /// Whether any lane in this table has a live envelope.
    ///
    /// The per-frame hook checks this first and returns immediately when
    /// `false`, so a project with no automation anywhere pays nothing for
    /// this feature on every tick.
    var hasAutomation: Bool {
        !automatedLanes.isEmpty
    }

    /// Whether `clipId` was present in the timeline this table was built
    /// from.
    ///
    /// Used by ``PlaybackEngine/playbackGain(for:lane:)`` to detect a clip
    /// added after this table was built - within the same edit that
    /// produced the current `timeline`, before the rebuild in
    /// `updateTimelineProperties()` runs - and fall back to a direct
    /// computation rather than reading `gain(forClip:at:)`'s unknown-clip
    /// value of `0`, which would otherwise be indistinguishable from a
    /// muted clip and go silent for a frame.
    ///
    /// - Parameter clipId: The clip to check.
    /// - Returns: `true` if this table has a base gain recorded for it.
    func knowsClip(_ clipId: UUID) -> Bool {
        baseGain[clipId] != nil
    }

    /// The gain to play `clipId` at, at `frame`.
    ///
    /// - Parameters:
    ///   - clipId: The clip to look up.
    ///   - frame: The timeline frame to evaluate the clip's lane envelope
    ///     at, if it has one.
    /// - Returns: `0` for a clip not present in this table (see
    ///   ``knowsClip(_:)``) or an inaudible one; otherwise the clip's base
    ///   gain, multiplied by its lane's envelope gain if it is automated.
    func gain(forClip clipId: UUID, at frame: Int) -> Float {
        guard let base = baseGain[clipId] else { return 0 }
        guard let laneId = laneOfClip[clipId], let automation = automatedLanes[laneId] else {
            return base
        }
        return base * automation.linearGain(at: frame)
    }

    /// Clip ids that live on an automated lane.
    ///
    /// The only clips the per-frame hook needs to touch: every other loaded
    /// clip's gain does not change between one frame and the next, so
    /// leaving its `AVAudioPlayerNode.volume` alone is both correct and
    /// cheaper than reassigning the same value.
    ///
    /// - Returns: Empty when ``hasAutomation`` is `false`.
    func automatedClipIds() -> [UUID] {
        automatedClips
    }

    /// Batched gain lookup for a set of clips, evaluating each automated
    /// lane's envelope once regardless of how many of its clips are in
    /// `clipIds`.
    ///
    /// `gain(forClip:at:)` is correct but re-evaluates
    /// `VolumeAutomation.linearGain(at:)` per call; a lane with several
    /// clips (e.g. a music bed split across takes) would otherwise pay for
    /// the same interpolation once per clip, per frame. Returning a
    /// dictionary rather than taking an `inout` buffer keeps this type free
    /// of any assumption about how the caller stores results - the caller
    /// (`PlaybackEngine.applyAutomationGainIfNeeded()`) already needs a
    /// clip-id-keyed lookup to pair each gain with its `AVAudioPlayerNode`,
    /// so the dictionary is not an extra conversion, and its size is bounded
    /// by the automated clip count, not by anything that grows with
    /// playback time.
    ///
    /// - Parameters:
    ///   - frame: The timeline frame to evaluate envelopes at.
    ///   - clipIds: The clips to compute gains for. Typically
    ///     ``automatedClipIds()`` filtered to currently loaded players.
    /// - Returns: One gain per id in `clipIds`, using the same rules as
    ///   ``gain(forClip:at:)``.
    func gains(at frame: Int, forClips clipIds: some Sequence<UUID>) -> [UUID: Float] {
        var linearGainByLane: [UUID: Float] = [:]
        var result: [UUID: Float] = [:]

        for clipId in clipIds {
            guard let base = baseGain[clipId] else {
                result[clipId] = 0
                continue
            }
            guard let laneId = laneOfClip[clipId], let automation = automatedLanes[laneId] else {
                result[clipId] = base
                continue
            }
            let linear: Float
            if let cached = linearGainByLane[laneId] {
                linear = cached
            } else {
                linear = automation.linearGain(at: frame)
                linearGainByLane[laneId] = linear
            }
            result[clipId] = base * linear
        }

        return result
    }
}
