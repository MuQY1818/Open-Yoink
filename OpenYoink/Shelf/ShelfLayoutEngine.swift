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

    // MARK: - 紧凑高度常量（UX5）

    /// 网格列最小宽度与间距 —— 与 `ShelfView.columnWidth` / `.gridSpacing`
    /// 保持一致（列数推算必须与 SwiftUI adaptive 网格的排布一致）。
    static let gridColumnMinimum: CGFloat = 84
    static let gridSpacing: CGFloat = 12
    /// 面板内水平/垂直固定边距合计：窗口外层 padding 8×2 + 内容 padding 8×2。
    static let contentPadding: CGFloat = 32
    /// 内缘收起把手可见时（左/右锚，非 custom），内容区在把手侧额外让出的
    /// 水平宽度 —— 修复「把手与第一列卡片水平交叠」（把手 10pt 占带 +
    /// 2pt 间隙 = 内容从形状缘 12pt 起排，列数推算必须同步扣减）。
    static let handleContentAllowance: CGFloat = 4
    /// 标题栏块高度（含 VStack 间距）。
    static let headerHeight: CGFloat = 28
    /// ActivityStrip 自身与 VStack 间距。只在状态可见时预留，避免覆盖卡片。
    static let activityStripHeight: CGFloat = 86
    /// 两行语义标题的卡片高度估算：缩略图区 52 + 间距 5 + 名称行 ~30 +
    /// 卡片 padding 12。实际内容仍可纵向扩展并在达到屏幕上限后滚动。
    static let cardRowHeight: CGFloat = 100
    /// 空架时的紧凑总高度（让 `ShelfEmptyState` 插画居中即可，不撑满）。
    static let emptyStateHeight: CGFloat = 200
    /// 高度上限：屏幕可见高度的 80%（超出部分由网格 ScrollView 滚动）。
    static let maximumHeightFraction: CGFloat = 0.8

    // MARK: - 目标屏判定

    /// 包含鼠标点的屏幕；无命中（鼠标所在屏刚被拔掉、坐标悬空）回退首屏（主屏）。
    /// 与 `ShelfWindowController.screen(containing:)` 同一规则。空数组返回 nil。
    static func targetScreen(mouseLocation: CGPoint, screens: [ScreenGeometry]) -> ScreenGeometry? {
        screens.first { $0.frame.contains(mouseLocation) } ?? screens.first
    }

    // MARK: - 边缘布局

    /// UX5: 由面板宽度推算网格列数（与 SwiftUI `adaptive(minimum:spacing:)`
    /// 的排布规则一致：n 列需 n×min + (n-1)×spacing ≤ 可用宽度）。
    /// 扣减固定边距外的把手让位（`handleContentAllowance`）——columnCount
    /// 只服务左/右锚的紧凑高度计算，把手恒定可见；custom 不走此路径。
    static func columnCount(forPanelWidth width: CGFloat) -> Int {
        let gridWidth = width - contentPadding - handleContentAllowance
        return max(1, Int((gridWidth + gridSpacing) / (gridColumnMinimum + gridSpacing)))
    }

    /// UX5: 内容贴合高度 —— 标题栏 + 内边距 + 行高×行数 + 行间距；
    /// 上限为可见高度的 80%（超出滚动）；空架给紧凑空态高度。
    static func contentHeight(itemCount: Int,
                              panelWidth: CGFloat,
                              visibleHeight: CGFloat,
                              hasActivity: Bool = false) -> CGFloat {
        let cap = visibleHeight * maximumHeightFraction
        let activityHeight = hasActivity ? activityStripHeight : 0
        guard itemCount > 0 else { return min(emptyStateHeight + activityHeight, cap) }
        let columns = columnCount(forPanelWidth: panelWidth)
        let rows = max(1, (itemCount + columns - 1) / columns)
        let gridHeight = CGFloat(rows) * cardRowHeight + CGFloat(rows - 1) * gridSpacing
        return min(headerHeight + gridHeight + contentPadding + activityHeight, cap)
    }

    /// 边缘吸附 frame：贴 position 对应缘。UX5 起高度由内容决定
    /// （`contentHeight`）；EdgeTab 起垂直位置由 `edgeOffset`（0 = 可见区底缘、
    /// 1 = 顶缘）决定，默认 0.5 即旧版的垂直居中。custom 无贴附缘概念，
    /// 返回 nil（走 `validatedCustomFrame` 路径）。
    static func edgeAttachedFrame(position: SettingsStore.ShelfPosition,
                                  width: CGFloat,
                                  height: CGFloat,
                                  visibleFrame: CGRect,
                                  edgeOffset: CGFloat = 0.5) -> CGRect? {
        let clampedOffset = min(max(edgeOffset, 0), 1)
        let travel = max(0, visibleFrame.height - height)
        let y = visibleFrame.minY + travel * clampedOffset
        switch position {
        case .left:
            return CGRect(x: visibleFrame.minX, y: y,
                          width: width, height: height)
        case .right:
            return CGRect(x: visibleFrame.maxX - width, y: y,
                          width: width, height: height)
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

    // MARK: - EdgeTab 布局（屏幕边缘常驻拉环）

    /// 拉环常态露出宽度（贴缘方向的横向尺寸）。
    static let edgeTabWidth: CGFloat = 14
    /// 拉环高度（沿边方向的纵向尺寸）。
    static let edgeTabHeight: CGFloat = 84
    /// 强调态（拖拽投放暗示 / 投放悬停）的加宽加高：贴缘与中心 y 不变。
    static let edgeTabEmphasizedWidth: CGFloat = 18
    static let edgeTabEmphasizedHeight: CGFloat = 92
    /// 换边判定带：拖动拉环时光标越过屏幕中线后，距对面边缘小于该值即换边。
    static let edgeTabFlipDistance: CGFloat = 120

    /// 拉环常态 frame：贴 position 对应缘（与 shelf 同用 visibleFrame，避开
    /// Dock/menu bar 遮挡区）；`offset`（0 = 拉环中心贴可见区底缘、1 = 顶缘）
    /// 映射垂直位置并夹取。custom 无贴附缘，返回 nil（调用方不显示拉环）。
    ///
    /// offset 映射以拉环**中心**为准（而非底缘），与 `edgeTabOffset(forCenterY:)`
    /// 互为精确反函数 —— 拖动结束持久化 offset 后重建 frame 不跳位。
    static func edgeTabFrame(position: SettingsStore.ShelfPosition,
                             offset: CGFloat,
                             visibleFrame: CGRect) -> CGRect? {
        let x: CGFloat
        switch position {
        case .left: x = visibleFrame.minX
        case .right: x = visibleFrame.maxX - edgeTabWidth
        case .custom: return nil
        }
        let height = min(edgeTabHeight, visibleFrame.height)
        let clampedOffset = min(max(offset, 0), 1)
        let travel = max(0, visibleFrame.height - height)
        let centerY = visibleFrame.minY + height / 2 + travel * clampedOffset
        return CGRect(x: x, y: centerY - height / 2,
                      width: edgeTabWidth, height: height)
    }

    /// 拉环中心 y（拖动时由光标驱动）→ offset（0 = 底缘、1 = 顶缘），
    /// 夹取进 [0,1]。可见高度不大于拉环高度时无垂直行程，回退 0.5。
    static func edgeTabOffset(forCenterY centerY: CGFloat, visibleFrame: CGRect) -> CGFloat {
        let height = min(edgeTabHeight, visibleFrame.height)
        let travel = visibleFrame.height - height
        guard travel > 0 else { return 0.5 }
        let raw = (centerY - visibleFrame.minY - height / 2) / travel
        return min(max(raw, 0), 1)
    }

    /// 强调态 frame（拖拽暗示的轻微放大）：贴缘侧与中心 y 不变，宽度向屏内
    /// 加宽、高度对称加高，结果夹取进 visibleFrame。custom 无拉环，原样返回。
    static func edgeTabEmphasisFrame(from base: CGRect,
                                     position: SettingsStore.ShelfPosition,
                                     visibleFrame: CGRect) -> CGRect {
        let x: CGFloat
        switch position {
        case .left: x = visibleFrame.minX
        case .right: x = visibleFrame.maxX - edgeTabEmphasizedWidth
        case .custom: return base
        }
        let height = min(edgeTabEmphasizedHeight, visibleFrame.height)
        let frame = CGRect(x: x, y: base.midY - height / 2,
                           width: edgeTabEmphasizedWidth, height: height)
        return clamped(frame, into: visibleFrame)
    }

    /// 拖动拉环的换边判定：光标越过屏幕中线、且进入距对面边缘
    /// `flipDistance` 的带状区 → 应换到对侧。只逼近对缘但未过中线不换
    /// （窄屏防护：带与中线可能交叠）。custom 无贴附缘，永不换边。
    static func shouldFlipSide(position: SettingsStore.ShelfPosition,
                               cursorLocation: CGPoint,
                               screenFrame: CGRect,
                               flipDistance: CGFloat = edgeTabFlipDistance) -> Bool {
        switch position {
        case .right:
            return cursorLocation.x < screenFrame.midX
                && cursorLocation.x - screenFrame.minX < flipDistance
        case .left:
            return cursorLocation.x > screenFrame.midX
                && screenFrame.maxX - cursorLocation.x < flipDistance
        case .custom:
            return false
        }
    }

    // MARK: - 内缘收起把手（任务三）

    /// 把手宽度（点）。10pt，贴在形状贴缘侧；配合 `handleContentAllowance`
    /// （内容区从形状缘 12pt 起排）与第一列卡片无交叠——此前 14pt 无让位
    /// 会与首列卡片水平重叠 6pt（真机验收发现）。
    static let innerEdgeHandleWidth: CGFloat = 10

    /// 内缘收起把手的贴附侧。
    enum InnerEdgeHandleSide: Sendable, Equatable {
        /// 把手在面板左缘（右锚 shelf：把手朝屏幕中心，chevron 指向右缘）。
        case leading
        /// 把手在面板右缘（左锚 shelf）。
        case trailing
    }

    /// 把手侧判定（纯函数）：把手总在 shelf 朝向屏幕中心的内缘 ——
    /// 右锚 → 面板左缘（leading）；左锚 → 右缘（trailing）。
    /// custom 自由位置无贴附缘 → nil（不显示把手，标题栏拖动把手已覆盖）。
    static func innerEdgeHandleSide(for position: SettingsStore.ShelfPosition) -> InnerEdgeHandleSide? {
        switch position {
        case .right: return .leading
        case .left: return .trailing
        case .custom: return nil
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

    /// show / 屏幕参数变化 / 设置变更 / 项目增删共用的目标 frame 决策：
    /// - 左/右：目标屏（鼠标所在屏，被拔掉回退主屏）visibleFrame 边缘吸附，
    ///   UX5 起高度贴合内容（`itemCount` → 行数 → 紧凑高度，上限 80% 屏高），
    ///   EdgeTab 起垂直位置按 `edgeOffset`（默认 0.5 = 垂直居中）；
    /// - custom：持久化 frame 校验后使用（高度取持久化值，不随内容变化）；
    ///   无持久化（首次选 custom）或持久化已落出所有屏幕（屏幕被拔掉）→
    ///   目标屏右缘默认 frame 起步；
    /// - 屏幕数组为空（防护）：原点兜底 frame。
    static func targetFrame(position: SettingsStore.ShelfPosition,
                            width: CGFloat,
                            itemCount: Int,
                            hasActivity: Bool = false,
                            mouseLocation: CGPoint,
                            screens: [ScreenGeometry],
                            persistedCustomFrame: CGRect?,
                            edgeOffset: CGFloat = 0.5) -> CGRect {
        guard let screen = targetScreen(mouseLocation: mouseLocation, screens: screens) else {
            return CGRect(origin: .zero, size: fallbackSize)
        }
        switch position {
        case .left, .right:
            let height = contentHeight(itemCount: itemCount,
                                       panelWidth: width,
                                       visibleHeight: screen.visibleFrame.height,
                                       hasActivity: hasActivity)
            // left/right 必有 edge frame（nil 仅 custom 返回），兜底同防护分支。
            return edgeAttachedFrame(position: position, width: width, height: height,
                                     visibleFrame: screen.visibleFrame, edgeOffset: edgeOffset)
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
