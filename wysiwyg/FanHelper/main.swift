import Foundation

// fanhelper — tiny privileged CLI bundled in wysiwyg.app/Contents/Resources.
// The app runs it via a one-shot admin prompt (`do shell script ...
// with administrator privileges`) so SMC writes happen as root without a
// resident daemon. Reads need no privileges; only writes go through here.
//
// Usage:
//   fanhelper set <fanIndex> <rpm>   manual mode at rpm (clamped to FMin..FMax)
//   fanhelper auto <fanIndex>        back to system automatic control
// Prints OK/ERROR to stdout; exit 0 on success, 1 on failure.

func fail(_ msg: String) -> Never {
    print("ERROR \(msg)")
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    fail("usage: fanhelper (set <index> <rpm> | auto <index>)")
}
guard let index = Int(args[2]), index >= 0, index < 8 else {
    fail("bad fan index '\(args.count > 2 ? args[2] : "")'")
}

switch args[1] {
case "set":
    guard args.count >= 4, let rpm = Double(args[3]), rpm > 0 else {
        fail("bad rpm '\(args.count > 3 ? args[3] : "")'")
    }
    if let err = FanSMC.setManualRPM(rpm, fanIndex: index) {
        fail(err.message)
    }
    let applied = FanSMC.readFans().first(where: { $0.index == index })
    print(String(format: "OK fan %d manual %.0f rpm (actual %.0f)", index,
                 min(applied?.max ?? rpm, max(applied?.min ?? rpm, rpm)),
                 applied?.actual ?? -1))
case "auto":
    if let err = FanSMC.setAuto(fanIndex: index) {
        fail(err.message)
    }
    print("OK fan \(index) automatic")
default:
    fail("unknown command '\(args[1])'")
}
