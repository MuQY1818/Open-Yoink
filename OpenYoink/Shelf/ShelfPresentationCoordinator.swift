import CoreGraphics

/// Single routing façade for every shelf presentation entry point. It keeps
/// trigger/menu/hot-key code independent of the concrete classic or Island
/// surface and guarantees the two presentations cannot be shown together.
@MainActor
final class ShelfPresentationCoordinator {
    private let windowController: ShelfWindowController

    init(windowController: ShelfWindowController) {
        self.windowController = windowController
    }

    var isExpanded: Bool { windowController.isShelfVisible }

    func applyCurrentMode(animated: Bool = false) {
        windowController.applyPresentationSettings(animated: animated)
    }

    func toggle(animated: Bool = true) {
        windowController.toggleShelf(animated: animated)
    }

    func toggleForKeyboard(animated: Bool = true) {
        windowController.toggleShelfForKeyboard(animated: animated)
    }

    func show(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        windowController.showShelf(animated: animated,
                                   takeKeyboardFocus: takeKeyboardFocus)
    }

    func hide(animated: Bool = true) {
        windowController.hideShelf(animated: animated)
    }

    @discardableResult
    func dragApproachedTop(at point: CGPoint) -> Bool {
        windowController.islandDragApproachedTop(at: point)
    }

    func dragEnded(imported: Bool) {
        windowController.islandDragEnded(imported: imported)
    }

    func shutdown() {
        windowController.shutdown()
    }
}
