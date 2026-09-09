import SwiftUI

struct MemoryView: View {
    let snap: MemoryReader.Snapshot
    let history: [Double]

    private var tint: Color {
        switch snap.pressure {
        case .normal: return .green
        case .warn: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        StatCard(icon: "memorychip", tint: tint, title: "Memory",
                 value: Formatters.percent(snap.usage),
                 subtitle: "\(Formatters.memory(snap.used)) / \(Formatters.memory(snap.total)) · swap \(Formatters.memory(snap.swapUsed))") {
            HistoryChart(values: history, tint: tint)
        }
    }
}
