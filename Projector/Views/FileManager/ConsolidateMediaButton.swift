//
//  ConsolidateMediaButton.swift
//  Projector
//
//  Button for the media bay header that triggers media optimization/consolidation.
//

import SwiftUI

/// Opens the Prepare Media sheet - the single entry point for collecting files
/// into the project folder and reducing file sizes for playback.
///
/// Replaces the old "Consolidate" button. Those two operations previously sat
/// beside each other as similar pill buttons with no indication of which did
/// what, so they read as duplicates; they are now labelled steps inside one
/// sheet. See `PrepareMediaSheetView` in ConsolidationSheetView.swift.
struct PrepareMediaButton: View {
    @Binding var showSheet: Bool
    /// Whether there is any collecting or reducing to offer.
    let hasWork: Bool
    /// When true, shows only the icon for narrow layouts.
    var compact: Bool = false

    var body: some View {
        if hasWork {
            Button(action: { showSheet = true }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "wand.and.stars")
                    if !compact {
                        Text("Prepare Media")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            // Tooltip goes through the style, not .help(): NSToolTip never
            // fires through the macOS 26 glassEffect layer this button sits on.
            // Compact only - when the label is visible it would just repeat it.
            .buttonStyle(GlassActionButtonStyle(
                tint: AppColors.accentGreen,
                help: compact ? "Collect files into the project and reduce file sizes" : nil
            ))
            .accessibilityLabel("Prepare media")
        }
    }
}
