import AppKit
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import OpenYoink

/// DragPayloadBuilder 的策略映射 / stack 展开 / 各 kind 的表示集合断言。
///
/// 表示集合经 `NSPasteboard.writeObjects` 写入真实（测试私有）pasteboard 后
/// 断言其声明类型（advertised types）—— 与拖拽时 AppKit 走的路径一致，
/// 即拖放目标实际看到的类型集合。拖拽会话本身（`beginDraggingSession`）需要
/// 真实窗口与鼠标事件，列入手动回归清单。
///
/// 注：macOS 26 SDK 起 `NSItemProvider` 不具备 `NSPasteboardWriting` 一致性，
/// 不能作为 drag writer；因此断言对象为 pasteboard advertised types 而非
/// `registeredTypeIdentifiers`。
@MainActor
final class DragPayloadBuilderTests: XCTestCase {
    private let bookmarkService = BookmarkService()

    // MARK: - Helpers

    private func makeItem(kind: ItemKind, name: String = "item") -> ShelfItem {
        switch kind {
        case .file, .folder, .image:
            ShelfItem(kind: kind, path: "/tmp/\(name)", displayName: name)
        case .text:
            ShelfItem(kind: .text, displayName: name, text: "sample text")
        case .url:
            ShelfItem(kind: .url, displayName: name, urlString: "https://example.com")
        case .stack:
            ShelfItem(kind: .stack, displayName: name, children: [
                ShelfItem(kind: .file, path: "/tmp/child-a.txt", displayName: "child-a.txt"),
            ])
        }
    }

    /// 把 writer 写入测试 pasteboard，返回其声明的类型集合。
    private func advertisedTypes(of writer: NSPasteboardWriting) -> [String] {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        guard pasteboard.writeObjects([writer]) else { return [] }
        return pasteboard.types?.map(\.rawValue) ?? []
    }

    /// 把 writer 写入测试 pasteboard 并返回该 pasteboard（供读回数据断言，
    /// 与拖放目标的读取路径一致）。
    private func writtenPasteboard(for writer: NSPasteboardWriting) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        precondition(pasteboard.writeObjects([writer]), "writer 必须能写入 pasteboard")
        return pasteboard
    }

    // MARK: - 纯函数：策略映射

    func testStrategy_kindMapping() {
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .file)), .fileBacked)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .folder)), .fileBacked)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .image)), .fileBackedImage)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .text)), .plainText)
        XCTAssertEqual(DragPayloadBuilder.strategy(for: makeItem(kind: .url)), .webURL)
        XCTAssertNil(DragPayloadBuilder.strategy(for: makeItem(kind: .stack)),
                     "stack 不整体拖出，由 flattenedItems 展开")
    }

    // MARK: - 纯函数：stack 展开

    func testFlattenedItems_expandsStacksPreservingOrder() {
        let a = ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt")
        let b = ShelfItem(kind: .text, displayName: "b", text: "b")
        let c = ShelfItem(kind: .url, displayName: "c", urlString: "https://c.example.com")
        let d = ShelfItem(kind: .file, path: "/tmp/d.txt", displayName: "d.txt")
        let stack = ShelfItem(kind: .stack, displayName: "s", children: [b, c])

        let flat = DragPayloadBuilder.flattenedItems([a, stack, d])

        XCTAssertEqual(flat.map(\.displayName), ["a.txt", "b", "c", "d.txt"])
        XCTAssertEqual(flat.map(\.id), [a.id, b.id, c.id, d.id])
    }

    func testFlattenedItems_nestedStackAndEmptyStack() {
        let leaf = ShelfItem(kind: .file, path: "/tmp/leaf.txt", displayName: "leaf.txt")
        let inner = ShelfItem(kind: .stack, displayName: "inner", children: [leaf])
        let outer = ShelfItem(kind: .stack, displayName: "outer", children: [inner])
        let empty = ShelfItem(kind: .stack, displayName: "empty", children: [])

        // 嵌套 stack 递归展开；空 stack 原样保留（交由 writer 构造判 nil 丢弃）。
        let flat = DragPayloadBuilder.flattenedItems([outer, empty])
        XCTAssertEqual(flat.map(\.displayName), ["leaf.txt", "empty"])
    }

    // MARK: - 纯函数：promisedFileType

    func testPromisedFileType_folderExtensionFallback() {
        let folder = ShelfItem(kind: .folder, path: "/tmp/docs", displayName: "docs")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: folder), UTType.folder.identifier)

        // 与系统声明表对齐比较（macOS 26 起部分规范 UTI 如 public.pdf 已不再
        // 声明，声明表可能返回 com.adobe.pdf 等其他已声明标识符）。
        let text = ShelfItem(kind: .file, path: "/tmp/notes.txt", displayName: "notes.txt")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: text),
                       UTType(filenameExtension: "txt")?.identifier)

        let pdf = ShelfItem(kind: .file, path: "/tmp/report.pdf", displayName: "report.pdf")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: pdf),
                       UTType(filenameExtension: "pdf")?.identifier)

        let png = ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: png),
                       UTType(filenameExtension: "png")?.identifier)

        let noExtension = ShelfItem(kind: .file, path: "/tmp/README", displayName: "README")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: noExtension), UTType.data.identifier)

        let noPath = ShelfItem(kind: .file, displayName: "ghost")
        XCTAssertEqual(DragPayloadBuilder.promisedFileType(for: noPath), UTType.data.identifier)
    }

    /// NSFilePromiseProvider 对非法 fileType 抛 NSException（不可捕获）——
    /// promisedFileType 的输出必须符合 kUTTypeData/kUTTypeDirectory。
    func testPromisedFileType_alwaysConformsToDataOrDirectory() {
        let samples = [
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .file, path: "/tmp/a.pdf", displayName: "a.pdf"),
            ShelfItem(kind: .image, path: "/tmp/a.png", displayName: "a.png"),
            ShelfItem(kind: .file, path: "/tmp/a.unknownext123", displayName: "a.unknownext123"),
            ShelfItem(kind: .folder, path: "/tmp/docs", displayName: "docs"),
            ShelfItem(kind: .file, path: "/tmp/README", displayName: "README"),
        ]
        for item in samples {
            let identifier = DragPayloadBuilder.promisedFileType(for: item)
            let type = UTType(identifier)
            XCTAssertNotNil(type, "\(identifier) 必须是已声明 UTI")
            XCTAssertTrue(type?.conforms(to: .data) == true || type?.conforms(to: .directory) == true,
                          "\(identifier) 必须符合 data/directory（NSFilePromiseProvider 硬性要求）")
        }
    }

    // MARK: - 文件项：fileURL + promise 双表示

    func testFileItem_writerAdvertisesFileURLAndPromise() throws {
        let item = ShelfItem(kind: .file, path: "/tmp/report.pdf", displayName: "report.pdf")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let promiseProvider = try XCTUnwrap(writer as? FilePromiseProvider,
                                            "文件项 writer 应为 NSFilePromiseProvider 子类")
        XCTAssertEqual(promiseProvider.fileType, DragPayloadBuilder.promisedFileType(for: item))

        let advertised = advertisedTypes(of: writer)
        XCTAssertTrue(advertised.contains(UTType.fileURL.identifier),
                      "advertised types \(advertised) 应含 public.file-url（Finder copy 语义路径）")
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes
        XCTAssertTrue(advertised.contains { promiseTypes.contains($0) },
                      "advertised types \(advertised) 应含 file promise 类型 \(promiseTypes)")

        // fileURL 表示的数据内容：URL 字符串（Finder 可解析）。
        XCTAssertEqual(writer.pasteboardPropertyList(forType: .fileURL) as? String,
                       "file:///tmp/report.pdf")
    }

    func testFolderItem_writerAdvertisesFileURLAndPromise() throws {
        let item = ShelfItem(kind: .folder, path: "/tmp/docs", displayName: "docs")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let advertised = advertisedTypes(of: writer)
        XCTAssertTrue(advertised.contains(UTType.fileURL.identifier))
        XCTAssertTrue(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) })
        XCTAssertEqual((writer as? FilePromiseProvider)?.fileType, UTType.folder.identifier)
    }

    func testImageItem_writerAdvertisesFileURLPromiseAndTIFF() throws {
        let item = ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let advertised = advertisedTypes(of: writer)
        XCTAssertTrue(advertised.contains(UTType.fileURL.identifier))
        XCTAssertTrue(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) })
        XCTAssertTrue(advertised.contains(UTType.tiff.identifier),
                      "图片项应声明 public.tiff 位图回退")
    }

    // MARK: - 文本项

    func testTextItem_advertisesPlainText() throws {
        let item = ShelfItem(kind: .text, displayName: "note", text: "hello shelf")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        // NSPasteboardItem 只能写入一个 pasteboard（写第二次会抛异常）——
        // 一次写入，同板断言声明类型与读回数据（读回路径与目标应用一致）。
        let pasteboard = writtenPasteboard(for: writer)
        let advertised = pasteboard.types?.map(\.rawValue) ?? []
        XCTAssertTrue(advertised.contains(UTType.utf8PlainText.identifier),
                      "advertised types \(advertised) 应含 public.utf8-plain-text")
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier))
        XCTAssertEqual(pasteboard.string(forType: .string), "hello shelf")
    }

    // MARK: - URL 项

    func testURLItem_advertisesURLAndText_butNotFileURL() throws {
        let item = ShelfItem(kind: .url, displayName: "Apple", urlString: "https://www.apple.com")
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let pasteboard = writtenPasteboard(for: writer)
        let advertised = pasteboard.types?.map(\.rawValue) ?? []
        XCTAssertTrue(advertised.contains(UTType.url.identifier))
        XCTAssertTrue(advertised.contains(UTType.utf8PlainText.identifier))
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier),
                       "web URL 不得连带声明 public.file-url（错误表示）")
        // 读回路径与目标应用一致（NSURL 读取 + 文本回退）。
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.url), "https://www.apple.com")
        XCTAssertEqual(pasteboard.string(forType: .string), "https://www.apple.com")
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])
        XCTAssertEqual(urls, [URL(string: "https://www.apple.com")!])
    }

    // MARK: - F-05 剪切项：只广告 promise 类型

    func testCutItem_writerAdvertisesPromiseOnly_noFileURL() throws {
        var item = ShelfItem(kind: .file, path: "/tmp/report.pdf", displayName: "report.pdf")
        item.isCut = true
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let advertised = advertisedTypes(of: writer)
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier),
                       "剪切项不得广告 public.file-url（否则 Finder 直读路径绕过交付确认）：\(advertised)")
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes
        XCTAssertTrue(advertised.contains { promiseTypes.contains($0) },
                      "剪切项必须保留 promise 类型（一切目的地必经 promise 写入）：\(advertised)")
        // fileURL 表示不产出数据（双重防线：未声明，且请求也返回 nil）。
        XCTAssertNil(writer.pasteboardPropertyList(forType: .fileURL))
    }

    func testCutImageItem_noTiffFallbackEither() throws {
        var item = ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png")
        item.isCut = true
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(for: item, bookmarkService: bookmarkService))

        let advertised = advertisedTypes(of: writer)
        XCTAssertFalse(advertised.contains(UTType.fileURL.identifier))
        XCTAssertFalse(advertised.contains(UTType.tiff.identifier),
                       "剪切图片项不挂 tiff 位图回退（位图目标无法确认交付）")
        XCTAssertTrue(advertised.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0) })
    }

    /// 交付确认挂接：剪切项 writer 的 promise 写入完成后经 sink 上报 item id。
    func testCutItem_deliverySink_reportsItemID() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let managedSource = directory.appendingPathComponent("cut.txt")
        try "cut content".write(to: managedSource, atomically: true, encoding: .utf8)
        var item = ShelfItem(kind: .file, path: managedSource.path, displayName: "cut.txt")
        item.isCut = true

        let deliveredID = Mutex<UUID?>(nil)
        let deliveredURL = Mutex<URL?>(nil)
        let sink = CutDeliverySink(
            delivered: { id, url in
                deliveredID.withLock { $0 = id }
                deliveredURL.withLock { $0 = url }
            },
            failed: { _ in XCTFail("写入应成功") }
        )
        let writer = try XCTUnwrap(DragPayloadBuilder.makePasteboardWriter(
            for: item, bookmarkService: bookmarkService, cutDelivery: sink))
        let provider = try XCTUnwrap(writer as? FilePromiseProvider)
        let destination = directory.appendingPathComponent("delivered/cut.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let completionError = Mutex<Error??>(nil)
        provider.delegate?.filePromiseProvider(provider, writePromiseTo: destination) { error in
            completionError.withLock { $0 = error }
        }

        XCTAssertNil(try XCTUnwrap(completionError.withLock { $0 }))
        XCTAssertEqual(deliveredID.withLock { $0 }, item.id)
        XCTAssertEqual(deliveredURL.withLock { $0 }, destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "cut content")
    }

    // MARK: - 无法构造的项目

    func testInvalidItems_returnNilWriter() {
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .text, displayName: "empty"), // 无 text
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .url, displayName: "no url"), // 无 urlString
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .url, displayName: "bad", urlString: "ht tp://bad url"), // 非法 URL
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: ShelfItem(kind: .file, displayName: "ghost"), // 无 path
            bookmarkService: bookmarkService))
        XCTAssertNil(DragPayloadBuilder.makePasteboardWriter(
            for: makeItem(kind: .stack), // stack 未展开
            bookmarkService: bookmarkService))
    }

    // MARK: - NSDraggingItem 组装（多选 / stack）

    func testMakeDraggingItems_multiSelection_producesOnePerItem() {
        let items = [
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .text, displayName: "b", text: "b"),
            ShelfItem(kind: .url, displayName: "c", urlString: "https://c.example.com"),
        ]
        let frame = NSRect(x: 0, y: 0, width: 88, height: 100)

        let draggingItems = DragPayloadBuilder.makeDraggingItems(for: items, frame: frame, bookmarkService: bookmarkService)

        XCTAssertEqual(draggingItems.count, 3)
        for draggingItem in draggingItems {
            XCTAssertEqual(draggingItem.draggingFrame, frame)
        }
    }

    func testMakeDraggingItems_stackExpandsToChildren() {
        let stack = ShelfItem(kind: .stack, displayName: "s", children: [
            ShelfItem(kind: .image, path: "/tmp/pic.png", displayName: "pic.png"),
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .url, displayName: "c", urlString: "https://c.example.com"),
        ])

        let draggingItems = DragPayloadBuilder.makeDraggingItems(
            for: [stack], frame: NSRect(x: 0, y: 0, width: 88, height: 100), bookmarkService: bookmarkService)

        XCTAssertEqual(draggingItems.count, 3, "stack 拖出 = 其全部子项")
    }

    func testMakeDraggingItems_skipsUnbuildableItems() {
        let items = [
            ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt"),
            ShelfItem(kind: .text, displayName: "empty"), // 无 text → nil writer
        ]
        let draggingItems = DragPayloadBuilder.makeDraggingItems(
            for: items, frame: NSRect(x: 0, y: 0, width: 88, height: 100), bookmarkService: bookmarkService)
        XCTAssertEqual(draggingItems.count, 1)
    }
}
