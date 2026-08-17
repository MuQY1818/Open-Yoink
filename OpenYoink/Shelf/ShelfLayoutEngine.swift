import Foundation

/// S9: shelf 布局纯逻辑（计划 §2.2）——目标屏判定、边缘吸附 frame、隐藏滑出
/// 方向、frame 夹取、custom frame 校验与回退。全部与 AppKit 解耦（NSScreen
/// 先纯值化为 `ScreenGeometry`），供 `ShelfWindowController` 调用、单测直测。
///
/// 坐标系：全局屏幕坐标（`NSEvent.mouseLocation` / `NSScreen.frame` 同一空间，
/// 原点在主屏左下角）。
enum ShelfLayoutEngine {
    /// 屏幕几何快照（NSScreen.frame / visibleFrame 的纯值化）。
    struct ScreenGeometry: Equatable, Sendable {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    /// 屏幕数组为空时的兜底尺寸（正常运行的 macOS 至少一屏，纯防护）。
    static let fallbackSize = CGSize(width: 320, height: 600)

    // MARK: - 目标屏判定

    /// 包含鼠标点的屏幕；无命中（鼠标所在屏刚被拔掉、坐标悬空）回退首屏（主屏）。
    /// 与 `ShelfWindowController.screen(containing:)` 同一规则。空数组返回 nil。
    static func targetScreen(mouseLocation: CGPoint, screens: [ScreenGeometry]) -> ScreenGeometry? {
        screens.first { $0.frame.contains(mouseLocation) } ?? screens.first
    }

    // MARK: - 边缘布局

    /// 边缘吸附 frame：贴 position 对应缘、占满 visibleFrame 全高。
    /// custom 无贴附缘概念，返回 nil（走 `validatedCustomFrame` 路径）。
    static func edgeAttachedFrame(position: SettingsStore.ShelfPosition,
                                  width: CGFloat,
                                  visibleFrame: CGRect) -> CGRect? {
        switch position {
        case .left:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                          width: width, height: visibleFrame.height)
        case .right:
            return CGRect(x: visibleFrame.maxX - width, y: visibleFrame.minY,
                          width: width, height: visibleFrame.height)
        case .custom:
            return nil
        }
    }

    /// 隐藏态 frame：左/右向贴附缘外侧平移一个面板宽度（滑出方向随位置反转）；
    /// custom 无滑向，原位返回（显示/隐藏只剩透明度动画）。
    static func hiddenFrame(for frame: CGRect, position: SettingsStore.ShelfPosition) -> CGRect {
        switch position {
        case .right: return frame.offsetBy(dx: frame.width, dy: 0)
        case .left: return frame.offsetBy(dx: -frame.width, dy: 0)
        case .custom: return frame
        }
    }

    // MARK: - 夹取与校验

    /// 把任意 frame 夹取进 visibleFrame：先按可用区域收缩超出尺寸，
    /// 再把原点移到最近的可用位置（最小位移）。已在区域内时返回自身。
    static func clamped(_ frame: CGRect, into visibleFrame: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, visibleFrame.width),
                          height: min(frame.height, visibleFrame.height))
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// 与 frame 交集面积最大的屏幕。按屏幕 frame（而非 visibleFrame）判定相交：
    /// 用户拖到 menu bar / Dock 遮挡区仍认该屏，夹取时再收进 visibleFrame。
    /// 与所有屏幕零面积相交（含空数组）返回 nil。
    static func bestIntersectingScreen(for frame: CGRect, screens: [ScreenGeometry]) -> ScreenGeometry? {
        var best: ScreenGeometry?
        var bestArea: CGFloat = 0
        for screen in screens where screen.frame.intersects(frame) {
            let intersection = screen.frame.intersection(frame)
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    /// 校验持久化 custom frame：宽度以设置为准（custom 模式下宽度设置仍生效），
    /// 高度与位置取持久化值，夹取进交集最大屏的 visibleFrame。
    /// 完全落出所有屏幕（所在屏已拔掉）返回 nil，由调用方回退默认位置。
    static func validatedCustomFrame(_ persisted: CGRect,
                                     width: CGFloat,
                                     screens: [ScreenGeometry]) -> CGRect? {
        guard let screen = bestIntersectingScreen(for: persisted, screens: screens) else { return nil }
        let sized = CGRect(x: persisted.minX, y: persisted.minY, width: width, height: persisted.height)
        return clamped(sized, into: screen.visibleFrame)
    }

    /// Space 切换后的在位校正：frame 仍与某屏相交 → 夹取回该屏 visibleFrame
    /// （正常情况下夹取结果是自身，即 no-op）；完全落出所有屏幕或屏幕数组为空
    /// 返回 nil，由调用方按 `targetFrame` 全量重算。
    ///
    /// 只校正、不按鼠标重新跟随 —— canJoinAllSpaces + stationary 让面板留在原
    /// 全局坐标出现在每个 Space，跟随鼠标反而会造成跨屏漂移。
    static func onscreenCorrection(for frame: CGRect, screens: [ScreenGeometry]) -> CGRect? {
        guard let screen = bestIntersectingScreen(for: frame, screens: screens) else { return nil }
        return clamped(frame, into: screen.visibleFrame)
    }

    // MARK: - 完整目标 frame 决策

    /// show / 屏幕参数变化 / 设置变更共用的目标 frame 决策：
    /// - 左/右：目标屏（鼠标所在屏，被拔掉回退主屏）visibleFrame 边缘吸附；
    /// - custom：持久化 frame 校验后使用；无持久化（首次选 custom）或持久化
    ///   已落出所有屏幕（屏幕被拔掉）→ 目标屏右缘默认 frame 起步；
    /// - 屏幕数组为空（防护）：原点兜底 frame。
    static func targetFrame(position: SettingsStore.ShelfPosition,
                            width: CGFloat,
                            mouseLocation: CGPoint,
                            screens: [ScreenGeometry],
                            persistedCustomFrame: CGRect?) -> CGRect {
        guard let screen = targetScreen(mouseLocation: mouseLocation, screens: screens) else {
            return CGRect(origin: .zero, size: fallbackSize)
        }
        switch position {
        case .left, .right:
            // left/right 必有 edge frame（nil 仅 custom 返回），兜底同防护分支。
            return edgeAttachedFrame(position: position, width: width, visibleFrame: screen.visibleFrame)
                ?? CGRect(origin: .zero, size: fallbackSize)
        case .custom:
            if let persistedCustomFrame,
               let valid = validatedCustomFrame(persistedCustomFrame, width: width, screens: screens) {
                return valid
            }
            // 首次 custom / 持久化所在屏已拔掉：右缘默认 frame 起步。
            return CGRect(x: screen.visibleFrame.maxX - width,
                          y: screen.visibleFrame.minY,
                          width: width,
                          height: screen.visibleFrame.height)
        }
    }
}
