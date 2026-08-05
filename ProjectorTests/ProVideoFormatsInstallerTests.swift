//
//  ProVideoFormatsInstallerTests.swift
//  ProjectorTests
//
//  Download-link discovery and the trust check that guards it. No network.
//

import XCTest
@testable import Projector

final class ProVideoFormatsInstallerTests: XCTestCase {

    // MARK: - Link Discovery

    /// Shaped like Apple's support page: the real link is buried in markup and its
    /// path carries a per-release build token, which is why it is read rather than
    /// hardcoded.
    private let supportPageMarkup = """
    <html><body>
    <h1>Pro Video Formats 3.1</h1>
    <p>Requires macOS 11.0.1 or later.</p>
    <a class="download" href="https://updates.cdn-apple.com/2026/macos/\
    072-84099-20260127-5022F0FE-82CF-44E9-B96D-430E73501EBA/ProVideoFormats.dmg">Download</a>
    </body></html>
    """

    func testFindsDownloadLinkInSupportPage() {
        let found = ProVideoFormatsInstaller.firstDownloadLink(in: supportPageMarkup)
        XCTAssertEqual(found?.host, "updates.cdn-apple.com")
        XCTAssertEqual(found?.lastPathComponent, "ProVideoFormats.dmg")
    }

    func testReturnsNilWhenPageHasNoDownloadLink() {
        let markup = "<html><body><p>Nothing to download here.</p></body></html>"
        XCTAssertNil(ProVideoFormatsInstaller.firstDownloadLink(in: markup))
    }

    func testIgnoresLinksToOtherFiles() {
        let markup = """
        <a href="https://updates.cdn-apple.com/2026/macos/something/SomethingElse.dmg">x</a>
        """
        XCTAssertNil(ProVideoFormatsInstaller.firstDownloadLink(in: markup))
    }

    // MARK: - Trust

    func testAcceptsAppleDownloadURL() {
        let url = URL(string: "https://updates.cdn-apple.com/2026/macos/x/ProVideoFormats.dmg")!
        XCTAssertNoThrow(try ProVideoFormatsInstaller.validate(url))
    }

    func testRejectsNonAppleHost() throws {
        // The disk image is unsigned, so the host check is the only thing standing
        // between a tampered support page and an arbitrary download.
        let url = URL(string: "https://example.com/ProVideoFormats.dmg")!
        XCTAssertThrowsError(try ProVideoFormatsInstaller.validate(url)) { error in
            XCTAssertEqual(
                error as? ProVideoFormatsInstaller.InstallerError,
                .untrustedDownloadURL("example.com")
            )
        }
    }

    func testRejectsPlainHTTP() {
        let url = URL(string: "http://updates.cdn-apple.com/x/ProVideoFormats.dmg")!
        XCTAssertThrowsError(try ProVideoFormatsInstaller.validate(url)) { error in
            XCTAssertEqual(
                error as? ProVideoFormatsInstaller.InstallerError,
                .untrustedDownloadURL("http")
            )
        }
    }

    func testRejectsLookalikeHost() {
        // A host merely ending in Apple's domain must not pass.
        let url = URL(string: "https://updates.cdn-apple.com.evil.test/ProVideoFormats.dmg")!
        XCTAssertThrowsError(try ProVideoFormatsInstaller.validate(url))
    }

    // MARK: - Fallback

    func testPinnedFallbackURLIsItselfTrusted() {
        // The fallback is used when discovery fails, so it has to satisfy the same
        // check as anything discovered.
        XCTAssertNoThrow(try ProVideoFormatsInstaller.validate(ProVideoFormats.fallbackDownloadURL))
    }

    func testSupportPageURLIsApple() {
        XCTAssertEqual(ProVideoFormats.supportPageURL.host, "support.apple.com")
    }
}
