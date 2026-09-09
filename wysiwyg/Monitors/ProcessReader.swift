import Foundation
import Darwin

/// Top processes by CPU / memory via libproc. No sudo, no subprocess,
/// Intel + Silicon. CPU% is normalized so 100% = all cores busy.
final class ProcessReader {
    struct Proc: Equatable, Identifiable {
        let pid: Int32
        let name: String
        /// 0...1 of total machine CPU
        let cpu: Double
        let memoryBytes: UInt64
        var id: Int32 { pid }
    }

    private var previousCPUTime: [Int32: UInt64] = [:]
    private var previousAt: Date?

    func sampleTop(limit: Int = 8) -> [Proc] {
        let now = Date()
        let dt: Double? = previousAt.map { now.timeIntervalSince($0) }
        let ncpu = Double(max(1, Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount))

        let pids = listPIDs()
        var procs: [Proc] = []
        procs.reserveCapacity(min(pids.count, 256))
        var curTimes: [Int32: UInt64] = [:]
        curTimes.reserveCapacity(pids.count)

        for pid in pids {
            guard let (comm, cpuTime, rss) = procDetails(pid: pid) else { continue }
            curTimes[pid] = cpuTime
            var cpu = 0.0
            if let dt, dt > 0.05, let prev = previousCPUTime[pid] {
                let delta: UInt64 = cpuTime >= prev ? cpuTime - prev : 0
                // pti times are nanoseconds of CPU time.
                cpu = Double(delta) / (dt * 1_000_000_000 * ncpu)
            }
            procs.append(Proc(pid: pid, name: comm, cpu: min(1, max(0, cpu)), memoryBytes: rss))
        }

        previousCPUTime = curTimes
        previousAt = now

        // First tick has no deltas — rank by memory so the list isn't empty.
        if dt == nil {
            return procs.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(limit).map { $0 }
        }
        return procs.sorted { $0.cpu > $1.cpu }.prefix(limit).map { $0 }
    }

    // MARK: - libproc

    private func listPIDs() -> [Int32] {
        let maxPIDs = 4096
        var buf = [Int32](repeating: 0, count: maxPIDs)
        let bytes = buf.withUnsafeMutableBytes { ptr -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, ptr.baseAddress, Int32(ptr.count))
        }
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<Int32>.size
        return Array(buf.prefix(count)).filter { $0 > 0 }
    }

    private func procDetails(pid: Int32) -> (name: String, cpuTimeNs: UInt64, rss: UInt64)? {
        // Task info (cpu time + resident memory).
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let gotTask: Int32 = withUnsafeMutablePointer(to: &task) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(taskSize)) { raw in
                proc_pidinfo(pid, Int32(PROC_PIDTASKINFO), 0, raw, taskSize)
            }
        }
        guard gotTask == taskSize else { return nil }

        // BSD info (short comm name).
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let gotBsd: Int32 = withUnsafeMutablePointer(to: &bsd) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(bsdSize)) { raw in
                proc_pidinfo(pid, Int32(PROC_PIDTBSDINFO), 0, raw, bsdSize)
            }
        }
        var name = "pid \(pid)"
        if gotBsd == bsdSize {
            let commStr = withUnsafeBytes(of: bsd.pbi_comm) { raw -> String in
                String(bytes: raw.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
            }
            if !commStr.isEmpty { name = commStr }
        }

        let cpuTime = task.pti_total_user + task.pti_total_system
        return (name, cpuTime, UInt64(task.pti_resident_size))
    }
}
