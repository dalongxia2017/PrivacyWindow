import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// 靶窗口：高对比黑白条纹
let target = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 400, height: 260),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
target.title = "probe3-target"
target.isReleasedWhenClosed = false
let stripes = NSView()
stripes.wantsLayer = true
stripes.frame = NSRect(x: 0, y: 0, width: 400, height: 260)   // NSView() 默认零 frame，必须显式给
let grid = CALayer()
grid.frame = stripes.frame
grid.backgroundColor = NSColor.white.cgColor
for i in 0..<40 {
    let l = CALayer()
    l.frame = NSRect(x: CGFloat(i) * 20, y: 0, width: 10, height: 260)
    l.backgroundColor = NSColor.black.cgColor
    grid.addSublayer(l)
}
stripes.layer?.addSublayer(grid)
target.contentView = stripes
target.orderFrontRegardless()

var ov: NSWindow!
var blur: NSVisualEffectView!

func later(_ t: Double, _ f: @escaping () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f)
}

func makeOverlay() -> NSWindow {
    // 不能用 NSScreen.main（= 鼠标所在屏）；用靶窗口所在屏
    let scr = target.screen ?? NSScreen.screens.first!
    let ov = NSWindow(contentRect: scr.frame, styleMask: .borderless, backing: .buffered, defer: false)
    ov.isOpaque = false
    ov.backgroundColor = .clear
    ov.ignoresMouseEvents = true
    ov.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
    ov.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    ov.isMovable = false
    ov.contentView?.wantsLayer = true
    return ov
}

func roundedMask(radius: CGFloat) -> NSImage {
    let size = NSSize(width: radius * 2 + 4, height: radius * 2 + 4)
    let img = NSImage(size: size, flipped: false) { rect in
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: radius + 2, left: radius + 2, bottom: radius + 2, right: radius + 2)
    img.resizingMode = .stretch
    return img
}

// 模式由参数决定：baseline / hud / under / full / dim / fade
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "baseline"
let fadeArg = CommandLine.arguments.dropFirst(2).compactMap { Double($0) }.first ?? 1.0

if mode != "baseline" {
    ov = makeOverlay()
    blur = NSVisualEffectView(frame: NSRect(x: 300, y: 300, width: 400, height: 260))
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.maskImage = roundedMask(radius: 12)
    switch mode {
    case "hud": blur.material = .hudWindow
    case "under": blur.material = .underWindowBackground
    case "full": blur.material = .fullScreenUI
    case "popover": blur.material = .popover
    case "sheet": blur.material = .sheet
    case "menu": blur.material = .menu
    case "sidebar": blur.material = .sidebar
    case "titlebar": blur.material = .titlebar
    default: blur.material = .hudWindow
    }
    if mode == "dim" {
        // 低性能模式：纯半透明黑，无模糊
        let d = NSView(frame: blur.frame)
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        d.layer?.cornerRadius = 12
        d.layer?.cornerCurve = .continuous
        ov.contentView?.addSubview(d)
    } else {
        ov.contentView?.addSubview(blur)
    }
    ov.orderFrontRegardless()
    if fadeArg < 1.0 { blur.alphaValue = CGFloat(fadeArg) }
}

later(0.8) {
    let pid = ProcessInfo.processInfo.processIdentifier
    if let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
        for w in l where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
            print("own layer=\(w[kCGWindowLayer as String] ?? 0) name=\(w[kCGWindowName as String] ?? "nil") cgBounds=\(w[kCGWindowBounds as String] ?? "nil")")
        }
    }
    print("target NS frame=\(NSStringFromRect(target.frame)) screen=\(NSStringFromRect(target.screen?.frame ?? .zero)) overlay=\(ov == nil ? "nil" : NSStringFromRect(ov!.frame))")
    fflush(stdout)
}
// 稳定 1.2s 后退出；截图由外部 screencapture 命令完成。
// 传 --stay 则一直留着（给 spike/smoke.py 当被遮窗口用），由外部 kill。
// --drift：每 1.2s 把靶窗口跳到下一个位置并打印新位置（CG 坐标），用来测覆盖层跟随
if CommandLine.arguments.contains("--drift") {
    let mainHeight = NSScreen.screens[0].frame.height
    let origins = [CGPoint(x: 300, y: 300), CGPoint(x: 700, y: 500), CGPoint(x: 1000, y: 250), CGPoint(x: 300, y: 600)]
    var index = 0
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        func step() {
            let o = origins[index % origins.count]
            index += 1
            target.setFrameOrigin(o)
            let h = target.frame.height
            print("pos \(Int(o.x)) \(Int(mainHeight - o.y - h)) \(Int(target.frame.width)) \(Int(h))")
            fflush(stdout)
            // 每 1.2s 跳一次：给外部留出足够时间截图确认覆盖层跟上了再跳下一格
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: step)
        }
        step()
    }
}

// --slide：窗口自己连续移动 50 帧（每帧 3pt，约 0.85s），模拟切换桌面 / 吸附动画这类“不是用户拖着”的移动。
// 开始和结束时各打一行，结束那行带最终位置（CG 坐标）。
if CommandLine.arguments.contains("--slide") {
    let mainHeight = NSScreen.screens[0].frame.height
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        print("slide start")
        fflush(stdout)
        var frames = 0
        func step() {
            frames += 1
            target.setFrameOrigin(CGPoint(x: 300 + CGFloat(frames) * 3, y: 300))
            if frames < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: step)
            } else {
                let h = target.frame.height
                print("slide end \(Int(target.frame.minX)) \(Int(mainHeight - target.frame.minY - h)) \(Int(target.frame.width)) \(Int(h))")
                fflush(stdout)
            }
        }
        step()
    }
}

if CommandLine.arguments.contains("--stay") {
    print("staying; target cgBounds see above")
    fflush(stdout)
} else {
    later(2.5) {
        ov?.orderOut(nil)
        target.orderOut(nil)
        exit(0)
    }
}
app.run()
