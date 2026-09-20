import Foundation
import IOKit

/// Battery status read straight from the AppleSmartBattery registry entry.
/// No private APIs, no sudo. Desktops (no battery) report isPresent = false.
/// Intel + Silicon.
///
/// Health (Maximum Capacity) follows current macOS Settings behavior
/// (Tahoe 26 / 27 Golden Gate era): it prefers `NominalChargeCapacity` —
/// the stable, smoothed full-charge value Settings shows as
/// "Maximum Capacity" — then falls back to `AppleRawMaxCapacity`
/// (previous-versions behavior), then legacy `MaxCapacity`.
/// `MaxCapacity` alone is normalized to 100 on Apple Silicon and must never
/// be used for health by itself — that's the classic Silicon trap.
final class BatteryReader {
    struct Snapshot: Equatable {
        let isPresent: Bool
        /// 0...1
        let level: Double
        let isCharging: Bool
        let isCharged: Bool
        let timeRemainingMinutes: Int?
        let cycleCount: Int?
        /// maxCapacity / designCapacity, 0...1, nil when unknown
        let health: Double?
        /// Which key produced `health`: nominal (current macOS) vs rawMax
        /// (previous versions) vs legacy MaxCapacity.
        let healthSource: HealthSource
        /// Raw mAh figures behind the percentage (nil when unknown).
        let fullChargeMah: Int?
        let designMah: Int?
        /// macOS wording: Normal / Service Recommended.
        let condition: String?
        let temperatureC: Double?
        let powerSource: String

        enum HealthSource: String, Equatable {
            case nominal = "nominal"
            case rawMax = "raw max"
            case legacy = "legacy"
            case none = "unknown"
        }
    }

    func sample() -> Snapshot {
        let ac = Snapshot(isPresent: false, level: 1, isCharging: false, isCharged: false,
                          timeRemainingMinutes: nil, cycleCount: nil, health: nil,
                          healthSource: .none, fullChargeMah: nil, designMah: nil,
                          condition: nil, temperatureC: nil, powerSource: "AC")
        guard let b = Self.readBattery() else { return ac }

        let level = b.maxCapacity > 0 ? Double(b.currentCapacity) / Double(b.maxCapacity) : 0
        // macOS 27 style: NominalChargeCapacity first, then raw max, then legacy.
        var fullCharge: Int?
        var source = Snapshot.HealthSource.none
        if let n = b.nominalCapacity, n > 0 {
            fullCharge = n; source = .nominal
        } else if let r = b.rawMaxCapacity, r > 0 {
            fullCharge = r; source = .rawMax
        } else if b.maxCapacity > 0, b.maxCapacity <= 100, (b.designCapacity ?? 0) > 1000 {
            // Apple Silicon trap: MaxCapacity is a 0-100 percentage here, not mAh.
            // Without a raw/nominal key we cannot compute health honestly.
            fullCharge = nil; source = .none
        } else if b.maxCapacity > 0 {
            fullCharge = b.maxCapacity; source = .legacy
        }
        var health: Double?
        if let full = fullCharge, let design = b.designCapacity, design > 0 {
            health = min(1, max(0, Double(full) / Double(design)))
        } else {
            source = .none
        }
        let condition: String? = {
            guard b.cycleCount != nil || health != nil else { return nil }
            if b.permanentFailure { return "Service Recommended" }
            if let h = health, h < 0.8 { return "Service Recommended" }
            return "Normal"
        }()
        let src = health == nil ? Snapshot.HealthSource.none : source
        let power = b.externalConnected ? "AC Power" : "Battery Power"
        return Snapshot(
            isPresent: true, level: min(1, max(0, level)),
            isCharging: b.isCharging, isCharged: b.fullyCharged,
            timeRemainingMinutes: b.minutesRemaining,
            cycleCount: b.cycleCount,
            health: health,
            healthSource: src,
            fullChargeMah: fullCharge,
            designMah: b.designCapacity,
            condition: condition,
            temperatureC: b.temperatureC,
            powerSource: power
        )
    }

    // MARK: - Registry

    private struct RawBattery {
        var currentCapacity = 0
        var maxCapacity = 0
        var rawMaxCapacity: Int?
        var nominalCapacity: Int?
        var designCapacity: Int?
        var cycleCount: Int?
        var isCharging = false
        var fullyCharged = false
        var externalConnected = false
        var permanentFailure = false
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
            out.rawMaxCapacity = rawMax
            out.maxCapacity = rawMax
            out.currentCapacity = num("AppleRawCurrentCapacity")?.intValue ?? rawMax
        } else {
            out.currentCapacity = num("CurrentCapacity")?.intValue ?? 0
            out.maxCapacity = num("MaxCapacity")?.intValue ?? 0
        }
        // macOS 27 / Tahoe "Maximum Capacity" source: stable nominal value.
        // On newer Apple Silicon the mAh keys live inside the nested
        // BatteryData dictionary (top level only carries 0-100 percentages),
        // so merge from there when the top level has no raw values.
        let sub = dict["BatteryData"] as? [String: Any]
        let subNum = { (k: String) -> NSNumber? in sub?[k] as? NSNumber }
        if let nominal = num("NominalChargeCapacity")?.intValue, nominal > 0 {
            out.nominalCapacity = nominal
        } else if let nominal = subNum("NominalChargeCapacity")?.intValue, nominal > 0 {
            out.nominalCapacity = nominal
        } else if let rawNominal = (num("AppleRawNominalCapacity") ?? subNum("AppleRawNominalCapacity"))?.intValue,
                  rawNominal > 0 {
            out.nominalCapacity = rawNominal
        }
        if out.rawMaxCapacity == nil {
            if let full = subNum("FullChargeCapacity")?.intValue, full > 0 {
                out.rawMaxCapacity = full
            }
        }
        if out.designCapacity == nil {
            out.designCapacity = subNum("DesignCapacity")?.intValue
        }
        out.cycleCount = num("CycleCount")?.intValue
        out.isCharging = num("IsCharging")?.boolValue ?? false
        out.fullyCharged = num("FullyCharged")?.boolValue ?? false
        out.externalConnected = num("ExternalConnected")?.boolValue ?? false
        out.permanentFailure = (num("PermanentFailureStatus")?.intValue ?? 0) != 0

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
