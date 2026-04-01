//
//  SyncStatusIndicator.swift
//  Projector
//
//  A compact indicator showing MIDI sync status and quality.
//

import SwiftUI

// MARK: - SyncStatusIndicator

/// A compact indicator showing MIDI sync status and quality.
///
/// Displays:
/// - Colored dot indicating sync state (gray/yellow/green/orange/red)
/// - Status text (e.g., "Synced", "Locking...", "No MTC")
/// - Lock progress bar during acquisition
/// - Sync duration when locked
///
/// ## Usage
/// ```swift
/// SyncStatusIndicator(viewModel: midiSyncViewModel)
/// ```
struct SyncStatusIndicator: View {

    /// The MIDI sync view model to observe.
    @ObservedObject var viewModel: MIDISyncViewModel

    /// Whether to show the expanded view with progress bar.
    @State private var isExpanded: Bool = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Status dot
            Circle()
                .fill(viewModel.syncStatusColor)
                .frame(width: 8, height: 8)
                .shadow(color: viewModel.syncStatusColor.opacity(0.5), radius: 2)

            // Status text
            Text(statusText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)

            // Drift display (only when synced)
            if viewModel.mtcState == .sync {
                driftView
            }

            // Lock progress during acquisition
            if showLockProgress {
                lockProgressView
            }

            // Sync duration when locked
            if !viewModel.syncDurationString.isEmpty {
                Text(viewModel.syncDurationString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundView)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }

    // MARK: - Subviews

    /// Drift display showing sync quality.
    private var driftView: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 9))
                .foregroundColor(viewModel.driftColor)

            Text(viewModel.driftString)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(viewModel.driftColor)
        }
        .help("Sync drift: \(viewModel.driftString). Green = excellent (<0.5 frames), Yellow = fair (1-2 frames), Red = poor (>2 frames)")
    }

    /// Lock progress bar shown during sync acquisition.
    private var lockProgressView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.gray.opacity(0.3))

                // Progress fill
                RoundedRectangle(cornerRadius: 2)
                    .fill(viewModel.syncStatusColor)
                    .frame(width: geometry.size.width * viewModel.lockProgressPercent)
            }
        }
        .frame(width: 40, height: 4)
    }

    /// Background with subtle styling.
    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Computed Properties

    /// Status text to display.
    private var statusText: String {
        switch viewModel.mtcState {
        case .idle:
            return viewModel.selectedInputName == nil ? "No Input" : "No MTC"
        case .preSync:
            return "Locking"
        case .sync:
            return "Synced"
        case .freewheeling:
            return "Lost"
        case .incompatibleFrameRate:
            return "FPS Err"
        }
    }

    /// Whether to show the lock progress bar.
    private var showLockProgress: Bool {
        viewModel.mtcState == .preSync
    }
}

// MARK: - Compact Variant

/// A minimal version showing just the dot and essential info.
struct SyncStatusDot: View {

    @ObservedObject var viewModel: MIDISyncViewModel

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(viewModel.syncStatusColor)
                .frame(width: 6, height: 6)

            if viewModel.mtcState == .sync {
                Text("MTC")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SyncStatusIndicator_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Spacing.xl) {
            Text("Sync Status Indicator Variants")
                .font(.headline)

            // Note: Previews require a mock ViewModel
            // In real use, pass the actual MIDISyncViewModel
        }
        .padding()
        .frame(width: 300)
    }
}
#endif
