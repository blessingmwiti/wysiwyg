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
        /// Cluster split (Apple Silicon). Intel: hasClusters == false, eCount == 0.
        /// perCore ordering assumption: E cores first (low CPU ids), then P cores.
        let eAverage: Double
        let pAverage: Double
        let eCount: Int
        let pCount: Int
        var hasClusters: Bool { eCount > 0 && pCount > 0 }
        /// 0...1 values for the E cluster slice of perCore
        var eCores: [Double] {
            guard hasClusters, perCore.count >= eCount else { return [] }
            return Array(perCore.prefix(eCount))
        }
        /// 0...1 values for the P cluster slice of perCore
        var pCores: [Double] {
            guard hasClusters, perCore.count >= eCount else { return [] }
            return Array(perCore.dropFirst(eCount))
        }
    }

    private var previous: [[Int]] = []
    private var previousTotals: [UInt64] = []
    private(set) var logicalCount: Int = max(1, Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount)
    /// Cached E/P logical counts; refreshed lazily (stable per boot).
    private var cachedECount: Int?
    private var cachedPCount: Int?

    private func clusterCounts(totalLogical: Int) -> (e: Int, p: Int) {
        if let e = cachedECount, let p = cachedPCount { return (e, p) }
        let clusters = SystemInfo.cpuClusters(fallbackPhysical: totalLogical)
        // Sysctl reports logical per level; clamp so e+p == total when sane.
        var e = clusters.efficiency, p = clusters.performance
        if e + p != totalLogical, e + p > 0, totalLogical > 0 {
            if e <= totalLogical, p <= totalLogical {
                // Clamp P to the remainder so prefix(e) + dropFirst(e) covers all cores.
                p = max(0, totalLogical - e)
                if e + p != totalLogical { e = max(0, totalLogical - p) }
            } else {
                e = 0; p = totalLogical
            }
        }
        // No usable split (Intel, VMs) -> single group so the UI falls back
        // to the plain per-thread grid.
        if e == 0 || p == 0 { e = 0; p = totalLogical }
        cachedECount = e; cachedPCount = p
        return (e, p)
    }

    func sample() -> Snapshot {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t!
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let cpuInfo = info else {
            let (e, p) = clusterCounts(totalLogical: logicalCount)
            return Snapshot(average: 0, perCore: Array(repeating: 0, count: logicalCount), user: 0, system: 0,
                            eAverage: 0, pAverage: 0, eCount: e, pCount: p)
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
        let (eCount, pCount) = clusterCounts(totalLogical: n)
        let eAvg: Double = {
            guard eCount > 0, perCore.count >= eCount else { return 0 }
            let slice = perCore.prefix(eCount)
            return slice.reduce(0, +) / Double(max(1, slice.count))
        }()
        let pAvg: Double = {
            guard pCount > 0, perCore.count >= eCount else { return 0 }
            let slice = perCore.dropFirst(eCount)
            guard !slice.isEmpty else { return 0 }
            return slice.reduce(0, +) / Double(slice.count)
        }()
        return Snapshot(average: min(1, max(0, avg)), perCore: perCore, user: userFrac, system: sysFrac,
                        eAverage: min(1, max(0, eAvg)), pAverage: min(1, max(0, pAvg)),
                        eCount: eCount, pCount: pCount)
    }
}
