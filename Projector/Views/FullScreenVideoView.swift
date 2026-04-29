import SwiftUI
import UniformTypeIdentifiers

/// Full-screen video playback view with video content and exit controls.
///
/// Displays the video player filling the entire screen with a timecode overlay
/// and a minimize button to exit full-screen mode. Supports media drag-and-drop.
///
/// - Parameters:
///   - playbackEngine: The playback engine managing video playback.
///   - settings: Application settings for timecode overlay configuration.
///   - mediaImportCoordinator: Coordinator for handling media import from drag-and-drop.
///   - onExitFullScreen: Closure called when the user requests to exit full-screen mode.
struct FullScreenVideoView: View {
    // MARK: - Dependencies

    @ObservedObject var playbackEngine: PlaybackEngine
    @ObservedObject var settings: AppSettings
    @ObservedObject var mediaImportCoordinator: MediaImportCoordinator
    let onExitFullScreen: () -> Void

    // MARK: - Body

    var body: some View {
        ZStack {
            // Black background
            Color.black.ignoresSafeArea()

            // Video player fills the screen
            // Add extra trailing padding when timecode is in bottom-right to avoid overlapping minimize button
            VideoContentViewForEngine(
                playbackEngine: playbackEngine,
                showTimecode: settings.showTimecodeOverlay,
                overlayPosition: settings.timecodeOverlayPosition,
                overlayOpacity: settings.timecodeOverlayOpacity,
                extraTrailingPadding: settings.timecodeOverlayPosition == .bottomRight ? 50 : 0
            )
            .onDrop(of: [UTType.fileURL, UTType.url], isTargeted: nil) { providers in
                mediaImportCoordinator.handleDrop(providers: providers)
            }
            .ignoresSafeArea()

            // Minimize button in bottom right corner
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    FullScreenToggleButton(isFullScreen: true, action: onExitFullScreen)
                }
            }
        }
    }
}

// #Preview {
//     let manager = TimelineManager()
//     let actor = TimelineActor(timelineManager: manager)
//     let viewModel = TimelineViewModel(service: actor)
//
//     FullScreenVideoView(
//         playbackEngine: PlaybackEngine(),
//         settings: AppSettings.shared,
//         mediaImportCoordinator: MediaImportCoordinator(
//             mediaLibrary: ProjectMediaLibrary(),
//             timelineManager: manager,
//             timelineViewModel: viewModel
//         ),
//         onExitFullScreen: {}
//     )
// }
