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
    @Environment(IslandModuleContainer.self) private var moduleContainer
    @Environment(IslandTimerStore.self) private var timerStore
    @Environment(PowerSourceMonitor.self) private var powerMonitor
    @Environment(NowPlayingModuleStore.self) private var nowPlayingStore
    @Environment(SystemStatusModuleStore.self) private var systemStatusStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isCompactHovering = false
    @State private var isCompactMediaControlHovering = false
    @State private var isCollapseControlHovering = false
    @State private var isSettingsControlHovering = false
    @State private var isSendingCompactMediaCommand = false
    @State private var mediaAccent = ArtworkAccent.fallback
    @State private var renderedSurfaceState: IslandSurfaceState = .compact
    @State private var isShowingModuleLibrary = false

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
        .onChange(of: settings.islandModuleConfiguration, initial: true) {
            registry.apply(settings: settings)
            moduleContainer.apply(
                configuration: settings.islandModuleConfiguration,
                isActive: settings.islandEnabled
            )
            if !registry.isEnabled(coordinator.selectedModule),
               let fallback = visibleModuleDescriptors.first?.id
                    ?? registry.enabledDescriptors.first?.id {
                coordinator.selectedModule = fallback
            }
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
            if registry.isEnabled(.system),
               let cpu = systemStatusStore.snapshot.cpuUsage,
               let used = systemStatusStore.snapshot.memoryUsedBytes,
               let total = systemStatusStore.snapshot.memoryTotalBytes,
               total > 0 {
                Text("CPU \(Int((cpu * 100).rounded()))% · MEM \(Int((Double(used) / Double(total) * 100).rounded()))%")
                    .font(.caption2.monospacedDigit().weight(.semibold))
            } else {
                Text(String(localized: "OpenYoink Island"))
                    .font(.caption.weight(.semibold))
            }
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
        let slots = pinnedModuleSlots
        let leadingSlots = Array(slots.prefix(2))
        let trailingSlots = Array(slots.dropFirst(2))
        let notchWidth = coordinator.currentLayout?.cameraHousingWidth ?? 0
        let notchHeight = coordinator.currentLayout?.topInset ?? 32
        let stripHeight = notchHeight
            + IslandGeometryResolver.physicalNotchClickExtension

        return ZStack(alignment: .top) {
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    settingsButton(size: 26)

                    ForEach(leadingSlots.indices, id: \.self) { index in
                        if let descriptor = leadingSlots[index] {
                            physicalNotchModuleButton(descriptor)
                        } else {
                            emptyModuleSlot(size: 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                Color.clear
                    .frame(width: notchWidth)
                    .allowsHitTesting(false)

                HStack(spacing: 2) {
                    ForEach(trailingSlots.indices, id: \.self) { index in
                        if let descriptor = trailingSlots[index] {
                            physicalNotchModuleButton(descriptor)
                        } else {
                            emptyModuleSlot(size: 24)
                        }
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
            isShowingModuleLibrary = false
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
            settingsButton(size: 30)
            moduleNavigation
            Spacer(minLength: 4)

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
            isShowingModuleLibrary.toggle()
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
        .accessibilityLabel(Text("Module Library"))
        .help(Text("Module Library"))
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
            ForEach(pinnedModuleSlots.indices, id: \.self) { index in
                if let descriptor = pinnedModuleSlots[index] {
                    floatingModuleButton(descriptor)
                } else {
                    emptyModuleSlot(size: 30)
                }
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

    /// The five saved positions are the only normal compact navigation slots.
    /// Enabled but unpinned modules remain available from the module library.
    private var visibleModuleDescriptors: [IslandModuleDescriptor] {
        settings.islandModuleConfiguration.pinnedModuleIDs.compactMap {
            registry.descriptor(for: $0)
        }
    }

    private var pinnedModuleSlots: [IslandModuleDescriptor?] {
        let descriptors = visibleModuleDescriptors.map(Optional.some)
        return descriptors + Array(
            repeating: nil,
            count: max(0, IslandModuleConfiguration.maximumPinnedModules
                       - descriptors.count)
        )
    }

    private func floatingModuleButton(
        _ descriptor: IslandModuleDescriptor
    ) -> some View {
        let isSelected = coordinator.selectedModule == descriptor.id
        let isEnabled = registry.isEnabled(descriptor.id)
        return Button {
            isShowingModuleLibrary = false
            coordinator.selectedModule = descriptor.id
        } label: {
            Image(systemName: descriptor.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
                }
                .contentShape(Circle())
                .opacity(isEnabled || isSelected ? 1 : 0.46)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(descriptor.title))
        .help(Text(descriptor.title))
        .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
    }

    private func emptyModuleSlot(size: CGFloat) -> some View {
        IslandEmptyModuleSlot(size: size) { moduleID in
            coordinator.selectedModule = moduleID
            isShowingModuleLibrary = false
        }
    }

    private var moduleContent: some View {
        Group {
            if isShowingModuleLibrary {
                IslandModuleLibraryView(
                    onOpenModule: { moduleID in
                        coordinator.selectedModule = moduleID
                        isShowingModuleLibrary = false
                    },
                    onOpenSettings: openSettings
                )
            } else {
                moduleContainer.contentView(
                    for: coordinator.selectedModule,
                    context: IslandModuleViewContext(
                        onPerformRecovery: onPerformRecovery
                    )
                )
            }
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
        case .systemWarning: return .orange
        case .timerFinished: return .orange
        case .transfer, .userDrag: return .accentColor
        default: return .white
        }
    }

}

private struct IslandEmptyModuleSlot: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(IslandModuleRegistry.self) private var registry
    @State private var isPresentingPicker = false

    let size: CGFloat
    let onOpenModule: (IslandModuleID) -> Void

    var body: some View {
        Button {
            isPresentingPicker = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: size == 30 ? 10 : 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(0.075)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Choose a module"))
        .help(Text("Choose a module"))
        .popover(isPresented: $isPresentingPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a module")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)

                ForEach(unpinnedModuleDescriptors) { descriptor in
                    Button {
                        settings.setIslandModuleEnabled(true, id: descriptor.id)
                        settings.setIslandModulePinned(true, id: descriptor.id)
                        onOpenModule(descriptor.id)
                        isPresentingPicker = false
                    } label: {
                        Label(descriptor.title, systemImage: descriptor.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .frame(width: 190)
        }
    }

    private var unpinnedModuleDescriptors: [IslandModuleDescriptor] {
        registry.descriptors.filter {
            !settings.isIslandModulePinned($0.id)
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

struct IslandSelectedAccessibilityModifier: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        if selected {
            content.accessibilityAddTraits(.isSelected)
        } else {
            content
        }
    }
}

enum IslandVisualStyle {
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.68)
    static let tertiaryText = Color.white.opacity(0.46)
    static let controlFill = Color.white.opacity(0.09)
    static let selectedFill = Color.accentColor.opacity(0.22)
    static let cardFill = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.08)
}

struct IslandPressFeedbackStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.96)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12),
                       value: configuration.isPressed)
    }
}

struct IslandProgressTrack: View {
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

struct IslandModuleHeader: View {
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

private struct IslandModuleLibraryView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(IslandModuleRegistry.self) private var registry

    let onOpenModule: (IslandModuleID) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            IslandModuleHeader(
                title: "Module Library",
                subtitle: String(localized: "Choose up to five pinned modules"),
                systemImage: "square.grid.2x2"
            )

            ScrollView {
                VStack(spacing: 7) {
                    ForEach(registry.descriptors) { descriptor in
                        moduleRow(descriptor)
                    }
                }
            }

            HStack {
                Text("Drag pinned rows to reorder the five Island positions.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.46))
                Spacer()
                Button("Open Full Settings") { onOpenSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func moduleRow(_ descriptor: IslandModuleDescriptor) -> some View {
        let enabled = settings.isIslandModuleEnabled(descriptor.id)
        let pinned = settings.isIslandModulePinned(descriptor.id)
        let pinnedCount = settings.islandModuleConfiguration.pinnedModuleIDs.count

        return HStack(spacing: 10) {
            Image(systemName: descriptor.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Color.accentColor : Color.white.opacity(0.42))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(pinned
                     ? String(localized: "Pinned in the Island strip")
                     : enabled
                        ? String(localized: "Enabled in the module library")
                        : String(localized: "Disabled"))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.46))
            }

            Spacer(minLength: 4)

            if enabled {
                Button("Open") { onOpenModule(descriptor.id) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption.weight(.semibold))
            }

            Button {
                settings.setIslandModulePinned(!pinned, id: descriptor.id)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!enabled || (!pinned && pinnedCount >= 5))
            .opacity(!enabled || (!pinned && pinnedCount >= 5) ? 0.34 : 1)
            .accessibilityLabel(Text(pinned ? "Unpin module" : "Pin module"))

            Toggle("", isOn: Binding(
                get: { settings.isIslandModuleEnabled(descriptor.id) },
                set: { settings.setIslandModuleEnabled($0, id: descriptor.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 42)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(pinned ? 0.085 : 0.045))
        }
        .draggable(pinned ? descriptor.id.rawValue : "")
        .dropDestination(for: String.self) { items, _ in
            guard pinned,
                  let sourceRawValue = items.first,
                  !sourceRawValue.isEmpty else { return false }
            let ids = settings.islandModuleConfiguration.pinnedModuleIDs
            let sourceID = IslandModuleID(rawValue: sourceRawValue)
            guard let source = ids.firstIndex(of: sourceID),
                  let destination = ids.firstIndex(of: descriptor.id),
                  source != destination else { return false }
            settings.movePinnedIslandModules(
                fromOffsets: IndexSet(integer: source),
                toOffset: destination > source ? destination + 1 : destination
            )
            return true
        }
    }
}

struct IslandEmptyState: View {
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
