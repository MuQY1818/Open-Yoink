import CoreGraphics

/// Routing façade for the two independent shelf surfaces. Both surfaces share
/// one ShelfStore; this coordinator chooses the user's preferred entry point
/// without imposing mutual exclusion.
@MainActor
final class ShelfPresentationCoordinator {
    private let windowController: ShelfWindowController

    init(windowController: ShelfWindowController) {
        self.windowController = windowController
    }

    var isExpanded: Bool { windowController.isPreferredShelfExpanded }
    var isClassicVisible: Bool { windowController.isShelfVisible }
    var isIslandExpanded: Bool { windowController.isIslandExpanded }

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
        windowController.showPreferredShelf(animated: animated,
                                            takeKeyboardFocus: takeKeyboardFocus)
    }

    func hide(animated: Bool = true) {
        windowController.hidePreferredShelf(animated: animated)
    }

    func showClassic(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        windowController.showShelf(animated: animated,
                                   takeKeyboardFocus: takeKeyboardFocus)
    }

    func hideClassic(animated: Bool = true) {
        windowController.hideShelf(animated: animated)
    }

    func toggleClassic(animated: Bool = true) {
        if isClassicVisible {
            hideClassic(animated: animated)
        } else {
            showClassic(animated: animated)
        }
    }

    func showIslandShelf(animated: Bool = true, takeKeyboardFocus: Bool = false) {
        windowController.showIslandShelf(animated: animated,
                                         takeKeyboardFocus: takeKeyboardFocus)
    }

    func collapseIsland(animated: Bool = true) {
        windowController.collapseIsland(animated: animated)
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
