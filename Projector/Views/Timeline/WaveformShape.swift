import SwiftUI

/// Custom Shape for efficient waveform drawing
struct WaveformShape: Shape {
    let samples: [Float]

    /// Whether to draw mirrored waveform around center line
    var centerLine: Bool = true

    /// Power curve exponent for dynamics enhancement (0.8 = subtle lift, 1.0 = linear)
    var dynamicsCurve: Float = 0.8

    func path(in rect: CGRect) -> Path {
        var path = Path()

        guard !samples.isEmpty else { return path }

        let width = rect.width
        let height = rect.height
        let midY = rect.midY

        // Find the peak sample value for normalization
        let maxSample = samples.max() ?? 1.0
        let normalizationFactor: Float = maxSample > 0.001 ? 1.0 / maxSample : 1.0

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

            // Normalize the peak to 0-1 range
            let normalizedPeak = min(1.0, peak * normalizationFactor)

            // Apply power curve for dynamics enhancement
            // sqrt-ish curve makes quiet parts more visible while preserving loud peaks
            let enhancedPeak = pow(normalizedPeak, dynamicsCurve)

            // Calculate the height based on the enhanced peak
            let amplitude = CGFloat(enhancedPeak) * (height / 2) * 0.65 // 65% of half-height

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
    VStack(spacing: Spacing.xl) {
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
