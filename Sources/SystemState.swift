import AppKit
import ServiceManagement

/// 台前调度（Stage Manager）。没有公开 API 可以查询它是否开启，
/// 只能读系统设置的偏好域 `com.apple.WindowManager`。这不触发任何授权弹窗。
enum StageManager {
    static let preferencesDomain = "com.apple.WindowManager"
    static let enabledKey = "GloballyEnabled"

    /// 系统设置里「台前调度」的开关。读不到时返回 nil（当作没开）。
    /// 用 CFPreferencesCopyAppValue 而不是 UserDefaults(suiteName:)：后者会缓存，别的进程改了设置不会更新。
    private static var reader: (String) -> Bool? = readFromPreferences

    static func isEnabled(preferencesDomain: String = preferencesDomain) -> Bool? {
        reader(preferencesDomain)
    }

    /// 自检用：换成假的读取函数
    static func overrideReader(forTest reader: @escaping (String) -> Bool?) {
        self.reader = reader
    }

    private static func readFromPreferences(_ domain: String) -> Bool? {
        guard let value = CFPreferencesCopyAppValue(enabledKey as CFString, domain as CFString) else {
            return nil
        }
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        return nil
    }

    /// 每 `interval` 秒查一次的缓存。查询本身很快，但没必要每帧做。
    final class Monitor {
        private let interval: TimeInterval
        private var cached: Bool?
        private var lastCheck: TimeInterval = -.infinity

        init(interval: TimeInterval = 2) {
            self.interval = interval
        }

        func isEnabled(now: TimeInterval) -> Bool {
            if now - lastCheck >= interval {
                lastCheck = now
                cached = StageManager.isEnabled()
            }
            return cached == true
        }
    }
}

/// 开机自启：macOS 13+ 的 SMAppService。注册的是「这个 App 本身」，
/// 所以 App 挪了位置（比如从 build/ 移到「应用程序」）需要重新勾选。
enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        /// 系统等待用户在「系统设置 → 登录项」里批准
        case needsApproval
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    static func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func errorDescription(_ error: Error) -> String {
        "设置开机自启失败：\(error.localizedDescription)。也可以手动到「系统设置 → 通用 → 登录项」里添加。"
    }
}
