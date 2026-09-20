import Foundation

/// Static machine info + uptime. Same code path on Intel and Apple Silicon.
struct SystemInfo: Equatable {
    let model: String
    let chipName: String
    let osVersion: String
    let hostname: String
    let physicalCores: Int
    let logicalCores: Int
    /// Apple Silicon E/P split. Intel: performanceCores == physical, efficiencyCores == 0.
    let performanceCores: Int
    let efficiencyCores: Int
    var hasClusterInfo: Bool { efficiencyCores > 0 && performanceCores > 0 }
    let totalMemory: UInt64
    let bootDate: Date

    static func current() -> SystemInfo {
        let model = Sysctl.string("hw.model") ?? "Mac"
        // Intel exposes brand string; Apple Silicon reports hw.model like Mac15,3.
        let brand = Sysctl.string("machdep.cpu.brand_string")
        let chip: String
        if let brand, !brand.isEmpty, !brand.contains("Unknown") {
            chip = brand
        } else {
            chip = Self.appleSiliconName(model: model)
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let physical = Sysctl.int("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount
        let logical = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        let mem = Sysctl.uint64("hw.memsize") ?? ProcessInfo.processInfo.physicalMemory
        let clusters = Self.cpuClusters(fallbackPhysical: physical)
        return SystemInfo(
            model: model,
            chipName: chip,
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            hostname: ProcessInfo.processInfo.hostName,
            physicalCores: physical,
            logicalCores: logical,
            performanceCores: clusters.performance,
            efficiencyCores: clusters.efficiency,
            totalMemory: mem,
            bootDate: Self.bootDate()
        )
    }

    private static func bootDate() -> Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        let mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        // sysctl with mib needs mutable copy
        var m = mib
        let n = m.count
        let ok = m.withUnsafeMutableBufferPointer { ptr -> Bool in
            sysctl(ptr.baseAddress, UInt32(n), &tv, &size, nil, 0) == 0
        }
        guard ok else { return Date.distantPast }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    private static func appleSiliconName(model: String) -> String {
        // hw.model is like "Mac15,3" — surface it plus Apple Silicon marker.
        // Detailed chip marketing name (M1/M2/...) needs ioreg; keep it honest.
        if model.hasPrefix("Mac") { return "Apple Silicon (\(model))" }
        return model
    }

    /// E/P core split from hw.perflevel*. Uses the level *names* (not the
    /// index) so we don't assume perflevel0 is always Performance.
    /// Returns (performance, efficiency) logical counts; Intel -> (physical, 0).
    static func cpuClusters(fallbackPhysical: Int) -> (performance: Int, efficiency: Int) {
        let nLevels = Sysctl.int("hw.nperflevels") ?? 0
        guard nLevels >= 2 else {
            return (fallbackPhysical, 0)
        }
        var perf = 0, eff = 0
        for level in 0..<nLevels {
            let base = "hw.perflevel\(level)"
            let count = Sysctl.int("\(base).logicalcpu")
                ?? Sysctl.int("\(base).physicalcpu") ?? 0
            let name = (Sysctl.string("\(base).name") ?? "").lowercased()
            if name.contains("efficien") {
                eff += count
            } else if name.contains("perform") || name.contains("super") {
                // "Super" is the performance-tier name on newer chips (M5).
                perf += count
            } else {
                // Unknown label: level 0 has historically been the performance
                // tier on Apple Silicon — treat as performance.
                perf += count
            }
        }
        guard perf + eff > 0 else { return (fallbackPhysical, 0) }
        return (perf, eff)
    }
}
