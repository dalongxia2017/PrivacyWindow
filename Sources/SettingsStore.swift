import AppKit

/// 可选的系统材质。实测各材质的模糊程度一致，差别只在色调与明暗，
/// 所以设置项叫“材质”而不是“模糊强度”。
enum BlurMaterial: String, CaseIterable {
    case hudWindow
    case fullScreenUI
    case popover
    case titlebar
    case underWindowBackground

    var effect: NSVisualEffectView.Material {
        switch self {
        case .hudWindow: return .hudWindow
        case .fullScreenUI: return .fullScreenUI
        case .popover: return .popover
        case .titlebar: return .titlebar
        case .underWindowBackground: return .underWindowBackground
        }
    }

    var title: String {
        switch self {
        case .hudWindow: return "浅灰磨砂（HUD）"
        case .fullScreenUI: return "明亮（全屏面板）"
        case .popover: return "轻透（弹窗）"
        case .titlebar: return "中性（标题栏）"
        case .underWindowBackground: return "深色（窗口底衬）"
        }
    }
}

/// 鼠标不在任何窗口上（桌面、菜单栏、Dock）时的行为。
enum DesktopBehavior: String, CaseIterable {
    /// 所有窗口都盖毛玻璃
    case blurAll
    /// 保持上一个焦点窗口清晰
    case keepLast

    var title: String {
        switch self {
        case .blurAll: return "全部模糊"
        case .keepLast: return "保持上一个清晰"
        }
    }
}

/// 名单的两种语义。
enum AppList: String, CaseIterable {
    /// 永远清晰：不会被盖，鼠标移到它上面也不抢走焦点
    case whitelist
    /// 永远模糊：鼠标移到它上面也不会变清晰
    case blacklist

    var title: String {
        switch self {
        case .whitelist: return "白名单 · 永远清晰"
        case .blacklist: return "黑名单 · 永远模糊"
        }
    }

    var hint: String {
        switch self {
        case .whitelist: return "这些 App 的窗口不盖毛玻璃，也不会成为焦点（适合视频播放器、录屏预览）。"
        case .blacklist: return "这些 App 的窗口始终盖毛玻璃，鼠标移上去也不会变清晰（适合密码管理器、聊天软件）。"
        }
    }

    /// 白名单反转时（`SettingsStore.invertWhitelist`）的含义：只有列表里的 App 会被盖，其余一概不处理。
    static let invertedWhitelistTitle = "白名单 · 只模糊列表里的 App"
    static let invertedWhitelistHint = "只有这些 App 的窗口会被盖毛玻璃（鼠标移上去变清晰，和平时一样）；列表以外的 App 永远不盖。"
}

/// 所有设置都落在 UserDefaults，任一属性改动后广播 `SettingsStore.didChange`。
final class SettingsStore {
    static let shared = SettingsStore()
    static let didChange = Notification.Name("PrivacyWindow.SettingsDidChange")

    private let defaults: UserDefaults
    private let prefix = "pw."

    var enabled: Bool { didSet { save(enabled, "enabled") } }
    var material: BlurMaterial { didSet { save(material.rawValue, "material") } }
    /// 额外暗化，0...0.9
    var dimAlpha: Double { didSet { save(dimAlpha, "dimAlpha") } }
    /// 焦点切换的淡入淡出时长，毫秒，80...250
    var animationMS: Double { didSet { save(animationMS, "animationMS") } }
    /// 焦点防抖，毫秒，0...100
    var debounceMS: Double { didSet { save(debounceMS, "debounceMS") } }
    /// 白名单：永远清晰的 App（bundle id）
    var whitelist: [String] { didSet { save(whitelist, "whitelist") } }
    /// 黑名单：永远模糊的 App（bundle id）
    var blacklist: [String] { didSet { save(blacklist, "blacklist") } }
    /// 反转白名单：true = 只有白名单里的 App 会被盖（鼠标移上去仍会变清晰），列表以外的 App 一概不处理
    var invertWhitelist: Bool { didSet { save(invertWhitelist, "invertWhitelist") } }
    var desktopBehavior: DesktopBehavior { didSet { save(desktopBehavior.rawValue, "desktopBehavior") } }
    /// 某屏有全屏窗口时该屏暂停
    var pauseOnFullscreen: Bool { didSet { save(pauseOnFullscreen, "pauseOnFullscreen") } }
    /// 台前调度开启时全部暂停
    var pauseOnStageManager: Bool { didSet { save(pauseOnStageManager, "pauseOnStageManager") } }
    /// 低性能模式：不用毛玻璃，只盖一层暗色遮罩
    var lowPower: Bool { didSet { save(lowPower, "lowPower") } }
    /// 不做覆盖的屏幕（显示器 id）
    var disabledScreens: [CGDirectDisplayID] { didSet { save(disabledScreens.map(Int.init), "disabledScreens") } }
    var hotkeyEnabled: Bool { didSet { save(hotkeyEnabled, "hotkeyEnabled") } }
    var hotkey: HotKey { didSet { save(Int(hotkey.keyCode), "hotkeyCode"); save(Int(hotkey.modifiers), "hotkeyModifiers") } }

    /// 低性能模式下不模糊，遮罩要够深才挡得住文字
    static let lowPowerMinDim: Double = 0.5

    /// 覆盖层实际用的暗化
    var overlayDimAlpha: Double { lowPower ? max(dimAlpha, Self.lowPowerMinDim) : dimAlpha }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func get(_ key: String) -> Any? { defaults.object(forKey: "pw." + key) }

        enabled = get("enabled") as? Bool ?? true
        material = BlurMaterial(rawValue: get("material") as? String ?? "") ?? .hudWindow
        dimAlpha = get("dimAlpha") as? Double ?? 0.25
        animationMS = get("animationMS") as? Double ?? 150
        debounceMS = get("debounceMS") as? Double ?? 40
        // 旧版本只有一个“排除 App”名单，语义就是白名单
        whitelist = get("whitelist") as? [String] ?? get("excludedBundleIDs") as? [String] ?? []
        blacklist = get("blacklist") as? [String] ?? []
        invertWhitelist = get("invertWhitelist") as? Bool ?? false
        desktopBehavior = DesktopBehavior(rawValue: get("desktopBehavior") as? String ?? "") ?? .keepLast
        pauseOnFullscreen = get("pauseOnFullscreen") as? Bool ?? true
        pauseOnStageManager = get("pauseOnStageManager") as? Bool ?? true
        lowPower = get("lowPower") as? Bool ?? false
        disabledScreens = (get("disabledScreens") as? [Int] ?? []).map { CGDirectDisplayID($0) }
        hotkeyEnabled = get("hotkeyEnabled") as? Bool ?? true
        let keyCode = get("hotkeyCode") as? Int ?? Int(HotKey.default.keyCode)
        let modifiers = get("hotkeyModifiers") as? Int ?? Int(HotKey.default.modifiers)
        hotkey = HotKey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    var animationDuration: TimeInterval { animationMS / 1000 }
    var debounce: TimeInterval { debounceMS / 1000 }

    /// 实际生效的快捷键；关闭快捷键功能时为 nil
    var activeHotKey: HotKey? { hotkeyEnabled ? hotkey : nil }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: prefix + key)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func toggleEnabled() { enabled.toggle() }

    func bundleIDs(in list: AppList) -> [String] {
        switch list {
        case .whitelist: return whitelist
        case .blacklist: return blacklist
        }
    }

    func add(_ bundleID: String, to list: AppList) {
        // 一个 App 不能同时在两个名单里
        if list == .whitelist { blacklist.removeAll { $0 == bundleID } } else { whitelist.removeAll { $0 == bundleID } }
        var ids = bundleIDs(in: list)
        guard !ids.contains(bundleID) else { return }
        ids.append(bundleID)
        set(ids, in: list)
    }

    func remove(_ bundleID: String, from list: AppList) {
        var ids = bundleIDs(in: list)
        guard ids.contains(bundleID) else { return }
        ids.removeAll { $0 == bundleID }
        set(ids, in: list)
    }

    private func set(_ ids: [String], in list: AppList) {
        switch list {
        case .whitelist: whitelist = ids
        case .blacklist: blacklist = ids
        }
    }

    func isScreenEnabled(_ id: CGDirectDisplayID) -> Bool { !disabledScreens.contains(id) }
}
