import SwiftUI

struct SensorsProcessesView: View {
    let sensors: SensorReader.Snapshot
    let processes: [ProcessReader.Proc]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Sensors
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.medium").foregroundStyle(.orange)
                        .font(.system(size: 12, weight: .semibold))
                    Text("Sensors").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Spacer()
                }
                if sensors.isAvailable {
                    FlowChips(readings: sensors.readings)
                } else {
                    Text("Temperature / fan sensors unavailable on this Mac")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))

            // Top processes
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet").foregroundStyle(.pink)
                        .font(.system(size: 12, weight: .semibold))
                    Text("Top processes").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Spacer()
                }
                if processes.isEmpty {
                    Text("Collecting…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(processes) { p in
                        HStack {
                            Text(p.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(Formatters.memory(p.memoryBytes))
                                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                            Text(String(format: "%.1f%%", p.cpu * 100))
                                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct FlowChips: View {
    let readings: [SensorReader.Reading]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
            ForEach(readings) { r in
                HStack(spacing: 4) {
                    Image(systemName: r.kind == .temp ? "thermometer" : "fan")
                        .font(.system(size: 10))
                    Text("\(r.label) \(r.valueText)")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.tertiary.opacity(0.5), in: Capsule())
            }
        }
    }
}
