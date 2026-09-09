import Foundation

/// Shared formatting helpers for the dashboard.
enum Formatters {
    private static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
        f.countStyle = .memory
        return f
    }()

    private static let fileFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useTB, .useGB, .useMB]
        f.countStyle = .file
        return f
    }()

    static func memory(_ bytes: UInt64) -> String {
        bytesFormatter.string(fromByteCount: Int64(bytes))
    }

    static func disk(_ bytes: UInt64) -> String {
        fileFormatter.string(fromByteCount: Int64(bytes))
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    static func percent1(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    /// Network speed: B/s -> KB/s, MB/s...
    static func speed(_ bytesPerSec: Double) -> String {
        let v = max(0, bytesPerSec)
        switch v {
        case 1_000_000_000...:
            return String(format: "%.2f GB/s", v / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1f MB/s", v / 1_000_000)
        case 1_000...:
            return String(format: "%.0f KB/s", v / 1_000)
        default:
            return String(format: "%.0f B/s", v)
        }
    }

    static func uptime(since bootDate: Date) -> String {
        let secs = max(0, Int(Date().timeIntervalSince(bootDate)))
        let days = secs / 86400
        let hours = (secs % 86400) / 3600
        let mins = (secs % 3600) / 60
        if days > 0 {
            return "\(days)d \(hours)h \(mins)m"
        } else if hours > 0 {
            return "\(hours)h \(mins)m"
        } else {
            return "\(mins)m"
        }
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let c = celsius else { return "—" }
        return String(format: "%.0f°", c)
    }
}

/// Thin sysctl helpers shared by readers. Works on Intel + Apple Silicon.
enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func int(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// Reads vm.swapusage -> (total, used). Layout: total, avail, used (u_int64 x3) + encrypted (int).
    static func swapUsage() -> (total: UInt64, used: UInt64)? {
        var size = MemoryLayout<UInt64>.size * 3 + MemoryLayout<Int32>.size + 4 // padding-safe
        var buf = [UInt8](repeating: 0, count: 64)
        size = buf.count
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            sysctlbyname("vm.swapusage", ptr.baseAddress, &size, nil, 0) == 0
        }
        guard ok, size >= 24 else { return nil }
        let total = buf.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
        let used = buf.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self) }
        return (total, used)
    }
}
