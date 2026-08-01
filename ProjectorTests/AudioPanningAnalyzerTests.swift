//
//  AudioPanningAnalyzerTests.swift
//  ProjectorTests
//
//  Tests for the hard-panning detector itself: what it calls a split and what
//  it leaves alone. HardPannedSplitTests covers what happens once a split is
//  accepted; nothing covered the decision to offer one.
//

import XCTest
import AVFoundation
@testable import Projector

final class AudioPanningAnalyzerTests: XCTestCase {

    // MARK: - Fixtures

    private enum Fixture {
        static let sampleRate = 48000.0
        static let seconds = 8.0
    }

    private var written: [URL] = []

    override func tearDownWithError() throws {
        for url in written { try? FileManager.default.removeItem(at: url) }
        written = []
        try super.tearDownWithError()
    }

    private func stereoFile(_ sample: @escaping (Int, Int) -> Float) throws -> URL {
        let url = try TestAudioFileFactory.makeStereoFile(
            duration: Fixture.seconds,
            sampleRate: Fixture.sampleRate,
            sample: sample
        )
        written.append(url)
        return url
    }

    private func tone(_ hz: Double, _ frame: Int, amplitude: Float = 0.4) -> Float {
        Float(sin(2 * .pi * hz * Double(frame) / Fixture.sampleRate)) * amplitude
    }

    // MARK: - Split Detection

    func testUnrelatedChannelsAreASplit() async throws {
        // Dialogue-ish left, music-ish right: the deliverable this exists for.
        let url = try stereoFile { channel, frame in
            channel == 0
                ? self.tone(180, frame)
                : self.tone(440, frame) + self.tone(660, frame, amplitude: 0.2)
        }

        let analysis = try await AudioPanningAnalyzer.analyze(url: url)

        let result = try XCTUnwrap(analysis)
        XCTAssertTrue(result.isHardPanned)
        XCTAssertLessThan(abs(result.correlation), 0.2)
    }

    func testOneSilentChannelIsStillASplit() async throws {
        // A reel exported with a dead side. Splitting is how the user sees the
        // mistake - the empty lane draws flat beside a full one - so this must
        // be offered rather than quietly suppressed.
        let url = try stereoFile { channel, frame in
            channel == 0 ? self.tone(200, frame) : 0
        }

        let analysis = try await AudioPanningAnalyzer.analyze(url: url)

        let result = try XCTUnwrap(analysis)
        XCTAssertTrue(result.isHardPanned)
        XCTAssertEqual(result.rightRMS, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(result.leftRMS, 0.001)
    }

    func testSilenceOnBothSidesIsNotASplit() async throws {
        // Correlates with nothing, so it looks like a perfect split, but there
        // is nothing there to separate.
        let url = try stereoFile { _, _ in 0 }

        let analysis = try await AudioPanningAnalyzer.analyze(url: url)

        let result = try XCTUnwrap(analysis)
        XCTAssertFalse(result.isHardPanned)
    }

    // MARK: - Content That Must Be Left Alone

    func testMonoInAStereoFileIsNotASplit() async throws {
        let url = try stereoFile { _, frame in self.tone(220, frame) }

        let analysis = try await AudioPanningAnalyzer.analyze(url: url)

        let result = try XCTUnwrap(analysis)
        XCTAssertFalse(result.isHardPanned)
        XCTAssertGreaterThan(result.correlation, 0.9)
    }

    func testOrdinaryStereoMixIsNotASplit() async throws {
        // Shared content with a little per-side width, which is every stereo
        // mix ever made. A false positive here restructures a real timeline.
        let url = try stereoFile { channel, frame in
            let common = self.tone(220, frame)
            let wide = self.tone(331, frame, amplitude: 0.08)
            return channel == 0 ? common + wide : common - wide
        }

        let analysis = try await AudioPanningAnalyzer.analyze(url: url)

        let result = try XCTUnwrap(analysis)
        XCTAssertFalse(result.isHardPanned)
    }

    // MARK: - Nothing To Analyze

    func testMonoFileReturnsNil() async throws {
        // Not stereo, so there is no pair to compare - not an error.
        let url = try TestAudioFileFactory.makeSineWaveFile(duration: Fixture.seconds)
        written.append(url)

        let analysis = try await AudioPanningAnalyzer.analyze(url: url)

        XCTAssertNil(analysis)
    }
}
