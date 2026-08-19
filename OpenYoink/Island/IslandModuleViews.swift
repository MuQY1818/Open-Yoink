import SwiftUI

struct ShelfPresentationRootView: View {
    @Environment(SettingsStore.self) private var settings
    var onPerformRecovery: ((RecoveryAction) -> Void)?

    var body: some View {
        Group {
            if settings.shelfPresentationMode == .island {
                IslandRootView(onPerformRecovery: onPerformRecovery)
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

    var onPerformRecovery: ((RecoveryAction) -> Void)?

    var body: some View {
        Group {
            if coordinator.surfaceState.isExpanded {
                expandedContent
            } else {
                compactContent
            }
        }
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22),
                   value: coordinator.surfaceState)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("island.root")
        .onChange(of: settings.islandTimerEnabled, initial: true) {
            registry.apply(settings: settings)
        }
        .onChange(of: settings.islandBatteryEnabled) {
            registry.apply(settings: settings)
        }
        .onChange(of: settings.islandMediaEnabled) {
            registry.apply(settings: settings)
        }
        .onChange(of: transferStore.currentTask, initial: true) { _, task in
            publishTransferActivity(task)
        }
    }

    private var compactContent: some View {
        Button {
            coordinator.show(module: coordinator.primaryActivity()?.moduleID ?? .shelf)
        } label: {
            if coordinator.currentLayout?.hasPhysicalNotch == true {
                HStack(spacing: 0) {
                    compactLeading
                        .frame(width: IslandGeometryResolver.compactWingWidth)
                    Spacer()
                        .frame(width: coordinator.currentLayout?.cameraHousingWidth ?? 0)
                    compactTrailing
                        .frame(width: IslandGeometryResolver.compactWingWidth)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .contentShape(compactSurfaceShape)
        .background {
            compactSurfaceShape
                .fill(Color.black.opacity(0.96))
        }
        .overlay {
            if isCompactHovering {
                compactSurfaceShape
                    .fill(Color.accentColor.opacity(0.14))
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
        .accessibilityLabel(Text(compactAccessibilityLabel))
        .accessibilityHint(Text("Open OpenYoink Island"))
        .help(Text("Open OpenYoink Island"))
    }

    @ViewBuilder
    private var compactLeading: some View {
        let activity = coordinator.primaryActivity()
        Image(systemName: activity?.systemImage ?? "tray.full")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(activityTint(activity))
            .accessibilityHidden(true)
    }

    private var compactTrailing: some View {
        Group {
            if transferStore.hasVisibleActivity && !reduceMotion {
                ProgressView()
                    .controlSize(.mini)
            } else if case .running = timerStore.state {
                Text(timerStore.formattedRemaining)
                    .font(.caption2.monospacedDigit().weight(.semibold))
            } else {
                Text("\(shelfStore.items.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .accessibilityHidden(true)
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
        VStack(spacing: 8) {
            islandCap
            moduleNavigation
            Divider().overlay(Color.white.opacity(0.1))
            moduleContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .contentShape(expandedSurfaceShape)
        .background {
            expandedSurfaceShape
                .fill(Color.black.opacity(0.94))
        }
        .overlay {
            if !hasPhysicalNotch {
                expandedSurfaceShape
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
    }

    private var hasPhysicalNotch: Bool {
        coordinator.currentLayout?.hasPhysicalNotch == true
    }

    private var compactSurfaceShape: IslandSurfaceShape {
        IslandSurfaceShape(attachedToScreenTop: hasPhysicalNotch, cornerRadius: 13)
    }

    private var expandedSurfaceShape: IslandSurfaceShape {
        IslandSurfaceShape(attachedToScreenTop: hasPhysicalNotch, cornerRadius: 18)
    }

    private var islandCap: some View {
        HStack(spacing: 8) {
            Button {
                coordinator.collapse()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("OpenYoink Island")
                        .font(.headline)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Collapse Island"))
            .help(Text("Collapse Island"))

            Button {
                coordinator.setPinned(coordinator.surfaceState != .pinned)
            } label: {
                Image(systemName: coordinator.surfaceState == .pinned
                      ? "pin.fill" : "pin")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(pinLabel))
            .help(Text(pinLabel))

            Button {
                coordinator.collapse()
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Collapse Island"))
            .help(Text("Collapse Island"))
        }
        .frame(minHeight: max(28, coordinator.currentLayout?.topInset ?? 28))
    }

    private var pinLabel: String {
        coordinator.surfaceState == .pinned
            ? String(localized: "Unpin Island")
            : String(localized: "Pin Island")
    }

    private var moduleNavigation: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(registry.enabledDescriptors) { descriptor in
                    Button {
                        coordinator.selectedModule = descriptor.id
                    } label: {
                        Label(descriptor.title, systemImage: descriptor.systemImage)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .frame(minHeight: 30)
                            .background {
                                Capsule()
                                    .fill(coordinator.selectedModule == descriptor.id
                                          ? Color.accentColor.opacity(0.9)
                                          : Color.white.opacity(0.08))
                            }
                    }
                    .buttonStyle(.plain)
                    .modifier(IslandSelectedAccessibilityModifier(
                        selected: coordinator.selectedModule == descriptor.id
                    ))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var moduleContent: some View {
        switch coordinator.selectedModule {
        case .shelf:
            ShelfView(presentationStyle: .island)
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
        return String(localized: "OpenYoink Island, \(shelfStore.items.count) shelf items")
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

/// A physical-notch surface has a straight top edge so its black chrome joins the
/// camera housing without a transparent seam. Displays without a notch retain the
/// independent rounded capsule used by the fallback presentation.
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

        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
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

private struct IslandTransfersView: View {
    @Environment(TransferStore.self) private var transferStore
    var onPerformRecovery: ((RecoveryAction) -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Label("Transfers", systemImage: "arrow.up.arrow.down")
                .font(.title3.weight(.semibold))
            if transferStore.hasVisibleActivity {
                ShelfActivityStrip(onPerformRecovery: onPerformRecovery)
            } else {
                ContentUnavailableView("No active transfers",
                                       systemImage: "checkmark.circle",
                                       description: Text("New imports and deliveries appear here."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
    }
}

private struct IslandTimerView: View {
    @Environment(IslandTimerStore.self) private var timerStore
    @State private var customMinutes = 25.0

    var body: some View {
        VStack(spacing: 16) {
            Label("Timer", systemImage: "timer")
                .font(.title3.weight(.semibold))

            Text(timerStore.formattedRemaining)
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityLabel(Text("Time remaining \(timerStore.formattedRemaining)"))

            ProgressView(value: timerStore.progress)
                .tint(.accentColor)

            HStack(spacing: 7) {
                ForEach([5, 15, 25, 45, 60], id: \.self) { minutes in
                    Button("\(minutes)m") {
                        timerStore.start(minutes: Double(minutes))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Stepper(value: $customMinutes, in: 1...180, step: 1) {
                    Text("Custom: \(Int(customMinutes)) min")
                        .monospacedDigit()
                }
                Button("Start") {
                    timerStore.start(minutes: customMinutes)
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 10) {
                switch timerStore.state {
                case .running:
                    Button("Pause") { timerStore.pause() }
                case .paused:
                    Button("Resume") { timerStore.resume() }
                case .finished:
                    Button("Done") { timerStore.acknowledgeFinished() }
                case .idle:
                    EmptyView()
                }
                if timerStore.state != .idle {
                    Button("Reset", role: .destructive) { timerStore.reset() }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IslandBatteryView: View {
    @Environment(PowerSourceMonitor.self) private var powerMonitor

    var body: some View {
        VStack(spacing: 16) {
            Label("Battery", systemImage: batterySymbol)
                .font(.title3.weight(.semibold))
            if powerMonitor.snapshot.hasBattery {
                Text("\(powerMonitor.snapshot.percentage)%")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                ProgressView(value: Double(powerMonitor.snapshot.percentage), total: 100)
                    .tint(batteryTint)
                Label(powerStatus, systemImage: powerMonitor.snapshot.isConnectedToPower
                      ? "bolt.fill" : "battery.75percent")
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("Not applicable",
                                       systemImage: "desktopcomputer",
                                       description: Text("This Mac does not report an internal battery."))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct IslandNowPlayingView: View {
    @Environment(NowPlayingModuleStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Label("Now Playing", systemImage: "play.circle")
                .font(.title3.weight(.semibold))
            if store.availability == .probing {
                ProgressView("Checking media access…")
                    .controlSize(.small)
            } else if let snapshot = store.snapshot {
                VStack(spacing: 4) {
                    Text(snapshot.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let artist = snapshot.artist {
                        Text(artist)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 20) {
                    mediaButton("backward.fill", command: .previousTrack,
                                label: String(localized: "Previous track"))
                    mediaButton(snapshot.isPlaying ? "pause.fill" : "play.fill",
                                command: .togglePlayPause,
                                label: snapshot.isPlaying
                                ? String(localized: "Pause") : String(localized: "Play"))
                    mediaButton("forward.fill", command: .nextTrack,
                                label: String(localized: "Next track"))
                }
            } else if store.availability == .available {
                ContentUnavailableView("Nothing playing",
                                       systemImage: "music.note",
                                       description: Text("Start media in a supported player."))
            } else {
                ContentUnavailableView("Now Playing unavailable",
                                       systemImage: "play.slash",
                                       description: Text("This experimental module could not read the current player."))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mediaButton(_ symbol: String,
                             command: NowPlayingCommand,
                             label: String) -> some View {
        Button {
            Task { _ = await store.send(command) }
        } label: {
            Image(systemName: symbol)
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.bordered)
        .disabled(!store.supportsTransportControls)
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }
}
