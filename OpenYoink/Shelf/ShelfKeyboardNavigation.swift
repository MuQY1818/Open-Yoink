import Foundation
import Observation

enum ShelfArrowDirection: Sendable, Equatable {
    case left
    case right
    case up
    case down
}

/// Pure grid navigation shared by the panel keyboard handler and tests.
enum ShelfKeyboardNavigator {
    static func destinationIndex(currentIndex: Int,
                                 itemCount: Int,
                                 columnCount: Int,
                                 direction: ShelfArrowDirection) -> Int {
        guard itemCount > 0 else { return 0 }
        let current = min(max(currentIndex, 0), itemCount - 1)
        let columns = max(1, columnCount)
        let proposed: Int
        switch direction {
        case .left: proposed = current - 1
        case .right: proposed = current + 1
        case .up: proposed = current - columns
        case .down: proposed = current + columns
        }
        return min(max(proposed, 0), itemCount - 1)
    }
}

/// Runtime-only keyboard focus and expanded-stack interaction state.
/// Focus is intentionally independent from ShelfStore.selection.
@MainActor
@Observable
final class ShelfInteractionState {
    var focusedItemID: UUID?
    var expandedStackID: UUID?
    var childSelection: Set<UUID> = []

    func visibleItems(in topLevelItems: [ShelfItem]) -> [ShelfItem] {
        guard let expandedStackID,
              let stack = topLevelItems.first(where: { $0.id == expandedStackID }),
              stack.kind == .stack else {
            return topLevelItems
        }
        return stack.children ?? []
    }

    func enterStack(_ stack: ShelfItem) {
        guard stack.kind == .stack, let children = stack.children, !children.isEmpty else { return }
        expandedStackID = stack.id
        childSelection.removeAll()
        focusedItemID = children[0].id
    }

    func exitStack() {
        let returningFocus = expandedStackID
        expandedStackID = nil
        childSelection.removeAll()
        focusedItemID = returningFocus
    }

    func normalize(for topLevelItems: [ShelfItem]) {
        if let expandedStackID {
            guard let stack = topLevelItems.first(where: { $0.id == expandedStackID }),
                  stack.kind == .stack else {
                self.expandedStackID = nil
                childSelection.removeAll()
                focusedItemID = topLevelItems.first?.id
                return
            }
            let childIDs = Set((stack.children ?? []).map(\.id))
            childSelection.formIntersection(childIDs)
            if let focusedItemID, childIDs.contains(focusedItemID) { return }
            focusedItemID = stack.children?.first?.id
            return
        }

        let topLevelIDs = Set(topLevelItems.map(\.id))
        if let focusedItemID, topLevelIDs.contains(focusedItemID) { return }
        self.focusedItemID = nil
    }
}
