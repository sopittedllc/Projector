//
//  LaneLevelExportTests.swift
//  ProjectorTests
//
//  The lane level reaches export through `AVAudioMix` volumes above 1.0 (up to
//  +12 dB). Apple documents no range for those, so this renders through the
//  same `QuickTimeDemoBuilder.export` the app uses and measures the result: if
//  an OS update starts clamping, this fails instead of exports quietly losing
//  the boost.
//

import XCTest
import AVFoundation
@testable import Projector
import SwiftTimecodeCore

@MainActor
final class LaneLevelExportTests: XCTestCase {

    private enum Fixture {
        static let sampleRate = 48_000.0
        static let toneFrequency = 1_000.0
        static let toneSeconds = 1.0
        /// -20 dBFS, so +12 dB peaks near -8 dBFS with headroom for the AAC encode.
        static let toneAmplitude: Float = 0.1
        /// Skips the encoder's priming at the head and the tail's fade.
        static let measureFromSeconds = 0.25
        static let measureToSeconds = 0.75
        static let toleranceDB: Float = 1
    }

    /// Exports a tone with `levelDB` applied the way the builder applies a
    /// lane's level, and returns the exported peak in linear terms.
    private func exportedPeak(levelDB: Float) async throws -> Float {
        let toneURL = try TestAudioFileFactory.makeToneFile(
            duration: Fixture.toneSeconds,
            sampleRate: Fixture.sampleRate,
            frequency: Fixture.toneFrequency,
            amplitude: Fixture.toneAmplitude
        )
        defer { try? FileManager.default.removeItem(at: toneURL) }

        let asset = AVURLAsset(url: toneURL)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
            throw XCTSkip("Generated tone has no audio track.")
        }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw XCTSkip("Could not add a composition track.")
        }
        let duration = CMTime(seconds: Fixture.toneSeconds, preferredTimescale: CMTimeScale(Fixture.sampleRate))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)

        // Through the builder's own arithmetic: trim 0 + the lane's level.
        let span = QuickTimeDemoSpan(spec: QuickTimeDemoSpec(
            wavURL: toneURL, wavStartFrame: 0, wavDurationFrames: 24
        ))
        let mix = AVMutableAudioMix()
        mix.inputParameters = [QuickTimeDemoBuilder.mixParameters(
            for: track, trimDB: levelDB, automation: nil, span: span, rate: .fps24
        )]

        let demo = QuickTimeDemo(
            composition: composition,
            audioMix: mix,
            span: span,
            hasPicture: false,
            mixTrackID: nil,
            laneTrackIDs: [:],
            rate: .fps24,
            laneAutomation: [:],
            securityScopedResources: []
        )

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaneLevelExportTests-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }
        try await QuickTimeDemoBuilder.export(demo, to: output, onProgress: { _ in })

        return try peak(of: output)
    }

    private func peak(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let start = AVAudioFramePosition(Fixture.measureFromSeconds * rate)
        let count = AVAudioFrameCount((Fixture.measureToSeconds - Fixture.measureFromSeconds) * rate)
        file.framePosition = start
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
            throw XCTSkip("Could not allocate a read buffer.")
        }
        try file.read(into: buffer, frameCount: count)
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(channel[$1])) }
    }

    func testExportHonoursAMixVolumeAboveUnity() async throws {
        let reference = try await exportedPeak(levelDB: 0)
        let boosted = try await exportedPeak(levelDB: LaneLevel.maxDB)

        XCTAssertGreaterThan(reference, 0, "The reference export must not be silent")
        let measuredDB = 20 * log10(boosted / reference)
        XCTAssertEqual(
            measuredDB, LaneLevel.maxDB, accuracy: Fixture.toleranceDB,
            "AVAssetExportSession must render a +12 dB mix volume as +12 dB; if this fails the OS now clamps volumes at unity"
        )
    }

    func testSilentLaneLevelPrintsSilence() async throws {
        let peak = try await exportedPeak(levelDB: QuickTimeDemoBuilder.silentDB)
        XCTAssertLessThan(peak, 0.001)
    }

    // MARK: - Mix construction

    /// The live preview (`makeAudioMix`) must apply the level the same way the
    /// build and the export do.
    func testMakeAudioMixFoldsLaneLevelIntoTheTrim() throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw XCTSkip("Could not add a composition track.")
        }
        let laneId = UUID()
        let silentLaneId = UUID()
        let span = QuickTimeDemoSpan(spec: QuickTimeDemoSpec(
            wavURL: URL(fileURLWithPath: "/tmp/LaneLevelExportTests-mix.wav"), wavStartFrame: 0, wavDurationFrames: 24
        ))
        let demo = QuickTimeDemo(
            composition: composition,
            audioMix: AVMutableAudioMix(),
            span: span,
            hasPicture: false,
            mixTrackID: nil,
            laneTrackIDs: [laneId: track.trackID],
            rate: .fps24,
            laneAutomation: [:],
            laneLevelDB: [laneId: 6, silentLaneId: -.infinity],
            securityScopedResources: []
        )
        var spec = demo.spec(forTests: span)
        spec.lanes = [QuickTimeDemoLaneChoice(id: laneId, name: "Lane", isIncluded: true, gainDB: -2)]

        let mix = QuickTimeDemoBuilder.makeAudioMix(for: demo, spec: spec)

        let parameters = try XCTUnwrap(mix.inputParameters.first)
        var start: Float = 0
        var end: Float = 0
        var range = CMTimeRange.zero
        _ = parameters.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range)
        XCTAssertEqual(start, VolumeAutomation.linearVolume(fromDB: 4), accuracy: 1e-5, "Trim -2 dB plus level +6 dB")
    }
}

private extension QuickTimeDemo {
    func spec(forTests span: QuickTimeDemoSpan) -> QuickTimeDemoSpec {
        QuickTimeDemoSpec(
            wavURL: URL(fileURLWithPath: "/tmp/LaneLevelExportTests-mix.wav"),
            wavStartFrame: span.startFrame,
            wavDurationFrames: span.durationFrames
        )
    }
}
