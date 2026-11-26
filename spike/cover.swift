import AppKit
// 列出与给定 CG 矩形相交的 onscreen 窗口（前→后）
let a = CommandLine.arguments
let r = CGRect(x: Double(a[1])!, y: Double(a[2])!, width: Double(a[3])!, height: Double(a[4])!)
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let wb = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
    if wb.intersects(r) {
        let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
        let app = NSRunningApplication(processIdentifier: pid)
        print("layer=\(w[kCGWindowLayer as String] ?? 0) owner=\(w[kCGWindowOwnerName as String] ?? "") pid=\(pid) bundle=\(app?.bundleIdentifier ?? "?") cg=\(NSStringFromRect(wb)) alpha=\(w[kCGWindowAlpha as String] ?? 1)")
    }
}
