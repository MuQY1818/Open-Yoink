import AppKit
import OSLog
import UniformTypeIdentifiers

/// 一次拖入的分派结果：同步产出的项目 + 仍在后台物化的数量。
struct DropImportResult: Equatable, Sendable {
    /// 已可直接入架的项目（fileURL / URL / 文本路径同步产出）。
    var items: [ShelfItem]
    /// 已派发到后台、稍后经 `onAsyncItemReady` 回调产出的物化任务数
    /// （file promise 与图片数据路径）。
    var pendingMaterializations: Int

    /// 是否有任何内容被处理（决定 `performDragOperation` 的返回值）。
    var handled: Bool { !items.isEmpty || pendingMaterializations > 0 }

    static let unhandled = DropImportResult(items: [], pendingMaterializations: 0)
}

/// 拖入模式（F-05 双模式）：直接拖入 = 复制引用（现状语义）；⌘+拖入 =
/// 剪切移入（原文件进废纸篓，保管副本入架）。⌘ 只对 file/folder 的 fileURL
/// 拖入生效 —— file promise / 文本 / URL / 纯图片数据没有「原文件」概念。
enum DropInMode: String, Equatable, Sendable {
    /// 直接拖入：保存原文件引用，原文件不动（默认）。
    case copy
    /// ⌘+拖入：原文件移入保管目录（原位置进废纸篓），拖出时交付并离架。
    case move
}

/// 把 `NSPasteboard`（来自 `NSDraggingInfo`）转成 `[ShelfItem]` 的纯逻辑层。
///
/// 与 AppKit 拖放协议解耦：输入是 pasteboard，输出是同步 items + 异步物化
/// 回调，便于单测（测试中可直接构造 `NSPasteboard(name:)` 实例喂数据）。
///
/// 处理顺序严格遵循调研报告 F-03 与实施计划 §2.3：
/// **file promise → fileURL → 图片数据 → URL → 文本**。高优先级类别声明了
/// 类型但实际读不到内容时（极少数来源的怪异行为），按顺序回退到下一类别，
/// 不会直接丢弃整个拖放。
///
/// 任务一「万能拖入」：主链全部零产出时进入兜底链（`fallbackImport`），
/// 逐 pasteboard item 独立处理（混合多 item 各自寻找最佳出口）：
/// a. `text/uri-list` → URL 项；b. 仅 HTML/RTF（无 plain text）→ 物化
/// .html/.rtf 文件项；c. 通用数据物化（最佳类型挑选见
/// `PasteboardTypes.materializationCandidates`）；d. 任何类型读出非空
/// 字符串 → 文本项；e. 逐项日志，整次零产出 → notice 提示 + 不接收拖放。
///
/// 已知限制：
/// - 来源应用：跨应用拖拽时 `NSDraggingInfo.draggingSource` 为 nil，本层
///   只看到 pasteboard，v1 统一留 `sourceApp = nil`。
/// - 目录拖入按单项目处理（`kind = .folder`），不展开递归。
/// - 主链保持「整板优先类别胜出」语义（fileURL+text 混合拖放只取 fileURL，
///   见既有单测 `testImport_fileURLAndText_fileURLWins`）；逐 item 独立处理
///   仅在兜底链内进行。
@MainActor
final class DropImportCoordinator {
    /// 物化图片项目的默认显示名（落盘文件名带 UUID 前缀，显示名保持干净）。
    /// S10: 用户可见，走 catalog 本地化；保持计算属性以兼容既有引用（含单测）。
    nonisolated static var materializedImageDisplayName: String {
        String(localized: "Dropped Image.png")
    }

    /// UX1: 成功导入回调（拖入与 UX3 剪贴板保存共用此入口）。`importItems`
    /// 返回 `handled` 时在 MainActor 上同步触发 —— AppDelegate 据此标记
    /// 拖拽自动唤出会话「本轮已有内容落入」，拖结束时不再自动收回。
    var onImportHandled: (@MainActor () -> Void)?

    /// 快速上手的运行时令牌验证与导入回调。只有当前 session 的随机令牌
    /// 才能让本应用内部拖拽穿过 shelf 的「拒绝自身回落」防线。
    var isActiveTutorialToken: (@MainActor (String) -> Bool)?
    var onTutorialItemsImported: (@MainActor (String, [ShelfItem]) -> Void)?

    /// 共享的书签服务（ShelfWindowController 把它注入 SwiftUI 环境，
    /// 供卡片缩略图/打开操作经 bookmark 解析文件访问权）。
    let bookmarkService: BookmarkService
    /// D10: 拖入/物化失败的内联提示中心（ShelfWindowController 注入 SwiftUI 环境，
    /// ShelfView 渲染标题栏下方的瞬态胶囊）。
    let noticeCenter: ShelfNoticeModel
    /// F-05: ⌘+拖入（剪切模式）的搬运编排（copy → 校验 → trash → isCut item）。
    let cutMoveService: CutMoveService
    /// v1.2: 托管移动恢复事务。只有 managed item 已同步写入 shelf snapshot
    /// 后才由 `markManagedMoveCommitted` 删除对应记录。
    let managedMoveJournal: ManagedMoveJournal
    /// v1.2: promised files are journaled before leaving staging and remain
    /// retryable until their ShelfItem is synchronously persisted.
    let pendingImportJournal: PendingImportJournal
    /// v1.2: runtime-only batch status rendered by ShelfActivityStrip.
    let transferStore: TransferStore
    private let tempFileService: TempFileService
    private let promiseReceiver: FilePromiseReceiver
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "DropImport")

    init(bookmarkService: BookmarkService,
         tempFileService: TempFileService,
         noticeCenter: ShelfNoticeModel = ShelfNoticeModel(),
         managedMoveJournal: ManagedMoveJournal? = nil,
         pendingImportJournal: PendingImportJournal? = nil,
         transferStore: TransferStore? = nil,
         cutMoveService: CutMoveService? = nil) {
        self.bookmarkService = bookmarkService
        self.tempFileService = tempFileService
        self.noticeCenter = noticeCenter
        self.transferStore = transferStore ?? TransferStore()
        let journal = managedMoveJournal
            ?? cutMoveService?.managedMoveJournal
            ?? ManagedMoveJournal(directoryURL: tempFileService.directoryURL.deletingLastPathComponent())
        self.managedMoveJournal = journal
        let pendingJournal = pendingImportJournal ?? PendingImportJournal(
            directoryURL: tempFileService.directoryURL.deletingLastPathComponent(),
            managedDirectoryURL: tempFileService.directoryURL
        )
        self.pendingImportJournal = pendingJournal
        self.cutMoveService = cutMoveService ?? CutMoveService(
            tempFileService: tempFileService,
            bookmarkService: bookmarkService,
            managedMoveJournal: journal
        )
        self.promiseReceiver = FilePromiseReceiver(tempFileService: tempFileService,
                                                   bookmarkService: bookmarkService,
                                                   pendingImportJournal: pendingJournal,
                                                   transferStore: self.transferStore)
    }

    // MARK: - Entry point

    /// F-05: 修饰键 → 拖入模式（纯函数，单测直断）。⌘ 且拖放含 fileURL
    /// 时为剪切（.move）；其余一律 .copy —— 非文件类内容没有「原文件」可移。
    /// `modifiers` 由调用方读 `NSEvent.modifierFlags`（拖拽会话期间的实时状态）。
    nonisolated static func dropMode(for pasteboard: NSPasteboard,
                                     modifiers: NSEvent.ModifierFlags) -> DropInMode {
        guard modifiers.contains(.command),
              PasteboardTypes.supports(.fileURL, types: pasteboard.types ?? []) else {
            return .copy
        }
        return .move
    }

    /// 分派一次拖入。同步可产出的项目放进返回值；file promise 与图片数据
    /// 在后台物化，完成后经 `onAsyncItemReady`（MainActor 上调用）逐个产出。
    /// UX1: 结果被 `handled` 时同步触发 `onImportHandled`。
    /// F-05: `mode == .move`（⌘+拖入）时 fileURL 分支改走 cut 搬运。
    @discardableResult
    func importItems(from pasteboard: NSPasteboard,
                     mode: DropInMode = .copy,
                     onManagedMoveReady: (@MainActor (ShelfItem) -> Bool)? = nil,
                     onPromisedItemReady: (@MainActor (ShelfItem) -> Bool)? = nil,
                     onAsyncItemReady: @escaping @MainActor (ShelfItem) -> Void) -> DropImportResult {
        let batchID = UUID()
        let tutorialToken = activeTutorialToken(in: pasteboard)
        let wrappedAsyncReady: @MainActor (ShelfItem) -> Void = { [weak self] item in
            onAsyncItemReady(item)
            guard let self, let tutorialToken else { return }
            self.onTutorialItemsImported?(tutorialToken, [item])
        }
        let wrappedPromisedReady: @MainActor (ShelfItem) -> Bool = { [weak self] item in
            guard let onPromisedItemReady else {
                wrappedAsyncReady(item)
                return true
            }
            let committed = onPromisedItemReady(item)
            if committed, let self, let tutorialToken {
                self.onTutorialItemsImported?(tutorialToken, [item])
            }
            return committed
        }
        let result = dispatchImport(from: pasteboard,
                                    batchID: batchID,
                                    mode: mode,
                                    onManagedMoveReady: onManagedMoveReady,
                                    onPromisedItemReady: wrappedPromisedReady,
                                    onAsyncItemReady: wrappedAsyncReady)
        if result.handled {
            onImportHandled?()
        }
        return result
    }

    /// `NSDraggingDestination` 用于判定同进程来源是否是当前练习，而不是普通
    /// shelf 卡片回落。令牌不匹配时严格拒绝。
    func acceptsInternalTutorialDrag(_ pasteboard: NSPasteboard) -> Bool {
        activeTutorialToken(in: pasteboard) != nil
    }

    /// 同步 file URL 项由调用方先放进 ShelfStore，再调用本方法推进引导，
    /// 保证面板切到第二步时练习卡已经真实存在于 shelf。
    func noteSynchronousTutorialImport(from pasteboard: NSPasteboard,
                                       items: [ShelfItem]) {
        guard !items.isEmpty, let token = activeTutorialToken(in: pasteboard) else { return }
        onTutorialItemsImported?(token, items)
    }

    private func activeTutorialToken(in pasteboard: NSPasteboard) -> String? {
        guard let token = pasteboard.string(forType: PasteboardTypes.tutorialSession),
              !token.isEmpty,
              isActiveTutorialToken?(token) == true else {
            return nil
        }
        return token
    }

    /// 实际的分派逻辑（`importItems` 的薄包装之下，便于统一触发导入回调）。
    private func dispatchImport(from pasteboard: NSPasteboard,
                                batchID: UUID,
                                mode: DropInMode,
                                onManagedMoveReady: (@MainActor (ShelfItem) -> Bool)?,
                                onPromisedItemReady: @escaping @MainActor (ShelfItem) -> Bool,
                                onAsyncItemReady: @escaping @MainActor (ShelfItem) -> Void) -> DropImportResult {
        let types = pasteboard.types ?? []

        // 1. file promise 优先（高质量表示；F-03 明确建议先尝试 promise）。
        if PasteboardTypes.supports(.filePromise, types: types) {
            let pending = promiseReceiver.receivePromises(from: pasteboard,
                                                           taskID: batchID,
                                                           onItemReady: onPromisedItemReady)
            if pending > 0 {
                return DropImportResult(items: [], pendingMaterializations: pending)
            }
            // 声明了 promise 类型但 readObjects 拿不到 receiver：继续回退。
        }

        // 2. fileURL（Finder 文件/文件夹，及其他应用的文件表示）。
        if PasteboardTypes.supports(.fileURL, types: types) {
            if mode == .move {
                // v1.2: copy/trash can be expensive. Capture bookmarks while
                // the pasteboard grant is active, then perform each transaction
                // serially on a detached task.
                let pending = scheduleCutMovedItems(
                    from: pasteboard,
                    taskID: batchID,
                    onManagedMoveReady: onManagedMoveReady,
                    onItemReady: onAsyncItemReady
                )
                if pending > 0 {
                    return DropImportResult(items: [], pendingMaterializations: pending)
                }
            } else {
                let items = fileURLItems(from: pasteboard)
                if !items.isEmpty {
                    return DropImportResult(items: items, pendingMaterializations: 0)
                }
            }
        }

        // 3. 图片数据（无文件 URL 的位图）：物化 PNG 到 TempFileService 目录。
        if let imageType = PasteboardTypes.preferredImageType(in: types) {
            let pending = scheduleImageMaterialization(from: pasteboard,
                                                       taskID: batchID,
                                                       preferredType: imageType,
                                                       onItemReady: onAsyncItemReady)
            if pending > 0 {
                return DropImportResult(items: [], pendingMaterializations: pending)
            }
        }

        // 4. URL。
        if PasteboardTypes.supports(.url, types: types) {
            let items = urlItems(from: pasteboard)
            if !items.isEmpty {
                return DropImportResult(items: items, pendingMaterializations: 0)
            }
        }

        // 5. 文本族（v1 只取 plain text，见类型注释）。
        if PasteboardTypes.supports(.text, types: types) {
            let items = textItems(from: pasteboard)
            if !items.isEmpty {
                return DropImportResult(items: items, pendingMaterializations: 0)
            }
        }

        // 6. 兜底链（任务一）：主链零产出时逐 item 处理，尽可能物化出内容。
        let fallback = fallbackImport(from: pasteboard,
                                      taskID: batchID,
                                      onAsyncItemReady: onAsyncItemReady)
        guard !fallback.items.isEmpty || fallback.pending > 0 else {
            logger.warning("Drop contained no importable content; declared types: \(types.map(\.rawValue), privacy: .public)")
            noticeCenter.show(String(localized: "That content can't be added to the shelf yet."))
            return .unhandled
        }
        // A heterogeneous fallback drop can contain synchronous rich text/URL
        // items alongside background materializations. Once a runtime batch
        // exists, include those already-ready items in the same factual total.
        if fallback.pending > 0, !fallback.items.isEmpty {
            transferStore.extendImport(id: batchID, by: fallback.items.count)
            for item in fallback.items {
                transferStore.recordSuccess(taskID: batchID, itemID: item.id)
            }
        }
        return DropImportResult(items: fallback.items, pendingMaterializations: fallback.pending)
    }

    // MARK: - Fallback chain (任务一「万能拖入」)

    /// 兜底链：主链（promise→fileURL→image→url→text）全部零产出时调用。
    /// 逐 pasteboard item 独立走 a→b→c→d 分支；同步产出的项目直接返回，
    /// 通用数据物化（payload 可能很大）走后台写盘、计入 pending。
    private func fallbackImport(from pasteboard: NSPasteboard,
                                taskID: UUID,
                                onAsyncItemReady: @escaping @MainActor (ShelfItem) -> Void)
        -> (items: [ShelfItem], pending: Int) {
        var items: [ShelfItem] = []
        var pending = 0

        // a. URL 变体：text/uri-list。探针结论：该 flavor 在 item 级被桥接为
        //    dyn.* 动态类型（item.string(forType: "text/uri-list") 读不到），
        //    只能在 pasteboard 级按原始 flavor 字符串读取，故本分支是整板级的；
        //    每行一个 URI（# 开头为注释行），逐行产出 URL 项。
        let urlListItems = urlListVariantItems(from: pasteboard)
        items.append(contentsOf: urlListItems)

        for pasteboardItem in pasteboard.pasteboardItems ?? [] {
            // uri-list 已产出 URL 项时，跳过「全是 dyn.* 桥接类型」的 item ——
            // 它就是 uri-list 在 item 级的投影（探针 A），再走 b/c/d 会用同一份
            // 内容重复产出 .dat/文本项。
            if !urlListItems.isEmpty,
               pasteboardItem.types.allSatisfy({ $0.rawValue.hasPrefix("dyn.") }) {
                continue
            }
            // b. 仅 HTML/RTF（无 plain text 才会到达兜底链）：物化富文本文件项，
            //    拖出到 Pages/浏览器仍是富文本。payload 为文本级大小，同步落盘。
            if let richItem = richTextFileItem(from: pasteboardItem) {
                items.append(richItem)
                continue
            }
            // c. 通用数据物化：最佳类型挑选（tier 排序见
            //    `PasteboardTypes.materializationCandidates`），后台写盘。
            if scheduleDataMaterialization(from: pasteboardItem,
                                           taskID: taskID,
                                           onItemReady: onAsyncItemReady) {
                pending += 1
                continue
            }
            // d. 字符串兜底：任何类型能 string(forType:) 出非空内容 → 文本项。
            if let textItem = fallbackTextItem(from: pasteboardItem) {
                items.append(textItem)
                continue
            }
            // e. 逐项失败日志（不静默）。
            logger.info("Fallback import skipped an item; declared types: \(pasteboardItem.types.map(\.rawValue), privacy: .public)")
        }
        return (items, pending)
    }

    /// 分支 a：text/uri-list → URL 项（每行一个 URI，# 注释行跳过；首个无效行
    /// 不影响其余行）。粘贴板级读取（桥接原因见 `fallbackImport` 注释）。
    private func urlListVariantItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        guard (pasteboard.types ?? []).contains(PasteboardTypes.uriList),
              let payload = pasteboard.string(forType: PasteboardTypes.uriList),
              !payload.isEmpty else {
            return []
        }
        return payload.components(separatedBy: .newlines).compactMap { line in
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, !candidate.hasPrefix("#"),
                  let url = URL(string: candidate), url.scheme != nil else {
                return nil
            }
            return ShelfItem(kind: .url,
                             displayName: url.host() ?? candidate,
                             urlString: candidate)
        }
    }

    /// 分支 b：仅 HTML/RTF 的 item → 物化为 .html/.rtf 文件项（kind=.file，
    /// 拖出仍是富文本）。displayName 用 NSAttributedString 提取的纯文本首行
    /// 截断；提取为空时用本地化兜底名。HTML 解析必须在主线程（本类即在
    /// MainActor 上运行），勿移入后台任务。
    private func richTextFileItem(from pasteboardItem: NSPasteboardItem) -> ShelfItem? {
        if pasteboardItem.types.contains(PasteboardTypes.html),
           let data = pasteboardItem.data(forType: PasteboardTypes.html), !data.isEmpty {
            let plainText = NSAttributedString(html: data, documentAttributes: nil)?.string ?? ""
            return writeRichTextFile(data: data,
                                     fileExtension: "html",
                                     plainText: plainText,
                                     fallbackBaseName: String(localized: "Dropped HTML"))
        }
        if pasteboardItem.types.contains(PasteboardTypes.rtf),
           let data = pasteboardItem.data(forType: PasteboardTypes.rtf), !data.isEmpty {
            let plainText = NSAttributedString(rtf: data, documentAttributes: nil)?.string ?? ""
            return writeRichTextFile(data: data,
                                     fileExtension: "rtf",
                                     plainText: plainText,
                                     fallbackBaseName: String(localized: "Dropped RTF"))
        }
        return nil
    }

    /// 富文本物化落盘（b 分支共用）。写盘失败不静默：日志 + notice，返回 nil
    /// 让调用方继续尝试后续分支（字符串兜底仍可能产出文本项）。
    private func writeRichTextFile(data: Data, fileExtension: String,
                                   plainText: String, fallbackBaseName: String) -> ShelfItem? {
        // 提取的纯文本为空时用兜底名。探针结论：仅含 <img> 等嵌入对象的 HTML
        // 提取结果是 U+FFFC（object replacement character），先剥掉再判空；
        // 非空复用文本项命名规则（首行截断）。
        let stripped = plainText.replacingOccurrences(of: "\u{FFFC}", with: "")
        let hasText = !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let baseName = hasText ? Self.displayName(forText: stripped) : fallbackBaseName
        let fileName = "\(Self.sanitizedFileNameComponent(baseName)).\(fileExtension)"
        do {
            let destination = try tempFileService.uniqueFileURL(suggestedName: fileName)
            try data.write(to: destination, options: .atomic)
            return Self.makeFileBackedItem(for: destination,
                                           displayName: fileName,
                                           forcedKind: .file,
                                           bookmarkService: bookmarkService,
                                           logger: logger)
        } catch {
            logger.error("Failed to materialize dropped rich text: \(error.localizedDescription, privacy: .public)")
            noticeCenter.show(String(localized: "Couldn't add the dropped item."))
            return nil
        }
    }

    /// 分支 c：通用数据物化。按 `materializationCandidates` 的 tier 顺序取第一个
    /// 能读出非空 data 的类型，后台写盘（payload 可能很大，与图片物化同模式），
    /// kind 按 UTI 推断（image→.image，其余 .file）。返回是否已派发。
    private func scheduleDataMaterialization(from pasteboardItem: NSPasteboardItem,
                                             taskID: UUID,
                                             onItemReady: @escaping @MainActor (ShelfItem) -> Void) -> Bool {
        for candidate in PasteboardTypes.materializationCandidates(in: pasteboardItem.types) {
            // tier3（动态/桥接/泛型）且能读出「有意义的文本」→ 文本项比 .dat
            // 更有用，让给 d 分支（如 utf8-external-plain-text 这类 UTType
            // 解析为 nil 的文本 flavor；探针：string(forType:) 对它们有效）。
            // 注意必须有意义门槛：string(forType:) 对二进制数据也会做有损解码
            // （探针：[1,2,3] → "\u{1}\u{2}\u{3}"），无门槛会把二进制变成乱码文本。
            if candidate.tier == 3,
               let text = pasteboardItem.string(forType: candidate.type),
               Self.isMeaningfulText(text) {
                continue
            }
            let type = candidate.type
            guard let data = pasteboardItem.data(forType: type), !data.isEmpty else { continue }
            let fileExtension = PasteboardTypes.materializationFileExtension(for: type)
            let baseName = PasteboardTypes.materializedDisplayBaseName(for: type)
            let fileName = "\(Self.sanitizedFileNameComponent(baseName)).\(fileExtension)"
            let kind: ItemKind = UTType(type.rawValue)?.conforms(to: .image) == true ? .image : .file
            transferStore.extendImport(id: taskID, by: 1)
            let reportFailure: @MainActor () -> Void = { [transferStore] in
                transferStore.recordFailure(
                    taskID: taskID,
                    failure: TransferFailure(
                        reason: .materializationFailed,
                        itemName: fileName,
                        recoveryAction: .dragAgainFromSource
                    )
                )
            }
            let reportSuccess: @MainActor (ShelfItem) -> Void = { [transferStore] item in
                onItemReady(item)
                transferStore.recordSuccess(taskID: taskID, itemID: item.id)
            }
            Task.detached { [bookmarkService, tempFileService, logger] in
                do {
                    let destination = try tempFileService.uniqueFileURL(suggestedName: fileName)
                    try data.write(to: destination, options: .atomic)
                    let item = Self.makeFileBackedItem(for: destination,
                                                       displayName: fileName,
                                                       forcedKind: kind,
                                                       bookmarkService: bookmarkService,
                                                       logger: logger)
                    await reportSuccess(item)
                } catch {
                    logger.error("Failed to materialize dropped data (\(type.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    await reportFailure()
                }
            }
            return true
        }
        return false
    }

    /// 分支 d：字符串兜底 —— item 的任何类型能读出「有意义的文本」即产出文本项
    /// （按声明顺序取首个）。`string(forType:)` 对非字符串类类型返回 nil，
    /// 对二进制数据做有损解码 —— 由 `isMeaningfulText` 挡掉乱码。
    private func fallbackTextItem(from pasteboardItem: NSPasteboardItem) -> ShelfItem? {
        for type in pasteboardItem.types {
            guard let text = pasteboardItem.string(forType: type),
                  Self.isMeaningfulText(text) else { continue }
            return ShelfItem(kind: .text, displayName: Self.displayName(forText: text), text: text)
        }
        return nil
    }

    /// 字符串兜底的「有意义文本」门槛：非空且不含控制字符（空白/换行/制表除外）。
    /// 探针结论：`string(forType:)` 对任意二进制数据可能做有损解码
    /// （[0x01,0x02,0x03] → "\u{1}\u{2}\u{3}"），无此门槛二进制 payload 会被
    /// 误判为乱码文本项而不是物化为 .dat。
    nonisolated static func isMeaningfulText(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        let controls = CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines)
        return string.rangeOfCharacter(from: controls) == nil
    }

    /// 物化文件名单元清洗：去掉路径分隔符（显示名首行可能含 "/"，
    /// `TempFileService` 的 lastPathComponent 清洗会把整名前段吃掉）。
    nonisolated static func sanitizedFileNameComponent(_ name: String) -> String {
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? String(localized: "Dropped Item") : sanitized
    }

    // MARK: - fileURL

    private func fileURLItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return []
        }
        return urls.map { Self.makeFileBackedItem(for: $0, displayName: $0.lastPathComponent, bookmarkService: bookmarkService, logger: logger) }
    }

    // MARK: - fileURL（F-05 剪切模式）

    /// ⌘+拖入：在拖放会话内同步捕获 URL + bookmark，随后把 copy → journal
    /// → trash 搬运放到后台串行执行。串行避免一次多选拖入同时争抢磁盘 IO，
    /// 同时保持来源顺序。成功的 managed item 走专用回调，调用方必须先同步
    /// 持久化再删除 journal；失败回退项走普通异步回调。
    private func scheduleCutMovedItems(
        from pasteboard: NSPasteboard,
        taskID: UUID,
        onManagedMoveReady: (@MainActor (ShelfItem) -> Bool)?,
        onItemReady: @escaping @MainActor (ShelfItem) -> Void
    ) -> Int {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return 0
        }

        let service = cutMoveService
        let requests = urls.map {
            service.prepareRequest(for: $0, displayName: $0.lastPathComponent)
        }
        guard !requests.isEmpty else { return 0 }
        transferStore.beginImport(
            id: taskID,
            expectedCount: requests.count,
            safetyMessage: String(localized: "Managed copies are protected while originals move to the Trash.")
        )
        let transferStore = transferStore
        Task.detached(priority: .userInitiated) {
            for request in requests {
                switch service.makeCutItem(for: request) {
                case .moved(let item):
                    await MainActor.run {
                        let committed: Bool
                        if let onManagedMoveReady {
                            committed = onManagedMoveReady(item)
                        } else {
                            // Defensive compatibility path. The journal stays
                            // until startup reconciliation if the caller does
                            // not provide the commit-aware callback.
                            onItemReady(item)
                            committed = true
                        }
                        if committed {
                            transferStore.recordSuccess(taskID: taskID, itemID: item.id)
                        } else {
                            transferStore.recordWarning(
                                taskID: taskID,
                                itemID: item.id,
                                warning: TransferFailure(
                                    reason: .persistenceFailed,
                                    itemName: request.displayName,
                                    recoveryAction: .openStorageRecovery,
                                    impact: .itemAddedWithWarning
                                )
                            )
                        }
                    }
                case .fallbackToReference(let item, let reason):
                    await MainActor.run {
                        onItemReady(item)
                        if reason == .sourceInsideContainer {
                            // The item was intentionally downgraded to a normal
                            // reference, so the batch still succeeded.
                            transferStore.recordSuccess(taskID: taskID, itemID: item.id)
                        } else {
                            transferStore.recordWarning(
                                taskID: taskID,
                                itemID: item.id,
                                warning: TransferFailure(
                                    reason: .managedMoveFellBackToReference,
                                    itemName: request.displayName,
                                    recoveryAction: .dismiss,
                                    impact: .itemAddedWithWarning
                                )
                            )
                        }
                    }
                }
            }
        }
        return requests.count
    }

    /// Deletes the recovery transaction after the caller has synchronously
    /// committed `item` to the shelf snapshot. Failure is safe: the record is
    /// reconciled on the next launch and continues protecting its managed path.
    func markManagedMoveCommitted(itemID: UUID) {
        do {
            try managedMoveJournal.remove(id: itemID)
        } catch {
            logger.error("Failed to finish managed move transaction \(itemID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Image data

    /// 提取各 pasteboard item 的图片 Data 后派发到后台物化。NSPasteboardItem
    /// 非 Sendable，Data 必须在本层（MainActor）就地取出，不跨 actor 传递原 item。
    private func scheduleImageMaterialization(from pasteboard: NSPasteboard,
                                              taskID: UUID,
                                              preferredType: NSPasteboard.PasteboardType,
                                              onItemReady: @escaping @MainActor (ShelfItem) -> Void) -> Int {
        let payloads: [(type: NSPasteboard.PasteboardType, data: Data)] =
            (pasteboard.pasteboardItems ?? []).compactMap { item in
                guard let type = PasteboardTypes.preferredImageType(in: item.types),
                      let data = item.data(forType: type) else {
                    return nil
                }
                return (type, data)
            }

        guard !payloads.isEmpty else { return 0 }
        transferStore.beginImport(id: taskID, expectedCount: payloads.count)
        let reportFailure: @MainActor () -> Void = { [transferStore] in
            transferStore.recordFailure(
                taskID: taskID,
                failure: TransferFailure(
                    reason: .materializationFailed,
                    itemName: Self.materializedImageDisplayName,
                    recoveryAction: .dragAgainFromSource
                )
            )
        }
        let reportSuccess: @MainActor (ShelfItem) -> Void = { [transferStore] item in
            onItemReady(item)
            transferStore.recordSuccess(taskID: taskID, itemID: item.id)
        }
        for payload in payloads {
            Task.detached { [bookmarkService, tempFileService, logger] in
                do {
                    guard let pngData = Self.pngData(from: payload.data, type: payload.type) else {
                        throw DropImportError.imageConversionFailed
                    }
                    let destination = try tempFileService.uniqueFileURL(suggestedName: Self.materializedImageDisplayName)
                    try pngData.write(to: destination, options: .atomic)
                    let item = Self.makeFileBackedItem(for: destination,
                                                       displayName: Self.materializedImageDisplayName,
                                                       forcedKind: .image,
                                                       bookmarkService: bookmarkService,
                                                       logger: logger)
                    await reportSuccess(item)
                } catch {
                    // 失败不崩溃、不静默：日志记录 + D10 内联提示，拖放本身仍视为已处理。
                    logger.error("Failed to materialize dropped image data: \(error.localizedDescription, privacy: .public)")
                    await reportFailure()
                }
            }
        }
        return payloads.count
    }

    /// PNG 数据直接使用；TIFF / 通用 image 经 NSBitmapImageRep 转码为 PNG。
    /// 非隔离：转码在后台任务内就地完成，非 Sendable 的 NSBitmapImageRep 不跨 actor。
    private nonisolated static func pngData(from data: Data, type: NSPasteboard.PasteboardType) -> Data? {
        if type == PasteboardTypes.png {
            return data
        }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }

    // MARK: - URL

    private func urlItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard item.types.contains(PasteboardTypes.url),
                  let string = item.string(forType: PasteboardTypes.url),
                  let url = URL(string: string),
                  url.scheme != nil else {
                return nil
            }
            return ShelfItem(kind: .url,
                             displayName: url.host() ?? string,
                             urlString: string)
        }
    }

    // MARK: - Text

    private func textItems(from pasteboard: NSPasteboard) -> [ShelfItem] {
        let items = (pasteboard.pasteboardItems ?? []).compactMap { item -> ShelfItem? in
            guard let text = item.string(forType: .string), !text.isEmpty else { return nil }
            return ShelfItem(kind: .text, displayName: Self.displayName(forText: text), text: text)
        }
        // 少数来源只在整体 pasteboard 上提供 string（逐项读取为空）。
        if items.isEmpty,
           let text = pasteboard.string(forType: .string), !text.isEmpty {
            return [ShelfItem(kind: .text, displayName: Self.displayName(forText: text), text: text)]
        }
        return items
    }

    /// 文本项目显示名：首行截断（60 字符），空白文本回退为本地化「Text」。
    static func displayName(forText text: String) -> String {
        let firstLine = text.components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return String(localized: "Text") }
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }

    // MARK: - Shared file-backed item construction

    /// file/folder/image 统一的构造入口：推断 kind + 立即创建安全书签。
    /// 非隔离，`FilePromiseReceiver` 的后台物化回调与图片物化任务也走这里。
    /// 书签创建失败不丢弃项目（仍有路径可作显示与回退提示），但记录日志。
    nonisolated static func makeFileBackedItem(for url: URL,
                                               displayName: String,
                                               forcedKind: ItemKind? = nil,
                                               promisedTypeIdentifiers: [String] = [],
                                               bookmarkService: BookmarkService,
                                               logger: Logger) -> ShelfItem {
        let kind = forcedKind ?? inferFileKind(for: url, promisedTypeIdentifiers: promisedTypeIdentifiers)
        let bookmark: Data?
        do {
            bookmark = try bookmarkService.createBookmark(for: url)
        } catch {
            logger.error("Failed to create bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            bookmark = nil
        }
        return ShelfItem(kind: kind, path: url.path, bookmark: bookmark, displayName: displayName)
    }

    /// kind 推断以实际物化结果为准：folder（目录且非 package）→ 可识别扩展名
    /// （image / file）→ 单一明确的 promise UTI 兜底 → file。
    ///
    /// 一个 NSFilePromiseReceiver 可以交付多个、甚至不同类型的文件；其
    /// `fileTypes` 是 receiver 级集合，不能把集合中的任意 image 类型套到每个
    /// 回调文件上，否则同批的 txt 会被误标成 image。
    nonisolated static func inferFileKind(for url: URL, promisedTypeIdentifiers: [String] = []) -> ItemKind {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true {
            return .folder
        }
        if !url.pathExtension.isEmpty,
           let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image) ? .image : .file
        }

        let promisedTypes = Set(promisedTypeIdentifiers.compactMap(UTType.init))
        if promisedTypes.count == 1, let type = promisedTypes.first {
            if type.conforms(to: .folder), !type.conforms(to: .package) { return .folder }
            if type.conforms(to: .image) { return .image }
        }
        return .file
    }
}

/// 拖入物化错误。
enum DropImportError: LocalizedError {
    /// 拖入的位图数据无法转成 PNG。
    case imageConversionFailed

    var errorDescription: String? {
        switch self {
        case .imageConversionFailed:
            String(localized: "Dropped image data could not be converted to PNG.")
        }
    }
}
