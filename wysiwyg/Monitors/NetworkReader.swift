import Foundation
import Darwin

/// Network throughput via getifaddrs. No sudo, Intel + Silicon.
///
/// macOS keeps NO lifetime byte counters: per-interface counters reset on
/// reboot and on interface flap (sleep/wake, Wi-Fi roam), and the
/// getifaddrs ones are 32-bit, so they also wrap. Like Stats, we therefore
/// keep our own cumulative totals: every tick's per-interface delta is
/// added to lifetime counters persisted in UserDefaults, so they survive
/// restarts and keep counting from install — never reset by us.
///
/// Phantom traffic is the enemy here (a reboot/flap looks like a huge
/// negative jump that naive wrap math turns into phantom GBs). Two guards:
/// 1. `ifi_lastchange`: if the interface went down/up since the last
///    sample, re-baseline silently and count nothing that tick.
/// 2. Absurd-jump cap: a single tick can never exceed 10 GB.
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
        /// Lifetime totals (persisted, since install) — never reset by us.
        let totalDown: UInt64
        let totalUp: UInt64
        let interfaces: [InterfaceStat]
        let primaryLocalIP: String?
    }

    private struct Baseline: Equatable {
        var down: UInt64
        var up: UInt64
        var lastChangeSec: Int
        var lastChangeUsec: Int
        var at: Date
    }

    private var previous: [String: Baseline] = [:]
    private var lifetimeDown: UInt64
    private var lifetimeUp: UInt64
    private let downKey = "wysiwyg.net.totalDown"
    private let upKey = "wysiwyg.net.totalUp"
    /// A single tick can never legitimately exceed this (10 GB ≈ 80 Gbps).
    private let maxTickBytes: UInt64 = 10_000_000_000

    init() {
        lifetimeDown = Self.loadUInt64(key: "wysiwyg.net.totalDown")
        lifetimeUp = Self.loadUInt64(key: "wysiwyg.net.totalUp")
    }

    private static func loadUInt64(key: String) -> UInt64 {
        (UserDefaults.standard.object(forKey: key) as? NSNumber)?.uint64Value ?? 0
    }

    func sample() -> Snapshot {
        let now = Date()
        var current: [String: (down: UInt64, up: UInt64, ip: String?, changeSec: Int, changeUsec: Int)] = [:]
        let empty = Snapshot(downRate: 0, upRate: 0, totalDown: lifetimeDown, totalUp: lifetimeUp, interfaces: [], primaryLocalIP: nil)

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
                        current[ifName] = (0, 0, ip, 0, 0)
                    }
                }
            }

            if family == Int(AF_LINK), let dataPtr = node.ifa_data {
                let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                let down = UInt64(data.ifi_ibytes)
                let up = UInt64(data.ifi_obytes)
                let prevIP = current[ifName]?.ip
                current[ifName] = (down, up, prevIP,
                                   Int(data.ifi_lastchange.tv_sec), Int(data.ifi_lastchange.tv_usec))
            }
        }

        var downRate = 0.0, upRate = 0.0
        var list: [InterfaceStat] = []
        for (name, cur) in current {
            var deltaDown: UInt64 = 0, deltaUp: UInt64 = 0
            var dr = 0.0, ur = 0.0
            if let prev = previous[name],
               prev.lastChangeSec == cur.changeSec, prev.lastChangeUsec == cur.changeUsec {
                // Same uptime epoch: genuine traffic (or a 32-bit wrap).
                deltaDown = cappedDelta(cur.down, prev.down)
                deltaUp = cappedDelta(cur.up, prev.up)
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0.05 {
                    dr = Double(deltaDown) / dt
                    ur = Double(deltaUp) / dt
                }
            }
            // Else: new/flapped/rebooted interface — baseline silently, count nothing.
            lifetimeDown &+= deltaDown
            lifetimeUp &+= deltaUp
            downRate += dr; upRate += ur
            list.append(InterfaceStat(name: name, downRate: dr, upRate: ur,
                                      totalDown: cur.down, totalUp: cur.up, localIP: cur.ip))
            previous[name] = Baseline(down: cur.down, up: cur.up,
                                       lastChangeSec: cur.changeSec, lastChangeUsec: cur.changeUsec,
                                       at: now)
        }
        list.sort { ($0.downRate + $0.upRate) > ($1.downRate + $1.upRate) }

        UserDefaults.standard.set(lifetimeDown, forKey: downKey)
        UserDefaults.standard.set(lifetimeUp, forKey: upKey)

        let primaryIP = list.first(where: { $0.name.hasPrefix("en") && $0.localIP != nil })?.localIP
            ?? list.first(where: { $0.localIP != nil })?.localIP

        return Snapshot(downRate: downRate, upRate: upRate,
                        totalDown: lifetimeDown, totalUp: lifetimeUp,
                        interfaces: list, primaryLocalIP: primaryIP)
    }

    /// Tick delta that tolerates 32-bit counter wrap and kills absurd jumps
    /// (resets the lastchange check missed) instead of counting phantom GBs.
    private func cappedDelta(_ cur: UInt64, _ prev: UInt64) -> UInt64 {
        let d: UInt64
        if cur >= prev {
            d = cur - prev
        } else if prev <= UInt64(UInt32.max) {
            d = (UInt64(UInt32.max) - prev) + cur // genuine 32-bit wrap
        } else {
            return 0
        }
        return d > maxTickBytes ? 0 : d
    }
}
