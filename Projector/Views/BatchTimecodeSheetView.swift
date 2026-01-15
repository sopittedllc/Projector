//
//  BatchTimecodeSheetView.swift
//  Projector
//
//  Sheet view for handling multiple files with embedded timecode detection.
//  Allows users to choose placement preferences for each file in a batch drop.
//

import SwiftUI

/// Sheet view for batch timecode detection with per-file placement options
struct BatchTimecodeSheetView: View {
    /// The batch of files with detected timecodes (binding to allow checkbox updates)
    @Binding var batch: PendingBatchTimecode?

    /// Whether to set the timeline start to the first file's timecode
    let showSetTimelineStartOption: Bool

    /// Called when user confirms placement choices
    let onConfirm: (Bool) -> Void  // Bool = setTimelineStart

    /// Called when user cancels the operation
    let onCancel: () -> Void

    @State private var setTimelineStart = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            Image(systemName: "doc.on.doc")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            Text("Multiple Files Dropped")
                .font(.headline)

            if let batch = batch, batch.hasAnyTimecode {
                Text("Some files contain embedded timecode. Choose placement for each file:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text("Choose how to add these files to the timeline:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Divider()

            // File list with checkboxes
            if let batch = batch {
                fileListView(batch: batch)
            }

            // Set timeline start option (only for video, first file)
            if showSetTimelineStartOption, let batch = batch, batch.hasAnyTimecode {
                Divider()

                Toggle(isOn: $setTimelineStart) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set timeline start to first file's timecode")
                            .font(.body)
                        if let firstWithTC = batch.items.first(where: { $0.hasTimecode && $0.useEmbeddedTimecode }),
                           let tc = firstWithTC.detectedTimecode {
                            Text("The timeline will begin at \(tc.formattedTimecode)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal)
                .disabled(!hasAnyUsingTimecode)
            }

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Add Files") {
                    onConfirm(setTimelineStart)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 540, height: min(550, CGFloat(320 + (batch?.items.count ?? 0) * 40)))
    }

    /// Whether any file in the batch is set to use embedded timecode
    private var hasAnyUsingTimecode: Bool {
        batch?.items.contains { $0.useEmbeddedTimecode } ?? false
    }

    /// File list table view with video/audio sections
    @ViewBuilder
    private func fileListView(batch: PendingBatchTimecode) -> some View {
        VStack(spacing: 0) {
            // Header row
            HStack {
                Text("File")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Timecode")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .leading)

                Text("Use TC")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 60, alignment: .center)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // File rows grouped by media type
            ScrollView {
                VStack(spacing: 0) {
                    // Video section
                    if batch.hasVideoItems {
                        sectionHeader(title: "Video", icon: "film", count: batch.videoItems.count)
                        ForEach(batch.videoItems) { item in
                            fileRow(item: item)
                            Divider()
                        }
                    }

                    // Audio section
                    if batch.hasAudioItems {
                        sectionHeader(title: "Audio", icon: "waveform", count: batch.audioItems.count)
                        ForEach(batch.audioItems) { item in
                            fileRow(item: item)
                            if item.id != batch.audioItems.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minHeight: 50, maxHeight: 250)
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    /// Section header for video/audio groups
    @ViewBuilder
    private func sectionHeader(title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
            Text("\(title) (\(count))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    /// Single file row
    @ViewBuilder
    private func fileRow(item: BatchTimecodeItem) -> some View {
        HStack {
            // File icon and name
            HStack(spacing: 8) {
                Image(systemName: fileIcon(for: item))
                    .foregroundColor(item.hasTimecode ? .accentColor : .secondary)
                    .frame(width: 16)

                Text(item.displayName)
                    .font(.system(.body, design: .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Detected timecode
            if let tc = item.detectedTimecode {
                Text(tc.formattedTimecode)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(width: 100, alignment: .leading)
            } else {
                Text("(none)")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .leading)
            }

            // Checkbox
            Toggle("", isOn: binding(for: item))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 60, alignment: .center)
                .disabled(!item.hasTimecode)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Get the appropriate icon for a file item
    private func fileIcon(for item: BatchTimecodeItem) -> String {
        if item.hasTimecode {
            return item.mediaType == .video ? "film" : "waveform"
        } else {
            return item.mediaType == .video ? "video" : "speaker.wave.2"
        }
    }

    /// Create a binding for a specific item's useEmbeddedTimecode property
    private func binding(for item: BatchTimecodeItem) -> Binding<Bool> {
        Binding(
            get: { item.useEmbeddedTimecode },
            set: { newValue in
                guard var currentBatch = batch,
                      let index = currentBatch.items.firstIndex(where: { $0.id == item.id }) else {
                    return
                }
                currentBatch.items[index].useEmbeddedTimecode = newValue
                batch = currentBatch
            }
        )
    }
}

#Preview("Mixed Video/Audio") {
    BatchTimecodeSheetView(
        batch: .constant(PendingBatchTimecode(
            items: [
                BatchTimecodeItem(
                    url: URL(fileURLWithPath: "/Users/test/Interview_A.mov"),
                    mediaType: .video,
                    detectedTimecode: EmbeddedTimecodeResult(
                        timecodeFrames: 86400,
                        formattedTimecode: "01:00:00:00",
                        source: .quickTimeTrack,
                        frameRate: 24.0,
                        isDropFrame: false
                    )
                ),
                BatchTimecodeItem(
                    url: URL(fileURLWithPath: "/Users/test/FX_Mix.wav"),
                    mediaType: .audio,
                    detectedTimecode: EmbeddedTimecodeResult(
                        timecodeFrames: 86280,
                        formattedTimecode: "00:59:55:00",
                        source: .quickTimeTrack,
                        frameRate: 24.0,
                        isDropFrame: false
                    )
                ),
                BatchTimecodeItem(
                    url: URL(fileURLWithPath: "/Users/test/Music_Track.wav"),
                    mediaType: .audio,
                    detectedTimecode: EmbeddedTimecodeResult(
                        timecodeFrames: 86280,
                        formattedTimecode: "00:59:55:00",
                        source: .quickTimeTrack,
                        frameRate: 24.0,
                        isDropFrame: false
                    )
                )
            ],
            dropFrame: 0
        )),
        showSetTimelineStartOption: true,
        onConfirm: { setStart in
            print("Confirm, setStart: \(setStart)")
        },
        onCancel: {
            print("Cancel")
        }
    )
}

#Preview("Video Only") {
    BatchTimecodeSheetView(
        batch: .constant(PendingBatchTimecode(
            items: [
                BatchTimecodeItem(
                    url: URL(fileURLWithPath: "/Users/test/Clip1.mp4"),
                    mediaType: .video,
                    detectedTimecode: nil
                ),
                BatchTimecodeItem(
                    url: URL(fileURLWithPath: "/Users/test/Clip2.mp4"),
                    mediaType: .video,
                    detectedTimecode: nil
                )
            ],
            dropFrame: 0
        )),
        showSetTimelineStartOption: false,
        onConfirm: { _ in },
        onCancel: { }
    )
}
