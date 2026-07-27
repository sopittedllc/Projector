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
/// Copies media that lives outside the project folder into it.
///
/// Separate from optimizing again. They were briefly merged behind one
/// "Prepare Media" sheet, but they answer different questions - "is this
/// project portable?" and "will this play back smoothly?" - and a user who
/// wants one rarely wants the other in the same moment.
struct ConsolidateMediaButton: View {
    let hasWork: Bool
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        if hasWork {
            Button(action: action) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "folder.badge.plus")
                    if !compact {
                        Text("Consolidate Media")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            // Tooltip goes through the style, not .help(): NSToolTip never
            // fires through the macOS 26 glassEffect layer this button sits on.
            .buttonStyle(GlassActionButtonStyle(
                tint: AppColors.accentBlue,
                help: "Copy media into the project folder so the project stays portable"
            ))
            .accessibilityLabel("Consolidate media into the project folder")
        }
    }
}

/// Re-encodes heavy media so it plays back smoothly.
struct PrepareMediaButton: View {
    let hasWork: Bool
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        if hasWork {
            Button(action: action) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "wand.and.stars")
                    if !compact {
                        Text("Optimize Media")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .buttonStyle(GlassActionButtonStyle(
                tint: AppColors.accentGreen,
                help: "Re-encode heavy files so they play back smoothly"
            ))
            .accessibilityLabel("Optimize media for smoother playback")
        }
    }
}

