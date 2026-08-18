import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// User-driven recovery for unavailable shelf items.
///
/// External references use NSOpenPanel and only publish the replacement after
/// a new bookmark and the complete shelf snapshot are durably written.
/// Managed copies never enter this flow; they route to Storage & Recovery.
@MainActor
final class ItemRecoveryController {
    private let store: ShelfStore
    private let bookmarkService: BookmarkService
    private let notices: ShelfNoticeModel
    private let openStorageRecovery: @MainActor () -> Void
    private var activePanel: NSOpenPanel?

    init(store: ShelfStore,
         bookmarkService: BookmarkService,
         notices: ShelfNoticeModel,
         openStorageRecovery: @escaping @MainActor () -> Void) {
        self.store = store
        self.bookmarkService = bookmarkService
        self.notices = notices
        self.openStorageRecovery = openStorageRecovery
    }

    /// Re-evaluates paths whenever the shelf opens, so a file removed or an
    /// external disk disconnected during the current app session is reflected.
    func refreshAll() {
        for item in store.items {
            let result = ItemAvailabilityResolver.refresh(
                item,
                bookmarkService: bookmarkService
            )
            guard result.item != item else { continue }
            if result.requiresPersistence {
                store.update(result.item)
            } else {
                store.updateRuntime(result.item)
            }
        }
    }

    func recover(_ item: ShelfItem) {
        switch item.availability {
        case .available:
            return
        case .managedCopyMissing:
            openStorageRecovery()
        case .externalFileOffline:
            beginRelocation(for: item)
        }
    }

    private func beginRelocation(for item: ShelfItem) {
        guard activePanel == nil, !item.isCut else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Locate Original File")
        panel.message = String(localized: "Choose the file or folder that this shelf item should reference.")
        panel.prompt = String(localized: "Reconnect")
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.canChooseDirectories = item.kind == .folder
        panel.canChooseFiles = item.kind != .folder
        if item.kind == .image {
            panel.allowedContentTypes = [.image]
        }
        if let path = item.path {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }

        activePanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.activePanel = nil
                guard response == .OK, let url = panel.url else { return }
                self.finishRelocation(itemID: item.id, to: url)
            }
        }
    }

    private func finishRelocation(itemID: UUID, to url: URL) {
        guard let current = store.itemRecursively(withID: itemID),
              current.availability == .externalFileOffline,
              !current.isCut else { return }
        do {
            let bookmark = try bookmarkService.createBookmark(for: url)
            guard let relocated = ItemRelocationPlanner.relocatedItem(
                from: current,
                to: url,
                bookmark: bookmark
            ) else { return }
            guard try store.updateRecursivelyAndPersistNow(relocated) else { return }
            notices.show(String(localized: "The shelf item was reconnected."))
        } catch {
            notices.show(String(localized: "The file could not be reconnected. The original shelf item was kept."))
        }
    }
}

private struct ItemRecoveryControllerEnvironmentKey: EnvironmentKey {
    static let defaultValue: ItemRecoveryController? = nil
}

extension EnvironmentValues {
    var itemRecoveryController: ItemRecoveryController? {
        get { self[ItemRecoveryControllerEnvironmentKey.self] }
        set { self[ItemRecoveryControllerEnvironmentKey.self] = newValue }
    }
}
