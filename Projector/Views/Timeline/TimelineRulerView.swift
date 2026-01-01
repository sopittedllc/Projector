import SwiftUI
import SwiftTimecodeCore

/// Time ruler with tick marks and time labels
struct TimelineRulerView: View {
    let duration: Double
    let frameRate: TimecodeFrameRate
    let currentTime: Double

    /// Height of the ruler
    private let rulerHeight: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Background
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))

                // Tick marks and labels
                tickMarksView(in: geometry)

                // Current time indicator
                currentTimeIndicator(in: geometry)
            }
        }
        .frame(height: rulerHeight)
    }

    // MARK: - Tick Marks

    @ViewBuilder
    private func tickMarksView(in geometry: GeometryProxy) -> some View {
        let width = geometry.size.width
        let interval = calculateTickInterval(for: width)

        ForEach(tickPositions(interval: interval, width: width), id: \.offset) { tick in
            VStack(spacing: 0) {
                // Tick mark
                Rectangle()
                    .fill(Color.secondary.opacity(tick.isMajor ? 0.8 : 0.4))
                    .frame(width: 1, height: tick.isMajor ? 10 : 6)

                // Time label (only for major ticks)
                if tick.isMajor {
                    Text(formatTime(tick.time))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .offset(x: 2)
                }
            }
            .offset(x: tick.offset)
        }
    }

    private func currentTimeIndicator(in geometry: GeometryProxy) -> some View {
        let offset = (currentTime / max(duration, 0.001)) * geometry.size.width

        return Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1, height: rulerHeight)
            .offset(x: CGFloat(offset))
    }

    // MARK: - Calculations

    private struct TickMark: Hashable {
        let time: Double
        let offset: CGFloat
        let isMajor: Bool
    }

    private func calculateTickInterval(for width: CGFloat) -> Double {
        guard duration > 0, width > 0 else { return 1.0 }

        // Target approximately 8-12 major ticks
        let targetMajorTicks = 10.0
        let idealInterval = duration / targetMajorTicks

        // Snap to nice intervals (1s, 2s, 5s, 10s, 30s, 1m, 5m, 10m)
        let niceIntervals: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

        for interval in niceIntervals {
            if interval >= idealInterval {
                return interval
            }
        }

        return max(idealInterval, 1.0)
    }

    private func tickPositions(interval: Double, width: CGFloat) -> [TickMark] {
        guard duration > 0 else { return [] }

        var ticks: [TickMark] = []
        let minorInterval = interval / 4.0

        var time = 0.0
        while time <= duration {
            let offset = (time / duration) * Double(width)
            let isMajor = time.truncatingRemainder(dividingBy: interval) < 0.001 ||
                          abs(time.truncatingRemainder(dividingBy: interval) - interval) < 0.001

            ticks.append(TickMark(
                time: time,
                offset: CGFloat(offset),
                isMajor: isMajor || time == 0
            ))

            time += minorInterval
        }

        return ticks
    }

    private func formatTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else if minutes > 0 {
            return String(format: "%d:%02d", minutes, secs)
        } else {
            return String(format: "%d", secs)
        }
    }
}

#Preview {
    VStack {
        TimelineRulerView(
            duration: 120,
            frameRate: .fps24,
            currentTime: 45
        )

        TimelineRulerView(
            duration: 3600,
            frameRate: .fps24,
            currentTime: 1234
        )
    }
    .padding()
}
