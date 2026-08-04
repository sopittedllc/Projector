import AVFoundation
import CoreGraphics
import AppKit

// A reference reel with nothing to argue about:
//   - 23.976 exactly (frame duration 1001/24000)
//   - a timecode track starting at 01:00:00:00
//   - every frame's own timecode drawn into the picture, derived from the
//     SAME number the timecode track is based on, so burn-in and tmcd cannot
//     disagree by construction.

let out = URL(fileURLWithPath: CommandLine.arguments[1])
// Frame count and start address are arguments so the same generator can make a
// 100-second smoke reel or a 90-minute feature-length one.
let frameCount = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 2400
let startTCFrames = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 86400
let w = 960, h = 540

try? FileManager.default.removeItem(at: out)
let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
writer.movieTimeScale = 24000

let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: w, AVVideoHeightKey: h
])
videoIn.expectsMediaDataInRealTime = false
// Without this the writer quantises to a 600 timescale, where an NTSC frame
// boundary (1001/24000) is not representable - the reference would silently
// become 24 fps content wearing a 23.976 label.
videoIn.mediaTimeScale = 24000
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: videoIn,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h
    ])
writer.add(videoIn)

// Timecode track
var tcFormat: CMTimeCodeFormatDescription?
CMTimeCodeFormatDescriptionCreate(
    allocator: kCFAllocatorDefault,
    timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
    frameDuration: CMTime(value: 1001, timescale: 24000),
    frameQuanta: 24,
    flags: kCMTimeCodeFlag_24HourMax,
    extensions: nil,
    formatDescriptionOut: &tcFormat)
let tcIn = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: tcFormat)
tcIn.expectsMediaDataInRealTime = false
writer.add(tcIn)

writer.startWriting()
writer.startSession(atSourceTime: .zero)

// --- timecode sample: one sample spanning the whole reel ---
var tcFrame = UInt32(startTCFrames).bigEndian
var block: CMBlockBuffer?
CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
    blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 4,
    flags: 0, blockBufferOut: &block)
CMBlockBufferReplaceDataBytes(with: &tcFrame, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 4)
var tcSample: CMSampleBuffer?
var timing = CMSampleTimingInfo(
    duration: CMTime(value: CMTimeValue(1001 * frameCount), timescale: 24000),
    presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
var sizes = 4
CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: tcFormat,
    sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
    sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &tcSample)
tcIn.append(tcSample!)
tcIn.markAsFinished()

// --- video frames ---
func label(_ n: Int) -> String {
    String(format: "%02d:%02d:%02d:%02d", n/86400, (n%86400)/1440, (n%1440)/24, n%24)
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let sem = DispatchSemaphore(value: 0)
let queue = DispatchQueue(label: "gen")
var i = 0
videoIn.requestMediaDataWhenReady(on: queue) {
    while videoIn.isReadyForMoreMediaData {
        if i >= frameCount { videoIn.markAsFinished(); sem.signal(); return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let tcText = label(startTCFrames + i) as NSString
        tcText.draw(at: NSPoint(x: 40, y: 300), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.white])
        ("frame \(i)" as NSString).draw(at: NSPoint(x: 40, y: 200), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 40, weight: .regular),
            .foregroundColor: NSColor.systemGreen])
        NSGraphicsContext.restoreGraphicsState()
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(1001 * i), timescale: 24000))
        i += 1
    }
}
sem.wait()
writer.finishWriting { sem.signal() }
sem.wait()
print("wrote \(out.path): \(frameCount) frames @ 1001/24000, tmcd start \(label(startTCFrames))")
