// 列出某个进程在屏幕上的窗口：layer<TAB>name<TAB>x y w h
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    print("\(w[kCGWindowLayer as String] ?? 0)\t\(w[kCGWindowName as String] ?? "")\t\(Int(b["X"] ?? 0)) \(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0)) \(Int(b["Height"] ?? 0))")
}
