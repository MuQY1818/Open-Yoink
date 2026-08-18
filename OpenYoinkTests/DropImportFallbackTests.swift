import AppKit
import XCTest
@testable import OpenYoink

/// 任务一「万能拖入」兜底链单测：主链（promise→fileURL→image→url→text）全部
/// 零产出时，逐 pasteboard item 走 a(uri-list)→b(仅 HTML/RTF)→c(通用数据物化)
/// →d(字符串兜底) 分支；全部失败 → notice 提示 + 不接收拖放。
///
/// 说明（与 prompt 的出入）：「多 item 混合」用两个兜底相关 item（vCard +
/// 未知二进制）验证逐 item 独立处理；fileURL+text 混合由既有断言
/// `testImport_fileURLAndText_fileURLWins` 锁定为「主链整板优先」，不能改。
@MainActor
final class DropImportFallbackTests: XCTestCase {
    /// 与 DropImportCoordinatorTests 相同的 fixtures 模式：就地构造、defer 清理。
    @MainActor
    private struct Context {
        let bookmarkService = BookmarkService()
        let tempFileService: TempFileService
        let noticeCenter = ShelfNoticeModel()
        let coordinator: DropImportCoordinator
        var temporaryURLs: [URL] = []

        init() {
            let materializedDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("OpenYoinkTests-Materialized-\(UUID().uuidString)", isDirectory: true)
            tempFileService = TempFileService(directoryURL: materializedDir)
            coordinator = DropImportCoordinator(bookmarkService: bookmarkService,
                                                tempFileService: tempFileService,
                                                noticeCenter: noticeCenter)
            temporaryURLs.append(materializedDir)
        }

        func cleanup() {
            bookmarkService.stopAccessingAll()
            for url in temporaryURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func makeContext() -> Context { Context() }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
    }

    private func T(_ raw: String) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(raw)
    }

    private func ignoringAsyncItems() -> @MainActor (ShelfItem) -> Void {
        { _ in XCTFail("no async materialization expected for this pasteboard") }
    }

    // MARK: - 分支 b：仅 HTML / 仅 RTF

    /// 仅 HTML（无 plain text —— 主链文本阶段读不到）：物化为 .html 文件项，
    /// displayName 用 NSAttributedString 提取的纯文本首行，落盘内容即原文。
    func testFallback_htmlOnlyDrop_materializesHTMLFileItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let html = Data("<p>Hello <b>HTML</b></p><p>second</p>".utf8)
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.html], owner: nil)
        pasteboard.setData(html, forType: PasteboardTypes.html)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(result.pendingMaterializations, 0)
        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.displayName, "Hello HTML.html")
        XCTAssertNotNil(item.bookmark)
        let path = try XCTUnwrap(item.path)
        XCTAssertTrue(path.hasPrefix(context.tempFileService.directoryURL.path))
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "html")
        // 落盘原文不变 —— 拖出到 Pages/浏览器仍是富文本。
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), html)
    }

    /// 仅 RTF 且系统桥接的 plain-text 转换不可用（探针：有效 RTF 会被
    /// pasteboard 自动桥接出 utf8/utf16 plain-text flavor，由主链文本阶段
    /// 产出文本项 —— 那是既有行为；本用例覆盖桥接失败时的 b 分支）：
    /// 物化为 .rtf 文件项，提取不出纯文本时用本地化兜底名。
    func testFallback_rtfWithoutPlainTextBridge_materializesRTFFileItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let rtf = Data("not really rtf".utf8) // 无效 RTF：桥接转换读取时失败（探针实测）
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.rtf], owner: nil)
        pasteboard.setData(rtf, forType: PasteboardTypes.rtf)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.displayName, String(localized: "Dropped RTF") + ".rtf")
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "rtf")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), rtf)
    }

    /// HTML 提取不出纯文本（纯标签/图片）时回退本地化兜底名。
    func testFallback_htmlWithoutExtractableText_usesLocalizedFallbackName() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.html], owner: nil)
        pasteboard.setData(Data(#"<img src="x.png">"#.utf8), forType: PasteboardTypes.html)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.displayName, String(localized: "Dropped HTML") + ".html")
    }

    // MARK: - 分支 a：text/uri-list

    /// uri-list（pasteboard 级 flavor；# 注释行与空行跳过，每行一个 URL 项）。
    /// 附带验证去重：item 级的 dyn.* 桥接投影不会再经 d 分支产出重复的文本项。
    func testFallback_uriList_producesURLItemPerLine() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.uriList], owner: nil)
        pasteboard.setString("https://a.com/\r\n# a comment\r\n\r\nhttps://b.com/path",
                             forType: PasteboardTypes.uriList)

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertEqual(result.pendingMaterializations, 0)
        XCTAssertEqual(result.items.map(\.urlString), ["https://a.com/", "https://b.com/path"])
        XCTAssertEqual(result.items.map(\.kind), [.url, .url])
        XCTAssertEqual(result.items.map(\.displayName), ["a.com", "b.com"])
    }

    // MARK: - 分支 c：通用数据物化

    /// vCard 数据：tier1（带 preferredFilenameExtension 的具体 UTI）→ .vcf 文件项。
    func testFallback_vCardData_materializesVCFFileItem() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let vcf = Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Test Person\r\nEND:VCARD\r\n".utf8)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(vcf, forType: T("public.vcard"))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([pasteboardItem])

        let itemReady = expectation(description: "vCard materialized")
        var received: ShelfItem?
        let result = context.coordinator.importItems(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }

        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.pendingMaterializations, 1)
        await fulfillment(of: [itemReady], timeout: 5)

        let item = try XCTUnwrap(received)
        XCTAssertEqual(item.kind, .file)
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "vcf")
        XCTAssertTrue(item.displayName.hasSuffix(".vcf"))
        XCTAssertNotNil(item.bookmark)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), vcf)
    }

    /// 未声明的自定义类型（UTType 解析为 nil）→ tier3，物化为 .dat，内容保留。
    /// payload 含 NUL/控制字节：保证即使 `string(forType:)` 做有损解码也
    /// 通不过 `isMeaningfulText` 门槛（探针：纯可打印字节会被解码成字符串）。
    func testFallback_unknownBinaryData_materializesDatFileItem() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let blob = Data([0x00, 0xFF, 0x01, 0xFE])
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([T("com.openyoink.test.unknown-blob")], owner: nil)
        pasteboard.setData(blob, forType: T("com.openyoink.test.unknown-blob"))

        let itemReady = expectation(description: "blob materialized")
        var received: ShelfItem?
        let result = context.coordinator.importItems(from: pasteboard) { item in
            received = item
            itemReady.fulfill()
        }

        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.pendingMaterializations, 1)
        await fulfillment(of: [itemReady], timeout: 5)

        let item = try XCTUnwrap(received)
        XCTAssertEqual(item.kind, .file)
        let path = try XCTUnwrap(item.path)
        XCTAssertEqual(URL(fileURLWithPath: path).pathExtension, "dat")
        XCTAssertEqual(item.displayName, String(localized: "Dropped Item") + ".dat")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), blob)
    }

    // MARK: - 混合多 item（兜底链内逐 item 独立处理）

    /// 一个 vCard item + 一个未知二进制 item：各走 c 分支独立物化，互不影响。
    func testFallback_mixedFallbackItems_eachMaterializesIndependently() async throws {
        let context = makeContext()
        defer { context.cleanup() }
        let vcfItem = NSPasteboardItem()
        vcfItem.setData(Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:A\r\nEND:VCARD\r\n".utf8),
                        forType: T("public.vcard"))
        let blobItem = NSPasteboardItem()
        blobItem.setData(Data([0x00, 0x01, 0x02, 0x03]), forType: T("com.openyoink.test.unknown-blob"))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([vcfItem, blobItem])

        let allReady = expectation(description: "both materialized")
        allReady.expectedFulfillmentCount = 2
        var extensions: [String] = []
        let result = context.coordinator.importItems(from: pasteboard) { item in
            if let path = item.path {
                extensions.append(URL(fileURLWithPath: path).pathExtension)
            }
            allReady.fulfill()
        }

        XCTAssertEqual(result.items, [])
        XCTAssertEqual(result.pendingMaterializations, 2)
        await fulfillment(of: [allReady], timeout: 5)
        XCTAssertEqual(Set(extensions), ["vcf", "dat"])
    }

    // MARK: - 分支 d：字符串兜底

    /// item 声明了奇异的文本类类型（主链 .string 读不到）：d 分支按声明顺序
    /// 取首个能 string(forType:) 出非空内容的类型产出文本项。
    func testFallback_exoticStringType_producesTextItem() throws {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("exotic payload", forType: T("public.utf8-external-plain-text"))
        let pasteboard = makePasteboard()
        pasteboard.writeObjects([pasteboardItem])

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        let item = try XCTUnwrap(result.items.only)
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.text, "exotic payload")
        XCTAssertEqual(item.displayName, "exotic payload")
    }

    // MARK: - 分支 e：零内容

    /// 声明了类型但读不出任何内容：逐项日志（人工核查），整次零产出 →
    /// 不接收拖放 + notice 提示（双语键见 Localizable.xcstrings）。
    func testFallback_itemWithNoReadableContent_isUnhandled_andShowsNotice() {
        let context = makeContext()
        defer { context.cleanup() }
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([T("com.openyoink.test.void")], owner: nil)
        // 不写任何数据 —— 零内容 item。

        let result = context.coordinator.importItems(from: pasteboard, onAsyncItemReady: ignoringAsyncItems())

        XCTAssertFalse(result.handled)
        XCTAssertEqual(context.noticeCenter.message,
                       String(localized: "That content can't be added to the shelf yet."))
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
