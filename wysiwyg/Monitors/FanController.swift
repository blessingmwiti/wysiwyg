import Foundation
import Combine
import AppKit

/// Per-fan Auto/Manual helper.
///
/// Reads are unprivileged and always work. Writes need root (enforced
/// per-key by SMC firmware), so there are two write paths:
/// 1. Direct — attempted first; works when privileged or on firmware that
///    allows it. Once one direct write succeeds we keep live-applying.
/// 2. Admin helper — the bundled `fanhelper` CLI in app Resources, run once
///    per user action via a system password prompt (`do shell script ...
///    with administrator privileges`). No daemon, nothing resident.
///
/// While unprivileged, the slider moves freely as a *pending* target and an
/// Apply button commits it through the helper. The SMC resets to Auto on
/// sleep/reboot — manual settings must be re-applied after wake.
@MainActor
final class FanController: ObservableObject {
    enum Mode: String, CaseIterable {
        case auto = "Automatic"
        case manual = "Manual"
    }

    struct FanState: Equatable, Identifiable {
        let index: Int
        var id: Int { index }
        var label: String
        var actualRPM: Double?
        var minRPM: Double
        var maxRPM: Double
        var targetRPM: Double?
        var mode: Mode
        /// What the firmware itself reports (0 auto / 1 manual), if exposed.
        var firmwareMode: Int?
        /// 0...1 slider position when manual (maps to min...max)
        var manualFraction: Double
        /// Last write problem for this fan, if any.
        var writeError: String?

        var manualRPM: Double {
            minRPM + manualFraction * (maxRPM - minRPM)
        }

        var isControllable: Bool { maxRPM > minRPM && maxRPM < 30000 }
    }

    @Published private(set) var fans: [FanState] = []
    @Published private(set) var isAvailable: Bool = false
    /// nil = not yet attempted, true = direct writes work, false = admin needed.
    @Published private(set) var directWriteWorks: Bool?

    private let defaultsPrefix = "wysiwyg.fan."
    static let adminHint = "Direct control is blocked for this app — set your speed, then Apply to run the helper (one system password prompt)."

    init() {
        refresh()
    }

    /// True when this fan has a pending change that needs the admin helper.
    func needsAdmin(for fan: FanState) -> Bool {
        directWriteWorks == false && fan.mode == .manual && fan.isControllable
    }

    var helperURL: URL? {
        Bundle.main.url(forResource: "fanhelper", withExtension: nil)
    }

    // MARK: - Refresh (read-only, safe without privileges)

    func refresh() {
        let infos = FanSMC.readFans()
        guard !infos.isEmpty else {
            if fans.isEmpty { isAvailable = false }
            return
        }
        isAvailable = true
        var next: [FanState] = []
        for info in infos {
            let savedMode = UserDefaults.standard.string(forKey: "\(defaultsPrefix)\(info.index).mode")
                .flatMap(Mode.init(rawValue:))
            let savedFraction = UserDefaults.standard.object(forKey: "\(defaultsPrefix)\(info.index).fraction") as? Double
            let prev = fans.first(where: { $0.index == info.index })
            let mode = prev?.mode ?? savedMode ?? .auto
            let fraction: Double = {
                if let f = prev?.manualFraction { return f }
                if let f = savedFraction { return min(1, max(0, f)) }
                if let actual = info.actual, info.max > info.min {
                    return min(1, max(0, (actual - info.min) / (info.max - info.min)))
                }
                return 0.5
            }()
            let count = infos.count
            next.append(FanState(
                index: info.index,
                label: count == 1 ? "Fan" : "Fan \(info.index + 1)",
                actualRPM: info.actual,
                minRPM: info.min,
                maxRPM: info.max,
                targetRPM: info.target,
                mode: mode,
                firmwareMode: info.mode,
                manualFraction: min(1, max(0, fraction)),
                writeError: prev?.writeError
            ))
        }
        fans = next
    }

    // MARK: - User intent

    func setMode(_ mode: Mode, for index: Int) {
        guard let i = fans.firstIndex(where: { $0.index == index }) else { return }
        fans[i].mode = mode
        fans[i].writeError = nil
        UserDefaults.standard.set(mode.rawValue, forKey: "\(defaultsPrefix)\(index).mode")
        if mode == .manual {
            commitManual(at: i)
        } else {
            commitAuto(at: i)
        }
    }

    func setManualFraction(_ fraction: Double, for index: Int) {
        guard let i = fans.firstIndex(where: { $0.index == index }) else { return }
        fans[i].manualFraction = min(1, max(0, fraction))
        UserDefaults.standard.set(fans[i].manualFraction, forKey: "\(defaultsPrefix)\(index).fraction")
        if directWriteWorks == false {
            // Unprivileged: keep as pending, don't spam failing SMC writes.
            if fans[i].writeError == nil { fans[i].writeError = Self.adminHint }
            return
        }
        fans[i].writeError = nil
        commitManual(at: i)
    }

    func setFullSpeed(for index: Int) {
        guard let i = fans.firstIndex(where: { $0.index == index }) else { return }
        fans[i].manualFraction = 1.0
        UserDefaults.standard.set(1.0, forKey: "\(defaultsPrefix)\(index).fraction")
        if fans[i].mode != .manual {
            setMode(.manual, for: index)
        } else {
            setManualFraction(1.0, for: index)
        }
    }

    func retry(for index: Int) {
        guard let i = fans.firstIndex(where: { $0.index == index }) else { return }
        fans[i].writeError = nil
        if fans[i].mode == .manual { commitManual(at: i) } else { commitAuto(at: i) }
    }

    // MARK: - Direct path (attempt first)

    private func commitManual(at i: Int) {
        let fan = fans[i]
        guard fan.isControllable else {
            fans[i].writeError = "No controllable range reported for this fan."
            return
        }
        if directWriteWorks == false {
            fans[i].writeError = Self.adminHint
            return
        }
        let rpm = max(fan.minRPM, min(fan.maxRPM, fan.manualRPM))
        handleResult(FanSMC.setManualRPM(rpm, fanIndex: fan.index), at: i)
    }

    private func commitAuto(at i: Int) {
        let fan = fans[i]
        if directWriteWorks == false {
            // Auto-restore also needs the helper when unprivileged.
            applyWithAdmin(for: fan.index)
            return
        }
        handleResult(FanSMC.setAuto(fanIndex: fan.index), at: i)
    }

    private func handleResult(_ error: FanWriteError?, at i: Int) {
        if let error {
            switch error {
            case .denied:
                directWriteWorks = false
                fans[i].writeError = error.message
            case .unsupported, .comms:
                fans[i].writeError = error.message
            }
        } else {
            directWriteWorks = true
            fans[i].writeError = nil
        }
        refreshKeepingIntent()
    }

    // MARK: - Admin helper path (one password prompt per user action)

    /// Runs the bundled `fanhelper` CLI as root via a system auth dialog.
    /// Uses the fan's current mode + slider value. The helper's own
    /// OK/ERROR verdict is parsed and shown — never a generic failure.
    func applyWithAdmin(for index: Int) {
        guard let i = fans.firstIndex(where: { $0.index == index }) else { return }
        guard let helper = helperURL else {
            fans[i].writeError = "Helper tool missing from app Resources — reinstall the app."
            return
        }
        let fan = fans[i]
        let args: String
        let expectedRPM: Double?
        if fan.mode == .manual {
            let rpm = max(fan.minRPM, min(fan.maxRPM, fan.manualRPM))
            args = "set \(fan.index) \(Int(rpm.rounded()))"
            expectedRPM = rpm
        } else {
            args = "auto \(fan.index)"
            expectedRPM = nil
        }
        let cmd = "'\(helper.path.replacingOccurrences(of: "'", with: "'\\''") )' \(args)"
        // `|| true` keeps AppleScript from swallowing the helper's own
        // stdout: we parse its OK/ERROR verdict ourselves below.
        let source = "do shell script \(quotedForAppleScript("( \(cmd) ) 2>&1 || true")) with administrator privileges"
        var errInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errInfo)
        guard let result else {
            let msg = (errInfo?[NSAppleScript.errorMessage] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let msg, msg.lowercased().contains("cancel") {
                // User cancelled the prompt — keep pending state quietly.
                fans[i].writeError = "Admin prompt cancelled — no changes made."
            } else if let msg, !msg.isEmpty {
                fans[i].writeError = "Admin prompt failed: \(msg)"
            } else {
                fans[i].writeError = "Admin prompt failed to run."
            }
            return
        }
        directWriteWorks = false
        let output = (result.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if output.contains("OK ") || output.hasPrefix("OK") {
            fans[i].writeError = nil
            refreshKeepingIntent()
            if let expectedRPM {
                scheduleVerify(for: fan.index, expectedRPM: expectedRPM)
            }
        } else {
            // Surface the helper's actual complaint (e.g. firmware rejection).
            let detail = output.isEmpty ? "no output" : output.count > 300 ? String(output.prefix(300)) + "…" : output
            fans[i].writeError = "Helper ran but could not apply it: \(detail)"
            refreshKeepingIntent()
        }
    }

    /// A few seconds after a successful apply, check the setting actually
    /// holds — macOS thermal management can reclaim the fan without telling
    /// us. Reports plainly instead of leaving a silent prompt loop.
    private func scheduleVerify(for index: Int, expectedRPM: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let i = self.fans.firstIndex(where: { $0.index == index }) else { return }
            // Only report if the user hasn't moved on since the apply.
            guard self.fans[i].mode == .manual, self.fans[i].writeError == nil else { return }
            self.refreshKeepingIntent()
            guard let k = self.fans.firstIndex(where: { $0.index == index }) else { return }
            let fan = self.fans[k]
            if let m = fan.firmwareMode, m != 1 {
                self.fans[k].writeError = "macOS thermal manager switched the fan back to automatic — the manual target was overridden. Tap Apply to re-assert it."
            } else if let actual = fan.actualRPM,
                      abs(actual - expectedRPM) > max(400, expectedRPM * 0.2) {
                self.fans[k].writeError = "Target was written but the fan isn't following it (actual \(Int(actual)) vs target \(Int(expectedRPM))). The firmware may be overriding — try Full speed or re-apply."
            }
        }
    }

    private func quotedForAppleScript(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Re-read hardware without clobbering the user's mode/slider/error.
    private func refreshKeepingIntent() {
        let infos = FanSMC.readFans()
        for info in infos {
            guard let i = fans.firstIndex(where: { $0.index == info.index }) else { continue }
            fans[i].actualRPM = info.actual
            fans[i].minRPM = info.min
            fans[i].maxRPM = info.max
            fans[i].targetRPM = info.target
            fans[i].firmwareMode = info.mode
        }
    }
}
