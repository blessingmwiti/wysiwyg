import Foundation
import IOKit
import Metal

/// GPU utilization from IOKit `IOAccelerator` performance statistics.
/// Public IOKit only — no private frameworks, no sudo. Works for Apple
/// Silicon (AGX), Intel iGPU and AMD dGPUs; VMs without an accelerator
/// report `.unavailable` honestly.
///
/// Multi-GPU Macs (Intel iGPU + AMD dGPU, eGPU) expose one IOAccelerator
/// per device — we return all of them and flag the discrete / fastest one
/// as Performance, the rest as Standard (integrated/efficiency).
final class GPUReader {
    struct Device: Equatable {
        let name: String
        /// 0...1 overall (max of device/renderer/tiler counters)
        let utilization: Double
        /// 0...1 split when the firmware exposes them (Apple Silicon AGX)
        let rendererUtil: Double?
        let tilerUtil: Double?
        let temperatureC: Double?
        /// true = Performance (discrete/fastest), false = Standard/integrated
        let isPerformance: Bool
    }

    enum State: Equatable {
        case available(devices: [Device])
        case unavailable(reason: String)

        /// Highest utilization across devices — drives the sparkline + menu label.
        var bestUtilization: Double? {
            guard case .available(let devices) = self else { return nil }
            return devices.map(\.utilization).max()
        }

        var performanceDevices: [Device] {
            guard case .available(let devices) = self else { return [] }
            return devices.filter(\.isPerformance)
        }

        var standardDevices: [Device] {
            guard case .available(let devices) = self else { return [] }
            return devices.filter { !$0.isPerformance }
        }
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

        struct Raw {
            let name: String
            let util: Double?
            let renderer: Double?
            let tiler: Double?
            let temp: Double?
        }
        var raws: [Raw] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["PerformanceStatistics"] as? [String: Any] {
                let (overall, renderer, tiler) = Self.utilization(from: stats)
                let name = (stats["model"] as? String) ?? fallbackName
                var temp: Double?
                if let t = (stats["Temperature(C)"] as? NSNumber)?.intValue, t > 0, t < 130 {
                    temp = Double(t)
                }
                raws.append(Raw(name: name, util: overall, renderer: renderer, tiler: tiler, temp: temp))
            }
            service = IOIteratorNext(iterator)
        }

        guard !raws.isEmpty else {
            return .unavailable(reason: "No GPU counters on this Mac")
        }

        // Classify: discrete markers win; otherwise the busiest device is Performance.
        let discreteMarkers = ["amd", "radeon", "nvidia", "geforce", "discrete", "external", "egpu"]
        let hasDiscreteHint = raws.contains { r in
            discreteMarkers.contains { r.name.lowercased().contains($0) }
        }
        let maxUtil = raws.compactMap(\.util).max() ?? 0
        let firstMaxIndex = raws.firstIndex(where: { ($0.util ?? 0) >= maxUtil })

        var devices: [Device] = raws.enumerated().map { idx, r in
            let u = min(1, max(0, r.util ?? 0))
            let isPerf: Bool
            if raws.count == 1 {
                isPerf = true
            } else if hasDiscreteHint {
                isPerf = discreteMarkers.contains { r.name.lowercased().contains($0) }
            } else {
                // No naming hint: fastest device is the Performance one.
                // Ties (e.g. all idle at 0) -> first device wins so the UI is stable.
                isPerf = idx == firstMaxIndex
            }
            return Device(name: r.name, utilization: u,
                          rendererUtil: r.renderer, tilerUtil: r.tiler,
                          temperatureC: r.temp, isPerformance: isPerf)
        }
        // Performance first for a stable UI order.
        devices.sort { ($0.isPerformance ? 0 : 1, $0.name) < ($1.isPerformance ? 0 : 1, $1.name) }
        return .available(devices: devices)
    }

    /// Returns (overall, renderer, tiler) as 0...1 fractions.
    private static func utilization(from stats: [String: Any]) -> (Double?, Double?, Double?) {
        let num = { (k: String) -> Int? in (stats[k] as? NSNumber)?.intValue }
        let frac = { (v: Int) -> Double in Double(min(100, max(0, v))) / 100 }
        let renderer = num("Renderer Utilization %").map(frac)
        let tiler = num("Tiler Utilization %").map(frac)
        if let v = num("Device Utilization %") ?? num("GPU Activity(%)") {
            return (frac(v), renderer, tiler)
        }
        if renderer != nil || tiler != nil {
            let overall = max(renderer ?? 0, tiler ?? 0)
            return (overall, renderer, tiler)
        }
        return (nil, renderer, tiler)
    }
}
