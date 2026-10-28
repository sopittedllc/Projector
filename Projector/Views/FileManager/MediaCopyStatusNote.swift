//
//  MediaCopyStatusNote.swift
//  Projector
//
//  A one-line, non-modal note under the media bay header that says imported
//  files are being copied into the project.
//

import SwiftUI

/// Tells the user that imported media is being copied into the project's Media
/// folder, with a progress bar while it is.
///
/// Informs rather than asks: copying is automatic, so this is how the user finds
/// out it happened. It stays up for a few seconds after the last file lands, then
/// the coordinator clears it.
struct MediaCopyStatusNote: View {
    /// The sentence to show.
    let message: String

    /// Where the copy stands; decides whether a progress bar is drawn.
    let status: MediaCopyInCoordinator.Status

    /// Width of the progress bar.
    private static let progressWidth: CGFloat = 96

    var body: some View {
        HStack(spacing: Spacing.sm) {
            icon

            Text(message)
                .font(Typography.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if case .copying(_, _, let fraction) = status {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: Self.progressWidth)
                    .accessibilityLabel("Copy progress")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .copying:
            Image(systemName: "doc.on.doc")
                .foregroundColor(.secondary)
        case .finished:
            Image(systemName: "checkmark.circle")
                .foregroundColor(AppColors.accentGreen)
        case .idle:
            EmptyView()
        }
    }
}
