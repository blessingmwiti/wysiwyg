import Foundation
import Darwin

/// CPU usage via Mach host_processor_info. No sudo, works on Intel + Silicon.
/// Samples per-CPU tick counters and diffs them every refresh.
final class CPUReader {
    struct Snapshot: Equatable {
        /// 0...1 average across all logical CPUs
        let average: Double
        /// 0...1 per logical CPU
        let perCore: [Double]
        /// 0...1 user / system split of total busy time
        let user: Double
        let system: Double
    }

    private var previous: [[Int]] = []
    private var previousTotals: [UInt64] = []
    private(set) var logicalCount: Int = max(1, Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount)

    func sample() -> Snapshot {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t!
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let cpuInfo = info else {
            return Snapshot(average: 0, perCore: Array(repeating: 0, count: logicalCount), user: 0, system: 0)
        }
        defer {
            // Memory returned by host_processor_info must be released.
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, unsafeBitCast(cpuInfo, to: vm_address_t.self), size)
        }

        let n = Int(cpuCount)
        logicalCount = n
        let states = Int(CPU_STATE_MAX)
        var perCore: [Double] = []
        perCore.reserveCapacity(n)
        var totUser: UInt64 = 0, totSys: UInt64 = 0, totIdle: UInt64 = 0, totNice: UInt64 = 0
        var cur: [[Int]] = []
        cur.reserveCapacity(n)

        for i in 0..<n {
            let base = states * i
            let ticks = [
                Int(cpuInfo[base + Int(CPU_STATE_USER)]),
                Int(cpuInfo[base + Int(CPU_STATE_SYSTEM)]),
                Int(cpuInfo[base + Int(CPU_STATE_IDLE)]),
                Int(cpuInfo[base + Int(CPU_STATE_NICE)])
            ]
            cur.append(ticks)
            totUser &+= UInt64(max(0, ticks[0]))
            totSys &+= UInt64(max(0, ticks[1]))
            totIdle &+= UInt64(max(0, ticks[2]))
            totNice &+= UInt64(max(0, ticks[3]))

            if previous.count == n {
                let p = previous[i]
                let d = ticks.enumerated().map { idx, t in max(0, t - p[idx]) }
                let total = d.reduce(0, +)
                perCore.append(total > 0 ? Double(total - d[2]) / Double(total) : 0)
            } else {
                perCore.append(0)
            }
        }

        var userFrac = 0.0, sysFrac = 0.0
        if previousTotals.count == 4 {
            let du = totUser >= previousTotals[0] ? totUser - previousTotals[0] : 0
            let ds = totSys >= previousTotals[1] ? totSys - previousTotals[1] : 0
            let di = totIdle >= previousTotals[2] ? totIdle - previousTotals[2] : 0
            let dn = totNice >= previousTotals[3] ? totNice - previousTotals[3] : 0
            let total = du + ds + di + dn
            if total > 0 {
                userFrac = Double(du + dn) / Double(total)
                sysFrac = Double(ds) / Double(total)
            }
        }
        previousTotals = [totUser, totSys, totIdle, totNice]
        previous = cur

        let avg = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)
        return Snapshot(average: min(1, max(0, avg)), perCore: perCore, user: userFrac, system: sysFrac)
    }
}
