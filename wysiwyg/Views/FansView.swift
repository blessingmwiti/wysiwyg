import SwiftUI

/// Per-fan Auto/Manual helper. Each fan gets its own mode toggle + slider;
/// manual targets are clamped to the firmware [min, max] range and the SMC
/// resets to Auto on sleep/reboot.
struct FansView: View {
    @ObservedObject var controller: FanController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "fan")
                    .foregroundStyle(.cyan)
                    .font(.system(size: 12, weight: .semibold))
                Text("Fans")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if controller.isAvailable {
                    Text("\(controller.fans.count) fan\(controller.fans.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            if !controller.isAvailable || controller.fans.isEmpty {
                Text("No fans on this Mac — fanless model or sensors unavailable.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(controller.fans) { fan in
                    fanRow(fan)
                    if fan.id != controller.fans.last?.id {
                        Divider().opacity(0.5)
                    }
                }
                Text("Manual overrides macOS thermal control and resets to Auto on sleep/reboot. Writes need admin rights — the helper asks once per change, nothing stays resident.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func firmwareSuffix(_ fan: FanController.FanState) -> String {
        guard let m = fan.firmwareMode else { return "" }
        if m == 1 { return " · firmware manual" }
        if m == 0 { return " · firmware auto" }
        return " · firmware mode \(m)"
    }

    private func fanRow(_ fan: FanController.FanState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(fan.label)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(fan.actualRPM.map { String(format: "%.0f rpm", $0) } ?? "—")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Text("range \(Int(fan.minRPM))–\(Int(fan.maxRPM)) rpm" +
                 (fan.targetRPM.map { " · target \(Int($0))" } ?? "") +
                 firmwareSuffix(fan))
                .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()

            Picker("", selection: Binding(
                get: { fan.mode },
                set: { controller.setMode($0, for: fan.index) }
            )) {
                ForEach(FanController.Mode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if fan.mode == .manual {
                HStack(spacing: 8) {
                    Image(systemName: "tortoise").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { fan.manualFraction },
                        set: { controller.setManualFraction($0, for: fan.index) }
                    ), in: 0...1)
                    .tint(.cyan)
                    Image(systemName: "hare").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(String(format: "%.0f", fan.manualRPM))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                HStack(spacing: 12) {
                    Button("Auto") { controller.setMode(.auto, for: fan.index) }
                        .buttonStyle(.link).font(.system(size: 11))
                    Button("Full speed") { controller.setFullSpeed(for: fan.index) }
                        .buttonStyle(.link).font(.system(size: 11))
                    Spacer()
                    Text("\(Int(fan.manualFraction * 100))%")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            if let err = fan.writeError {                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.system(size: 10))
                    Text(err)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if controller.needsAdmin(for: fan) {
                        Button {
                            controller.applyWithAdmin(for: fan.index)
                        } label: {
                            Label("Apply", systemImage: "lock.fill")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("Retry") { controller.retry(for: fan.index) }
                            .buttonStyle(.link).font(.system(size: 10))
                    }
                }
            }
        }
    }
}
