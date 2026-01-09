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

    var body: some View {
        Button(action: { showSheet = true }) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10))
                Text("Optimize")
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help("Optimize media files to reduce project size")
    }
}
