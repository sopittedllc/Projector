//
//  OptimizationSuggestionBanner.swift
//  Projector
//
//  Contextual prompt offering optimization when heavy media is detected.
//
//  Layer: Views
//

import SwiftUI

// MARK: - Suggestion Type

/// Types of optimization suggestions with contextual messaging.
///
/// One case per thing the app can actually detect. Two more - playback stutter
/// and project size - were carried here for a suggestion manager that nothing
/// ever used, so no code path could produce them and no banner could show them.
enum OptimizationSuggestion: Equatable {
    /// Heavy files detected - high bitrate, high resolution, or both
    case highBitrateImport(count: Int)
    /// ProRes files could be converted to proxies
    case proResDetected(count: Int)

    var title: String {
        switch self {
        case .highBitrateImport:
            return "Heavy Media Detected"
        case .proResDetected:
            return "ProRes Files Detected"
        }
    }

    var message: String {
        switch self {
        case .highBitrateImport(let count):
            // Deliberately does not name the reason: this case now covers high
            // resolution as well as high bitrate, and a 4K file at a modest
            // bitrate would make "high-bitrate" a false statement.
            return "\(count) file\(count == 1 ? "" : "s") could be optimized for smoother playback"
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
/// This banner appears when the media library holds files that still qualify
/// for optimizing - heavy production codecs, or high bitrate/resolution. Its
/// caller derives it from the library rather than storing it, so it goes away
/// on its own once the work is done.
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
                .font(Typography.iconLarge)
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
                Button("Optimize Media") {
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

// MARK: - Preview

#if DEBUG
struct OptimizationSuggestionBanner_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Spacing.lg) {
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
        }
        .padding()
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
