//
//  BugReportViewModel.swift
//  Projector
//
//  Gathers a diagnostic report and hands it to the user's mail client.
//

import AppKit
import Combine
import Foundation

/// Drives the Report a Bug sheet.
///
/// Gathering happens once when the sheet opens, so the report describes the app
/// as it was when the user noticed the problem rather than after they have
/// clicked around describing it.
@MainActor
final class BugReportViewModel: ObservableObject {

    /// What the user typed. Added to the top of the report when it is sent.
    @Published var userDescription: String = ""

    /// The diagnostic half of the report - everything the app gathered on its
    /// own, without the user's description.
    ///
    /// Built once, because the log it contains can run to a hundred kilobytes
    /// and re-rendering that on every keystroke would make the description box
    /// stutter. The sheet says the description is added on top rather than
    /// showing a stale placeholder in its place.
    @Published private(set) var previewText: String = ""

    /// True until the snapshot and log have been collected.
    @Published private(set) var isPreparing = true

    /// Set when sending has been attempted, so the sheet can report what
    /// happened without throwing an alert on top of itself.
    @Published private(set) var outcome: Outcome?

    /// How a send attempt finished.
    enum Outcome: Equatable {
        /// The mail client was handed the report.
        case emailOpened
        /// Written to a file the user chose.
        case saved(URL)
        /// Placed on the clipboard.
        case copied
        /// Nothing was sent. Carries a sentence fit to show a user.
        case failed(String)
    }

    /// Produces the state half of the report.
    ///
    /// A closure rather than a pile of manager references, so the view model
    /// stays independent of how that state is assembled.
    private let gatherSnapshot: () -> DiagnosticSnapshot

    private var snapshot: DiagnosticSnapshot?
    private var log: [DiagnosticEntry] = []
    private var overwritten = 0

    /// - Parameter gatherSnapshot: Called once, on the main actor, to read the
    ///   app's current state.
    init(gatherSnapshot: @escaping () -> DiagnosticSnapshot) {
        self.gatherSnapshot = gatherSnapshot
    }

    // MARK: - Preparation

    /// Collects the snapshot and log, then renders the preview.
    func prepare() async {
        let snapshot = gatherSnapshot()
        let log = await DiagnosticLog.shared.snapshot()
        let overwritten = await DiagnosticLog.shared.overwrittenCount()

        self.snapshot = snapshot
        self.log = log
        self.overwritten = overwritten
        self.previewText = DiagnosticReportBuilder.diagnosticSections(
            snapshot: snapshot,
            log: log,
            overwritten: overwritten
        )
        self.isPreparing = false

        diagnosticLog(.info, .app, "Bug report sheet opened (\(log.count) log entries)")
    }

    // MARK: - Delivery

    /// Writes the report and opens the user's mail client with it attached.
    func sendByEmail() {
        guard let url = writeReport() else { return }

        guard let service = NSSharingService(named: .composeEmail) else {
            outcome = .failed(
                "No email client is set up on this Mac. Use “Save to File…” and "
                + "send the report however you prefer."
            )
            return
        }

        service.recipients = [SupportContact.email]
        service.subject = emailSubject

        // The string becomes the message body and the file URL the attachment.
        let items: [Any] = [emailBody, url]

        guard service.canPerform(withItems: items) else {
            outcome = .failed(
                "This Mac's email client could not accept the report. Use "
                + "“Save to File…” and send it however you prefer."
            )
            return
        }

        service.perform(withItems: items)
        outcome = .emailOpened
        diagnosticLog(.info, .app, "Bug report handed to mail client")
    }

    /// Writes the report to a location the user picks.
    ///
    /// Always available, not just when mail fails - a user who would rather send
    /// the file through their own channel should not have to trip an error to
    /// get at it.
    func saveToFile() {
        guard let text = finalReportText() else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = reportFilename
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.title = "Save Bug Report"
        panel.message = "Save the diagnostic report so you can send it on."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            outcome = .saved(url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            diagnosticLog(.info, .app, "Bug report saved to file")
        } catch {
            outcome = .failed("The report could not be saved: \(error.localizedDescription)")
            diagnosticLog(.error, .app, "Bug report save failed: \(error.localizedDescription)")
        }
    }

    /// Puts the whole report on the clipboard.
    ///
    /// The escape hatch for a user whose mail client will not cooperate and who
    /// would rather paste into a message than deal with a file.
    func copyToClipboard() {
        guard let text = finalReportText() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        outcome = .copied
        diagnosticLog(.info, .app, "Bug report copied to clipboard")
    }

    // MARK: - Private

    /// The report with the user's description in place.
    private func finalReportText() -> String? {
        guard let snapshot else { return nil }
        return DiagnosticReportBuilder.build(
            description: userDescription,
            snapshot: snapshot,
            log: log,
            overwritten: overwritten
        )
    }

    /// Writes the report into the app's temporary directory for attaching.
    ///
    /// The sandbox grants the mail client access to the file as part of the
    /// share, so a temporary location is enough - the user is never asked to
    /// pick somewhere just to send a report.
    private func writeReport() -> URL? {
        guard let text = finalReportText() else {
            outcome = .failed("The report could not be prepared.")
            return nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(reportFilename)

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            outcome = .failed("The report could not be written: \(error.localizedDescription)")
            diagnosticLog(.error, .app, "Bug report write failed: \(error.localizedDescription)")
            return nil
        }
    }

    private var reportFilename: String {
        let stamp = Self.filenameFormatter.string(from: Date())
        return "Projector-Bug-Report-\(stamp).txt"
    }

    private var emailSubject: String {
        let version = snapshot?.appVersion ?? "unknown"
        let build = snapshot?.appBuild ?? "?"
        return "Projector bug report — \(version) (\(build))"
    }

    private var emailBody: String {
        let trimmed = userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = trimmed.isEmpty ? "" : "\(trimmed)\n\n"
        body += "The full diagnostic report is attached.\n"
        return body
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
