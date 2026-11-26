import AppKit

/// 一个需要处理的窗口。bounds 是 CG 全局坐标：主屏左上角为原点，Y 向下。
struct WindowInfo: Equatable {
    let id: CGWindowID
    let bounds: CGRect
    let pid: pid_t
    let ownerName: String
    let bundleID: String?
    /// 黑名单里的窗口：始终盖毛玻璃，鼠标移上去也不会成为焦点
    var pinned = false
    /// 在系统窗口列表（前 → 后）里的位置，用来和“不处理的窗口”比 z 序
    var order = 0
}

/// 不参与处理、但也不能被盖住的窗口：白名单里的 App、小于 80 pt 的小窗（输入法候选条一类）、
/// 1–3 层的浮动面板、本进程的设置窗口。它们不在处理列表里，但层级不高于覆盖层，
/// 伸到被遮窗口上面时必须在覆盖区域里挖掉，否则会连它们一起糊掉。
struct ClearWindow: Equatable {
    /// 在系统窗口列表（前 → 后）里的位置
    let order: Int
    let bounds: CGRect
}

/// 一帧的窗口快照。
struct WindowFrame {
    /// 要处理的窗口，前 → 后
    let windows: [WindowInfo]
    /// 不处理、但也不能盖住的窗口，前 → 后
    let clear: [ClearWindow]
}

/// NS（左下角原点，Y 向上）与 CG（左上角原点，Y 向下）的全局坐标互换。
/// 两套坐标只差一个沿主屏高度的翻转：cgY = mainHeight - nsY。
enum Geometry {
    /// 主屏在 CG 坐标系里的 bounds，origin 恒为 (0,0)
    static var mainCG: CGRect { CGDisplayBounds(CGMainDisplayID()) }

    static func nsToCG(_ p: CGPoint, mainHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: mainHeight - p.y)
    }

    static func nsToCG(_ r: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cgToNS(_ r: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    static func approxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

enum WindowSnapshot {
    /// 宽或高小于此值的窗口不处理（悬浮歌词、候选条、工具面板等）
    static let minSize: CGFloat = 80

    /// 覆盖层窗口的层级（floating + 1）。层级不高于它的窗口都会被覆盖层压在下面。
    static let overlayLevel: Int = Int(CGWindowLevelForKey(.floatingWindow)) + 1

    private static var appCache: [pid_t: (name: String, bundleID: String?)] = [:]

    /// 当前 Space 上的窗口：要处理的 + 不处理但也不能盖住的。数组顺序即 z 序（前 → 后）。
    /// 不需要任何权限：只有窗口标题受录屏权限保护，这里不读它。
    static func fetch(ownPID: pid_t, whitelist: Set<String>, blacklist: Set<String>, invertWhitelist: Bool = false) -> WindowFrame {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return WindowFrame(windows: [], clear: []) }
        let windows = parse(list, ownPID: ownPID, whitelist: invertWhitelist ? [] : whitelist, blacklist: blacklist,
                            only: invertWhitelist ? whitelist : nil, bundleIDForPID: appInfo)
        return WindowFrame(windows: windows, clear: clearWindows(in: list, processed: windows, ownPID: ownPID))
    }

    /// `list` 里没有被 `parse` 处理、但层级不高于覆盖层的可见窗口（前 → 后）。
    /// 层级高于覆盖层的（菜单、Dock、菜单栏）本来就在覆盖层上面，不用管；
    /// 层级为负的（桌面图标、通知小组件）永远垫在最底下，也不会压在谁的上面。
    /// 本进程层级不低于覆盖层的窗口是覆盖层自己，跳过；设置窗口（layer 0）要算进来。
    ///
    /// layer 0 里只有“正常大小的窗口”才挖洞——因为 App 规则不处理的（白名单、反转时不在中国内的）
    /// 和本进程的设置窗口。layer 0 的小窗（< `minSize`，例如系统贴着文本光标显示的 64×64 输入法角标）
    /// 不挖洞：洞是按窗口矩形挖的，比角标本身大得多，看起来就是“光标右边的毛玻璃没了”。
    /// 它们只能压在被遮窗口的毛玻璃下面（同一层级里插不进覆盖层，见 README「设计上的取舍」）。
    /// 1–3 层的小窗照常挖洞（它们本来就在覆盖层该在的位置之上/之下不好判定，统一按挖洞处理）。
    static func clearWindows(in list: [[String: Any]], processed: [WindowInfo], ownPID: pid_t) -> [ClearWindow] {
        let handled = Set(processed.map(\.id))
        var out: [ClearWindow] = []
        for (index, w) in list.enumerated() {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID, !handled.contains(id),
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = w[kCGWindowLayer as String] as? Int,
                  layer >= 0, layer <= overlayLevel,
                  !(pid == ownPID && layer >= overlayLevel),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) >= 0.05,
                  let bounds = bounds(of: w), bounds.width >= 1, bounds.height >= 1,
                  layer >= 1 || (bounds.width >= minSize && bounds.height >= minSize)
            else { continue }
            out.append(ClearWindow(order: index, bounds: bounds))
        }
        return out
    }

    private static func bounds(of w: [String: Any]) -> CGRect? {
        guard let b = w[kCGWindowBounds as String] as? [String: NSNumber],
              let x = b["X"]?.doubleValue, let y = b["Y"]?.doubleValue,
              let width = b["Width"]?.doubleValue, let height = b["Height"]?.doubleValue else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `bundleIDForPID` 的返回值是 (显示名, bundle id)。
    /// 白名单里的 App 直接不处理（永远清晰）；黑名单里的 App 保留并标记 `pinned`（永远模糊）。
    /// `only` 非 nil 时反过来（白名单反转）：只有列表里的 App 才处理，其余全部丢掉；列表为空就什么都不处理。
    static func parse(_ list: [[String: Any]], ownPID: pid_t, whitelist: Set<String>, blacklist: Set<String>, only: Set<String>? = nil,
                      bundleIDForPID: (pid_t) -> (name: String, bundleID: String?)) -> [WindowInfo] {
        var out: [WindowInfo] = []
        for (order, w) in list.enumerated() {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  pid != ownPID
            else { continue }
            guard let bounds = bounds(of: w) else { continue }
            if bounds.width < minSize || bounds.height < minSize { continue }
            if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }

            let app = bundleIDForPID(pid)
            if let bid = app.bundleID, whitelist.contains(bid) { continue }
            // 反转模式：没有 bundle id 的进程（命令行程序等）认不出来，也不处理
            if let only {
                // 没有 bundle id 的进程（命令行程序等）认不出来，也不处理
                guard let bid = app.bundleID, only.contains(bid) else { continue }
            }
            out.append(WindowInfo(id: id, bounds: bounds, pid: pid, ownerName: app.name, bundleID: app.bundleID,
                                  pinned: app.bundleID.map(blacklist.contains) ?? false, order: order))
        }
        return out
    }

    private static func appInfo(_ pid: pid_t) -> (name: String, bundleID: String?) {
        if let cached = appCache[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let info = (app?.localizedName ?? "pid \(pid)", app?.bundleIdentifier)
        appCache[pid] = info
        return info
    }
}

/// 判断鼠标下方的窗口：取 z 序里第一个包含鼠标点的可处理窗口。
/// 黑名单窗口不算候选：鼠标停在它上面时，保持上一个焦点窗口清晰（或按桌面行为全部模糊）。
enum HitTest {
    static func candidate(windows: [WindowInfo], at point: CGPoint) -> WindowInfo? {
        windows.first { !$0.pinned && $0.bounds.contains(point) }
    }
}
