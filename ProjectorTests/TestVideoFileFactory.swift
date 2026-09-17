import AVFoundation
import CoreVideo
import Foundation

/// Utility for generating short, real `.mov` files for tests that need a
/// genuine video asset.
///
/// `QuickTimeDemoBuilder.makeDemo`/`export` load a video track from
/// `VideoReel.sourceURL` and encode the result through
/// `AVAssetExportSession` - neither can be driven by a synthetic composition
/// the way this test target's other `QuickTimeDemoBuilderTests` drive
/// `QuickTimeDemoBuilder.mixParameters` directly against a bare, contentless
/// composition track. Those tests need no picture at all; the export
/// round-trip tests need a real, decodable video track to composite against.
enum TestVideoFileFactory {
    enum Failure: LocalizedError {
        case setupFailed(String)
        case pixelBufferUnavailable
        case appendFailed(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .setupFailed(let reason):
                return "Could not start writing a test movie: \(reason)"
            case .pixelBufferUnavailable:
                return "The writer's pixel buffer pool produced no buffer."
            case .appendFailed(let reason):
                return "Appending a frame to a test movie failed: \(reason)"
            case .writerFailed(let reason):
                return "Writing a test movie failed: \(reason)"
            }
        }
    }

    /// Writes a short, silent, black H.264 `.mov`.
    ///
    /// Frames are flat black `kCVPixelFormatType_32ARGB` buffers from the
    /// writer input's own pixel buffer pool - content does not matter here,
    /// only that the file is a real, decodable video asset with the
    /// requested duration and frame rate, since that is what
    /// `QuickTimeDemoBuilder` reads a track from and what
    /// `AVAssetExportSession` re-encodes.
    ///
    /// - Parameters:
    ///   - duration: Length in seconds.
    ///   - fps: Frame rate to write at. Presentation times are `frame/fps`,
    ///     an exact rational at that timescale - matching how
    ///     `QuickTimeDemoBuilder.time(forFrame:at:)` places picture, so a
    ///     reel built from this file lines up on exact frame boundaries.
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    /// - Returns: URL of the written movie.
    static func makeBlackMovie(
        duration: TimeInterval,
        fps: Int32 = 24,
        width: Int = 320,
        height: Int = 240
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectorTest-\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 250_000
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw Failure.setupFailed("cannot add a video input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw Failure.setupFailed(writer.error?.localizedDescription ?? "unknown reason")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, Int((duration * Double(fps)).rounded()))
        let queue = DispatchQueue(label: "ProjectorTests.TestVideoFileFactory")

        // Event-driven, matching `MediaOptimizationService`'s own
        // `requestMediaDataWhenReady` + continuation pattern rather than a
        // sleep-poll loop.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var nextFrame = 0
            var didResume = false
            func finish(_ result: Result<Void, Error>) {
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard nextFrame < frameCount else {
                        input.markAsFinished()
                        finish(.success(()))
                        return
                    }
                    guard let pool = adaptor.pixelBufferPool else {
                        input.markAsFinished()
                        finish(.failure(Failure.pixelBufferUnavailable))
                        return
                    }
                    var pixelBufferOut: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
                    guard let pixelBuffer = pixelBufferOut else {
                        input.markAsFinished()
                        finish(.failure(Failure.pixelBufferUnavailable))
                        return
                    }

                    CVPixelBufferLockBaseAddress(pixelBuffer, [])
                    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                        let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
                        memset(base, 0, byteCount)
                    }
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

                    let time = CMTime(value: CMTimeValue(nextFrame), timescale: CMTimeScale(fps))
                    guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                        input.markAsFinished()
                        finish(.failure(Failure.appendFailed(writer.error?.localizedDescription ?? "unknown reason")))
                        return
                    }
                    nextFrame += 1
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }

        guard writer.status == .completed else {
            throw Failure.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }

        return url
    }
}
