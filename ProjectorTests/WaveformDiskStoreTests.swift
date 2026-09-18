import XCTest
@testable import Projector

final class WaveformDiskStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformDiskStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLevel(count: Int, seed: Float) -> WaveformLevel {
        let values = (0..<count).map { Float($0) * seed / Float(count) }
        return WaveformLevel(min: values.map { -$0 }, max: values, rms: values.map { $0 * 0.5 })
    }

    func testRoundTripPreservesEveryLevelAndChannel() throws {
        let atlas = WaveformAtlas(
            duration: 12.5,
            levels: [256: makeLevel(count: 256, seed: 1), 512: makeLevel(count: 512, seed: 0.7)],
            channelLevels: [
                [256: makeLevel(count: 256, seed: 0.3)],
                [256: makeLevel(count: 256, seed: 0.9)]
            ]
        )

        WaveformDiskStore.store(atlas, key: "roundtrip", in: directory)
        let loaded = try XCTUnwrap(WaveformDiskStore.load(key: "roundtrip", in: directory))

        XCTAssertEqual(loaded.duration, atlas.duration)
        XCTAssertEqual(Set(loaded.levels.keys), Set(atlas.levels.keys))
        for (bucketCount, original) in atlas.levels {
            let level = try XCTUnwrap(loaded.levels[bucketCount])
            XCTAssertEqual(level.min, original.min)
            XCTAssertEqual(level.max, original.max)
            XCTAssertEqual(level.rms, original.rms)
            XCTAssertEqual(level.rmsFloor, original.rmsFloor)
            XCTAssertEqual(level.rmsPeak, original.rmsPeak)
        }
        XCTAssertEqual(loaded.channelLevels.count, 2)
        XCTAssertEqual(loaded.channelLevels[0][256]?.max, atlas.channelLevels[0][256]?.max)
        XCTAssertEqual(loaded.channelLevels[1][256]?.max, atlas.channelLevels[1][256]?.max)
    }

    func testMissingKeyIsAMiss() {
        XCTAssertNil(WaveformDiskStore.load(key: "never-stored", in: directory))
    }

    func testCorruptFileIsAMissNotAnError() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = WaveformDiskStore.fileURL(for: "corrupt", in: directory)
        try Data("not an atlas".utf8).write(to: url)

        XCTAssertNil(WaveformDiskStore.load(key: "corrupt", in: directory))
    }

    func testKeyChangesWhenSourceContentOrSettingsChange() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("stem.wav")
        try Data(repeating: 0, count: 100).write(to: source)

        let base = try XCTUnwrap(WaveformDiskStore.key(
            sourceURL: source, trackIndex: 0, channel: nil, samplesPerSecond: 200, bucketCounts: [256]
        ))
        let otherTrack = try XCTUnwrap(WaveformDiskStore.key(
            sourceURL: source, trackIndex: 1, channel: nil, samplesPerSecond: 200, bucketCounts: [256]
        ))
        let leftOnly = try XCTUnwrap(WaveformDiskStore.key(
            sourceURL: source, trackIndex: 0, channel: .left, samplesPerSecond: 200, bucketCounts: [256]
        ))
        XCTAssertNotEqual(base, otherTrack)
        XCTAssertNotEqual(base, leftOnly)

        // Same name, different content: the size changed, so must the key.
        try Data(repeating: 0, count: 101).write(to: source)
        let rewritten = try XCTUnwrap(WaveformDiskStore.key(
            sourceURL: source, trackIndex: 0, channel: nil, samplesPerSecond: 200, bucketCounts: [256]
        ))
        XCTAssertNotEqual(base, rewritten)
    }

    func testKeySurvivesMovingTheFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("stem.wav")
        try Data(repeating: 1, count: 100).write(to: original)
        let before = try XCTUnwrap(WaveformDiskStore.key(
            sourceURL: original, trackIndex: 0, channel: nil, samplesPerSecond: 200, bucketCounts: [256]
        ))

        let subfolder = directory.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let moved = subfolder.appendingPathComponent("stem.wav")
        try FileManager.default.moveItem(at: original, to: moved)
        let after = try XCTUnwrap(WaveformDiskStore.key(
            sourceURL: moved, trackIndex: 0, channel: nil, samplesPerSecond: 200, bucketCounts: [256]
        ))

        XCTAssertEqual(before, after, "Moving media on the same volume must not discard its waveform")
    }

    func testDistinctFilesWithMatchingMetadataDoNotShareAtlas() throws {
        let firstFolder = directory.appendingPathComponent("first")
        let secondFolder = directory.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        let first = firstFolder.appendingPathComponent("stem.wav")
        let second = secondFolder.appendingPathComponent("stem.wav")
        try Data(repeating: 1, count: 100).write(to: first)
        try Data(repeating: 2, count: 100).write(to: second)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for url in [first, second] {
            try FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
        }
        let firstKey = try XCTUnwrap(WaveformDiskStore.key(
            sourceURL: first, trackIndex: 0, channel: nil, samplesPerSecond: 200, bucketCounts: [256]
        ))
        let secondKey = try XCTUnwrap(WaveformDiskStore.key(
            sourceURL: second, trackIndex: 0, channel: nil, samplesPerSecond: 200, bucketCounts: [256]
        ))
        XCTAssertNotEqual(firstKey, secondKey)
        WaveformDiskStore.store(WaveformAtlas(duration: 1, levels: [256: makeLevel(count: 256, seed: 1)]),
                                key: firstKey, in: directory)
        XCTAssertNil(WaveformDiskStore.load(key: secondKey, in: directory))
    }

    func testUnreadableSourceYieldsNoKey() {
        XCTAssertNil(WaveformDiskStore.key(
            sourceURL: directory.appendingPathComponent("absent.wav"),
            trackIndex: 0, channel: nil, samplesPerSecond: 200, bucketCounts: [256]
        ))
    }
}
