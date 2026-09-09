import Foundation
import Combine

/// Polls every reader on one cadence and publishes snapshots + history.
/// Single source of truth for the whole dashboard (one menu-bar popup).
@MainActor
final class SystemMonitor: ObservableObject {
    @Published var cpu = CPUReader.Snapshot(average: 0, perCore: [], user: 0, system: 0)
    @Published var memory = MemoryReader.Snapshot(total: 1, used: 0, free: 1, wired: 0, compressed: 0, swapTotal: 0, swapUsed: 0, kernelPressure: nil)
    @Published var gpu: GPUReader.State = .unavailable(reason: "Starting…")
    @Published var network = NetworkReader.Snapshot(downRate: 0, upRate: 0, totalDown: 0, totalUp: 0, interfaces: [], primaryLocalIP: nil)
    @Published var disk = DiskReader.Snapshot(volumes: [], readRate: nil, writeRate: nil)
    @Published var battery = BatteryReader.Snapshot(isPresent: false, level: 1, isCharging: false, isCharged: false, timeRemainingMinutes: nil, cycleCount: nil, health: nil, temperatureC: nil, powerSource: "AC")
    @Published var sensors = SensorReader.Snapshot(readings: [])
    @Published var topProcesses: [ProcessReader.Proc] = []
    @Published var publicIP: String?
    @Published var update: UpdateChecker.Result = .unknown
    let system = SystemInfo.current()

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    // Rolling history for sparklines (last ~60 ticks).
    @Published var cpuHistory: [Double] = []
    @Published var memHistory: [Double] = []
    @Published var downHistory: [Double] = []
    @Published var upHistory: [Double] = []
    @Published var gpuHistory: [Double] = []

    private let cpuReader = CPUReader()
    private let memReader = MemoryReader()
    private let gpuReader = GPUReader()
    private let netReader = NetworkReader()
    private let diskReader = DiskReader()
    private let batteryReader = BatteryReader()
    private let sensorReader = SensorReader()
    private let procReader = ProcessReader()
    private let updateChecker = UpdateChecker()
    private let skippedUpdateKey = "wysiwyg.skippedUpdate"

    private var timer: Timer?
    private var tick = 0
    private var ipTask: Task<Void, Never>?

    func start() {
        guard timer == nil else { return }
        refresh() // immediate first paint
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        ipTask = Task { await fetchPublicIP() }
        Task { update = await updateChecker.check(currentVersion: appVersion) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        ipTask?.cancel()
    }

    private func refresh() {
        tick += 1
        cpu = cpuReader.sample()
        memory = memReader.sample()
        network = netReader.sample()
        if tick % 2 == 1 { disk = diskReader.sample() }       // 2s
        if tick % 2 == 1 { battery = batteryReader.sample() } // 2s
        gpu = gpuReader.sample()                              // self-diffs internally
        if tick % 3 == 1 { topProcesses = procReader.sampleTop() } // 3s, heavier
        if tick % 5 == 1 { sensors = sensorReader.sample() }  // 5s, SMC is slowish
        if tick % 21600 == 0 { Task { update = await updateChecker.check(currentVersion: appVersion) } } // 6h

        push(&cpuHistory, cpu.average)
        push(&memHistory, memory.usage)
        push(&downHistory, network.downRate)
        push(&upHistory, network.upRate)
        if case .available(let u, _, _) = gpu { push(&gpuHistory, u) }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > 60 { arr.removeFirst(arr.count - 60) }
    }

    /// Banner visibility: available, and the user hasn't hit Later on it.
    func shouldShowUpdate(_ version: String) -> Bool {
        UserDefaults.standard.string(forKey: skippedUpdateKey) != version
    }

    func skipUpdate(_ version: String) {
        UserDefaults.standard.set(version, forKey: skippedUpdateKey)
    }

    private func fetchPublicIP() async {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let ip, !ip.isEmpty, ip.count < 64 { self.publicIP = ip }
        } catch { /* offline — leave nil */ }
    }
}
