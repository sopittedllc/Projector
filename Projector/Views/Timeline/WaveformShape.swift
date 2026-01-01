import SwiftUI

/// Custom Shape for efficient waveform drawing
struct WaveformShape: Shape {
    let samples: [Float]

    /// Whether to draw mirrored waveform around center line
    var centerLine: Bool = true

    func path(in rect: CGRect) -> Path {
        var path = Path()

        guard !samples.isEmpty else { return path }

        let width = rect.width
        let height = rect.height
        let midY = rect.midY

        // Calculate how many samples to average per pixel
        let samplesPerPixel = max(1, samples.count / Int(width))

        for x in 0..<Int(width) {
            // Get the sample range for this pixel
            let startIndex = (x * samples.count) / Int(width)
            let endIndex = min(startIndex + samplesPerPixel, samples.count)

            guard startIndex < samples.count else { continue }

            // Get the peak value in this range
            var peak: Float = 0
            for i in startIndex..<endIndex {
                peak = max(peak, samples[i])
            }

            // Calculate the height based on the peak
            let amplitude = CGFloat(peak) * (height / 2) * 0.9 // 90% of half-height

            if centerLine {
                // Draw mirrored waveform around center
                path.move(to: CGPoint(x: CGFloat(x), y: midY - amplitude))
                path.addLine(to: CGPoint(x: CGFloat(x), y: midY + amplitude))
            } else {
                // Draw from bottom up
                path.move(to: CGPoint(x: CGFloat(x), y: height))
                path.addLine(to: CGPoint(x: CGFloat(x), y: height - amplitude * 2))
            }
        }

        return path
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        // Centered waveform
        WaveformShape(samples: generatePreviewSamples())
            .stroke(Color.accentColor, lineWidth: 1)
            .frame(height: 60)
            .background(Color.black.opacity(0.1))
            .padding()

        // Bottom-aligned waveform
        WaveformShape(samples: generatePreviewSamples(), centerLine: false)
            .stroke(Color.green, lineWidth: 1)
            .frame(height: 60)
            .background(Color.black.opacity(0.1))
            .padding()
    }
}

private func generatePreviewSamples() -> [Float] {
    // Generate fake audio waveform data for preview
    var samples: [Float] = []
    for i in 0..<500 {
        let t = Float(i) / 500.0
        // Mix of sine waves with varying amplitudes
        let sample = abs(sin(t * 20) * 0.3 + sin(t * 50) * 0.2 + sin(t * 100) * 0.1)
        samples.append(min(1.0, sample + Float.random(in: 0...0.2)))
    }
    return samples
}
