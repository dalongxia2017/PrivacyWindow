import AppKit

/// 菜单栏图标 + 下拉菜单：开关、设置、退出。
final class MenuBarController: NSObject {
    private let settings: SettingsStore
    private let statusItem: NSStatusItem
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggleClicked), keyEquivalent: "")
    private let onSettings: () -> Void

    init(settings: SettingsStore, onSettings: @escaping () -> Void) {
        self.settings = settings
        self.onSettings = onSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(settingsClicked), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出隐私窗口", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu

        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: SettingsStore.didChange, object: nil)
        refresh()
    }

    var isEnabled: Bool { settings.enabled }

    /// 状态栏按钮所在窗口的 frame（全局坐标）。按钮挂到了菜单栏上才有。
    var statusItemFrame: NSRect? { statusItem.button?.window?.frame }

    @objc private func toggleClicked() {
        settings.toggleEnabled()
    }

    @objc private func settingsClicked() {
        onSettings()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    @objc private func refresh() {
        let on = settings.enabled
        let hotkey = settings.activeHotKey
        toggleItem.title = (on ? "关闭毛玻璃" : "开启毛玻璃") + (hotkey.map { "（\($0.title)）" } ?? "")
        toggleItem.state = on ? .on : .off
        toggleItem.keyEquivalent = ""
        let symbol = on ? "eye.slash" : "eye"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "隐私窗口")
        statusItem.button?.image = image
    }
}
