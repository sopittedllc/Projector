import SwiftUI
import SwiftTimecodeCore

/// Bottom transport bar with timecode display and controls
struct TransportBarView: View {
    @ObservedObject var playerManager: VideoPlayerManager
    let onSettingsPressed: () -> Void

    @State private var isEditingTimecode = false
    @State private var editingTimecodeText = ""

    var body: some View {
        HStack(spacing: 16) {
            // Timecode display with label - double-click to set current frame's timecode
            EditableTimecodeView(
                timecode: playerManager.currentTimecode,
                frameRate: playerManager.frameRate,
                hasVideo: playerManager.hasVideo,
                isEditing: $isEditingTimecode,
                editingText: $editingTimecodeText,
                onSetCurrentTimecode: { newTimecode in
                    // Calculate new offset: newTimecode - currentPositionInFrames = newOffset
                    let currentPositionFrames = Int(playerManager.currentTime * playerManager.frameRate.fps)
                    let newTimecodeFrames = newTimecode.frameCount.wholeFrames
                    let newOffsetFrames = newTimecodeFrames - currentPositionFrames
                    if let newOffset = try? Timecode(.frames(max(0, newOffsetFrames)), at: playerManager.frameRate) {
                        playerManager.setTimecodeOffset(newOffset)
                    }
                }
            )

            Spacer()

            // Transport controls
            HStack(spacing: 8) {
                // Step backward
                Button(action: { playerManager.stepBackward() }) {
                    Image(systemName: "backward.frame.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!playerManager.hasVideo)

                // Play/Pause
                Button(action: { playerManager.togglePlayback() }) {
                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .disabled(!playerManager.hasVideo)
                .keyboardShortcut(.space, modifiers: [])

                // Step forward
                Button(action: { playerManager.stepForward() }) {
                    Image(systemName: "forward.frame.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!playerManager.hasVideo)

                // Stop (return to start)
                Button(action: { playerManager.stop() }) {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!playerManager.hasVideo)
            }

            Spacer()

            // Frame rate indicator
            if playerManager.hasVideo {
                Text(playerManager.frameRate.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.1))
                    )
            }

            // Settings button
            Button(action: onSettingsPressed) {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

/// Editable timecode display with label - double-click to set current frame's timecode
struct EditableTimecodeView: View {
    let timecode: Timecode
    let frameRate: TimecodeFrameRate
    let hasVideo: Bool
    @Binding var isEditing: Bool
    @Binding var editingText: String
    let onSetCurrentTimecode: (Timecode) -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        // Wrap everything in a container with consistent left padding
        VStack(alignment: .leading, spacing: 2) {
            // Label
            Text("PROJECTOR TC:")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            // Timecode display or edit field
            if isEditing {
                TextField("00:00:00:00", text: $editingText)
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .textFieldStyle(.plain)
                    .fixedSize()
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        commitEdit()
                    }
                    .onExitCommand {
                        cancelEdit()
                    }
                    .onChange(of: editingText) { _, newValue in
                        editingText = autoFormatTimecode(newValue)
                    }
                    .onAppear {
                        isTextFieldFocused = true
                    }
            } else {
                Text(timecode.stringValue())
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .onTapGesture(count: 2) {
                        startEditing()
                    }
                    .help("Double-click to set this frame's timecode")
            }

            // Hint text (only shown when video is loaded)
            if hasVideo {
                Text("Double-click to set timeline")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func startEditing() {
        // Clear the field so user can start typing fresh
        editingText = ""
        isEditing = true
    }

    private func commitEdit() {
        // Parse the entered timecode and set it as current frame's timecode
        let formatted = formatForCommit(editingText)
        if let newTimecode = try? Timecode(.string(formatted), at: frameRate) {
            onSetCurrentTimecode(newTimecode)
        }
        isEditing = false
    }

    /// Format input for final commit (pads with leading zeros)
    private func formatForCommit(_ input: String) -> String {
        let digits = input.filter { $0.isNumber }

        if digits.isEmpty {
            return "00:00:00:00"
        }

        // Already formatted
        if input.contains(":") && input.filter({ $0 == ":" }).count == 3 {
            return input
        }

        // Pad to 8 digits and format
        let padded = String(digits.prefix(8)).padLeft(toLength: 8, withPad: "0")

        let h = padded.prefix(2)
        let m = padded.dropFirst(2).prefix(2)
        let s = padded.dropFirst(4).prefix(2)
        let f = padded.dropFirst(6).prefix(2)

        return "\(h):\(m):\(s):\(f)"
    }

    private func cancelEdit() {
        isEditing = false
    }

    /// Auto-format input to timecode format (HH:MM:SS:FF)
    /// Accepts input like "01020511" and formats to "01:02:05:11"
    private func autoFormatTimecode(_ input: String) -> String {
        // Extract only digits
        let digits = input.filter { $0.isNumber }

        // Don't format if empty or user is still typing
        if digits.isEmpty {
            return ""
        }

        // If already formatted with colons and valid length, keep it
        if input.contains(":") && input.filter({ $0 == ":" }).count == 3 {
            return input
        }

        // Don't auto-format until we have enough digits (let user type freely)
        if digits.count < 8 {
            return digits
        }

        // Pad with leading zeros if needed, max 8 digits
        let padded = String(digits.prefix(8)).padLeft(toLength: 8, withPad: "0")

        // Format as HH:MM:SS:FF
        let h = padded.prefix(2)
        let m = padded.dropFirst(2).prefix(2)
        let s = padded.dropFirst(4).prefix(2)
        let f = padded.dropFirst(6).prefix(2)

        return "\(h):\(m):\(s):\(f)"
    }
}

extension String {
    func padLeft(toLength length: Int, withPad pad: String) -> String {
        let toPad = length - self.count
        if toPad < 1 { return self }
        return String(repeating: pad, count: toPad) + self
    }
}

/// Simple styled timecode display (non-editable, for overlays)
struct TimecodeDisplayView: View {
    let timecode: Timecode

    var body: some View {
        Text(timecode.stringValue())
            .font(.system(size: 28, weight: .medium, design: .monospaced))
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            )
    }
}

#Preview {
    TransportBarView(
        playerManager: VideoPlayerManager(),
        onSettingsPressed: {}
    )
    .frame(width: 600)
}
