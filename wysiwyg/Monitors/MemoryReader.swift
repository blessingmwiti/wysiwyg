import Foundation
import Darwin

/// RAM + swap via Mach vm_statistics64. No sudo, Intel + Silicon.
final class MemoryReader {
    struct Snapshot: Equatable {
        let total: UInt64
        let used: UInt64
        let free: UInt64
        let wired: UInt64
        let compressed: UInt64
        let swapTotal: UInt64
        let swapUsed: UInt64
        /// Kernel-reported level when available (nil on failure).
        let kernelPressure: Pressure?
        /// 0...1
        var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
        var pressure: Pressure {
            // Prefer the kernel's own pressure gauge; heuristic as fallback.
            if let kernelPressure { return kernelPressure }
            if usage > 0.85 || (swapTotal > 0 && Double(swapUsed) / Double(swapTotal) > 0.4) { return .critical }
            if usage > 0.65 { return .warn }
            return .normal
        }
    }

    enum Pressure { case normal, warn, critical }

    func sample() -> Snapshot {
        let total = Sysctl.uint64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(max(1, pageSize))

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        var used: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0
        if kr == KERN_SUCCESS {
            let p = Double(page)
            let active = Double(vm.active_count) * p
            let inactive = Double(vm.inactive_count) * p
            let speculative = Double(vm.speculative_count) * p
            wired = UInt64(Double(vm.wire_count) * p)
            compressed = UInt64(Double(vm.compressor_page_count) * p)
            let purgeable = Double(vm.purgeable_count) * p
            // File-backed cache is reclaimable — Activity Monitor doesn't
            // count it as "used", so neither do we.
            let external = Double(vm.external_page_count) * p
            let u = active + inactive + speculative + Double(wired) + Double(compressed) - purgeable - external
            used = UInt64(max(0, u))
            if used > total { used = total }
        }

        let swap = Sysctl.swapUsage() ?? (0, 0)
        return Snapshot(
            total: total, used: used, free: total >= used ? total - used : 0,
            wired: wired, compressed: compressed,
            swapTotal: swap.total, swapUsed: swap.used,
            kernelPressure: Self.kernelPressure()
        )
    }

    /// The kernel's own memory-pressure gauge (2 = warn, 4 = critical).
    private static func kernelPressure() -> Pressure? {
        guard let level = Sysctl.int("kern.memorystatus_vm_pressure_level") else { return nil }
        switch level {
        case 4: return .critical
        case 2: return .warn
        default: return .normal
        }
    }
}
