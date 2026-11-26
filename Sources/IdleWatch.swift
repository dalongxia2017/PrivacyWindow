import CoreGraphics
import Foundation

/// “鼠标和键盘都静止多久后重新模糊”的可选时长。0 = 关闭。
enum IdleTimeout {
    /// 设置窗口下拉框里的选项（秒）
    static let options: [TimeInterval] = [0, 10, 20, 30, 60, 120, 300]

    static func title(for seconds: TimeInterval) -> String {
        switch seconds {
        case 0: return "关闭"
        case ..<60: return "\(Int(seconds)) 秒"
        default: return "\(Int(seconds) / 60) 分钟"
        }
    }

    /// 存的是秒；不在选项里的值（旧版本手改过的 defaults）按最接近的较长一档处理
    static func normalized(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds > 0 else { return 0 }
        return options.first { $0 >= seconds } ?? options[options.count - 1]
    }
}

/// 静止判定，纯逻辑，可单测。
///
/// 鼠标位置变了、或者最近敲过键盘，就算“有操作”，重新计时。
/// 只看鼠标是不够的：打字的时候鼠标不动，正在编辑的窗口不能被糊掉。
struct IdleTracker {
    /// 多少秒没有操作算静止；<= 0 表示不启用
    var timeout: TimeInterval
    /// 敲键后这么久之内都算“刚才在打字”
    var keyActiveWindow: TimeInterval = 0.5

    private var lastActivityAt: TimeInterval = 0
    private var hasBaseline = false
    private(set) var isIdle = false

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// `mouse`：本帧的鼠标位置；`keyboardIdle`：距离上次按键的秒数（拿不到时传 nil）。
    /// 返回本帧是否处于静止状态。第一帧只记基线、不算静止。
    mutating func update(mouse: CGPoint, keyboardIdle: TimeInterval?, now: TimeInterval) -> Bool {
        guard timeout > 0 else {
            isIdle = false
            hasBaseline = false
            return false
        }
        let keyActive = keyboardIdle.map { $0 < keyActiveWindow } ?? false
        if !hasBaseline || mouse != lastMouse || keyActive {
            lastActivityAt = now
            hasBaseline = true
        }
        lastMouse = mouse
        isIdle = now - lastActivityAt >= timeout
        return isIdle
    }

    mutating func reset() {
        hasBaseline = false
        isIdle = false
    }

    private var lastMouse = CGPoint.zero

    /// 距离上一次按键过了多少秒。不需要任何权限：只问系统事件源“上次按键是什么时候”，不读按的是什么键。
    /// 调试参数 `--set keyActivity=0` 时返回 nil（跑自动化测试时不会被同时敲键盘的人干扰）。
    static var keyboardActivityEnabled = true

    static func keyboardIdleSeconds() -> TimeInterval? {
        guard keyboardActivityEnabled else { return nil }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }
}
