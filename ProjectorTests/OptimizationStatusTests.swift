//
//  OptimizationStatusTests.swift
//  ProjectorTests
//
//  What counts as media worth optimizing. The Optimize Media button is shown from
//  exactly this answer, so "nothing qualifies" has to be reachable.
//

import AVFoundation
import CoreGraphics
import XCTest
@testable import Projector

final class OptimizationStatusTests: XCTestCase {

    // MARK: - Helpers

    private func item(
        name: String = "clip",
        ext: String = "mov",
        type: MediaType = .video,
        width: CGFloat? = 1920,
        bitrate: Int? = nil,
        isOptimized: Bool = false
    ) -> MediaItem {
        var media = MediaItem(
            url: URL(fileURLWithPath: "/tmp/\(name).\(ext)"),
            type: type,
            duration: 60,
            videoSize: width.map { CGSize(width: $0, height: $0 * 9 / 16) },
            bitrate: bitrate
        )
        media.isOptimized = isOptimized
        return media
    }

    private func qualifies(_ media: MediaItem) -> Bool {
        if case .needsOptimization = OptimizationStatusHelper.status(for: media) { return true }
        return false
    }

    // MARK: - Nothing To Do

    /// The case the button's visibility hangs on: ordinary delivery-weight media that
    /// is already fine. Previously an unsaved project offered to optimize this anyway.
    func testModestFileNeedsNothing() {
        let modest = item(ext: "mp4", width: 1920, bitrate: 5_000_000)
        XCTAssertFalse(qualifies(modest))
    }

    func testAlreadyOptimizedFileNeedsNothing() {
        // Heavy enough to qualify on every other rule - the optimized flag wins.
        let done = item(width: 3840, bitrate: 100_000_000, isOptimized: true)
        XCTAssertFalse(qualifies(done))

        guard case .optimized = OptimizationStatusHelper.status(for: done) else {
            return XCTFail("Expected .optimized")
        }
    }

    func testAudioFileNeedsNothing() {
        let audio = item(ext: "wav", type: .audio, width: nil, bitrate: 2_300_000)
        XCTAssertFalse(qualifies(audio))
    }

    // MARK: - Thresholds

    func testResolutionThresholdIsExclusive() {
        // 1920 wide is the reference delivery size and must not be flagged; anything
        // wider is. An inclusive comparison here would mark every HD reel as needing
        // work, which is the whole population.
        XCTAssertFalse(qualifies(item(ext: "mp4", width: 1920, bitrate: 5_000_000)))
        XCTAssertTrue(qualifies(item(ext: "mp4", width: 1921, bitrate: 5_000_000)))
    }

    func testHighResolutionQualifies() {
        guard case .needsOptimization(let reason) =
                OptimizationStatusHelper.status(for: item(ext: "mp4", width: 3840, bitrate: 5_000_000)),
              case .highResolution(let width) = reason else {
            return XCTFail("Expected .highResolution")
        }
        XCTAssertEqual(width, 3840)
    }

    func testHighBitrateQualifies() {
        guard case .needsOptimization(let reason) =
                OptimizationStatusHelper.status(for: item(ext: "mp4", width: 1920, bitrate: 20_000_000)),
              case .highBitrate = reason else {
            return XCTFail("Expected .highBitrate")
        }
    }

    func testBitrateThresholdIsExclusive() {
        XCTAssertFalse(qualifies(item(ext: "mp4", width: 1920, bitrate: 10_000_000)))
        XCTAssertTrue(qualifies(item(ext: "mp4", width: 1920, bitrate: 10_000_001)))
    }

    // MARK: - Production Codecs

    func testHeavyQuickTimeIsFlaggedAsProductionCodec() {
        guard case .needsOptimization(let reason) =
                OptimizationStatusHelper.status(for: item(ext: "mov", width: 1920, bitrate: 100_000_000)),
              case .productionCodec = reason else {
            return XCTFail("Expected .productionCodec")
        }
    }

    func testLightQuickTimeIsNotAProductionCodecByExtensionAlone() {
        // A .mov is not heavy just for being a .mov - a 5 Mbps one is ordinary.
        XCTAssertFalse(qualifies(item(ext: "mov", width: 1920, bitrate: 5_000_000)))
    }

    // MARK: - Missing Metadata

    func testUnknownBitrateDoesNotQualifyOnItsOwn() {
        // Bitrate is estimated from file size and can be absent. Absent must not read
        // as "huge", or the button returns for files nothing is known about.
        XCTAssertFalse(qualifies(item(ext: "mp4", width: 1920, bitrate: nil)))
    }

    // MARK: - The Button's Rule

    func testALibraryOfLightMediaOffersNothing() {
        let library = [
            item(name: "a", ext: "mp4", width: 1920, bitrate: 5_000_000),
            item(name: "b", ext: "wav", type: .audio, width: nil, bitrate: 2_300_000),
            item(name: "c", ext: "mov", width: 1280, bitrate: 8_000_000)
        ]
        XCTAssertFalse(library.contains(where: qualifies))
    }

    func testOneHeavyFileIsEnoughToOffer() {
        let library = [
            item(name: "a", ext: "mp4", width: 1920, bitrate: 5_000_000),
            item(name: "b", ext: "mov", width: 3840, bitrate: 200_000_000)
        ]
        XCTAssertTrue(library.contains(where: qualifies))
    }

    func testAnEmptyLibraryOffersNothing() {
        XCTAssertFalse([MediaItem]().contains(where: qualifies))
    }

    // MARK: - Nothing Left To Flag

    /// Optimized media carries no badge and raises no banner. Both are shown from
    /// `.needsOptimization`, so `.optimized` answering anything else is what makes
    /// the flag disappear when the work is done.
    func testOptimizingSilencesEveryOffer() {
        var library = [
            item(name: "a", ext: "mov", width: 3840, bitrate: 200_000_000),
            item(name: "b", ext: "mp4", width: 1920, bitrate: 40_000_000)
        ]
        XCTAssertTrue(library.contains(where: qualifies), "Precondition: work to offer")

        for index in library.indices {
            library[index].isOptimized = true
        }
        XCTAssertFalse(library.contains(where: qualifies))
    }

    /// The banner splits what qualifies into "ProRes" and everything else, so the
    /// production-codec test has to stand on its own outside `status(for:)`.
    func testProductionCodecTestIsIndependentOfStatus() {
        XCTAssertTrue(OptimizationStatusHelper.isProductionCodec(item(ext: "mov", bitrate: 100_000_000)))
        XCTAssertTrue(OptimizationStatusHelper.isProductionCodec(item(ext: "mxf", bitrate: 100_000_000)))
        XCTAssertFalse(OptimizationStatusHelper.isProductionCodec(item(ext: "mov", bitrate: 5_000_000)))
        XCTAssertFalse(OptimizationStatusHelper.isProductionCodec(item(ext: "mp4", bitrate: 100_000_000)))
        // Absent bitrate must not read as heavy, same as everywhere else.
        XCTAssertFalse(OptimizationStatusHelper.isProductionCodec(item(ext: "mov", bitrate: nil)))
    }
}

// MARK: - ProjectFolders

/// What counts as already being in the project. The Consolidate Media button is
/// shown from exactly this answer.
final class ProjectFoldersTests: XCTestCase {

    private let projectURL = URL(fileURLWithPath: "/Users/editor/Show/Cut.projector")

    private func contains(_ path: String) -> Bool {
        ProjectFolders.contains(URL(fileURLWithPath: path), projectURL: projectURL)
    }

    func testMediaInsideThePackageIsOurs() {
        XCTAssertTrue(contains("/Users/editor/Show/Cut.projector/Media/reel.mov"))
    }

    /// The case that made the button reappear after every optimize pass: optimized
    /// output is written *beside* the package, not inside it, so a package-only test
    /// read the app's own output as external media and offered to copy it back in.
    func testOptimizedOutputIsOurs() {
        XCTAssertTrue(contains("/Users/editor/Show/Optimized Media/reel.mov"))
    }

    func testMovedOriginalsAreOurs() {
        XCTAssertTrue(contains("/Users/editor/Show/Raw Files/reel.mov"))
    }

    func testMediaElsewhereIsExternal() {
        XCTAssertFalse(contains("/Volumes/Transfer/reel.mov"))
    }

    /// A neighbouring folder in the same directory is not the project's.
    /// Claiming the whole enclosing directory would consider a project saved to
    /// the Desktop to have consolidated the entire Desktop.
    func testSiblingFoldersWeDoNotOwnAreExternal() {
        XCTAssertFalse(contains("/Users/editor/Show/Dailies/reel.mov"))
    }

    /// String prefixes match names that merely start the same. `Cut.projector`
    /// is a textual prefix of `Cut.projector.backup`, a different directory.
    func testNeighbourWithASharedNamePrefixIsExternal() {
        XCTAssertFalse(contains("/Users/editor/Show/Cut.projector.backup/Media/reel.mov"))
        XCTAssertFalse(contains("/Users/editor/Show/Optimized Media Archive/reel.mov"))
    }

    /// The folder itself is not a file inside it.
    func testTheFolderIsNotItsOwnContents() {
        XCTAssertFalse(contains("/Users/editor/Show/Cut.projector"))
    }
}

@MainActor
final class MediaOptimizationRegressionTests: XCTestCase {
    func testProductionMediaFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROJECTOR_MEDIA_FIXTURE"] else {
            throw XCTSkip("Set TEST_RUNNER_PROJECTOR_MEDIA_FIXTURE to a short production MOV fixture")
        }
        let sourceURL = URL(fileURLWithPath: path)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = MediaOptimizationService()
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        let analysis = try await service.analyzeProject(mediaItems: [MediaItem(url: sourceURL, type: .video, duration: duration, videoSize: CGSize(width: 1920, height: 1080))])
        let result = try await service.optimizeMedia(items: analysis.items, options: .handbrakeVeryFast720p(optimizedMediaFolderURL: folder)) { _ in }
        XCTAssertEqual(result.optimizedCount, 1, result.failedItems.compactMap(\.errorMessage).joined(separator: "\n"))
        let output = try XCTUnwrap(result.successfulItems.first)
        let optimized = AVURLAsset(url: output.optimizedURL)
        let outputDuration = try await optimized.load(.duration).seconds
        XCTAssertEqual(outputDuration, duration, accuracy: 0.15)
        let audio = try await optimized.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audio.isEmpty)
        let cache = WaveformCache()
        let clip = AudioClip(sourceURL: sourceURL, timelineStartFrame: 0, durationFrames: Int(duration * 24), sourceStartFrame: 0, sourceType: .videoTrack)
        _ = cache.renderData(for: clip, targetWidth: 512)
        for _ in 0..<200 {
            if cache.clipAtlases[clip.id] != nil || cache.hasFailed(for: clip) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(cache.clipAtlases[clip.id])
        XCTAssertFalse(cache.isLoading(for: clip))
    }

    /// Adding a file to an optimized project offers only the new file.
    ///
    /// An optimized item keeps its original's `videoSize`, so a resolution check
    /// alone re-flags it - which re-encoded the whole project on every new import.
    func testAlreadyOptimizedItemsAreNotOfferedAgain() async throws {
        let videoURL = try await TestVideoFileFactory.makeBlackMovie(duration: 1)
        defer { try? FileManager.default.removeItem(at: videoURL) }
        let originalSize = CGSize(width: 1920, height: 1080)
        let optimized = MediaItem(url: videoURL, type: .video, duration: 1, videoSize: originalSize, isOptimized: true)
        let incoming = MediaItem(url: videoURL, type: .video, duration: 1, videoSize: originalSize)

        let analysis = try await MediaOptimizationService().analyzeProject(mediaItems: [optimized, incoming])

        XCTAssertEqual(analysis.itemsNeedingOptimization.map(\.mediaItemId), [incoming.id])
        let skipped = try XCTUnwrap(analysis.items.first { $0.mediaItemId == optimized.id })
        XCTAssertEqual(skipped.skipReason, MediaOptimizationService.alreadyOptimizedReason)
    }

    func testOptimizesMovieWithPCMAudio() async throws {
        let videoURL = try await TestVideoFileFactory.makeBlackMovie(duration: 1)
        let audioURL = try TestAudioFileFactory.makeSineWaveFile(duration: 1)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: folder)
        }
        let composition = AVMutableComposition()
        for (url, type) in [(videoURL, AVMediaType.video), (audioURL, AVMediaType.audio)] {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: type)
            let source = try XCTUnwrap(tracks.first)
            let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 48000)), of: source, at: .zero)
        }
        let sourceURL = folder.appendingPathComponent("source.mov")
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        export.outputURL = sourceURL
        export.outputFileType = .mov
        await export.export()
        XCTAssertEqual(export.status, .completed)
        let service = MediaOptimizationService()
        let analysis = try await service.analyzeProject(mediaItems: [MediaItem(url: sourceURL, type: .video, duration: 1, videoSize: CGSize(width: 1920, height: 1080))])
        let result = try await service.optimizeMedia(items: analysis.items, options: .handbrakeVeryFast720p(optimizedMediaFolderURL: folder.appendingPathComponent("optimized"))) { _ in }
        XCTAssertEqual(result.failedCount, 0, result.failedItems.compactMap(\.errorMessage).joined(separator: "\n"))
        XCTAssertEqual(result.optimizedCount, 1)
        let output = try XCTUnwrap(result.successfulItems.first)
        let outputAsset = AVURLAsset(url: output.optimizedURL)
        let duration = try await outputAsset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.1)
        let audioTracks = try await outputAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
    }
}

/// Column widths for the media panel's list view.
final class MediaListColumnWidthsTests: XCTestCase {
    func testUnresizedColumnsUseDefaults() {
        let widths = MediaListColumnWidths()
        XCTAssertEqual(widths[.name], MediaListColumn.name.defaultWidth)
    }

    func testDraggingBelowMinimumStopsAtMinimum() {
        var widths = MediaListColumnWidths()
        widths[.name] = 1
        XCTAssertEqual(widths[.name], MediaListColumn.name.minimumWidth)
    }

    func testWidthsSurviveStorageRoundTrip() {
        var widths = MediaListColumnWidths()
        widths[.name] = 480
        widths[.codec] = 140
        XCTAssertEqual(MediaListColumnWidths(storage: widths.storage), widths)
    }

    func testUnreadableStorageFallsBackToDefaults() {
        XCTAssertEqual(MediaListColumnWidths(storage: "not json"), MediaListColumnWidths())
    }

    func testFrameRatesDropTrailingZeros() {
        XCTAssertEqual(MediaListText.frameRate(24), "24 fps")
        XCTAssertEqual(MediaListText.frameRate(29.97), "29.97 fps")
        XCTAssertEqual(MediaListText.frameRate(24000.0 / 1001.0), "23.976 fps")
    }

    func testSampleRates() {
        XCTAssertEqual(MediaListText.sampleRate(48_000), "48 kHz")
        XCTAssertEqual(MediaListText.sampleRate(44_100), "44.1 kHz")
    }
}

/// Click-to-sort ordering for the media panel's list view.
final class MediaListSortTests: XCTestCase {
    private func item(
        _ name: String,
        type: MediaType = .video,
        duration: Double = 10,
        bitrate: Int? = nil,
        videoSize: CGSize? = nil,
        frameRate: Double? = nil,
        sampleRate: Double? = nil,
        codecName: String? = nil,
        id: UUID = UUID()
    ) -> MediaItem {
        var made = MediaItem(
            id: id,
            url: URL(fileURLWithPath: "/tmp/\(name).mov"),
            type: type,
            duration: duration,
            frameRate: frameRate,
            videoSize: videoSize,
            sampleRate: sampleRate,
            bitrate: bitrate
        )
        made.codecName = codecName
        return made
    }

    private func names(_ sort: MediaListSort, _ items: [MediaItem]) -> [String] {
        sort.sorted(items).map(\.displayName)
    }

    func testNameSortsNaturallyIgnoringCase() {
        let items = [item("reel 10 Mx"), item("Reel 2 Dx"), item("reel 1 Dx")]
        XCTAssertEqual(names(MediaListSort(column: .name, ascending: true), items),
                       ["reel 1 Dx", "Reel 2 Dx", "reel 10 Mx"])
        XCTAssertEqual(names(MediaListSort(column: .name, ascending: false), items),
                       ["reel 10 Mx", "Reel 2 Dx", "reel 1 Dx"])
    }

    func testClickingTogglesDirectionAndNewColumnStartsAscending() {
        let first = MediaListSort.afterClicking(.duration, current: nil)
        XCTAssertEqual(first, MediaListSort(column: .duration, ascending: true))
        let second = MediaListSort.afterClicking(.duration, current: first)
        XCTAssertEqual(second, MediaListSort(column: .duration, ascending: false))
        let other = MediaListSort.afterClicking(.name, current: second)
        XCTAssertEqual(other, MediaListSort(column: .name, ascending: true))
    }

    func testMissingValuesAreSmallestAndDescendingIsExactReverse() {
        let items = [item("a", bitrate: nil), item("b", bitrate: 500), item("c", bitrate: 100)]
        let ascending = names(MediaListSort(column: .bitrate, ascending: true), items)
        XCTAssertEqual(ascending, ["a", "c", "b"])
        XCTAssertEqual(names(MediaListSort(column: .bitrate, ascending: false), items), ascending.reversed())
    }

    func testFormatComparesDisplayedTextWithoutGrouping() {
        let items = [
            item("song", type: .audio),
            item("hd", videoSize: CGSize(width: 1920, height: 1080)),
            item("sd", videoSize: CGSize(width: 640, height: 360))
        ]
        let sort = MediaListSort(column: .format, ascending: true)
        let sorted = sort.sorted(items)
        // Unread audio format is missing, so it leads; no video-before-audio grouping.
        XCTAssertEqual(sorted.first?.displayName, "song")
        let texts = sorted.compactMap(\.formatText)
        XCTAssertEqual(texts, texts.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(sort.sorted(items).map(\.id), MediaListSort(column: .format, ascending: false).sorted(items).reversed().map(\.id))
    }

    func testRateComparesOwnValueDirectly() {
        let items = [
            item("audio", type: .audio, sampleRate: 48_000),
            item("film", frameRate: 24),
            item("unread")
        ]
        XCTAssertEqual(names(MediaListSort(column: .rate, ascending: true), items), ["unread", "film", "audio"])
        XCTAssertEqual(names(MediaListSort(column: .rate, ascending: false), items), ["audio", "film", "unread"])
    }

    func testCodecComparesDisplayedText() {
        let items = [
            item("prores", codecName: "ProRes 422"),
            item("unread"),
            item("song", type: .audio),
            item("avc", codecName: "H.264")
        ]
        // Unread video codec is missing; the audio container names its codec (MOV here).
        XCTAssertEqual(names(MediaListSort(column: .codec, ascending: true), items),
                       ["unread", "avc", "song", "prores"])
    }

    func testStatusComparesDisplayedTextWithBlankAsMissing() {
        var optimized = item("done", videoSize: CGSize(width: 1280, height: 720))
        optimized.isOptimized = true
        let audio = item("song", type: .audio)
        let heavy = item("heavy", videoSize: CGSize(width: 3840, height: 2160))
        XCTAssertNil(audio.statusText)
        XCTAssertNotNil(heavy.statusText)
        let all = [heavy, optimized, audio]
        let ascending = names(MediaListSort(column: .status, ascending: true), all)
        XCTAssertEqual(ascending.first, "song")
        XCTAssertEqual(names(MediaListSort(column: .status, ascending: false), all), ascending.reversed())
    }

    func testTiesBreakByNameThenIdInBothDirections() {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let items = [
            item("Reel 2 Dx", duration: 5, id: high),
            item("Reel 2 Dx", duration: 5, id: low),
            item("Reel 1 Dx", duration: 5)
        ]
        for ascending in [true, false] {
            let sorted = MediaListSort(column: .duration, ascending: ascending).sorted(items)
            XCTAssertEqual(sorted.map(\.displayName), ["Reel 1 Dx", "Reel 2 Dx", "Reel 2 Dx"])
            XCTAssertEqual(sorted.map(\.id).suffix(2), [low, high])
        }
    }

    func testStorageRoundTrip() {
        for column in MediaListColumn.allCases {
            for ascending in [true, false] {
                let sort = MediaListSort(column: column, ascending: ascending)
                XCTAssertEqual(MediaListSort.restored(from: sort.storage), sort)
            }
        }
    }

    func testUnreadableStorageFallsBackToDefault() {
        XCTAssertNil(MediaListSort.restored(from: ""))
        XCTAssertNil(MediaListSort.restored(from: "not a sort"))
        XCTAssertNil(MediaListSort.restored(from: "name:sideways"))
        XCTAssertNil(MediaListSort.restored(from: "nope:asc"))
    }

    func testEmptyOrGarbageStorageFallsBackToNameAscending() {
        let nameAscending = MediaListSort(column: .name, ascending: true)
        XCTAssertEqual(MediaListSort.standard, nameAscending)
        for stored in ["", "not a sort", "name:sideways", "nope:asc"] {
            XCTAssertEqual(MediaListSort.restoredOrStandard(from: stored), nameAscending)
        }
        XCTAssertEqual(MediaListSort.restoredOrStandard(from: "rate:desc"),
                       MediaListSort(column: .rate, ascending: false))
        // Name is already the active ascending column, so the first click flips it.
        XCTAssertEqual(MediaListSort.afterClicking(.name, current: .standard),
                       MediaListSort(column: .name, ascending: false))
    }
}
