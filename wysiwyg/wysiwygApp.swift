import SwiftUI

/// Single menu-bar icon -> one dashboard popup.
/// Universal binary (arm64 + x86_64) via ARCHS_STANDARD; LSUIElement hides the Dock icon.
@main
struct wysiwygApp: App {
    @StateObject private var monitor: SystemMonitor

    init() {
        let m = SystemMonitor()
        _monitor = StateObject(wrappedValue: m)
        m.start() // tick from launch so the menu-bar label is live
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
                .onAppear { monitor.start() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge")
                Text(menuLabel)
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// Compact live readout: CPU% + net rates. One icon, not seven.
    private var menuLabel: String {
        let cpu = Formatters.percent(monitor.cpu.average)
        // Rates only when something is moving; keeps the bar quiet at idle.
        if monitor.network.downRate < 1_000 && monitor.network.upRate < 1_000 {
            return cpu
        }
        return "\(cpu) ↓\(compact(monitor.network.downRate)) ↑\(compact(monitor.network.upRate))"
    }

    private func compact(_ bytesPerSec: Double) -> String {
        switch bytesPerSec {
        case 1_000_000...: return String(format: "%.1fM", bytesPerSec / 1_000_000)
        case 1_000...: return String(format: "%.0fK", bytesPerSec / 1_000)
        default: return String(format: "%.0f", bytesPerSec)
        }
    }
}
