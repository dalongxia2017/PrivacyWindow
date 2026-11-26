import AppKit

// 命令行开关：
//   --selftest               只跑纯逻辑自检，不弹窗口，退出码 0/1
//   --smoke <秒>             正常启动，但到点自动退出（无人值守冒烟测试）
//   --toggle / --enable / --disable
//                            通知正在运行的实例开关毛玻璃，然后自己退出
//   --mouse / --set / --trace / --open-settings
//                            调试参数，见 README「调试」。带这些参数启动时使用独立的
//                            defaults 域，不会读写用户的真实设置。

let arguments = CommandLine.arguments
let bundleID = "com.dalongxia2017.PrivacyWindow"

if arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

for command in ["toggle", "enable", "disable"] where arguments.contains("--\(command)") {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("\(bundleID).command"), object: nil,
        userInfo: ["command": command], deliverImmediately: true)
    exit(0)
}

let debugFlags: Set<String> = ["--mouse", "--set", "--trace", "--smoke", "--open-settings"]
let debug = arguments.contains { debugFlags.contains($0) }
let debugDefaults = UserDefaults(suiteName: "\(bundleID).debug")
let settings: SettingsStore = {
    if debug {
        // 每次调试启动都从默认设置出发
        debugDefaults?.removePersistentDomain(forName: "\(bundleID).debug")
        return SettingsStore(defaults: debugDefaults ?? .standard)
    }
    return .shared
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var smokeTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController(settings: settings)
        self.controller = controller
        controller.start()
        if arguments.contains("--open-settings") { controller.showSettings() }

        if let index = arguments.firstIndex(of: "--smoke"), index + 1 < arguments.count,
           let seconds = Double(arguments[index + 1]) {
            smokeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
                print("smoke: exiting after \(seconds)s")
                fflush(stdout)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        smokeTimer?.invalidate()
        if debug { debugDefaults?.removePersistentDomain(forName: "\(bundleID).debug") }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
