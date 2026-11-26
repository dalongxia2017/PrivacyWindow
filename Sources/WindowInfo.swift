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

    private static var appCache: [pid_t: (name: String, bundleID: String?)] = [:]

    /// 当前 Space 上的可处理窗口，数组顺序即 z 序（前 → 后）。
    /// 不需要任何权限：只有窗口标题受录屏权限保护，这里不读它。
    static func fetch(ownPID: pid_t, whitelist: Set<String>, blacklist: Set<String>, invertWhitelist: Bool = false) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return parse(list, ownPID: ownPID, whitelist: invertWhitelist ? [] : whitelist, blacklist: blacklist,
                     only: invertWhitelist ? whitelist : nil, bundleIDForPID: appInfo)
    }

    /// `bundleIDForPID` 的返回值是 (显示名, bundle id)。
    /// 白名单里的 App 直接不处理（永远清晰）；黑名单里的 App 保留并标记 `pinned`（永远模糊）。
    /// `only` 非 nil 时反过来（白名单反转）：只有列表里的 App 才处理，其余全部丢掉；列表为空就什么都不处理。
    static func parse(_ list: [[String: Any]], ownPID: pid_t, whitelist: Set<String>, blacklist: Set<String>, only: Set<String>? = nil,
                      bundleIDForPID: (pid_t) -> (name: String, bundleID: String?)) -> [WindowInfo] {
        var out: [WindowInfo] = []
        for w in list {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  pid != ownPID
            else { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: NSNumber],
                  let x = b["X"]?.doubleValue, let y = b["Y"]?.doubleValue,
                  let width = b["Width"]?.doubleValue, let height = b["Height"]?.doubleValue
            else { continue }
            if width < minSize || height < minSize { continue }
            if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }

            let app = bundleIDForPID(pid)
            if let bid = app.bundleID, whitelist.contains(bid) { continue }
            // 反转模式：没有 bundle id 的进程（命令行程序等）认不出来，也不处理
            if let only {
                // 没有 bundle id 的进程（命令行程序等）认不出来，也不处理
                guard let bid = app.bundleID, only.contains(bid) else { continue }
            }
            out.append(WindowInfo(id: id, bounds: CGRect(x: x, y: y, width: width, height: height),
                                  pid: pid, ownerName: app.name, bundleID: app.bundleID,
                                  pinned: app.bundleID.map(blacklist.contains) ?? false))
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
