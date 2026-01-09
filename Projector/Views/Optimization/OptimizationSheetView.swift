//
//  OptimizationSheetView.swift
//  Projector
//
//  Sheet for analyzing and optimizing media files.
//  Shows analysis results, progress, and verification report.
//

import SwiftUI

/// Main optimization sheet view
struct OptimizationSheetView: View {
    @ObservedObject var viewModel: OptimizationViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content based on state
            switch viewModel.state {
            case .idle:
                idleView
            case .analyzing:
                analyzingView
            case .ready:
                readyView
            case .optimizing:
                optimizingView
            case .complete:
                completeView
            case .error(let message):
                errorView(message: message)
            }

            Divider()

            // Footer with actions
            footer
        }
        .frame(width: 600, height: 500)
        .onAppear {
            if viewModel.state == .idle {
                viewModel.analyze()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.headline)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    private var headerTitle: String {
        switch viewModel.state {
        case .idle, .analyzing: return "Analyzing Media..."
        case .ready: return "Optimize Media"
        case .optimizing: return "Optimizing..."
        case .complete: return "Optimization Complete"
        case .error: return "Optimization Error"
        }
    }

    // MARK: - Idle View

    private var idleView: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Preparing...")
                .foregroundColor(.secondary)
                .padding(.top)
            Spacer()
        }
    }

    // MARK: - Analyzing View

    private var analyzingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text("Analyzing media files...")
                .foregroundColor(.secondary)
                .padding(.top)
            Spacer()
        }
    }

    // MARK: - Ready View (Analysis Complete)

    private var readyView: some View {
        VStack(spacing: 0) {
            // File list
            fileListView

            Divider()

            // Summary
            summaryView

            // Options
            optionsView
        }
    }

    private var fileListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Header row
                HStack {
                    Text("File")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Current")
                        .frame(width: 80, alignment: .trailing)
                    Text("Optimized")
                        .frame(width: 80, alignment: .trailing)
                    Text("Savings")
                        .frame(width: 100, alignment: .trailing)
                }
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                // File rows
                ForEach(viewModel.analysisResult.items) { item in
                    FileAnalysisRow(item: item)
                }
            }
        }
        .frame(maxHeight: 200)
    }

    private var summaryView: some View {
        HStack {
            Text("Total:")
                .font(.headline)

            Spacer()

            Text("\(viewModel.totalOriginalSizeFormatted)")
                .foregroundColor(.secondary)

            Image(systemName: "arrow.right")
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            Text("\(viewModel.totalOptimizedSizeFormatted)")
                .foregroundColor(.green)

            Text("(Save \(viewModel.savingsFormatted), \(viewModel.savingsPercentageFormatted))")
                .foregroundColor(.green)
                .fontWeight(.semibold)
        }
        .padding()
    }

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $viewModel.replaceOriginals) {
                VStack(alignment: .leading) {
                    Text("Replace originals")
                    Text("Originals will be moved to \"Originals\" folder if unchecked")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text("Video: H.264 720p ~2Mbps  |  Audio: AAC Stereo 160kbps")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.green)
                Text("Frame rates and sample rates will be preserved")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Optimizing View

    private var optimizingView: some View {
        VStack(spacing: 20) {
            Spacer()

            Text(viewModel.progressText)
                .font(.headline)

            // Current item progress
            VStack(alignment: .leading, spacing: 4) {
                Text("Current file:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ProgressView(value: viewModel.currentItemProgress)
                    .progressViewStyle(.linear)
            }
            .padding(.horizontal, 40)

            // Overall progress
            VStack(alignment: .leading, spacing: 4) {
                Text("Overall progress:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ProgressView(value: viewModel.overallProgress)
                    .progressViewStyle(.linear)
                Text("\(Int(viewModel.overallProgress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Complete View (Verification Report)

    private var completeView: some View {
        VStack(spacing: 0) {
            // Success banner
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text("\(viewModel.result?.optimizedCount ?? 0) files optimized")
                        .font(.headline)
                    if let saved = viewModel.result?.totalSavedBytes, saved > 0 {
                        Text("Saved \(ByteCountFormatter.string(fromByteCount: Int64(saved), countStyle: .file))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding()
            .background(Color.green.opacity(0.1))

            // Verification report
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("VERIFICATION REPORT")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        .padding(.top)

                    if let result = viewModel.result {
                        ForEach(result.successfulItems) { item in
                            VerificationItemRow(item: item)
                        }

                        if !result.failedItems.isEmpty {
                            Divider()
                                .padding(.vertical, 8)

                            Text("FAILED")
                                .font(.caption.bold())
                                .foregroundColor(.red)

                            ForEach(result.failedItems) { item in
                                FailedItemRow(item: item)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }

            // Originals folder info
            if let folder = viewModel.result?.originalsFolder {
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                    Text("Originals saved to: \(folder.lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Optimization Error")
                .font(.headline)

            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Left side info
            if viewModel.state == .ready {
                Text("\(viewModel.itemsNeedingOptimizationCount) files need optimization")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Action buttons
            switch viewModel.state {
            case .idle, .analyzing:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

            case .ready:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Optimize") {
                    viewModel.startOptimization()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canOptimize)

            case .optimizing:
                Button("Cancel") {
                    viewModel.cancel()
                }
                .keyboardShortcut(.cancelAction)

            case .complete, .error:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}

// MARK: - Supporting Views

/// Row showing file analysis result
private struct FileAnalysisRow: View {
    let item: MediaAnalysisItem

    var body: some View {
        HStack {
            // File info
            HStack(spacing: 6) {
                Image(systemName: item.isVideo ? "film" : "waveform")
                    .foregroundColor(item.isVideo ? .blue : .green)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .lineLimit(1)
                    if let codec = item.currentCodec {
                        Text(codec)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Sizes
            Text(formatBytes(item.originalSize))
                .font(.system(.body, design: .monospaced))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(.secondary)

            Text(formatBytes(item.estimatedOptimizedSize))
                .font(.system(.body, design: .monospaced))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(item.needsOptimization ? .primary : .secondary)

            // Savings
            if item.needsOptimization {
                Text("\(formatBytes(item.estimatedSavings)) (\(Int(item.savingsPercentage * 100))%)")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 100, alignment: .trailing)
                    .foregroundColor(.green)
            } else {
                Text("Already optimized")
                    .font(.caption)
                    .frame(width: 100, alignment: .trailing)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.02))
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Row showing verification result for an optimized item
private struct VerificationItemRow: View {
    let item: OptimizedItemResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: item.isVideo ? "film" : "waveform")
                    .foregroundColor(item.isVideo ? .blue : .green)
                Text(item.displayName)
                    .fontWeight(.medium)
            }

            HStack(spacing: 16) {
                if let fps = item.frameRate {
                    Label {
                        Text(String(format: "%.3f fps", fps))
                    } icon: {
                        Image(systemName: "checkmark")
                            .foregroundColor(.green)
                    }
                    .font(.caption)
                }

                if let sr = item.sampleRate {
                    Label {
                        Text("\(Int(sr)) Hz")
                    } icon: {
                        Image(systemName: "checkmark")
                            .foregroundColor(.green)
                    }
                    .font(.caption)
                }

                Spacer()

                Text("\(formatBytes(item.originalSize)) → \(formatBytes(item.optimizedSize))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(6)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Row showing a failed optimization item
private struct FailedItemRow: View {
    let item: OptimizedItemResult

    var body: some View {
        HStack {
            Image(systemName: "xmark.circle")
                .foregroundColor(.red)
            Text(item.displayName)
            Spacer()
            if let error = item.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
