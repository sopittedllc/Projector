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
                    Text("Consolidate")
                }
            }
            .buttonStyle(GlassActionButtonStyle(tint: .orange))
            .help("Copy external media files into the project folder")
        }
    }
}
