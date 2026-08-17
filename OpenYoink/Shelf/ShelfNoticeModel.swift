import Foundation
import Observation

/// S10: shelf 内联轻量提示（拖入/物化失败等瞬态反馈）。
///
/// 选内联提示而非 NSAlert：失败发生在拖放会话末尾，模态框会打断「放下后
/// 继续操作」的心流，且 LSUIElement 下弹窗还需激活应用（见
/// `DragSessionController.askWhetherToRemove` 的说明）；标题栏下方一枚自动
/// 消失的胶囊既不阻塞也不打扰，与 OSLog 记录互补（日志仍保留完整错误）。
///
/// 由 `DropImportCoordinator` / `FilePromiseReceiver` 的失败路径调用 `show`，
/// `ShelfView` 观察 `message` 渲染胶囊。消息在调用点本地化后传入。
@MainActor
@Observable
final class ShelfNoticeModel {
    /// 当前展示的消息；nil 表示无提示。
    private(set) var message: String?

    /// 自动消失时长（秒）。
    static let displayDuration: TimeInterval = 4

    private var dismissalTask: Task<Void, Never>?

    /// 展示一条提示；新提示替换旧提示并重置计时。
    func show(_ message: String) {
        dismissalTask?.cancel()
        self.message = message
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.displayDuration))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}
