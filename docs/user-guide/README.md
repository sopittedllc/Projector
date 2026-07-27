# Projector User Guide

**Professional Video Playback with MIDI Timecode Sync**

Projector is a macOS application for frame-accurate multi-reel video playback with MIDI Time Code (MTC) and MIDI Machine Control (MMC) synchronization. Designed for post-production, live events, and professional playback scenarios.

## Table of Contents

### Getting Started
- [Installation & First Project](getting-started.md) - Install Projector and create your first timeline

### Configuration
- [MIDI Sync Setup](midi-sync-setup.md) - Configure MIDI timecode and machine control
- [Audio Routing Guide](audio-routing-guide.md) - Multi-channel audio configuration
- [Keyboard Shortcuts](keyboard-shortcuts.md) - Complete keyboard reference

### Troubleshooting
- [Common Issues & Solutions](troubleshooting.md) - Resolve common problems

## System Requirements

- **macOS**: 14.0 (Sonoma) or later
- **RAM**: 8 GB minimum (16 GB recommended for 4K playback)
- **Storage**: SSD recommended for smooth playback
- **MIDI**: USB MIDI interface (for MTC/MMC sync)
- **Audio**: Multi-channel audio interface (optional, for multi-output routing)

## Key Features

### Multi-Reel Timeline
- Seamless playback across multiple video files
- Gap handling with timer-based advancement
- Frame-accurate positioning

### MIDI Synchronization
- **MTC (MIDI Time Code)**: Auto-sync to external timecode source
- **MMC (MIDI Machine Control)**: Remote transport control
- Drift compensation and quality indicators

### Audio Routing
- Multi-channel output (up to 32+ channels)
- Flexible lane-to-channel mapping
- Per-lane volume, mute, solo controls

### Professional Workflow
- Security-scoped bookmarks (sandbox-safe file access)
- Media consolidation (copy files into project)
- Embedded timecode detection
- Waveform visualization

## Quick Start

1. **Import Media**: Drag video/audio files into the media library
2. **Build Timeline**: Drag files from library to timeline
3. **Configure Audio**: Settings → Audio → Output Mapping
4. **Configure MIDI** (optional): Settings → MIDI → Select Input
5. **Play**: Press Spacebar or receive MTC play command

## Getting Help

- **Issues**: Report bugs at [GitHub Issues](https://github.com/musiquela/Projector/issues)
- **Documentation**: This user guide
- **Updates**: Check for updates in Projector → About Projector
