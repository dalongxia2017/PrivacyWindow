import AppKit
import Carbon

/// 纯逻辑自检：`PrivacyWindow --selftest`。不弹任何窗口。
enum SelfTest {
    static func run() -> Bool {
        geometryRoundTrip()
        windowParsing()
        hitTest()
        focusImmediate()
        focusDebounce()
        focusFlapping()
        focusVanish()
        regionSubtract()
        fullscreenPause()
        pausePolicy()
        splitViewLayout()
        pinnedWindows()
        clearWindows()
        motionDetector()
        hotKeyTitles()
        stageManagerReader()
        defaultsRoundTrip()
        print(failures == 0 ? "ALL PASSED (\(tests) tests)" : "FAILED: \(failures) assertion(s) in \(tests) tests")
        return failures == 0
    }

    private static var tests = 0
    private static var failures = 0

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        tests += 1
        if condition() {
            print("  ok   \(name)")
        } else {
            failures += 1
            print("  FAIL \(name)")
        }
    }

    private static func entry(_ id: CGWindowID, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                              pid: pid_t = 100, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
         kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h] as [String: NSNumber]]
    }

    private static func expect(_ name: String, _ condition: Bool) {
        SelfTest.check(name, condition)
    }

    private static func geometryRoundTrip() {
        let h: CGFloat = 1169
        let r = CGRect(x: 300, y: 577, width: 400, height: 292)
        let back = Geometry.cgToNS(Geometry.nsToCG(r, mainHeight: h), mainHeight: h)
        expect("geometry round trip", back == r)
        // 实测：NS {{400,300},{320,232}} ↔ CG {{400,637},{320,232}}
        let cg = Geometry.nsToCG(CGRect(x: 400, y: 300, width: 320, height: 232), mainHeight: h)
        expect("ns→cg matches probe", cg == CGRect(x: 400, y: 637, width: 320, height: 232))
        expect("point flip", Geometry.nsToCG(CGPoint(x: 10, y: 0), mainHeight: h) == CGPoint(x: 10, y: h))
    }

    private static func windowParsing() {
        let list: [[String: Any]] = [
            entry(1, 0, 0, 1800, 39, pid: 172, layer: 24),                       // 菜单栏
            entry(2, 0, 39, 1800, 1130, pid: 10),                                // 普通窗口
            entry(3, 1800, 0, 40, 20, pid: 11),                                  // 太小
            entry(4, 1800, 0, 600, 400, pid: 12, alpha: 0),                      // 透明
            entry(5, 1800, 100, 600, 400, pid: 999),                             // 自己
            entry(6, 100, 100, 300, 300, pid: 13),                               // 白名单
            entry(7, 100, 100, 300, 300, pid: 14, layer: -2147483601),           // 通知中心小组件
            entry(8, 100, 400, 300, 300, pid: 15),
        ]
        let names: [pid_t: (String, String?)] = [
            10: ("A", "com.a"), 11: ("B", "com.b"), 12: ("C", "com.c"), 13: ("D", "com.d"),
            14: ("E", "com.e"), 15: ("F", nil),
        ]
        // com.d 白名单（丢掉），com.a 黑名单（保留并钉住）
        let out = WindowSnapshot.parse(list, ownPID: 999, whitelist: ["com.d"], blacklist: ["com.a"]) { names[$0] ?? ("?", nil) }
        expect("keeps layer-0, ≥80pt, opaque, other apps, not whitelisted", out.map(\.id) == [2, 8])
        expect("bundle-less app is kept", out.last?.bundleID == nil)
        expect("blacklisted window is pinned", out.first?.pinned == true && out.last?.pinned == false)

        // 反转白名单：只处理 com.a（仍是黑名单 → 钉住）和 com.b（但它的窗口太小，本就被过滤），com.c 和没有 bundle id 的 F 都丢掉
        let only: Set<String> = ["com.a", "com.b"]
        let inverted = WindowSnapshot.parse(list, ownPID: 999, whitelist: [], blacklist: ["com.a"], only: only) { names[$0] ?? ("?", nil) }
        expect("inverted whitelist keeps only listed apps", inverted.map(\.id) == [2])
        expect("inverted whitelist still pins blacklisted apps", inverted.first?.pinned == true)
        // 反转但列表为空 = 什么都不处理（列表里有其它 App 时 com.d 所在的窗口不会出现）
        let none = WindowSnapshot.parse(list, ownPID: 999, whitelist: [], blacklist: [], only: []) { names[$0] ?? ("?", nil) }
        expect("inverted whitelist with an empty list covers nothing", none.isEmpty)
        let some = WindowSnapshot.parse(list, ownPID: 999, whitelist: [], blacklist: [], only: ["com.d"]) { names[$0] ?? ("?", nil) }
        expect("listed app becomes a normal (focusable, covered) window when inverted", some.map(\.id) == [6] && some.first?.pinned == false)
    }

    private static func hitTest() {
        let a = WindowInfo(id: 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), pid: 1, ownerName: "a", bundleID: nil)
        let b = WindowInfo(id: 2, bounds: CGRect(x: 300, y: 300, width: 500, height: 500), pid: 2, ownerName: "b", bundleID: nil)
        // b 在前（z 序更高）
        expect("topmost wins", HitTest.candidate(windows: [b, a], at: CGPoint(x: 400, y: 400))?.id == 2)
        expect("lower window when outside top", HitTest.candidate(windows: [b, a], at: CGPoint(x: 100, y: 100))?.id == 1)
        expect("desktop", HitTest.candidate(windows: [b, a], at: CGPoint(x: 900, y: 900)) == nil)
        var pinnedB = b
        pinnedB.pinned = true
        expect("pinned window is not a candidate", HitTest.candidate(windows: [pinnedB, a], at: CGPoint(x: 400, y: 400))?.id == 1)
        expect("only pinned under mouse → nil", HitTest.candidate(windows: [pinnedB], at: CGPoint(x: 400, y: 400)) == nil)
    }

    private static func pausePolicy() {
        let main = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let side = CGRect(x: 1800, y: 0, width: 1920, height: 1080)
        let screens: [(id: CGDirectDisplayID, rect: CGRect)] = [(1, main), (2, side)]
        func window(_ rect: CGRect) -> WindowInfo { WindowInfo(id: 1, bounds: rect, pid: 10, ownerName: "x", bundleID: nil) }
        expect("disabled screen is paused, others keep working",
               PausePolicy.pausedScreens(windows: [], screens: screens, pauseOnFullscreen: true, stageManagerActive: false,
                                         disabledScreens: [2]) == [2])
        expect("stage manager pauses every screen",
               PausePolicy.pausedScreens(windows: [], screens: screens, pauseOnFullscreen: true, stageManagerActive: true,
                                         disabledScreens: []) == [1, 2])
        expect("nothing to pause → nothing paused",
               PausePolicy.pausedScreens(windows: [window(CGRect(x: 50, y: 50, width: 800, height: 600))], screens: screens,
                                         pauseOnFullscreen: false, stageManagerActive: false, disabledScreens: []).isEmpty)
    }

    private static func splitViewLayout() {
        // 分屏：两个窗口各占半块屏，都没有与整块屏幕重合，所以不触发全屏暂停
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let left = WindowInfo(id: 1, bounds: CGRect(x: 0, y: 0, width: 900, height: 1169), pid: 10, ownerName: "L", bundleID: nil)
        let right = WindowInfo(id: 2, bounds: CGRect(x: 900, y: 0, width: 900, height: 1169), pid: 11, ownerName: "R", bundleID: nil)
        expect("split view is not treated as fullscreen",
               PausePolicy.pausedScreens(windows: [left, right], screens: [(1, screen)], pauseOnFullscreen: true,
                                         stageManagerActive: false, disabledScreens: []).isEmpty)
        expect("mouse on left → only right is covered, in full",
               OverlayLayout.regions(windows: [left, right], focus: 1) == [2: [right.bounds]])
        expect("mouse on right → only left is covered, in full",
               OverlayLayout.regions(windows: [left, right], focus: 2) == [1: [left.bounds]])
        expect("no focus yet → both covered",
               OverlayLayout.regions(windows: [left, right], focus: nil).keys.sorted() == [1, 2])
    }

    private static func pinnedWindows() {
        let normal = WindowInfo(id: 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), pid: 10, ownerName: "n", bundleID: "com.n")
        var pinned = WindowInfo(id: 2, bounds: CGRect(x: 200, y: 200, width: 500, height: 500), pid: 11, ownerName: "p", bundleID: "com.p")
        pinned.pinned = true
        // 鼠标在黑名单窗口上：它不是焦点，下面的普通窗口露出来的部分照常遮盖
        let regions = OverlayLayout.regions(windows: [pinned, normal], focus: nil)
        expect("pinned window is covered", regions[2] == [pinned.bounds])
        expect("window under it is covered minus the pinned hole", regions[1]?.count == 2)
        // 就算误把黑名单窗口当成焦点，也不能让它清晰
        expect("pinned window never becomes the hole",
               OverlayLayout.regions(windows: [pinned, normal], focus: 2).keys.sorted() == [1, 2])
    }

    /// MotionDetector：窗口连续自己动、鼠标不动 → 系统动画；鼠标键按着或光标跟着走 → 用户在拖。
    private static func motionDetector() {
        let still = CGPoint(x: 10, y: 10)
        var clock = 0.0
        func detector() -> MotionDetector { MotionDetector() }
        /// 窗口在 x 处，光标在 mouse；返回这一帧是否判定为“系统动画中”
        func frame(_ d: inout MotionDetector, x: CGFloat, mouse: CGPoint = still, button: Bool = false, force: Bool = false) -> Bool {
            clock += 1.0 / 60
            let w = WindowInfo(id: 1, bounds: CGRect(x: x, y: 100, width: 300, height: 200), pid: 1, ownerName: "a", bundleID: nil)
            return d.update(windows: [w], mouse: mouse, buttonPressed: button, force: force, now: clock)
        }
        var d = detector()
        expect("motion: nothing moving", !frame(&d, x: 0))
        expect("motion: a single jump is not an animation", !frame(&d, x: 40))
        expect("motion: second frame of the same jump", !frame(&d, x: 40))
        expect("motion: moving frame 1", !frame(&d, x: 60))
        expect("motion: moving frame 2", !frame(&d, x: 80))
        expect("motion: three moving frames without the mouse → animation", frame(&d, x: 100))
        expect("motion: animation continues while windows still move", frame(&d, x: 120))
        var held = true
        for _ in 0..<MotionDetector().stillToLeave - 1 { held = held && frame(&d, x: 120) }
        expect("motion: one frame before the still threshold it is still animating", held)
        expect("motion: enough still frames → animation over", !frame(&d, x: 120))

        d = detector()
        for x in [CGFloat(0), 20, 40, 60, 80] { _ = frame(&d, x: x, button: true) }
        expect("motion: window moving while the mouse button is held = dragging, not animation", !frame(&d, x: 100, button: true))

        d = detector()
        for i in 0..<5 { _ = frame(&d, x: CGFloat(i) * 20, mouse: CGPoint(x: 10 + i * 15, y: 10)) }
        expect("motion: window moving while the cursor moves = dragging, not animation", !frame(&d, x: 100, mouse: CGPoint(x: 85, y: 10)))

        d = detector()
        expect("motion: forced by the space-changed notification even with nothing moving", frame(&d, x: 0, force: true))
        expect("motion: forced state persists on the next still frame", frame(&d, x: 0))
        held = true
        // 上一行已经用掉一帧静止，再数到阈值前一帧
        for _ in 0..<MotionDetector().stillToLeave - 2 { held = held && frame(&d, x: 0) }
        expect("motion: forced state holds until the still threshold", held)
        expect("motion: forced state ends after the still threshold", !frame(&d, x: 0))

        d = detector()
        for x in [CGFloat(0), 20, 40, 60] { _ = frame(&d, x: x) }
        d.reset()
        expect("motion: reset clears the moving streak", !frame(&d, x: 100))

        var jerk = detector()
        for i in 0..<6 { _ = frame(&jerk, x: CGFloat(i), mouse: CGPoint(x: CGFloat(i % 2), y: 0)) }
        expect("motion: a pixel of cursor jitter still counts as an animation", frame(&jerk, x: 100, mouse: CGPoint(x: 1, y: 0)))
    }

    private static func clearWindows() {
        let list: [[String: Any]] = [
            entry(10, 500, 150, 200, 200, pid: 20),                        // 白名单 App 的窗口，压在 B 露出的部分上
            entry(11, 450, 250, 84, 77, pid: 21, layer: 3),                // 浮动面板
            entry(1, 0, 0, 400, 300, pid: 1),                              // A：焦点
            entry(12, 450, 250, 120, 60, pid: 22),                         // 小窗（60 pt 高）
            entry(2, 200, 200, 400, 300, pid: 2),                          // B：被遮
            entry(13, 300, 250, 100, 60, pid: 23),                         // 小窗（60 pt 高），垫在 B 下面
            entry(14, 0, 0, 1800, 1169, pid: 999, layer: 4),               // 本进程的覆盖层
            entry(15, 250, 260, 100, 100, pid: 999),                       // 本进程的设置窗口，垫在 B 下面
            entry(16, 0, 0, 1800, 39, pid: 172, layer: 24),                // 菜单栏：在覆盖层上面
            entry(17, 8, 227, 360, 180, pid: 173, layer: -2147483601),     // 通知小组件：垫在最底下
        ]
        let names: [pid_t: (String, String?)] = [1: ("A", "a"), 2: ("B", "b"), 20: ("W", "com.w"), 21: ("F", "f"),
                                                22: ("S", "s"), 23: ("T", "t"), 999: ("自己", "me")]
        let info = { (pid: pid_t) -> (String, String?) in names[pid] ?? ("?", nil) }
        let windows = WindowSnapshot.parse(list, ownPID: 999, whitelist: ["com.w"], blacklist: [], bundleIDForPID: info)
        expect("clear test setup: A and B are processed", windows.map(\.id) == [1, 2])
        let clear = WindowSnapshot.clearWindows(in: list, processed: windows, ownPID: 999)
        // 白名单窗口、浮动面板、上面的小窗、下面的小窗、下面的设置窗口；不含覆盖层自己、菜单栏、小组件
        expect("clear list = unprocessed windows at or below the overlay level",
               clear.map(\.order) == [0, 1, 3, 5, 7])
        let regions = OverlayLayout.regions(windows: windows, focus: 1, clear: clear)
        let covered = regions[2] ?? []
        func coveredArea(_ rect: CGRect) -> CGFloat {
            covered.reduce(CGFloat(0)) { $0 + ($1.intersection(rect).isNull ? 0 : $1.intersection(rect).width * $1.intersection(rect).height) }
        }
        expect("whitelisted window above a covered window is never covered",
               coveredArea(CGRect(x: 500, y: 150, width: 200, height: 200)) == 0)
        expect("floating panel (layer 3) above a covered window is never covered",
               coveredArea(CGRect(x: 450, y: 250, width: 84, height: 77)) == 0)
        expect("small window above a covered window is never covered",
               coveredArea(CGRect(x: 450, y: 250, width: 120, height: 60)) == 0)
        expect("small window below does not punch a hole",
               coveredArea(CGRect(x: 300, y: 300, width: 100, height: 10)) == 1000)
        expect("settings window below does not punch a hole",
               coveredArea(CGRect(x: 250, y: 300, width: 100, height: 60)) == 6000)
        expect("covered window minus all the windows on top of it",
               regions[2] == RegionMath.subtract(CGRect(x: 200, y: 200, width: 400, height: 300),
                                                 [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 500, y: 150, width: 200, height: 200),
                                                  CGRect(x: 450, y: 250, width: 84, height: 77), CGRect(x: 450, y: 250, width: 120, height: 60)]))
        // 修复前的行为：不挖这些洞，白名单窗口被盖 15000
        let before = OverlayLayout.regions(windows: windows, focus: 1)
        let beforeArea = (before[2] ?? []).reduce(CGFloat(0)) { sum, r in
            let i = r.intersection(CGRect(x: 500, y: 150, width: 200, height: 200))
            return sum + (i.isNull ? 0 : i.width * i.height)
        }
        expect("regression: without clear windows the whitelisted window got covered", beforeArea == 15000)
    }

    private static func hotKeyTitles() {
        expect("default hotkey is ⌥⌘P", HotKey.default.title == "⌥⌘P" && HotKey.default.isValid)
        expect("order of modifiers", HotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(Carbon.shiftKey | Carbon.controlKey | Carbon.cmdKey)).title == "⌃⇧⌘K")
        expect("plain letter is not a valid hotkey", !HotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: 0).isValid)
        expect("function key alone is valid", HotKey(keyCode: UInt32(kVK_F19), modifiers: 0).isValid)
        expect("modifier only is not a hotkey", HotKey(keyCode: 55, modifiers: UInt32(Carbon.cmdKey)).title == "未设置")
        expect("flags → carbon", HotKey.carbonModifiers(from: [.command, .shift]) == UInt32(Carbon.cmdKey | Carbon.shiftKey))
    }

    private static func stageManagerReader() {
        var reads = 0
        StageManager.overrideReader(forTest: { domain in reads += 1; return domain == "on" ? true : domain == "off" ? false : nil })
        expect("stage manager on", StageManager.isEnabled(preferencesDomain: "on") == true)
        expect("stage manager off", StageManager.isEnabled(preferencesDomain: "off") == false)
        expect("stage manager unknown → nil", StageManager.isEnabled(preferencesDomain: "missing") == nil)
        let monitor = StageManager.Monitor(interval: 10)
        // Monitor 读的是真实的偏好域
        StageManager.overrideReader(forTest: { _ in reads += 1; return true })
        reads = 0
        expect("monitor caches", monitor.isEnabled(now: 0) && monitor.isEnabled(now: 1) && reads == 1)
        expect("monitor refreshes after interval", monitor.isEnabled(now: 11) && reads == 2)
        expect("stale cache until interval", monitor.isEnabled(now: 12) && reads == 2)
    }

    private static func focusImmediate() {
        var r = FocusResolver(debounce: 0)
        let existing: Set<CGWindowID> = [1, 2]
        r.update(candidate: 1, existing: existing, now: 0)
        expect("debounce 0 switches at once", r.current == 1)
        r.update(candidate: 2, existing: existing, now: 0.001)
        expect("debounce 0 switches again", r.current == 2)
    }

    private static func focusDebounce() {
        var r = FocusResolver(debounce: 0.04)
        let existing: Set<CGWindowID> = [1, 2]
        r.update(candidate: 1, existing: existing, now: 0)
        expect("first focus still needs debounce", r.current == nil)
        r.update(candidate: 1, existing: existing, now: 0.039)
        expect("not yet", r.current == nil)
        r.update(candidate: 1, existing: existing, now: 0.041)
        expect("switched after 40ms", r.current == 1)
    }

    private static func focusFlapping() {
        var r = FocusResolver(debounce: 0.05)
        let existing: Set<CGWindowID> = [1, 2]
        r.update(candidate: 1, existing: existing, now: 0)
        r.update(candidate: 1, existing: existing, now: 0.1)
        // 在两个窗口之间来回：每次换候选都重新计时
        r.update(candidate: 2, existing: existing, now: 0.2)
        r.update(candidate: 1, existing: existing, now: 0.24)
        r.update(candidate: 2, existing: existing, now: 0.26)
        r.update(candidate: 2, existing: existing, now: 0.30)
        expect("flapping keeps original focus", r.current == 1)
        r.update(candidate: 2, existing: existing, now: 0.311)
        expect("stable candidate takes over", r.current == 2)
    }

    private static func focusVanish() {
        var r = FocusResolver(debounce: 0.1)
        r.update(candidate: 1, existing: [1, 2], now: 0)
        r.update(candidate: 1, existing: [1, 2], now: 0.2)
        expect("focused", r.current == 1)
        let changed = r.update(candidate: nil, existing: [2], now: 0.3)
        expect("vanished focus clears immediately", changed && r.current == nil)
        r.update(candidate: 2, existing: [2], now: 0.4)
        r.update(candidate: 2, existing: [2], now: 0.52)
        expect("next focus", r.current == 2)
    }

    private static func regionSubtract() {
        let base = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // 全屏背景窗口上面压着一个 300x200 的焦点窗口：中间要挖掉
        let pieces = RegionMath.subtract(base, [CGRect(x: 300, y: 200, width: 300, height: 200)])
        let area = pieces.reduce(0) { $0 + $1.width * $1.height }
        expect("hole removed", abs(area - (1000 * 800 - 300 * 200)) < 1)
        expect("no piece overlaps the hole", pieces.allSatisfy { !$0.intersects(CGRect(x: 300, y: 200, width: 300, height: 200)) })
        // 两个洞，一个在边上，一个跨到区域外
        let edge = RegionMath.subtract(base, [CGRect(x: 900, y: 600, width: 400, height: 400),
                                              CGRect(x: -50, y: 100, width: 100, height: 50)])
        let edgeArea = edge.reduce(0) { $0 + $1.width * $1.height }
        expect("edge holes", abs(edgeArea - (1000 * 800 - 100 * 200 - 50 * 50)) < 1)
        // 被遮窗口完全被上面的窗口挡住：不需要任何覆盖
        expect("fully hidden → nothing", RegionMath.subtract(CGRect(x: 0, y: 0, width: 100, height: 100),
                                                             [CGRect(x: -10, y: -10, width: 200, height: 200)]).isEmpty)
    }

    private static func fullscreenPause() {
        let main = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let side = CGRect(x: 1800, y: 0, width: 1920, height: 1080)
        let screens: [(id: CGDirectDisplayID, rect: CGRect)] = [(1, main), (2, side)]
        func pause(_ windows: [CGRect], fullscreen: Bool = true) -> Set<CGDirectDisplayID> {
            PausePolicy.pausedScreens(windows: windows.map { WindowInfo(id: 1, bounds: $0, pid: 10, ownerName: "x", bundleID: nil) },
                                      screens: screens, pauseOnFullscreen: fullscreen, stageManagerActive: false, disabledScreens: [])
        }
        expect("no fullscreen → nothing paused", pause([CGRect(x: 50, y: 50, width: 800, height: 600)]).isEmpty)
        expect("fullscreen on side display pauses only it", pause([side]) == [2])
        // 贴着菜单栏下沿的最大化窗口不算全屏（菜单栏还露着）
        let maximized = CGRect(x: 0, y: 39, width: 1800, height: 1130)
        expect("maximized under menu bar is not fullscreen", pause([maximized]).isEmpty)
        expect("fullscreen with 1pt rounding", pause([CGRect(x: 0, y: 0, width: 1800, height: 1170)]) == [1])
        expect("fullscreen pause can be turned off", pause([side], fullscreen: false).isEmpty)
    }

    private static func defaultsRoundTrip() {
        let name = "PrivacyWindow.SelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let a = SettingsStore(defaults: defaults)
        expect("defaults", a.enabled && a.material == .hudWindow && a.desktopBehavior == .keepLast
            && a.animationMS == 150 && a.debounceMS == 40 && a.pauseOnFullscreen && a.pauseOnStageManager
            && !a.lowPower && a.hotkeyEnabled && a.hotkey == .default && a.overlayDimAlpha == 0.25)
        a.enabled = false
        a.material = .popover
        a.dimAlpha = 0.5
        a.animationMS = 250
        a.debounceMS = 0
        a.add("com.x", to: .whitelist)
        a.add("com.x", to: .whitelist)
        a.add("com.p", to: .blacklist)
        a.desktopBehavior = .blurAll
        a.pauseOnFullscreen = false
        a.lowPower = true
        a.invertWhitelist = true
        a.disabledScreens = [3]
        a.hotkeyEnabled = false
        a.hotkey = HotKey(keyCode: UInt32(kVK_F19), modifiers: 0)
        let b = SettingsStore(defaults: defaults)
        expect("persisted", !b.enabled && b.material == .popover && b.dimAlpha == 0.5
            && b.animationMS == 250 && b.debounceMS == 0 && b.whitelist == ["com.x"] && b.blacklist == ["com.p"]
            && b.desktopBehavior == .blurAll && !b.pauseOnFullscreen && b.lowPower && b.invertWhitelist
            && b.disabledScreens == [3] && !b.hotkeyEnabled && b.hotkey.keyCode == UInt32(kVK_F19))
        expect("low power forces dim ≥ 50%", b.overlayDimAlpha == 0.5)
        b.dimAlpha = 0.1
        expect("low power raises a too-light dim", b.overlayDimAlpha == SettingsStore.lowPowerMinDim)
        b.lowPower = false
        expect("normal mode uses the dim as set", b.overlayDimAlpha == 0.1)
        expect("disabled screen lookup", !b.isScreenEnabled(3) && b.isScreenEnabled(1))
        expect("hotkey off → no active hotkey", b.activeHotKey == nil)
        b.hotkeyEnabled = true
        expect("hotkey on → active hotkey", b.activeHotKey == b.hotkey)
        // 同一个 App 不能同时出现在两个名单里
        b.add("com.x", to: .blacklist)
        expect("moving to blacklist removes from whitelist", b.whitelist.isEmpty && b.blacklist == ["com.p", "com.x"])
        b.remove("com.x", from: .blacklist)
        b.remove("com.missing", from: .whitelist)
        expect("remove from list", b.blacklist == ["com.p"] && b.whitelist.isEmpty)
        defaults.removePersistentDomain(forName: name)

        // 旧版本只有“排除 App”一个名单：升级后应当成为白名单
        let legacy = "PrivacyWindow.SelfTest.legacy.\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacy)!
        legacyDefaults.set(["com.old"], forKey: "pw.excludedBundleIDs")
        let c = SettingsStore(defaults: legacyDefaults)
        expect("old exclusion list becomes the whitelist", c.whitelist == ["com.old"] && c.blacklist.isEmpty)
        legacyDefaults.removePersistentDomain(forName: legacy)
    }
}
