//
//  OptimizeMediaButton.swift
//  Projector
//
//  Button for the media bay header that opens the optimization sheet.
//

import SwiftUI

/// Button that opens the media optimization sheet
struct OptimizeMediaButton: View {
    @Binding var showSheet: Bool
    let hasUnoptimizedFiles: Bool

    var body: some View {
        if hasUnoptimizedFiles {
            Button(action: { showSheet = true }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "stopwatch")
                    Text("Optimize")
                }
            }
            .buttonStyle(GlassActionButtonStyle(tint: .green))
            .help("Optimize media files to reduce project size")
        }
    }
}
