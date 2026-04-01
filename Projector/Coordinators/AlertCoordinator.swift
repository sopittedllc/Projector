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

        // MARK: Sheets
        case embeddedTimecode(
            result: EmbeddedTimecodeResult,
            showSetTimelineStart: Bool,
            onPlaceAtTimecode: (Bool) -> Void,
            onPlaceAtDropLocation: () -> Void,
            onCancel: () -> Void
        )
        case videoInsert(
            url: Binding<URL?>,
            frameRate: TimecodeFrameRate,
            startTimecode: Timecode,
            onConfirm: (URL, Int) -> Void
        )
        case batchTimecode(
            batch: Binding<PendingBatchTimecode?>,
            showSetTimelineStart: Bool,
            onConfirm: (Bool) -> Void,
            onCancel: () -> Void
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
            case .embeddedTimecode: return "embeddedTimecode"
            case .videoInsert: return "videoInsert"
            case .batchTimecode: return "batchTimecode"
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
            .alert(item: $coordinator.activeAlert) { alert in
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

                case .missingFile(let message, let onLocate, let onSkip, let onSkipAll):
                    return Alert(
                        title: Text("Missing File"),
                        message: Text(message),
                        primaryButton: .default(Text("Locate..."), action: onLocate),
                        secondaryButton: .destructive(Text("Skip"), action: onSkip)
                    )
                    // Note: SwiftUI Alert only supports 2 buttons, so "Skip All" will need sheet

                case .fpsConflict(let message, let onChangeProjectFPS, let onCancel):
                    return Alert(
                        title: Text("Frame Rate Mismatch"),
                        message: Text(message),
                        primaryButton: .destructive(Text("Change Project FPS"), action: onChangeProjectFPS),
                        secondaryButton: .cancel(Text("Cancel"), action: onCancel)
                    )

                case .embeddedTimecode, .videoInsert, .batchTimecode, .saveProject, .settings:
                    // These are sheets, handled below
                    return Alert(title: Text(""))
                }
            }
            .sheet(item: Binding(
                get: {
                    // Only return sheet-type alerts
                    guard let alert = coordinator.activeAlert else { return nil }
                    switch alert {
                    case .embeddedTimecode, .videoInsert, .batchTimecode, .saveProject, .settings:
                        return alert
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
        case .embeddedTimecode(let result, let showSetTimelineStart, let onPlaceAtTimecode, let onPlaceAtDropLocation, let onCancel):
            EmbeddedTimecodeSheetView(
                formattedTimecode: result.formattedTimecode,
                sourceDescription: result.source.rawValue,
                showSetTimelineStartOption: showSetTimelineStart,
                onPlaceAtTimecode: onPlaceAtTimecode,
                onPlaceAtDropLocation: onPlaceAtDropLocation,
                onCancel: onCancel
            )

        case .videoInsert(let url, let frameRate, let startTimecode, let onConfirm):
            VideoInsertSheetView(
                url: url,
                frameRate: frameRate,
                startTimecode: startTimecode,
                onConfirm: onConfirm
            )

        case .batchTimecode(let batch, let showSetTimelineStart, let onConfirm, let onCancel):
            BatchTimecodeSheetView(
                batch: batch,
                showSetTimelineStartOption: showSetTimelineStart,
                onConfirm: onConfirm,
                onCancel: onCancel
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
