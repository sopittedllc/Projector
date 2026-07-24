//
//  SpotMediaSheet.swift
//  Projector
//
//  A composer-focused "Spot Media" dialog for placing media at specific timecodes.
//  Sprint 1: Core composer workflow - the missing "Spot to Timecode" feature.
//
//  Layer: Views
//  Contract: N/A (pure UI component)
//

import SwiftUI
import SwiftTimecodeCore

// MARK: - Spot Placement Option

/// The available options for placing media on the timeline.
enum SpotPlacementOption: String, CaseIterable, Identifiable {
    /// Auto-detected from filename pattern (e.g., R1_01_00_00_00.mov)
    case filename = "filename"
    /// Auto-detected from video metadata (QuickTime track, XMP, etc.)
    case metadata = "metadata"
    /// Manually entered timecode
    case manual = "manual"
    /// Place at current playhead position
    case playhead = "playhead"

    var id: String { rawValue }

    /// User-facing label for this option
    var label: String {
        switch self {
        case .filename: return "From Filename"
        case .metadata: return "From Video Metadata"
        case .manual: return "Manual Entry"
        case .playhead: return "At Playhead"
        }
    }

    /// SF Symbol icon for this option
    var iconName: String {
        switch self {
        case .filename: return "doc.text.fill"
        case .metadata: return "film.stack.fill"
        case .manual: return "keyboard.fill"
        case .playhead: return "play.circle.fill"
        }
    }

    /// Icon color for this option
    var iconColor: Color {
        switch self {
        case .filename: return .orange
        case .metadata: return .blue
        case .manual: return .purple
        case .playhead: return .green
        }
    }
}

// MARK: - Spot Result

/// The result of the spot dialog, containing placement details.
struct SpotResult: Sendable {
    /// The file URL to place
    let url: URL

    /// The selected placement option
    let option: SpotPlacementOption

    /// The target timecode frame count (relative to timeline start)
    let targetFrame: Int

    /// Whether to set this as the timeline start (first video only)
    let setTimelineStart: Bool

    /// Whether the user wants to remember this choice for the session
    let rememberChoice: Bool
}

// MARK: - SpotMediaSheet

/// A composer-focused dialog for placing media at specific timecode positions.
///
/// This sheet appears when a single file is dropped, offering multiple placement options:
/// - Auto-detect from filename (parses patterns like R1_01_00_00_00.mov)
/// - Auto-detect from video metadata (QuickTime track, XMP, etc.)
/// - Manual timecode entry
/// - Place at current playhead position
///
/// ## Usage
/// ```swift
/// .sheet(isPresented: $showSpotSheet) {
///     SpotMediaSheet(
///         url: droppedURL,
///         filenameTimecode: detectedFromFilename,
///         metadataTimecode: embeddedTimecodeResult,
///         playheadTimecode: currentPlayheadTimecode,
///         frameRate: timeline.config.frameRate,
///         startTimecode: timeline.config.startTimecode,
///         showSetTimelineStartOption: isFirstVideo,
///         onSpot: { result in
///             handleSpotResult(result)
///         },
///         onCancel: {
///             // Handle cancellation
///         }
///     )
/// }
/// ```
struct SpotMediaSheet: View {
    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Properties

    /// The file URL to place
    let url: URL

    /// Timecode detected from filename pattern (nil if not detected)
    let filenameTimecode: String?

    /// Timecode detected from video metadata (nil if not detected)
    let metadataTimecode: EmbeddedTimecodeResult?

    /// Current playhead timecode string
    let playheadTimecode: String

    /// Current playhead frame (for quick placement)
    let playheadFrame: Int

    /// The timeline's frame rate
    let frameRate: TimecodeFrameRate

    /// The timeline's start timecode
    let startTimecode: Timecode

    /// Whether to show the "set timeline start" option (first video only)
    let showSetTimelineStartOption: Bool

    /// Callback when user confirms placement
    let onSpot: (SpotResult) -> Void

    /// Callback when user cancels
    let onCancel: () -> Void

    // MARK: - State

    /// Currently selected placement option
    @State private var selectedOption: SpotPlacementOption = .metadata

    /// Manual timecode entry text
    @State private var manualTimecode: String = "01:00:00:00"

    /// Whether to set timeline start to this timecode
    @State private var setTimelineStart: Bool = false

    /// Whether to remember this choice for the session
    @State private var rememberChoice: Bool = false

    /// Error message for invalid manual timecode
    @State private var manualError: String?

    /// Focus state for manual timecode field
    @FocusState private var isManualTCFocused: Bool

    // MARK: - Computed Properties

    /// File duration string (if available)
    private var durationString: String? {
        // This would be passed in from the coordinator
        // For now, return nil - could be enhanced to show duration
        nil
    }

    /// Whether filename timecode is available
    private var hasFilenameTimecode: Bool {
        filenameTimecode != nil
    }

    /// Whether metadata timecode is available
    private var hasMetadataTimecode: Bool {
        metadataTimecode != nil
    }

    /// The best default option based on available data
    private var defaultOption: SpotPlacementOption {
        if hasMetadataTimecode { return .metadata }
        if hasFilenameTimecode { return .filename }
        return .playhead
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerView
                .padding(Spacing.lg)

            Divider()

            // File info
            fileInfoView
                .padding(Spacing.lg)

            Divider()

            // Placement options
            placementOptionsView
                .padding(Spacing.lg)

            Divider()

            // Footer with options and buttons
            footerView
                .padding(Spacing.lg)
        }
        .frame(width: 480)
        .onAppear {
            selectedOption = defaultOption
            manualTimecode = startTimecode.stringValue()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "target")
                .font(.system(size: 24))
                .foregroundColor(.accentColor)

            Text("Spot Media")
                .font(Typography.title)

            Spacer()

            Button(action: { onCancel(); dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(Typography.iconLarge)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close without placing media")
            .accessibilityLabel("Close")
        }
    }

    // MARK: - File Info

    private var fileInfoView: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(url.lastPathComponent)
                .font(Typography.heading)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: Spacing.md) {
                if let duration = durationString {
                    Label(duration, systemImage: "clock")
                        .font(Typography.caption)
                        .foregroundColor(.secondary)
                }

                Label("\(Int(frameRate.fps)) fps", systemImage: "film")
                    .font(Typography.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Placement Options

    private var placementOptionsView: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Place at:")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(spacing: Spacing.xs) {
                // Filename option
                optionRow(
                    option: .filename,
                    timecodeString: filenameTimecode,
                    badge: hasFilenameTimecode ? "detected" : nil,
                    disabled: !hasFilenameTimecode
                )

                // Metadata option
                optionRow(
                    option: .metadata,
                    timecodeString: metadataTimecode?.formattedTimecode,
                    badge: hasMetadataTimecode ? metadataTimecode?.source.rawValue : nil,
                    disabled: !hasMetadataTimecode
                )

                // Manual option
                manualOptionRow

                // Playhead option
                optionRow(
                    option: .playhead,
                    timecodeString: playheadTimecode,
                    badge: nil,
                    disabled: false
                )
            }
        }
    }

    // MARK: - Option Row

    private func optionRow(
        option: SpotPlacementOption,
        timecodeString: String?,
        badge: String?,
        disabled: Bool
    ) -> some View {
        Button(action: { selectedOption = option }) {
            HStack(spacing: Spacing.md) {
                // Radio indicator
                ZStack {
                    Circle()
                        .strokeBorder(selectedOption == option ? Color.accentColor : AppColors.borderMedium, lineWidth: 2)
                        .frame(width: 20, height: 20)

                    if selectedOption == option {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 10, height: 10)
                    }
                }

                // Colored icon
                Image(systemName: option.iconName)
                    .font(.system(size: 16))
                    .foregroundColor(disabled ? .secondary.opacity(0.4) : option.iconColor)
                    .frame(width: 24, height: 24)

                // Label
                Text(option.label)
                    .font(Typography.body)
                    .foregroundColor(disabled ? .secondary.opacity(0.5) : .primary)

                Spacer()

                // Timecode
                if let tc = timecodeString {
                    Text(tc)
                        .font(Typography.mono)
                        .foregroundColor(disabled ? .secondary.opacity(0.4) : .green)
                }

                // Badge (source info)
                if let badgeText = badge {
                    Text(badgeText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, 3)
                        .background(AppColors.surfaceMedium)
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedOption == option ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selectedOption == option ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .animation(AppAnimations.quick, value: selectedOption)
        .accessibilityLabel("\(option.label), \(timecodeString ?? "not available")")
        .accessibilityAddTraits(selectedOption == option ? .isSelected : [])
    }

    // MARK: - Manual Option Row

    private var manualOptionRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Button(action: { selectedOption = .manual }) {
                HStack(spacing: Spacing.md) {
                    // Radio indicator
                    ZStack {
                        Circle()
                            .strokeBorder(selectedOption == .manual ? Color.accentColor : AppColors.borderMedium, lineWidth: 2)
                            .frame(width: 20, height: 20)

                        if selectedOption == .manual {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 10, height: 10)
                        }
                    }

                    // Colored icon
                    Image(systemName: SpotPlacementOption.manual.iconName)
                        .font(.system(size: 16))
                        .foregroundColor(SpotPlacementOption.manual.iconColor)
                        .frame(width: 24, height: 24)

                    // Label
                    Text(SpotPlacementOption.manual.label)
                        .font(Typography.body)
                        .foregroundColor(.primary)

                    Spacer()

                    // Text field
                    TextField("00:00:00:00", text: $manualTimecode)
                        .font(Typography.mono)
                        .textFieldStyle(.plain)
                        .frame(width: 110)
                        .padding(.horizontal, Spacing.sm)
                        .padding(.vertical, Spacing.xs + 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(AppColors.surfaceMedium)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(manualError != nil ? AppColors.error : AppColors.borderLight, lineWidth: 1)
                        )
                        .focused($isManualTCFocused)
                        .onChange(of: manualTimecode) { _, newValue in
                            manualTimecode = formatTimecodeInput(newValue)
                            manualError = nil
                        }
                        .onSubmit {
                            confirmSpot()
                        }
                        .onTapGesture {
                            selectedOption = .manual
                        }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm + 2)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selectedOption == .manual ? Color.accentColor.opacity(0.1) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selectedOption == .manual ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(AppAnimations.quick, value: selectedOption)

            if let error = manualError {
                Text(error)
                    .font(Typography.captionSmall)
                    .foregroundColor(AppColors.error)
                    .padding(.leading, 48)
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: Spacing.md) {
            // Set timeline start checkbox (only for first video)
            if showSetTimelineStartOption {
                Toggle(isOn: $setTimelineStart) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set timeline start to this timecode")
                            .font(Typography.body)
                        Text("The timeline will begin at the selected timecode")
                            .font(Typography.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }

            // Remember choice checkbox
            Toggle(isOn: $rememberChoice) {
                Text("Remember this choice for session")
                    .font(Typography.body)
            }
            .toggleStyle(.checkbox)

            Divider()
                .padding(.vertical, Spacing.xs)

            // Buttons
            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button(action: confirmSpot) {
                    Text("Spot")
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Actions

    private func confirmSpot() {
        // Calculate target frame based on selected option
        let targetFrame: Int

        switch selectedOption {
        case .filename:
            guard let tc = filenameTimecode,
                  let parsed = parseTimecode(tc) else {
                // Should not happen since button is disabled without valid timecode
                return
            }
            let startFrames = startTimecode.frameCount.wholeFrames
            targetFrame = max(0, parsed.frameCount.wholeFrames - startFrames)

        case .metadata:
            guard let result = metadataTimecode else { return }
            let startFrames = startTimecode.frameCount.wholeFrames
            // Convert from source frame rate to timeline frame rate
            let convertedFrames = result.convertedFrames(to: frameRate.fps)
            targetFrame = max(0, convertedFrames - startFrames)

        case .manual:
            guard let parsed = parseTimecode(manualTimecode) else {
                manualError = "Invalid timecode format"
                return
            }
            let startFrames = startTimecode.frameCount.wholeFrames
            targetFrame = max(0, parsed.frameCount.wholeFrames - startFrames)

        case .playhead:
            targetFrame = playheadFrame
        }

        let result = SpotResult(
            url: url,
            option: selectedOption,
            targetFrame: targetFrame,
            setTimelineStart: setTimelineStart,
            rememberChoice: rememberChoice
        )

        onSpot(result)
        dismiss()
    }

    // MARK: - Timecode Helpers

    /// Formats raw input into a timecode string (HH:MM:SS:FF).
    private func formatTimecodeInput(_ input: String) -> String {
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
    private func parseTimecode(_ string: String) -> Timecode? {
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

// MARK: - Filename Timecode Detection

/// Detects timecode from filename patterns commonly used by composers.
///
/// Supported patterns:
/// - `R1_01_00_00_00` (underscore-separated HH_MM_SS_FF)
/// - `R1_01-00-00-00` (dash-separated HH-MM-SS-FF)
/// - `R1_010000_00` (compact HHMMSS_FF)
/// - `01:00:00:00` (colon-separated in filename)
///
/// - Parameter filename: The filename (without path) to parse
/// - Returns: Detected timecode string, or nil if not found
func detectTimecodeFromFilename(_ filename: String) -> String? {
    // Remove extension
    let name = (filename as NSString).deletingPathExtension

    // Pattern 1: Underscore separated (R1_01_00_00_00)
    // Matches: two digits separated by underscores at end of filename
    let underscorePattern = #"(\d{2})[_](\d{2})[_](\d{2})[_](\d{2})\s*$"#
    if let match = name.range(of: underscorePattern, options: .regularExpression) {
        let component = String(name[match])
        let digits = component.filter { $0.isNumber }
        if digits.count == 8 {
            let h = digits.prefix(2)
            let m = digits.dropFirst(2).prefix(2)
            let s = digits.dropFirst(4).prefix(2)
            let f = digits.dropFirst(6).prefix(2)
            return "\(h):\(m):\(s):\(f)"
        }
    }

    // Pattern 2: Dash separated (R1_01-00-00-00)
    let dashPattern = #"(\d{2})[-](\d{2})[-](\d{2})[-](\d{2})\s*$"#
    if let match = name.range(of: dashPattern, options: .regularExpression) {
        let component = String(name[match])
        let digits = component.filter { $0.isNumber }
        if digits.count == 8 {
            let h = digits.prefix(2)
            let m = digits.dropFirst(2).prefix(2)
            let s = digits.dropFirst(4).prefix(2)
            let f = digits.dropFirst(6).prefix(2)
            return "\(h):\(m):\(s):\(f)"
        }
    }

    // Pattern 3: Colon separated in filename (rare but possible)
    let colonPattern = #"(\d{2}):(\d{2}):(\d{2}):(\d{2})"#
    if let match = name.range(of: colonPattern, options: .regularExpression) {
        return String(name[match])
    }

    // Pattern 4: Compact with frame separator (010000_00 or 010000-00)
    let compactPattern = #"(\d{6})[_-](\d{2})\s*$"#
    if let match = name.range(of: compactPattern, options: .regularExpression) {
        let component = String(name[match])
        let digits = component.filter { $0.isNumber }
        if digits.count == 8 {
            let h = digits.prefix(2)
            let m = digits.dropFirst(2).prefix(2)
            let s = digits.dropFirst(4).prefix(2)
            let f = digits.dropFirst(6).prefix(2)
            return "\(h):\(m):\(s):\(f)"
        }
    }

    return nil
}

// MARK: - Preview

#if DEBUG
struct SpotMediaSheet_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            // With all options available
            SpotMediaSheet(
                url: URL(fileURLWithPath: "/Movies/R1_Opening_01_00_00_00.mov"),
                filenameTimecode: "01:00:00:00",
                metadataTimecode: EmbeddedTimecodeResult(
                    timecodeFrames: 86400,
                    formattedTimecode: "01:00:00:00",
                    source: .quickTimeTrack,
                    frameRate: 24.0,
                    isDropFrame: false
                ),
                playheadTimecode: "00:42:16:08",
                playheadFrame: 61000,
                frameRate: .fps23_976,
                startTimecode: Timecode(.components(h: 0, m: 59, s: 55, f: 0), at: .fps23_976, by: .clamping),
                showSetTimelineStartOption: true,
                onSpot: { result in
                    print("Spot result: \(result)")
                },
                onCancel: {
                    print("Cancelled")
                }
            )
        }
        .frame(width: 500, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
