import CoreGraphics
import Foundation

/// 判断窗口是不是在“自己动”——切换桌面、调度中心、最小化、窗口管理软件的吸附动画——
/// 而不是被用户拖着。这种动画期间覆盖层不去追：窗口每帧都在动，追不上，看起来一卡一卡；
/// 干脆淡出，等动画停下来再按新布局出来。
///
/// 依据只有两条，都是零权限能拿到的：
/// - 拖动窗口时鼠标键一定按着，而且光标跟着窗口走；
/// - 系统动画期间鼠标不动，窗口却连续好几帧在动（一次性挪窗口只会动一帧）。
struct MotionDetector {
    /// 连续几帧有窗口在动才当成动画
    var streakToEnter = 3
    /// 连续几帧没有窗口在动才当成动画结束
    var stillToLeave = 6
    /// 这几帧内光标位移超过这个值就算用户在操作
    var mouseSlack: CGFloat = 4

    private var prevBounds: [CGWindowID: CGRect] = [:]
    private var mouseTrail: [CGPoint] = []
    private var motionStreak = 0
    private var stillStreak = 0
    private(set) var isAnimating = false
    /// 这一帧位置变了的窗口
    private(set) var moving: [CGWindowID] = []

    /// - parameter windows: 本帧的处理列表（z 序，前 → 后）
    /// - parameter buttonPressed: 鼠标键是否按着（`NSEvent.pressedMouseButtons != 0`）
    /// - parameter force: 明确知道正在切换桌面（`NSWorkspace.activeSpaceDidChangeNotification` 之后的一小段时间）
    /// - returns: 这一帧是否按“系统动画中”处理（覆盖层应当藏起来）
    mutating func update(windows: [WindowInfo], mouse: CGPoint, buttonPressed: Bool, force: Bool, now: TimeInterval) -> Bool {
        var moving: [CGWindowID] = []
        var current: [CGWindowID: CGRect] = [:]
        current.reserveCapacity(windows.count)
        for w in windows {
            current[w.id] = w.bounds
            if let prev = prevBounds[w.id], !Geometry.approxEqual(prev, w.bounds, tolerance: 0.5) { moving.append(w.id) }
        }
        prevBounds = current
        self.moving = moving
        let moved = !moving.isEmpty

        mouseTrail.append(mouse)
        if mouseTrail.count > 3 { mouseTrail.removeFirst(mouseTrail.count - 3) }
        let userDriving = buttonPressed || Self.spread(mouseTrail) > mouseSlack

        if moved {
            motionStreak += 1
            stillStreak = 0
        } else {
            motionStreak = 0
            stillStreak += 1
        }

        if !isAnimating {
            if force || (motionStreak >= streakToEnter && !userDriving) {
                isAnimating = true
                stillStreak = 0
            }
        } else if !force, stillStreak >= stillToLeave {
            isAnimating = false
        }
        return isAnimating
    }

    mutating func reset() {
        prevBounds = [:]
        mouseTrail = []
        motionStreak = 0
        stillStreak = 0
        isAnimating = false
        moving = []
    }

    /// 几个点里离得最远的两个的距离
    static func spread(_ points: [CGPoint]) -> CGFloat {
        var worst: CGFloat = 0
        for i in points.indices {
            for j in points.indices where j > i {
                let dx = points[i].x - points[j].x, dy = points[i].y - points[j].y
                worst = max(worst, (dx * dx + dy * dy).squareRoot())
            }
        }
        return worst
    }
}
