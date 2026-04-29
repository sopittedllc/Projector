//
//  ConsolidateMediaButton.swift
//  Projector
//
//  Button for the media bay header that triggers media optimization/consolidation.
//

import SwiftUI

/// Button that triggers consolidation of media files into the project folder
struct ConsolidateMediaButton: View {
    @Binding var showSheet: Bool
    let hasExternalFiles: Bool

    var body: some View {
        if hasExternalFiles {
            Button(action: { showSheet = true }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "arrow.down.doc.fill")
                    Text("Consolidate")
                }
            }
            .buttonStyle(GlassActionButtonStyle(tint: AppColors.accentGreen))
            .help("Copy external media files into the project folder for portability")
        }
    }
}
