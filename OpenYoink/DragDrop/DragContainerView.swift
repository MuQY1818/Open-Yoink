import AppKit

/// 拖入悬停/插入位置状态，由 `DragContainerView`（NSDraggingDestination）驱动，
/// 经 `@Environment` 注入 `ShelfView` 渲染落点高亮与插入指示线（S3 预留样式）。
@MainActor
@Observable
final class DropTargetState {
    /// 有拖放正悬停在面板上且内容可导入。
    var isTargeted = false
    /// 插入位置（目标 index 卡片前缘；等于 items.count 时画在末卡片后缘）。
    var insertionIndex: Int?

    func reset() {
        isTargeted = false
        insertionIndex = nil
    }
}

/// Shelf 面板的拖入容器：NSView 子类实现 `NSDraggingDestination`（一致性由
/// NSView 继承），包住 `ShelfView` 的 NSHostingController 视图并装到 `ShelfPanel`。
///
/// 职责（实施计划 §2.3「拖入」）：
/// - 注册 `PasteboardTypes.dragInTypes` 全部类型（fileURL / file promise /
///   文本族 / 图片族 / URL）；
/// - 悬停时把高亮与插入位置桥给 `DropTargetState` → ShelfView；
/// - `performDragOperation` 调 `DropImportCoordinator` 分派，同步 items 直接
///   入架，异步物化（promise / 图片数据）完成后经回调逐个入架。
///
/// 插入位置（S10/C6）：`draggingEntered/Updated` 把鼠标位置（本视图坐标，
/// 左下原点）翻转到窗口 .global（左上原点）坐标，与 `ShelfGridGeometry`
/// 上报的卡片 frame 对齐后交 `DropInsertionLocator` 算出行列插入下标，
/// 实时驱动 ShelfView 的 `insertionIndex` 指示线；网格下方空白区与几何未
/// 就绪时回退「追加到末尾」（Yoink 语义）。
@MainActor
final class DragContainerView: NSView {
    private let store: ShelfStore
    private let coordinator: DropImportCoordinator
    private let dropTargetState: DropTargetState
    /// S10: 卡片网格几何（SwiftUI 上报），拖入插入定位用。
    private let gridGeometry: ShelfGridGeometry
    /// 持有的 hosting controller（addSubview 只 retain 视图，controller 需显式持有）。
    private let contentViewController: NSViewController

    init(store: ShelfStore,
         coordinator: DropImportCoordinator,
         dropTargetState: DropTargetState,
         gridGeometry: ShelfGridGeometry,
         contentViewController: NSViewController) {
        self.store = store
        self.coordinator = coordinator
        self.dropTargetState = dropTargetState
        self.gridGeometry = gridGeometry
        self.contentViewController = contentViewController
        super.init(frame: .zero)

        let contentView = contentViewController.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        registerForDraggedTypes(PasteboardTypes.dragInTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DragContainerView is created programmatically")
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // S5: 来自本应用卡片的拖出（draggingSource 非空）不接受回落到自身，
        // 避免「拖出又放回 shelf」产生重复引用。跨应用拖入 draggingSource 为 nil。
        guard sender.draggingSource == nil else { return [] }
        guard Self.hasImportableContent(sender.draggingPasteboard) else { return [] }
        dropTargetState.isTargeted = true
        updateInsertionIndex(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil else { return [] }
        guard Self.hasImportableContent(sender.draggingPasteboard) else { return [] }
        // C6: 拖动期间实时更新插入位置（行列映射见 DropInsertionLocator）。
        updateInsertionIndex(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTargetState.reset()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let result = coordinator.importItems(from: sender.draggingPasteboard) { [weak self] item in
            // 异步物化完成（promise / 图片数据）：逐个追加入架。
            self?.store.add(item)
        }
        guard result.handled else { return false }
        // C6: 同步项目插入到指示线所示位置（无指示线时追加到末尾）。
        store.add(contentsOf: result.items, at: dropTargetState.insertionIndex)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropTargetState.reset()
    }

    // MARK: - Helpers

    /// C6: 把拖放鼠标位置映射为网格插入下标。`draggingLocation` 在本视图
    /// （面板 contentView）坐标系（左下原点）；卡片 frame 由 SwiftUI 以窗口
    /// `.global`（左上原点）上报 —— 本视图铺满窗口内容区，翻转 y 即对齐。
    private func updateInsertionIndex(_ sender: NSDraggingInfo) {
        let location = sender.draggingLocation
        let point = CGPoint(x: location.x, y: bounds.height - location.y)
        let frames: [(index: Int, frame: CGRect)] = store.items.enumerated().compactMap { index, item in
            gridGeometry.cardFrames[item.id].map { (index, $0) }
        }
        dropTargetState.insertionIndex = DropInsertionLocator.insertionIndex(
            for: point,
            frames: frames,
            itemCount: store.items.count
        )
    }

    private static func hasImportableContent(_ pasteboard: NSPasteboard) -> Bool {
        PasteboardTypes.preferredCategory(in: pasteboard.types ?? []) != nil
    }
}
