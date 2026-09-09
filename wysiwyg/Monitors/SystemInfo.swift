import Foundation

/// Static machine info + uptime. Same code path on Intel and Apple Silicon.
struct SystemInfo: Equatable {
    let model: String
    let chipName: String
    let osVersion: String
    let hostname: String
    let physicalCores: Int
    let logicalCores: Int
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
        return SystemInfo(
            model: model,
            chipName: chip,
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            hostname: ProcessInfo.processInfo.hostName,
            physicalCores: physical,
            logicalCores: logical,
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
}
