import Foundation
import IOKit

/// Battery status read straight from the AppleSmartBattery registry entry.
/// No private APIs, no sudo. Desktops (no battery) report isPresent = false.
/// Intel + Silicon.
final class BatteryReader {
    struct Snapshot: Equatable {
        let isPresent: Bool
        /// 0...1
        let level: Double
        let isCharging: Bool
        let isCharged: Bool
        let timeRemainingMinutes: Int?
        let cycleCount: Int?
        /// maxCapacity / designCapacity
        let health: Double?
        let temperatureC: Double?
        let powerSource: String
    }

    func sample() -> Snapshot {
        let ac = Snapshot(isPresent: false, level: 1, isCharging: false, isCharged: false,
                          timeRemainingMinutes: nil, cycleCount: nil, health: nil,
                          temperatureC: nil, powerSource: "AC")
        guard let b = Self.readBattery() else { return ac }

        let level = b.maxCapacity > 0 ? Double(b.currentCapacity) / Double(b.maxCapacity) : 0
        var health: Double?
        if let design = b.designCapacity, design > 0 {
            health = Double(b.maxCapacity) / Double(design)
        }
        let source = b.externalConnected ? "AC Power" : "Battery Power"
        return Snapshot(
            isPresent: true, level: min(1, max(0, level)),
            isCharging: b.isCharging, isCharged: b.fullyCharged,
            timeRemainingMinutes: b.minutesRemaining,
            cycleCount: b.cycleCount,
            health: health,
            temperatureC: b.temperatureC,
            powerSource: source
        )
    }

    // MARK: - Registry

    private struct RawBattery {
        var currentCapacity = 0
        var maxCapacity = 0
        var designCapacity: Int?
        var cycleCount: Int?
        var isCharging = false
        var fullyCharged = false
        var externalConnected = false
        var minutesRemaining: Int?
        var temperatureC: Double?
    }

    private static func readBattery() -> RawBattery? {
        let matching = IOServiceMatching("AppleSmartBattery")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        // No battery installed (desktop Macs) -> treat as absent.
        if let installed = dict["BatteryInstalled"] as? NSNumber, !installed.boolValue { return nil }
        guard dict["CurrentCapacity"] != nil, dict["MaxCapacity"] != nil else { return nil }

        let num = { (k: String) -> NSNumber? in dict[k] as? NSNumber }
        var out = RawBattery()
        // Apple Silicon reports Current/MaxCapacity as percentages (0-100)
        // while DesignCapacity stays raw — so prefer the raw keys when present.
        if let rawMax = num("AppleRawMaxCapacity")?.intValue, rawMax > 0 {
            out.maxCapacity = rawMax
            out.currentCapacity = num("AppleRawCurrentCapacity")?.intValue ?? rawMax
        } else {
            out.currentCapacity = num("CurrentCapacity")?.intValue ?? 0
            out.maxCapacity = num("MaxCapacity")?.intValue ?? 0
        }
        out.designCapacity = num("DesignCapacity")?.intValue
        out.cycleCount = num("CycleCount")?.intValue
        out.isCharging = num("IsCharging")?.boolValue ?? false
        out.fullyCharged = num("FullyCharged")?.boolValue ?? false
        out.externalConnected = num("ExternalConnected")?.boolValue ?? false

        // TimeRemaining is minutes (65535 = unknown/calculating).
        let timeKeys = ["TimeRemaining", "AvgTimeToEmpty", "AvgTimeToFull"]
        for k in timeKeys {
            if let t = num(k)?.intValue, t > 0, t < 65535 {
                out.minutesRemaining = t
                break
            }
        }
        // Temperature is 0.1 Kelvin units (e.g. ~3020 = ~29°C).
        if let t = num("Temperature")?.doubleValue {
            let c = t / 10.0 - 273.15
            if c > -40, c < 100 { out.temperatureC = c }
        }
        return out
    }
}
