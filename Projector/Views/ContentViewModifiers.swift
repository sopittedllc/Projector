import SwiftUI
import SwiftTimecodeCore


/// Helper for comparing lane output states in onChange observer
struct LaneOutputState: Equatable {
    let id: UUID
    let mappingId: UUID?
    let offset: Int
    let count: Int
}

// MARK: - View Modifiers for Breaking Up Body Complexity

/// View modifier for applying all sheets
struct SheetsModifier: ViewModifier {
    @Binding var showSettings: Bool
    @Binding var showVideoInsertSheet: Bool
    @Binding var showSaveProjectSheet: Bool
    @Binding var videoInsertURL: URL?
    let frameRate: TimecodeFrameRate
    let startTimecode: Timecode
    let onVideoInsertConfirm: (URL, Int) -> Void
    let settingsView: AnyView
    let saveProjectSheet: AnyView

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showSettings) { settingsView }
            .sheet(isPresented: $showVideoInsertSheet) {
                VideoInsertSheetView(
                    url: $videoInsertURL,
                    frameRate: frameRate,
                    startTimecode: startTimecode,
                    onConfirm: onVideoInsertConfirm
                )
            }
            .sheet(isPresented: $showSaveProjectSheet) { saveProjectSheet }
    }
}

/// View modifier for applying all alerts
struct AlertsModifier: ViewModifier {
    @Binding var showErrorAlert: Bool
    @Binding var showVideoAlreadyInTimelineAlert: Bool
    @Binding var showAudioAlreadyInTimelineAlert: Bool
    @Binding var showDuplicateMediaAlert: Bool
    @Binding var showMissingFilesAlert: Bool
    @Binding var showFPSConflictAlert: Bool
    @Binding var showEmbeddedTimecodeAlert: Bool

    let loadError: String?
    let videoAlreadyInTimelineName: String
    let audioAlreadyInTimelineName: String
    let duplicateMediaAlertMessage: String
    let missingFileMessage: String
    let fpsConflictMessage: String

    let onLocateMissingFile: () -> Void
    let onSkipMissingFile: () -> Void
    let onSkipAllMissingFiles: () -> Void
    let onChangeProjectFPS: () -> Void
    let onCancelFPSConflict: () -> Void
    let onPlaceAtTimecode: (Bool) -> Void  // Bool = setTimelineStart
    let onPlaceAtDropLocation: () -> Void
    let onCancelTimecode: () -> Void
    let pendingTimecodeResult: EmbeddedTimecodeResult?

    func body(content: Content) -> some View {
        content
            .alert("Error Loading Video", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(loadError ?? "Unknown error")
            }
            .alert("Already in Timeline", isPresented: $showVideoAlreadyInTimelineAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\"\(videoAlreadyInTimelineName)\" is already on the timeline.")
            }
            .alert("Already in Timeline", isPresented: $showAudioAlreadyInTimelineAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\"\(audioAlreadyInTimelineName)\" is already on the timeline.")
            }
            .alert("Already in Project", isPresented: $showDuplicateMediaAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(duplicateMediaAlertMessage)
            }
            .alert("Missing File", isPresented: $showMissingFilesAlert) {
                Button("Locate...") { onLocateMissingFile() }
                Button("Skip", role: .destructive) { onSkipMissingFile() }
                Button("Skip All", role: .destructive) { onSkipAllMissingFiles() }
            } message: {
                Text(missingFileMessage)
            }
            .alert("Frame Rate Mismatch", isPresented: $showFPSConflictAlert) {
                Button("Change Project FPS", role: .destructive) { onChangeProjectFPS() }
                Button("Cancel", role: .cancel) { onCancelFPSConflict() }
            } message: {
                Text(fpsConflictMessage)
            }
            .sheet(isPresented: $showEmbeddedTimecodeAlert) {
                EmbeddedTimecodeSheetView(
                    formattedTimecode: pendingTimecodeResult?.formattedTimecode ?? "Unknown",
                    sourceDescription: pendingTimecodeResult?.source.rawValue ?? "unknown source",
                    onPlaceAtTimecode: { setTimelineStart in
                        onPlaceAtTimecode(setTimelineStart)
                    },
                    onPlaceAtDropLocation: onPlaceAtDropLocation,
                    onCancel: onCancelTimecode
                )
            }
    }
}
