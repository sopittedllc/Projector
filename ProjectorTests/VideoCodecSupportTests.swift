//
//  VideoCodecSupportTests.swift
//  ProjectorTests
//
//  Codec identification and classification. Pure functions - no media, no network.
//

import CoreMedia
import XCTest
@testable import Projector

final class VideoCodecSupportTests: XCTestCase {

    // Four-character codes as they appear in a QuickTime sample description.
    private let dnxHD: FourCharCode = 0x4156_646E       // 'AVdn'
    private let dnxHR: FourCharCode = 0x4156_6468       // 'AVdh'
    private let appleIntermediate: FourCharCode = 0x6963_6F64  // 'icod'
    private let proResProxy: FourCharCode = 0x6170_636F  // 'apco'
    private let proRes422HQ: FourCharCode = 0x6170_6368  // 'apch'
    private let proResRAW: FourCharCode = 0x6170_726E    // 'aprn'
    private let avcIntra: FourCharCode = 0x6169_3170     // 'ai1p'
    private let dvcProHD: FourCharCode = 0x6476_6835     // 'dvh5'
    private let xdcam: FourCharCode = 0x7864_3559        // 'xd5Y'
    private let mpegIMX: FourCharCode = 0x6D78_336E      // 'mx3n'

    // MARK: - FourCC Rendering

    func testFourCCStringRendersPrintableCode() {
        XCTAssertEqual(VideoCodecSupport.fourCCString(dnxHD), "AVdn")
        XCTAssertEqual(VideoCodecSupport.fourCCString(dnxHR), "AVdh")
    }

    func testFourCCStringFallsBackToHexForUnprintableCode() {
        // A code containing a control byte cannot be shown as four characters.
        let unprintable: FourCharCode = 0x0001_0203
        XCTAssertEqual(VideoCodecSupport.fourCCString(unprintable), "0x00010203")
    }

    // MARK: - Display Names

    func testDisplayNameKnowsProfessionalCodecs() {
        XCTAssertEqual(VideoCodecSupport.displayName(forFourCC: dnxHD), "Avid DNxHD")
        XCTAssertEqual(VideoCodecSupport.displayName(forFourCC: dnxHR), "Avid DNxHR")
        XCTAssertEqual(
            VideoCodecSupport.displayName(forFourCC: appleIntermediate),
            "Apple Intermediate Codec"
        )
    }

    func testDisplayNameKnowsNativeCodecs() {
        XCTAssertEqual(VideoCodecSupport.displayName(forFourCC: proResProxy), "ProRes 422 Proxy")
        XCTAssertEqual(
            VideoCodecSupport.displayName(forFourCC: kCMVideoCodecType_H264),
            "H.264"
        )
        XCTAssertEqual(
            VideoCodecSupport.displayName(forFourCC: kCMVideoCodecType_HEVC),
            "HEVC"
        )
    }

    func testDisplayNameFallsBackToFourCCWhenUnknown() {
        let unknown: FourCharCode = 0x7A7A_7A7A  // 'zzzz'
        XCTAssertEqual(VideoCodecSupport.displayName(forFourCC: unknown), "zzzz")
    }

    // MARK: - Pro Video Formats Classification

    func testDNxIsProVideoFormatsCodec() {
        XCTAssertTrue(VideoCodecSupport.isProVideoFormatsCodec(dnxHD))
        XCTAssertTrue(VideoCodecSupport.isProVideoFormatsCodec(dnxHR))
    }

    func testProfessionalFamiliesAreRecognisedByPrefix() {
        XCTAssertTrue(VideoCodecSupport.isProVideoFormatsCodec(avcIntra))
        XCTAssertTrue(VideoCodecSupport.isProVideoFormatsCodec(dvcProHD))
        XCTAssertTrue(VideoCodecSupport.isProVideoFormatsCodec(xdcam))
        XCTAssertTrue(VideoCodecSupport.isProVideoFormatsCodec(mpegIMX))
        XCTAssertTrue(VideoCodecSupport.isProVideoFormatsCodec(proResRAW))
    }

    func testNativeCodecsAreNotProVideoFormatsCodecs() {
        XCTAssertFalse(VideoCodecSupport.isProVideoFormatsCodec(kCMVideoCodecType_H264))
        XCTAssertFalse(VideoCodecSupport.isProVideoFormatsCodec(kCMVideoCodecType_HEVC))
        XCTAssertFalse(VideoCodecSupport.isProVideoFormatsCodec(proResProxy))
    }

    /// ProRes 422 HQ is `apch`, which the ProRes RAW family prefix `apr`... does not
    /// match, but `apc`-style codes sit close enough to the prefix rules that this is
    /// worth pinning: a natively decodable codec must never be offered an install.
    func testProResIsNeverOfferedAnInstallDespitePrefixProximity() {
        XCTAssertFalse(VideoCodecSupport.isProVideoFormatsCodec(proRes422HQ))
        XCTAssertTrue(VideoCodecSupport.isNativelyDecodableCodec(proRes422HQ))
    }

    func testUnknownCodecIsNotOfferedAnInstall() {
        // Offering Apple's package for a codec it does not contain would send the
        // user through an install that could not fix anything.
        let unknown: FourCharCode = 0x7A7A_7A7A  // 'zzzz'
        XCTAssertFalse(VideoCodecSupport.isProVideoFormatsCodec(unknown))
    }

    // MARK: - Install Offer

    func testInstallIsOfferedOnlyForUndecodableProfessionalCodecs() {
        let undecodableDNx = CodecSupport(
            fourCC: "AVdn",
            displayName: "Avid DNxHD",
            isDecodable: false,
            isProVideoFormatsCodec: true
        )
        XCTAssertTrue(undecodableDNx.shouldOfferProVideoFormatsInstall)

        // Once the decoder is installed the same codec must stop prompting.
        let decodableDNx = CodecSupport(
            fourCC: "AVdn",
            displayName: "Avid DNxHD",
            isDecodable: true,
            isProVideoFormatsCodec: true
        )
        XCTAssertFalse(decodableDNx.shouldOfferProVideoFormatsInstall)

        // A broken file with a codec the package does not carry gets a plain error.
        let undecodableUnknown = CodecSupport(
            fourCC: "zzzz",
            displayName: "zzzz",
            isDecodable: false,
            isProVideoFormatsCodec: false
        )
        XCTAssertFalse(undecodableUnknown.shouldOfferProVideoFormatsInstall)
    }
}
