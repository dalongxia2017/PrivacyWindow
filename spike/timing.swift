import AppKit
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
var n = 0
_ = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
let t0 = DispatchTime.now().uptimeNanoseconds
for _ in 0..<200 { if let l = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] { n = l.count } }
let t1 = DispatchTime.now().uptimeNanoseconds
_ = NSEvent.mouseLocation
let m0 = DispatchTime.now().uptimeNanoseconds
for _ in 0..<2000 { _ = NSEvent.mouseLocation; _ = NSScreen.screens.count }
let m1 = DispatchTime.now().uptimeNanoseconds
print(String(format: "CGWindowList onscreen=%d windows, %.3f ms/call (60fps budget 16.7ms)", n, Double(t1 - t0) / 200 / 1e6))
print(String(format: "NSEvent.mouseLocation %.4f ms/call", Double(m1 - m0) / 2000 / 1e6))
print("CGPreflightPostEventAccess=\(CGPreflightPostEventAccess()) screens=\(NSScreen.screens.count) postEvent=\(CGPreflightPostEventAccess())")
if let l = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
    let mine = ProcessInfo.processInfo.processIdentifier
    let others = l.filter { ($0[kCGWindowOwnerPID as String] as? Int32) != mine }
    let named = others.filter { ($0[kCGWindowName as String] as? String) != nil }
    let minSize = others.filter { if let b = $0[kCGWindowBounds as String] as? [String: CGFloat], let w = b["Width"], let h = b["Height"] { return w < 50 || h < 50 } ; return false }
    let alpha0 = others.filter { ($0[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 }
    print("otherApp windows=\(others.count) withName=\(named.count) tiny(<50pt)=\(minSize.count) alpha<0.05=\(alpha0.count)")
    var layers = Set<Int>(); for w in others { layers.insert(w[kCGWindowLayer as String] as? Int ?? 0) }
    print("layers=\(layers.sorted())")
    for w in others.prefix(40) {
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        print("  layer=\(w[kCGWindowLayer as String] ?? 0) alpha=\(w[kCGWindowAlpha as String] ?? 1) pid=\(w[kCGWindowOwnerPID as String] ?? 0) owner=\(w[kCGWindowOwnerName as String] ?? "?") name=\(w[kCGWindowName as String] ?? "nil") size=\(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0))")
    }
}
