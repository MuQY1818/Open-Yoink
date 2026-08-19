import AppKit

enum IslandGeometryResolver {
    struct ScreenGeometry: Equatable, Sendable {
        var frame: CGRect
        var visibleFrame: CGRect
        var safeAreaTop: CGFloat
        var auxiliaryTopLeftArea: CGRect
        var auxiliaryTopRightArea: CGRect
    }

    struct Layout: Equatable, Sendable {
        var hasPhysicalNotch: Bool
        var cameraHousingFrame: CGRect
        var compactFrame: CGRect
        var expandedFrame: CGRect
        var activationFrame: CGRect

        var cameraHousingWidth: CGFloat { cameraHousingFrame.width }
        var topInset: CGFloat { cameraHousingFrame.height }
    }

    static let compactWingWidth: CGFloat = 58
    /// A physical camera housing cannot receive pointer events. Extending the
    /// attached surface slightly below it creates one obvious click target while
    /// keeping the top edge fused to the screen hardware.
    static let physicalNotchClickExtension: CGFloat = 10
    static let floatingCompactSize = CGSize(width: 224, height: 38)
    static let maximumExpandedWidth: CGFloat = 520
    static let minimumExpandedWidth: CGFloat = 360
    static let expandedPreferredHeight: CGFloat = 430
    static let maximumExpandedHeightFraction: CGFloat = 0.6

    /// Chooses the screen under the pointer/drag and falls back to the first
    /// remaining screen after a display is unplugged. Keeping this selection
    /// pure makes negative-coordinate and hot-unplug behavior deterministic.
    static func resolve(at point: CGPoint, screens: [ScreenGeometry]) -> Layout? {
        guard let screen = screens.first(where: { $0.frame.contains(point) })
                ?? screens.first else { return nil }
        return resolve(screen: screen)
    }

    static func resolve(screen: ScreenGeometry) -> Layout {
        let left = screen.auxiliaryTopLeftArea
        let right = screen.auxiliaryTopRightArea
        // auxiliary areas have been observed in both screen-relative and global
        // coordinates. Their widths are stable in either representation, while
        // subtracting minX/maxX can place the housing on the wrong display.
        let notchWidth = max(0, screen.frame.width - left.width - right.width)
        let notchHeight = max(0, screen.safeAreaTop)
        let hasNotch = notchHeight >= 20
            && !left.isEmpty
            && !right.isEmpty
            && notchWidth >= 40

        let housing: CGRect
        let compact: CGRect
        let topAnchor: CGFloat
        let horizontalAnchor: CGFloat
        if hasNotch {
            housing = CGRect(x: screen.frame.minX + left.width,
                             y: screen.frame.maxY - notchHeight,
                             width: notchWidth,
                             height: notchHeight)
            let width = notchWidth + compactWingWidth * 2
            let compactHeight = notchHeight + physicalNotchClickExtension
            compact = CGRect(x: housing.midX - width / 2,
                             y: screen.frame.maxY - compactHeight,
                             width: width,
                             height: compactHeight)
            topAnchor = screen.frame.maxY
            horizontalAnchor = housing.midX
        } else {
            housing = .zero
            compact = CGRect(x: screen.visibleFrame.midX - floatingCompactSize.width / 2,
                             y: screen.visibleFrame.maxY - floatingCompactSize.height - 8,
                             width: floatingCompactSize.width,
                             height: floatingCompactSize.height)
            topAnchor = compact.maxY
            horizontalAnchor = screen.visibleFrame.midX
        }

        let availableWidth = max(240, screen.visibleFrame.width - 24)
        let expandedWidth = min(maximumExpandedWidth,
                                max(minimumExpandedWidth,
                                    min(availableWidth, maximumExpandedWidth)))
        let heightCap = max(260, screen.visibleFrame.height * maximumExpandedHeightFraction)
        let expandedHeight = min(expandedPreferredHeight, heightCap)
        let expanded = CGRect(x: horizontalAnchor - expandedWidth / 2,
                              y: topAnchor - expandedHeight,
                              width: expandedWidth,
                              height: expandedHeight)
        let activationHeight: CGFloat = 88
        let activation = CGRect(x: horizontalAnchor - expandedWidth / 2,
                                y: screen.frame.maxY - activationHeight,
                                width: expandedWidth,
                                height: activationHeight)
        return Layout(hasPhysicalNotch: hasNotch,
                      cameraHousingFrame: housing,
                      compactFrame: compact,
                      expandedFrame: expanded,
                      activationFrame: activation)
    }
}
