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
    /// When true, shows only the icon (no "Consolidate" label) for narrow layouts.
    var compact: Bool = false

    var body: some View {
        if hasExternalFiles {
            Button(action: { showSheet = true }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "arrow.down.doc.fill")
                    if !compact {
                        Text("Consolidate")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            // Tooltip goes through the style, not .help(): NSToolTip never
            // fires through the macOS 26 glassEffect layer this button sits on.
            // Compact only - when the "Consolidate" label is visible the
            // tooltip would just repeat it.
            .buttonStyle(GlassActionButtonStyle(
                tint: AppColors.accentGreen,
                help: compact ? "Copy external media files into the project folder" : nil
            ))
            .accessibilityLabel("Consolidate media into project folder")
        }
    }
}
