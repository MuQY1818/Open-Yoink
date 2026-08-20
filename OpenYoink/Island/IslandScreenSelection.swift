import AppKit
import ColorSync

struct IslandScreenSelectionCandidate: Equatable {
    let id: String
    let frame: CGRect
    let isMain: Bool
}

enum IslandScreenSelectionPolicy {
    static func selectedID(
        for target: SettingsStore.IslandDisplayTarget,
        pointerPoint: CGPoint,
        screens: [IslandScreenSelectionCandidate]
    ) -> String? {
        guard !screens.isEmpty else { return nil }

        switch target {
        case .main:
            return screens.first(where: \.isMain)?.id ?? screens[0].id
        case .automatic:
            return screens.first(where: { $0.frame.contains(pointerPoint) })?.id
                ?? screens.first(where: \.isMain)?.id
                ?? screens[0].id
        case let .display(id):
            // Keep the stored physical-display choice when it is disconnected.
            // Runtime placement temporarily falls back to the main display;
            // reconnecting the display makes the same ID resolve again.
            return screens.contains(where: { $0.id == id })
                ? id
                : screens.first(where: \.isMain)?.id ?? screens[0].id
        }
    }
}

@MainActor
enum IslandScreenCatalog {
    struct Option: Identifiable, Equatable {
        let id: String
        let name: String
        let isMain: Bool
    }

    static func options() -> [Option] {
        NSScreen.screens.enumerated().map { index, screen in
            Option(id: identifier(for: screen),
                   name: screen.localizedName,
                   isMain: index == 0)
        }
    }

    static func selectedScreen(
        for target: SettingsStore.IslandDisplayTarget,
        pointerPoint: CGPoint
    ) -> NSScreen? {
        let screens = NSScreen.screens
        let candidates = screens.enumerated().map { index, screen in
            IslandScreenSelectionCandidate(
                id: identifier(for: screen),
                frame: screen.frame,
                isMain: index == 0
            )
        }
        guard let selectedID = IslandScreenSelectionPolicy.selectedID(
            for: target,
            pointerPoint: pointerPoint,
            screens: candidates
        ) else { return nil }
        return screens.first { identifier(for: $0) == selectedID }
            ?? screens.first
    }

    static func geometry(for screen: NSScreen)
        -> IslandGeometryResolver.ScreenGeometry {
        IslandGeometryResolver.ScreenGeometry(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea ?? .zero,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea ?? .zero
        )
    }

    static func identifier(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return "frame:\(Int(screen.frame.minX)):\(Int(screen.frame.minY)):"
                + "\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display:\(displayID)"
    }
}
