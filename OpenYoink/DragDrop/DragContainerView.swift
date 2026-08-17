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
/// 插入位置近似（v1）：固定追加到末尾，指示线画在末卡片后缘。鼠标 y →
/// 网格行的精确映射需要 LazyVGrid 内各卡片几何（ScrollView 滚动偏移 +
/// adaptive 列数），留待 S10 打磨；追加语义与 Yoink 一致。
@MainActor
final class DragContainerView: NSView {
    private let store: ShelfStore
    private let coordinator: DropImportCoordinator
    private let dropTargetState: DropTargetState
    /// 持有的 hosting controller（addSubview 只 retain 视图，controller 需显式持有）。
    private let contentViewController: NSViewController

    init(store: ShelfStore,
         coordinator: DropImportCoordinator,
         dropTargetState: DropTargetState,
         contentViewController: NSViewController) {
        self.store = store
        self.coordinator = coordinator
        self.dropTargetState = dropTargetState
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
        dropTargetState.insertionIndex = store.items.count
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil else { return [] }
        return Self.hasImportableContent(sender.draggingPasteboard) ? .copy : []
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
        // v1 固定追加到末尾，与 draggingEntered 中的指示线位置一致。
        store.add(contentsOf: result.items)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropTargetState.reset()
    }

    // MARK: - Helpers

    private static func hasImportableContent(_ pasteboard: NSPasteboard) -> Bool {
        PasteboardTypes.preferredCategory(in: pasteboard.types ?? []) != nil
    }
}
