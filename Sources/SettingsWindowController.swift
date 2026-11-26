import AppKit
import UniformTypeIdentifiers

extension AppList {
    /// 控件的 identifier 存的就是名单名
    init?(of identifier: NSUserInterfaceItemIdentifier?) {
        guard let identifier else { return nil }
        self.init(rawValue: identifier.rawValue)
    }
}

/// 系统给的名字可能为空
private func screenName(_ screen: NSScreen) -> String {
    if !screen.localizedName.isEmpty { return screen.localizedName }
    let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    return "显示器 \(id)"
}

/// 支持把 App（.app）从访达 / 启动台 / 应用程序文件夹拖进来的表格。
final class AppListTableView: NSTableView {
    var onDropBundleID: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return false
        }
        var accepted = false
        for url in urls {
            if let id = Self.bundleID(at: url) {
                onDropBundleID?(id)
                accepted = true
            }
        }
        return accepted
    }

    private func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else { return false }
        return urls.contains { Self.bundleID(at: $0) != nil }
    }

    /// 拖进来的可能是 .app 本身，也可能是 App 包里的可执行文件
    static func bundleID(at url: URL) -> String? {
        if let id = Bundle(url: url)?.bundleIdentifier { return id }
        return Bundle(url: url.deletingLastPathComponent())?.bundleIdentifier
    }
}

/// 设置窗口：全部代码布局，没有 xib / storyboard。
final class SettingsWindowController: NSObject {
    let settings: SettingsStore
    let window: NSWindow

    private let minLabelWidth: CGFloat = 96
    private let tableHeight: CGFloat = 110
    private var materialPopup = NSPopUpButton()
    private var desktopPopup = NSPopUpButton()
    private var idlePopup = NSPopUpButton()
    private var idleField = NSTextField()
    private var fullscreenCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var stageManagerCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var lowPowerCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var launchCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var hotkeyCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var invertCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var whitelistTitle = NSTextField(labelWithString: "")
    private var whitelistHint = NSTextField(wrappingLabelWithString: "")
    private var hotkeyRecorder = HotKeyRecorder(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
    private var displayStack = NSStackView()
    private var displayChecks: [(check: NSButton, id: CGDirectDisplayID)] = []
    private var tables: [AppList: AppListTableView] = [:]
    private var dimSlider = NSSlider()
    private var animSlider = NSSlider()
    private var debounceSlider = NSSlider()
    private var dimLabel = NSTextField(labelWithString: "")
    private var animLabel = NSTextField(labelWithString: "")
    private var debounceLabel = NSTextField(labelWithString: "")
    private var names: [String: String] = [:]

    init(settings: SettingsStore) {
        self.settings = settings
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 590),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "隐私窗口 设置"
        window.isReleasedWhenClosed = false
        window.contentView = buildContent()
        fitWindowToContent()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: SettingsStore.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        syncControls()
    }

    func show() {
        syncControls()
        NSApp.activate(ignoringOtherApps: true)
        window.centerIfOffscreen()
        window.makeKeyAndOrderFront(nil)
    }

    /// 窗口高度跟着内容走：固定高度的话，字体或系统语言不同时底部几行会被裁掉
    private func fitWindowToContent() {
        guard let fit = window.contentView?.fittingSize else { return }
        window.setContentSize(NSSize(width: max(480, fit.width), height: max(590, fit.height)))
    }

    // MARK: - 布局

    private func buildContent() -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 590))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: 22),
        ])

        // 材质
        materialPopup.addItems(withTitles: BlurMaterial.allCases.map(\.title))
        materialPopup.target = self
        materialPopup.action = #selector(materialChanged)
        stack.addArrangedSubview(row("材质", materialPopup))

        // 暗化
        dimSlider = makeSlider(min: 0, max: 0.9, action: #selector(dimChanged))
        stack.addArrangedSubview(row("暗化", sliderRow(dimSlider, valueLabel: dimLabel)))

        // 动画时长
        animSlider = makeSlider(min: 80, max: 250, action: #selector(animChanged))
        stack.addArrangedSubview(row("切换动画", sliderRow(animSlider, valueLabel: animLabel)))

        // 防抖
        debounceSlider = makeSlider(min: 0, max: 100, action: #selector(debounceChanged))
        stack.addArrangedSubview(row("焦点防抖", sliderRow(debounceSlider, valueLabel: debounceLabel)))

        // 桌面行为
        desktopPopup.addItems(withTitles: DesktopBehavior.allCases.map(\.title))
        desktopPopup.target = self
        desktopPopup.action = #selector(desktopChanged)
        stack.addArrangedSubview(row("鼠标在桌面", desktopPopup))

        // 静止后重新模糊
        idlePopup.addItems(withTitles: IdleTimeout.options.map(IdleTimeout.title) + [Self.customTitle])
        idlePopup.target = self
        idlePopup.action = #selector(idleChanged)
        idlePopup.toolTip = "鼠标和键盘都这么久没动，清晰的窗口重新变模糊；动一下就恢复"
        idleField = NSTextField(string: "\(Int(IdleTimeout.customDefault)) 秒")
        idleField.target = self
        idleField.action = #selector(idleFieldChanged)
        idleField.alignment = .right
        idleField.toolTip = "手动输入秒数（1 秒 – 24 小时），回车生效"
        idleField.widthAnchor.constraint(equalToConstant: 86).isActive = true
        idleField.translatesAutoresizingMaskIntoConstraints = false
        idleField.isHidden = true
        let idleRow = NSStackView(views: [idlePopup, idleField])
        idleRow.orientation = .horizontal
        idleRow.spacing = 8
        idleRow.alignment = .centerY
        stack.addArrangedSubview(row("静止后重新模糊", idleRow))

        // 快捷键
        hotkeyCheck = NSButton(checkboxWithTitle: "启用快捷键", target: self, action: #selector(hotkeyEnabledChanged))
        hotkeyCheck.toolTip = "按一下开关毛玻璃，不需要辅助功能权限"
        hotkeyRecorder.hotKey = settings.hotkey
        hotkeyRecorder.onChange = { [weak self] key in self?.hotkeyRecorded(key) }
        stack.addArrangedSubview(row("快捷键", hotkeyRow()))

        // 三个开关
        fullscreenCheck = NSButton(checkboxWithTitle: "某块屏幕上有全屏 App 时，该屏幕暂停覆盖",
                                   target: self, action: #selector(fullscreenChanged))
        stack.addArrangedSubview(fullscreenCheck)
        stageManagerCheck = NSButton(checkboxWithTitle: "「台前调度」开启时暂停覆盖",
                                     target: self, action: #selector(stageManagerChanged))
        stack.addArrangedSubview(stageManagerCheck)
        lowPowerCheck = NSButton(checkboxWithTitle: "低性能模式（不用毛玻璃，只盖一层暗色遮罩）",
                                 target: self, action: #selector(lowPowerChanged))
        stack.addArrangedSubview(lowPowerCheck)

        // 开机自启
        launchCheck = NSButton(checkboxWithTitle: "登录时自动启动", target: self, action: #selector(launchChanged))
        launchCheck.toolTip = "App 挪了位置（例如移到「应用程序」）后需要重新勾选一次"
        stack.addArrangedSubview(row("开机自启", launchCheck))

        // 显示器
        displayStack.orientation = .vertical
        displayStack.alignment = .leading
        displayStack.spacing = 4
        stack.addArrangedSubview(row("显示器", displayStack))
        rebuildDisplayChecks()

        stack.addArrangedSubview(separator())

        // 名单
        for list in AppList.allCases {
            let title = NSTextField(labelWithString: list.title)
            title.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            stack.addArrangedSubview(title)
            if list == .whitelist {
                // 反转白名单：列表里的 App 从“永远清晰”变成“只有它们会被盖”
                invertCheck = NSButton(checkboxWithTitle: "反转：只给列表里的 App 盖毛玻璃（其余 App 不处理）",
                                       target: self, action: #selector(invertWhitelistChanged))
                stack.addArrangedSubview(invertCheck)
            }
            stack.addArrangedSubview(buildTable(list))
            stack.addArrangedSubview(buildListButtons(list))
            let text = hint(list.hint)
            if list == .whitelist {
                whitelistTitle = title
                whitelistHint = text
            }
            stack.addArrangedSubview(text)
        }

        return content
    }

    private func separator() -> NSView {
        let separator = NSBox()
        separator.boxType = .separator
        // 分隔线要撑满宽度
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(greaterThanOrEqualToConstant: 428).isActive = true
        return separator
    }

    private func hint(_ text: String) -> NSTextField {
        let hint = NSTextField(wrappingLabelWithString: text)
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.preferredMaxLayoutWidth = 420
        return hint
    }

    /// 反转开关只改白名单这一块的标题和说明，列表本身（bundle id）不动
    private func syncWhitelistWording() {
        let inverted = settings.invertWhitelist
        invertCheck.state = inverted ? .on : .off
        whitelistTitle.stringValue = inverted ? AppList.invertedWhitelistTitle : AppList.whitelist.title
        whitelistHint.stringValue = inverted ? AppList.invertedWhitelistHint : AppList.whitelist.hint
    }

    private func buildTable(_ list: AppList) -> NSView {
        let table = AppListTableView(frame: .zero)
        table.identifier = NSUserInterfaceItemIdentifier(list.rawValue)
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "应用"
        nameColumn.width = 210
        let idColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundle"))
        idColumn.title = "Bundle ID"
        idColumn.width = 220
        table.addTableColumn(nameColumn)
        table.addTableColumn(idColumn)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // 让表格随窗口宽度伸展
        for column in table.tableColumns { column.resizingMask = .autoresizingMask }
        table.onDropBundleID = { [weak self] id in
            guard let self else { return }
            self.settings.add(id, to: list)
        }
        tables[list] = table

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 428, height: tableHeight))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 428),
            scroll.heightAnchor.constraint(equalToConstant: tableHeight),
        ])
        return scroll
    }

    private func buildListButtons(_ list: AppList) -> NSView {
        let add = NSButton(title: "添加…", target: self, action: #selector(addClicked(_:)))
        add.identifier = NSUserInterfaceItemIdentifier(list.rawValue)
        let remove = NSButton(title: "移除所选", target: self, action: #selector(removeClicked(_:)))
        remove.identifier = NSUserInterfaceItemIdentifier(list.rawValue)
        let buttons = NSStackView(views: [add, remove])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        return buttons
    }

    private func row(_ title: String, _ control: NSView, label: String? = nil) -> NSView {
        let text = NSTextField(labelWithString: label ?? title)
        text.alignment = .right
        text.widthAnchor.constraint(equalToConstant: minLabelWidth).isActive = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [text, control])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    private func hotkeyRow() -> NSView {
        hotkeyRecorder.translatesAutoresizingMaskIntoConstraints = false
        hotkeyRecorder.widthAnchor.constraint(equalToConstant: 150).isActive = true
        hotkeyRecorder.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let row = NSStackView(views: [hotkeyRecorder, hotkeyCheck])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    private func sliderRow(_ slider: NSSlider, valueLabel: NSTextField) -> NSView {
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let row = NSStackView(views: [slider, valueLabel])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        valueLabel.widthAnchor.constraint(equalToConstant: 76).isActive = true
        return row
    }

    private func makeSlider(min: Double, max: Double, action: Selector) -> NSSlider {
        let slider = NSSlider(value: min, minValue: min, maxValue: max, target: self, action: action)
        slider.isContinuous = true
        return slider
    }

    /// 每块显示器一个勾选框；没勾的屏幕完全不覆盖
    private func rebuildDisplayChecks() {
        for view in displayStack.arrangedSubviews { displayStack.removeArrangedSubview(view) }
        displayChecks = []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            let name = screenName(screen)
            let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
            let check = NSButton(checkboxWithTitle: "\(name)（\(size)）", target: self, action: #selector(displayChanged(_:)))
            check.identifier = NSUserInterfaceItemIdentifier(String(id))
            check.state = settings.isScreenEnabled(id) ? .on : .off
            displayStack.addArrangedSubview(check)
            displayChecks.append((check, id))
        }
    }

    // MARK: - 动作

    @objc private func materialChanged() {
        let index = materialPopup.indexOfSelectedItem
        if BlurMaterial.allCases.indices.contains(index) { settings.material = BlurMaterial.allCases[index] }
    }

    @objc private func dimChanged() {
        settings.dimAlpha = (dimSlider.doubleValue * 20).rounded() / 20
    }

    @objc private func animChanged() {
        settings.animationMS = (animSlider.doubleValue / 10).rounded() * 10
    }

    @objc private func debounceChanged() {
        settings.debounceMS = (debounceSlider.doubleValue / 10).rounded() * 10
    }

    private static let customTitle = "自定义…"

    @objc private func idleChanged() {
        let index = idlePopup.indexOfSelectedItem
        if IdleTimeout.options.indices.contains(index) {
            settings.idleTimeout = IdleTimeout.options[index]
        } else if !IdleTimeout.isCustom(settings.idleTimeout) {
            // 刚从预设切到“自定义”：先用输入框里现在的数（或默认值），用户改了再覆盖
            settings.idleTimeout = IdleTimeout.parse(idleField.stringValue) ?? IdleTimeout.customDefault
        }
        syncIdleControls()
        if idlePopup.indexOfSelectedItem == IdleTimeout.options.count {
            window.makeFirstResponder(idleField)
        }
    }

    /// 输入框里改了数：是正整数才生效，否则保持原值（下一次 syncControls 会把文字改回去）
    @objc private func idleFieldChanged() {
        if let seconds = IdleTimeout.parse(idleField.stringValue) {
            settings.idleTimeout = seconds
        }
        syncControls()
    }

    private func syncIdleControls() {
        let seconds = settings.idleTimeout
        idlePopup.selectItem(at: IdleTimeout.options.firstIndex(of: seconds) ?? IdleTimeout.options.count)
        idleField.isHidden = !IdleTimeout.isCustom(seconds)
        idleField.stringValue = "\(Int(IdleTimeout.isCustom(seconds) ? seconds : IdleTimeout.customDefault))"
    }

    /// `--open-settings` 用：下拉框选中的是哪一项、输入框露出来没有、里面是什么
    var debugIdleControls: String {
        let title = idlePopup.titleOfSelectedItem ?? "none"
        return "popup=\(title) field=\(idleField.isHidden ? "hidden" : "shown"):\(idleField.stringValue)"
    }

    @objc private func desktopChanged() {
        let index = desktopPopup.indexOfSelectedItem
        if DesktopBehavior.allCases.indices.contains(index) { settings.desktopBehavior = DesktopBehavior.allCases[index] }
    }

    @objc private func fullscreenChanged() {
        settings.pauseOnFullscreen = fullscreenCheck.state == .on
    }

    @objc private func stageManagerChanged() {
        settings.pauseOnStageManager = stageManagerCheck.state == .on
    }

    @objc private func lowPowerChanged() {
        settings.lowPower = lowPowerCheck.state == .on
    }

    @objc private func invertWhitelistChanged() {
        settings.invertWhitelist = invertCheck.state == .on
    }

    @objc private func hotkeyEnabledChanged() {
        settings.hotkeyEnabled = hotkeyCheck.state == .on
    }

    private func hotkeyRecorded(_ key: HotKey?) {
        guard let key else {
            // 清除了快捷键：功能一起关掉，免得留下一个不响应的开关
            settings.hotkeyEnabled = false
            return
        }
        settings.hotkey = key
        settings.hotkeyEnabled = true
    }

    @objc private func launchChanged() {
        let wanted = launchCheck.state == .on
        do {
            try LaunchAtLogin.setEnabled(wanted)
        } catch {
            let alert = NSAlert()
            alert.messageText = "开机自启没有设置成功"
            alert.informativeText = LaunchAtLogin.errorDescription(error)
            alert.runModal()
        }
        syncControls()
    }

    @objc private func displayChanged(_ check: NSButton) {
        guard let id = check.identifier.flatMap({ CGDirectDisplayID($0.rawValue) }) else { return }
        var disabled = settings.disabledScreens
        if check.state == .on { disabled.removeAll { $0 == id } } else if !disabled.contains(id) { disabled.append(id) }
        settings.disabledScreens = disabled
    }

    @objc private func addClicked(_ sender: NSButton) {
        guard let list = AppList(of: sender.identifier) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = AppListTableView.bundleID(at: url) { settings.add(id, to: list) }
        }
    }

    @objc private func removeClicked(_ sender: NSButton) {
        guard let list = AppList(of: sender.identifier),
              let table = tables[list], table.selectedRow >= 0 else { return }
        let ids = settings.bundleIDs(in: list)
        guard table.selectedRow < ids.count else { return }
        settings.remove(ids[table.selectedRow], from: list)
    }

    // MARK: - 刷新

    /// 显示器插拔后重建勾选框
    @objc func screensChanged() {
        guard displayChecks.map(\.id) != NSScreen.screens.compactMap({
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }) else { return }
        rebuildDisplayChecks()
        fitWindowToContent()
    }

    /// 给 `--open-settings` 的自检用：每块屏一行“id:开/关”
    /// 设置窗口永远清晰：可见时把它的窗口 id 交给窗口快照，按 z 序留在列表里当“洞”。
    var alwaysClearWindowIDs: Set<CGWindowID> {
        guard window.isVisible else { return [] }
        return [CGWindowID(window.windowNumber)]
    }

    /// 设置窗口在 CG 坐标系里的矩形（不可见时为 nil）
    var alwaysClearRect: CGRect? {
        guard window.isVisible else { return nil }
        return Geometry.nsToCG(window.frame, mainHeight: Geometry.mainCG.height)
    }

    func debugScreenChecks() -> String {
        displayChecks.map { "\($0.id):\($0.check.state == .on ? "on" : "off")" }.joined(separator: ",")
    }

    @objc private func settingsChanged() {
        syncControls()
    }

    // 程序自己改控件的 state / doubleValue 不会再触发动作，所以不需要防重入标记
    private func syncControls() {
        materialPopup.selectItem(at: BlurMaterial.allCases.firstIndex(of: settings.material) ?? 0)
        desktopPopup.selectItem(at: DesktopBehavior.allCases.firstIndex(of: settings.desktopBehavior) ?? 0)
        syncIdleControls()
        fullscreenCheck.state = settings.pauseOnFullscreen ? .on : .off
        stageManagerCheck.state = settings.pauseOnStageManager ? .on : .off
        lowPowerCheck.state = settings.lowPower ? .on : .off
        syncWhitelistWording()
        hotkeyCheck.state = settings.hotkeyEnabled ? .on : .off
        hotkeyRecorder.hotKey = settings.hotkey
        launchCheck.state = LaunchAtLogin.state == .disabled ? .off : .on
        dimSlider.doubleValue = settings.dimAlpha
        animSlider.doubleValue = settings.animationMS
        debounceSlider.doubleValue = settings.debounceMS
        dimLabel.stringValue = "\(Int(settings.dimAlpha * 100))%"
        animLabel.stringValue = "\(Int(settings.animationMS)) ms"
        debounceLabel.stringValue = "\(Int(settings.debounceMS)) ms"
        for (check, id) in displayChecks { check.state = settings.isScreenEnabled(id) ? .on : .off }
        for table in tables.values { table.reloadData() }
    }
}

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let list = AppList(of: tableView.identifier) else { return 0 }
        return settings.bundleIDs(in: list).count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let list = AppList(of: tableView.identifier) else { return nil }
        let ids = settings.bundleIDs(in: list)
        guard row < ids.count else { return nil }
        let id = ids[row]
        let text = tableColumn?.identifier.rawValue == "bundle" ? id : displayName(id)
        let identifier = NSUserInterfaceItemIdentifier("cell.\(tableColumn?.identifier.rawValue ?? "")")
        let field = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.stringValue = text
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = text
        return field
    }

    private func displayName(_ bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) == nil ? nil : $0 }
            .flatMap { Bundle(url: $0)?.localizedInfoDictionary?["CFBundleName"] as? String }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? "（未找到）"
        names[bundleID] = name
        return name
    }
}

extension NSWindow {
    /// 第一次打开时居中；用户挪过之后保持在原位
    func centerIfOffscreen() {
        guard !isVisible else { return }
        let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
        if !onAnyScreen || frame.origin == .zero { center() }
    }
}
