import AppKit

/// 覆盖层圆角用的九宫格 mask 图，只需要生成一次。
enum RoundedMask {
    static let radius: CGFloat = 10

    static let image: NSImage = {
        let edge = radius * 2 + 4
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius + 2, left: radius + 2, bottom: radius + 2, right: radius + 2)
        image.resizingMode = .stretch
        return image
    }()
}

/// 一块覆盖区域：毛玻璃 + 可选暗化。
final class OverlayItem {
    let blur = NSVisualEffectView(frame: .zero)
    let dim = NSView(frame: .zero)
    private(set) var fadingOut = false
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings

        blur.wantsLayer = true
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = RoundedMask.image

        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.cgColor
        dim.layer?.cornerRadius = RoundedMask.radius
        dim.layer?.cornerCurve = .continuous
        dim.layer?.masksToBounds = true

        applySettings(settings)
    }

    var frame: CGRect {
        get { blur.frame }
        set {
            // 窗口移动/缩放时直接设 frame，不做动画，避免毛玻璃滞后于窗口
            if blur.frame != newValue {
                blur.frame = newValue
                dim.frame = newValue
            }
        }
    }

    func applySettings(_ s: SettingsStore) {
        blur.material = s.material.effect
        blur.isHidden = s.lowPower          // 低性能模式：不用毛玻璃，只留暗色遮罩
        if !isAnimating() { dim.alphaValue = CGFloat(s.overlayDimAlpha) }
    }

    private func isAnimating() -> Bool {
        (blur.layer?.animationKeys()?.isEmpty == false) || (dim.layer?.animationKeys()?.isEmpty == false)
    }

    /// 淡入到完全遮盖（t = 1）或淡出到透明（t = 0）
    func fade(to t: CGFloat, completion: (() -> Void)? = nil) {
        fadingOut = t < 1
        let duration = settings.animationDuration
        let dimTarget = CGFloat(settings.overlayDimAlpha) * t
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            self.blur.animator().alphaValue = t
            self.dim.animator().alphaValue = dimTarget
        }, completionHandler: completion)
    }

    /// 停在当前显示值，取消进行中的动画
    func cancelAnimations() {
        stop(blur)
        stop(dim)
        fadingOut = false
    }

    private func stop(_ view: NSView) {
        let shown = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
        view.layer?.removeAllAnimations()
        view.alphaValue = CGFloat(shown)
    }

    func addTo(_ parent: NSView) {
        parent.addSubview(blur)
        parent.addSubview(dim)
    }

    func removeFromSuperview() {
        blur.removeFromSuperview()
        dim.removeFromSuperview()
    }
}

enum RegionMath {
    /// `rect` 减去若干 `holes` 之后剩下的矩形（互不重叠，覆盖原区域）。
    static func subtract(_ rect: CGRect, _ holes: [CGRect]) -> [CGRect] {
        let valid = holes.map { $0.intersection(rect) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !valid.isEmpty else { return [rect] }

        // 用所有洞的左右边把区域竖着切成条；每条内，每个洞要么整条覆盖、要么完全不碰
        var cuts: [CGFloat] = [rect.minX, rect.maxX]
        for h in valid { cuts.append(h.minX); cuts.append(h.maxX) }
        cuts = Array(Set(cuts)).sorted()

        var out: [CGRect] = []
        for i in 0..<(cuts.count - 1) {
            let x0 = cuts[i], x1 = cuts[i + 1]
            guard x1 - x0 >= 1 else { continue }
            var spans: [(CGFloat, CGFloat)] = [(rect.minY, rect.maxY)]
            for h in valid where h.minX <= x0 && h.maxX >= x1 {
                var next: [(CGFloat, CGFloat)] = []
                for (lo, hi) in spans {
                    if h.maxY <= lo || h.minY >= hi {
                        next.append((lo, hi))
                    } else {
                        if h.minY - lo >= 1 { next.append((lo, h.minY)) }
                        if hi - h.maxY >= 1 { next.append((h.maxY, hi)) }
                    }
                }
                spans = next
            }
            out.append(contentsOf: spans.map { CGRect(x: x0, y: $0.0, width: x1 - x0, height: $0.1 - $0.0) })
        }
        return out
    }
}

/// 纯计算：每个窗口露在外面、需要遮盖的矩形。
enum OverlayLayout {
    /// `windows` 是 z 序（前 → 后）；`focus` 是保持清晰的窗口 id。
    /// 被遮窗口伸到别的窗口下面的那部分不能盖：盖了会把上面那个窗口也糊掉。
    /// 所以每个窗口只遮“自己的矩形 减去 z 序在它上面的所有窗口”。焦点窗口不算被遮，
    /// 但它的矩形同样要从下面的窗口里挖掉。
    static func regions(windows: [WindowInfo], focus: CGWindowID?) -> [CGWindowID: [CGRect]] {
        var holes: [CGRect] = []
        var regions: [CGWindowID: [CGRect]] = [:]
        for w in windows {
            if w.id == focus && !w.pinned {
                holes.append(w.bounds)
            } else {
                regions[w.id] = RegionMath.subtract(w.bounds, holes)
                holes.append(w.bounds)
            }
        }
        return regions
    }
}

/// 每块屏幕一个：一个鼠标穿透的全屏透明窗口 + 若干覆盖区域。
final class ScreenOverlay {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let window: NSWindow
    /// 窗口 id → 这个窗口露出来需要遮盖的几块区域
    private(set) var items: [CGWindowID: [OverlayItem]] = [:]
    private let mainHeight: CGFloat

    init(screen: NSScreen) {
        self.screen = screen
        self.displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        self.mainHeight = Geometry.mainCG.height

        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true          // 点击、拖拽、滚动全部穿透
        window.isMovable = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1) // 高于普通窗口，低于 Dock 与菜单栏
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView?.wantsLayer = true
    }

    /// 把一个 CG 全局矩形换成覆盖层窗口里的本地坐标，并裁到本屏范围内
    func localRect(for cgRect: CGRect) -> CGRect? {
        let screenCG = Geometry.nsToCG(screen.frame, mainHeight: mainHeight)
        let clipped = cgRect.intersection(screenCG)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let ns = Geometry.cgToNS(clipped, mainHeight: mainHeight)
        return CGRect(x: ns.minX - screen.frame.minX, y: ns.minY - screen.frame.minY, width: ns.width, height: ns.height)
    }

    var isEmpty: Bool { items.isEmpty }

    /// `needed`：本屏上需要遮盖的窗口 id → 本地矩形列表
    func update(needed: [CGWindowID: [CGRect]], settings: SettingsStore) {
        for (id, group) in items {
            guard let rects = needed[id] else {
                // 已经在淡出的不重复启动，否则动画永远走不完
                if group.first?.fadingOut != true {
                    for item in group { item.fade(to: 0) { [weak self] in self?.remove(item, id: id) } }
                }
                continue
            }
            if group.first?.fadingOut == true {
                for item in group { item.cancelAnimations(); item.fade(to: 1) }
            }
            if group.count == rects.count {
                // 形状没变只是位置变了：原地挪，不重建，避免拖动窗口时闪烁
                for (item, rect) in zip(group, rects) { item.frame = rect }
            } else {
                let wasVisible = group.first.map { $0.blur.alphaValue > 0 } ?? false
                for item in group { item.cancelAnimations(); item.removeFromSuperview() }
                items[id] = makeGroup(rects, settings: settings, fadeIn: !wasVisible)
            }
        }
        for (id, rects) in needed where items[id] == nil {
            items[id] = makeGroup(rects, settings: settings, fadeIn: true)
        }

        if items.isEmpty {
            if window.isVisible { window.orderOut(nil) }
        } else if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func makeGroup(_ rects: [CGRect], settings: SettingsStore, fadeIn: Bool) -> [OverlayItem] {
        rects.map { rect in
            let item = OverlayItem(settings: settings)
            item.frame = rect
            item.blur.alphaValue = 0
            item.dim.alphaValue = 0
            item.addTo(window.contentView!)
            if fadeIn { item.fade(to: 1) } else { item.fade(to: 1, completion: nil) }
            return item
        }
    }

    func applySettings(_ settings: SettingsStore) {
        for group in items.values { for item in group { item.applySettings(settings) } }
    }

    func hide(settings: SettingsStore) {
        update(needed: [:], settings: settings)
    }

    private func remove(_ item: OverlayItem, id: CGWindowID) {
        // 淡出途中又被重新遮盖的区域不能删
        guard item.fadingOut, var group = items[id], let index = group.firstIndex(where: { $0 === item }) else { return }
        item.removeFromSuperview()
        group.remove(at: index)
        items[id] = group.isEmpty ? nil : group
    }
}

/// 管理所有屏幕的覆盖层。
final class OverlayManager {
    private let settings: SettingsStore
    private var screens: [CGDirectDisplayID: ScreenOverlay] = [:]

    init(settings: SettingsStore) {
        self.settings = settings
        rebuildScreens()
    }

    /// 当前需要遮盖的窗口 id（供调试/测试）
    var coveredWindowIDs: Set<CGWindowID> {
        var ids: Set<CGWindowID> = []
        for s in screens.values { for (id, group) in s.items where group.first?.fadingOut != true { ids.insert(id) } }
        return ids
    }

    var overlayWindowCount: Int { screens.count }
    var visibleOverlayWindowCount: Int { screens.values.filter { $0.window.isVisible }.count }

    /// 所有覆盖层窗口都应忽略鼠标事件（点击、拖拽、滚动穿透）
    var allIgnoreMouse: Bool { screens.values.allSatisfy { $0.window.ignoresMouseEvents } }

    /// 调试：所有覆盖区域的状态（含正在淡出的）
    func debugItems() -> [String] {
        screens.values.flatMap { overlay in
            overlay.items.sorted { $0.key < $1.key }.map { id, group in
                "\(id):pieces=\(group.count) out=\(group.first?.fadingOut == true) alpha=\(group.first.map { String(format: "%.2f", $0.blur.alphaValue) } ?? "-")"
            }
        }
    }

    /// `windows`：本帧的可处理窗口（z 序，前 → 后）；`focus`：保持清晰的窗口 id；
    /// `pausedScreens`：完全暂停覆盖的屏幕（例如上面有全屏 App）。
    func update(windows: [WindowInfo], focus: CGWindowID?, pausedScreens: Set<CGDirectDisplayID>) {
        syncScreensIfNeeded()
        let regions = OverlayLayout.regions(windows: windows, focus: focus)

        for (id, overlay) in screens {
            if pausedScreens.contains(id) {
                overlay.hide(settings: settings)
                continue
            }
            var needed: [CGWindowID: [CGRect]] = [:]
            for (windowID, rects) in regions {
                let local = rects.compactMap { overlay.localRect(for: $0) }
                if !local.isEmpty { needed[windowID] = local }
            }
            overlay.update(needed: needed, settings: settings)
        }
    }

    func hideAll() {
        for overlay in screens.values { overlay.hide(settings: settings) }
    }

    func settingsChanged() {
        for overlay in screens.values { overlay.applySettings(settings) }
    }

    private func syncScreensIfNeeded() {
        let current = NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        guard Set(current) != Set(screens.keys) else { return }
        rebuildScreens()
    }

    func rebuildScreens() {
        for overlay in screens.values { overlay.window.orderOut(nil) }
        screens = [:]
        for screen in NSScreen.screens {
            let overlay = ScreenOverlay(screen: screen)
            screens[overlay.displayID] = overlay
        }
    }
}
