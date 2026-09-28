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
                    if sensors.temps.isEmpty && sensors.powers.isEmpty {
                        Text("No temperature or power sensors exposed — fans live in the Fans card below.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        if !sensors.temps.isEmpty {
                            SensorGroup(title: "Temperature", readings: sensors.temps)
                        }
                        if !sensors.powers.isEmpty {
                            SensorGroup(title: "Power", readings: sensors.powers)
                        }
                    }
                } else {
                    Text("Temperature / power sensors unavailable on this Mac")
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

/// One sensor family (Temperature / Power): labeled group with a fixed
/// two-column grid of uniform chips, so rows always come out even — no
/// orphans, no ragged adaptive columns. Values right-align per chip.
private struct SensorGroup: View {
    let title: String
    let readings: [SensorReader.Reading]

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(readings) { r in
                    HStack(spacing: 4) {
                        Image(systemName: r.kind == .temp ? "thermometer" : "bolt")
                            .font(.system(size: 10))
                            .frame(width: 14)
                        Text(r.label)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(r.valueText)
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.tertiary.opacity(0.5), in: Capsule())
                }
            }
        }
    }
}
