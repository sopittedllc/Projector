//
//  AlertCoordinator.swift
//  Projector
//
//  Consolidates all alert and sheet state into a single coordinator.
//  Eliminates the need for 8+ separate @State alert properties in ContentView.
//

import Foundation
import SwiftUI
import SwiftTimecodeCore

/// Coordinator for managing all alerts and sheets in the application.
///
/// This coordinator consolidates alert state into a single observable object,
/// replacing the previous pattern of having 8+ separate `@State` alert properties
/// scattered across ContentView.
///
/// ## Architecture Benefits
///
/// - **Single source of truth**: All alert state in one place
/// - **Type-safe**: Enum-based alert types prevent invalid states
/// - **Testable**: Can easily test alert logic without UI
/// - **Maintainable**: Adding new alerts requires only adding enum case
///
/// ## Usage
///
/// ```swift
/// @StateObject private var alertCoordinator = AlertCoordinator()
///
/// // Show an alert
/// alertCoordinator.show(.error("Failed to load file"))
///
/// // Apply to view
/// .alertCoordinator(alertCoordinator)
/// ```
@MainActor
final class AlertCoordinator: ObservableObject {

    // MARK: - Alert Types

    /// All possible alert types in the application.
    enum AlertType: Identifiable {
        // MARK: Error Alerts
        case error(String)
        case videoAlreadyInTimeline(String)
        case audioAlreadyInTimeline(String)
        case duplicateMedia(String)

        // MARK: Confirmation Alerts
        case missingFile(message: String, onLocate: () -> Void, onSkip: () -> Void, onSkipAll: () -> Void)
        case fpsConflict(message: String, onChangeProjectFPS: () -> Void, onCancel: () -> Void)
        case hardPannedAudio(message: String, onSplit: () -> Void, onKeepAsIs: () -> Void)

        // MARK: Sheets
        case videoInsert(
            url: Binding<URL?>,
            frameRate: TimecodeFrameRate,
            startTimecode: Timecode,
            onConfirm: (URL, Int) -> Void
        )
        case saveProject(content: AnyView)
        case settings(content: AnyView)

        var id: String {
            switch self {
            case .error: return "error"
            case .videoAlreadyInTimeline: return "videoAlreadyInTimeline"
            case .audioAlreadyInTimeline: return "audioAlreadyInTimeline"
            case .duplicateMedia: return "duplicateMedia"
            case .missingFile: return "missingFile"
            case .fpsConflict: return "fpsConflict"
            case .hardPannedAudio: return "hardPannedAudio"
            case .videoInsert: return "videoInsert"
            case .saveProject: return "saveProject"
            case .settings: return "settings"
            }
        }
    }

    // MARK: - Published State

    /// Currently active alert/sheet, if any.
    @Published var activeAlert: AlertType?

    // MARK: - Methods

    /// Shows an alert or sheet.
    ///
    /// - Parameter alert: The alert type to show.
    func show(_ alert: AlertType) {
        activeAlert = alert
    }

    /// Dismisses the current alert or sheet.
    func dismiss() {
        activeAlert = nil
    }
}

// MARK: - View Extension

extension View {
    /// Applies the alert coordinator to this view.
    ///
    /// This modifier handles all alert and sheet presentation based on the
    /// coordinator's `activeAlert` state.
    ///
    /// - Parameter coordinator: The alert coordinator to use.
    /// - Returns: A view with alert/sheet modifiers applied.
    func alertCoordinator(_ coordinator: AlertCoordinator) -> some View {
        modifier(AlertCoordinatorModifier(coordinator: coordinator))
    }
}

// MARK: - Alert Coordinator Modifier

/// View modifier that applies all alerts and sheets based on AlertCoordinator state.
private struct AlertCoordinatorModifier: ViewModifier {
    @ObservedObject var coordinator: AlertCoordinator

    func body(content: Content) -> some View {
        content
            // IMPORTANT: Only show alert-type alerts here, not sheets
            // Sheet types are handled by .sheet() below
            .alert(item: Binding(
                get: {
                    // Filter to only return alert types, not sheet types
                    guard let alert = coordinator.activeAlert else { return nil }
                    switch alert {
                    case .error, .videoAlreadyInTimeline, .audioAlreadyInTimeline,
                         .duplicateMedia, .missingFile, .fpsConflict, .hardPannedAudio:
                        return alert  // These are alerts
                    case .videoInsert, .saveProject, .settings:
                        return nil    // These are sheets, don't show as alerts
                    }
                },
                set: { coordinator.activeAlert = $0 }
            )) { alert in
                switch alert {
                case .error(let message):
                    return Alert(
                        title: Text("Error"),
                        message: Text(message),
                        dismissButton: .default(Text("OK"))
                    )

                case .videoAlreadyInTimeline(let name):
                    return Alert(
                        title: Text("Already in Timeline"),
                        message: Text("\"\(name)\" is already on the timeline."),
                        dismissButton: .default(Text("OK"))
                    )

                case .audioAlreadyInTimeline(let name):
                    return Alert(
                        title: Text("Already in Timeline"),
                        message: Text("\"\(name)\" is already on the timeline."),
                        dismissButton: .default(Text("OK"))
                    )

                case .duplicateMedia(let message):
                    return Alert(
                        title: Text("Already in Project"),
                        message: Text(message),
                        dismissButton: .default(Text("OK"))
                    )

                case .missingFile(let message, let onLocate, let onSkip, _):
                    // Note: SwiftUI Alert only supports 2 buttons, so "Skip All" (4th param) is unused here
                    // and would require a sheet-based approach to implement
                    return Alert(
                        title: Text("Missing File"),
                        message: Text(message),
                        primaryButton: .default(Text("Locate..."), action: onLocate),
                        secondaryButton: .destructive(Text("Skip"), action: onSkip)
                    )

                case .fpsConflict(let message, let onChangeProjectFPS, let onCancel):
                    return Alert(
                        title: Text("Frame Rate Mismatch"),
                        message: Text(message),
                        primaryButton: .destructive(Text("Change Project FPS"), action: onChangeProjectFPS),
                        secondaryButton: .cancel(Text("Cancel"), action: onCancel)
                    )

                case .hardPannedAudio(let message, let onSplit, let onKeepAsIs):
                    // Splitting is offered, never assumed: the detector reads
                    // correlation, and a wide stereo mix can look like a split
                    // track. Restructuring a timeline on that guess is worse
                    // than leaving the file alone.
                    return Alert(
                        title: Text("Hard-Panned Audio Detected"),
                        message: Text(message),
                        primaryButton: .default(Text("Split Channels"), action: onSplit),
                        secondaryButton: .cancel(Text("Keep As Is"), action: onKeepAsIs)
                    )

                default:
                    // Sheet types should never reach here due to binding filter above
                    return Alert(title: Text("Unexpected Alert"))
                }
            }
            .sheet(item: Binding(
                get: {
                    // Only return sheet-type alerts (excluding settings, which is handled by ContentView)
                    guard let alert = coordinator.activeAlert else { return nil }
                    switch alert {
                    case .videoInsert, .saveProject:
                        return alert
                    case .settings:
                        // Settings sheet is handled separately by ContentView
                        return nil
                    default:
                        return nil
                    }
                },
                set: { coordinator.activeAlert = $0 }
            )) { alert in
                sheetContent(for: alert)
            }
    }

    @ViewBuilder
    private func sheetContent(for alert: AlertCoordinator.AlertType) -> some View {
        switch alert {
        case .videoInsert(let url, let frameRate, let startTimecode, let onConfirm):
            VideoInsertSheetView(
                url: url,
                frameRate: frameRate,
                startTimecode: startTimecode,
                onConfirm: onConfirm
            )

        case .saveProject(let content):
            content

        case .settings(let content):
            content

        default:
            EmptyView()
        }
    }
}
