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

        /// A video's codec cannot be decoded on this Mac.
        ///
        /// Carries the codec's own name so the alert can say which format is missing
        /// rather than reporting a generic playback failure.
        case codecUnavailable(codecName: String, onInstall: () -> Void)

        // MARK: Confirmation Alerts
        case missingFile(message: String, onLocate: () -> Void, onSkip: () -> Void, onSkipAll: () -> Void)
        case fpsConflict(message: String, onChangeProjectFPS: () -> Void, onCancel: () -> Void)

        /// Files a multi-file import left behind because their frame rate is not
        /// the project's.
        ///
        /// Reports rather than asks. ``fpsConflict`` offers to change the
        /// project's rate, which removes every reel already on the timeline -
        /// destructive and incoherent halfway through a batch that has just
        /// imported some of those reels. A batch states what it skipped and
        /// leaves the decision for a later, deliberate import.
        case batchFrameRateMismatch(names: [String], projectFPS: String)

        // MARK: Sheets
        case videoInsert(
            url: Binding<URL?>,
            frameRate: TimecodeFrameRate,
            startTimecode: Timecode,
            onConfirm: (URL, Int) -> Void
        )
        case saveProject(content: AnyView)
        case settings(content: AnyView)

        /// Guides the user through installing Apple's Pro Video Formats package.
        case proVideoFormatsInstall(codecName: String)

        var id: String {
            switch self {
            case .error: return "error"
            case .videoAlreadyInTimeline: return "videoAlreadyInTimeline"
            case .audioAlreadyInTimeline: return "audioAlreadyInTimeline"
            case .duplicateMedia: return "duplicateMedia"
            case .codecUnavailable: return "codecUnavailable"
            case .missingFile: return "missingFile"
            case .fpsConflict: return "fpsConflict"
            case .batchFrameRateMismatch: return "batchFrameRateMismatch"
            case .videoInsert: return "videoInsert"
            case .saveProject: return "saveProject"
            case .settings: return "settings"
            case .proVideoFormatsInstall: return "proVideoFormatsInstall"
            }
        }

        /// Whether this case presents as a sheet rather than an alert.
        ///
        /// The two are driven by separate presentation modifiers over the same
        /// state, so each binding needs to know which cases belong to it - both
        /// to decide what to present and to make sure a dismissal only clears
        /// the presentation that actually raised it.
        var isSheet: Bool {
            switch self {
            case .error, .videoAlreadyInTimeline, .audioAlreadyInTimeline,
                 .duplicateMedia, .codecUnavailable, .missingFile, .fpsConflict,
                 .batchFrameRateMismatch:
                return false
            case .videoInsert, .saveProject, .settings, .proVideoFormatsInstall:
                return true
            }
        }
    }

    // MARK: - Published State

    /// Currently active alert/sheet, if any.
    @Published private(set) var activeAlert: AlertType?

    /// Alerts raised while another was already on screen, oldest first.
    ///
    /// Not published: nothing renders the queue, and republishing on every
    /// enqueue would invalidate the whole view tree for state it cannot see.
    private var pending: [AlertType] = []

    // MARK: - Methods

    /// Shows an alert or sheet, or queues it if one is already presenting.
    ///
    /// Queued rather than assigned because several imports can finish at once
    /// and each raises its own question. A batch drop of hard-panned reels used
    /// to overwrite `activeAlert` once per reel, so the user answered whichever
    /// extraction happened to finish last and every other offer was destroyed
    /// before it could be seen - silently discarding work they had asked for.
    ///
    /// - Parameter alert: The alert type to show.
    func show(_ alert: AlertType) {
        guard activeAlert == nil else {
            pending.append(alert)
            return
        }
        activeAlert = alert
    }

    /// Dismisses the current alert or sheet and presents the next queued one.
    func dismiss() {
        activeAlert = nil
        presentNextIfNeeded()
    }

    /// Moves the next queued alert on screen, one runloop turn later.
    ///
    /// The delay is load-bearing. Clearing and reassigning `activeAlert` in a
    /// single turn leaves SwiftUI with no observable transition through nil, and
    /// the replacement alert never appears - so a queued alert would be lost in
    /// exactly the way the queue exists to prevent.
    private func presentNextIfNeeded() {
        guard !pending.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeAlert == nil, !self.pending.isEmpty else { return }
            self.activeAlert = self.pending.removeFirst()
        }
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
                    guard let alert = coordinator.activeAlert, !alert.isSheet else { return nil }
                    return alert
                },
                set: { (newValue: AlertCoordinator.AlertType?) in
                    // Only clear when an alert is what is actually on screen.
                    // This binding reports nil whenever a sheet is active, and
                    // acting on that would dismiss the sheet and pull the next
                    // queued item forward while the user was still reading it.
                    guard case .none = newValue,
                          let active = coordinator.activeAlert,
                          !active.isSheet else { return }
                    coordinator.dismiss()
                }
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

                case .codecUnavailable(let codecName, let onInstall):
                    return Alert(
                        title: Text("Cannot Play \(codecName)"),
                        message: Text(
                            "This Mac has no decoder for \(codecName). Apple publishes "
                            + "a free package, Pro Video Formats, that adds one.\n\n"
                            + "The reel stays on the timeline with its timecode intact, "
                            + "so audio can still be placed against it."
                        ),
                        primaryButton: .default(Text("Install…"), action: onInstall),
                        secondaryButton: .cancel(Text("Not Now"))
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

                case .batchFrameRateMismatch(let names, let projectFPS):
                    let list: String = names.map { "• \($0)" }.joined(separator: "\n")
                    let message: String = "This project runs at \(projectFPS), and these files do not:\n\n"
                        + list
                        + "\n\nEverything else in the drop was imported. Projector plays one "
                        + "frame rate at a time, so mixing them on a timeline would put every "
                        + "timecode out."
                    return Alert(
                        title: Text("Not Imported"),
                        message: Text(message),
                        dismissButton: .default(Text("OK"))
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
                    case .videoInsert, .saveProject, .proVideoFormatsInstall:
                        return alert
                    case .settings:
                        // Settings sheet is handled separately by ContentView
                        return nil
                    default:
                        return nil
                    }
                },
                set: { (newValue: AlertCoordinator.AlertType?) in
                    // Mirrors the alert binding: this one reports nil for every
                    // alert-type case too, so it must confirm one of its own
                    // sheets is presenting before clearing it.
                    guard case .none = newValue,
                          let active = coordinator.activeAlert,
                          active.isSheet, active.id != "settings" else { return }
                    coordinator.dismiss()
                }
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

        case .proVideoFormatsInstall(let codecName):
            ProVideoFormatsInstallSheet(codecName: codecName) {
                coordinator.dismiss()
            }

        default:
            EmptyView()
        }
    }
}
