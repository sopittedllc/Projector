//
//  AudioStemGroupingTests.swift
//  ProjectorTests
//
//  Tests for reading the stem role out of a delivery filename.
//
//  Dropping a five-reel delivery used to make one lane per file: ten lanes of
//  one clip each for two stems cut into reels. The shape these tests protect is
//  the one deliveries actually have - a reel number and a descriptive middle
//  that both vary, and a stem suffix that does not.
//

import XCTest
@testable import Projector

final class AudioStemGroupingTests: XCTestCase {

    // MARK: - Helpers

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    private func roles(_ name: String) -> [AudioStemRole]? {
        AudioStemGrouping.stem(for: url(name))?.roles
    }

    // MARK: - Reading a single name

    /// The plain cases: one role at the end of a name.
    func testReadsASingleTrailingRole() {
        XCTAssertEqual(roles("SHOW reel 1 0000-AB SESSION_GT_MX.wav"), [.music])
        XCTAssertEqual(roles("SHOW reel 1_DX.wav"), [.dialogue])
        XCTAssertEqual(roles("SHOW reel 1_FX.wav"), [.effects])
    }

    /// A combined stem keeps both roles, in the order the filename wrote them.
    func testReadsACombinedStem() {
        XCTAssertEqual(roles("SHOW reel 1 0000-AB SESSION_GT_DX_FX.wav"), [.dialogue, .effects])
    }

    /// Longer spellings land on the same roles as the abbreviations.
    func testAliasesResolveToTheSameRole() {
        XCTAssertEqual(roles("SHOW reel 1 dialogue.wav"), [.dialogue])
        XCTAssertEqual(roles("SHOW reel 1 Music.wav"), [.music])
        XCTAssertEqual(roles("SHOW reel 1_SFX.wav"), [.effects])
    }

    /// `&` is not a separator, so `M&E` stays one token.
    func testMusicAndEffectsSurvivesTokenising() {
        XCTAssertEqual(roles("SHOW reel 1_M&E.wav"), [.musicAndEffects])
    }

    /// Trailing detail is skipped, but never makes a stem on its own.
    func testTrailingDetailIsSkipped() {
        XCTAssertEqual(roles("SHOW reel 1_DX_STEM.wav"), [.dialogue])
        XCTAssertEqual(roles("SHOW reel 1_MX_51.wav"), [.music])
        XCTAssertEqual(roles("SHOW_MX_v2.wav"), [.music])
        XCTAssertEqual(roles("SHOW_MX_02.wav"), [.music])
        XCTAssertNil(roles("SHOW reel 1 stereo bounce.wav"))
    }

    /// Two spellings of one role name the lane once.
    func testRepeatedRoleIsNotDuplicated() {
        XCTAssertEqual(roles("SHOW reel 1 print master.wav"), [.printMaster])
    }

    /// A name that says nothing about stems is left alone.
    func testNamesWithoutAStemAreNotGuessed() {
        XCTAssertNil(roles("SHOW reel 1 0000-AB SESSION.wav"))
        XCTAssertNil(roles("Scene 42 take 3.wav"))
    }

    /// The walk stops at the first token that is neither role nor noise, so a
    /// role buried mid-name is not treated as the file's stem.
    func testARoleBeforeARealWordIsNotTheStem() {
        XCTAssertNil(roles("SHOW_DX_notes.wav"))
    }

    // MARK: - Lane identity

    /// Order of the roles does not change which lane a file belongs on.
    func testCombinedStemsGroupRegardlessOfOrder() {
        let forward = AudioStemGrouping.stem(for: url("SHOW reel 1_DX_FX.wav"))
        let reverse = AudioStemGrouping.stem(for: url("SHOW reel 2_FX_DX.wav"))
        XCTAssertEqual(forward?.key, reverse?.key)
    }

    /// The lane is named after the stem, spaced rather than underscored.
    func testDisplayName() {
        XCTAssertEqual(AudioStemGrouping.stem(for: url("SHOW_DX_FX.wav"))?.displayName, "DX FX")
        XCTAssertEqual(AudioStemGrouping.stem(for: url("SHOW_MX.wav"))?.displayName, "MX")
    }

    // MARK: - Grouping a batch

    /// The delivery this was built for: five reels, two stems, reel 5 carrying
    /// a different descriptive middle from the rest.
    func testFiveReelDeliveryCollapsesToTwoLanes() {
        let dropped = [
            "SHOW reel 1 0000-AB SESSION_GT_DX_FX.wav",
            "SHOW reel 1 0000-AB SESSION_GT_MX.wav",
            "SHOW reel 2  0000-AB SESSION_GT_DX_FX.wav",
            "SHOW reel 2  0000-AB SESSION_GT_MX.wav",
            "SHOW reel 3  0000-AB SESSION _GT_DX_FX.wav",
            "SHOW reel 3  0000-AB SESSION_GT_MX.wav",
            "SHOW reel 4  0000-AB SESSION_GT_DX_FX.wav",
            "SHOW reel 4  0000-AB SESSION_GT_MX.wav",
            "SHOW reel 5  0000-AB SESSION-with an end song_DX_FX.wav",
            "SHOW reel 5  0000-AB SESSION-with an end song_MX.wav"
        ].map(url)

        let groups = AudioStemGrouping.groups(for: dropped)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map { $0.stem?.displayName }, ["DX FX", "MX"])
        XCTAssertEqual(groups.map { $0.urls.count }, [5, 5])
    }

    /// Files in a group are ordered the way the Finder orders them, so reel 2
    /// precedes reel 10 and sequential placement follows the reels.
    func testGroupedFilesAreInReelOrder() {
        let dropped = [
            "SHOW reel 10_MX.wav",
            "SHOW reel 2_MX.wav",
            "SHOW reel 1_MX.wav"
        ].map(url)

        let groups = AudioStemGrouping.groups(for: dropped)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(
            groups.first?.urls.map { $0.lastPathComponent },
            ["SHOW reel 1_MX.wav", "SHOW reel 2_MX.wav", "SHOW reel 10_MX.wav"]
        )
    }

    /// Files with no stem keep a lane each - the behaviour that has always
    /// applied to material the filename says nothing about.
    func testFilesWithoutAStemAreNotGroupedTogether() {
        let dropped = ["one.wav", "two.wav", "three.wav"].map(url)

        let groups = AudioStemGrouping.groups(for: dropped)

        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { $0.stem == nil && $0.urls.count == 1 })
    }

    /// A batch that mixes both: the stems collect, the rest stay separate.
    func testMixedBatchGroupsOnlyWhatItCan() {
        let dropped = [
            "SHOW reel 1_DX.wav",
            "room tone.wav",
            "SHOW reel 2_DX.wav"
        ].map(url)

        let groups = AudioStemGrouping.groups(for: dropped)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.stem?.displayName, "DX")
        XCTAssertEqual(groups.first?.urls.count, 2)
        XCTAssertNil(groups.last?.stem)
        XCTAssertEqual(groups.last?.urls.count, 1)
    }

    /// Groups come back in the order their stem first appeared in the drop, so
    /// the lanes land in a predictable order.
    func testGroupOrderFollowsFirstAppearance() {
        let dropped = [
            "SHOW reel 1_MX.wav",
            "SHOW reel 1_DX.wav",
            "SHOW reel 2_MX.wav"
        ].map(url)

        XCTAssertEqual(
            AudioStemGrouping.groups(for: dropped).map { $0.stem?.displayName },
            ["MX", "DX"]
        )
    }

    /// An empty drop is not an error.
    func testEmptyBatch() {
        XCTAssertTrue(AudioStemGrouping.groups(for: []).isEmpty)
    }
}
