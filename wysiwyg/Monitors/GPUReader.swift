import Foundation
import IOKit
import Metal

/// GPU utilization from IOKit `IOAccelerator` performance statistics.
/// Public IOKit only — no private frameworks, no sudo. Works for Apple
/// Silicon (AGX), Intel iGPU and AMD dGPUs; VMs without an accelerator
/// report `.unavailable` honestly.
final class GPUReader {
    enum State: Equatable {
        case available(utilization: Double, deviceName: String, temperatureC: Double?)
        case unavailable(reason: String)
    }

    private let fallbackName: String = {
        MTLCreateSystemDefaultDevice()?.name ?? "GPU"
    }()

    func sample() -> State {
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return .unavailable(reason: "IORegistry unavailable")
        }
        defer { IOObjectRelease(iterator) }

        var best: (util: Double, name: String, temp: Double?)?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["PerformanceStatistics"] as? [String: Any] {
                let util = Self.utilization(from: stats)
                let name = (stats["model"] as? String) ?? fallbackName
                var temp: Double?
                if let t = (stats["Temperature(C)"] as? NSNumber)?.intValue, t > 0, t < 130 {
                    temp = Double(t)
                }
                if let u = util {
                    if best == nil || u > best!.util { best = (u, name, temp) }
                } else if best == nil {
                    best = (0, name, temp) // accelerator exists but idle/unknown counter
                }
            }
            service = IOIteratorNext(iterator)
        }

        guard let b = best else {
            return .unavailable(reason: "No GPU counters on this Mac")
        }
        return .available(utilization: min(1, max(0, b.util)), deviceName: b.name, temperatureC: b.temp)
    }

    private static func utilization(from stats: [String: Any]) -> Double? {
        let num = { (k: String) -> Int? in (stats[k] as? NSNumber)?.intValue }
        if let v = num("Device Utilization %") ?? num("GPU Activity(%)") {
            return Double(min(100, max(0, v))) / 100
        }
        let r = num("Renderer Utilization %")
        let t = num("Tiler Utilization %")
        if r != nil || t != nil {
            return Double(min(100, max(0, max(r ?? 0, t ?? 0)))) / 100
        }
        return nil
    }
}
