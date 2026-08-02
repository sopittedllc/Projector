//
//  BugReportView.swift
//  Projector
//
//  Sheet for describing a problem and sending the diagnostic report.
//

import SwiftUI

/// Layout constants for the bug report sheet.
private enum BugReportLayout {
    static let sheetWidth: CGFloat = 560
    static let sheetHeight: CGFloat = 620
    static let descriptionHeight: CGFloat = 110
    static let previewHeight: CGFloat = 220

    /// Monospaced face for the report preview. Small on purpose: the point is
    /// to let a user scan the whole thing, not to read it comfortably.
    static let reportFont = Font.system(size: 10, design: .monospaced)

    /// Nudge that lines the placeholder up with `TextEditor`'s first line,
    /// which sits slightly lower than its own padding suggests.
    static let placeholderBaselineNudge: CGFloat = 2
}

/// Lets a user describe a problem and send it with the diagnostic report.
///
/// The report is shown in full before anything is sent. Composers routinely work
/// on unreleased material under NDA, and the report carries media file paths, so
/// "trust us" is not good enough - the contents are on screen and the user
/// decides.
struct BugReportView: View {
    @ObservedObject var viewModel: BugReportViewModel

    /// Closes the sheet.
    @Binding var isPresented: Bool

    /// Starts expanded. A review pane the user has to go looking for is not a
    /// review pane - the whole point is that nothing leaves the machine
    /// unseen, so the contents are on screen from the moment the sheet opens.
    @State private var isShowingReport = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            descriptionField
            reportDisclosure

            if let outcome = viewModel.outcome {
                outcomeMessage(outcome)
            }

            Spacer(minLength: 0)
            actions
        }
        .padding(Spacing.xl)
        .frame(width: BugReportLayout.sheetWidth, height: BugReportLayout.sheetHeight)
        .task {
            await viewModel.prepare()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "ladybug")
                    .font(Typography.title)
                    .foregroundColor(AppColors.accentPink)

                Text("Report a Bug")
                    .font(Typography.title)
            }

            Text("Tell us what went wrong. A diagnostic report is attached so we can "
                 + "see what the app was doing at the time.")
                .font(Typography.bodySmall)
                .foregroundColor(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Description

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("What happened?")
                .font(Typography.heading)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.userDescription)
                    .font(Typography.body)
                    .padding(Spacing.xs)
                    .frame(height: BugReportLayout.descriptionHeight)
                    .background(AppColors.surfaceSubtle)
                    .cornerRadius(Spacing.xs)
                    .overlay(
                        RoundedRectangle(cornerRadius: Spacing.xs)
                            .stroke(AppColors.borderSubtle, lineWidth: 1)
                    )

                // TextEditor has no placeholder of its own, and an empty box
                // gives no hint about the detail that makes a report useful.
                if viewModel.userDescription.isEmpty {
                    Text("e.g. “Playback drifted out of sync with MTC after I "
                         + "moved a reel to 01:02:00:00.”")
                        .font(Typography.body)
                        .foregroundColor(AppColors.textMuted)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.sm + BugReportLayout.placeholderBaselineNudge)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Report Preview

    private var reportDisclosure: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            DisclosureGroup(isExpanded: $isShowingReport) {
                Group {
                    if viewModel.isPreparing {
                        HStack(spacing: Spacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Collecting…")
                                .font(Typography.bodySmall)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Spacing.sm)
                    } else {
                        ScrollView {
                            Text(viewModel.previewText)
                                .font(BugReportLayout.reportFont)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Spacing.sm)
                        }
                        .frame(height: BugReportLayout.previewHeight)
                        .background(AppColors.surfaceSubtle)
                        .cornerRadius(Spacing.xs)
                        .padding(.top, Spacing.sm)
                    }
                }
            } label: {
                Text("Review what will be sent")
                    .font(Typography.heading)
            }

            Text("Includes your macOS version, audio and MIDI devices, project "
                 + "statistics, media file paths, and a log of recent activity. "
                 + "Your description is added to the top.")
                .font(Typography.caption)
                .foregroundColor(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Outcome

    @ViewBuilder
    private func outcomeMessage(_ outcome: BugReportViewModel.Outcome) -> some View {
        switch outcome {
        case .emailOpened:
            outcomeRow(
                icon: "checkmark.circle.fill",
                tint: AppColors.accentGreen,
                text: "Your email client is opening with the report attached. "
                    + "Send the message to finish."
            )
        case .saved(let url):
            outcomeRow(
                icon: "checkmark.circle.fill",
                tint: AppColors.accentGreen,
                text: "Saved to \(url.lastPathComponent) and revealed in Finder."
            )
        case .copied:
            outcomeRow(
                icon: "doc.on.clipboard.fill",
                tint: AppColors.accentGreen,
                text: "The report is on your clipboard. Paste it into an email to "
                    + "\(SupportContact.email)."
            )
        case .failed(let message):
            outcomeRow(
                icon: "exclamationmark.triangle.fill",
                tint: AppColors.accentYellow,
                text: message
            )
        }
    }

    private func outcomeRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: icon)
                .foregroundColor(tint)
            Text(text)
                .font(Typography.bodySmall)
                .foregroundColor(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sm)
        .background(tint.opacity(0.12))
        .cornerRadius(Spacing.xs)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: Spacing.sm) {
            Button("Cancel") {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Copy") {
                viewModel.copyToClipboard()
            }
            .disabled(viewModel.isPreparing)
            .accessibilityLabel("Copy the report to the clipboard")

            Button("Save to File…") {
                viewModel.saveToFile()
            }
            .disabled(viewModel.isPreparing)
            .accessibilityLabel("Save the report as a file")

            Button("Send by Email") {
                viewModel.sendByEmail()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(viewModel.isPreparing)
            .accessibilityLabel("Send the report by email")
        }
    }
}

#Preview {
    BugReportView(
        viewModel: BugReportViewModel(gatherSnapshot: {
            DiagnosticSnapshot(
                appVersion: "1.4",
                appBuild: "1",
                bundleIdentifier: "com.projector.app",
                osVersion: "15.0",
                hardwareModel: "Mac14,6",
                architecture: "arm64",
                physicalMemoryGB: 32,
                uptime: 1_234,
                audioOutputs: ["Stereo Out (1-2)"],
                midiInputs: ["IAC Driver Bus 1"],
                selectedMIDIInput: "IAC Driver Bus 1",
                midiSyncState: "idle",
                projectPath: "/Users/someone/Film.projector",
                hasUnsavedChanges: true,
                videoReelCount: 2,
                audioLaneCount: 3,
                audioClipCount: 7,
                timelineFrameRate: "24",
                timelineDurationFrames: 172_800,
                mediaPaths: ["/Users/someone/Media/reel1.mov"]
            )
        }),
        isPresented: .constant(true)
    )
}
