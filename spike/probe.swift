import AppKit
import ApplicationServices

// 1) 权限状态
let scrOK = CGPreflightScreenCaptureAccess()
let axOK = AXIsProcessTrusted()
print("screenRecordingPreflight=\(scrOK) axTrusted=\(axOK)")

// 2) 无/有权限时窗口列表能拿到什么
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("windowList=nil"); exit(1)
}
let myPID = Int(ProcessInfo.processInfo.processIdentifier)
var total = 0, withName = 0, other = 0, otherWithName = 0
var layers = Set<Int>()
print("--- onscreen windows (front->back), first 25 ---")
for (i, w) in list.enumerated() {
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let name = w[kCGWindowName as String] as? String
    let alpha = w[kCGWindowAlpha as String] as? CGFloat ?? -1
    total += 1
    layers.insert(layer)
    if name != nil { withName += 1 }
    if pid != myPID { other += 1; if name != nil { otherWithName += 1 } }
    if i < 25 {
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        print(String(format: "%2d layer=%-4d pid=%-6d alpha=%.2f %@%@ frame=%@",
                     i, layer, pid, alpha, owner, name != nil ? " name=\"\(name!)\"" : " name=<nil>", NSStringFromRect(r)))
    }
}
print("total=\(total) withName=\(withName) otherApps=\(other) otherAppsWithName=\(otherWithName) layers=\(layers.sorted())")

// 3) 自建窗口：NSWindow.frame 与 CGWindowBounds 是否一致（是否含阴影）
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let win = NSWindow(contentRect: NSRect(x: 400, y: 300, width: 320, height: 200),
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
win.title = "probe-target"
win.hasShadow = true
win.isReleasedWhenClosed = false
win.orderFrontRegardless()

// 4) 覆盖层：鼠标穿透 + behind-window 模糊 + 圆角 maskImage
func runProbe() {
    let target = win.frame
    let screen = win.screen ?? NSScreen.main!
    // 全屏覆盖层（每屏一个的方案 B）
    let ov = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    ov.isOpaque = false
    ov.backgroundColor = .clear
    ov.ignoresMouseEvents = true
    ov.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
    ov.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    ov.isMovable = false
    ov.isExcludedFromWindowsMenu = true
    ov.contentView?.wantsLayer = true

    let blur = NSVisualEffectView(frame: NSRect(x: target.minX, y: 0, width: target.width, height: target.minY))
    blur.blendingMode = .behindWindow
    blur.material = .hudWindow
    blur.state = .active
    blur.maskImage = roundedMask(radius: 10, corners: [.bl, .br])
    ov.contentView?.addSubview(blur)
    let dim = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    dim.wantsLayer = true
    dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
    dim.layer?.cornerRadius = 10
    dim.layer?.cornerCurve = .continuous
    ov.contentView?.addSubview(dim)
    ov.orderFrontRegardless()

    // 对比 CG bounds 与 NSWindow.frame
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        if let l2 = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
            for w in l2 where (w[kCGWindowOwnerPID as String] as? Int) == myPID {
                let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
                let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                print("own window layer=\(w[kCGWindowLayer as String] ?? 0) name=\(w[kCGWindowName as String] ?? "nil") cgBounds=\(NSStringFromRect(r))")
            }
        }
        print("probe NSWindow.frame=\(NSStringFromRect(win.frame)) screen=\(NSStringFromRect(screen.frame)) scale=\(screen.backingScaleFactor)")
        // 各材质的 maskImage 是否被接受
        let m = NSVisualEffectView()
        m.material = .hudWindow
        print("maskImage set OK: \(m.maskImage != nil ? "yes" : "no")")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        ov.orderOut(nil); win.orderOut(nil)
        exit(0)
    }
}
enum Corner: Int { case tl, tr, bl, br }
struct Corners: OptionSet { let rawValue: Int; init(rawValue: Int){ self.rawValue = rawValue }
    static let tl = Corners(rawValue: 1<<0), tr = Corners(rawValue: 1<<1), bl = Corners(rawValue: 1<<2), br = Corners(rawValue: 1<<3) }
func roundedMask(radius: CGFloat, corners: Corners) -> NSImage? {
    let size = NSSize(width: radius * 2 + 4, height: radius * 2 + 4)
    let img = NSImage(size: size, flipped: false) { rect in
        let p = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        NSColor.white.setFill(); p.fill()
        // 把不需要圆角的角补成方角
        let full = NSBezierPath(rect: rect)
        if !corners.contains(.bl) { NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: radius, height: radius)).fill() }
        if !corners.contains(.br) { NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: size.width - radius, y: 0, width: radius, height: radius)).fill() }
        if !corners.contains(.tl) { NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: size.height - radius, width: radius, height: radius)).fill() }
        if !corners.contains(.tr) { NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: size.width - radius, y: size.height - radius, width: radius, height: radius)).fill() }
        return true
    }
    img.capInsets = NSEdgeInsets(top: radius + 2, left: radius + 2, bottom: radius + 2, right: radius + 2)
    img.resizingMode = .stretch as NSImage.ResizingMode
    return img
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { runProbe() }
app.run()
