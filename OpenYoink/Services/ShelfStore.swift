import Foundation
import Observation

/// Ordered, observable model of the shelf's contents.
///
/// Every mutation schedules a debounced save through the injected
/// `PersistenceController` (pass nil in tests to disable persistence).
/// Removing an item only drops the reference — the user's original file is
/// never deleted.
@MainActor
@Observable
final class ShelfStore {
    /// Top-level items in display order. Stack members live inside their parent
    /// item (`ShelfItem.children`) and are not part of this array.
    private(set) var items: [ShelfItem]

    /// Ids of the currently selected top-level items (multi-select).
    private(set) var selection: Set<UUID> = []

    private let persistence: PersistenceController?

    /// UX5/UX6: items 变更回调（每次触发持久化的项目变更后调用 —— 增、删、
    /// 移动、stack 操作、update）。ShelfWindowController 据此做紧凑高度动画
    /// 与空架自动隐藏；选择集变更不触发（不影响布局）。测试可不设置。
    var onItemsDidChange: (@MainActor () -> Void)?

    init(items: [ShelfItem] = [], persistence: PersistenceController? = nil) {
        self.items = items
        self.persistence = persistence
    }

    /// Creates a store preloaded with the persisted shelf contents.
    convenience init(persistence: PersistenceController) {
        self.init(items: persistence.load(), persistence: persistence)
    }

    // MARK: - Queries

    /// Selected items in display order.
    var selectedItems: [ShelfItem] {
        items.filter { selection.contains($0.id) }
    }

    func item(withID id: UUID) -> ShelfItem? {
        items.first { $0.id == id }
    }

    func index(ofItemWithID id: UUID) -> Int? {
        items.firstIndex { $0.id == id }
    }

    // MARK: - Adding

    /// Inserts an item at `index` (clamped to bounds), or appends when nil.
    func add(_ item: ShelfItem, at index: Int? = nil) {
        let insertionIndex = min(max(index ?? items.count, 0), items.count)
        items.insert(item, at: insertionIndex)
        persist()
    }

    /// Appends multiple items, preserving their order.
    func add(contentsOf newItems: [ShelfItem]) {
        add(contentsOf: newItems, at: nil)
    }

    /// Inserts multiple items starting at `index` (clamped to bounds),
    /// preserving their order; nil appends (S10/C6: drop-in at the indicated
    /// insertion position).
    func add(contentsOf newItems: [ShelfItem], at index: Int?) {
        guard !newItems.isEmpty else { return }
        let insertionIndex = min(max(index ?? items.count, 0), items.count)
        items.insert(contentsOf: newItems, at: insertionIndex)
        persist()
    }

    // MARK: - Removing (never deletes the user's original files)

    /// Removes the given items from the shelf and returns them.
    @discardableResult
    func remove(ids: Set<UUID>) -> [ShelfItem] {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return [] }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        persist()
        return removed
    }

    /// Removes the current selection.
    @discardableResult
    func removeSelection() -> [ShelfItem] {
        remove(ids: selection)
    }

    func removeAll() {
        guard !items.isEmpty else { return }
        items.removeAll()
        selection.removeAll()
        persist()
    }

    // MARK: - Reordering

    /// Manual reordering with SwiftUI `onMove` semantics: the elements at
    /// `offsets` are placed at `destination`, interpreted in the pre-move
    /// coordinate space. Out-of-range offsets are ignored.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let validOffsets = offsets.filter { items.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return }
        let moving = validOffsets.map { items[$0] }
        for index in validOffsets.reversed() {
            items.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(max(destination - removedBeforeDestination, 0), items.count)
        items.insert(contentsOf: moving, at: insertionIndex)
        persist()
    }

    // MARK: - Selection

    /// Selects `id`; replaces the selection unless `additive` is true (cmd-click).
    func select(_ id: UUID, additive: Bool = false) {
        guard item(withID: id) != nil else { return }
        if additive {
            selection.insert(id)
        } else {
            selection = [id]
        }
    }

    func toggleSelection(_ id: UUID) {
        guard item(withID: id) != nil else { return }
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    /// Replaces the selection; unknown ids are ignored.
    func setSelection(_ ids: Set<UUID>) {
        selection = ids.filter { item(withID: $0) != nil }
    }

    func selectAll() {
        selection = Set(items.map(\.id))
    }

    func clearSelection() {
        selection.removeAll()
    }

    // MARK: - Stacks

    /// Merges the given top-level items into a stack, preserving their current
    /// display order. The stack takes the position of the first selected item
    /// and becomes the only selected item. Returns nil when fewer than two of
    /// the ids exist on the shelf.
    @discardableResult
    func makeStack(from ids: Set<UUID>) -> UUID? {
        let members = items.filter { ids.contains($0.id) }
        guard members.count >= 2,
              let firstIndex = items.firstIndex(where: { ids.contains($0.id) }) else {
            return nil
        }
        let stack = ShelfItem(
            kind: .stack,
            // The UI shows a count badge; naming the stack after its first
            // member keeps the card recognizable.
            displayName: members[0].displayName,
            children: members
        )
        // `firstIndex` is the first selected index, so nothing before it is
        // removed and it stays valid as the insertion position.
        items.removeAll { ids.contains($0.id) }
        items.insert(stack, at: min(firstIndex, items.count))
        selection = [stack.id]
        persist()
        return stack.id
    }

    /// Expands a stack back into its members, inserted at the stack's position
    /// in their original order. The members become the selection. Returns false
    /// when the id does not belong to a non-empty stack.
    @discardableResult
    func unstack(_ stackID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == stackID }),
              items[index].kind == .stack,
              let children = items[index].children,
              !children.isEmpty else {
            return false
        }
        items.remove(at: index)
        items.insert(contentsOf: children, at: min(index, items.count))
        selection = Set(children.map(\.id))
        persist()
        return true
    }

    /// UX4: 从 stack 中移除一个子项（卡片悬停 ✕）。只移除引用，不删除用户
    /// 的原始文件。剩余 1 项时 stack 自动解散 —— 原位替换为普通项，选中
    /// 跟随存活项；剩余 0 项（防御性分支，stack 按构造至少 2 项）时移除
    /// stack 本身。id 不存在或子项不在该 stack 中时不做任何事，返回 false。
    @discardableResult
    func removeChild(_ childID: UUID, fromStack stackID: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == stackID }),
              items[index].kind == .stack,
              let children = items[index].children,
              children.contains(where: { $0.id == childID }) else {
            return false
        }
        let remaining = children.filter { $0.id != childID }
        switch remaining.count {
        case 0:
            items.remove(at: index)
            selection.remove(stackID)
        case 1:
            let survivor = remaining[0]
            items[index] = survivor
            if selection.contains(stackID) {
                selection = [survivor.id]
            }
        default:
            items[index].children = remaining
        }
        persist()
        return true
    }

    // MARK: - Item updates

    /// Replaces the item with the same id (e.g. after refreshing a bookmark
    /// that resolved as stale).
    func update(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        persist()
    }

    /// Sets the runtime-only stale flag. Not persisted — the flag is recomputed
    /// on every launch.
    func markStale(_ id: UUID, _ isStale: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isStale = isStale
    }

    // MARK: - Persistence

    private func persist() {
        persistence?.scheduleSave(items)
        // UX5/UX6: 一切会持久化的变更都是 items 变更（选择集不持久化、
        // 不触发）——高度动画/空架裁决的统一下发点。
        onItemsDidChange?()
    }
}
