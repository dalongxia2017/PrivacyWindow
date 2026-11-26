# AGENTS.md — 隐私窗口（PrivacyWindow）

给 AI 代理和新接手者的工程说明。面向用户的部分看 [README.md](README.md)。设计依据、实测数据、
还没验证的事、完整计划都在本文；同类产品和参考资料在文末「同类与参考」。

## 这是什么

macOS 菜单栏工具：鼠标悬停的窗口保持清晰，同屏其它普通窗口盖一层毛玻璃。零权限、不截屏、不联网、只用公开 API。
约 2200 行 Swift，**没有 Xcode 工程、没有第三方依赖、没有 Package.swift**，直接 `swiftc` 编译 `Sources/*.swift`。

现有工具（FocalVeil、HazeOver、Blurred、Hush）都是把非活动窗口变暗 / 模糊，焦点跟**键盘 / 前台 App**；
跟**鼠标悬停**走的没有先例。本项目和它们共用的技术是“每屏一个鼠标穿透的覆盖层 + `NSVisualEffectView.blending == .behindWindow`”。

## 硬性约束

- **只用公开 API。** 不引入 `CAFilter` / `CABackdropLayer` / `CGS*` 等私有接口（理由见下面「设计依据」；连续模糊半径如果做，只能是默认关闭的实验开关，失效要能退回公开 API）。
- **零权限。** 不调用任何会触发系统授权弹窗的 API：不申请辅助功能（`AXIsProcessTrusted`）、不申请屏幕录制、不读窗口标题（`kCGWindowName` 是唯一需要录屏权限的字段，本程序不读）。新增系统调用前先对照下面「权限对照」。
- **覆盖层必须穿透鼠标。** 所有覆盖层窗口 `ignoresMouseEvents = true`；不要给覆盖层加任何会接收事件的子视图。
- **不动别人的窗口。** 只读 `CGWindowListCopyWindowInfo`，不置前、不移动、不改 alpha。
- 不新增第三方依赖，不改成 Xcode 工程 / SPM，除非用户明确要求。
- **开机自启只走 `SMAppService.mainApp`**，不要手写 `com.apple.loginItems` 或往 `~/Library/LaunchAgents` 里放文件。
- **台前调度只读不写**：`CFPreferencesCopyAppValue("GloballyEnabled", "com.apple.WindowManager")`，不要调 `CFPreferencesSetAppValue`。测试里要注入开关用 `StageManager.overrideReader(forTest:)` 或 `--set stageManager=1`。
- 设置项只放 `UserDefaults`（键前缀 `pw.`），改动后必须 post `SettingsStore.didChange`，各模块监听这个通知而不是互相引用。
- 碰 AppKit 的代码必须在主线程。目前没有后台回调，但如果以后加了（例如 ScreenCaptureKit），回调里要先 `DispatchQueue.main.async`，否则会崩在 `NSWindow should only be instantiated on the main thread`（SCK 的 completion 在后台队列）。
- **不要走“截屏 + 自己算模糊”的路线**（ScreenCaptureKit / Core Image）。它要屏幕录制权限，而实测截到的画面和屏幕上真正合成出来的不一致（alpha 为 0 的覆盖层被采成纯色，基线两次运行方差 1890 / 3586 不稳定）。`CGWindowListCreateImage` 在本 SDK 已经不可用（`Please use ScreenCaptureKit instead`）。
- **不要把“材质”叫成“模糊强度”，也不要承诺强度可调。** 7 种系统材质的模糊程度一样（方差都 ≤ 11），只差色调。想加强效果只能加暗化。

## 设计依据（调研结论）

### 最初的设想 vs 实测

| 最初的设想 | 实际情况 | 现在的做法 |
|---|---|---|
| 模糊强度 / 暗化 / 材质都可调 | 系统材质的模糊半径**不可调**，7 种材质方差都 ≤ 11 | “材质（色调）+ 暗化”两个选项；连续半径只有私有 `CAFilter` 或截屏自算 |
| 切换动画 120–180 ms 防闪烁 | 还要**防抖**：划过窗口边缘 / 缝隙会高频切换 | 焦点判定加防抖（默认 40 ms）；旧焦点淡出与新焦点淡入并行 |
| 跟随延迟 < 50 ms | 窗口列表一次 0.26 ms，余量很大 | 跟随时直接改 frame、不做动画；只有焦点切换做 alpha 动画 |
| 读窗口信息可能要录屏权限 | **不要**：id / bounds / layer / pid 都给，只有标题受限 | 不读标题 → 零权限 |
| 监听窗口移动可能要辅助功能 | 轮询足够 | 60 Hz 轮询 |
| `NSVisualEffectView` 比 Core Image 省电 | 对，而且是唯一零权限方案 | 默认路径 |
| 低性能 = 半透明暗色遮罩 | 0.45 黑遮罩方差仍 4900（清晰 16256），**文字可读** | 低性能模式暗化不低于 50 %（`lowPowerMinDim`）；它省电、助专注，但挡不住刻意凑近看 |

### 悬停聚焦会“抖”

鼠标在窗口边界或经过小窗口（Finder 工具面板、悬浮歌词、输入法候选条）时焦点高频变化。靠四件事压住：最小尺寸 80 pt（`WindowSnapshot.minSize`）、防抖（`FocusResolver`）、磁滞（`DesktopBehavior.keepLast`）、白 / 黑名单。

### 四条技术路线

| 路线 | 连续强度 | 权限 | 决定 |
|---|---|---|---|
| A 公开 API：覆盖层 + `NSVisualEffectView` | 否 | 零 | 默认 |
| B 私有 `CABackdropLayer` + `CAFilter` | 是 | 零 | 以后做实验开关（参考 MaterialView；MAS 不可用，系统升级可能失效） |
| C ScreenCaptureKit 截屏自算 | 是 | 屏幕录制 | 不做 |
| D 纯暗色遮罩 | — | 零 | 设置里的“低性能模式” |

叠多层 `NSVisualEffectView` 来模拟“更糊”效果有限、GPU 成本线性增加，不推荐。

### 本机实测（macOS 27.2 / Apple Silicon）

靶窗口 = 10 pt 黑白条纹，`screencapture` 截内部算亮度方差，清晰 ≈ 16256（平均亮度 127.5）。

| 项 | 数值 | 写进了代码的哪里 |
|---|---|---|
| 材质 hudWindow / fullScreenUI / popover / titlebar / underWindowBackground / menu / sheet | 方差 11 / 6 / 5 / 1 / 1 / 2 / 0，平均亮度 91 / 83 / 75 / 73 / 58 / 66 / 34 | `BlurMaterial`（取前 5 种） |
| 只暗化 45 % 不模糊 | 方差 4900，平均亮度 70，仍可读 | `SettingsStore.lowPowerMinDim = 0.5` |
| 低性能模式（暗化 50 %） | 方差 4032 | smoke 的 `low power uses dim mask` |
| `CGWindowListCopyWindowInfo` 一次 | 0.259 ms（10 个窗口） | 60 Hz 轮询 |
| `NSEvent.mouseLocation` 一次 | 0.0003 ms | — |
| CG bounds 与 NS frame 尺寸 | 完全一致，不含阴影 | `Geometry` 不外扩 |
| NS `{{400,300},{320,232}}` ↔ CG `{{400,637},{320,232}}` | 1169 = 300 + 232 + 637 | `Geometry.nsToCG` |
| `kCGWindowLayer` 出现过的值 | `0` / `24`（菜单栏）/ `-2147483601`（通知小组件） | `WindowSnapshot` 只留 layer 0 |
| 小于 50 pt 的 onscreen 窗口 | 10 个里有 2 个 | `WindowSnapshot.minSize = 80` |
| 覆盖层 level | floating(3) + 1 = 4，低于 Dock(20) 和菜单栏(24) | `ScreenOverlay` |
| toggle 开 / 关延迟上界（含截图耗时） | 130–180 ms | smoke 的 `toggle off / on` |
| 覆盖层跟随移动窗口 | 8/8，最慢 184 ms（含截图耗时） | smoke 的 `overlay follows window` |
| 设置窗口 | 480×787（含标题栏） | smoke 的 `settings window` |

### 权限对照（改代码前对照这张表）

| 想做的事 | 需要权限吗 |
|---|---|
| 窗口 id / bounds / layer / pid / alpha（`CGWindowListCopyWindowInfo`） | 不需要 |
| 窗口标题（`kCGWindowName`） | **屏幕录制** → 不读 |
| 全局快捷键（Carbon `RegisterEventHotKey`） | 不需要 |
| 开机自启（`SMAppService.mainApp`） | 不需要（未签名的 App 用户可能要在系统设置里允许一次） |
| 读台前调度开关（`CFPreferencesCopyAppValue`） | 不需要 |
| 窗口移动 / 缩放的事件通知（`AXObserver`） | **辅助功能** → 不用，改为轮询 |
| 用 `CGEvent` 注入点击（自动化测试） | **辅助功能** → 测不了，只能人工验收 |
| 截屏（ScreenCaptureKit） | **屏幕录制** → 不用 |
| 检测“当前是否在屏幕共享” | 公开方式未确认；Hush 用私有 CGS API → 做之前先探针，要权限就做成可选 |

本机探针：`CGPreflightScreenCaptureAccess = true`（终端已有录屏权限）、`AXIsProcessTrusted = false`、`CGPreflightPostEventAccess = false`。所以本机测不了“无录屏权限账户”的表现，也注入不了点击。

### 关键实现细节备忘

- **层级**：覆盖层 level = `CGWindowLevelForKey(.floatingWindow) + 1` = 4。`CGWindowLevel.h` 常量 floating=3、dock=20、status=25、overlay=102；实测菜单栏窗口 layer=24。菜单栏 / Dock 永远不会被盖。如果以后要盖菜单栏，level 要 ≥ 25，而 Swift 里**没有**对应的 `CGWindowLevelKey` 枚举，只能写数字。
- **圆角**：`OverlayItem` 用 `maskImage` 圆角 10 裁边。要更贴近系统圆角可改用 `CALayer.cornerCurve = .continuous` + `cornerMask`。
- **全屏检测**：窗口 bounds ≈ 屏幕矩形（容差 2）即视为全屏，该屏暂停。
- **Space**：`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` 只返回当前 Space 的窗口，切换桌面后自动重算，不用监听。
- **Stage Manager**：它的缩略图 / 侧条不是 layer 0，`WindowSnapshot` 天然过滤；开着时整体暂停只是避免视觉打架。
- **屏幕共享 / 录屏**：可以用 `CGDisplayStream` / `SCStream` 的运行状态或私有 CGS API 判断。做“共享时自动全模糊”之前先确认权限。
- **节能**：空闲时降到 10–20 Hz（还没做，见「下一步」第 3 项）。

## 构建与测试

```bash
./build.sh build     # → build/PrivacyWindow.app；日志 build/build.log
./build.sh test      # 构建 + --selftest（83 项，纯逻辑，不弹窗）
./build.sh dmg       # ad-hoc 签名 + build/PrivacyWindow.dmg
python3 spike/smoke.py --all   # 端到端，见下
```

- **打包 dmg 不要用 `hdiutil create`**：在这个沙盒里它对任何来源（包括空目录和空白镜像）都报 `create failed - 目錄不是空的`，而且沙盒不能写 `/Volumes`。`build.sh dmg` 走的是 `diskutil image create blank` → `diskutil image attach --mountPoint <项目内目录>` → `ditto` → `hdiutil detach` → `diskutil image create from … --format UDZO`。卸载一律用 `hdiutil detach <挂载点>`（`diskutil image detach` 不认挂载点路径）；挂上以后必须卸载，否则会留下一个空盘。**`hdiutil verify` 也会把镜像挂到 `/Volumes/<卷名>` 并且不弹出**，所以 `dmg()` 验完要再 `hdiutil detach "/Volumes/$VOL"`；每次打完 dmg 都用 `hdiutil info | grep -c '^/dev/disk'` 确认是 0。

- 本机只有 Command Line Tools，没有 Xcode。`swiftc` 必须带
  `-module-cache-path build/mcache -clang-scanner-module-cache-path build/mcache/clang`，否则模块缓存目录被沙盒拒绝写入。`build.sh` 已经带了；手工编译 `spike/` 下的文件时记得加。
- 编译参数：`-swift-version 5 -target arm64-apple-macosx14.0 -sdk $(xcrun --show-sdk-path) -O`。
- **不要加 `-parse-as-library`**：`main.swift` 有顶层代码。
- 编译输出要重定向到文件再 `grep "error:"`，不要用 `tail`——warning 很长，真正的 error 常在最后几行之外。
- 沙盒里不能用进程替换 `>(...)`（报 `/dev/fd/62: Operation not permitted`）。
- 改完代码至少跑 `./build.sh test` 和一次 `spike/smoke.py`，并且要求 `build/build.log` 里 `warning:` 数为 0。

### 端到端测试（`spike/smoke.py`）

- 用任意装了 Pillow 的 Python 3：`python3 -m pip install Pillow` 之后 `python3 spike/smoke.py --all`。
- 原理：`spike/probe3.swift`（由 `build_tool("probe3")` 编成 `build/probe3`，源码在 git 里、二进制不在）开一个黑白条纹靶窗口（CG 坐标 `300,577,400,292`，内部截图区 `320,629,360,200`），`screencapture -R` 截这一块算亮度方差。清晰 ≈ 16256，被毛玻璃盖住 < 10。
- **焦点位置一律用 `--mouse` 调试参数指定，不要调 `CGWarpMouseCursorPosition`**：跑测试时你多半还在用这台机器，挪真实光标会被你的操作覆盖，也不该打扰你。
- 带调试参数（`--mouse/--set/--trace/--smoke/--open-settings`）启动时，程序用的是独立的 defaults 域 `com.dalongxia2017.PrivacyWindow.debug`（启动和退出时清空），不会动用户真实设置。**不要用真实域做测试**——早先用 `--material` 写进过 `com.dalongxia2017.PrivacyWindow`，留下了 `pw.material`，已手动清掉。
- 测试结束检查没有残留进程：`pgrep -fl "probe3|PrivacyWindow"`。
- **你正在用的真实实例可能也在跑**（真实 defaults 域 `com.dalongxia2017.PrivacyWindow` 里有用户的 `pw.*`），**不要清空它**，也不要 `killall PrivacyWindow`。smoke.py 只结束自己启动的进程。
- **读靶窗口位置要用 `build/winid` 现查**，不要信 `probe3 --drift` 通过管道打印的 `pos x y w h`：管道会积压，`readline()` 读到的往往是落后几格的旧坐标。按旧坐标截图截到的是靶窗口下面的画面（实测某个视频窗口，方差 ≈ 4000–5000），旧判定 "< 2000 就算盖住" 因此出过**假阳性**。`phase_drift` 现在的做法：读到 pos 行 → `drain()` 排空管道 → winid 现查 bounds → 采样 1 s，只认两个特征值（≈ 16256 = 靶在且没盖；< 2000 = 已盖），中间值（靶窗口不在截图区）忽略。
- `probe3 --drift` 每 **1.2 s** 跳一格（原来是 0.6 s，太密，采样窗口会跨过下一次移动）。
- **靶窗口随时可能被别的窗口挡住**（跑测试时你还在用这台机器，窗口随时会被拖过来）。方差落在“既不像清晰也不像盖住”的区间（例如 ≈ 12000 / 9900）时，先用 `spike/cover.swift`（`build/cover x y w h`，前→后列出与矩形相交的窗口）看压在截图区最上层的 layer 0 窗口是谁：不是 probe3 就是环境干扰，把那个窗口挪开再跑，不要当成程序缺陷去改代码。`smoke.py` 开始时会等靶窗口露出最上层（最多 6 s），等不到会直接报是谁挡的。
- **不要 `import spike/smoke.py`**：它底部会执行 `main()`（现在有 `__name__` 保护，但别依赖），要复用函数就单独抽出来。
- `wait_until` 超时返回 `None`，拼接消息时不能直接 `* 1000`（崩过一次 `TypeError`）。
- 已知**不可行**的检测方式：Auto Layout 冲突信息（`Unable to simultaneously satisfy constraints`）不会出现在进程 stderr 里（用 `spike/conflict_probe.swift` 校准过，0 行），所以不要靠日志数冲突；用 `--open-settings` 输出的 `selfcheck: contentFits ok` 判断内容是否被裁。
- 状态栏图标的窗口不属于本进程（`CGWindowList` 查不到），要用 `MenuBarController.statusItemFrame`（状态栏按钮所在窗口的 frame）来确认它挂上去了。
- `NSScreen.main` 是**鼠标所在屏**，不是主屏；设置窗口 `center()` 因此可能落到副屏。测试里按宽度判定，不要按位置判定。
- `screencapture -R` 用左上角原点的 CG 坐标。

## 代码结构

```
Sources/
├── main.swift                     入口。解析 --selftest / --toggle|--enable|--disable / 调试参数；AppDelegate 持有 AppController
├── AppController.swift            tick()：鼠标 → 窗口快照 → 命中 → 桌面回退 → 防抖 → 覆盖层。另有 PausePolicy（全屏 / 台前调度 / 关掉的显示器）
├── SettingsStore.swift            SettingsStore（UserDefaults + didChange 通知）、BlurMaterial、DesktopBehavior、AppList（白/黑名单）
├── WindowInfo.swift               WindowInfo、Geometry（NS↔CG 坐标）、WindowSnapshot（过滤规则）、HitTest、OverlayLayout
├── FocusResolver.swift            FocusResolver.update(candidate:existing:now:) 防抖
├── OverlayManager.swift           RegionMath.subtract、RoundedMask、OverlayItem、ScreenOverlay、OverlayManager
├── HotKey.swift                   HotKey（键码 + Carbon 修饰键）、HotKeyController（RegisterEventHotKey）、HotKeyRecorder（改键用的录入框）
├── SystemState.swift              StageManager（读系统偏好 + Monitor 缓存）、LaunchAtLogin（SMAppService）
├── SettingsWindowController.swift 代码布局的设置窗口；AppListTableView（拖拽接收 .fileURL）
├── MenuBarController.swift        NSStatusItem + 菜单
└── SelfTest.swift                 --selftest
```

数据流（每帧 60 Hz，关闭时降到 4 Hz）：

```
NSEvent.mouseLocation ─nsToCG─▶ HitTest.candidate(windows:at:) ─▶ candidate: CGWindowID?   （pinned 和 alwaysClear 的窗口不当候选）
WindowSnapshot.fetch ──────────┘            （layer 0、≥80pt、非本进程；白名单跳过，黑名单标 pinned；
                                            设置窗口按 alwaysClearIDs 保留，标 alwaysClear）
candidate == nil 且 desktopBehavior == .keepLast → 沿用 resolver.current（鼠标在黑名单窗口上也算 candidate == nil）
FocusResolver.update(candidate:existing:now:) → resolver.current
PausePolicy.pausedScreens(...) → Set<CGDirectDisplayID>
    （全屏窗口所在屏 ∪ 用户关掉的显示器；台前调度开着 → 全部屏）
OverlayManager.update(windows:focus:pausedScreens:)
```

### 各模块要点

- **`WindowSnapshot.parse`** 是唯一的窗口过滤入口，规则集中在这里，改规则只改这一处。bundle id 通过 `NSRunningApplication(processIdentifier:)` 取并缓存。白名单里的 App 直接丢掉（等于不存在）；黑名单里的 App 保留，但 `pinned = true`：`HitTest` 不选它当焦点，它永远是“被遮”的。`--trace` 的窗口列表里黑名单窗口带 `(黑)`。
- **白名单反转**（`SettingsStore.invertWhitelist`，键 `pw.invertWhitelist`）：`WindowSnapshot.fetch` 把 `whitelist` 当 `only:` 传给 `parse`，白名单本身传空集。含义 = 只有列表里的 App 被处理（能当焦点、不悬停时被盖），其余全部丢掉；列表为空就什么都不盖；没有 bundle id 的进程（命令行工具）认不出来，反转时不处理。黑名单只在同时也在白名单里的 App 上生效。设置窗口里是白名单标题下的一个复选框，`syncWhitelistWording()` 负责切换标题和说明。
- **`Geometry`**：CG 坐标原点在主屏左上、Y 向下；`nsToCG(_, mainHeight:)` 用主屏高度翻 Y。`CGWindowListCopyWindowInfo` 给的 bounds **不含阴影**，所以不需要外扩。
- **`PausePolicy.pausedScreens`**：台前调度开着 → 返回全部屏幕（优先级最高）；否则 = `disabledScreens` ∪ 有全屏窗口的屏幕。分屏的两个窗口各占半屏，不与整块屏幕重合，所以不会误判成全屏。
- **`HotKey`** 用 Carbon 的 `RegisterEventHotKey`（零权限）。`HotKey.isValid` 要求要么带修饰键，要么是不产出字符的键（F 键、方向键、Home/End/PageUp/PageDown/Help）——否则打字就会触发。键名表 `HotKey.keyNames` 用 `kVK_*` 常量，**不要手写键码数字**。Carbon 的 `cmdKey` 等常量在 Swift 里是 `Int`，要先转 `UInt32`。
- **`StageManager.Monitor`** 每 2 s 读一次偏好并缓存，不要每帧读（`CFPreferencesCopyAppValue` 没那么便宜，而且读的是别的进程的域）。
- **`SettingsStore.overlayDimAlpha`**：低性能模式 = 隐藏 `NSVisualEffectView`，暗化取 `max(dimAlpha, lowPowerMinDim)`（`lowPowerMinDim = 0.5`）。用户把暗化调到 0 再开低性能，仍然要保证看不清。
- **`FocusResolver`** 是 struct，`debounce <= 0` 时立即切换；候选窗口消失（`existing` 不含）时立即清空，不防抖。
- **`RegionMath.subtract(rect, holes)`**：被遮窗口的覆盖区域要减去 z 序在它上面的所有窗口矩形（含焦点窗口）。否则被遮窗口伸到焦点窗口下面的部分会把焦点窗口也糊掉——这是实测踩到的坑。
- **`OverlayManager`**：每屏一个 `ScreenOverlay`（全屏透明窗口，level = `CGWindowLevelForKey(.floatingWindow) + 1`，`collectionBehavior` 含 `.canJoinAllSpaces .fullScreenAuxiliary .stationary .ignoresCycle`）。`items: [CGWindowID: [OverlayItem]]`，块数相同就原地改 frame，不同才重建；淡出中的块不重复启动淡出。窗口 frame 直接设、不做动画（跟随要快），alpha 走 `animator()`。
- **`OverlayItem`** = `NSVisualEffectView`（`.behindWindow` + `.active`，`maskImage` 圆角 10）+ 黑色暗化 view，两个都是覆盖层窗口的直接子视图。
- **设置窗口**用 `NSStackView` 代码布局，四边都有约束，窗口按 `contentView.fittingSize` 定尺寸（最小 480×590），当前实测 480×787（含标题栏，白名单反转勾上时 480×801）；加了新行后要确认它仍放得进 1169 高的屏幕（smoke 的 `settings window fits on screen`）。
- **菜单栏**在 `AppController.start()` 里创建，不在 `init` 里——init 阶段 `self` 还没初始化完，闭包不能捕获它。

### 调试参数（只在命令行显式传入时生效）

| 参数 | 作用 |
|---|---|
| `--mouse "x,y[;x,y@毫秒…]"` | 用给定 CG 坐标代替真实鼠标；`@毫秒` = 启动后多久切到这个点 |
| `--set key=value,…` | 覆盖设置：`enabled material dimAlpha animationMS debounceMS desktopBehavior pauseOnFullscreen pauseOnStageManager lowPower hotkeyEnabled hotkeyCode hotkeyModifiers whitelist blacklist invertWhitelist disableScreenAt=x;y stageManager=1`（`stageManager=1` 只是注入“开着”的标志，不改系统偏好） |
| `--trace` | 每 15 帧打印 `mouse cand focus covered overlayIgnoresMouse windows`；焦点 / 被遮集合 / 暂停屏一变化就打一行 `t=… focus=… covered=… paused=…` |
| `--open-settings` | 启动 2 s 后打开设置并打印 `selfcheck: …`（settingsWindow / settingsWindowSize / statusItem / overlayWindows / overlayIgnoresMouse / hotkey / launchAtLogin / screens / settingsWindowClear / contentFits）。`settingsWindowClear ok control:N`：设置窗口上被盖面积应为 0，control 是不带 `alwaysClearIDs` 的对照（旧逻辑的面积，应 > 0） |
| `--smoke <秒>` | 到点自动退出 |
| `--toggle/--enable/--disable` | 通过 `DistributedNotificationCenter`（`com.dalongxia2017.PrivacyWindow.command`）发给运行中的实例，自己退出 |

## 写代码时容易踩的坑（都是本项目实际编不过 / 崩过 / 测错的）

- 不要凭记忆写 SDK 签名，先查头文件或编译验证。编造过的例子：`NSRectCorner`（AppKit 没有）、`constraintShouldDeactivate`、`_layoutFlushingDidEnd`。
- `NSStatusItem.button` 是**可选**的（`NSStatusBarButton?`）。
- Swift 里是 `joined(separator:)`，没有 `join`。
- `CGWindowLevelKey.floatingWindow`（不是 `floatingWindowLevel`）。
- `EventTypeSpec(eventClass:)` 要写 `OSType(kEventClassKeyboard)`。
- `NSScreen.localizedName` 在本 SDK 里是**非可选**的 `String`；`NSButton` 没有 `setToolTip`，用 `.toolTip =`。
- `guard let x = dict.flatMap { … } else { }` 里尾随闭包会被当成 guard 的 body 而报 `expected 'else' after 'guard' condition`，把 flatMap 拆成独立函数再 `guard let`。
- failable init 里写 `guard let raw = identifier?.rawValue` 会报 "must have Optional type"（编译器把 `.rawValue` 当成非可选）→ 先 `guard let identifier`，再用 `identifier.rawValue`。
- enum 不能有存储属性；测试用具全部写成 `static`。
- `NSSlider(value:minValue:maxValue:target:action:)`；分隔线用 `NSBox()` + `boxType = .separator`。
- `Bundle` 没有 `localizedName`（显示名走 `NSRunningApplication.localizedName` 或 `URL` 资源键）。
- `NSView()` 的 frame 为零时**不渲染**（早期探针基线方差只有 240，原因就是这个）。
- 不要用 sed/正则大段改代码，越改越乱；用整段替换或 edit。改 `smoke.py` 的 python 补丁脚本里多行字符串经常匹配不上，而且 heredoc 里含 `├` 会触发 `SyntaxError`——脚本写到 `/tmp` 文件再执行，或者直接用 edit 工具。
- 窗口列表内容取决于用户当下开着什么，测试**不能假设**固定有哪些窗口，只假设靶窗口存在（先量一次 baseline）。

## 还没验证的

| 项 | 现状 |
|---|---|
| 圆角遮罩的裁剪效果 | `maskImage` 已赋值，没有人目视确认过 |
| 焦点切换的体感速度 | 逻辑上 16 ms 轮询 + 150 ms 淡入；自动化只量了结果，没量体感 |
| 多桌面 Space、真实全屏 App、真实台前调度、真实分屏 | 基于 API 语义推断。台前调度只用了“注入开关”的方式测过（本机 `GloballyEnabled = 0`，系统没开） |
| 没有录屏权限的账户 | 本机终端有录屏权限，无法复现；程序自身不申请，理论上不受影响 |
| 快捷键真实按键、开机自启 | 需要 `CGPreflightPostEventAccess`（本机 false）和一次重新登录，只能人工 |
| 私有 `CAFilter` 在 macOS 27 上还能不能用 | 没测。做实验开关之前要先用 MaterialView 的代码单独探针 |
| Intel 机型、macOS 14–26 | 兼容性验证还没做，排在下一步第 8 项 |
| 点击穿透 | 不做自动化：覆盖层在鼠标移到上方时自动让位，人工验收即可 |

## 下一步

完整清单和理由，按建议顺序。用户已明确：**兼容性先不做**。

**需要你手动确认的两件事**：开机自启（勾上后注销再登录）；快捷键（按 ⌥⌘P、改键、关掉）。

1. **模糊强度真正可调**：先做“材质 + 暗化”预设（公开 API）；`CAFilter` 连续半径只能做成默认关闭的实验开关，失效要能退回公开 API。
2. **降低滞后**：`CVDisplayLink` 对齐刷新代替 `Timer`；窗口列表变化时立即重算；拖放 / 调整窗口大小期间可临时降刷新率；实测 4K / 多显示器每帧耗时。
3. **空闲降频**：鼠标和窗口都不动时降到 ~10 Hz，一有变化立刻恢复。
4. **桌面图标模糊**：鼠标在桌面空白处时的可选项（在桌面区域再放一块覆盖层）。
5. **屏幕共享 / 录屏时自动全模糊**：隐私场景的核心价值。先确认检测共享状态要不要权限（`CGDisplayStream` / `SCStream` 运行状态 vs 私有 CGS API），要的话做成可选、默认不申请。
6. **应用图标**：现在只有菜单栏的 SF Symbol。
7. **Developer ID 签名 + 公证**：别人下载就能打开，开机自启不被系统拦。
8. **兼容性验证**：Intel + macOS 14/15/16/26；重点看 macOS 14 的 `SMAppService` 和 `NSVisualEffectView`。
9. **自动更新**：Sparkle，等有了签名再做。
10. **快捷键注册失败时在设置里提示**：`HotKeyController.errorDescription` 已经能给出中文说明，但设置窗口没有显示它；在快捷键那一行下面加一行红字。

更远的想法（都要权限，暂不做）：只模糊含敏感内容的窗口（要读标题或辅助功能接口）；录屏时强制全模糊。

做过但不做的：真实点击穿透的自动化测试（没有辅助功能权限注入不了点击；覆盖层一有鼠标经过就让位，实际没有影响）。

变更记录：第一轮 调研 + 架构选型 → 第二轮 最小程序（焦点毛玻璃、设置、菜单栏、开关）→ 第三轮 快捷键、低性能模式、按屏开关、开机自启、黑白名单、台前调度暂停；调研和计划并入 README 与本文 → 第四轮 白名单反转（只给列表里的 App 盖毛玻璃）→ 第五轮 回滚 → 第六轮 设置窗口永远清晰（`alwaysClear`，只对这一个窗口）。

- **设置窗口永远清晰**（`WindowInfo.alwaysClear`）：`SettingsWindowController.alwaysClearWindowIDs` 在窗口可见时给出它的窗口 id，`parse` 对这些 id 放行本进程过滤并标 `alwaysClear`（放在白名单 / 反转判断之前，所以不受名单影响）。`OverlayLayout.regions` 把 `alwaysClear` 的窗口**不论 z 序一律当洞、自己不盖**；`HitTest` 不选它当焦点。不按 z 序挖也可以：盖在它上面的普通窗口自己照常被遮，不会漏出清晰的一块。`existing`（keepLast 回退用）要滤掉 alwaysClear 的窗口。这和第五轮的通用挖洞不同：只认这一个窗口 id，别的“不处理的窗口”仍然会被连带糊掉。

**第五轮回滚掉的东西，不要按原思路重做**（提交 04c90ea、d91119e 里有完整实现，可以查，但不要再合回来）：

| 试过的改动 | 当时的理由 | 实际结果 |
|---|---|---|
| 不处理的窗口（白名单 App、1–3 层面板、设置窗口、第 0 层小窗）在覆盖层里挖洞（`WindowSnapshot.clearWindows` / `WindowFrame.clear`） | 它们叠在被遮窗口上时被连带糊掉 | 挖洞按矩形算，系统贴着文本光标的 64×64 输入法角标（`CursorUIViewService`，第 0 层）在被遮窗口上破出一个方口，光标右边的毛玻璃缺一块 |
| 系统动画期间隐藏覆盖层（`MotionDetector` + `NSWorkspace.activeSpaceDidChangeNotification`）、`CADisplayLink` 代替 `Timer`、块数变化时在原组上增减而不重建 | 切换桌面时覆盖层不跟着滑、拖窗口时闪 | 用户实测卡顿感比原来更重，且修完后问题依旧 |
| 第 0 层小窗（宽或高 < `minSize`）不挖洞 | 修上面那个方口 | 没修好 |

重做之前必须先拿到**问题发生那一刻**的窗口列表（用后台观察器在用户真实操作时录，`NEW` / `GONE` / `STATE` 行），确认是哪个窗口、哪一层造成的，再决定改哪里；不要再靠“列表里有一批 64×64 窗口”这类间接证据推断根因。

排查时确认的系统事实（仍然有效）：简体拼音候选条在第 20 层（397×28），高于覆盖层，本来就不受影响；`CursorUIViewService` 有多个 64×64 的第 0 层窗口，平时 offscreen；同一层级的窗口之间插不进覆盖层。

## 同类与参考

### 最接近的现成产品

| 项目 | 形态 | 焦点定义 | 渲染方式 | 权限 | 与本项目的关系 |
|---|---|---|---|---|---|
| **FocalVeil 凝焦** — [官网](https://focalveil.com/) · [V2EX 讨论](https://global.v2ex.co/t/1244297) · [Product Hunt](https://www.producthunt.com/p/focalveil-focus-on-what-matters) · 反馈仓库 [FocalVeil-website/issues](https://github.com/YinHeng89/FocalVeil-website/issues) | v0.1.68，闭源，macOS 14+，基础免费 / PRO，Developer ID + 公证，Sparkle 2 计划随 v0.2.0 | **键盘活动窗口**（系统弹窗 > 前台 App 窗口），每帧向窗口服务器询问 | 有录屏权限：ScreenCaptureKit 截“焦点以外”的画面并缩小 → 先补色再高斯模糊（半径 5–60 pt 连续）→ 挖透明洞。无权限：降级为 `NSVisualEffectView` 系统模糊（强度只能粗调）。每屏一层覆盖；排除的 App 永远清晰；静止 0.75 s 降 30 fps、约 15 s 降 4 fps；全屏窗口时该屏停止；菜单栏 / Dock 默认清晰（覆盖层降层级） | 屏幕录制（可选，用于高质量模糊） | **最直接的对标**。双路径设计（授权 = 自算模糊，未授权 = 系统材质）值得借鉴；它不做悬停 |

### 同类“变暗 / 模糊非活动窗口”工具

| 项目 | 平台 / 许可 | 做法 | 可借鉴点 |
|---|---|---|---|
| **HazeOver** — [帮助页](https://hazeover.com/help.html) | macOS，付费，Mac App Store + 官网直发 | 变暗非活动窗口，跟随键盘焦点；辅助功能权限可提升响应与准确性；多显示器可按屏开关；Fn 拖放时暂停；支持 Shortcuts / Focus Filters | 产品化细节：按屏开关、拖放时暂停、与专注模式联动。页面未提及鼠标悬停跟随 |
| **Blurred** — Dwarves Foundation，[Mac App Store id1497527363](https://apps.apple.com/app/id1497527363) | macOS，免费 | 变暗非前台窗口；Single / Parallel（多显示器）模式 | 仓库 `github.com/dwarvesf/blurred` 已 404（Homebrew cask 元数据仍指向它），读不到源码 |
| **Hush** — [产品页](https://poteam.pro/products/hush) · [Hacker News 讨论](https://news.ycombinator.com/item?id=47215613) | macOS | `CGWindowList` 追踪窗口 + `NSVisualEffectView` 模糊；用 CGS 私有 API 检测屏幕共享；Desktop 模式 / Focus 模式 | 架构与本项目的公开 API 路线一致；“检测到屏幕共享时自动处理”值得做 |
| **GhostLayer** — [GitHub](https://github.com/HelithaSri/GhostLayer) | macOS，开源 | 让覆盖层在屏幕共享 / 录屏中**隐藏** | 对“隐私窗口”有用：共享时对方看不到毛玻璃层；反过来用就是“共享时强制全模糊” |
| **Ghoster** — [介绍](https://www.appinn.com/ghoster/) | Windows | 变暗非活动窗口 | Windows 端的同类，需求跨平台存在 |

### 技术参考

| 资料 | 价值 |
|---|---|
| **MaterialView** — [GitHub](https://github.com/OskarGroth/MaterialView) · [逆向分析文章](https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview) | 逆向了 `NSVisualEffectView`：私有 `CABackdropLayer` + `CAFilter`，可**连续调模糊半径 / 饱和度 / 亮度**，支持 behind-window。需要的私有设置：`setValue(true, forKey: "clear")`、窗口 `shouldAutoFlattenLayerTree=false`、`canHostLayersInWindowServer` 先 false 后 true、`window.backgroundColor = NSColor.white.withAlphaComponent(0.001)`、backdrop `windowServerAware=true`、`allowsSubstituteColor=true`、`CGSSetWindowTags` 的 `kCGSNeverFlattenSurfacesDuringSwipesTagBit`(1<<16) 且 resize 后重设；`scale=0.25` 采样。**非公开 API，Mac App Store 审核不安全，系统更新可能失效** |
| **trycua/cua 的提交** — [e00840a](https://github.com/trycua/cua/commit/e00840a5f3f4dd823132827b3fdafebc309364241) | 侧面印证：`CGWindowListCopyWindowInfo` 没有录屏权限也返回窗口 id 与 bounds，仅标题受限 |
| Apple 文档：`NSVisualEffectView.blendingMode = .behindWindow` | 用窗口后方的内容作为模糊输入；整个方案的基础 |
| `CGWindowLevel.h` 层级常量（本机 SDK） | `kCGFloatingWindowLevel=3`、`kCGDockWindowLevel=20`、`kCGStatusWindowLevel=25`、`kCGOverlayWindowLevel=102`。覆盖层放在 4：高于一切普通窗口（0），低于 Dock 与菜单栏（实测菜单栏窗口 layer = 24） |
