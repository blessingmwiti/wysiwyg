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

    private var prevBytes: (read: UInt64, written: UInt64, at: Date)?

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
        guard let cur = Self.blockStorageBytes() else { return (nil, nil) }
        defer { prevBytes = (cur.read, cur.written, Date()) }
        guard let prev = prevBytes else { return (0, 0) }
        let dt = Date().timeIntervalSince(prev.at)
        guard dt > 0.05 else { return (0, 0) }
        let r = cur.read >= prev.read ? Double(cur.read - prev.read) / dt : 0
        let w = cur.written >= prev.written ? Double(cur.written - prev.written) / dt : 0
        return (r, w)
    }

    private static func blockStorageBytes() -> (read: UInt64, written: UInt64)? {
        var read: UInt64 = 0, written: UInt64 = 0, found = false
        let matching = IOServiceMatching("IOBlockStorageDriver")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                // Keys per IOBlockStorageDriver.h: "Bytes (Read)" / "Bytes (Write)"
                if let b = stats["Bytes (Read)"] as? NSNumber { read &+= b.uint64Value; found = true }
                if let b = stats["Bytes (Write)"] as? NSNumber { written &+= b.uint64Value; found = true }
            }
            service = IOIteratorNext(iterator)
        }
        return found ? (read, written) : nil
    }
}
