//
//  TemporaryAudioFilesTests.swift
//  ProjectorTests
//
//  Nothing extracts audio any more. These cover the sweep that clears what
//  earlier versions left, and the boundary that keeps it off a user's media.
//

import XCTest
@testable import Projector

final class TemporaryAudioFilesTests: XCTestCase {

    // MARK: - Legacy Files

    /// Names the old schemes produced, which nothing will ever look for again.
    func testLegacyNamesAreRecognised() {
        XCTAssertTrue(TemporaryAudioFiles.isLegacyName("projector-audio-8471895692213557923.mov"))
        XCTAssertTrue(TemporaryAudioFiles.isLegacyName("SHOW_PREV2_R1_COMPOSER-left-9D38DAB8.caf"))
        XCTAssertTrue(TemporaryAudioFiles.isLegacyName("260727_DeliLove_Full-right-290C97D5.caf"))
    }

    /// A user's own media, and this type's current files, must not match.
    func testCurrentAndUnrelatedNamesAreNotTreatedAsLegacy() {
        XCTAssertFalse(TemporaryAudioFiles.isLegacyName("Reel_01.mov"))
        XCTAssertFalse(TemporaryAudioFiles.isLegacyName("MyMix-final.caf"))
        XCTAssertFalse(TemporaryAudioFiles.isLegacyName("com.projector.app.savedState"))

        // A 16-character digest is what the later naming used; only the old
        // eight-character UUID prefix counts as legacy.
        XCTAssertFalse(
            TemporaryAudioFiles.isLegacyName("SHOW_PREV2_R1_COMPOSER-left-9d38dab8c7d81394.caf"),
            "a longer digest is not the old naming and must not be swept"
        )
    }
}
