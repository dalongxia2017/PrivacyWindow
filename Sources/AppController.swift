import AppKit

/// 把各模块串起来：每帧取鼠标位置与窗口列表 → 判定焦点 → 更新覆盖层。
final class AppController {
    let settings: SettingsStore
    let overlays: OverlayManager
    private var resolver: FocusResolver
    private var menuBar: MenuBarController?
    private let settingsWindow: SettingsWindowController
    private let hotKeys = HotKeyController()
    private var registeredHotKey: HotKey?
    private let stageMonitor = StageManager.Monitor()
    private var timer: Timer?

    /// 调试/测试参数。只在命令行显式传入时生效，正常双击启动时全部为 nil / false。
    private let mouseOverride: MouseOverride?
    private let trace = CommandLine.arguments.contains("--trace")
    private let selfcheck = CommandLine.arguments.contains("--open-settings")
    /// `--set stageManager=1`：假装台前调度已开启（本机没法在测试里真的打开它）
    private var stageManagerOverride: Bool?

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        self.mouseOverride = Self.parseMouseOverride()
        overlays = OverlayManager(settings: settings)
        resolver = FocusResolver(debounce: settings.debounce)
        settingsWindow = SettingsWindowController(settings: settings)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: SettingsStore.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // 其它进程（`PrivacyWindow --toggle` 等）发来的命令
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteCommand(_:)),
            name: Notification.Name("com.dalongxia2017.PrivacyWindow.command"), object: nil)
    }

    func start() {
        // 放在 init 之外：菜单栏回调要弱引用 self，init 里 self 还没初始化完。
        let menuBar = MenuBarController(settings: settings) { [weak self] in self?.showSettings() }
        self.menuBar = menuBar
        hotKeys.onPress = { [weak self] in self?.settings.toggleEnabled() }
        applyDebugOverrides()
        registerHotKey(alertOnError: false)
        scheduleTimer()
        if selfcheck { scheduleSelfcheck() }
    }

    var pollInterval: TimeInterval { settings.enabled ? 1.0 / 60 : 0.25 }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func showSettings() {
        settingsWindow.show()
    }

    /// 把当前生效的快捷键交给系统。`alertOnError`：用户刚改了快捷键却注册失败时给出说明。
    private func registerHotKey(alertOnError: Bool) {
        let wanted = settings.activeHotKey
        guard wanted != registeredHotKey else { return }
        hotKeys.register(wanted)
        registeredHotKey = wanted
        if alertOnError, wanted != nil, let message = hotKeys.errorDescription {
            let alert = NSAlert()
            alert.messageText = "快捷键没有生效"
            alert.informativeText = message + "。可以换一个组合，或先关闭「启用快捷键」。"
            alert.runModal()
        }
    }

    /// `--set key=value[,...]`：调试/测试用，启动时覆盖指定设置。
    /// 调试启动用的是独立的 defaults 域（见 main.swift），不会动用户真实设置。
    private func applyDebugOverrides() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--set"), index + 1 < args.count else { return }
        for pair in args[index + 1].split(separator: ",").map(String.init) {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<eq]), value = String(pair[pair.index(after: eq)...])
            let flag = value == "1"
            let number = Double(value)
            switch key {
            case "enabled": settings.enabled = flag
            case "material": if let v = BlurMaterial(rawValue: value) { settings.material = v }
            case "dimAlpha": if let v = number { settings.dimAlpha = v }
            case "animationMS": if let v = number { settings.animationMS = v }
            case "debounceMS": if let v = number { settings.debounceMS = v }
            case "desktopBehavior": if let v = DesktopBehavior(rawValue: value) { settings.desktopBehavior = v }
            case "pauseOnFullscreen": settings.pauseOnFullscreen = flag
            case "pauseOnStageManager": settings.pauseOnStageManager = flag
            case "lowPower": settings.lowPower = flag
            case "hotkeyEnabled": settings.hotkeyEnabled = flag
            case "hotkeyCode": if let v = number { settings.hotkey.keyCode = UInt32(v) }
            case "hotkeyModifiers": if let v = number { settings.hotkey.modifiers = UInt32(v) }
            // 名单里的 bundle id 用 `+` 连接：`--set` 自己已经用逗号分隔了
            case "whitelist": settings.whitelist = Self.splitList(value)
            case "blacklist": settings.blacklist = Self.splitList(value)
            case "invertWhitelist": settings.invertWhitelist = flag
            // `disableScreenAt=x;y`：关掉包含这个 CG 坐标的显示器
            case "disableScreenAt":
                let xy = value.split(separator: ";").compactMap { Double($0) }
                if xy.count == 2 { settings.disabledScreens += Self.screen(at: CGPoint(x: xy[0], y: xy[1])).map { [$0] } ?? [] }
            case "stageManager": stageManagerOverride = flag
            default: break
            }
        }
    }

    private static func splitList(_ value: String) -> [String] {
        value.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 包含某个 CG 坐标的显示器 id
    private static func screen(at point: CGPoint) -> CGDirectDisplayID? {
        connectedScreens().first { $0.rect.contains(point) }?.id
    }

    private static func connectedScreens() -> [(id: CGDirectDisplayID, rect: CGRect, screen: NSScreen)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return (id, Geometry.nsToCG(screen.frame, mainHeight: Geometry.mainCG.height), screen)
        }
    }

    /// `--open-settings`：启动 2 秒后把几项只能靠运行时确认的状态打成 `selfcheck: key=value`，
    /// 给 spike/smoke.py 用。
    private func scheduleSelfcheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            let frame = self.settingsWindow.window.frame
            var lines = [
                "selfcheck: settingsWindow \(self.settingsWindow.window.isVisible ? "ok" : "hidden")",
                "selfcheck: settingsWindowSize \(Int(frame.width))x\(Int(frame.height))",
                "selfcheck: statusItem \(self.menuBar?.statusItemFrame.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))" } ?? "missing")",
                "selfcheck: overlayWindows \(self.overlays.overlayWindowCount)",
                "selfcheck: overlayIgnoresMouse \(self.overlays.allIgnoreMouse)",
                "selfcheck: hotkey \(self.hotKeyState)",
                "selfcheck: launchAtLogin \(self.launchAtLoginState)",
                "selfcheck: screens \(self.settingsWindow.debugScreenChecks())",
            ]
            if let content = self.settingsWindow.window.contentView, content.subviews.first is NSStackView {
                let fit = content.fittingSize
                lines.append("selfcheck: contentFits \(fit.height <= content.bounds.height + 1 ? "ok" : "clip:\(Int(fit.height))>\(Int(content.bounds.height))")")
            }
            print(lines.joined(separator: "\n"))
            fflush(stdout)
        }
    }

    private var hotKeyState: String {
        guard let key = settings.activeHotKey else { return "off" }
        if let error = hotKeys.lastError { return "error:\(error)" }
        return registeredHotKey == key ? "registered" : "invalid"
    }

    private var launchAtLoginState: String {
        switch LaunchAtLogin.state {
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .needsApproval: return "needsApproval"
        }
    }

    // MARK: - 事件

    @objc private func settingsChanged() {
        overlays.settingsChanged()
        if !settings.enabled {
            resolver.reset()
            overlays.hideAll()
        }
        registerHotKey(alertOnError: true)
        scheduleTimer()
    }

    @objc private func screensChanged() {
        overlays.rebuildScreens()
        settingsWindow.screensChanged()
    }

    @objc private func remoteCommand(_ notification: Notification) {
        switch notification.userInfo?["command"] as? String {
        case "toggle": settings.toggleEnabled()
        case "enable": settings.enabled = true
        case "disable": settings.enabled = false
        default: break
        }
    }

    // MARK: - 每帧

    /// 一帧：返回本帧的焦点窗口 id，便于测试。
    @discardableResult
    func tick(now: TimeInterval = CACurrentMediaTime()) -> CGWindowID? {
        guard settings.enabled else { return nil }
        let mouse = mouseOverride?.current ?? Geometry.nsToCG(NSEvent.mouseLocation, mainHeight: Geometry.mainCG.height)
        let windows = WindowSnapshot.fetch(ownPID: ProcessInfo.processInfo.processIdentifier,
                                           whitelist: Set(settings.whitelist), blacklist: Set(settings.blacklist),
                                           invertWhitelist: settings.invertWhitelist)
        let existing = Set(windows.map(\.id))

        var candidate = HitTest.candidate(windows: windows, at: mouse)?.id
        // 鼠标在桌面 / 菜单栏 / Dock / 黑名单窗口上：保持上一个焦点窗口清晰
        if candidate == nil, settings.desktopBehavior == .keepLast, let current = resolver.current,
           existing.contains(current) {
            candidate = current
        }

        resolver.debounce = settings.debounce
        resolver.update(candidate: candidate, existing: existing, now: now)

        let screens = Self.connectedScreens()
        lastWindows = windows
        let stageManagerOn = stageManagerOverride ?? (settings.pauseOnStageManager && stageMonitor.isEnabled(now: now))
        let paused = PausePolicy.pausedScreens(windows: windows, screens: screens.map { (id: $0.id, rect: $0.rect) },
                                               pauseOnFullscreen: settings.pauseOnFullscreen,
                                               stageManagerActive: stageManagerOn,
                                               disabledScreens: Set(settings.disabledScreens))
        overlays.update(windows: windows, focus: resolver.current, pausedScreens: paused)
        if trace {
            traceFrame(mouse: mouse, candidate: candidate, paused: paused)
            traceChanges(now: now, covered: overlays.coveredWindowIDs, paused: paused)
        }
        return resolver.current
    }

    /// `--mouse "x,y[;x,y@毫秒...]"`：用给定的 CG 坐标代替真实鼠标位置，
    /// `@毫秒` 表示启动后过这么久再切到这个点。自动测试不需要挪动真实光标。
    private struct MouseOverride {
        let points: [(point: CGPoint, after: TimeInterval)]
        let start = CACurrentMediaTime()
        var current: CGPoint {
            let elapsed = CACurrentMediaTime() - start
            var point = points[0].point
            for p in points where elapsed >= p.after { point = p.point }
            return point
        }
    }

    private static func parseMouseOverride() -> MouseOverride? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--mouse"), index + 1 < args.count else { return nil }
        let points = args[index + 1].split(separator: ";").compactMap { part -> (CGPoint, TimeInterval)? in
            let pieces = part.split(separator: "@")
            let xy = pieces[0].split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else { return nil }
            return (CGPoint(x: xy[0], y: xy[1]), pieces.count > 1 ? (Double(pieces[1]) ?? 0) / 1000 : 0)
        }
        return points.isEmpty ? nil : MouseOverride(points: points)
    }

    /// `--trace`：每 15 帧打印一行焦点判定，用于排查“为什么没盖住 / 为什么没变清晰”。
    private var traceCount = 0

    private func traceFrame(mouse: CGPoint, candidate: CGWindowID?, paused: Set<CGDirectDisplayID>) {
        traceCount += 1
        guard traceCount % 15 == 0 else { return }
        let covered = overlays.coveredWindowIDs.sorted()
        let list = windowsDescription()
        print("mouse CG=\(Int(mouse.x)),\(Int(mouse.y)) cand=\(candidate.map(String.init) ?? "nil") "
              + "focus=\(resolver.current.map(String.init) ?? "nil") covered=\(covered) paused=\(paused.sorted()) "
              + "overlayIgnoresMouse=\(overlays.allIgnoreMouse) windows=[\(list)]")
        fflush(stdout)
    }

    /// `--trace`：焦点 / 被遮窗口集合 / 暂停的屏幕一变化就打一行（带启动后的秒数），
    /// 用来查“窗口移动时覆盖层为什么闪”。每 15 帧那行太稀，抓不到一两帧的变化。
    private var lastTraceState: String?

    private func traceChanges(now: TimeInterval, covered: Set<CGWindowID>, paused: Set<CGDirectDisplayID>) {
        let state = "focus=\(resolver.current.map(String.init) ?? "nil") covered=\(covered.sorted()) paused=\(paused.sorted())"
        guard state != lastTraceState else { return }
        lastTraceState = state
        print(String(format: "t=%.3f ", now - traceStart) + state)
        fflush(stdout)
    }

    private let traceStart = CACurrentMediaTime()

    private var lastWindows: [WindowInfo] = []

    private func windowsDescription() -> String {
        lastWindows.map { "\($0.id):\($0.ownerName)\($0.pinned ? "(黑)" : "")" }.joined(separator: " ")
    }
}

/// 哪些屏幕这一帧完全不覆盖。
enum PausePolicy {
    /// - 全屏 App：窗口矩形与某块屏幕完全重合 → 这块屏幕上有全屏 App
    /// - 台前调度开启：所有屏幕暂停（系统自己的缩略图与侧栏会跟覆盖层冲突）
    /// - 用户在设置里关掉的显示器
    static func pausedScreens(windows: [WindowInfo], screens: [(id: CGDirectDisplayID, rect: CGRect)],
                              pauseOnFullscreen: Bool, stageManagerActive: Bool,
                              disabledScreens: Set<CGDirectDisplayID>) -> Set<CGDirectDisplayID> {
        if stageManagerActive { return Set(screens.map(\.id)) }
        var paused = disabledScreens
        if pauseOnFullscreen {
            for screen in screens where windows.contains(where: { Geometry.approxEqual($0.bounds, screen.rect) }) {
                paused.insert(screen.id)
            }
        }
        return paused
    }
}
