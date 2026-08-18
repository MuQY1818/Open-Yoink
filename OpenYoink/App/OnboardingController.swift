import AppKit
import Observation
import SwiftUI

/// 打破 ShelfWindowController 与 OnboardingController 的初始化环：拖出侧只
/// 读取这一小块运行时上下文，不持有完整引导控制器。
@MainActor
final class OnboardingDragContext {
    private var itemID: UUID?
    private var token: String?

    func activate(itemID: UUID, token: String) {
        self.itemID = itemID
        self.token = token
    }

    func clear() {
        itemID = nil
        token = nil
    }

    func token(for itemID: UUID) -> String? {
        self.itemID == itemID ? token : nil
    }
}

/// 启动时是否自动显示快速上手的纯策略。已有未完成 session 总是优先恢复；
/// 没有显式 onboarding 键的旧用户只做静默迁移，避免升级后被打扰。
struct OnboardingLaunchPolicy: Equatable, Sendable {
    static func shouldAutomaticallyShow(onboardingVersion: Int,
                                        hadPersistedVersion: Bool,
                                        hasLegacyInstallEvidence: Bool,
                                        hasPendingSession: Bool) -> Bool {
        if hasPendingSession { return true }
        guard onboardingVersion < 1 else { return false }
        if hadPersistedVersion { return true }
        return !hasLegacyInstallEvidence
    }
}

/// 与 shelf 相邻放置 tutorial panel 的纯布局函数，便于覆盖左右边缘、多屏和
/// 窄屏回退。panel 始终夹在目标屏可见区域内。
struct OnboardingPanelLayout: Equatable, Sendable {
    static func frame(shelfFrame: CGRect,
                      panelSize: CGSize,
                      visibleFrame: CGRect,
                      gap: CGFloat = 14) -> CGRect {
        let shelfIsOnRight = shelfFrame.midX >= visibleFrame.midX
        let preferredX = shelfIsOnRight
            ? shelfFrame.minX - gap - panelSize.width
            : shelfFrame.maxX + gap
        let minX = visibleFrame.minX + 12
        let maxX = max(minX, visibleFrame.maxX - panelSize.width - 12)
        let x = min(max(preferredX, minX), maxX)
        let preferredY = shelfFrame.maxY - panelSize.height
        let minY = visibleFrame.minY + 12
        let maxY = max(minY, visibleFrame.maxY - panelSize.height - 12)
        return CGRect(x: x,
                      y: min(max(preferredY, minY), maxY),
                      width: panelSize.width,
                      height: panelSize.height)
    }
}

@MainActor
@Observable
final class OnboardingViewModel {
    enum Phase: Equatable, Sendable {
        case awaitingImport
        case awaitingExport
        case complete
        case fallback
    }

    var phase: Phase = .awaitingImport
    var tutorialFileURL: URL?
    var token = ""
    var isDropTargeted = false
    var failureMessage: String?
}

/// 一次真实「拖入 → 拖出」练习的编排器。所有教程状态和文件都限制在
/// Application Support/OpenYoink/Tutorial，且运行时只通过随机 token 识别。
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    static let currentVersion = 1

    private let settings: SettingsStore
    private let shelfStore: ShelfStore
    private let shelfWindowController: ShelfWindowController
    private let importCoordinator: DropImportCoordinator
    private let sessionStore: OnboardingSessionStore
    private let dragContext: OnboardingDragContext
    private let model = OnboardingViewModel()

    private var record: OnboardingSessionStore.Record?
    private var presentationSnapshot: ShelfWindowController.OnboardingPresentationSnapshot?
    private var completionTask: Task<Void, Never>?

    private static let panelSize = CGSize(width: 430, height: 286)

    private lazy var panel: NSPanel = {
        let panel = OnboardingPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "OpenYoink Quick Start")
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: OnboardingView(
                model: model,
                onSkip: { [weak self] in self?.skip() },
                onDone: { [weak self] in self?.closeAfterCompletion() },
                onTutorialDrop: { [weak self] token in self?.acceptTutorialDrop(token) }
            )
        )
        return panel
    }()

    init(settings: SettingsStore,
         shelfStore: ShelfStore,
         shelfWindowController: ShelfWindowController,
         importCoordinator: DropImportCoordinator,
         dragContext: OnboardingDragContext,
         sessionStore: OnboardingSessionStore = OnboardingSessionStore()) {
        self.settings = settings
        self.shelfStore = shelfStore
        self.shelfWindowController = shelfWindowController
        self.importCoordinator = importCoordinator
        self.dragContext = dragContext
        self.sessionStore = sessionStore
        super.init()

        importCoordinator.isActiveTutorialToken = { [weak self] token in
            self?.isActiveToken(token) == true
        }
        importCoordinator.onTutorialItemsImported = { [weak self] token, items in
            self?.acceptTutorialImport(token: token, items: items)
        }
    }

    /// 启动恢复完成、bookmark 已解析、清理安全门已裁决后调用。
    func startAtLaunch(hasLegacyInstallEvidence: Bool) {
        let pending = sessionStore.load()
        let shouldShow = OnboardingLaunchPolicy.shouldAutomaticallyShow(
            onboardingVersion: settings.onboardingVersion,
            hadPersistedVersion: settings.hadPersistedOnboardingVersion,
            hasLegacyInstallEvidence: hasLegacyInstallEvidence,
            hasPendingSession: pending != nil
        )

        guard shouldShow else {
            // 首次带本能力升级的旧用户没有 onboarding 键：写入 1 作为静默
            // 迁移，后续启动不再重复判断。用户仍可从菜单手动重播。
            if !settings.hadPersistedOnboardingVersion {
                settings.onboardingVersion = Self.currentVersion
            }
            return
        }

        if let pending, resume(pending) { return }
        try? sessionStore.discardAll()
        if settings.onboardingVersion >= Self.currentVersion { return }
        startNewSession()
    }

    /// 菜单栏「快速上手…」。正在进行时仅把面板带到前台；否则新建独立
    /// session，不重置任何设置。
    func replay() {
        if panel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        do {
            try removeTutorialItemIfPresentAndPersist()
            if let record { try sessionStore.discard(record) }
        } catch {
            model.failureMessage = String(localized: "The previous practice couldn't be cleaned up safely. Your files were not touched.")
            present()
            return
        }
        record = nil
        dragContext.clear()
        startNewSession()
    }

    func token(for itemID: UUID) -> String? {
        guard let record,
              record.phase == .awaitingExport,
              record.tutorialItemID == itemID else { return nil }
        return record.token
    }

    func applicationWillTerminate() {
        completionTask?.cancel()
        panel.orderOut(nil)
        endShelfPresentation()
        // 不删 record/练习文件：未完成 session 下次按 phase 安全恢复。
    }

    private func startNewSession() {
        completionTask?.cancel()
        dragContext.clear()
        do {
            let newRecord = try sessionStore.begin()
            record = newRecord
            model.phase = .awaitingImport
            model.tutorialFileURL = sessionStore.tutorialFileURL(for: newRecord)
            model.token = newRecord.token
            model.failureMessage = nil
        } catch {
            record = nil
            model.phase = .fallback
            model.tutorialFileURL = nil
            model.token = ""
            model.failureMessage = String(localized: "The practice file couldn't be created. You can still follow the two steps below.")
        }
        present()
    }

    private func resume(_ record: OnboardingSessionStore.Record) -> Bool {
        let tutorialURL = sessionStore.tutorialFileURL(for: record)
        switch record.phase {
        case .awaitingImport:
            guard FileManager.default.fileExists(atPath: tutorialURL.path) else { return false }
            self.record = record
            model.phase = .awaitingImport
            dragContext.clear()
        case .awaitingExport:
            guard let itemID = record.tutorialItemID,
                  let item = shelfStore.item(withID: itemID),
                  item.fileURL.map({ sessionStore.isTutorialFile($0, for: record) }) == true else {
                return false
            }
            self.record = record
            model.phase = .awaitingExport
            dragContext.activate(itemID: itemID, token: record.token)
        }
        model.tutorialFileURL = tutorialURL
        model.token = record.token
        model.failureMessage = nil
        present()
        return true
    }

    private func present() {
        if presentationSnapshot == nil {
            presentationSnapshot = shelfWindowController.beginOnboardingPresentation()
        }
        let shelfFrame = shelfWindowController.visibleOrTargetFrame
        let screen = NSScreen.screens.first { $0.frame.intersects(shelfFrame) }
            ?? ShelfWindowController.screen(containing: CGPoint(x: shelfFrame.midX, y: shelfFrame.midY))
        panel.setFrame(OnboardingPanelLayout.frame(shelfFrame: shelfFrame,
                                                   panelSize: Self.panelSize,
                                                   visibleFrame: screen.visibleFrame),
                       display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func isActiveToken(_ token: String) -> Bool {
        guard let record else { return false }
        return record.token == token && model.phase != .complete
    }

    private func acceptTutorialImport(token: String, items: [ShelfItem]) {
        guard let record,
              record.phase == .awaitingImport,
              record.token == token,
              let tutorialItem = items.first(where: { item in
                  item.fileURL.map { sessionStore.isTutorialFile($0, for: record) } == true
              }) else { return }
        do {
            let updated = try sessionStore.markAwaitingExport(record,
                                                              tutorialItemID: tutorialItem.id)
            self.record = updated
            model.phase = .awaitingExport
            dragContext.activate(itemID: tutorialItem.id, token: updated.token)
        } catch {
            model.failureMessage = String(localized: "The practice state couldn't be saved. Your files were not touched.")
        }
    }

    private func acceptTutorialDrop(_ token: String) {
        guard let record,
              record.phase == .awaitingExport,
              record.token == token,
              record.tutorialItemID.flatMap(shelfStore.item(withID:)) != nil else { return }

        model.isDropTargeted = false
        model.phase = .complete
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            // 让 AppKit 先结束真实 dragging session，再移除练习卡和源文件。
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.finishSuccessfulSession(record)
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self.closeAfterCompletion()
        }
    }

    private func finishSuccessfulSession(_ completedRecord: OnboardingSessionStore.Record) {
        do {
            if let itemID = completedRecord.tutorialItemID {
                try shelfStore.removeAndPersistNow(ids: [itemID])
            }
            // 版本先于 session 文件清理写入：若进程恰在两者之间退出，下次
            // 启动看到“已完成 + 卡片已不在 shelf”只清理残留，不重播。
            settings.onboardingVersion = Self.currentVersion
            try sessionStore.discard(completedRecord)
            record = nil
            dragContext.clear()
        } catch {
            model.failureMessage = String(localized: "The practice finished, but its temporary file could not be cleaned up automatically.")
        }
    }

    private func skip() {
        completionTask?.cancel()
        do {
            try removeTutorialItemIfPresentAndPersist()
            settings.onboardingVersion = Self.currentVersion
            if let record {
                try sessionStore.discard(record)
            } else {
                try sessionStore.discardAll()
            }
        } catch {
            model.failureMessage = String(localized: "The practice couldn't be closed safely. Your files were not touched.")
            return
        }
        record = nil
        dragContext.clear()
        panel.orderOut(nil)
        endShelfPresentation()
    }

    private func closeAfterCompletion() {
        completionTask?.cancel()
        panel.orderOut(nil)
        endShelfPresentation()
    }

    private func removeTutorialItemIfPresentAndPersist() throws {
        guard let itemID = record?.tutorialItemID else { return }
        try shelfStore.removeAndPersistNow(ids: [itemID])
    }

    private func endShelfPresentation() {
        guard let snapshot = presentationSnapshot else { return }
        presentationSnapshot = nil
        shelfWindowController.endOnboardingPresentation(snapshot)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        skip()
        return false
    }
}

@MainActor
private final class OnboardingPanel: NSPanel {
    override init(contentRect: NSRect,
                  styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: style,
                   backing: backingStoreType,
                   defer: flag)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        animationBehavior = .none
        titleVisibility = .visible
    }

    override var canBecomeKey: Bool { true }
}

private struct OnboardingView: View {
    @Bindable var model: OnboardingViewModel
    let onSkip: () -> Void
    let onDone: () -> Void
    let onTutorialDrop: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 430, height: 258)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.phase == .complete ? "checkmark.circle.fill" : "hand.draw.fill")
                .font(.title2)
                .foregroundStyle(model.phase == .complete ? Color.green : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(stepLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .awaitingImport:
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    tutorialFileCard
                    if let url = model.tutorialFileURL {
                        TutorialDragSourceBridge(fileURL: url, token: model.token)
                    }
                }
                Text("This file was created by OpenYoink. It won't read, move, or upload your files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .awaitingExport:
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(model.isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(model.isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                                      style: StrokeStyle(lineWidth: model.isDropTargeted ? 2 : 1,
                                                         dash: [6, 4]))
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.down.to.line.compact")
                        Text("Drag the practice card from the shelf back here")
                            .fontWeight(.medium)
                    }
                }
                .frame(height: 76)
                .overlay {
                    TutorialDropTargetBridge(expectedToken: model.token,
                                             isTargeted: $model.isDropTargeted,
                                             onDrop: onTutorialDrop)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Practice drop target")
                .accessibilityIdentifier("onboarding.drop-target")
                Text("The same gesture works after switching windows, Spaces, or full-screen apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .complete:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("You're ready. OpenYoink will appear when you start dragging, and ⌘⇧Space shows or hides it anytime.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10)
        case .fallback:
            VStack(alignment: .leading, spacing: 10) {
                Label("1. Drag content into the shelf.", systemImage: "1.circle.fill")
                Label("2. Drag its card out to your destination.", systemImage: "2.circle.fill")
                if let failureMessage = model.failureMessage {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tutorialFileCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            Text(OnboardingSessionStore.tutorialFileName)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer()
            Label("Drag to the shelf", systemImage: "arrow.right")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OpenYoink practice file. Drag to the shelf.")
        .accessibilityIdentifier("onboarding.practice-file")
    }

    private var footer: some View {
        HStack {
            if let failureMessage = model.failureMessage, model.phase != .fallback {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if model.phase == .complete {
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.done")
            } else {
                Button("Skip", action: onSkip)
                    .accessibilityIdentifier("onboarding.skip")
            }
        }
    }

    private var stepLabel: String {
        switch model.phase {
        case .awaitingImport: String(localized: "1 of 2")
        case .awaitingExport: String(localized: "2 of 2")
        case .complete: String(localized: "Complete")
        case .fallback: String(localized: "Quick guide")
        }
    }

    private var title: String {
        switch model.phase {
        case .awaitingImport: String(localized: "Put it in")
        case .awaitingExport: String(localized: "Take it back out")
        case .complete: String(localized: "Nice work")
        case .fallback: String(localized: "Two simple steps")
        }
    }
}

/// 第一步的真实 NSDraggingSource 桥。它提供 file URL 与随机 tutorial token，
/// shelf 仍通过现有 DropImportCoordinator 生成 ShelfItem。
private struct TutorialDragSourceBridge: NSViewRepresentable {
    let fileURL: URL
    let token: String

    func makeNSView(context: Context) -> TutorialDragSourceView {
        TutorialDragSourceView(fileURL: fileURL, token: token)
    }

    func updateNSView(_ nsView: TutorialDragSourceView, context: Context) {
        nsView.fileURL = fileURL
        nsView.token = token
    }
}

@MainActor
private final class TutorialDragSourceView: NSView {
    var fileURL: URL
    var token: String
    private var mouseDownLocation: CGPoint?
    private var dragStarted = false

    init(fileURL: URL, token: String) {
        self.fileURL = fileURL
        self.token = token
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Programmatic view") }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let start = mouseDownLocation else { return }
        let current = event.locationInWindow
        guard hypot(current.x - start.x, current.y - start.y) >= 4 else { return }
        dragStarted = true
        let writer = TutorialSourceWriter(fileURL: fileURL, token: token)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        icon.size = CGSize(width: 54, height: 54)
        item.setDraggingFrame(CGRect(origin: .zero, size: CGSize(width: 64, height: 64)),
                              contents: icon)
        beginDraggingSession(with: [item], event: event, source: TutorialSource())
    }
}

private final class TutorialSourceWriter: NSObject, NSPasteboardWriting {
    let fileURL: URL
    let token: String

    init(fileURL: URL, token: String) {
        self.fileURL = fileURL
        self.token = token
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, PasteboardTypes.tutorialSession]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL: fileURL.absoluteString as NSString
        case PasteboardTypes.tutorialSession: token as NSString
        default: nil
        }
    }
}

@MainActor
private final class TutorialSource: NSObject, NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

private struct TutorialDropTargetBridge: NSViewRepresentable {
    let expectedToken: String
    @Binding var isTargeted: Bool
    let onDrop: (String) -> Void

    func makeNSView(context: Context) -> TutorialDropTargetView {
        let view = TutorialDropTargetView()
        view.expectedToken = expectedToken
        view.onTargetedChange = { isTargeted = $0 }
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: TutorialDropTargetView, context: Context) {
        nsView.expectedToken = expectedToken
        nsView.onTargetedChange = { isTargeted = $0 }
        nsView.onDrop = onDrop
    }
}

@MainActor
private final class TutorialDropTargetView: NSView {
    var expectedToken = ""
    var onTargetedChange: ((Bool) -> Void)?
    var onDrop: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([PasteboardTypes.tutorialSession])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Programmatic view") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard matchingToken(in: sender.draggingPasteboard) != nil else { return [] }
        onTargetedChange?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        matchingToken(in: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargetedChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let token = matchingToken(in: sender.draggingPasteboard) else { return false }
        onDrop?(token)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        onTargetedChange?(false)
    }

    private func matchingToken(in pasteboard: NSPasteboard) -> String? {
        guard let value = pasteboard.string(forType: PasteboardTypes.tutorialSession),
              value == expectedToken else { return nil }
        return value
    }
}
