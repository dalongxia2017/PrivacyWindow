import CoreGraphics
import Foundation

/// 焦点判定 + 防抖。纯逻辑，不依赖 AppKit，可单测。
///
/// 候选窗口与当前焦点不同时，要连续稳定 `debounce` 秒才切换；
/// 鼠标在窗口边缘来回划过时不会来回闪。
struct FocusResolver {
    var debounce: TimeInterval

    /// 当前清晰窗口的 id；nil 表示没有窗口清晰
    private(set) var current: CGWindowID?

    private var pendingID: CGWindowID?
    private var pendingSince: TimeInterval = 0
    private var hasPending = false

    init(debounce: TimeInterval) {
        self.debounce = debounce
    }

    /// `existing` 是本帧仍然存在的窗口集合；当前焦点窗口消失时立即清空。
    /// 返回 true 表示 `current` 在这次调用中发生了变化。
    @discardableResult
    mutating func update(candidate: CGWindowID?, existing: Set<CGWindowID>, now: TimeInterval) -> Bool {
        var changed = false
        if let c = current, !existing.contains(c) {
            current = nil
            clearPending()
            changed = true
        }
        if candidate == current {
            clearPending()
            return changed
        }
        if !hasPending || pendingID != candidate {
            pendingID = candidate
            pendingSince = now
            hasPending = true
            // 防抖为 0：不用等下一帧，当场切换
            if debounce <= 0 {
                current = candidate
                clearPending()
                return true
            }
            return changed
        }
        if now - pendingSince >= debounce {
            current = candidate
            clearPending()
            return true
        }
        return changed
    }

    mutating func reset() {
        current = nil
        clearPending()
    }

    private mutating func clearPending() {
        pendingID = nil
        hasPending = false
    }
}
