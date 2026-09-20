import SwiftUI

struct GPUView: View {
    let state: GPUReader.State
    let history: [Double]

    var body: some View {
        switch state {
        case .available(let devices):
            let perf = devices.filter(\.isPerformance)
            let standard = devices.filter { !$0.isPerformance }
            let best = devices.max(by: { $0.utilization < $1.utilization })
            StatCard(icon: "display", tint: .purple, title: "GPU",
                     value: best.map { Formatters.percent($0.utilization) } ?? "—",
                     subtitle: best.map { subtitle(for: $0, multi: devices.count > 1) } ?? "—") {
                HistoryChart(values: history, tint: .purple)
                if !perf.isEmpty {
                    deviceGroup(title: devices.count > 1 ? "Performance" : nil, devices: perf)
                }
                if !standard.isEmpty {
                    deviceGroup(title: "Standard", devices: standard)
                }
            }
        case .unavailable(let reason):
            StatCard(icon: "display", tint: .gray, title: "GPU",
                     value: "—", subtitle: reason)
        }
    }

    private func subtitle(for d: GPUReader.Device, multi: Bool) -> String {
        var s = d.name
        if multi { s += d.isPerformance ? " · perf" : " · std" }
        if let t = d.temperatureC { s += " · \(Int(t))°C" }
        return s
    }

    private func deviceGroup(title: String?, devices: [GPUReader.Device]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(devices.enumerated()), id: \.offset) { _, d in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(d.name)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(Formatters.percent(d.utilization))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    UsageBar(fraction: d.utilization, tint: d.utilization > 0.85 ? .red : .purple)
                    if let r = d.rendererUtil, let t = d.tilerUtil {
                        Text("renderer \(Formatters.percent(r)) · tiler \(Formatters.percent(t))")
                            .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                    } else if let t = d.temperatureC {
                        Text("\(Int(t))°C")
                            .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
            }
        }
    }
}
