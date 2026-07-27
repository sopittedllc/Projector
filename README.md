# Projector

A professional macOS video playback application with MTC/MMC synchronization for broadcast and post-production workflows.

## Overview

Projector is a native macOS app built with SwiftUI and AVFoundation, designed for frame-accurate video playback with industry-standard timecode synchronization. It integrates seamlessly with DAWs, video editors, and other professional audio/video tools via MIDI Time Code (MTC) and MIDI Machine Control (MMC).

## Key Features

- **Multi-Track Timeline** - Video track with multiple audio lanes, drag-and-drop support, and zoom controls
- **Frame-Accurate Playback** - Precise seeking and transport controls with timecode overlay
- **MTC/MMC Synchronization** - Sync with Pro Tools, Logic, Nuendo, and other DAWs
- **Flexible Audio Routing** - Route audio lanes to specific output channels via Core Audio
- **Waveform Visualization** - High-performance waveform rendering with DSWaveformImage
- **Media Optimization** - Automatic detection and transcoding for optimal playback performance
- **Embedded Timecode Detection** - reads timecode from QuickTime tracks, BWF/broadcast WAV, and XMP metadata, and places media at it on import

## Architecture

Projector follows a two-layer architecture with strict separation between UI and business logic:

```
┌─────────────────────────────────────────────────────────────────┐
│                     PRESENTATION LAYER                          │
│   SwiftUI Views  →  ViewModels (@MainActor)  →  THE CONTRACT   │
├─────────────────────────────────────────────────────────────────┤
│                        THE CONTRACT                              │
│   Protocols + AsyncStreams + Sendable Types                     │
├─────────────────────────────────────────────────────────────────┤
│                        LOGIC LAYER                               │
│   Swift Actors  ←  CoreMIDI/CoreAudio  ←  Real-time Callbacks  │
└─────────────────────────────────────────────────────────────────┘
```

### Core Components

| Component | Purpose |
|-----------|---------|
| `PlaybackEngine` | AVFoundation-based video playback |
| `TimelineManager` | Timeline state and CRUD operations |
| `TimelineActor` | Thread-safe timeline operations via AsyncStream |
| `TransportActor` | Transport control with frame-accurate positioning |
| `MIDISyncActor` | MTC/MMC parsing and sync state |
| `AudioOutputManager` | Core Audio routing via AUMatrixMixer |

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later
- Apple Developer account (for code signing)

## Building

1. Clone the repository
2. Open `Projector.xcodeproj` in Xcode
3. Select the Projector scheme
4. Build and run (⌘R)

## Project Structure

```
Projector/
├── Projector/                  # Main app target
│   ├── Views/                  # SwiftUI views
│   ├── ViewModels/             # @MainActor view models
│   ├── Managers/               # Business logic (actors, services)
│   ├── Models/                 # Data structures
│   ├── Contracts/              # Service protocols
│   ├── Coordinators/           # Alert/sheet coordination
│   └── Utilities/              # Layout constants, helpers
├── ProjectorTests/             # Unit tests
├── ProjectorUITests/           # UI tests
├── ProjectorQuickLook/         # Quick Look extension
└── docs/                       # User documentation
```

## Documentation

- [Getting Started Guide](docs/getting-started.md)
- [MIDI Sync Setup](docs/midi-sync-setup.md)
- [Audio Routing Guide](docs/audio-routing-guide.md)
- [Keyboard Shortcuts](docs/keyboard-shortcuts.md)
- [Troubleshooting](docs/troubleshooting.md)

## Development

See [CLAUDE.md](CLAUDE.md) for development standards and the multi-agent workflow.

- [PROJECT_ROADMAP.md](PROJECT_ROADMAP.md) - Progress tracking
- [FEATURES.md](FEATURES.md) - Feature registry
- [KNOWLEDGE_BASE.md](KNOWLEDGE_BASE.md) - Patterns and lessons learned

## License

Copyright © 2026 Musique LA. All rights reserved.
