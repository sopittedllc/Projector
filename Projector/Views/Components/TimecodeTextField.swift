//
//  TimecodeTextField.swift
//  Projector
//
//  Reusable timecode editing component with auto-formatting and validation.
//

import SwiftUI

/// A text field for editing timecode values with automatic formatting and validation.
///
/// ## Features
/// - Auto-formats input as HH:MM:SS:FF
/// - Validates frame numbers against frame rate
/// - Monospaced font for alignment
/// - Visual feedback for invalid input
///
/// ## Usage
/// ```swift
/// TimecodeTextField(
///     timecode: $startTimecode,
///     frameRate: 24.0,
///     label: "Start TC"
/// )
/// ```
struct TimecodeTextField: View {
    /// Binding to the timecode string (format: "HH:MM:SS:FF")
    @Binding var timecode: String

    /// Frame rate for frame validation (default: 24.0)
    var frameRate: Double = 24.0

    /// Label for the text field (optional)
    var label: String = ""

    /// Width of the text field (default: 100)
    var width: CGFloat = 100

    @State private var isEditing = false
    @State private var isInvalid = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(label, text: $timecode)
            .textFieldStyle(.roundedBorder)
            .font(Typography.mono)
            .frame(width: width)
            .focused($isFocused)
            .onChange(of: timecode) { _, newValue in
                let (formatted, valid) = formatAndValidate(newValue)
                timecode = formatted
                isInvalid = !valid
            }
            .onSubmit {
                isFocused = false
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isInvalid ? Color.red : Color.clear, lineWidth: 1)
            )
            .help("Format: HH:MM:SS:FF")
    }

    // MARK: - Formatting & Validation

    /// Formats and validates timecode input
    ///
    /// - Parameter input: Raw input string
    /// - Returns: Tuple of (formatted string, is valid)
    private func formatAndValidate(_ input: String) -> (String, Bool) {
        // Strip all non-digits
        let digits = input.filter { $0.isNumber }

        // If empty, return empty (valid)
        if digits.isEmpty {
            return ("", true)
        }

        // Pad to 8 digits if needed (HH:MM:SS:FF)
        let padded = String(repeating: "0", count: max(0, 8 - digits.count)) + digits
        let workingDigits = String(padded.suffix(8))

        // Extract components
        guard workingDigits.count == 8 else {
            return (input, false)
        }

        let hours = Int(workingDigits.prefix(2)) ?? 0
        let minutes = Int(workingDigits.dropFirst(2).prefix(2)) ?? 0
        let seconds = Int(workingDigits.dropFirst(4).prefix(2)) ?? 0
        let frames = Int(workingDigits.suffix(2)) ?? 0

        // Validate components
        let maxFrames = Int(frameRate) - 1
        let validHours = hours < 24
        let validMinutes = minutes < 60
        let validSeconds = seconds < 60
        let validFrames = frames <= maxFrames

        let isValid = validHours && validMinutes && validSeconds && validFrames

        // Clamp frames if needed
        let clampedFrames = min(frames, maxFrames)

        // Format as HH:MM:SS:FF
        let formatted = String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, clampedFrames)

        return (formatted, isValid)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: Spacing.lg) {
        TimecodeTextField(
            timecode: .constant("00:00:00:00"),
            frameRate: 24.0,
            label: "Start TC"
        )

        TimecodeTextField(
            timecode: .constant("01:23:45:12"),
            frameRate: 29.97,
            label: "End TC"
        )

        TimecodeTextField(
            timecode: .constant(""),
            frameRate: 24.0,
            label: "Duration"
        )
    }
    .padding()
}
