//
//  OptimizationSuggestionBanner.swift
//  Projector
//
//  Sprint 4: Optimization Discoverability - Smart contextual prompts
//  that suggest optimization when it would help performance.
//
//  Layer: Views
//

import SwiftUI

// MARK: - Suggestion Type

/// Types of optimization suggestions with contextual messaging
enum OptimizationSuggestion: Equatable {
    /// Video is stuttering during playback
    case playbackStutter(filename: String)
    /// Large files are impacting project size
    case largeProjectSize(totalGB: Double, savingsGB: Double)
    /// High-bitrate files detected on import
    case highBitrateImport(count: Int)
    /// ProRes files could be converted to proxies
    case proResDetected(count: Int)

    var title: String {
        switch self {
        case .playbackStutter:
            return "Playback Performance"
        case .largeProjectSize:
            return "Project Size"
        case .highBitrateImport:
            return "Heavy Media Detected"
        case .proResDetected:
            return "ProRes Files Detected"
        }
    }

    var message: String {
        switch self {
        case .playbackStutter(let filename):
            return "'\(filename)' may play smoother after optimization"
        case .largeProjectSize(let total, let savings):
            return String(format: "Your project is %.1f GB. Optimization could save %.1f GB", total, savings)
        case .highBitrateImport(let count):
            return "\(count) high-bitrate file\(count == 1 ? "" : "s") could be optimized for smoother playback"
        case .proResDetected(let count):
            return "\(count) ProRes file\(count == 1 ? "" : "s") can be converted to playback proxies"
        }
    }

    var iconName: String {
        // Use consistent bolt icon for all optimization suggestions
        return "bolt.fill"
    }

    var accentColor: Color {
        // Use consistent green for all optimization suggestions
        return AppColors.accentGreen
    }
}

// MARK: - OptimizationSuggestionBanner

/// A contextual banner that suggests media optimization
///
/// This banner appears when:
/// - Video stutters during playback
/// - Project size exceeds reasonable limits
/// - High-bitrate files are imported
/// - ProRes files are detected that could use proxies
///
/// ## Usage
/// ```swift
/// OptimizationSuggestionBanner(
///     suggestion: .highBitrateImport(count: 3),
///     onOptimize: { showOptimizationSheet = true },
///     onDismiss: { hideSuggestion() }
/// )
/// ```
struct OptimizationSuggestionBanner: View {

    // MARK: - Properties

    let suggestion: OptimizationSuggestion
    let onOptimize: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    // MARK: - Body

    var body: some View {
        HStack(spacing: Spacing.md) {
            // Icon
            Image(systemName: suggestion.iconName)
                .font(.system(size: 20))
                .foregroundColor(suggestion.accentColor)
                .frame(width: 28)

            // Message
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(Typography.label)
                    .foregroundColor(.primary)

                Text(suggestion.message)
                    .font(Typography.captionSmall)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Actions
            HStack(spacing: Spacing.sm) {
                Button("Optimize") {
                    onOptimize()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(suggestion.accentColor)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
            }
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
                .fill(suggestion.accentColor.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
                        .strokeBorder(suggestion.accentColor.opacity(0.3), lineWidth: PanelLayout.borderWidth)
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(AppAnimations.quick, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Compact Variant

/// A more compact version of the suggestion banner for tight spaces
struct OptimizationSuggestionCompact: View {

    let suggestion: OptimizationSuggestion
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: suggestion.iconName)
                    .font(.system(size: 10))

                Text(suggestion.title)
                    .font(Typography.captionSmall)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
            }
            .foregroundColor(suggestion.accentColor)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(suggestion.accentColor.opacity(0.15))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(suggestion.message)
    }
}

// MARK: - Suggestion Manager

/// Manages optimization suggestions across the app
@MainActor
final class OptimizationSuggestionManager: ObservableObject {

    /// Current active suggestion (nil if none)
    @Published var activeSuggestion: OptimizationSuggestion?

    /// Suggestions that have been dismissed in this session
    @Published private(set) var dismissedSuggestions: Set<String> = []

    /// Check media items and potentially show a suggestion
    func evaluateMedia(_ items: [MediaItem]) {
        // Don't suggest if user dismissed similar suggestion
        guard !dismissedSuggestions.contains("highBitrate") else { return }
        guard !dismissedSuggestions.contains("proRes") else { return }

        // Check for ProRes files
        let proResCount = items.filter { item in
            // ProRes typically has very high bitrate (50+ Mbps)
            if let bitrate = item.bitrate, bitrate > 50_000_000 {
                return true
            }
            return false
        }.count

        if proResCount > 0 {
            activeSuggestion = .proResDetected(count: proResCount)
            return
        }

        // Check for high-bitrate files
        let highBitrateCount = items.filter { item in
            if let bitrate = item.bitrate, bitrate > 10_000_000 {
                return true
            }
            return false
        }.count

        if highBitrateCount > 0 {
            activeSuggestion = .highBitrateImport(count: highBitrateCount)
            return
        }
    }

    /// Report playback stutter for a specific file
    func reportPlaybackStutter(filename: String) {
        guard !dismissedSuggestions.contains("stutter") else { return }
        activeSuggestion = .playbackStutter(filename: filename)
    }

    /// Evaluate project size and suggest optimization if needed
    func evaluateProjectSize(totalBytes: UInt64, potentialSavingsBytes: UInt64) {
        guard !dismissedSuggestions.contains("projectSize") else { return }

        let totalGB = Double(totalBytes) / 1_000_000_000
        let savingsGB = Double(potentialSavingsBytes) / 1_000_000_000

        // Suggest if project is > 2GB and we can save > 500MB
        if totalGB > 2.0 && savingsGB > 0.5 {
            activeSuggestion = .largeProjectSize(totalGB: totalGB, savingsGB: savingsGB)
        }
    }

    /// Dismiss the current suggestion
    func dismissCurrent() {
        guard let suggestion = activeSuggestion else { return }

        // Track which type was dismissed
        switch suggestion {
        case .playbackStutter:
            dismissedSuggestions.insert("stutter")
        case .largeProjectSize:
            dismissedSuggestions.insert("projectSize")
        case .highBitrateImport:
            dismissedSuggestions.insert("highBitrate")
        case .proResDetected:
            dismissedSuggestions.insert("proRes")
        }

        activeSuggestion = nil
    }

    /// Clear all dismissed suggestions (e.g., on new project)
    func resetDismissals() {
        dismissedSuggestions.removeAll()
    }
}

// MARK: - Preview

#if DEBUG
struct OptimizationSuggestionBanner_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Spacing.lg) {
            OptimizationSuggestionBanner(
                suggestion: .playbackStutter(filename: "R1_Scene_01.mov"),
                onOptimize: {},
                onDismiss: {}
            )

            OptimizationSuggestionBanner(
                suggestion: .largeProjectSize(totalGB: 12.5, savingsGB: 8.2),
                onOptimize: {},
                onDismiss: {}
            )

            OptimizationSuggestionBanner(
                suggestion: .highBitrateImport(count: 3),
                onOptimize: {},
                onDismiss: {}
            )

            OptimizationSuggestionBanner(
                suggestion: .proResDetected(count: 5),
                onOptimize: {},
                onDismiss: {}
            )

            Divider()

            Text("Compact variants:")
                .font(.caption)

            HStack {
                OptimizationSuggestionCompact(
                    suggestion: .highBitrateImport(count: 2),
                    onTap: {}
                )

                OptimizationSuggestionCompact(
                    suggestion: .proResDetected(count: 1),
                    onTap: {}
                )
            }
        }
        .padding()
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
