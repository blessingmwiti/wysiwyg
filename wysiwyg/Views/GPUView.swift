import SwiftUI

struct GPUView: View {
    let state: GPUReader.State
    let history: [Double]

    var body: some View {
        switch state {
        case .available(let u, let name, let temp):
            StatCard(icon: "display", tint: .purple, title: "GPU",
                     value: Formatters.percent(u),
                     subtitle: temp.map { "\(name) · \(Int($0))°C" } ?? name) {
                HistoryChart(values: history, tint: .purple)
            }
        case .unavailable(let reason):
            StatCard(icon: "display", tint: .gray, title: "GPU",
                     value: "—", subtitle: reason)
        }
    }
}
