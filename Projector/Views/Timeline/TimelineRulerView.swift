import SwiftUI
import SwiftTimecodeCore

/// Time ruler with tick marks and time labels
struct TimelineRulerView: View {
    let duration: Double
    let frameRate: TimecodeFrameRate
    let currentTime: Double

    /// Height of the ruler
    private let rulerHeight: CGFloat = TimelineLayout.rulerHeight

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Tick marks and labels
                Canvas { context, size in
                    drawTickMarks(context: context, size: size)
                }
            }
        }
        .frame(height: rulerHeight)
    }

    // MARK: - Drawing

    private func drawTickMarks(context: GraphicsContext, size: CGSize) {
        guard duration > 0 else { return }

        let width = size.width
        let majorInterval = calculateMajorInterval(for: width)
        let minorInterval = majorInterval / 4.0

        // Draw minor ticks first, then major ticks on top
        var time = 0.0
        while time <= duration + 0.001 {
            let x = CGFloat((time / duration) * Double(width))
            let isMajor = isNearMultiple(time, of: majorInterval)

            // Draw tick mark
            let tickHeight: CGFloat = isMajor ? 12 : 6
            let tickColor = isMajor ? Color.secondary.opacity(0.8) : Color.secondary.opacity(0.3)

            let tickPath = Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: tickHeight))
            }
            context.stroke(tickPath, with: .color(tickColor), lineWidth: 1)

            // Draw label for major ticks
            if isMajor {
                let label = formatTime(time)
                let text = Text(label)
                    .font(Typography.monoTiny)
                    .foregroundColor(.secondary)

                // Position label slightly to the right of the tick
                let labelX = x + 3
                if labelX < width - 40 { // Don't draw if too close to edge
                    context.draw(text, at: CGPoint(x: labelX, y: 16), anchor: .leading)
                }
            }

            time += minorInterval
        }
    }

    private func isNearMultiple(_ value: Double, of interval: Double) -> Bool {
        let remainder = value.truncatingRemainder(dividingBy: interval)
        return remainder < 0.01 || abs(remainder - interval) < 0.01
    }

    // MARK: - Calculations

    private func calculateMajorInterval(for width: CGFloat) -> Double {
        guard duration > 0, width > 0 else { return 60.0 }

        // Calculate pixels per second
        let pixelsPerSecond = width / CGFloat(duration)

        // Choose interval based on available space
        // We want major labels roughly every 80-120 pixels
        let targetPixelsPerMajor: CGFloat = TimelineLayout.targetPixelsPerMajor

        let idealInterval = Double(targetPixelsPerMajor / pixelsPerSecond)

        // Snap to nice intervals: 5s, 10s, 15s, 30s, 1m, 2m, 5m, 10m, 15m, 30m
        let niceIntervals: [Double] = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

        for interval in niceIntervals {
            if interval >= idealInterval * 0.8 {
                return interval
            }
        }

        return niceIntervals.last!
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 || duration >= 3600 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

#Preview {
    VStack(spacing: Spacing.xl) {
        // Short duration
        TimelineRulerView(
            duration: 120,
            frameRate: .fps24,
            currentTime: 45
        )
        .background(Color(nsColor: .controlBackgroundColor))

        // Medium duration
        TimelineRulerView(
            duration: 600,
            frameRate: .fps24,
            currentTime: 200
        )
        .background(Color(nsColor: .controlBackgroundColor))

        // Long duration (1 hour)
        TimelineRulerView(
            duration: 3600,
            frameRate: .fps24,
            currentTime: 1234
        )
        .background(Color(nsColor: .controlBackgroundColor))
    }
    .padding()
    .frame(width: 800)
}
