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
        /// 0...1
        var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
        /// Simple pressure heuristic: usage blended with swap activity.
        var pressure: Pressure {
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

        var used: UInt64 = 0, free: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0
        if kr == KERN_SUCCESS {
            let active = UInt64(vm.active_count) * page
            let inactive = UInt64(vm.inactive_count) * page
            wired = UInt64(vm.wire_count) * page
            compressed = UInt64(vm.compressor_page_count) * page
            let speculative = UInt64(vm.speculative_count) * page
            let purgeable = UInt64(vm.purgeable_count) * page
            free = UInt64(vm.free_count) * page
            // "Used" ≈ active + inactive + wired + compressed (matches Activity Monitor loosely).
            used = active + inactive + wired + compressed
            // Clamp: used + free + speculative can exceed total slightly; normalise.
            if used > total { used = total > free ? total - free : total }
            _ = speculative; _ = purgeable
        } else {
            free = total
        }

        let swap = Sysctl.swapUsage() ?? (0, 0)
        return Snapshot(
            total: total, used: used, free: total >= used ? total - used : 0,
            wired: wired, compressed: compressed,
            swapTotal: swap.total, swapUsed: swap.used
        )
    }
}
