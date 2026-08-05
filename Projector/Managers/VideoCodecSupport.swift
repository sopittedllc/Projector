//
//  VideoCodecSupport.swift
//  Projector
//
//  Identifies a video track's codec and whether this Mac can actually decode it.
//

import AVFoundation
import CoreMedia
import Foundation

/// What Projector knows about a video track's codec after probing it.
///
/// Produced by ``VideoCodecSupport/inspect(_:)``. The distinction that matters is
/// between ``isDecodable`` - whether this Mac can turn the track into pictures right
/// now - and ``isProVideoFormatsCodec`` - whether installing Apple's free Pro Video
/// Formats package would be expected to fix it.
public struct CodecSupport: Sendable, Equatable {

    /// The track's four-character codec code, e.g. `"AVdn"` for Avid DNxHD.
    public let fourCC: String

    /// Human-readable codec name for display, e.g. `"Avid DNxHD"`.
    ///
    /// Taken from the file's own format description when it supplies one, so the
    /// name shown is the name the encoder wrote rather than one we guessed.
    public let displayName: String

    /// Whether this Mac can decode the track.
    ///
    /// This is the ground truth for "will it play", and is always preferred over
    /// checking whether a codec package appears to be installed on disk.
    public let isDecodable: Bool

    /// Whether Apple's Pro Video Formats package supplies a decoder for this codec.
    ///
    /// Only true for codecs that package is documented to cover, so an undecodable
    /// file with an unrecognised codec produces a plain error rather than an install
    /// prompt that would not help.
    public let isProVideoFormatsCodec: Bool

    /// Whether Projector should offer to install Pro Video Formats for this track.
    public var shouldOfferProVideoFormatsInstall: Bool {
        !isDecodable && isProVideoFormatsCodec
    }
}

/// Identifies video codecs and reports whether this Mac can decode them.
///
/// macOS decodes only the codecs whose decoders ship in
/// `/System/Library/Video/Plug-Ins` - ProRes, H.264, HEVC, AV1, JPEG and MPEG-4.
/// Professional formats such as Avid DNxHD are decoded only when Apple's Pro Video
/// Formats package is installed and
/// ``ProVideoFormats/registerProfessionalDecoders()`` has run.
public enum VideoCodecSupport {

    // MARK: - Codec Codes

    /// Four-character codes for codecs supplied by Apple's Pro Video Formats package.
    ///
    /// Listed individually rather than matched loosely, so that only codecs the
    /// package genuinely covers can trigger an install offer.
    private enum ProCodec {
        /// Avid DNxHD.
        static let dnxHD: FourCharCode = 0x4156_646E          // 'AVdn'
        /// Avid DNxHR.
        static let dnxHR: FourCharCode = 0x4156_6468          // 'AVdh'
        /// Apple Intermediate Codec.
        static let appleIntermediate: FourCharCode = 0x6963_6F64  // 'icod'
        /// Uncompressed 4:2:2 8-bit.
        static let uncompressed8Bit: FourCharCode = 0x3276_7579   // '2vuy'
        /// Uncompressed 4:2:2 10-bit.
        static let uncompressed10Bit: FourCharCode = 0x7632_3130  // 'v210'
    }

    /// Leading byte patterns for professional codec families with many variants.
    ///
    /// AVC-Intra, DVCPRO HD, HDV, XDCAM and MPEG IMX each ship a dozen or more
    /// four-character codes that differ only by resolution and bitrate. Matching the
    /// family prefix covers them without enumerating every permutation, all of which
    /// Pro Video Formats provides as a set.
    private static let proCodecFamilyPrefixes: [String] = [
        "ai",   // AVC-Intra
        "dvh",  // DVCPRO HD
        "hdv",  // HDV
        "xd",   // XDCAM
        "mx",   // MPEG IMX
        "apr"   // Apple ProRes RAW
    ]

    /// Display names for codecs that do not name themselves in their format description.
    private static let codecDisplayNames: [FourCharCode: String] = [
        kCMVideoCodecType_AppleProRes4444XQ: "ProRes 4444 XQ",
        kCMVideoCodecType_AppleProRes4444: "ProRes 4444",
        kCMVideoCodecType_AppleProRes422HQ: "ProRes 422 HQ",
        kCMVideoCodecType_AppleProRes422: "ProRes 422",
        kCMVideoCodecType_AppleProRes422LT: "ProRes 422 LT",
        kCMVideoCodecType_AppleProRes422Proxy: "ProRes 422 Proxy",
        kCMVideoCodecType_H264: "H.264",
        kCMVideoCodecType_HEVC: "HEVC",
        kCMVideoCodecType_JPEG: "JPEG",
        kCMVideoCodecType_MPEG4Video: "MPEG-4",
        ProCodec.dnxHD: "Avid DNxHD",
        ProCodec.dnxHR: "Avid DNxHR",
        ProCodec.appleIntermediate: "Apple Intermediate Codec",
        ProCodec.uncompressed8Bit: "Uncompressed 4:2:2",
        ProCodec.uncompressed10Bit: "Uncompressed 4:2:2 10-bit"
    ]

    // MARK: - Inspection

    /// Probes an asset's first video track for its codec and decodability.
    ///
    /// - Parameter asset: The asset to inspect.
    /// - Returns: What was found, or `nil` if the asset has no video track.
    /// - Throws: Whatever `AVAsset` property loading throws.
    /// - Note: Safe to call on any asset. Reading a track's codec and decodability
    ///   does not require the codec to be installed, which is what makes it possible
    ///   to name a codec we cannot decode.
    public static func inspect(_ asset: AVAsset) async throws -> CodecSupport? {
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { return nil }

        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        guard let formatDescription = formatDescriptions.first else { return nil }

        let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
        let isDecodable = try await videoTrack.load(.isDecodable)

        return CodecSupport(
            fourCC: fourCCString(subType),
            displayName: displayName(for: formatDescription, subType: subType),
            isDecodable: isDecodable,
            isProVideoFormatsCodec: isProVideoFormatsCodec(subType)
        )
    }

    // MARK: - Naming

    /// The name to show for a codec, preferring the one the file declares.
    ///
    /// QuickTime files written by professional encoders carry a `FormatName`
    /// extension - an Avid DNxHD file names itself "Avid DNxHD Codec". Using it means
    /// the user sees the same codec name their delivery paperwork uses, and means new
    /// codecs are named correctly without a table entry.
    ///
    /// - Parameters:
    ///   - formatDescription: The track's format description.
    ///   - subType: The media sub-type already extracted from it.
    /// - Returns: A display name, falling back to the four-character code itself.
    static func displayName(
        for formatDescription: CMFormatDescription,
        subType: FourCharCode
    ) -> String {
        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any]
        let declaredName = extensions?[
            kCMFormatDescriptionExtension_FormatName as String
        ] as? String

        if let declaredName, !declaredName.isEmpty {
            return declaredName
        }
        return displayName(forFourCC: subType)
    }

    /// The name to show for a codec identified only by its four-character code.
    ///
    /// - Parameter fourCC: The codec's four-character code.
    /// - Returns: A known name, or the four-character code itself when unrecognised.
    static func displayName(forFourCC fourCC: FourCharCode) -> String {
        codecDisplayNames[fourCC] ?? fourCCString(fourCC)
    }

    /// Renders a four-character code as text, e.g. `0x4156646E` as `"AVdn"`.
    ///
    /// - Parameter fourCC: The code to render.
    /// - Returns: The four characters, or a hex representation if any byte is not
    ///   printable ASCII.
    static func fourCCString(_ fourCC: FourCharCode) -> String {
        let bytes = [
            UInt8((fourCC >> 24) & 0xFF),
            UInt8((fourCC >> 16) & 0xFF),
            UInt8((fourCC >> 8) & 0xFF),
            UInt8(fourCC & 0xFF)
        ]

        let printableASCII: ClosedRange<UInt8> = 0x20...0x7E
        guard bytes.allSatisfy({ printableASCII.contains($0) }) else {
            return String(format: "0x%08X", fourCC)
        }
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", fourCC)
    }

    // MARK: - Classification

    /// Whether Apple's Pro Video Formats package supplies a decoder for this codec.
    ///
    /// - Parameter fourCC: The codec's four-character code.
    /// - Returns: `true` when installing the package would be expected to help.
    static func isProVideoFormatsCodec(_ fourCC: FourCharCode) -> Bool {
        let known: Set<FourCharCode> = [
            ProCodec.dnxHD,
            ProCodec.dnxHR,
            ProCodec.appleIntermediate,
            ProCodec.uncompressed8Bit,
            ProCodec.uncompressed10Bit
        ]
        if known.contains(fourCC) { return true }

        // Codecs macOS decodes on its own are never the package's business, and must
        // be excluded before the family prefixes are consulted - 'apch' (ProRes 422 HQ)
        // would otherwise be caught by the ProRes RAW "apr" prefix.
        guard !isNativelyDecodableCodec(fourCC) else { return false }

        let code = fourCCString(fourCC).lowercased()
        return proCodecFamilyPrefixes.contains { code.hasPrefix($0) }
    }

    /// Whether macOS decodes this codec without any additional package installed.
    ///
    /// - Parameter fourCC: The codec's four-character code.
    /// - Returns: `true` for the codecs whose decoders ship with the OS.
    static func isNativelyDecodableCodec(_ fourCC: FourCharCode) -> Bool {
        let native: Set<FourCharCode> = [
            kCMVideoCodecType_AppleProRes4444XQ,
            kCMVideoCodecType_AppleProRes4444,
            kCMVideoCodecType_AppleProRes422HQ,
            kCMVideoCodecType_AppleProRes422,
            kCMVideoCodecType_AppleProRes422LT,
            kCMVideoCodecType_AppleProRes422Proxy,
            kCMVideoCodecType_H264,
            kCMVideoCodecType_HEVC,
            kCMVideoCodecType_JPEG,
            kCMVideoCodecType_MPEG4Video
        ]
        return native.contains(fourCC)
    }
}
