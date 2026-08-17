import Foundation

/// S10: shelf 网格几何共享模型 —— 顶层卡片在窗口内容坐标系（SwiftUI `.global`，
/// 左上原点）中的 frame，含滚动偏移。由 `ShelfView` 的网格 cell 经
/// `onGeometryChange` 实时上报；框选多选（C5）与拖入插入定位（C6，
/// `DragContainerView` → `DropInsertionLocator`）共用同一份数据，
/// 保证两条路径的坐标系一致。
@MainActor
@Observable
final class ShelfGridGeometry {
    /// 卡片 frame，按顶层项目 id 索引。Stack 浮层子项不上报（不参与网格定位）。
    var cardFrames: [UUID: CGRect] = [:]
}

/// C6: 拖入鼠标位置 → 网格插入下标的纯逻辑映射（与 AppKit/SwiftUI 解耦，单测覆盖）。
///
/// 输入为 (items 数组下标, 卡片 frame) 列表与鼠标点（同一坐标系）。自适应网格
/// 按行布局（同行 minY 一致），行内按 x 排序 —— 即阅读顺序与 items 顺序一致。
enum DropInsertionLocator {
    /// 行间空隙归并半径（网格间距 12pt 的一半）。
    nonisolated static let rowGapSlack: CGFloat = 6

    /// 计算插入下标（0...itemCount；itemCount = 追加到末尾，与 Yoink 语义一致）。
    ///
    /// 行领地纵向上扩/下延 `rowGapSlack`：行间空隙归属上一行；首行之上
    /// （如标题栏区域）与末行之下（网格空白区）不命中任何行 → 追加末尾。
    /// 行内取第一张水平中线在点右侧的卡片之下标；点在本行末卡片右侧 →
    /// 本行末尾之后（下一行首卡位置；末行即 itemCount）。
    /// 无可用几何（布局尚未上报）时回退追加末尾（S4 的既有行为）。
    nonisolated static func insertionIndex(for point: CGPoint,
                                           frames: [(index: Int, frame: CGRect)],
                                           itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let sorted = frames.sorted { $0.index < $1.index }
        guard !sorted.isEmpty else { return itemCount }

        // 行分组：同行卡片 minY 一致（4pt 容差抗浮点抖动）。
        var rows: [[(index: Int, frame: CGRect)]] = []
        for entry in sorted {
            if let rowMinY = rows.last?.first?.frame.minY,
               abs(entry.frame.minY - rowMinY) <= 4 {
                rows[rows.count - 1].append(entry)
            } else {
                rows.append([entry])
            }
        }

        for row in rows {
            let rowTop = (row.map(\.frame.minY).min() ?? 0) - rowGapSlack
            let rowBottom = (row.map(\.frame.maxY).max() ?? 0) + rowGapSlack
            guard point.y >= rowTop, point.y <= rowBottom else { continue }
            for entry in row where point.x < entry.frame.midX {
                return entry.index
            }
            let lastIndex = row.map(\.index).max() ?? (itemCount - 1)
            return min(lastIndex + 1, itemCount)
        }
        return itemCount
    }
}
