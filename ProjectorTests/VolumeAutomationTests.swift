//
//  VolumeAutomationTests.swift
//  ProjectorTests
//
//  Tests for the per-lane volume-automation envelope model: interpolation,
//  mutation invariants, decode normalization, full-span segment coverage,
//  the export ramp-count closed form, and the TimelineManager entry points
//  that read and write it.
//

import XCTest
@testable import Projector
import SwiftTimecodeCore

// MARK: - Model

final class VolumeAutomationTests: XCTestCase {

    // MARK: Unity / empty

    func testEmptyEnvelopeIsUnity() {
        let automation = VolumeAutomation()
        XCTAssertTrue(automation.isUnity)
        XCTAssertTrue(automation.points.isEmpty)
    }

    func testEmptyEnvelopeGainIsZeroEverywhere() {
        let automation = VolumeAutomation()
        XCTAssertEqual(automation.gainDB(at: -1000), 0)
        XCTAssertEqual(automation.gainDB(at: 0), 0)
        XCTAssertEqual(automation.gainDB(at: 1000), 0)
    }

    func testEnvelopeIsNotUnityWhenAnyPointIsNonZero() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -12)
        XCTAssertFalse(automation.isUnity)
    }

    func testEnvelopeIsUnityWhenEveryPointIsZero() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: 0)
        automation.insert(frame: 10, gainDB: 0)
        XCTAssertTrue(automation.isUnity)
    }

    // MARK: Interpolation

    func testSinglePointHoldsEverywhere() {
        var automation = VolumeAutomation()
        automation.insert(frame: 50, gainDB: -20)
        XCTAssertEqual(automation.gainDB(at: -1000), -20)
        XCTAssertEqual(automation.gainDB(at: 50), -20)
        XCTAssertEqual(automation.gainDB(at: 1000), -20)
    }

    func testTwoPointsMidpointIsTheDBMidpoint() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: 0)
        automation.insert(frame: 100, gainDB: -60)
        XCTAssertEqual(automation.gainDB(at: 50), -30, accuracy: 0.0001)
        XCTAssertEqual(automation.gainDB(at: 25), -15, accuracy: 0.0001)
        XCTAssertEqual(automation.gainDB(at: 75), -45, accuracy: 0.0001)
    }

    func testTwoPointsHoldBeforeAndAfter() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: 0)
        automation.insert(frame: 100, gainDB: -60)
        XCTAssertEqual(automation.gainDB(at: -10), 0)
        XCTAssertEqual(automation.gainDB(at: 200), -60)
    }

    func testLinearGainMatchesLinearVolumeOfGainDB() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -20)
        let expected = VolumeAutomation.linearVolume(fromDB: -20)
        XCTAssertEqual(automation.linearGain(at: 0), expected, accuracy: 0.0001)
    }

    // MARK: Mutation

    func testInsertReplacesGainOnExistingFrameKeepingId() {
        var automation = VolumeAutomation()
        let first = automation.insert(frame: 10, gainDB: -6)
        let second = automation.insert(frame: 10, gainDB: -12)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(automation.points.count, 1)
        XCTAssertEqual(automation.points[0].gainDB, -12)
    }

    func testInsertClampsGainToRangeAndRejectsNonFinite() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: 10)
        automation.insert(frame: 1, gainDB: -1000)
        automation.insert(frame: 2, gainDB: .nan)

        XCTAssertEqual(automation.points[0].gainDB, 0, "above range clamps to 0 dB")
        XCTAssertEqual(automation.points[1].gainDB, -60, "below range clamps to -60 dB")
        XCTAssertEqual(automation.points[2].gainDB, 0, "non-finite becomes unity, not clamped extreme")
    }

    func testInsertSortsNewPoints() {
        var automation = VolumeAutomation()
        automation.insert(frame: 100, gainDB: -10)
        automation.insert(frame: 0, gainDB: -20)
        automation.insert(frame: 50, gainDB: -30)
        XCTAssertEqual(automation.points.map(\.frame), [0, 50, 100])
    }

    func testMoveCannotCrossNeighbours() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: 0)
        let middle = automation.insert(frame: 50, gainDB: -10)
        automation.insert(frame: 100, gainDB: -20)

        automation.move(id: middle.id, toFrame: 1000, gainDB: -10)
        XCTAssertEqual(automation.points.first(where: { $0.id == middle.id })?.frame, 99)

        automation.move(id: middle.id, toFrame: -1000, gainDB: -10)
        XCTAssertEqual(automation.points.first(where: { $0.id == middle.id })?.frame, 1)
    }

    func testMoveClampsGainToRange() {
        var automation = VolumeAutomation()
        let point = automation.insert(frame: 0, gainDB: 0)
        automation.insert(frame: 100, gainDB: -10)

        automation.move(id: point.id, toFrame: 10, gainDB: 5)
        XCTAssertEqual(automation.points.first(where: { $0.id == point.id })?.gainDB, 0)

        automation.move(id: point.id, toFrame: 20, gainDB: -1000)
        XCTAssertEqual(automation.points.first(where: { $0.id == point.id })?.gainDB, -60)
    }

    func testMoveOnUnknownIdIsANoOp() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -6)
        automation.move(id: UUID(), toFrame: 10, gainDB: -20)
        XCTAssertEqual(automation.points.count, 1)
        XCTAssertEqual(automation.points[0].frame, 0)
        XCTAssertEqual(automation.points[0].gainDB, -6)
    }

    func testSetGainClampsToRange() {
        var automation = VolumeAutomation()
        let point = automation.insert(frame: 0, gainDB: 0)

        automation.setGain(id: point.id, gainDB: 5)
        XCTAssertEqual(automation.points[0].gainDB, 0)

        automation.setGain(id: point.id, gainDB: -100)
        XCTAssertEqual(automation.points[0].gainDB, -60)

        automation.setGain(id: point.id, gainDB: -30)
        XCTAssertEqual(automation.points[0].gainDB, -30)
        XCTAssertEqual(automation.points[0].frame, 0, "setGain never moves the point")
    }

    func testRemoveDeletesOnlyTheMatchingPoint() {
        var automation = VolumeAutomation()
        let doomed = automation.insert(frame: 0, gainDB: -6)
        automation.insert(frame: 10, gainDB: -12)

        automation.remove(id: doomed.id)

        XCTAssertEqual(automation.points.count, 1)
        XCTAssertNil(automation.points.first(where: { $0.id == doomed.id }))
    }

    func testRemoveAllReturnsToUnity() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -6)
        automation.insert(frame: 10, gainDB: -12)

        automation.removeAll()

        XCTAssertTrue(automation.points.isEmpty)
        XCTAssertTrue(automation.isUnity)
    }

    // MARK: mapFrames

    func testMapFramesKeepsNegativesAndResorts() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -6)
        automation.insert(frame: 10, gainDB: -12)

        automation.mapFrames { $0 - 20 }

        XCTAssertEqual(automation.points.map(\.frame), [-20, -10])
        XCTAssertEqual(automation.points.map(\.gainDB), [-6, -12])
    }

    func testMapFramesDedupesCollidingFramesKeepingTheLaterOne() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -6)
        automation.insert(frame: 1, gainDB: -12)

        automation.mapFrames { _ in 5 }

        XCTAssertEqual(automation.points.count, 1)
        XCTAssertEqual(automation.points[0].frame, 5)
        XCTAssertEqual(automation.points[0].gainDB, -12, "the point that was later (frame 1) wins the collision")
    }

    /// The §2.6 regression: a shift must be reversible, including through
    /// negative intermediate frames.
    func testShiftRegressionIsReversible() {
        var automation = VolumeAutomation()
        let first = automation.insert(frame: 0, gainDB: 0)
        let last = automation.insert(frame: 100, gainDB: -60)

        automation.mapFrames { $0 - 50 }
        XCTAssertEqual(automation.gainDB(at: 0), -30, accuracy: 0.01)
        XCTAssertEqual(automation.gainDB(at: 50), -60, accuracy: 0.01)

        automation.mapFrames { $0 + 50 }
        XCTAssertEqual(automation.points.count, 2)
        XCTAssertEqual(automation.points[0].frame, 0)
        XCTAssertEqual(automation.points[0].gainDB, 0)
        XCTAssertEqual(automation.points[0].id, first.id)
        XCTAssertEqual(automation.points[1].frame, 100)
        XCTAssertEqual(automation.points[1].gainDB, -60)
        XCTAssertEqual(automation.points[1].id, last.id)
    }

    // MARK: Decode normalization

    func testDecodeNormalizesUnsortedDuplicatesOutOfRangeAndMissingId() throws {
        let idA = UUID()
        let idB = UUID()
        let idHundred = UUID()
        let json = """
        {
            "points": [
                { "id": "\(idHundred.uuidString)", "frame": 100, "gainDB": -90 },
                { "frame": 0, "gainDB": 3 },
                { "id": "\(idA.uuidString)", "frame": 50, "gainDB": -12 },
                { "id": "\(idB.uuidString)", "frame": 50, "gainDB": -6 }
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VolumeAutomation.self, from: json)

        XCTAssertEqual(decoded.points.map(\.frame), [0, 50, 100], "sorted and deduped")
        XCTAssertEqual(decoded.points[0].gainDB, 0, "+3 dB clamps to 0")
        XCTAssertEqual(decoded.points[1].gainDB, -6, "duplicate frame 50 keeps the later JSON entry")
        XCTAssertEqual(decoded.points[1].id, idB)
        XCTAssertEqual(decoded.points[2].gainDB, -60, "-90 dB clamps to -60")
        XCTAssertEqual(decoded.points[2].id, idHundred)
    }

    func testDecodeRegeneratesDuplicateIds() throws {
        let sharedId = UUID()
        let json = """
        {
            "points": [
                { "id": "\(sharedId.uuidString)", "frame": 0, "gainDB": -6 },
                { "id": "\(sharedId.uuidString)", "frame": 10, "gainDB": -12 }
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VolumeAutomation.self, from: json)

        XCTAssertEqual(decoded.points.count, 2)
        XCTAssertNotEqual(decoded.points[0].id, decoded.points[1].id)
    }

    func testEncodedEnvelopeDecodesUnchanged() throws {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -6)
        automation.insert(frame: 240, gainDB: -24)

        let data = try JSONEncoder().encode(automation)
        let decoded = try JSONDecoder().decode(VolumeAutomation.self, from: data)

        XCTAssertEqual(decoded, automation)
    }

    // MARK: AudioLane integration

    /// A project saved before automation existed must still open, with no
    /// envelope and the sub-lane hidden. Pattern from
    /// `HardPannedSplitTests.testLaneSavedBeforeSplittingDecodesUnowned`.
    func testLegacyAudioLaneJSONDecodesWithoutAutomation() throws {
        let legacyJSON = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Dialogue",
            "clips": [],
            "isMuted": false,
            "isSolo": false,
            "volume": 1.0,
            "outputChannelOffset": 0,
            "outputChannelCount": 2,
            "colorIndex": 2
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AudioLane.self, from: legacyJSON)

        XCTAssertNil(decoded.automation)
        XCTAssertFalse(decoded.isAutomationShown)
    }

    func testAudioLaneWithAutomationRoundTripsThroughJSON() throws {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: 0)
        automation.insert(frame: 100, gainDB: -24)
        let lane = AudioLane(name: "Music", automation: automation, isAutomationShown: true)

        let data = try JSONEncoder().encode(lane)
        let decoded = try JSONDecoder().decode(AudioLane.self, from: data)

        XCTAssertEqual(decoded.automation, automation)
        XCTAssertTrue(decoded.isAutomationShown)
    }

    // MARK: segments(from:to:)

    private func assertFullCoverage(
        _ segments: [VolumeAutomation.Segment],
        start: Int,
        end: Int,
        envelope: VolumeAutomation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(segments.isEmpty, "non-empty range must yield at least one segment", file: file, line: line)
        guard let firstSegment = segments.first, let lastSegment = segments.last else { return }

        XCTAssertEqual(firstSegment.startFrame, start, file: file, line: line)
        XCTAssertEqual(lastSegment.endFrame, end, file: file, line: line)

        for index in 1..<segments.count {
            XCTAssertEqual(
                segments[index - 1].endFrame, segments[index].startFrame,
                "segments must be contiguous", file: file, line: line
            )
        }

        for segment in segments {
            XCTAssertEqual(
                segment.startDB, envelope.gainDB(at: segment.startFrame), accuracy: 0.0001,
                file: file, line: line
            )
            XCTAssertEqual(
                segment.endDB, envelope.gainDB(at: segment.endFrame), accuracy: 0.0001,
                file: file, line: line
            )
        }
    }

    func testSegmentsEmptyRangeIsEmpty() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -10)
        XCTAssertEqual(automation.segments(from: 50, to: 50), [])
        XCTAssertEqual(automation.segments(from: 50, to: 10), [])
    }

    func testSegmentsPointExactlyOnSpanEdgesIsNotDuplicated() {
        // A point on `startFrame` or `endFrame` must not produce a
        // zero-length or duplicate-frame segment: the span's own endpoint
        // knot already carries that point's gain.
        var automation = VolumeAutomation()
        automation.insert(frame: 10, gainDB: -6)
        automation.insert(frame: 20, gainDB: -12)
        automation.insert(frame: 30, gainDB: -3)

        let segments = automation.segments(from: 10, to: 30)
        assertFullCoverage(segments, start: 10, end: 30, envelope: automation)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].startDB, -6)
        XCTAssertEqual(segments[0].endDB, -12)
        XCTAssertEqual(segments[1].startDB, -12)
        XCTAssertEqual(segments[1].endDB, -3)
        XCTAssertTrue(segments.allSatisfy { $0.endFrame > $0.startFrame })
    }

    func testSegmentsEmptyEnvelopeIsOneHold() {
        let automation = VolumeAutomation()
        let segments = automation.segments(from: 0, to: 100)
        assertFullCoverage(segments, start: 0, end: 100, envelope: automation)
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].isHold)
        XCTAssertEqual(segments[0].startDB, 0)
    }

    func testSegmentsSinglePointIsOneHoldEvenInsideTheSpan() {
        var automation = VolumeAutomation()
        automation.insert(frame: 50, gainDB: -20)
        let segments = automation.segments(from: 0, to: 100)
        assertFullCoverage(segments, start: 0, end: 100, envelope: automation)
        XCTAssertEqual(segments.count, 1, "a single point never splits the span at its own frame")
        XCTAssertEqual(segments[0].startDB, -20)
        XCTAssertEqual(segments[0].endDB, -20)
    }

    func testSegmentsCoverPointsInsideTheSpan() {
        var automation = VolumeAutomation()
        automation.insert(frame: 20, gainDB: 0)
        automation.insert(frame: 40, gainDB: -30)
        let segments = automation.segments(from: 0, to: 100)
        assertFullCoverage(segments, start: 0, end: 100, envelope: automation)
        XCTAssertEqual(segments.count, 3)
        XCTAssertTrue(segments[0].isHold, "0..20 holds at 0 dB")
        XCTAssertFalse(segments[1].isHold, "20..40 is the slope")
        XCTAssertTrue(segments[2].isHold, "40..100 holds at -30 dB")
    }

    func testSegmentsSpanWhollyBeforeFirstPoint() {
        var automation = VolumeAutomation()
        automation.insert(frame: 50, gainDB: -10)
        automation.insert(frame: 100, gainDB: -20)
        let segments = automation.segments(from: 0, to: 40)
        assertFullCoverage(segments, start: 0, end: 40, envelope: automation)
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].isHold)
        XCTAssertEqual(segments[0].startDB, -10)
    }

    func testSegmentsSpanWhollyAfterLastPoint() {
        var automation = VolumeAutomation()
        automation.insert(frame: 50, gainDB: -10)
        automation.insert(frame: 100, gainDB: -20)
        let segments = automation.segments(from: 150, to: 200)
        assertFullCoverage(segments, start: 150, end: 200, envelope: automation)
        XCTAssertEqual(segments.count, 1)
        XCTAssertTrue(segments[0].isHold)
        XCTAssertEqual(segments[0].startDB, -20)
    }

    func testSegmentsSpanStartingAtNonzeroFrame() {
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: 0)
        automation.insert(frame: 100, gainDB: -60)
        let segments = automation.segments(from: 25, to: 75)
        assertFullCoverage(segments, start: 25, end: 75, envelope: automation)
        XCTAssertEqual(segments.count, 1)
        XCTAssertFalse(segments[0].isHold)
        XCTAssertEqual(segments[0].startDB, -15, accuracy: 0.01)
        XCTAssertEqual(segments[0].endDB, -45, accuracy: 0.01)
    }

    func testSegmentsAdjacentFramePointsFormOneFrameSlope() {
        var automation = VolumeAutomation()
        automation.insert(frame: 10, gainDB: 0)
        automation.insert(frame: 11, gainDB: -6)
        let segments = automation.segments(from: 0, to: 20)
        assertFullCoverage(segments, start: 0, end: 20, envelope: automation)
        let slope = segments.first { $0.startFrame == 10 && $0.endFrame == 11 }
        XCTAssertNotNil(slope)
        XCTAssertFalse(slope?.isHold ?? true)
    }

    // MARK: rampCount

    func testRampCountZeroDeltaIsZero() {
        XCTAssertEqual(VolumeAutomation.rampCount(forDeltaDB: 0, toleranceDB: 0.1), 0)
    }

    func testRampCountAtTheExactBoundary() {
        // The bound is solved on the *true* maximum error, not the midpoint
        // closed form (≈ 2.6397 dB): the maximum sits slightly off-centre, so
        // the exact answer at 0.1 dB is ≈ 2.636 dB. Deltas either side pin it.
        let maxDelta = VolumeAutomation.maximumRampDeltaDB(forToleranceDB: 0.1)
        XCTAssertEqual(maxDelta, 2.636, accuracy: 0.003)
        XCTAssertLessThanOrEqual(VolumeAutomation.maximumRampErrorDB(forDeltaDB: maxDelta), 0.1)
        XCTAssertGreaterThan(VolumeAutomation.maximumRampErrorDB(forDeltaDB: maxDelta + 0.01), 0.1)
        XCTAssertEqual(VolumeAutomation.rampCount(forDeltaDB: 2.5, toleranceDB: 0.1), 1)
        XCTAssertEqual(VolumeAutomation.rampCount(forDeltaDB: 2.63, toleranceDB: 0.1), 1)
        XCTAssertEqual(VolumeAutomation.rampCount(forDeltaDB: 2.64, toleranceDB: 0.1), 2)
        XCTAssertEqual(VolumeAutomation.rampCount(forDeltaDB: 2.7, toleranceDB: 0.1), 2)
    }

    /// The guarantee holds for *any* tolerance, including the loose ones the
    /// midpoint closed form got wrong (Codex found ≈2.06 dB of error at a
    /// 2 dB tolerance with the old 0.99 margin).
    func testRampCountHonoursLooseAndTightTolerancesExactly() {
        for tolerance: Float in [0.01, 0.1, 1, 2, 6] {
            let maxDelta = VolumeAutomation.maximumRampDeltaDB(forToleranceDB: tolerance)
            XCTAssertLessThanOrEqual(VolumeAutomation.maximumRampErrorDB(forDeltaDB: maxDelta), tolerance, "tolerance \(tolerance)")
            var delta: Float = 0.05
            while delta <= 60 {
                let count = VolumeAutomation.rampCount(forDeltaDB: delta, toleranceDB: tolerance)
                let piece = delta / Float(count)
                // `piece` is Float arithmetic on the test's side; allow the
                // last-bit rounding that a Float division can add.
                XCTAssertLessThanOrEqual(
                    VolumeAutomation.maximumRampErrorDB(forDeltaDB: piece), tolerance + 1e-5,
                    "delta \(delta) tolerance \(tolerance) count \(count)"
                )
                delta += 0.37
            }
        }
    }

    func testRampCountRejectsNonFiniteAndCapsHugeDeltas() {
        XCTAssertEqual(VolumeAutomation.rampCount(forDeltaDB: .nan, toleranceDB: 0.1), 0)
        XCTAssertEqual(VolumeAutomation.rampCount(forDeltaDB: .infinity, toleranceDB: 0.1), 0)
        // A delta beyond the whole range is answered as the whole range.
        XCTAssertEqual(
            VolumeAutomation.rampCount(forDeltaDB: 1e9, toleranceDB: 0.1),
            VolumeAutomation.rampCount(forDeltaDB: 60, toleranceDB: 0.1)
        )
        XCTAssertEqual(VolumeAutomation.maximumRampErrorDB(forDeltaDB: 0), 0)
    }

    func testExtremeFramesAreClampedNotTrapped() {
        var automation = VolumeAutomation()
        automation.insert(frame: Int.min, gainDB: -60)
        automation.insert(frame: Int.max, gainDB: 0)
        XCTAssertEqual(automation.points.map(\.frame), [VolumeAutomation.frameRange.lowerBound, VolumeAutomation.frameRange.upperBound])
        // Interpolation across the whole clamped range must not overflow.
        XCTAssertEqual(automation.gainDB(at: 0), -30, accuracy: 0.01)
        automation.move(id: automation.points[0].id, toFrame: Int.min, gainDB: -60)
        automation.mapFrames { _ in Int.max }
        XCTAssertTrue(automation.points.allSatisfy { VolumeAutomation.frameRange.contains($0.frame) })

        let json = """
        {"points":[{"frame":-9223372036854775808,"gainDB":-6},{"frame":9223372036854775807,"gainDB":0}]}
        """
        let decoded = try? JSONDecoder().decode(VolumeAutomation.self, from: Data(json.utf8))
        XCTAssertEqual(decoded?.points.map(\.frame), [VolumeAutomation.frameRange.lowerBound, VolumeAutomation.frameRange.upperBound])
    }

    func testRampCountSixtyDBAtDefaultToleranceIs23() {
        XCTAssertEqual(VolumeAutomation.rampCount(forDeltaDB: 60, toleranceDB: 0.1), 23)
    }

    func testRampCountToleranceClampsNonFiniteZeroAndNegativeToTheFloor() {
        let floor = VolumeAutomation.rampCount(forDeltaDB: 60, toleranceDB: 0.01)
        XCTAssertEqual(VolumeAutomation.rampCount(forDeltaDB: 60, toleranceDB: .nan), floor)
        XCTAssertEqual(VolumeAutomation.rampCount(forDeltaDB: 60, toleranceDB: 0), floor)
        XCTAssertEqual(VolumeAutomation.rampCount(forDeltaDB: 60, toleranceDB: -5), floor)
    }

    /// Independent analytic check of the maximum error a single ramp piece
    /// can have, from the plan's formula: `q = ln10·|Δ|/20`,
    /// `u = 1/q − 1/expm1(q)`, `err = 20/ln10·(log1p(u·expm1(q)) − q·u)`.
    /// Deliberately re-derived here rather than calling into
    /// `VolumeAutomation`, so this test can catch a wrong closed form, not
    /// just a mismatched one.
    private func analyticMaxErrorDB(forPieceDeltaDB d: Double) -> Double {
        guard d != 0 else { return 0 }
        let q = log(10.0) * abs(d) / 20.0
        let u = 1.0 / q - 1.0 / expm1(q)
        return (20.0 / log(10.0)) * (log1p(u * expm1(q)) - q * u)
    }

    func testRampCountKeepsEveryPieceWithinTheAnalyticErrorBound() {
        let toleranceDB: Float = 0.1
        for delta: Float in [0.1, 2.5, 2.63, 30, 60] {
            let n = VolumeAutomation.rampCount(forDeltaDB: delta, toleranceDB: toleranceDB)
            XCTAssertGreaterThan(n, 0)
            let pieceDelta = Double(delta) / Double(n)
            let error = analyticMaxErrorDB(forPieceDeltaDB: pieceDelta)
            XCTAssertLessThanOrEqual(
                error, Double(toleranceDB) + 1e-6,
                "Δ=\(delta) split into \(n) pieces of \(pieceDelta) dB exceeds tolerance"
            )
        }
    }

    /// Extra coverage alongside the analytic check: sample 100 points across
    /// one ramp piece, compare linear-amplitude interpolation (what
    /// AVFoundation actually does) against the dB-linear line it approximates.
    private func maxSampledDBError(pieceDeltaDB d: Double, samples: Int = 100) -> Double {
        let startDB = 0.0
        let endDB = -abs(d)
        let startLinear = pow(10.0, startDB / 20.0)
        let endLinear = pow(10.0, endDB / 20.0)

        var maxError = 0.0
        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let interpolatedLinear = startLinear + (endLinear - startLinear) * t
            let dBFromLinear = 20.0 * log10(interpolatedLinear)
            let dBLinearReference = startDB + (endDB - startDB) * t
            maxError = max(maxError, abs(dBFromLinear - dBLinearReference))
        }
        return maxError
    }

    func testRampCountKeepsEveryPieceWithinTheSampledErrorBound() {
        let toleranceDB: Float = 0.1
        for delta: Float in [0.1, 2.5, 2.63, 30, 60] {
            let n = VolumeAutomation.rampCount(forDeltaDB: delta, toleranceDB: toleranceDB)
            let pieceDelta = Double(delta) / Double(n)
            let error = maxSampledDBError(pieceDeltaDB: pieceDelta)
            XCTAssertLessThanOrEqual(
                error, Double(toleranceDB) + 0.01,
                "Δ=\(delta) split into \(n) pieces of \(pieceDelta) dB exceeds sampled tolerance"
            )
        }
    }
}

// MARK: - TimelineManager integration

@MainActor
final class VolumeAutomationTimelineManagerTests: XCTestCase {

    var manager: TimelineManager!

    override func setUp() async throws {
        try await super.setUp()
        let startTC = Timecode(.components(h: 0, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        let endTC = Timecode(.components(h: 0, m: 10, s: 0, f: 0), at: .fps24, by: .clamping)
        let config = TimelineConfig(startTimecode: startTC, endTimecode: endTC, frameRate: .fps24)
        manager = TimelineManager(timeline: Timeline(config: config, videoReels: [], audioLanes: []))
    }

    override func tearDown() async throws {
        manager = nil
        try await super.tearDown()
    }

    func testAddAutomationCreatesEnvelopeAndShowsItAndMarksDirty() {
        let lane = manager.addAudioLane(name: "Music")
        manager.markClean()

        manager.addAutomation(toLane: lane.id)

        let updated = manager.timeline.audioLanes.first { $0.id == lane.id }
        XCTAssertNotNil(updated?.automation)
        XCTAssertTrue(updated?.isAutomationShown ?? false)
        XCTAssertTrue(manager.hasChanges)
    }

    func testAddAutomationOnAnAlreadyAutomatedLaneJustShowsIt() {
        let lane = manager.addAudioLane(name: "Music")
        manager.addAutomation(toLane: lane.id)
        var automation = manager.timeline.audioLanes.first { $0.id == lane.id }!.automation!
        automation.insert(frame: 10, gainDB: -12)
        manager.setAutomation(automation, laneId: lane.id)
        manager.setAutomationShown(false, laneId: lane.id)

        manager.addAutomation(toLane: lane.id)

        let updated = manager.timeline.audioLanes.first { $0.id == lane.id }
        XCTAssertEqual(updated?.automation?.points.count, 1, "existing points are not discarded")
        XCTAssertTrue(updated?.isAutomationShown ?? false)
    }

    func testAddAutomationRefusedOnNonStandaloneLane() {
        let lane = AudioLane(name: "MX", splitChannel: .left)
        manager.timeline.addAudioLane(lane)

        manager.addAutomation(toLane: lane.id)

        XCTAssertNil(manager.timeline.audioLanes.first { $0.id == lane.id }?.automation)
    }

    func testSetAutomationReachesTheTimelineAndMarksDirty() {
        let lane = manager.addAudioLane(name: "Music")
        manager.addAutomation(toLane: lane.id)
        manager.markClean()

        var automation = VolumeAutomation()
        automation.insert(frame: 10, gainDB: -6)
        manager.setAutomation(automation, laneId: lane.id)

        XCTAssertEqual(manager.timeline.audioLanes.first { $0.id == lane.id }?.automation, automation)
        XCTAssertTrue(manager.hasChanges)
    }

    func testSetAutomationRefusedOnNonStandaloneLane() {
        let lane = AudioLane(name: "MX", splitChannel: .right)
        manager.timeline.addAudioLane(lane)

        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -6)
        manager.setAutomation(automation, laneId: lane.id)

        XCTAssertNil(manager.timeline.audioLanes.first { $0.id == lane.id }?.automation)
    }

    func testRemoveAutomationClearsEnvelopeAndShownAndMarksDirty() {
        let lane = manager.addAudioLane(name: "Music")
        manager.addAutomation(toLane: lane.id)
        manager.markClean()

        manager.removeAutomation(fromLane: lane.id)

        let updated = manager.timeline.audioLanes.first { $0.id == lane.id }
        XCTAssertNil(updated?.automation)
        XCTAssertFalse(updated?.isAutomationShown ?? true)
        XCTAssertTrue(manager.hasChanges)
    }

    func testApplyAutomationRestoresAnEnvelopeWithoutTheStandaloneGuard() {
        let lane = AudioLane(name: "MX", splitChannel: .left)
        manager.timeline.addAudioLane(lane)
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -6)

        manager.applyAutomation(automation, laneId: lane.id)

        XCTAssertEqual(manager.timeline.audioLanes.first { $0.id == lane.id }?.automation, automation)
    }

    func testApplyAutomationWithNilHidesTheSubLane() {
        let lane = manager.addAudioLane(name: "Music")
        manager.addAutomation(toLane: lane.id)

        manager.applyAutomation(nil, laneId: lane.id)

        let updated = manager.timeline.audioLanes.first { $0.id == lane.id }
        XCTAssertNil(updated?.automation)
        XCTAssertFalse(updated?.isAutomationShown ?? true)
    }

    /// Content keeps its real time across a rate change (frame 240 at 24 fps
    /// is frame 250 at 25) - a node must move the same way a clip does.
    func testSetFrameRateRegridsAutomationPoints() {
        let lane = manager.addAudioLane(name: "Music")
        manager.addAutomation(toLane: lane.id)
        var automation = VolumeAutomation()
        automation.insert(frame: 240, gainDB: -12)
        manager.setAutomation(automation, laneId: lane.id)

        manager.setFrameRate(.fps25)

        let regridded = manager.timeline.audioLanes.first { $0.id == lane.id }?.automation
        XCTAssertEqual(regridded?.points.map(\.frame), [250])
    }

    /// A timeline-start shift preserves absolute timecode: moving the start
    /// 240 frames earlier moves content 240 frames later, same as clips.
    func testSetTimelineStartShiftsAutomationPoints() {
        var config = manager.timeline.config
        config.startTimecode = Timecode(.components(h: 1, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        config.endTimecode = Timecode(.components(h: 2, m: 0, s: 0, f: 0), at: .fps24, by: .clamping)
        manager.timeline.config = config

        let lane = manager.addAudioLane(name: "Music")
        manager.addAutomation(toLane: lane.id)
        var automation = VolumeAutomation()
        automation.insert(frame: 0, gainDB: -12)
        manager.setAutomation(automation, laneId: lane.id)

        manager.setTimelineStart(toFrame: -240)

        let shifted = manager.timeline.audioLanes.first { $0.id == lane.id }?.automation
        XCTAssertEqual(shifted?.points.map(\.frame), [240])
    }
}
