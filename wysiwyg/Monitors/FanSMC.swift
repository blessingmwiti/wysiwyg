import Foundation
import IOKit

/// Shared SMC access for fan monitoring + control. Compiled into both the
/// app and the bundled `fanhelper` CLI so the two can never disagree on
/// protocol details.
///
/// Key layout (probed live, Apple M5):
/// - `FNum` (ui8): fan count. `F{i}Ac`/`Mn`/`Mx`/`Tg`: actual/min/max/target
///   RPM as `flt` (Apple Silicon) or `fpe2` (Intel).
/// - Mode key casing varies by generation: `F{i}Md` on M1–M4, lowercase
///   `F{i}md` on M5. Value: 0 auto · 1 manual (3 = system/thermalmonitord).
/// - M3+ may need an `Ftst` = 1 diagnostic unlock before the mode write.
/// - Intel fallback: `FS!` force bitmask.
/// Reads work unprivileged; writes require root (enforced per-key by SMC
/// firmware) — hence the bundled helper executed via an admin prompt.
enum FanWriteError: Error, Equatable {
    /// No mode/target keys: fanless Mac or unknown firmware.
    case unsupported(String)
    /// Key exists but the write was rejected — almost always privilege.
    case denied(String)
    /// Could not talk to the SMC at all.
    case comms(String)

    var message: String {
        switch self {
        case .unsupported(let m), .denied(let m), .comms(let m): return m
        }
    }
}

struct FanHWInfo {
    let index: Int
    let actual: Double?
    let min: Double
    let max: Double
    let target: Double?
    /// Firmware mode when a mode key exists: 0 auto, 1 manual (3 system).
    let mode: Int?
}

enum FanSMC {
    static let deniedMessage = "macOS blocked the write — admin privileges are required (use Apply in the app, or run as root)."

    // MARK: reads (unprivileged)

    static func readFans() -> [FanHWInfo] {
        guard let smc = FanSMCConnection.open() else { return [] }
        defer { smc.close() }
        let count = smc.fanCount() ?? 0
        guard count > 0 else {
            var out: [FanHWInfo] = []
            for i in 0..<2 {
                if let info = smc.fanInfo(index: i) { out.append(info) }
            }
            return out
        }
        return (0..<min(count, 4)).compactMap { smc.fanInfo(index: $0) }
    }

    // MARK: writes (need root; pure — safe to call from helper CLI)

    static func setManualRPM(_ rpm: Double, fanIndex: Int) -> FanWriteError? {
        guard let smc = FanSMCConnection.open() else { return .comms("Could not talk to the SMC.") }
        defer { smc.close() }
        guard let info = smc.fanInfo(index: fanIndex) else {
            return .unsupported("No fan \(fanIndex + 1) found on this Mac.")
        }
        guard info.max > info.min, info.max < 30000 else {
            return .unsupported("No controllable range reported for this fan.")
        }
        let clamped = max(info.min, min(info.max, rpm))
        if let mdKey = smc.modeKey(for: fanIndex) {
            if !smc.writeUInt8(mdKey, value: 1) {
                // M3+ thermal-manager lock: try the Ftst unlock once, then retry.
                _ = smc.writeUInt8("Ftst", value: 1)
                if !smc.writeUInt8(mdKey, value: 1) { return .denied(deniedMessage) }
            }
            if let tgKey = smc.targetKey(for: fanIndex), smc.writeFanRPM(tgKey, rpm: clamped) {
                return nil
            }
            return .denied(deniedMessage)
        }
        if smc.keyExists("FS! ") || smc.keyExists("FS!") {
            smc.setForceBit(fanIndex, forced: true)
            if let tgKey = smc.targetKey(for: fanIndex), smc.keyExists(tgKey),
               smc.writeFanRPM(tgKey, rpm: clamped) { return nil }
            let mnKey = String(format: "F%01dMn", fanIndex)
            if smc.writeFanRPM(mnKey, rpm: clamped) { return nil }
            return .denied(deniedMessage)
        }
        return .unsupported("Manual fan control is not supported on this Mac.")
    }

    static func setAuto(fanIndex: Int) -> FanWriteError? {
        guard let smc = FanSMCConnection.open() else { return .comms("Could not talk to the SMC.") }
        defer { smc.close() }
        if let mdKey = smc.modeKey(for: fanIndex) {
            if smc.writeUInt8(mdKey, value: 0) { return nil }
            return .denied(deniedMessage)
        }
        if smc.keyExists("FS! ") || smc.keyExists("FS!") {
            smc.setForceBit(fanIndex, forced: false)
            return nil
        }
        return .unsupported("Automatic fan control is not supported on this Mac.")
    }
}

// MARK: - Minimal SMC client (read + fan writes)

final class FanSMCConnection {
    private var conn: io_connect_t = 0

    static func open() -> FanSMCConnection? {
        let c = FanSMCConnection()
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

    func keyExists(_ key: String) -> Bool {
        readKey(key) != nil
    }

    /// Mode key for a fan, probing M1–M4 casing first, then M5 lowercase.
    func modeKey(for index: Int) -> String? {
        let upper = String(format: "F%01dMd", index)
        if keyExists(upper) { return upper }
        let lower = String(format: "F%01dmd", index)
        if keyExists(lower) { return lower }
        return nil
    }

    /// Target-RPM key for a fan (uppercase on all probed hardware; lowercase fallback).
    func targetKey(for index: Int) -> String? {
        let upper = String(format: "F%01dTg", index)
        if keyExists(upper) { return upper }
        let lower = String(format: "F%01dtg", index)
        if keyExists(lower) { return lower }
        return nil
    }

    func fanCount() -> Int? {
        guard let val = readKey("FNum"), val.dataSize >= 1 else { return nil }
        switch val.dataType {
        case "ui8 ": return Int(val.bytes[0])
        case "ui16": return Int(UInt16(val.bytes[0]) << 8 | UInt16(val.bytes[1]))
        default: return nil
        }
    }

    func fanInfo(index: Int) -> FanHWInfo? {
        let ac = String(format: "F%01dAc", index)
        let mn = String(format: "F%01dMn", index)
        let mx = String(format: "F%01dMx", index)
        let actual = fanRPM(forKey: ac)
        let min = fanRPM(forKey: mn)
        let max = fanRPM(forKey: mx)
        guard let actual else { return nil }
        let target = targetKey(for: index).flatMap { fanRPM(forKey: $0) }
        return FanHWInfo(index: index,
                         actual: actual,
                         min: min ?? 1000,
                         max: max ?? 6000,
                         target: target,
                         mode: modeValue(for: index))
    }

    /// Current firmware mode for a fan (0 auto / 1 manual), nil when the
    /// firmware exposes no mode key.
    func modeValue(for index: Int) -> Int? {
        guard let key = modeKey(for: index),
              let val = readKey(key), val.dataSize >= 1 else { return nil }
        if val.dataSize == 1 { return Int(val.bytes[0]) }
        var v = 0
        for i in 0..<Int(val.dataSize) { v = (v << 8) | Int(val.bytes[i]) }
        return v
    }

    func fanRPM(forKey key: String) -> Double? {
        guard let val = readKey(key), val.dataSize >= 2 else { return nil }
        let b = val.bytes
        switch val.dataType {
        case "fpe2":
            let rpm = Double((Int(b[0]) << 6) + (Int(b[1]) >> 2))
            return (rpm >= 0 && rpm < 30000) ? rpm : nil
        case "flt ":
            guard val.dataSize >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let rpm = Double(Float(bitPattern: bits))
            return (rpm >= 0 && rpm < 30000) ? rpm : nil
        default:
            return nil
        }
    }

    @discardableResult
    func writeFanRPM(_ key: String, rpm: Double) -> Bool {
        guard let info = readKey(key) else { return false }
        switch info.dataType {
        case "flt ":
            let bits = Float(rpm).bitPattern
            let bytes: [UInt8] = [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                                  UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
            return writeKey(key, size: info.dataSize, bytes: bytes)
        case "fpe2":
            let v = max(0, min(0x3FFF, Int(rpm)))
            let raw = UInt16(v << 2)
            let bytes: [UInt8] = [UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
            return writeKey(key, size: info.dataSize, bytes: bytes)
        default:
            return false
        }
    }

    @discardableResult
    func writeUInt8(_ key: String, value: UInt8) -> Bool {
        guard let info = readKey(key) else { return false }
        var bytes = [value]
        if info.dataSize > 1 {
            bytes += Array(repeating: 0, count: Int(info.dataSize) - 1)
        }
        return writeKey(key, size: info.dataSize, bytes: bytes)
    }

    /// Intel FS! force bitmask (big-endian integer). Sets/clears bit `index`.
    func setForceBit(_ index: Int, forced: Bool) {
        let key = keyExists("FS! ") ? "FS! " : "FS!"
        guard let info = readKey(key), info.dataSize >= 1 else { return }
        var current: UInt32 = 0
        for i in 0..<Int(info.dataSize) {
            current = (current << 8) | UInt32(info.bytes[i])
        }
        if forced { current |= (1 << UInt32(index)) } else { current &= ~(1 << UInt32(index)) }
        var bytes: [UInt8] = []
        for i in stride(from: Int(info.dataSize) - 1, through: 0, by: -1) {
            bytes.append(UInt8((current >> (i * 8)) & 0xFF))
        }
        _ = writeKey(key, size: info.dataSize, bytes: bytes)
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

        var input = SMCParam(key: code, data8: 9)
        var output = SMCParam()
        guard call(&input, &output) == KERN_SUCCESS else { return nil }

        var val = Value()
        val.dataSize = output.keyInfoSize
        val.dataType = fourCC(output.keyInfoType)
        guard val.dataSize > 0, val.dataSize <= 32 else { return nil }

        input = SMCParam(key: code, data8: 5, keyInfoSize: output.keyInfoSize)
        output = SMCParam()
        guard call(&input, &output) == KERN_SUCCESS else { return nil }
        val.bytes = output.byteArray
        return val
    }

    private func writeKey(_ key: String, size: UInt32, bytes: [UInt8]) -> Bool {
        guard key.utf8.count == 4, size > 0, size <= 32 else { return false }
        var code: UInt32 = 0
        for b in key.utf8 { code = (code << 8) | UInt32(b) }
        var input = SMCParam(key: code, data8: 6, keyInfoSize: size)
        input.setBytes(bytes)
        var output = SMCParam()
        return call(&input, &output) == KERN_SUCCESS
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
struct SMCParam {
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

    mutating func setBytes(_ values: [UInt8]) {
        var arr = Array(repeating: UInt8(0), count: 32)
        for (i, v) in values.prefix(32).enumerated() { arr[i] = v }
        bytes = (arr[0],arr[1],arr[2],arr[3],arr[4],arr[5],arr[6],arr[7],
                 arr[8],arr[9],arr[10],arr[11],arr[12],arr[13],arr[14],arr[15],
                 arr[16],arr[17],arr[18],arr[19],arr[20],arr[21],arr[22],arr[23],
                 arr[24],arr[25],arr[26],arr[27],arr[28],arr[29],arr[30],arr[31])
    }
}
