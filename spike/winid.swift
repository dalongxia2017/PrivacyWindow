// 打印某进程 onscreen 窗口的 id 和位置：每行 "id<TAB>x y w h"（CG 坐标）
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    print("\(w[kCGWindowNumber as String] ?? 0)\t\(Int(b["X"] ?? 0)) \(Int(b["Y"] ?? 0)) \(Int(b["Width"] ?? 0)) \(Int(b["Height"] ?? 0))")
}
