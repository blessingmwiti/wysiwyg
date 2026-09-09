import SwiftUI

struct NetworkView: View {
    let snap: NetworkReader.Snapshot
    let downHistory: [Double]
    let upHistory: [Double]
    let publicIP: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "network").foregroundStyle(.teal)
                    .font(.system(size: 12, weight: .semibold))
                Text("Network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            HStack(spacing: 12) {
                Label(Formatters.speed(snap.downRate), systemImage: "arrow.down")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                Label(Formatters.speed(snap.upRate), systemImage: "arrow.up")
                    .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
            }
            HistoryChart(values: downHistory, tint: .teal)
            VStack(alignment: .leading, spacing: 2) {
                if let ip = snap.primaryLocalIP {
                    Text("local \(ip)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                if let pub = publicIP {
                    Text("public \(pub)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Text("total ↓ \(Formatters.disk(snap.totalDown)) · ↑ \(Formatters.disk(snap.totalUp))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                ForEach(snap.interfaces.prefix(3)) { iface in
                    Text("\(iface.name)  ↓ \(Formatters.speed(iface.downRate))  ↑ \(Formatters.speed(iface.upRate))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}
