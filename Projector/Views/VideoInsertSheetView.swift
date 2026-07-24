import SwiftUI
import SwiftTimecodeCore

/// A sheet view for placing video at a specific timecode position.
///
/// Presents a timecode input field and allows the user to confirm placement
/// of a video file at the specified timeline position.
///
/// ## Usage
/// ```swift
/// .sheet(isPresented: $showVideoInsertSheet) {
///     VideoInsertSheetView(
///         url: $videoInsertURL,
///         frameRate: timeline.config.frameRate,
///         startTimecode: timeline.config.startTimecode,
///         onConfirm: { url, frame in
///             await addVideoToTimeline(url: url, atFrame: frame)
///         }
///     )
/// }
/// ```
struct VideoInsertSheetView: View {
    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Properties

    /// The URL of the video file to insert. Set to nil on dismiss.
    @Binding var url: URL?

    /// The timeline's frame rate for timecode parsing.
    let frameRate: TimecodeFrameRate

    /// The timeline's start timecode for calculating frame offsets.
    let startTimecode: Timecode

    /// Callback when the user confirms video placement.
    /// - Parameters:
    ///   - url: The video file URL
    ///   - frame: The target frame number (relative to timeline start)
    let onConfirm: (URL, Int) -> Void

    // MARK: - State

    /// The current timecode input text.
    @State private var timecodeText: String = ""

    /// Error message to display if timecode is invalid.
    @State private var errorMessage: String?

    /// Focus state for timecode field
    @FocusState private var isTimecodeFocused: Bool

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Place Video")
                .font(.system(size: 14, weight: .semibold))

            Text("Enter the timecode where the video should start.")
                .font(Typography.body)
                .foregroundColor(.secondary)

            TextField("00:00:00:00", text: $timecodeText)
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .focused($isTimecodeFocused)
                .onChange(of: timecodeText) { _, newValue in
                    timecodeText = Self.formatTimecodeInput(newValue)
                }
                .onSubmit {
                    confirmVideoInsert()
                }

            if let error = errorMessage {
                Text(error)
                    .font(Typography.bodySmall)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    clearAndDismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Place") {
                    confirmVideoInsert()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 320)
        .onAppear {
            // Initialize timecode text to the start timecode
            timecodeText = startTimecode.stringValue()
        }
    }

    // MARK: - Private Methods

    /// Confirms the video insert and calls the onConfirm callback.
    private func confirmVideoInsert() {
        guard let videoURL = url else {
            clearAndDismiss()
            return
        }

        guard let timecode = Self.parseTimecode(timecodeText, at: frameRate) else {
            errorMessage = "Invalid timecode."
            return
        }

        let startFrames = startTimecode.frameCount.wholeFrames
        let targetFrame = max(0, timecode.frameCount.wholeFrames - startFrames)

        clearAndDismiss()
        onConfirm(videoURL, targetFrame)
    }

    /// Clears state and dismisses the sheet.
    private func clearAndDismiss() {
        url = nil
        errorMessage = nil
        dismiss()
    }

    // MARK: - Static Helpers

    /// Formats raw input into a timecode string (HH:MM:SS:FF).
    ///
    /// Takes any string input, extracts digits, pads/trims to 8 digits,
    /// and formats with colons.
    ///
    /// - Parameter input: Raw user input string
    /// - Returns: Formatted timecode string in HH:MM:SS:FF format
    static func formatTimecodeInput(_ input: String) -> String {
        let digits = input.filter { $0.isNumber }
        let padded = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        let trimmed = String(padded.suffix(8))
        guard trimmed.count == 8 else { return "00:00:00:00" }

        let h = trimmed.prefix(2)
        let m = trimmed.dropFirst(2).prefix(2)
        let s = trimmed.dropFirst(4).prefix(2)
        let f = trimmed.dropFirst(6).prefix(2)
        return "\(h):\(m):\(s):\(f)"
    }

    /// Parses a timecode string into a Timecode value.
    ///
    /// Extracts digits from the input, interprets as HHMMSSFF,
    /// and creates a clamped Timecode at the given frame rate.
    ///
    /// - Parameters:
    ///   - string: The timecode string to parse
    ///   - frameRate: The frame rate to use for the Timecode
    /// - Returns: A Timecode value, or nil if parsing fails
    static func parseTimecode(_ string: String, at frameRate: TimecodeFrameRate) -> Timecode? {
        let digits = string.filter { $0.isNumber }
        let padded = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        let trimmed = String(padded.suffix(8))
        guard trimmed.count == 8 else { return nil }

        let h = Int(trimmed.prefix(2)) ?? 0
        let m = Int(trimmed.dropFirst(2).prefix(2)) ?? 0
        let s = Int(trimmed.dropFirst(4).prefix(2)) ?? 0
        let f = Int(trimmed.dropFirst(6).prefix(2)) ?? 0

        return Timecode(.components(h: h, m: m, s: s, f: f), at: frameRate, by: .clamping)
    }
}
