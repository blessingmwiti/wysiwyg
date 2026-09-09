import SwiftUI
import Charts

/// Minimal sparkline. Uses Swift Charts on macOS 13+.
struct HistoryChart: View {
    let values: [Double]
    let tint: Color
    /// Normalise network-style spikes with a fixed ceiling; nil = 0...max(1, peak).
    var ceiling: Double? = nil

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                LineMark(
                    x: .value("t", i),
                    y: .value("v", v)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                AreaMark(
                    x: .value("t", i),
                    y: .value("v", v)
                )
                .foregroundStyle(tint.opacity(0.18))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(ceiling ?? max(1, values.max() ?? 1)))
        .chartXScale(domain: 0...max(1, 59))
        .frame(height: 34)
    }
}
