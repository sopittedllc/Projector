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
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 10))
                    Text("Consolidate")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Copy external media files into the project folder")
        }
    }
}
