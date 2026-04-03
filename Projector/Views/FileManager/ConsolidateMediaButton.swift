//
//  ConsolidateMediaButton.swift
//  Projector
//
//  Button for the media bay header that triggers media optimization/consolidation.
//

import SwiftUI

/// Button that triggers optimization and consolidation of media files
struct ConsolidateMediaButton: View {
    @Binding var showSheet: Bool
    let hasExternalFiles: Bool

    var body: some View {
        if hasExternalFiles {
            Button(action: { showSheet = true }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "bolt.fill")
                    Text("Optimize")
                }
            }
            .buttonStyle(GlassActionButtonStyle(tint: AppColors.accentGreen))
            .help("Optimize media files for better playback and consolidate into project folder")
        }
    }
}
