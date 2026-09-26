import Foundation
import IOKit

/// Disk space for all local volumes + best-effort R/W activity via IOKit.
/// Works on Intel + Silicon, no sudo.
final class DiskReader {
    struct Volume: Equatable, Identifiable {
        let name: String
        let path: String
        var id: String { path }
        let total: UInt64
        let free: UInt64
        var used: UInt64 { total >= free ? total - free : 0 }
        var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    struct Snapshot: Equatable {
        let volumes: [Volume]
        /// bytes/sec, nil when IOKit stats unavailable
        let readRate: Double?
        let writeRate: Double?
        var boot: Volume? { volumes.first }
    }

    private var prevByID: [UInt64: (read: UInt64, written: UInt64, at: Date)] = [:]

    func sample() -> Snapshot {
        let volumes = Self.localVolumes()
        let (readRate, writeRate) = ioRates()
        return Snapshot(volumes: volumes, readRate: readRate, writeRate: writeRate)
    }

    // MARK: - Volumes

    private static func localVolumes() -> [Volume] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsLocalKey]
        guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return [bootVolume()]
        }
        var out: [Volume] = []
        for url in urls {
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  (vals.volumeIsLocal ?? true) == true,
                  let total = vals.volumeTotalCapacity,
                  let avail = vals.volumeAvailableCapacity,
                  total > 0
            else { continue }
            out.append(Volume(
                name: vals.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: UInt64(total),
                free: UInt64(max(0, avail))
            ))
        }
        if out.isEmpty { return [bootVolume()] }
        // Boot volume first.
        out.sort {
            if $0.path == "/" { return true }
            if $1.path == "/" { return false }
            return $0.name < $1.name
        }
        return out
    }

    private static func bootVolume() -> Volume {
        var total: UInt64 = 0, free: UInt64 = 0
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
            total = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
            free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        }
        return Volume(name: "Macintosh HD", path: "/", total: total, free: free)
    }

    // MARK: - IO activity (best effort)

    private func ioRates() -> (Double?, Double?) {
        let objs = Self.counterObjects()
        guard !objs.isEmpty else { return (nil, nil) }
        let now = Date()
        var r = 0.0, w = 0.0, havePrev = false
        for o in objs {
            if let p = prevByID[o.id] {
                let dt = now.timeIntervalSince(p.at)
                if dt > 0.05 {
                    // Lifetime counters only move forward; anything else is a
                    // reset (reboot) — and rebooted entry IDs are new keys.
                    if o.read >= p.read { r += Double(o.read - p.read) / dt }
                    if o.written >= p.written { w += Double(o.written - p.written) / dt }
                    havePrev = true
                }
            }
            prevByID[o.id] = (o.read, o.written, now)
        }
        let ids = Set(objs.map(\.id))
        prevByID = prevByID.filter { ids.contains($0.key) }
        return havePrev ? (r, w) : (0, 0)
    }

    /// Whole-disk byte counters, one entry per physical disk.
    ///
    /// Method (same as Stats): for each local volume, resolve its BSD node
    /// (statfs, no extra frameworks), walk up the IORegistry chain, and take
    /// the topmost ancestor with live Statistics. The level holding
    /// "Bytes (Read)"/"Bytes (Write)" varies by stack — classic SATA keeps
    /// them on IOBlockStorageDriver, Apple Silicon APFS keeps them on
    /// AppleAPFSContainerScheme — so we probe the chain instead of assuming.
    /// Volumes sharing a disk (APFS volume group) dedupe by entry ID.
    /// All-zero Statistics (idle virtual drivers) are skipped.
    private static func counterObjects() -> [(id: UInt64, read: UInt64, written: UInt64)] {
        var out: [(id: UInt64, read: UInt64, written: UInt64)] = []
        var seen = Set<UInt64>()
        for volume in localVolumes() {
            guard let bsd = bsdName(for: volume.path) else { continue }
            var svc: io_service_t = 0
            bsd.withCString { ptr in
                svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOBSDNameMatching(kIOMainPortDefault, 0, ptr))
            }
            guard svc != 0 else { continue }
            var chain: [io_service_t] = [svc]
            for _ in 0..<10 {
                var parent: io_registry_entry_t = 0
                guard IORegistryEntryGetParentEntry(chain.last!, kIOServicePlane, &parent) == KERN_SUCCESS,
                      parent != 0 else { break }
                chain.append(parent)
            }
            defer { chain.forEach { IOObjectRelease($0) } }
            // Topmost bearer wins (whole-device aggregate over partitions).
            for service in chain.reversed() {
                guard let st = nonzeroStats(of: service),
                      let id = entryID(of: service),
                      !seen.contains(id) else { continue }
                seen.insert(id)
                out.append((id, st.read, st.written))
                break
            }
        }
        return out
    }

    /// Statistics with actual traffic; nil for missing or all-zero counters.
    private static func nonzeroStats(of service: io_service_t) -> (read: UInt64, written: UInt64)? {
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let stats = dict["Statistics"] as? [String: Any] else { return nil }
        let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
        let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        guard r > 0 || w > 0 else { return nil }
        return (r, w)
    }

    private static func entryID(of service: io_service_t) -> UInt64? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS, id != 0 else { return nil }
        return id
    }

    /// "/dev/disk3s1s1" for a mount path, via statfs (no extra frameworks).
    private static func bsdName(for path: String) -> String? {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return nil }
        let size = MemoryLayout.size(ofValue: st.f_mntfromname)
        let full: String = withUnsafePointer(to: &st.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
        }
        guard full.hasPrefix("/dev/") else { return nil }
        return String(full.dropFirst("/dev/".count))
    }
}
