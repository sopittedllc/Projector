//
//  SettingsAccordionView.swift
//  Projector
//
//  The accordion itself was REMOVED 2026-07-26. Settings is an overlay now,
//  opened from the gear in the video controls: it is app configuration rather
//  than part of the project, and as a panel it competed for height with the
//  media it sat above. Nothing was lost - SettingsView already covered its
//  Timecode Overlay and Audio Output sections, plus MIDI.
//
//  The channel-mapping grid that lived here went too, on 2026-07-26: audio
//  outputs are now built through the guided DX/SFX, MX and "add additional"
//  flow in SettingsView, so a hand-edited grid had nothing left to do.
//
//  The file is NOT empty. It still holds the shared `View.cursor(_:)` helper,
//  which OptimizationSheetView depends on. That belongs somewhere better named,
//  but moving it is a separate job.
//

import SwiftUI

// MARK: - Channel State

/// Represents the state of a single channel in the audio output grid
enum ChannelState: Equatable {
    case inactive
    case activeMono(outputId: UUID)
    case stereoPrimary(outputId: UUID)
    case stereoSecondary(outputId: UUID)
}

// MARK: - Channel Item (for grouped rendering)

/// Represents an item in the channel grid - can be a single channel or a stereo group
enum ChannelItem: Identifiable {
    case inactive(channel: Int)
    case mono(channel: Int, outputId: UUID)
    case stereoGroup(channels: (Int, Int), outputId: UUID)

    var id: String {
        switch self {
        case .inactive(let channel):
            return "inactive-\(channel)"
        case .mono(let channel, _):
            return "mono-\(channel)"
        case .stereoGroup(let channels, _):
            return "stereo-\(channels.0)-\(channels.1)"
        }
    }
}



// MARK: - Channel Grid View




// MARK: - Stereo Group View


// MARK: - Channel Cell View



// MARK: - Cursor Extension

extension View {
    /// Sets the cursor type when hovering over this view
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { isHovered in
            if isHovered {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Output Row View



// MARK: - Preview

#if DEBUG

#endif
