import SwiftUI

struct CPUView: View {
    let snap: CPUReader.Snapshot
    let history: [Double]
    let logicalCores: Int

    var body: some View {
        StatCard(icon: "cpu", tint: .blue, title: "CPU",
                 value: Formatters.percent(snap.average),
                 subtitle: "user \(Formatters.percent(snap.user)) · sys \(Formatters.percent(snap.system)) · \(logicalCores) threads") {
            HistoryChart(values: history, tint: .blue)
            if snap.hasClusters {
                // Performance cluster (P cores) — high-throughput cores.
                clusterBlock(
                    title: "Performance",
                    count: snap.pCount,
                    average: snap.pAverage,
                    cores: snap.pCores,
                    tint: .blue
                )
                // Efficiency cluster (E cores) — low-power cores.
                clusterBlock(
                    title: "Efficiency",
                    count: snap.eCount,
                    average: snap.eAverage,
                    cores: snap.eCores,
                    tint: .teal
                )
            } else if !snap.perCore.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(Array(snap.perCore.enumerated()), id: \.offset) { _, v in
                        UsageBar(fraction: v, tint: v > 0.85 ? .red : .blue)
                    }
                }
            }
        }
    }

    private func clusterBlock(title: String, count: Int, average: Double, cores: [Double], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(title) · \(count) cores")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Formatters.percent(average))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if cores.isEmpty {
                Text("collecting…")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { _, v in
                        UsageBar(fraction: v, tint: v > 0.85 ? .red : tint)
                    }
                }
            }
        }
    }
}
