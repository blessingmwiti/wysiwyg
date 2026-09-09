import SwiftUI

struct DiskBatteryView: View {
    let disk: DiskReader.Snapshot
    let battery: BatteryReader.Snapshot

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Disk
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").foregroundStyle(.indigo)
                        .font(.system(size: 12, weight: .semibold))
                    Text("Disk").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Spacer()
                    if let boot = disk.boot {
                        Text(Formatters.percent(boot.usage))
                            .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                }
                if let boot = disk.boot {
                    UsageBar(fraction: boot.usage, tint: boot.usage > 0.9 ? .red : .indigo)
                    Text("\(Formatters.disk(boot.free)) free of \(Formatters.disk(boot.total))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                if let r = disk.readRate, let w = disk.writeRate {
                    Text("↓ \(Formatters.speed(r)) · ↑ \(Formatters.speed(w))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                ForEach(disk.volumes.dropFirst().prefix(2)) { v in
                    Text("\(v.name) \(Formatters.percent(v.usage))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))

            // Battery
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: batteryIcon).foregroundStyle(.green)
                        .font(.system(size: 12, weight: .semibold))
                    Text("Battery").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Spacer()
                    Text(battery.isPresent ? Formatters.percent(battery.level) : "AC")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                }
                if battery.isPresent {
                    UsageBar(fraction: battery.level, tint: battery.level < 0.2 && !battery.isCharging ? .red : .green)
                    Text(batteryLine)
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    if let cycles = battery.cycleCount {
                        Text("\(cycles) cycles" + (battery.health.map { " · \(Int($0 * 100))% health" } ?? ""))
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                } else {
                    Text("No battery — desktop Mac")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var batteryIcon: String {
        guard battery.isPresent else { return "powerplug" }
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.level {
        case 0.875...: return "battery.100percent"
        case 0.625...: return "battery.75percent"
        case 0.375...: return "battery.50percent"
        default: return "battery.25percent"
        }
    }

    private var batteryLine: String {
        if battery.isCharging { return "charging" + timeSuffix }
        if battery.isCharged { return "charged" }
        return "discharging" + timeSuffix
    }

    private var timeSuffix: String {
        guard let m = battery.timeRemainingMinutes else { return "" }
        if m >= 60 { return " · \(m / 60)h \(m % 60)m left" }
        return " · \(m)m left"
    }
}
