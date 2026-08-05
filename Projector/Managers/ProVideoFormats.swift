//
//  ProVideoFormats.swift
//  Projector
//
//  Loads the professional video decoders Apple distributes separately from macOS.
//

import Foundation
import VideoToolbox

/// Access to the professional video decoders Apple ships in its Pro Video Formats
/// package.
///
/// macOS decodes only the codecs whose decoders live in
/// `/System/Library/Video/Plug-Ins` - ProRes, H.264, HEVC, AV1, JPEG and MPEG-4.
/// Professional formats including Avid DNxHD and DNxHR, AVC-Intra, XAVC, DVCPRO HD,
/// HDV, XDCAM, MPEG IMX and Uncompressed 4:2:2 are decoded only when Apple's free Pro
/// Video Formats package has been installed.
///
/// Apple's instruction for reaching those decoders is a single registration call made
/// once per process, from WWDC20 session 10090 *Decode ProRes with AVFoundation and
/// VideoToolbox*:
///
/// > If your application needs to access the set of specialized decoders distributed
/// > for Pro video workflows, your application can make a call to
/// > `VTRegisterProfessionalVideoWorkflowVideoDecoders`. This only needs to happen once
/// > in your application.
///
/// Registration binds decoders into the current process at the moment it runs, so a
/// package installed while Projector is running does not take effect until the app is
/// relaunched.
public enum ProVideoFormats {

    // MARK: - Registration

    /// Registers Apple's professional video decoders with this process, once.
    ///
    /// Calling this more than once is harmless but pointless; the `static let` below
    /// makes repeat calls free and guarantees the underlying registration happens
    /// exactly once, including from concurrent callers.
    ///
    /// - Note: Must be called from every process that decodes media. The QuickLook
    ///   extension runs separately from the app and needs its own call.
    public static func registerProfessionalDecoders() {
        _ = hasRegistered
    }

    /// Performs registration on first access.
    ///
    /// Swift guarantees a `static let` initialiser runs at most once and is
    /// thread-safe, which is exactly the "only needs to happen once" contract.
    private static let hasRegistered: Bool = {
        VTRegisterProfessionalVideoWorkflowVideoDecoders()
        return true
    }()

    // MARK: - Package Detection

    /// Directory the Pro Video Formats installer writes its decoders into.
    ///
    /// Named for the *workflow*, not the package: the installer is called "Pro Video
    /// Formats" but its payload lands in "Professional Video Workflow Plug-Ins",
    /// alongside `DNXDecoder.bundle`, `AppleAVCIntraCodec.bundle` and the rest.
    private static let decoderPlugInDirectory =
        "/Library/Video/Professional Video Workflow Plug-Ins"

    /// Whether the Pro Video Formats package appears to be installed.
    ///
    /// - Important: For diagnostics and message wording only. Whether a *particular*
    ///   file will play is answered by ``VideoCodecSupport/inspect(_:)``, because a
    ///   package can be present without covering the codec in hand, and because these
    ///   decoders do nothing until ``registerProfessionalDecoders()`` has run. Never
    ///   gate playback on this.
    public static var packageAppearsInstalled: Bool {
        FileManager.default.fileExists(atPath: decoderPlugInDirectory)
    }

    // MARK: - Obtaining the Package

    /// Apple's support page for the package, and the source of its download link.
    public static let supportPageURL = URL(string: "https://support.apple.com/106396")!

    /// Host serving Apple's software downloads.
    ///
    /// Any candidate download URL must be on this host, so that a change to Apple's
    /// page can never redirect the installer somewhere else.
    public static let downloadHost = "updates.cdn-apple.com"

    /// Last known direct download, used when the support page cannot be parsed.
    ///
    /// The path carries a per-release build token, so this URL goes stale with each
    /// new version of the package. It is a fallback behind live discovery, never the
    /// primary source.
    public static let fallbackDownloadURL = URL(
        string: "https://updates.cdn-apple.com/2026/macos/072-84099-20260127-5022F0FE-82CF-44E9-B96D-430E73501EBA/ProVideoFormats.dmg"
    )!
}
