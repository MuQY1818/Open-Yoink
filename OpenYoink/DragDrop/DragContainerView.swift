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
    /// F-05: 当前悬停的拖入模式（⌘ 按下为 .move），驱动 ShelfView 的
    /// 高亮色调与「松开即移动/添加引用」提示。
    var mode: DropInMode = .copy

    func reset() {
        isTargeted = false
        insertionIndex = nil
        mode = .copy
    }
}

/// Shelf 面板的拖入容器：NSView 子类实现 `NSDraggingDestination`（一致性由
/// NSView 继承），包住 `ShelfView` 的 NSHostingController 视图并装到 `ShelfPanel`。
///
/// 职责（实施计划 §2.3「拖入」）：
/// - 注册 `PasteboardTypes.dragInTypes` 全部类型（fileURL / file promise /
///   文本族 / 图片族 / URL + 任务一的宽兜底泛型，「万能拖入」）；
/// - 悬停时把高亮与插入位置桥给 `DropTargetState` → ShelfView；
/// - `performDragOperation` 调 `DropImportCoordinator` 分派，同步 items 直接
///   入架，异步物化（promise / 图片数据 / 通用数据）完成后经回调逐个入架。
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
        guard sender.draggingSource == nil
                || coordinator.acceptsInternalTutorialDrag(sender.draggingPasteboard) else {
            return []
        }
        guard Self.hasImportableContent(sender.draggingPasteboard) else { return [] }
        dropTargetState.isTargeted = true
        updateDropMode(sender)
        updateInsertionIndex(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil
                || coordinator.acceptsInternalTutorialDrag(sender.draggingPasteboard) else {
            return []
        }
        guard Self.hasImportableContent(sender.draggingPasteboard) else { return [] }
        // F-05: ⌘ 状态在拖动期间可能变化，实时刷新模式（高亮色调/提示随之切换）。
        updateDropMode(sender)
        // C6: 拖动期间实时更新插入位置（行列映射见 DropInsertionLocator）。
        updateInsertionIndex(sender)
        // 始终回 .copy（含 ⌘ 剪切模式）：剪切由我们自管（copy+trash，
        // 见 CutMoveService），不依赖来源应用配合 .move —— 若回 .move，
        // Finder 源会在 drop 后自行删除原文件，与我们已做的 trash 重复且
        // 无法区分来源是否支持。光标徽标的一致性由 ShelfView 的模式提示承担。
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTargetState.reset()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // F-05: 落下瞬间以实时修饰键判定模式（⌘ = 剪切移入）。
        // 教程文件永远走引用导入；即使用户此刻按住 ⌘，也不能把应用自己
        // 创建的练习文件移入废纸篓/托管目录。
        let mode: DropInMode = coordinator.acceptsInternalTutorialDrag(sender.draggingPasteboard)
            ? .copy
            : DropImportCoordinator.dropMode(for: sender.draggingPasteboard,
                                              modifiers: NSEvent.modifierFlags)
        let result = coordinator.importItems(
            from: sender.draggingPasteboard,
            mode: mode,
            onManagedMoveReady: { [weak self] item in
                self?.commitManagedMove(item) ?? false
            },
            onPromisedItemReady: { [weak self] item in
                self?.commitPromisedItem(item) ?? false
            }
        ) { [weak self] item in
            // 异步物化完成（promise / 图片数据 / 剪切失败回退）：逐个追加入架。
            self?.store.add(item)
        }
        guard result.handled else { return false }
        // C6: 同步项目插入到指示线所示位置（无指示线时追加到末尾）。
        store.add(contentsOf: result.items, at: dropTargetState.insertionIndex)
        coordinator.noteSynchronousTutorialImport(from: sender.draggingPasteboard,
                                                   items: result.items)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropTargetState.reset()
    }

    // MARK: - Helpers

    /// F-05: 读取实时修饰键（`NSEvent.modifierFlags`，拖拽会话期间随 ⌘ 按放
    /// 变化）刷新悬停模式；只含 fileURL 的拖放才可能为 .move。
    private func updateDropMode(_ sender: NSDraggingInfo) {
        dropTargetState.mode = DropImportCoordinator.dropMode(for: sender.draggingPasteboard,
                                                              modifiers: NSEvent.modifierFlags)
    }

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

    /// 「Drop everything」语义（任务一）：宽兜底注册后能抵达这里的拖放几乎
    /// 总能由兜底链物化出内容，故只要声明了任意类型即接受高亮；零类型才拒绝。
    private static func hasImportableContent(_ pasteboard: NSPasteboard) -> Bool {
        PasteboardTypes.hasImportableContent(in: pasteboard.types ?? [])
    }

    /// ManagedMoveJournal 的提交边界：先同步保存包含 item 的 shelf snapshot，
    /// 再删除 transaction。若写盘失败，item 仍加入运行期 shelf 并继续安排常规
    /// 保存，但 journal 保留到下次启动恢复，托管副本也持续受清理保护。
    private func commitManagedMove(_ item: ShelfItem) -> Bool {
        do {
            try store.addAndPersistNow(item)
            coordinator.markManagedMoveCommitted(itemID: item.id)
            return true
        } catch {
            store.add(item)
            coordinator.noticeCenter.show(String(localized: "The moved item is being kept for recovery because the shelf could not be saved immediately."))
            return false
        }
    }

    /// Promise imports stay in PendingImportJournal until this synchronous
    /// shelf write succeeds. Unlike managed moves, a failed promise commit is
    /// not inserted into memory: Storage > Pending Imports remains the single,
    /// truthful retry path and the in-memory shelf cannot diverge from disk.
    private func commitPromisedItem(_ item: ShelfItem) -> Bool {
        do {
            try store.addAndPersistNow(item)
            return true
        } catch {
            coordinator.noticeCenter.show(String(localized: "The received file was kept safely. Open Recovery to finish importing it."))
            return false
        }
    }
}
