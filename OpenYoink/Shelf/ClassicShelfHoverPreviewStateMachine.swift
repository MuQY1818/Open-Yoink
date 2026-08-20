import Foundation

/// Pure transition model for the side-shelf edge-tab preview. AppKit owns the
/// timers and pointer monitors; this type owns only intent and cancellation.
struct ClassicShelfHoverPreviewStateMachine: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case idle
        case waitingForDwell
        case preview
        case persistent
    }

    enum Event: Sendable, Equatable {
        case tabEntered
        case tabExited
        case shelfEntered
        case shelfExited
        case dwellElapsed
        case exitElapsed
        case persistentInteraction
        case suppress
        case shelfHidden
    }

    enum Action: Sendable, Equatable {
        case scheduleDwell
        case cancelDwell
        case showPreview
        case scheduleExit
        case cancelExit
        case hidePreview
        case promoteToPersistent
    }

    private(set) var phase: Phase = .idle
    private var pointerInTab = false
    private var pointerInShelf = false

    var isPreview: Bool { phase == .preview }

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .tabEntered:
            pointerInTab = true
            if phase == .idle {
                phase = .waitingForDwell
                return [.scheduleDwell]
            }
            if phase == .preview { return [.cancelExit] }
        case .tabExited:
            pointerInTab = false
            if phase == .waitingForDwell {
                phase = .idle
                return [.cancelDwell]
            }
            if phase == .preview, !pointerInShelf { return [.scheduleExit] }
        case .shelfEntered:
            pointerInShelf = true
            if phase == .preview { return [.cancelExit] }
        case .shelfExited:
            pointerInShelf = false
            if phase == .preview, !pointerInTab { return [.scheduleExit] }
        case .dwellElapsed:
            guard phase == .waitingForDwell, pointerInTab else { return [] }
            phase = .preview
            return [.showPreview]
        case .exitElapsed:
            guard phase == .preview, !pointerInTab, !pointerInShelf else { return [] }
            phase = .idle
            return [.hidePreview]
        case .persistentInteraction:
            switch phase {
            case .waitingForDwell:
                phase = .persistent
                return [.cancelDwell, .promoteToPersistent]
            case .preview:
                phase = .persistent
                return [.cancelExit, .promoteToPersistent]
            case .idle:
                phase = .persistent
                return [.promoteToPersistent]
            case .persistent:
                return []
            }
        case .suppress:
            switch phase {
            case .waitingForDwell:
                phase = .idle
                pointerInTab = false
                return [.cancelDwell]
            case .preview:
                phase = .idle
                pointerInTab = false
                pointerInShelf = false
                return [.cancelExit, .hidePreview]
            case .idle, .persistent:
                return []
            }
        case .shelfHidden:
            let actions: [Action] = phase == .preview
                ? [.cancelExit]
                : phase == .waitingForDwell ? [.cancelDwell] : []
            phase = .idle
            pointerInTab = false
            pointerInShelf = false
            return actions
        }
        return []
    }
}
