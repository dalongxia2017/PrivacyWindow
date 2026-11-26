import AppKit
import Carbon

/// Carbon 的修饰键位（在 Swift 里是 Int），这里统一成 UInt32
private let cmdKey: UInt32 = UInt32(Carbon.cmdKey)
private let optionKey: UInt32 = UInt32(Carbon.optionKey)
private let controlKey: UInt32 = UInt32(Carbon.controlKey)
private let shiftKey: UInt32 = UInt32(Carbon.shiftKey)

/// 一组全局快捷键。`keyCode` 是 Carbon 的虚拟键码（与 NSEvent.keyCode 一致），
/// `modifiers` 是 Carbon 的修饰键位掩码（cmdKey / optionKey / controlKey / shiftKey）。
struct HotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    /// 默认 ⌥⌘P
    static let `default` = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: optionKey | cmdKey)

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if flags.contains(.command) { out |= cmdKey }
        if flags.contains(.option) { out |= optionKey }
        if flags.contains(.control) { out |= controlKey }
        if flags.contains(.shift) { out |= shiftKey }
        return out
    }

    /// 这些键单独按不会打出字，所以不带修饰键也能当快捷键
    private static let standaloneCodes: Set<UInt32> = [
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Help, kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
    ].map { UInt32($0) }.reduce(into: []) { $0.insert($1) }

    /// 至少要有一个修饰键，否则打字就会触发；单独的修饰键（⌘、⌥……）本身也不算快捷键
    var isValid: Bool {
        guard Self.keyNames[keyCode] != nil else { return false }
        return modifiers != 0 || Self.standaloneCodes.contains(keyCode)
    }

    var title: String {
        guard Self.keyNames[keyCode] != nil else { return "未设置" }
        var out = ""
        if modifiers & controlKey != 0 { out += "⌃" }
        if modifiers & optionKey != 0 { out += "⌥" }
        if modifiers & shiftKey != 0 { out += "⇧" }
        if modifiers & cmdKey != 0 { out += "⌘" }
        return out + Self.keyNames[keyCode]!
    }

    /// 虚拟键码 → 显示名（美式键盘布局）。这里没有的键不能设为快捷键。
    static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [:]
        func put(_ texts: [String], _ codes: [Int]) {
            precondition(texts.count == codes.count)
            for (text, code) in zip(texts, codes) { names[UInt32(code)] = text }
        }
        put(["A", "S", "D", "F", "H", "G", "J", "K", "L", "Q", "W", "E", "R", "Y", "T", "U", "I", "O", "P", "Z", "X", "C", "V", "B", "N", "M"],
            [kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_H, kVK_ANSI_G, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
             kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_Y, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_O,
             kVK_ANSI_P, kVK_ANSI_Z, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B, kVK_ANSI_N, kVK_ANSI_M])
        put(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
            [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0])
        put(["=", "-", "[", "]", "\\", ";", "'", "`", ",", ".", "/"],
            [kVK_ANSI_Equal, kVK_ANSI_Minus, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Backslash,
             kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_Grave, kVK_ANSI_Comma, kVK_ANSI_Period, kVK_ANSI_Slash])
        put(["空格", "回车", "⇥", "⌫", "⎋", "小键盘回车"],
            [kVK_Space, kVK_Return, kVK_Tab, kVK_Delete, kVK_Escape, kVK_ANSI_KeypadEnter])
        put(["Home", "End", "Page Up", "Page Down", "←", "→", "↑", "↓", "Help"],
            [kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Help])
        put(["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"],
            [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12])
        put(["F13", "F14", "F15", "F16", "F17", "F18", "F19"],
            [kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19])
        return names
    }()
}

/// 用 Carbon 的 RegisterEventHotKey 注册全局快捷键，不需要辅助功能权限。
/// （NSEvent.addGlobalMonitorForEvents 才需要辅助功能权限，所以不用它。）
final class HotKeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x5057574B   // 'PW HK' 里的 'PWWK'
    private let hotKeyID: UInt32 = 1
    private var handlerInstalled = false

    /// 按下快捷键时调用（主线程）
    var onPress: (() -> Void)?

    /// 最近一次注册的结果：nil 成功，否则是错误码
    private(set) var lastError: OSStatus?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard got == noErr, pressed.id == controller.hotKeyID else { return OSStatus(eventNotHandledErr) }
            controller.onPress?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        handlerInstalled = status == noErr
        lastError = status == noErr ? nil : status
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// 注册或替换当前快捷键；传 nil 表示注销。
    func register(_ hotKey: HotKey?) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        guard let hotKey, handlerInstalled else { return }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers,
                                         EventHotKeyID(signature: signature, id: hotKeyID),
                                         GetApplicationEventTarget(), 0, &ref)
        lastError = status == noErr ? nil : status
        hotKeyRef = status == noErr ? ref : nil
    }

    /// 注册失败时的中文说明
    var errorDescription: String? {
        switch lastError {
        case nil: return nil
        case OSStatus(eventHotKeyExistsErr): return "这个快捷键已经被其它程序占用"
        case OSStatus(eventHotKeyInvalidErr): return "这个快捷键无效"
        case let code?: return "注册快捷键失败（错误码 \(code)）"
        }
    }
}

/// 快捷键录入控件：点一下，然后按下想用的组合键。Esc 取消，⌫ 清除。
final class HotKeyRecorder: NSView {
    var hotKey: HotKey? {
        didSet { needsDisplay = true }
    }

    /// 录入结束时调用：参数是新快捷键，nil 表示已清除
    var onChange: ((HotKey?) -> Void)?

    private var recording = false

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        toolTip = "点一下，然后按下想用的组合键。Esc 取消，⌫ 清除快捷键。"
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        if recording {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
        let text = recording ? "请按下组合键…" : (hotKey?.title ?? "未设置")
        let color = (recording || hotKey == nil) ? NSColor.secondaryLabelColor : NSColor.labelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                                         .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return }
        switch event.keyCode {
        case UInt16(kVK_Escape):
            finish(with: hotKey)          // 取消，保持原样
        case UInt16(kVK_Delete), UInt16(kVK_ForwardDelete):
            finish(with: nil)             // 清除
        default:
            let candidate = HotKey(keyCode: UInt32(event.keyCode),
                                   modifiers: HotKey.carbonModifiers(from: event.modifierFlags))
            // 只按了修饰键、或不带修饰键的普通字符：提示无效，继续等待
            guard candidate.isValid else { NSSound.beep(); return }
            finish(with: candidate)
        }
    }

    private func finish(with result: HotKey?) {
        hotKey = result
        recording = false
        needsDisplay = true
        window?.makeFirstResponder(nil)
        onChange?(result)
    }
}
