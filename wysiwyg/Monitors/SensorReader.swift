import Foundation
import IOKit

/// Temperature + fan readings via AppleSMC. Read-only, no sudo, no helper.
///
/// What we learned probing real hardware (Apple M5, 2779 SMC keys):
/// - Intel temps are `sp78` (big-endian fixed point); Apple Silicon temps
///   are `flt ` (LITTLE-endian float, e.g. Tp00 = 0x422A8000 = ~42.6°C).
/// - Key names differ per generation (TC0P on Intel, Tp0x/Tg0x/Ts0x on M5),
///   so we discover working keys on first sample and cache them.
/// Nothing answers -> `.isAvailable == false` and the UI says so.
final class SensorReader {
    struct Reading: Equatable, Identifiable {
        let label: String
        var id: String { label }
        let valueText: String
        let kind: Kind
        enum Kind { case temp, fan }
    }

    struct Snapshot: Equatable {
        let readings: [Reading]
        var temps: [Reading] { readings.filter { $0.kind == .temp } }
        var fans: [Reading] { readings.filter { $0.kind == .fan } }
        var isAvailable: Bool { !readings.isEmpty }
    }

    // Candidate keys per category, M5/M1-gen first, Intel fallback.
    private let cpuCandidates = [
        "Tp00", "Tp01", "Tp04", "Tp05", "Tp09", "Tp0C", "Tp0D", "Tp0G", "Tp0H",
        "Tp0L", "Tp0O", "Tp0P", "Tp0R", "Tp0T", "Tp0X", "Tp0a", "Tp0p", "Tp0u",
        "Tp0y", "Tp12", "Tp16", "Tp1E",
        "TC0P", "TC0c", "TC0D", "TC1C", "TC2C", "TCAD", "Tm0P"
    ]
    private let gpuCandidates = [
        "Tg04", "Tg0C", "Tg0G", "Tg0K", "Tg0O", "Tg0R", "Tg0U", "Tg0X", "Tg0d",
        "Tg0g", "Tg0j", "Tg0m", "Tg0p", "Tg12", "Tg16", "Tg1A", "Tg1I", "Tg1M",
        "Tg1Y", "Tg1c", "Tg1g", "Tg1o", "Tg1s",
        "TG0P", "TG0D", "TGDD", "TCGC", "Tg0P"
    ]

    // Discovered on first successful sample; nil = not yet discovered.
    private var cpuKeys: [String]?
    private var gpuKeys: [String]?
    private var fanKeys: [String]?
    private var discoveryDone = false

    func sample() -> Snapshot {
        guard let smc = SMCConnection.open() else { return Snapshot(readings: []) }
        defer { smc.close() }
        var out: [Reading] = []

        if !discoveryDone {
            cpuKeys = smc.discoverTemperatureKeys(from: cpuCandidates, max: 8)
            gpuKeys = smc.discoverTemperatureKeys(from: gpuCandidates, max: 6)
            fanKeys = smc.discoverFanKeys()
            discoveryDone = true
        }

        if let keys = cpuKeys, !keys.isEmpty {
            let temps = keys.compactMap { smc.temperature(forKey: $0) }
            if let max = temps.max() {
                out.append(Reading(label: "CPU", valueText: String(format: "%.0f°C", max), kind: .temp))
            }
        }
        if let keys = gpuKeys, !keys.isEmpty {
            let temps = keys.compactMap { smc.temperature(forKey: $0) }
            if let max = temps.max() {
                out.append(Reading(label: "GPU", valueText: String(format: "%.0f°C", max), kind: .temp))
            }
        }
        for (i, key) in (fanKeys ?? []).prefix(2).enumerated() {
            if let rpm = smc.fanSpeed(forKey: key) {
                let label = (fanKeys?.count ?? 1) == 1 ? "Fan" : "Fan \(i + 1)"
                out.append(Reading(label: label, valueText: String(format: "%.0f rpm", rpm), kind: .fan))
            }
        }
        return Snapshot(readings: out)
    }
}

// MARK: - Minimal read-only SMC client

private final class SMCConnection {
    private var conn: io_connect_t = 0

    static func open() -> SMCConnection? {
        let c = SMCConnection()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &c.conn) == KERN_SUCCESS else { return nil }
        return c
    }

    func close() {
        if conn != 0 { IOServiceClose(conn); conn = 0 }
    }

    /// Any supported temp encoding (Intel sp78, Silicon flt-LE). Nil if absent/garbage.
    func temperature(forKey key: String) -> Double? {
        guard let val = readKey(key), val.dataSize >= 2 else { return nil }
        let b = val.bytes
        let c: Double?
        switch val.dataType {
        case "sp78":
            let raw = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
            c = Double(raw) / 256.0
        case "flt ":
            guard val.dataSize >= 4 else { return nil }
            // Apple Silicon stores flt little-endian.
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            c = Double(Float(bitPattern: bits))
        default:
            return nil
        }
        guard let c, c > -40, c < 130 else { return nil }
        return c
    }

    /// Fan RPM: Silicon `flt `-LE (F0Ac), Intel `fpe2`.
    func fanSpeed(forKey key: String) -> Double? {
        guard let val = readKey(key), val.dataSize >= 2 else { return nil }
        let b = val.bytes
        switch val.dataType {
        case "fpe2":
            let rpm = Double((Int(b[0]) << 6) + (Int(b[1]) >> 2))
            return (rpm >= 0 && rpm < 20000) ? rpm : nil
        case "flt ":
            guard val.dataSize >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let rpm = Double(Float(bitPattern: bits))
            return (rpm >= 0 && rpm < 20000) ? rpm : nil
        default:
            return nil
        }
    }

    func discoverTemperatureKeys(from candidates: [String], max: Int) -> [String] {
        candidates.filter { temperature(forKey: $0) != nil }.prefix(max).map { $0 }
    }

    func discoverFanKeys() -> [String] {
        var keys: [String] = []
        if let n = fanCount(), n > 0 {
            for i in 0..<min(n, 4) {
                let k = String(format: "F%01dAc", i)
                if fanSpeed(forKey: k) != nil { keys.append(k) }
            }
        }
        if keys.isEmpty {
            for k in ["F0Ac", "F1Ac"] where fanSpeed(forKey: k) != nil { keys.append(k) }
        }
        return keys
    }

    private func fanCount() -> Int? {
        guard let val = readKey("FNum"), val.dataSize >= 1 else { return nil }
        switch val.dataType {
        case "ui8 ": return Int(val.bytes[0])
        case "ui16": return Int(UInt16(val.bytes[0]) << 8 | UInt16(val.bytes[1]))
        default: return nil
        }
    }

    // MARK: protocol

    private struct Value {
        var dataSize: UInt32 = 0
        var dataType: String = ""
        var bytes: [UInt8] = Array(repeating: 0, count: 32)
    }

    private func readKey(_ key: String) -> Value? {
        guard key.utf8.count == 4 else { return nil }
        var code: UInt32 = 0
        for b in key.utf8 { code = (code << 8) | UInt32(b) }

        var input = SMCParam(key: code, data8: 9) // READ_KEYINFO
        var output = SMCParam()
        guard call(&input, &output) == KERN_SUCCESS else { return nil }

        var val = Value()
        val.dataSize = output.keyInfoSize
        val.dataType = fourCC(output.keyInfoType)
        guard val.dataSize > 0, val.dataSize <= 32 else { return nil }

        input = SMCParam(key: code, data8: 5, keyInfoSize: output.keyInfoSize) // READ_BYTES
        output = SMCParam()
        guard call(&input, &output) == KERN_SUCCESS else { return nil }
        val.bytes = output.byteArray
        return val
    }

    private func fourCC(_ v: UInt32) -> String {
        String(bytes: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                       UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)], encoding: .ascii) ?? ""
    }

    private func call(_ input: inout SMCParam, _ output: inout SMCParam) -> kern_return_t {
        let inputSize = MemoryLayout<SMCParam>.stride
        var outputSize = MemoryLayout<SMCParam>.stride
        return IOConnectCallStructMethod(conn, 2, &input, inputSize, &output, &outputSize)
    }
}

/// Mirrors smc.h `SMCKeyData_t` (field order + sizes matter; stride = 80).
private struct SMCParam {
    var key: UInt32 = 0
    var versMajor: UInt8 = 0, versMinor: UInt8 = 0, versBuild: UInt8 = 0, versReserved: UInt8 = 0
    var versRelease: UInt16 = 0
    var pLimitVersion: UInt16 = 0, pLimitLength: UInt16 = 0
    var pLimitCPU: UInt32 = 0, pLimitGPU: UInt32 = 0, pLimitMem: UInt32 = 0
    var keyInfoSize: UInt32 = 0
    var keyInfoType: UInt32 = 0
    var keyInfoAttrs: UInt8 = 0
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

    init() {}
    init(key: UInt32, data8: UInt8, keyInfoSize: UInt32 = 0) {
        self.key = key; self.data8 = data8; self.keyInfoSize = keyInfoSize
    }

    var byteArray: [UInt8] {
        withUnsafeBytes(of: bytes) { Array($0) }
    }
}
