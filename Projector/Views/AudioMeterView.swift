//
//  AudioMeterView.swift
//  Projector
//
//  A compact audio level meter showing real-time RMS levels.
//

import SwiftUI

// MARK: - AudioMeterView

/// A compact stereo audio level meter for real-time monitoring.
///
/// Displays left and right channel levels as horizontal bars with
/// color-coded zones (green for safe, yellow for caution, red for clipping).
///
/// ## Usage
/// ```swift
/// AudioMeterView(
///     leftLevel: playbackEngine.meterLevelLeft,
///     rightLevel: playbackEngine.meterLevelRight,
///     isEnabled: playbackEngine.isMeteringEnabled
/// )
/// ```
struct AudioMeterView: View {

    /// Left channel level (0.0-1.0)
    let leftLevel: Float

    /// Right channel level (0.0-1.0)
    let rightLevel: Float

    /// Whether metering is currently active
    let isEnabled: Bool

    /// Meter bar height
    private let barHeight: CGFloat = 4

    /// Meter width
    private let meterWidth: CGFloat = 80

    /// Spacing between meter bars
    private let barSpacing: CGFloat = 2

    var body: some View {
        HStack(spacing: Spacing.xs) {
            // Channel labels
            VStack(alignment: .trailing, spacing: barSpacing) {
                Text("L")
                    .font(Typography.labelTiny)
                    .foregroundColor(.secondary)
                Text("R")
                    .font(Typography.labelTiny)
                    .foregroundColor(.secondary)
            }

            // Meter bars
            VStack(spacing: barSpacing) {
                MeterBar(level: CGFloat(leftLevel), isEnabled: isEnabled)
                    .frame(width: meterWidth, height: barHeight)

                MeterBar(level: CGFloat(rightLevel), isEnabled: isEnabled)
                    .frame(width: meterWidth, height: barHeight)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(backgroundView)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audio meter")
        .accessibilityValue(isEnabled ? "Left \(Int(leftLevel * 100)) percent, Right \(Int(rightLevel * 100)) percent" : "Disabled")
        .help(isEnabled ? "Audio levels: L=\(Int(leftLevel * 100))% R=\(Int(rightLevel * 100))%" : "Audio metering disabled")
    }

    /// Corner radius for the background
    private let backgroundCornerRadius: CGFloat = 4

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: backgroundCornerRadius)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
}

// MARK: - MeterBar

/// A single horizontal meter bar with color-coded zones.
private struct MeterBar: View {

    /// Level value (0.0-1.0)
    let level: CGFloat

    /// Whether metering is active
    let isEnabled: Bool

    /// Yellow zone threshold (70%)
    private let cautionThreshold: CGFloat = 0.7

    /// Red zone threshold (90%)
    private let clipThreshold: CGFloat = 0.9

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppColors.surfaceLight)

                // Level fill with gradient zones
                if isEnabled {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(meterGradient)
                        .frame(width: geometry.size.width * min(1.0, level))
                        .animation(AppAnimations.linear, value: level)
                }

                // Zone markers (subtle vertical lines)
                HStack(spacing: 0) {
                    Spacer()
                        .frame(width: geometry.size.width * cautionThreshold)
                    Rectangle()
                        .fill(AppColors.borderSubtle)
                        .frame(width: PanelLayout.borderWidth)
                    Spacer()
                        .frame(width: geometry.size.width * (clipThreshold - cautionThreshold) - 1)
                    Rectangle()
                        .fill(AppColors.borderSubtle)
                        .frame(width: PanelLayout.borderWidth)
                    Spacer()
                }
            }
        }
    }

    /// Gradient fill for the meter bar
    private var meterGradient: LinearGradient {
        LinearGradient(
            colors: [
                .green,
                .green,
                .yellow,
                .orange,
                .red
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Compact Variant

/// A minimal single-bar meter for space-constrained layouts.
struct AudioMeterCompact: View {

    /// Combined stereo level (max of L/R)
    let level: Float

    /// Whether metering is active
    let isEnabled: Bool

    /// Compact meter width
    private let compactWidth: CGFloat = 40

    /// Compact meter height
    private let compactHeight: CGFloat = 3

    var body: some View {
        MeterBar(level: CGFloat(level), isEnabled: isEnabled)
            .frame(width: compactWidth, height: compactHeight)
    }
}

// MARK: - Preview

#if DEBUG
struct AudioMeterView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Spacing.xl) {
            Text("Audio Meter Variants")
                .font(.headline)

            // Full meter
            AudioMeterView(
                leftLevel: 0.65,
                rightLevel: 0.45,
                isEnabled: true
            )

            // Near clipping
            AudioMeterView(
                leftLevel: 0.85,
                rightLevel: 0.92,
                isEnabled: true
            )

            // Disabled
            AudioMeterView(
                leftLevel: 0,
                rightLevel: 0,
                isEnabled: false
            )

            // Compact variant
            HStack {
                Text("Compact:")
                AudioMeterCompact(level: 0.6, isEnabled: true)
            }
        }
        .padding()
        .frame(width: 200)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
#endif
