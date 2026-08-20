import SwiftUI

struct IslandShelfModuleView: View {
    @Environment(ShelfStore.self) private var shelfStore

    var body: some View {
        VStack(spacing: 8) {
            IslandModuleHeader(
                title: "Shelf",
                subtitle: String(localized: "\(shelfStore.items.count) items"),
                systemImage: "tray.full"
            )
            ShelfView(presentationStyle: .island)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
struct IslandTransfersView: View {
    @Environment(TransferStore.self) private var transferStore
    var onPerformRecovery: ((RecoveryAction) -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            IslandModuleHeader(
                title: "Transfers",
                subtitle: transferStore.hasVisibleActivity
                    ? String(localized: "Transferring content…")
                    : String(localized: "No active transfers"),
                systemImage: "arrow.up.arrow.down"
            )
            if transferStore.hasVisibleActivity {
                ShelfActivityStrip(onPerformRecovery: onPerformRecovery)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                IslandEmptyState(
                    title: "All caught up",
                    message: "New imports and deliveries appear here.",
                    systemImage: "checkmark.circle"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
