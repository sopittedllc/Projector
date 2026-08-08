//
//  QuickTimeDemoBuilder.swift
//  Projector
//
//  Builds a review QuickTime: the picture on the timeline against a stereo mix
//  the user supplies, with a chosen set of lanes underneath it.
//

import AVFoundation
import Foundation
import SwiftTimecodeCore

/// A lane offered for inclusion in a demo, with the level it will be printed at.
struct QuickTimeDemoLaneChoice: Identifiable, Equatable {
    let id: UUID
    let name: String
    var isIncluded: Bool
    /// Level relative to the lane's own recorded level, in decibels.
    var gainDB: Float

    init(id: UUID, name: String, isIncluded: Bool = false, gainDB: Float = 0) {
        self.id = id
        self.name = name
        self.isIncluded = isIncluded
        self.gainDB = gainDB
    }
}

/// Everything a demo needs that the timeline does not already know.
struct QuickTimeDemoSpec: Equatable {
    /// The stereo mix the demo is built around.
    var wavURL: URL

    /// Where that mix belongs, as a frame on the timeline's own grid.
    ///
    /// Derived from the file's embedded timecode via
    /// `EmbeddedTimecodeResult.convertedFrames(to:)`, which carries a timecode
    /// *address* between counting grids. Never scale by the ratio of two rates:
    /// 23.976 and 24 spell an address identically, and treating one as a speed
    /// put a reel 101 frames late once already.
    var wavStartFrame: Int

    /// Length of the mix, in timeline frames.
    var wavDurationFrames: Int

    /// Level for the supplied mix, in decibels.
    var wavGainDB: Float = 0

    /// Lanes on the timeline, in timeline order, with their inclusion and level.
    var lanes: [QuickTimeDemoLaneChoice] = []

    /// Extra picture to print before the mix starts, in frames.
    var headFrames: Int = 0

    /// Extra picture to print after the mix ends, in frames.
    var tailFrames: Int = 0
}

/// The frame range a demo covers.
///
/// Pure arithmetic, kept separate so it can be tested without building a
/// composition or touching a file.
struct QuickTimeDemoSpan: Equatable {
    let startFrame: Int
    let endFrame: Int

    var durationFrames: Int { max(0, endFrame - startFrame) }

    /// The demo's own frame for a timeline frame, which is simply the offset
    /// from its start.
    func offset(ofTimelineFrame frame: Int) -> Int { frame - startFrame }

    /// - Parameter spec: The demo being built.
    init(spec: QuickTimeDemoSpec) {
        // Clamped at 0 because a mix delivered at the very head of the timeline
        // cannot have picture before it, and a negative start would ask the
        // composition for a time that does not exist.
        startFrame = max(0, spec.wavStartFrame - max(0, spec.headFrames))

        // Deliberately *not* clamped to the timeline's duration: a mix may run
        // past the last reel, and the honest answer there is black picture with
        // the audio continuing rather than a demo that stops early.
        endFrame = spec.wavStartFrame + max(0, spec.wavDurationFrames) + max(0, spec.tailFrames)
    }
}

/// A built demo, ready to preview or export.
///
/// The composition is the *same* object both paths use, which is the point: a
/// preview built from a different graph than the encode is a preview of
/// something else.
struct QuickTimeDemo {
    let composition: AVMutableComposition
    let audioMix: AVAudioMix
    let span: QuickTimeDemoSpan

    /// Whether any picture was found for this span. A demo with none is still
    /// valid - it is black - but the caller may want to say so.
    let hasPicture: Bool

    /// The composition track carrying the supplied mix.
    let mixTrackID: CMPersistentTrackID?

    /// Which composition track carries which lane.
    ///
    /// Kept so a level change can rebuild the *mix* alone and hand it to the
    /// player already playing this composition. Rebuilding the composition
    /// instead would restart the preview from the top every time a fader moved,
    /// which is exactly when you want to keep listening to the same moment.
    let laneTrackIDs: [UUID: CMPersistentTrackID]
}

enum QuickTimeDemoError: LocalizedError {
    case mixHasNoTimecode
    case mixUnreadable(URL)
    case nothingToPrint
    case exportSetupFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .mixHasNoTimecode:
            return "This file carries no timecode, so there is nowhere to place it "
                + "against the picture. A BWF from a DAW bounce normally has one."
        case .mixUnreadable(let url):
            return "\"\(url.lastPathComponent)\" could not be read."
        case .nothingToPrint:
            return "There is no picture or audio in this range to print."
        case .exportSetupFailed:
            return "The QuickTime encoder could not be started."
        case .exportFailed(let reason):
            return "Encoding failed: \(reason)"
        }
    }
}

/// Assembles and encodes a review QuickTime.
///
/// ## Why this is main-actor rather than an actor
///
/// It holds no state and does no real-time work: every method is a pure
/// transformation of the timeline plus a spec. `AVMutableComposition` and
/// `AVAudioMix` are not `Sendable`, so handing them across an isolation
/// boundary would be a warning at best and a data race at worst, while the
/// actual expensive work - decoding and encoding - happens inside
/// `AVAssetExportSession` on its own threads regardless of who asked for it.
///
/// It imports no SwiftUI, in keeping with the layer rules.
@MainActor
struct QuickTimeDemoBuilder {

    /// Frames per decibel is not a thing - this is the conversion from the
    /// decibels the user sets to the linear scalar AVFoundation wants.
    ///
    /// - Parameter dB: Level in decibels.
    /// - Returns: A linear volume, 1.0 at 0 dB.
    static func linearVolume(fromDB dB: Float) -> Float {
        pow(10, dB / 20)
    }

    /// Build the composition and mix for a demo.
    ///
    /// Reels and clips are inserted only where they overlap the span, trimmed to
    /// it, and offset so the span's first frame is time zero. Gaps are left
    /// empty, which a composition renders as black and silence - that is what
    /// makes head and tail beyond the picture behave sensibly.
    ///
    /// - Parameters:
    ///   - timeline: The timeline to print.
    ///   - spec: The mix, the lane choices and the handles.
    /// - Returns: The composition, its mix, and the span they cover.
    static func makeDemo(timeline: Timeline, spec: QuickTimeDemoSpec) async throws -> QuickTimeDemo {
        let span = QuickTimeDemoSpan(spec: spec)
        guard span.durationFrames > 0 else { throw QuickTimeDemoError.nothingToPrint }

        let rate = timeline.config.frameRate
        let composition = AVMutableComposition()
        var inputParameters: [AVAudioMixInputParameters] = []
        var mixTrackID: CMPersistentTrackID?
        var laneTrackIDs: [UUID: CMPersistentTrackID] = [:]

        let hasPicture = try await insertPicture(
            from: timeline,
            span: span,
            rate: rate,
            into: composition
        )

        // The supplied mix first, so it is the demo's primary audio track and
        // reads as such in anything that lists tracks.
        if let mixTrack = try await insertAudio(
            url: spec.wavURL,
            bookmark: nil,
            sourceStartFrame: 0,
            timelineStartFrame: spec.wavStartFrame,
            durationFrames: spec.wavDurationFrames,
            span: span,
            rate: rate,
            into: composition
        ) {
            inputParameters.append(mixParameters(for: mixTrack, gainDB: spec.wavGainDB))
            mixTrackID = mixTrack.trackID
        }

        // *Every* lane goes into the composition, included or not, and inclusion
        // is expressed in the mix instead. Building only the included ones meant
        // ticking a lane rebuilt the composition, which handed the preview a new
        // player item and restarted it from the top - so the one control you use
        // while listening was the one that stopped the listening.
        for choice in spec.lanes {
            guard let lane = timeline.audioLanes.first(where: { $0.id == choice.id }) else { continue }

            // One composition track per lane, so a lane keeps one level even
            // when it holds several clips.
            guard let laneTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            for clip in lane.clips where clip.isMuted == false {
                try await insert(
                    clip: clip,
                    span: span,
                    rate: rate,
                    into: laneTrack
                )
            }

            // A lane whose clips all fell outside the span contributes nothing;
            // leaving the empty track in would print silence and an extra track.
            if laneTrack.segments.isEmpty {
                composition.removeTrack(laneTrack)
                continue
            }

            // The number on the slider is the number applied. `AudioLane.volume`
            // is deliberately left out: there is no control for it anywhere in
            // the app, so folding it in would mean the printed level differed
            // from the one on screen for a reason the user could not see.
            let gain = choice.isIncluded ? choice.gainDB : Self.silentDB
            inputParameters.append(mixParameters(for: laneTrack, gainDB: gain))
            laneTrackIDs[lane.id] = laneTrack.trackID
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters

        guard hasPicture || !inputParameters.isEmpty else {
            throw QuickTimeDemoError.nothingToPrint
        }

        return QuickTimeDemo(
            composition: composition,
            audioMix: audioMix,
            span: span,
            hasPicture: hasPicture,
            mixTrackID: mixTrackID,
            laneTrackIDs: laneTrackIDs
        )
    }

    /// Rebuild only the levels for a demo that is already built.
    ///
    /// Lets a fader move without reassembling the composition, so the preview
    /// keeps playing the moment being judged. Which lanes are included, and the
    /// handles, still need a rebuild - those change what is in the composition,
    /// not how loud it is.
    ///
    /// - Parameters:
    ///   - demo: A demo from ``makeDemo(timeline:spec:)``.
    ///   - spec: The levels to apply.
    ///   - timeline: Source of each lane's own recorded level.
    /// - Returns: A mix to hand to the player item or the export session.
    static func makeAudioMix(
        for demo: QuickTimeDemo,
        spec: QuickTimeDemoSpec
    ) -> AVAudioMix {
        var inputParameters: [AVAudioMixInputParameters] = []

        if let mixTrackID = demo.mixTrackID,
           let track = demo.composition.track(withTrackID: mixTrackID) {
            inputParameters.append(mixParameters(for: track, gainDB: spec.wavGainDB))
        }

        for choice in spec.lanes {
            guard let trackID = demo.laneTrackIDs[choice.id],
                  let track = demo.composition.track(withTrackID: trackID) else { continue }

            // An excluded lane is silenced rather than removed - the composition
            // is not being rebuilt here, and silence is the same result.
            let gain = choice.isIncluded ? choice.gainDB : Self.silentDB
            inputParameters.append(mixParameters(for: track, gainDB: gain))
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = inputParameters
        return mix
    }

    /// Low enough to be silence at any bit depth, without being `-infinity`.
    static let silentDB: Float = -120

    // MARK: - Export

    /// Encode a demo to a QuickTime file.
    ///
    /// `AVAssetExportPreset1920x1080` is H.264 in a `.mov`, and a preset only
    /// ever scales *down* - so a 4K reel is capped at 1080p while an HD one is
    /// printed at its own size. **Frame rate is left alone**, which is the whole
    /// reason the media-optimisation preset is not reused here: that one caps at
    /// 30fps, and a 23.976 reel resampled to 30 is useless for judging sync.
    ///
    /// - Parameters:
    ///   - demo: The built demo.
    ///   - destination: Where to write. Overwritten if it exists.
    ///   - onProgress: Called on the main actor with 0...1.
    static func export(
        _ demo: QuickTimeDemo,
        to destination: URL,
        onProgress: @escaping @MainActor (Float) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(
            asset: demo.composition,
            presetName: AVAssetExportPreset1920x1080
        ) else {
            throw QuickTimeDemoError.exportSetupFailed
        }

        session.outputURL = destination
        session.outputFileType = .mov
        session.audioMix = demo.audioMix
        session.shouldOptimizeForNetworkUse = true

        // Written fresh every time: an export session refuses to overwrite, and
        // the user has already agreed to the destination in a save panel.
        try? FileManager.default.removeItem(at: destination)

        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                onProgress(session.progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { ticker.cancel() }

        await session.export()

        switch session.status {
        case .completed:
            onProgress(1)
        case .cancelled:
            throw QuickTimeDemoError.exportFailed("cancelled")
        default:
            throw QuickTimeDemoError.exportFailed(
                session.error?.localizedDescription ?? "unknown error"
            )
        }
    }

    // MARK: - Picture

    /// Insert every reel that overlaps the span, trimmed to it.
    ///
    /// - Returns: Whether anything was inserted.
    private static func insertPicture(
        from timeline: Timeline,
        span: QuickTimeDemoSpan,
        rate: TimecodeFrameRate,
        into composition: AVMutableComposition
    ) async throws -> Bool {
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return false }

        for reel in timeline.sortedVideoReels {
            let overlapStart = max(reel.timelineStartFrame, span.startFrame)
            let overlapEnd = min(reel.timelineEndFrame, span.endFrame)
            guard overlapEnd > overlapStart else { continue }

            let asset = try resolvedAsset(url: reel.sourceURL, bookmark: reel.sourceBookmark)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else { continue }

            let sourceStart = reel.sourceStartFrame + (overlapStart - reel.timelineStartFrame)
            let range = CMTimeRange(
                start: time(forFrame: sourceStart, at: rate),
                duration: time(forFrame: overlapEnd - overlapStart, at: rate)
            )

            try videoTrack.insertTimeRange(
                range,
                of: sourceTrack,
                at: time(forFrame: span.offset(ofTimelineFrame: overlapStart), at: rate)
            )
        }

        if videoTrack.segments.isEmpty {
            composition.removeTrack(videoTrack)
            return false
        }
        return true
    }

    // MARK: - Audio

    /// Insert one clip into a lane's composition track, trimmed to the span.
    private static func insert(
        clip: AudioClip,
        span: QuickTimeDemoSpan,
        rate: TimecodeFrameRate,
        into track: AVMutableCompositionTrack
    ) async throws {
        let overlapStart = max(clip.timelineStartFrame, span.startFrame)
        let overlapEnd = min(clip.timelineEndFrame, span.endFrame)
        guard overlapEnd > overlapStart else { return }

        // Tracks past the first live in an extracted file, because a container's
        // second audio track cannot be played directly - the same rule playback
        // follows.
        let url = clip.extractedAudioURL ?? clip.sourceURL
        let bookmark = clip.extractedAudioURL == nil ? clip.sourceBookmark : nil

        let asset = try resolvedAsset(url: url, bookmark: bookmark)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { return }

        let sourceStart = clip.sourceStartFrame + (overlapStart - clip.timelineStartFrame)
        let range = CMTimeRange(
            start: time(forFrame: sourceStart, at: rate),
            duration: time(forFrame: overlapEnd - overlapStart, at: rate)
        )

        try track.insertTimeRange(
            range,
            of: sourceTrack,
            at: time(forFrame: span.offset(ofTimelineFrame: overlapStart), at: rate)
        )
    }

    /// Insert a whole file as its own audio track, trimmed to the span.
    ///
    /// - Returns: The track it went on, or `nil` if nothing overlapped.
    private static func insertAudio(
        url: URL,
        bookmark: Data?,
        sourceStartFrame: Int,
        timelineStartFrame: Int,
        durationFrames: Int,
        span: QuickTimeDemoSpan,
        rate: TimecodeFrameRate,
        into composition: AVMutableComposition
    ) async throws -> AVMutableCompositionTrack? {
        let clip = AudioClip(
            sourceURL: url,
            sourceBookmark: bookmark,
            timelineStartFrame: timelineStartFrame,
            durationFrames: durationFrames,
            sourceStartFrame: sourceStartFrame,
            sourceType: .audioFile,
            channelCount: 2,
            sampleRate: 48_000
        )

        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }

        try await insert(clip: clip, span: span, rate: rate, into: track)

        if track.segments.isEmpty {
            composition.removeTrack(track)
            return nil
        }
        return track
    }

    private static func mixParameters(
        for track: AVCompositionTrack,
        gainDB: Float
    ) -> AVAudioMixInputParameters {
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(linearVolume(fromDB: gainDB), at: .zero)
        return parameters
    }

    // MARK: - Files and Time

    /// An asset for a file the app may only reach through a bookmark.
    ///
    /// Security-scoped access is started and deliberately not stopped: the
    /// composition reads from this asset for as long as it is previewed or
    /// exported, and revoking access at the end of this function would leave a
    /// composition that decodes to nothing.
    private static func resolvedAsset(url: URL, bookmark: Data?) throws -> AVURLAsset {
        guard let bookmark else { return AVURLAsset(url: url) }

        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return AVURLAsset(url: url)
        }

        _ = resolved.startAccessingSecurityScopedResource()
        return AVURLAsset(url: resolved)
    }

    /// A frame count as an exact time.
    ///
    /// Built from the rate's frame duration as a rational, matching
    /// `VideoReel.sourceFrameDuration`. A 600-tick timescale cannot express a
    /// 23.976 frame boundary - 25.025 ticks - which is what left every seek a
    /// frame either way before it was fixed.
    private static func time(forFrame frame: Int, at rate: TimecodeFrameRate) -> CMTime {
        let duration = rate.frameDuration
        return CMTime(
            value: CMTimeValue(frame) * CMTimeValue(duration.numerator),
            timescale: CMTimeScale(duration.denominator)
        )
    }
}
