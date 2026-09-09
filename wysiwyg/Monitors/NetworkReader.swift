import Foundation
import Darwin

/// Network throughput via getifaddrs. No sudo, Intel + Silicon.
/// Samples byte counters and diffs them to get per-second up/down.
/// Counter width differs by OS version (32- vs 64-bit), so deltas are
/// computed wrap-aware and never go negative.
final class NetworkReader {
    struct InterfaceStat: Equatable, Identifiable {
        let name: String
        var id: String { name }
        let downRate: Double
        let upRate: Double
        let totalDown: UInt64
        let totalUp: UInt64
        let localIP: String?
    }

    struct Snapshot: Equatable {
        /// Aggregated across non-loopback interfaces, bytes/sec
        let downRate: Double
        let upRate: Double
        let totalDown: UInt64
        let totalUp: UInt64
        let interfaces: [InterfaceStat]
        let primaryLocalIP: String?
    }

    private var previous: [String: (down: UInt64, up: UInt64, at: Date)] = [:]

    func sample() -> Snapshot {
        let now = Date()
        var totals: (down: UInt64, up: UInt64) = (0, 0)
        var current: [String: (down: UInt64, up: UInt64, ip: String?)] = [:]
        let empty = Snapshot(downRate: 0, upRate: 0, totalDown: 0, totalUp: 0, interfaces: [], primaryLocalIP: nil)

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return empty }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let addr = cursor?.pointee.ifa_addr {
            let node = cursor!.pointee
            let next = node.ifa_next
            defer { cursor = next }

            let flags = Int(node.ifa_flags)
            let isUp = (flags & Int(IFF_UP)) != 0 && (flags & Int(IFF_RUNNING)) != 0
            guard isUp, let namePtr = node.ifa_name else { continue }
            let ifName = String(cString: namePtr)
            guard ifName != "lo0" else { continue }
            let family = Int(addr.pointee.sa_family)

            if family == Int(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let len = socklen_t(addr.pointee.sa_len)
                if getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if var e = current[ifName] {
                        if e.ip == nil { e.ip = ip; current[ifName] = e }
                    } else {
                        current[ifName] = (0, 0, ip)
                    }
                }
            }

            if family == Int(AF_LINK), let dataPtr = node.ifa_data {
                let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                let down = UInt64(data.ifi_ibytes)
                let up = UInt64(data.ifi_obytes)
                let prevIP = current[ifName]?.ip
                current[ifName] = (down, up, prevIP)
                totals.down &+= down
                totals.up &+= up
            }
        }

        var downRate = 0.0, upRate = 0.0
        var list: [InterfaceStat] = []
        for (name, cur) in current {
            var dr = 0.0, ur = 0.0
            if let prev = previous[name] {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0.05 {
                    dr = Double(wrapDelta(cur.down, prev.down)) / dt
                    ur = Double(wrapDelta(cur.up, prev.up)) / dt
                }
            }
            downRate += dr; upRate += ur
            list.append(InterfaceStat(name: name, downRate: dr, upRate: ur,
                                     totalDown: cur.down, totalUp: cur.up, localIP: cur.ip))
            previous[name] = (cur.down, cur.up, now)
        }
        list.sort { ($0.downRate + $0.upRate) > ($1.downRate + $1.upRate) }

        let primaryIP = list.first(where: { $0.name.hasPrefix("en") && $0.localIP != nil })?.localIP
            ?? list.first(where: { $0.localIP != nil })?.localIP

        return Snapshot(downRate: downRate, upRate: upRate,
                        totalDown: totals.down, totalUp: totals.up,
                        interfaces: list, primaryLocalIP: primaryIP)
    }

    /// Delta that tolerates 32-bit counter wrap (and interface resets).
    private func wrapDelta(_ cur: UInt64, _ prev: UInt64) -> UInt64 {
        if cur >= prev {
            let d = cur - prev
            // Absurd jump (>10 GB in one tick) means reset, not traffic.
            return d > 10_000_000_000 ? 0 : d
        }
        // Wrapped 32-bit counter?
        if prev <= UInt64(UInt32.max) {
            return (UInt64(UInt32.max) - prev) + cur
        }
        return 0
    }
}
