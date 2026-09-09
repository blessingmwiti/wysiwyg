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
            if !snap.perCore.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(Array(snap.perCore.enumerated()), id: \.offset) { _, v in
                        UsageBar(fraction: v, tint: v > 0.85 ? .red : .blue)
                    }
                }
            }
        }
    }
}
