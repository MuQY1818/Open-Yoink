import AppKit
import SwiftUI

struct ShelfPresentationRootView: View {
    let presentationStyle: ShelfPresentationStyle
    var onPerformRecovery: ((RecoveryAction) -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        Group {
            if presentationStyle == .island {
                IslandRootView(
                    onPerformRecovery: onPerformRecovery,
                    onOpenSettings: onOpenSettings
                )
            } else {
                ShelfView()
            }
        }
    }
}

struct IslandRootView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ShelfStore.self) private var shelfStore
    @Environment(TransferStore.self) private var transferStore
    @Environment(IslandActivityCoordinator.self) private var coordinator
    @Environment(IslandModuleRegistry.self) private var registry
    @Environment(IslandTimerStore.self) private var timerStore
    @Environment(PowerSourceMonitor.self) private var powerMonitor
    @Environment(NowPlayingModuleStore.self) private var nowPlayingStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCompactHovering = false
    @State private var isCompactMediaControlHovering = false
    @State private var isCollapseControlHovering = false
    @State private var isSettingsControlHovering = false
    @State private var isSendingCompactMediaCommand = false
    @State private var mediaAccent = ArtworkAccent.fallback
    @State private var renderedSurfaceState: IslandSurfaceState = .compact

    var onPerformRecovery: ((RecoveryAction) -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            if renderedSurfaceState.isExpanded {
                expandedContent
                    .frame(width: coordinator.currentLayout?.expandedFrame.width,
                           height: coordinator.currentLayout?.expandedFrame.height,
                           alignment: .top)
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: IslandSurfaceRevealModifier(
                                progress: 0,
                                opacity: 0.82,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            ),
                            identity: IslandSurfaceRevealModifier(
                                progress: 1,
                                opacity: 1,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            )
                        ),
                        removal: .modifier(
                            active: IslandSurfaceRevealModifier(
                                progress: 0,
                                opacity: 0,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            ),
                            identity: IslandSurfaceRevealModifier(
                                progress: 1,
                                opacity: 1,
                                collapsedWidth: collapsedSurfaceWidth,
                                collapsedHeight: collapsedSurfaceHeight,
                                attachedToScreenTop: hasPhysicalNotch
                            )
                        )
                    ))
            } else {
                compactContent
                    .frame(width: coordinator.currentLayout?.compactFrame.width,
                           height: coordinator.currentLayout?.compactFrame.height,
                           alignment: .top)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("island.root")
        .onChange(of: coordinator.surfaceState, initial: true) { _, state in
            guard renderedSurfaceState != state else { return }
            if reduceMotion {
                renderedSurfaceState = state
            } else {
                withAnimation(surfaceAnimation(for: state)) {
                    renderedSurfaceState = state
                }
            }
        }
        .onChange(of: settings.islandTimerEnabled, initial: true) {
            registry.apply(settings: settings)
        }
        .onChange(of: settings.islandBatteryEnabled) {
            registry.apply(settings: settings)
        }
        .onChange(of: settings.islandShelfEnabled) {
            registry.apply(settings: settings)
        }
        .onChange(of: settings.islandMediaEnabled) {
            registry.apply(settings: settings)
        }
        .onChange(of: transferStore.currentTask, initial: true) { _, task in
            publishTransferActivity(task)
        }
        .onChange(of: nowPlayingStore.snapshot?.artworkData, initial: true) { _, data in
            mediaAccent = ArtworkAccentExtractor.accent(from: data)
        }
    }

    private func surfaceAnimation(for state: IslandSurfaceState) -> Animation {
        if state.isExpanded {
            return .smooth(
                duration: IslandMotion.expandContentDuration,
                extraBounce: 0
            )
        }
        return .smooth(
            duration: IslandMotion.collapseContentDuration,
            extraBounce: 0
        )
    }

    private var collapsedSurfaceHeight: CGFloat {
        coordinator.currentLayout?.compactFrame.height
            ?? IslandGeometryResolver.floatingCompactSize.height
    }

    private var collapsedSurfaceWidth: CGFloat {
        coordinator.currentLayout?.compactFrame.width
            ?? IslandGeometryResolver.floatingCompactSize.width
    }

    private var compactContent: some View {
        ZStack {
            Button {
                coordinator.show(module: defaultOpenModule)
            } label: {
                if hasPhysicalNotch {
                    physicalNotchCompactContent
                } else {
                    HStack(spacing: 8) {
                        compactLeading
                        compactSummary
                        Spacer(minLength: 4)
                        compactTrailing
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(compactAccessibilityLabel))
            .accessibilityHint(Text("Open OpenYoink Island"))
            .help(Text("Open OpenYoink Island"))

            compactMediaTransportOverlay
        }
        // The panel keeps a transparent strip below the real camera housing so
        // clicking remains easy. Only the content above draws pixels.
        .contentShape(Rectangle())
        .background {
            if !hasPhysicalNotch {
                compactSurfaceShape
                    .fill(Color.black.opacity(0.94))
            }
        }
        .overlay {
            if !hasPhysicalNotch && compactIsHighlighted {
                compactSurfaceShape
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            } else if !hasPhysicalNotch {
                compactSurfaceShape
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
        }
        .onHover { hovering in
            if reduceMotion {
                isCompactHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    isCompactHovering = hovering
                }
            }
        }
    }

    private var physicalNotchCompactContent: some View {
        ZStack(alignment: .top) {
            Color.clear
            IslandSurfaceShape(attachedToScreenTop: true, cornerRadius: 11)
                .fill(Color.black)
                .frame(height: coordinator.currentLayout?.topInset ?? 32)
            HStack(spacing: 0) {
                compactLeading
                    .frame(width: IslandGeometryResolver.compactWingWidth)
                Spacer()
                    .frame(width: coordinator.currentLayout?.cameraHousingWidth ?? 0)
                compactTrailing
                    .frame(width: IslandGeometryResolver.compactWingWidth)
            }
            .frame(maxWidth: .infinity)
            .frame(height: coordinator.currentLayout?.topInset ?? 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var compactLeading: some View {
        let activity = coordinator.primaryActivity()
        if activity?.moduleID == .media,
           let data = nowPlayingStore.snapshot?.artworkData,
           let image = NSImage(data: data) {
            CompactNowPlayingArtworkView(
                image: image,
                tint: mediaAccent.color,
                isHovered: compactIsHighlighted
            )
                .id(nowPlayingStore.snapshot?.title)
                .transition(.opacity.combined(with: .scale(scale: 0.86)))
        } else {
            Image(systemName: activity?.systemImage
                  ?? defaultModuleDescriptor?.systemImage
                  ?? "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(activityTint(activity))
                .opacity(compactIsHighlighted || activity != nil ? 1 : 0.72)
                .accessibilityHidden(true)
        }
    }

    private var compactTrailing: some View {
        Group {
            if coordinator.primaryActivity()?.moduleID == .media,
               let snapshot = nowPlayingStore.snapshot {
                if nowPlayingStore.supportsTransportControls {
                    Color.clear.frame(width: 30, height: 22)
                } else {
                    IslandEqualizerView(
                        isPlaying: snapshot.isPlaying,
                        reduceMotion: reduceMotion,
                        tint: mediaAccent.color,
                        rhythmSeed: mediaRhythmSeed
                    )
                    .scaleEffect(0.92)
                }
            } else if transferStore.hasVisibleActivity && !reduceMotion {
                ProgressView()
                    .controlSize(.mini)
            } else if case .running = timerStore.state {
                Text(timerStore.formattedRemaining)
                    .font(.caption2.monospacedDigit().weight(.semibold))
            } else if registry.isEnabled(.shelf) {
                Text("\(shelfStore.items.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            } else if registry.isEnabled(.battery), powerMonitor.snapshot.hasBattery {
                Text("\(powerMonitor.snapshot.percentage)%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .opacity(compactIsHighlighted || coordinator.primaryActivity() != nil ? 1 : 0.72)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var compactMediaTransportOverlay: some View {
        if coordinator.primaryActivity()?.moduleID == .media,
           nowPlayingStore.snapshot != nil,
           nowPlayingStore.supportsTransportControls {
            if hasPhysicalNotch {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    compactMediaTransportButton
                        .frame(width: IslandGeometryResolver.compactWingWidth,
                               height: coordinator.currentLayout?.topInset ?? 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    compactMediaTransportButton
                        .frame(width: 44, height: 38)
                }
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var compactMediaTransportButton: some View {
        let snapshot = nowPlayingStore.snapshot
        let isPlaying = snapshot?.isPlaying == true
        let showsTransportControl = isCompactMediaControlHovering || compactIsHighlighted
        let actionLabel = isPlaying ? String(localized: "Pause") : String(localized: "Play")
        return Button {
            guard !isSendingCompactMediaCommand else { return }
            Task {
                isSendingCompactMediaCommand = true
                _ = await nowPlayingStore.send(.togglePlayPause)
                isSendingCompactMediaCommand = false
            }
        } label: {
            ZStack {
                IslandEqualizerView(
                    isPlaying: isPlaying,
                    reduceMotion: reduceMotion,
                    tint: mediaAccent.color,
                    rhythmSeed: mediaRhythmSeed
                )
                .scaleEffect(showsTransportControl ? 0.84 : 0.92)
                .opacity(showsTransportControl ? 0 : 1)

                Group {
                    if isSendingCompactMediaCommand {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(mediaAccent.color)
                    }
                }
                .frame(width: 30, height: 22)
                .background {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .overlay {
                            Capsule().strokeBorder(mediaAccent.color.opacity(0.38),
                                                   lineWidth: 0.75)
                        }
                }
                .scaleEffect(showsTransportControl ? 1 : 0.82)
                .opacity(showsTransportControl ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!nowPlayingStore.supportsTransportControls
                  || isSendingCompactMediaCommand)
        .opacity(nowPlayingStore.supportsTransportControls ? 1 : 0.46)
        .onHover { hovering in
            if reduceMotion {
                isCompactMediaControlHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.16)) {
                    isCompactMediaControlHovering = hovering
                }
            }
        }
        .accessibilityLabel(Text(actionLabel))
        .accessibilityHint(Text("Control playback without expanding the Island"))
        .help(Text(actionLabel))
    }

    private var mediaRhythmSeed: UInt64 {
        guard let snapshot = nowPlayingStore.snapshot else { return 0 }
        return MusicVisualizerRhythm.seed(title: snapshot.title,
                                          artist: snapshot.artist,
                                          album: snapshot.album)
    }

    @ViewBuilder
    private var compactSummary: some View {
        if let activity = coordinator.primaryActivity() {
            VStack(alignment: .leading, spacing: 0) {
                Text(activity.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let detail = activity.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Text(String(localized: "OpenYoink Island"))
                .font(.caption.weight(.semibold))
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            if hasPhysicalNotch {
                physicalNotchModuleStrip
            } else {
                floatingIslandToolbar
                    .padding(.top, 12)
                    .padding(.horizontal, 14)
            }
            moduleContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(coordinator.selectedModule)
                .transition(.opacity)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .contentShape(expandedSurfaceShape)
        .background {
            ZStack {
                Color.black
                LinearGradient(
                    colors: [Color.white.opacity(0.035), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .clipShape(expandedSurfaceShape)
        }
        .overlay {
            if !hasPhysicalNotch {
                expandedSurfaceShape
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
        // A physical notch is attached to the display rather than floating
        // above it, so an elevation shadow reads as a translucent rectangle.
        // Keep elevation only for the fallback pill on displays without a notch.
        .shadow(color: hasPhysicalNotch ? .clear : .black.opacity(0.30),
                radius: hasPhysicalNotch ? 0 : 16,
                y: hasPhysicalNotch ? 0 : 8)
        .contextMenu {
            Button("Settings…") {
                openSettings()
            }
            Button(pinLabel) {
                coordinator.setPinned(coordinator.surfaceState != .pinned)
            }
            Button("Collapse Island") {
                coordinator.collapse()
            }
        }
    }

    private var hasPhysicalNotch: Bool {
        coordinator.currentLayout?.hasPhysicalNotch == true
    }

    private var compactIsHighlighted: Bool {
        isCompactHovering || coordinator.isPointerHovering
    }

    private var compactSurfaceShape: IslandSurfaceShape {
        IslandSurfaceShape(attachedToScreenTop: hasPhysicalNotch, cornerRadius: 13)
    }

    private var expandedSurfaceShape: IslandSurfaceShape {
        IslandSurfaceShape(attachedToScreenTop: hasPhysicalNotch, cornerRadius: 26)
    }

    private var physicalNotchModuleStrip: some View {
        let descriptors = visibleModuleDescriptors
        let leftCount = descriptors.count / 2
        let leadingModules = Array(descriptors.prefix(leftCount))
        let trailingModules = Array(descriptors.dropFirst(leftCount))
        let notchWidth = coordinator.currentLayout?.cameraHousingWidth ?? 0
        let notchHeight = coordinator.currentLayout?.topInset ?? 32
        let stripHeight = notchHeight
            + IslandGeometryResolver.physicalNotchClickExtension

        return ZStack(alignment: .top) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    settingsButton(size: 26)

                    ForEach(leadingModules) { descriptor in
                        physicalNotchModuleButton(descriptor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                Color.clear
                    .frame(width: notchWidth)
                    .allowsHitTesting(false)

                HStack(spacing: 2) {
                    ForEach(trailingModules) { descriptor in
                        physicalNotchModuleButton(descriptor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)

            // The hardware camera housing itself cannot receive mouse events.
            // Give its small visible chin an explicit, top-most collapse target
            // instead of relying on a background button underneath the module
            // tabs. This also prevents the adjacent media tab from stealing a
            // click intended for the center of the Island.
            Button {
                coordinator.collapse()
            } label: {
                VStack(spacing: 0) {
                    Color.clear.frame(height: notchHeight)
                    Capsule()
                        .fill(Color.white.opacity(isCollapseControlHovering ? 0.50 : 0.22))
                        .frame(width: 30, height: 3)
                        .padding(.top, 2)
                    Spacer(minLength: 0)
                }
                .frame(width: notchWidth, height: stripHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if reduceMotion {
                    isCollapseControlHovering = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        isCollapseControlHovering = hovering
                    }
                }
            }
            .accessibilityLabel(Text("Collapse Island"))
            .help(Text("Collapse Island"))
        }
        .frame(height: stripHeight)
    }

    private func physicalNotchModuleButton(
        _ descriptor: IslandModuleDescriptor
    ) -> some View {
        let isSelected = coordinator.selectedModule == descriptor.id
        let isEnabled = registry.isEnabled(descriptor.id)
        return Button {
            coordinator.selectedModule = descriptor.id
        } label: {
            Image(systemName: descriptor.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.72))
                .frame(width: 24, height: 24)
                .background {
                    Circle().fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
                }
                .opacity(isEnabled || isSelected ? 1 : 0.46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(descriptor.title))
        .help(Text(descriptor.title))
        .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
    }

    private var floatingIslandToolbar: some View {
        HStack(spacing: 10) {
            moduleNavigation
            Spacer(minLength: 4)
            settingsButton(size: 30)

            Button {
                coordinator.setPinned(coordinator.surfaceState != .pinned)
            } label: {
                Image(systemName: coordinator.surfaceState == .pinned
                      ? "pin.fill" : "pin")
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(pinLabel))
            .help(Text(pinLabel))

            Button {
                coordinator.collapse()
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Collapse Island"))
            .help(Text("Collapse Island"))
        }
        .frame(height: 38)
    }

    private func settingsButton(size: CGFloat) -> some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: size == 30 ? 13 : 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isSettingsControlHovering ? 1 : 0.72))
                .frame(width: size, height: size)
                .background {
                    Circle().fill(Color.white.opacity(isSettingsControlHovering ? 0.14 : 0.07))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if reduceMotion {
                isSettingsControlHovering = hovering
            } else {
                withAnimation(.easeOut(duration: 0.14)) {
                    isSettingsControlHovering = hovering
                }
            }
        }
        .accessibilityLabel(Text("Settings…"))
        .help(Text("Settings…"))
    }

    private func openSettings() {
        // The Island panel intentionally sits above ordinary app windows.
        // Collapse it before presenting Settings so it cannot cover the
        // controls the user just asked to reach.
        coordinator.collapse()
        onOpenSettings?()
    }

    private var pinLabel: String {
        coordinator.surfaceState == .pinned
            ? String(localized: "Unpin Island")
            : String(localized: "Pin Island")
    }

    private var moduleNavigation: some View {
        HStack(spacing: 3) {
            ForEach(visibleModuleDescriptors) { descriptor in
                let isSelected = coordinator.selectedModule == descriptor.id
                let isEnabled = registry.isEnabled(descriptor.id)
                Button {
                    coordinator.selectedModule = descriptor.id
                } label: {
                    Image(systemName: descriptor.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.7))
                        .frame(width: 30, height: 30)
                        .background {
                            Circle()
                                .fill(isSelected
                                      ? Color.accentColor.opacity(0.16)
                                      : Color.clear)
                        }
                        .contentShape(Circle())
                        .opacity(isEnabled || isSelected ? 1 : 0.46)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(descriptor.title))
                .help(Text(descriptor.title))
                .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
            }
        }
        .padding(4)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.34))
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }
        }
    }

    /// Now Playing stays discoverable while disabled, but remains explicitly
    /// opt-in. Other optional modules disappear when the user turns them off.
    private var visibleModuleDescriptors: [IslandModuleDescriptor] {
        registry.descriptors
            .filter { registry.isEnabled($0.id) || $0.id == .media }
            .sorted { $0.order < $1.order }
    }

    @ViewBuilder
    private var moduleContent: some View {
        switch coordinator.selectedModule {
        case .shelf:
            IslandShelfModuleView()
        case .transfers:
            IslandTransfersView(onPerformRecovery: onPerformRecovery)
        case .timer:
            IslandTimerView()
        case .battery:
            IslandBatteryView()
        case .media:
            IslandNowPlayingView()
        }
    }

    private var compactAccessibilityLabel: String {
        if let activity = coordinator.primaryActivity() {
            return [activity.title, activity.detail].compactMap { $0 }.joined(separator: ", ")
        }
        if registry.isEnabled(.shelf) {
            return String(localized: "OpenYoink Island, \(shelfStore.items.count) shelf items")
        }
        return String(localized: "OpenYoink Island")
    }

    private var defaultModuleDescriptor: IslandModuleDescriptor? {
        if registry.isEnabled(coordinator.selectedModule) {
            return registry.descriptors.first { $0.id == coordinator.selectedModule }
        }
        return registry.enabledDescriptors.first
    }

    private var defaultOpenModule: IslandModuleID {
        if let activity = coordinator.primaryActivity(), registry.isEnabled(activity.moduleID) {
            return activity.moduleID
        }
        return defaultModuleDescriptor?.id ?? .transfers
    }

    private func activityTint(_ activity: IslandActivity?) -> Color {
        switch activity?.priority {
        case .criticalBattery: return .red
        case .timerFinished: return .orange
        case .transfer, .userDrag: return .accentColor
        default: return .white
        }
    }

    private func publishTransferActivity(_ task: TransferTask?) {
        guard let task else {
            coordinator.removeActivity(id: "transfer")
            return
        }
        coordinator.publish(.init(id: "transfer", moduleID: .transfers,
                                  priority: .transfer,
                                  title: transferTitle(task), detail: nil,
                                  systemImage: transferSystemImage(task),
                                  expiresAt: nil))
    }

    private func transferTitle(_ task: TransferTask) -> String {
        switch task.phase {
        case .preparing, .receiving, .finalizing:
            return String(localized: "Transferring content…")
        case .targetAccepted, .delivered:
            return String(localized: "Transfer complete")
        case .partiallySucceeded:
            return String(localized: "Transfer completed with warnings")
        case .failed:
            return String(localized: "Transfer failed")
        case .cancelled:
            return String(localized: "Transfer cancelled")
        }
    }

    private func transferSystemImage(_ task: TransferTask) -> String {
        switch task.phase {
        case .failed: return "exclamationmark.octagon.fill"
        case .partiallySucceeded: return "exclamationmark.triangle.fill"
        case .delivered, .targetAccepted: return "checkmark.circle.fill"
        default: return "arrow.up.arrow.down"
        }
    }
}

/// Screen-attached surfaces use shallow inward top corners and fuller convex
/// bottom corners. The shape stays flush with the screen edge while avoiding
/// the square, pasted-on silhouette of a regular rounded rectangle.
private struct IslandSurfaceShape: InsettableShape {
    var attachedToScreenTop: Bool
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> IslandSurfaceShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard attachedToScreenTop else {
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .path(in: rect)
        }

        let bottomRadius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let topCut = min(7, max(4, bottomRadius * 0.45))
        let leftBody = rect.minX + topCut
        let rightBody = rect.maxX - topCut
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: leftBody, y: rect.minY + topCut),
            control1: CGPoint(x: rect.minX + topCut * 0.55, y: rect.minY),
            control2: CGPoint(x: leftBody, y: rect.minY + topCut * 0.45)
        )
        path.addLine(to: CGPoint(x: leftBody, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: leftBody + bottomRadius, y: rect.maxY),
            control: CGPoint(x: leftBody, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightBody - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rightBody, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rightBody, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightBody, y: rect.minY + topCut))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rightBody, y: rect.minY + topCut * 0.45),
            control2: CGPoint(x: rect.maxX - topCut * 0.55, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct IslandSelectedAccessibilityModifier: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        if selected {
            content.accessibilityAddTraits(.isSelected)
        } else {
            content
        }
    }
}

private enum IslandVisualStyle {
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.68)
    static let tertiaryText = Color.white.opacity(0.46)
    static let controlFill = Color.white.opacity(0.09)
    static let selectedFill = Color.accentColor.opacity(0.22)
    static let cardFill = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.08)
}

private struct IslandPressFeedbackStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.96)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12),
                       value: configuration.isPressed)
    }
}

private struct IslandProgressTrack: View {
    let progress: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.13))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 4)
        .accessibilityValue(Text("\(Int(min(max(progress, 0), 1) * 100)) percent"))
    }
}

private struct IslandModuleHeader: View {
    let title: LocalizedStringKey
    let subtitle: String?
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.08)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
        }
        .frame(height: 34)
    }
}

private struct IslandEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.46))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 270)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IslandShelfModuleView: View {
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

private struct IslandTransfersView: View {
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

private struct IslandTimerView: View {
    private enum Page: Hashable {
        case timer
        case history
    }

    @Environment(IslandTimerStore.self) private var timerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var customMinutes = 25
    @State private var page: Page = .timer

    var body: some View {
        VStack(spacing: 10) {
            IslandModuleHeader(
                title: "Timer",
                subtitle: page == .timer
                    ? timerSubtitle
                    : String(localized: "Focus history"),
                systemImage: timerStore.mode.systemImage
            )
            .overlay(alignment: .trailing) {
                timerPageSwitcher
            }

            Group {
                if page == .timer {
                    timerControls
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                } else {
                    IslandFocusHistoryView()
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            customMinutes = timerStore.mode.defaultMinutes
        }
        .onChange(of: timerStore.mode) { _, mode in
            customMinutes = mode.defaultMinutes
        }
    }

    private var timerControls: some View {
        HStack(spacing: 18) {
            IslandTimerDial(
                timeText: timerDisplayText,
                stateText: timerDialState,
                systemImage: timerStateSymbol,
                remainingFraction: timerDialRemainingFraction,
                tint: timerTint,
                tick: timerStore.tick,
                isRunning: isRunning,
                reduceMotion: reduceMotion
            )
            .frame(width: 146, height: 146)

            VStack(spacing: 7) {
                if timerStore.state == .idle {
                    timerModeSelector
                    timerIntention
                    timerPresets
                    timerSetupRow
                } else {
                    timerStatusSummary
                    timerRunningControls
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
    }

    private var timerPageSwitcher: some View {
        HStack(spacing: 2) {
            timerPageButton(.timer,
                            systemImage: "timer",
                            accessibilityLabel: "Timer controls")
            timerPageButton(.history,
                            systemImage: "chart.dots.scatter",
                            accessibilityLabel: "Focus history")
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay {
            Capsule().strokeBorder(IslandVisualStyle.hairline, lineWidth: 1)
        }
    }

    private func timerPageButton(
        _ target: Page,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey
    ) -> some View {
        let selected = page == target
        return Button {
            if reduceMotion {
                page = target
            } else {
                withAnimation(.smooth(duration: 0.26)) {
                    page = target
                }
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.white : IslandVisualStyle.tertiaryText)
                .frame(width: 27, height: 24)
                .background {
                    if selected {
                        Capsule().fill(Color.white.opacity(0.11))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(Text(accessibilityLabel))
        .modifier(IslandSelectedAccessibilityModifier(selected: selected))
    }

    private var timerModeSelector: some View {
        HStack(spacing: 5) {
            ForEach(IslandTimerStore.Mode.allCases, id: \.self) { mode in
                let isSelected = timerStore.mode == mode
                Button {
                    timerStore.selectMode(mode)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 9, weight: .bold))
                        Text(mode.title)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Color.white : IslandVisualStyle.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background {
                        Capsule()
                            .fill(isSelected ? modeTint(mode).opacity(0.24)
                                             : IslandVisualStyle.controlFill)
                            .overlay {
                                Capsule().strokeBorder(
                                    isSelected ? modeTint(mode).opacity(0.64)
                                               : IslandVisualStyle.hairline,
                                    lineWidth: 1
                                )
                            }
                    }
                }
                .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
                .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
            }
        }
    }

    @ViewBuilder
    private var timerIntention: some View {
        if timerStore.mode == .focus {
            HStack(spacing: 7) {
                Image(systemName: "scope")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(timerTint)
                TextField(String(localized: "What will you focus on?"), text: goalBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandVisualStyle.primaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(Capsule().fill(Color.white.opacity(0.065)))
            .overlay {
                Capsule().strokeBorder(timerTint.opacity(0.20), lineWidth: 1)
            }
        } else {
            HStack(spacing: 7) {
                Image(systemName: timerStore.mode.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(timerStore.mode == .shortBreak
                     ? String(localized: "Take a breath")
                     : String(localized: "Step away and recharge"))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(timerTint)
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(Capsule().fill(timerTint.opacity(0.075)))
            .overlay {
                Capsule().strokeBorder(timerTint.opacity(0.18), lineWidth: 1)
            }
        }
    }

    private var timerPresets: some View {
        HStack(spacing: 5) {
            ForEach(modePresets, id: \.self) { minutes in
                let isSelected = customMinutes == minutes
                Button {
                    if reduceMotion {
                        customMinutes = minutes
                    } else {
                        withAnimation(.snappy(duration: 0.22)) {
                            customMinutes = minutes
                        }
                    }
                } label: {
                    Text("\(minutes)m")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected
                                         ? Color.white
                                         : IslandVisualStyle.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 27)
                        .background {
                            Capsule()
                                .fill(isSelected
                                      ? AnyShapeStyle(LinearGradient(
                                        colors: [timerTint.opacity(0.92),
                                                 timerTint.opacity(0.58)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                      ))
                                      : AnyShapeStyle(IslandVisualStyle.controlFill))
                                .overlay {
                                    Capsule().strokeBorder(
                                        isSelected ? Color.white.opacity(0.20)
                                            : IslandVisualStyle.hairline,
                                        lineWidth: 1
                                    )
                                }
                        }
                }
                .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
                .accessibilityLabel(Text("\(minutes) minutes"))
                .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
            }
        }
    }

    private var timerSetupRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                compactControlButton("minus") {
                    customMinutes = max(1, customMinutes - 1)
                }
                Text("\(customMinutes) min")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IslandVisualStyle.primaryText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(minWidth: 58)
                compactControlButton("plus") {
                    customMinutes = min(180, customMinutes + 1)
                }
            }
            .padding(.horizontal, 3)
            .background(Capsule().fill(IslandVisualStyle.controlFill))

            Spacer(minLength: 4)

            Button {
                timerStore.start(minutes: Double(customMinutes))
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .frame(height: 35)
                    .background {
                        Capsule().fill(Color.white)
                    }
                    .shadow(color: timerTint.opacity(0.32), radius: 8, y: 3)
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        }
    }

    private var timerStatusSummary: some View {
        HStack(spacing: 9) {
            Image(systemName: timerStateSymbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(timerTint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(timerTint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(timerDialState)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IslandVisualStyle.primaryText)
                Text(timerStatusDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IslandVisualStyle.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Capsule().fill(timerTint.opacity(0.08)))
        .overlay {
            Capsule().strokeBorder(timerTint.opacity(0.16), lineWidth: 1)
        }
    }

    private var timerRunningControls: some View {
        HStack(spacing: 10) {
            timerPrimaryAction
            Button(role: .destructive) { timerStore.reset() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Capsule().fill(IslandVisualStyle.controlFill))
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var timerSubtitle: String {
        switch timerStore.state {
        case .idle: return String(localized: "Ready to flow")
        case .running: return timerStore.mode.title
        case .paused: return String(localized: "Paused")
        case .finished: return String(localized: "Timer finished")
        }
    }

    private var timerDisplayText: String {
        if timerStore.state == .idle {
            return String(format: "%02d:00", customMinutes)
        }
        return timerStore.formattedRemaining
    }

    private var timerDialRemainingFraction: Double {
        timerStore.state == .idle ? 1 : timerStore.remainingFraction
    }

    private var isRunning: Bool {
        if case .running = timerStore.state { return true }
        return false
    }

    private var timerDialState: String {
        switch timerStore.state {
        case .idle, .running: return timerStore.mode.title
        case .paused: return String(localized: "Paused")
        case .finished: return String(localized: "Time's up")
        }
    }

    private var timerStatusDetail: String {
        let trimmedGoal = timerStore.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        switch timerStore.state {
        case .idle: return String(localized: "Ready to flow")
        case .running where timerStore.mode == .focus && !trimmedGoal.isEmpty:
            return trimmedGoal
        case .running: return String(localized: "Countdown is running")
        case .paused: return String(localized: "Continue whenever you're ready")
        case .finished: return String(localized: "Your timer is complete")
        }
    }

    private var timerStateSymbol: String {
        switch timerStore.state {
        case .idle: return timerStore.mode.systemImage
        case .running: return "hourglass.bottomhalf.filled"
        case .paused: return "pause.fill"
        case .finished: return "checkmark"
        }
    }

    private var timerTint: Color {
        switch timerStore.state {
        case .idle, .running, .paused: return modeTint(timerStore.mode)
        case .finished: return .green
        }
    }

    private var modePresets: [Int] {
        switch timerStore.mode {
        case .focus: [15, 25, 45]
        case .shortBreak: [5, 10, 15]
        case .longBreak: [15, 20, 30]
        }
    }

    private var goalBinding: Binding<String> {
        Binding(get: { timerStore.goal }, set: { timerStore.setGoal($0) })
    }

    private func modeTint(_ mode: IslandTimerStore.Mode) -> Color {
        switch mode {
        case .focus: Color(red: 0.22, green: 0.86, blue: 0.48)
        case .shortBreak: Color(red: 0.26, green: 0.67, blue: 1.0)
        case .longBreak: Color(red: 0.66, green: 0.43, blue: 0.98)
        }
    }

    @ViewBuilder
    private var timerPrimaryAction: some View {
        switch timerStore.state {
        case .running:
            timerStateButton("Pause", systemImage: "pause.fill") { timerStore.pause() }
        case .paused:
            timerStateButton("Resume", systemImage: "play.fill") { timerStore.resume() }
        case .finished:
            timerStateButton("Done", systemImage: "checkmark") {
                timerStore.acknowledgeFinished()
            }
        case .idle:
            EmptyView()
        }
    }

    private func timerStateButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Capsule().fill(timerTint))
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
    }

    private func compactControlButton(
        _ symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
    }
}

private struct IslandFocusHistoryView: View {
    private struct Cell: Equatable {
        let date: Date
        let period: IslandFocusPeriod
    }

    @Environment(IslandTimerStore.self) private var timerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var weekOffset = 0
    @State private var hoveredCell: Cell?
    @State private var selectedCell: Cell?

    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            focusSummary

            VStack(spacing: 10) {
                weekNavigation
                heatmap
                heatmapLegend
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
    }

    private var focusSummary: some View {
        let cell = hoveredCell ?? selectedCell
        let summaryDate = cell?.date ?? Date()
        let summaryPeriod = cell?.period
        let duration = IslandFocusStatistics.duration(
            timerStore.sessions,
            on: summaryDate,
            period: summaryPeriod,
            calendar: calendar
        )
        let sessionCount = IslandFocusStatistics.sessions(
            timerStore.sessions,
            on: summaryDate,
            period: summaryPeriod,
            calendar: calendar
        ).count
        let summaryTint = summaryPeriod?.tint ?? focusGreen

        return VStack(alignment: .leading, spacing: 5) {
            Text(summaryTitle(for: cell))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(summaryTint)
                .textCase(.uppercase)
                .lineLimit(1)

            Text(focusDurationText(duration))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(IslandVisualStyle.primaryText)
                .monospacedDigit()
                .contentTransition(.numericText())

            Label(
                String.localizedStringWithFormat(
                    String(localized: "%lld focus sessions"),
                    sessionCount
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(IslandVisualStyle.secondaryText)
            .lineLimit(1)

            Label(
                String.localizedStringWithFormat(
                    String(localized: "%lld day streak"),
                    IslandFocusStatistics.currentStreak(
                        timerStore.sessions,
                        at: Date(),
                        calendar: calendar
                    )
                ),
                systemImage: "flame.fill"
            )
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(focusGreen)
            .lineLimit(1)

            if timerStore.sessions.isEmpty {
                Text("Complete a focus session to start your map.")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(IslandVisualStyle.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(width: 136, alignment: .leading)
        .frame(minHeight: 138, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay {
                    LinearGradient(
                        colors: [summaryTint.opacity(0.11), .clear, .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16,
                                                style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
                }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: cell)
    }

    private var weekNavigation: some View {
        HStack(spacing: 6) {
            Button {
                changeWeek(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(Text("Previous week"))

            Spacer(minLength: 0)

            Text(weekRangeText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .monospacedDigit()
                .contentTransition(.numericText())

            Spacer(minLength: 0)

            Button {
                changeWeek(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
            .disabled(weekOffset >= 0)
            .opacity(weekOffset >= 0 ? 0.26 : 1)
            .accessibilityLabel(Text("Next week"))
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(IslandVisualStyle.secondaryText)
    }

    private var heatmap: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(spacing: 4) {
                Color.clear.frame(width: 18, height: 12)
                ForEach(IslandFocusPeriod.allCases, id: \.self) { period in
                    Image(systemName: period.systemImage)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(period.tint.opacity(0.78))
                        .frame(width: 18, height: 25)
                        .accessibilityHidden(true)
                }
            }

            ForEach(Array(weekDays.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 4) {
                    Text(day, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(calendar.isDateInToday(day)
                                         ? Color.white
                                         : IslandVisualStyle.tertiaryText)
                        .frame(height: 12)

                    ForEach(IslandFocusPeriod.allCases, id: \.self) { period in
                        heatCell(day: day, period: period)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var heatmapLegend: some View {
        HStack(spacing: 10) {
            ForEach(IslandFocusPeriod.allCases, id: \.self) { period in
                Label(period.title, systemImage: period.systemImage)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(period.tint.opacity(0.76))
            }
            Spacer(minLength: 0)
            Text("Focus time")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(IslandVisualStyle.tertiaryText)
        }
        .lineLimit(1)
    }

    private func heatCell(day: Date, period: IslandFocusPeriod) -> some View {
        let cell = Cell(date: day, period: period)
        let duration = IslandFocusStatistics.duration(
            timerStore.sessions,
            on: day,
            period: period,
            calendar: calendar
        )
        let count = IslandFocusStatistics.sessions(
            timerStore.sessions,
            on: day,
            period: period,
            calendar: calendar
        ).count
        let isHighlighted = hoveredCell == cell || selectedCell == cell
        let intensity = min(max(duration / 3_600, 0), 1)

        return Button {
            selectedCell = selectedCell == cell ? nil : cell
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(duration > 0
                      ? period.tint.opacity(0.20 + intensity * 0.72)
                      : Color.white.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isHighlighted
                                ? Color.white.opacity(0.78)
                                : Color.white.opacity(duration > 0 ? 0.12 : 0.045),
                            lineWidth: isHighlighted ? 1.2 : 1
                        )
                }
                .shadow(color: duration > 0
                        ? period.tint.opacity(0.16 + intensity * 0.18)
                        : .clear,
                        radius: 4)
                .frame(maxWidth: .infinity, minHeight: 25, maxHeight: 25)
                .scaleEffect(isHighlighted && !reduceMotion ? 1.055 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredCell = hovering ? cell : (hoveredCell == cell ? nil : hoveredCell)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14),
                   value: isHighlighted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(cellAccessibilityLabel(cell)))
        .accessibilityValue(Text(
            String.localizedStringWithFormat(
                String(localized: "%lld focus sessions"),
                count
            ) + ", " + focusDurationText(duration)
        ))
        .modifier(IslandSelectedAccessibilityModifier(selected: selectedCell == cell))
    }

    private var weekStart: Date {
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .weekOfYear,
                             value: weekOffset,
                             to: currentWeek) ?? currentWeek
    }

    private var weekDays: [Date] {
        (0..<7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: weekStart)
        }
    }

    private var weekRangeText: String {
        guard let end = weekDays.last else { return "" }
        let startText = weekStart.formatted(.dateTime.month(.abbreviated).day())
        let endText = end.formatted(.dateTime.month(.abbreviated).day())
        return "\(startText) – \(endText)"
    }

    private func changeWeek(by amount: Int) {
        let target = min(0, weekOffset + amount)
        if reduceMotion {
            weekOffset = target
        } else {
            withAnimation(.smooth(duration: 0.24)) {
                weekOffset = target
            }
        }
        hoveredCell = nil
        selectedCell = nil
    }

    private func summaryTitle(for cell: Cell?) -> String {
        guard let cell else { return String(localized: "Today") }
        let date = cell.date.formatted(.dateTime.month(.abbreviated).day())
        return "\(date) · \(cell.period.title)"
    }

    private func cellAccessibilityLabel(_ cell: Cell) -> String {
        let date = cell.date.formatted(.dateTime.year().month().day().weekday(.wide))
        return "\(date), \(cell.period.title)"
    }

    private func focusDurationText(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration.rounded() / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    private var focusGreen: Color {
        Color(red: 0.22, green: 0.86, blue: 0.48)
    }
}

private extension IslandFocusPeriod {
    var title: String {
        switch self {
        case .morning: String(localized: "Morning")
        case .afternoon: String(localized: "Afternoon")
        case .evening: String(localized: "Evening")
        }
    }

    var systemImage: String {
        switch self {
        case .morning: "sunrise.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "moon.stars.fill"
        }
    }

    var tint: Color {
        switch self {
        case .morning: Color(red: 1.0, green: 0.70, blue: 0.34)
        case .afternoon: Color(red: 0.22, green: 0.86, blue: 0.48)
        case .evening: Color(red: 0.66, green: 0.43, blue: 0.98)
        }
    }
}

private struct IslandTimerDial: View {
    let timeText: String
    let stateText: String
    let systemImage: String
    let remainingFraction: Double
    let tint: Color
    let tick: Int
    let isRunning: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let fraction = min(max(remainingFraction, 0), 1)
            let radius = diameter / 2 - 9
            let radians = (fraction * 360 - 90) * Double.pi / 180

            ZStack {
                Circle()
                    .stroke(tint.opacity(isRunning ? 0.12 : 0.07), lineWidth: 1)
                    .scaleEffect(1.075)
                    .shadow(color: tint.opacity(isRunning ? 0.22 : 0.08), radius: 9)
                Circle()
                    .fill(RadialGradient(
                        colors: [tint.opacity(isRunning ? 0.18 : 0.10),
                                 Color.black.opacity(0.02)],
                        center: .center,
                        startRadius: 2,
                        endRadius: diameter * 0.54
                    ))
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.46), tint, tint.opacity(0.72)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(isRunning ? 0.52 : 0.28),
                            radius: isRunning ? 7 : 4)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.38),
                               value: fraction)

                if isRunning {
                    Circle()
                        .trim(from: 0.02, to: 0.16)
                        .stroke(
                            AngularGradient(
                                colors: [.clear, tint.opacity(0.22), .white, .clear],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(reduceMotion
                                                 ? -48
                                                 : Double(tick % 120) * 9 - 90))
                        .scaleEffect(1.075)
                        .shadow(color: tint.opacity(0.55), radius: 5)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.72),
                                   value: tick)
                }

                if fraction > 0.001 && fraction < 0.999 {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .shadow(color: tint, radius: 5)
                        .offset(x: cos(radians) * radius,
                                y: sin(radians) * radius)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.38),
                                   value: fraction)
                }

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: systemImage)
                        Text(stateText.uppercased())
                    }
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint)

                    Text(timeText)
                        .font(.system(size: 31, weight: .semibold, design: .rounded))
                        .foregroundStyle(IslandVisualStyle.primaryText)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.22),
                                   value: timeText)
                }
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(isRunning && !reduceMotion && tick.isMultiple(of: 2) ? 1.009 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.34), value: tick)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(stateText), \(timeText)"))
    }
}

private struct IslandBatteryView: View {
    @Environment(PowerSourceMonitor.self) private var powerMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            IslandModuleHeader(
                title: "Battery",
                subtitle: nil,
                systemImage: batterySymbol
            )
            if powerMonitor.snapshot.hasBattery {
                HStack(spacing: 22) {
                    BatteryChargeRing(
                        percentage: powerMonitor.snapshot.percentage,
                        tint: batteryTint,
                        reduceMotion: reduceMotion
                    )

                    VStack(alignment: .leading, spacing: 9) {
                        Image(systemName: statusSymbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(batteryTint)
                            .frame(width: 42, height: 42)
                            .background {
                                Circle().fill(batteryTint.opacity(0.13))
                            }

                        Text(powerStatus)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(IslandVisualStyle.primaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(IslandVisualStyle.cardFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(IslandVisualStyle.hairline, lineWidth: 1)
                        }
                }
            } else {
                IslandEmptyState(
                    title: "Not applicable",
                    message: "This Mac does not report an internal battery.",
                    systemImage: "desktopcomputer"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var statusSymbol: String {
        if powerMonitor.snapshot.isCharging { return "bolt.fill" }
        if powerMonitor.snapshot.isConnectedToPower { return "powerplug.fill" }
        return batterySymbol
    }

    private var batterySymbol: String {
        switch powerMonitor.snapshot.percentage {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...65: return "battery.50percent"
        case 66...90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var batteryTint: Color {
        if powerMonitor.snapshot.percentage <= 10 { return .red }
        if powerMonitor.snapshot.percentage <= 20 { return .orange }
        return .green
    }

    private var powerStatus: String {
        if powerMonitor.snapshot.isCharging { return String(localized: "Charging") }
        if powerMonitor.snapshot.isConnectedToPower { return String(localized: "Connected to power") }
        return String(localized: "Running on battery")
    }
}

private struct BatteryChargeRing: View {
    let percentage: Int
    let tint: Color
    let reduceMotion: Bool

    private var progress: Double {
        min(max(Double(percentage) / 100, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.09), lineWidth: 8)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.62), tint, tint.opacity(0.88)],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.30), radius: 5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35),
                           value: progress)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(percentage)")
                    .font(.system(size: 31, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandVisualStyle.primaryText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandVisualStyle.secondaryText)
            }
        }
        .frame(width: 108, height: 108)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery"))
        .accessibilityValue(Text("\(percentage) percent"))
    }
}

private struct IslandNowPlayingView: View {
    @Environment(NowPlayingModuleStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artwork: NSImage?
    @State private var artworkAccent = ArtworkAccent.fallback
    @State private var artworkRevision = 0
    @State private var isSendingCommand = false

    var body: some View {
        VStack(spacing: 8) {
            IslandModuleHeader(
                title: "Now Playing",
                subtitle: nowPlayingSubtitle,
                systemImage: "music.note"
            )
            if store.availability == .disabled {
                VStack(spacing: 12) {
                    IslandEmptyState(
                        title: "Enable Now Playing",
                        message: "Show album artwork, playback progress, and media controls in the Island.",
                        systemImage: "music.note"
                    )
                    Button { settings.islandMediaEnabled = true } label: {
                        Label("Enable", systemImage: "waveform")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 36)
                            .background(Capsule().fill(Color.accentColor))
                    }
                    .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
                }
            } else if store.availability == .probing {
                VStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Checking media access…")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot = store.snapshot {
                playerCard(snapshot)
            } else if store.availability == .available {
                IslandEmptyState(
                    title: "Nothing playing",
                    message: "Start media in a supported player.",
                    systemImage: "music.note"
                )
            } else {
                IslandEmptyState(
                    title: "Now Playing unavailable",
                    message: "OpenYoink could not read the current player. Other Island features still work normally.",
                    systemImage: "play.slash"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: store.snapshot?.artworkData, initial: true) { _, data in
            updateArtwork(with: data)
        }
    }

    private var nowPlayingSubtitle: String {
        guard let snapshot = store.snapshot else {
            return store.availability == .disabled
                ? String(localized: "Off")
                : String(localized: "Music and media controls")
        }
        if let sourceName = snapshot.sourceName {
            return sourceDisplayName(sourceName)
        }
        return snapshot.isPlaying ? String(localized: "Playing") : String(localized: "Paused")
    }

    private func playerCard(_ snapshot: NowPlayingSnapshot) -> some View {
        let trackIdentity = NowPlayingTrackVisualIdentity(snapshot: snapshot)

        return ZStack {
            artworkBackdrop
            LinearGradient(
                colors: [Color.black.opacity(0.18), Color.black.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(alignment: .center, spacing: 14) {
                artworkView(isPlaying: snapshot.isPlaying)

                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        trackMetadata(snapshot)
                            .id(trackIdentity)
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, minHeight: 51,
                           maxHeight: 51, alignment: .topLeading)
                    .animation(trackCrossfadeAnimation, value: trackIdentity)

                    ZStack {
                        playbackProgress(snapshot)
                            .id(trackIdentity)
                            .transition(.opacity)
                    }
                    .animation(trackCrossfadeAnimation, value: trackIdentity)
                        .padding(.top, 10)

                    HStack(spacing: 14) {
                        mediaButton("backward.fill", command: .previousTrack,
                                    label: String(localized: "Previous track"))
                        mediaButton(snapshot.isPlaying ? "pause.fill" : "play.fill",
                                    command: .togglePlayPause,
                                    label: snapshot.isPlaying
                                    ? String(localized: "Pause") : String(localized: "Play"),
                                    emphasized: true)
                        mediaButton("forward.fill", command: .nextTrack,
                                    label: String(localized: "Next track"))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(IslandVisualStyle.hairline, lineWidth: 1)
        }
    }

    private var artworkBackdrop: some View {
        ZStack {
            artworkBackdropLayer
                .id(artworkRevision)
                .transition(.opacity)
        }
        .animation(trackCrossfadeAnimation, value: artworkRevision)
    }

    private func artworkView(isPlaying: Bool) -> some View {
        ZStack {
            artworkLayer
                .id(artworkRevision)
                .transition(.opacity)
        }
        // Video thumbnails are often much wider than album covers. Constrain
        // the rendering surface before applying the rounded mask so
        // `.scaledToFill()` crops inside this square instead of retaining the
        // source image's wide intrinsic width and spilling into metadata.
        .frame(width: 104, height: 104)
        .clipped()
        .animation(trackCrossfadeAnimation, value: artworkRevision)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            IslandEqualizerView(
                isPlaying: isPlaying,
                reduceMotion: reduceMotion,
                tint: artworkAccent.color,
                rhythmSeed: visualizerSeed
            )
                .padding(7)
        }
        .shadow(color: .black.opacity(0.42), radius: 10, y: 4)
        .accessibilityLabel(Text("Album artwork"))
    }

    private func trackMetadata(_ snapshot: NowPlayingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(snapshot.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(IslandVisualStyle.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(snapshot.title)

            Text(snapshot.artist ?? String(localized: "Unknown artist"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .lineLimit(1)
                .padding(.top, 3)

            Text(visibleAlbum(snapshot))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IslandVisualStyle.tertiaryText)
                .lineLimit(1)
                .padding(.top, 2)
                .accessibilityHidden(snapshot.album?.isEmpty != false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func visibleAlbum(_ snapshot: NowPlayingSnapshot) -> String {
        guard let album = snapshot.album, !album.isEmpty else { return " " }
        return album
    }

    @ViewBuilder
    private var artworkBackdropLayer: some View {
        if let artwork {
            GeometryReader { proxy in
                Image(nsImage: artwork)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.medium)
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: 32)
                    .scaleEffect(1.22)
                    .opacity(0.42)
            }
            .clipped()
        } else {
            LinearGradient(
                colors: [Color.indigo.opacity(0.58),
                         Color.accentColor.opacity(0.34),
                         Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private var artworkLayer: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .renderingMode(.original)
                .interpolation(.high)
                .scaledToFill()
        } else {
            LinearGradient(
                colors: [Color.accentColor, Color.indigo, Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private var trackCrossfadeAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .easeInOut(duration: 0.28)
    }

    private func updateArtwork(with data: Data?) {
        let nextArtwork = data.flatMap(NSImage.init(data:))
        let nextAccent = ArtworkAccentExtractor.accent(from: data)
        let update = {
            artwork = nextArtwork
            artworkAccent = nextAccent
            artworkRevision &+= 1
        }

        if artworkRevision == 0 {
            update()
        } else {
            withAnimation(trackCrossfadeAnimation, update)
        }
    }

    private func playbackProgress(_ snapshot: NowPlayingSnapshot) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = snapshot.duration ?? 0
            let elapsed = store.projectedElapsed(at: context.date) ?? 0
            IslandMediaScrubber(
                duration: duration,
                elapsed: elapsed,
                tint: artworkAccent.color,
                isEnabled: store.supportsSeeking,
                onSeek: { await store.seek(to: $0) }
            )
        }
    }

    private func sourceDisplayName(_ source: String) -> String {
        source.split(separator: ".").last.map(String.init) ?? source
    }

    private func mediaButton(
        _ symbol: String,
        command: NowPlayingCommand,
        label: String,
        emphasized: Bool = false
    ) -> some View {
        Button {
            Task {
                isSendingCommand = true
                _ = await store.send(command)
                isSendingCommand = false
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: emphasized ? 16 : 12, weight: .bold))
                .foregroundStyle(emphasized ? Color.black : Color.white)
                .frame(width: emphasized ? 42 : 34,
                       height: emphasized ? 42 : 34)
                .background {
                    Circle().fill(emphasized ? Color.white : IslandVisualStyle.controlFill)
                }
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        .disabled(!store.supportsTransportControls || isSendingCommand)
        .opacity(store.supportsTransportControls && !isSendingCommand ? 1 : 0.38)
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }

    private var visualizerSeed: UInt64 {
        guard let snapshot = store.snapshot else { return 0 }
        return MusicVisualizerRhythm.seed(title: snapshot.title,
                                          artist: snapshot.artist,
                                          album: snapshot.album)
    }
}

private struct IslandMediaScrubber: View {
    let duration: TimeInterval
    let elapsed: TimeInterval
    let tint: Color
    let isEnabled: Bool
    let onSeek: @MainActor (TimeInterval) async -> Bool

    @State private var scrubbedSeconds: TimeInterval?
    @State private var isScrubbing = false
    @State private var isSeeking = false
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 0)
                let thumbSize = 10.0
                let trackInset = thumbSize / 2
                let trackWidth = max(0, width - trackInset * 2)
                let thumbCenter = MediaScrubMath.location(
                    for: displayedSeconds,
                    width: Double(width),
                    duration: duration,
                    horizontalInset: trackInset
                )
                let fillWidth = max(0, thumbCenter - trackInset)

                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color.white.opacity(isEnabled ? 0.17 : 0.10))
                        .frame(width: trackWidth, height: 4)
                        .position(x: width / 2, y: 9)
                    if fillWidth > 0 {
                        Capsule()
                            .fill(tint)
                            .frame(width: fillWidth, height: 4)
                            .position(x: trackInset + fillWidth / 2, y: 9)
                    }
                    Circle()
                        .fill(Color.white)
                        .overlay {
                            Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                        }
                        .shadow(color: tint.opacity(0.52), radius: 4)
                        .frame(width: thumbSize, height: thumbSize)
                        .position(x: thumbCenter, y: 9)
                        .opacity(showsThumb ? 1 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            guard isEnabled, !isSeeking else { return }
                            isScrubbing = true
                            scrubbedSeconds = MediaScrubMath.seconds(
                                at: Double(value.location.x),
                                width: Double(width),
                                duration: duration,
                                horizontalInset: trackInset
                            )
                        }
                        .onEnded { value in
                            guard isEnabled, !isSeeking else { return }
                            isScrubbing = false
                            let target = MediaScrubMath.seconds(
                                at: Double(value.location.x),
                                width: Double(width),
                                duration: duration,
                                horizontalInset: trackInset
                            )
                            commitSeek(target)
                        }
                )
            }
            .frame(height: 18)

            HStack {
                Text(formatTime(displayedSeconds))
                Spacer()
                Text(duration > 0 ? formatTime(duration) : "–:––")
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(IslandVisualStyle.tertiaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text("\(formatTime(displayedSeconds)) / \(formatTime(duration))"))
        .accessibilityHint(Text(isEnabled
                                ? "Drag or click to seek"
                                : "Seeking is unavailable for this player"))
        .accessibilityAdjustableAction { direction in
            guard isEnabled, !isSeeking else { return }
            let step = max(5, duration * 0.02)
            switch direction {
            case .increment:
                commitSeek(min(duration, displayedSeconds + step))
            case .decrement:
                commitSeek(max(0, displayedSeconds - step))
            @unknown default:
                break
            }
        }
        .help(Text(isEnabled
                   ? "Drag or click to seek"
                   : "Seeking is unavailable for this player"))
    }

    private var displayedSeconds: TimeInterval {
        min(max(scrubbedSeconds ?? elapsed, 0), max(0, duration))
    }

    private var showsThumb: Bool {
        isEnabled && (isHovering || isScrubbing || isSeeking)
    }

    private func commitSeek(_ target: TimeInterval) {
        guard isEnabled, !isSeeking else { return }
        scrubbedSeconds = target
        isSeeking = true
        Task { @MainActor in
            _ = await onSeek(target)
            isSeeking = false
            scrubbedSeconds = nil
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let finiteSeconds = seconds.isFinite ? seconds : 0
        let total = max(0, Int(finiteSeconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Reveals the expanded surface with a moving bottom edge rather than scaling
/// its contents. Text, artwork, and controls keep their natural geometry while
/// the island visibly grows out of the notch even if the AppKit window resize
/// is coalesced into a single display update by the window server.
private struct IslandSurfaceRevealModifier: ViewModifier, @MainActor Animatable {
    var progress: CGFloat
    var opacity: Double
    let collapsedWidth: CGFloat
    let collapsedHeight: CGFloat
    let attachedToScreenTop: Bool

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(progress, opacity) }
        set {
            progress = newValue.first
            opacity = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content
            .mask {
                GeometryReader { proxy in
                    let clampedProgress = min(max(progress, 0), 1)
                    let minimumWidth = min(collapsedWidth, proxy.size.width)
                    let minimumHeight = min(collapsedHeight, proxy.size.height)
                    let revealedWidth = minimumWidth
                        + (proxy.size.width - minimumWidth) * clampedProgress
                    let revealedHeight = minimumHeight
                        + (proxy.size.height - minimumHeight) * clampedProgress
                    IslandSurfaceShape(
                        attachedToScreenTop: attachedToScreenTop,
                        cornerRadius: 26
                    )
                    .fill(Color.white)
                    .frame(width: revealedWidth, height: revealedHeight,
                           alignment: .top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .top)
                }
            }
            .opacity(opacity)
    }
}

private struct IslandEqualizerView: View {
    let isPlaying: Bool
    let reduceMotion: Bool
    var tint: Color = .accentColor
    var rhythmSeed: UInt64 = 0

    var body: some View {
        Group {
            if isPlaying && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                    bars(time: context.date.timeIntervalSinceReferenceDate)
                }
            } else if isPlaying {
                bars(time: 0.72)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .frame(width: 30, height: 22)
        .background {
            Capsule()
                .fill(Color.black.opacity(0.72))
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75)
                }
        }
        .shadow(color: isPlaying ? tint.opacity(0.32) : .clear,
                radius: 5)
        .accessibilityHidden(true)
    }

    private func bars(time: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 1.8) {
            ForEach(0..<5, id: \.self) { index in
                let level = MusicVisualizerRhythm.level(
                    bar: index,
                    time: time,
                    seed: rhythmSeed
                )
                let height = 4 + CGFloat(level) * 10
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.96), tint],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2.2, height: height)
            }
        }
    }
}

private struct CompactNowPlayingArtworkView: View {
    @Environment(NowPlayingModuleStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let image: NSImage
    let tint: Color
    let isHovered: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = store.snapshot?.duration ?? 0
            let elapsed = store.projectedElapsed(at: context.date) ?? 0
            let progress = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.13), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            colors: [.white, tint, .white],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(isHovered ? 0.16 : 0))
                    }
            }
            .frame(width: 23, height: 23)
            .scaleEffect(isHovered ? 1.04 : 1)
            .shadow(color: store.snapshot?.isPlaying == true
                    ? tint.opacity(0.38) : .clear,
                    radius: 4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        }
        .accessibilityHidden(true)
    }
}
