import SwiftUI

/// The single-popup dashboard: everything in one place.
struct ContentView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                CPUView(snap: monitor.cpu, history: monitor.cpuHistory,
                        logicalCores: monitor.system.logicalCores)
                MemoryView(snap: monitor.memory, history: monitor.memHistory)
                GPUView(state: monitor.gpu, history: monitor.gpuHistory)
                NetworkView(snap: monitor.network,
                            downHistory: monitor.downHistory,
                            upHistory: monitor.upHistory,
                            publicIP: monitor.publicIP)
                DiskBatteryView(disk: monitor.disk, battery: monitor.battery)
                SensorsProcessesView(sensors: monitor.sensors, processes: monitor.topProcesses)
                footer
            }
            .padding(12)
        }
        .frame(width: 400, height: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("wysiwyg")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Text("up \(Formatters.uptime(since: monitor.system.bootDate))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text("\(monitor.system.chipName) · \(monitor.system.physicalCores) physical / \(monitor.system.logicalCores) logical · macOS \(monitor.system.osVersion)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack {
            Text(monitor.system.hostname)
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 2)
    }
}
