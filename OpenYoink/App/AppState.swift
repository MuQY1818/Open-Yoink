import Foundation
import Observation

/// 全局应用状态（shelf 可见性等）。
///
/// SwiftUI 侧后续通过 `@Environment` 注入观察；AppKit 侧由
/// `ShelfWindowController` 在显示/隐藏面板时同步维护 `isShelfVisible`。
@MainActor
@Observable
final class AppState {
    /// Shelf 面板当前是否可见。
    private(set) var isShelfVisible = false

    func toggleShelf() {
        isShelfVisible.toggle()
    }

    func showShelf() {
        isShelfVisible = true
    }

    func hideShelf() {
        isShelfVisible = false
    }
}
