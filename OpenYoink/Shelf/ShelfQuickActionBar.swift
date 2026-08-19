import AppKit
import SwiftUI

/// A compact, native action bar that appears only for an explicit selection.
/// Full labels are preferred; narrow shelves fall back to shorter visible
/// labels while preserving full VoiceOver labels, hints and tooltips.
struct ShelfQuickActionBar: View {
    @Environment(\.shelfActionRunner) private var runner
    let items: [ShelfItem]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullActionRow
                .fixedSize(horizontal: true, vertical: false)
            compactActionRow
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .frame(height: 36)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shelf.quickActions")
    }

    private var fullActionRow: some View {
        HStack(spacing: 4) {
            ForEach(ShelfAction.allCases) { action in
                actionButton(action, title: action.title)
            }
        }
    }

    /// At the 240pt minimum shelf width, three labeled native buttons cannot
    /// fit inside an expanded stack. Keep Share visible and move the two
    /// synchronous file actions into one keyboard-accessible overflow menu.
    private var compactActionRow: some View {
        HStack(spacing: 4) {
            actionButton(.share, title: ShelfAction.share.compactTitle)
            Menu {
                menuButton(.copyPath)
                menuButton(.revealInFinder)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .disabled(
                runner == nil
                    || (!ShelfActionCatalog.canPerform(.copyPath, on: items)
                        && !ShelfActionCatalog.canPerform(.revealInFinder, on: items))
            )
            .accessibilityIdentifier("shelf.quickActions.more")
        }
    }

    private func actionButton(_ action: ShelfAction, title: String) -> some View {
        ShelfActionButton(
            title: title,
            accessibilityLabel: action.title,
            accessibilityHint: action.accessibilityHint,
            systemImage: action.systemImage,
            identifier: action.accessibilityIdentifier,
            isEnabled: runner != nil && ShelfActionCatalog.canPerform(action, on: items),
            firesOnMouseDown: action == .share
        ) { anchorView in
            runner?.perform(action, on: items, relativeTo: anchorView)
        }
    }

    @ViewBuilder
    private func menuButton(_ action: ShelfAction) -> some View {
        Button {
            runner?.perform(action, on: items)
        } label: {
            Label(action.title, systemImage: action.systemImage)
        }
        .disabled(runner == nil || !ShelfActionCatalog.canPerform(action, on: items))
        .accessibilityHint(Text(action.accessibilityHint))
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }
}

/// AppKit bridge used for every quick action so the controls keep native focus
/// rings and VoiceOver behavior. Share alone sends on leftMouseDown because
/// NSSharingServicePicker explicitly requires that timing.
private struct ShelfActionButton: NSViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let systemImage: String
    let identifier: String
    let isEnabled: Bool
    let firesOnMouseDown: Bool
    let perform: @MainActor (NSView) -> Void

    @MainActor
    final class Coordinator: NSObject {
        var perform: @MainActor (NSView) -> Void

        init(perform: @escaping @MainActor (NSView) -> Void) {
            self.perform = perform
        }

        @objc func invoke(_ sender: NSButton) {
            perform(sender)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(perform: perform)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.invoke(_:))
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        button.toolTip = accessibilityHint
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityHelp(accessibilityHint)
        button.setAccessibilityIdentifier(identifier)
        button.isEnabled = isEnabled
        if firesOnMouseDown {
            button.sendAction(on: .leftMouseDown)
        }
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.perform = perform
        button.title = title
        button.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        button.toolTip = accessibilityHint
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityHelp(accessibilityHint)
        button.isEnabled = isEnabled
    }
}

#Preview("Quick actions") {
    ShelfQuickActionBar(items: [
        ShelfItem(kind: .file, path: "/tmp/example.txt", displayName: "example.txt")
    ])
    .frame(width: 300)
    .padding()
}
