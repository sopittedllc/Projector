//
//  ConsolidateMediaButton.swift
//  Projector
//
//  Button for the media bay header that triggers media consolidation.
//

import SwiftUI

/// Button that triggers consolidation of external media files
struct ConsolidateMediaButton: View {
    @Binding var showSheet: Bool
    let hasExternalFiles: Bool

    var body: some View {
        if hasExternalFiles {
            Button(action: { showSheet = true }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 10))
                    Text("Consolidate")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Copy external media files into the project folder")
        }
    }
}
