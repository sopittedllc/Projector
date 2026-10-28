//
//  PrepareMediaButton.swift
//  Projector
//
//  Button for the media bay header that opens the optimize sheet.
//

import SwiftUI

/// Re-encodes heavy media so it plays back smoothly.
struct PrepareMediaButton: View {
    let hasWork: Bool
    var compact: Bool = false
    /// Why the button cannot be used right now; `nil` when it can.
    var disabledReason: String?
    let action: () -> Void

    /// Dimming for a button that is shown but cannot be used.
    private static let disabledOpacity: Double = 0.5

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
            // Tooltip goes through the style, not .help(): NSToolTip never
            // fires through the macOS 26 glassEffect layer this button sits on.
            .buttonStyle(GlassActionButtonStyle(
                tint: AppColors.accentGreen,
                help: disabledReason ?? "Re-encode heavy files so they play back smoothly"
            ))
            .disabled(disabledReason != nil)
            .opacity(disabledReason == nil ? 1 : Self.disabledOpacity)
            .accessibilityLabel("Optimize media for smoother playback")
        }
    }
}
