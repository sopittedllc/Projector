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
                        .font(.system(size: 10))
                    Text("Optimize")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(Color.green.opacity(0.15))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Optimize media files to reduce project size")
        }
    }
}
