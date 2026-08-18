import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import OpenYoink

/// 拖入兼容性 conformance 探针（任务一）—— 把设计 `dragInTypes` 注册清单时所
/// 依赖的系统行为固化为可重复执行的断言。这些行为此前只能查文档「想当然」，
/// 现以本机（macOS 26）实测为准：
///
/// 1. `availableType(from:)` **沿 UTI conformance 展开**（声明子类型可命中
///    注册的父类型），且包含可转换 flavor（png → tiff）。
/// 2. 非 UTI 的 legacy flavor（text/uri-list、NSFilenamesPboardType）被桥接为
///    dyn.* 动态类型后**可命中 public.data** —— 这是泛型注册能兜住它们的机理。
/// 3. 未声明的反向域名自定义标识（系统不知其 conformance）**无法**被任何
///    泛型类型命中 —— 宽注册的覆盖边界。
/// 4. `public.calendar-event` / `public.email-message` 的 conformance 不足以
///    挂进 data/item 树下，必须显式注册；且二者无 preferredFilenameExtension，
///    物化扩展名需兜底表（`PasteboardTypes.wellKnownExtensionFallback`）。
///
/// 注意：`registerForDraggedTypes` 的拖拽会话级匹配无法离开真实拖拽会话语法
/// 单测；本文件验证的是同一套 UTI conformance 在 pasteboard 侧的可观测行为。
final class PasteboardConformanceProbeTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("OpenYoinkProbeTests-\(UUID().uuidString)"))
    }

    private func T(_ raw: String) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(raw)
    }

    // MARK: - 1. availableType 沿 conformance 展开

    func testProbe_declaredPNG_matchesDataImageAndConvertibleTIFF() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(Data([0x89, 0x50]), forType: .png)

        XCTAssertNotNil(pasteboard.availableType(from: [T("public.data")]))
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.image")]))
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.item")]))
        // 可转换 flavor：声明 png 也能给出 tiff。
        XCTAssertNotNil(pasteboard.availableType(from: [.tiff]))
        // 不相关的族不命中。
        XCTAssertNil(pasteboard.availableType(from: [.string]))
    }

    func testProbe_declaredPlainText_matchesTextSupertypes() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("hello", forType: .string)

        XCTAssertNotNil(pasteboard.availableType(from: [T("public.text")]))
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.plain-text")]))
    }

    /// 展开是单向的：父类型声明不命中子类型查询。
    func testProbe_expansionIsDirectional_urlDoesNotMatchFileURL() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([T("public.url")], owner: nil)
        pasteboard.setString("https://example.com", forType: T("public.url"))

        XCTAssertNotNil(pasteboard.availableType(from: [T("public.item")]))
        XCTAssertNil(pasteboard.availableType(from: [.fileURL]))
    }

    // MARK: - 2. legacy flavor 的动态桥接

    func testProbe_uriListFlavor_bridgesToDynamicTypeMatchingData_andReadsAtPasteboardLevel() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.uriList], owner: nil)
        pasteboard.setString("https://example.com/", forType: PasteboardTypes.uriList)

        // 原始 flavor 字符串保留在 pasteboard 类型清单中。
        XCTAssertTrue(pasteboard.types?.contains(PasteboardTypes.uriList) ?? false)
        // 桥接出的 dyn.* 动态类型命中 public.data —— 泛型注册能兜住它的机理。
        XCTAssertNotNil(pasteboard.availableType(from: [T("public.data")]))
        // pasteboard 级按原始 flavor 读取正常（item 级读不到，见下）。
        XCTAssertEqual(pasteboard.string(forType: PasteboardTypes.uriList), "https://example.com/")
        // item 级只剩 dyn.* 桥接类型：按原始 flavor 读不到。
        let item = pasteboard.pasteboardItems?.first
        XCTAssertEqual(item?.string(forType: PasteboardTypes.uriList), nil)
    }

    // MARK: - 3. 覆盖边界：未声明的自定义标识不被泛型命中

    func testProbe_undeclaredReverseDNSIdentifier_matchesNothingGeneric() {
        let custom = T("com.openyoink.probe.undeclared-\(UUID().uuidString)")
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([custom], owner: nil)
        pasteboard.setData(Data([1, 2, 3]), forType: custom)

        XCTAssertNil(pasteboard.availableType(from: [T("public.data")]))
        XCTAssertNil(pasteboard.availableType(from: [T("public.item")]))
        XCTAssertNil(pasteboard.availableType(from: [T("public.content")]))
    }

    // MARK: - 4. 必须显式注册的类型与物化扩展名兜底的存在理由

    func testProbe_calendarEventAndEmailMessage_haveNoDataConformance() {
        // 若未来系统补全了它们的 conformance，泛型注册即可覆盖，
        // 显式注册变为冗余但无害 —— 届时可收紧本断言。
        XCTAssertFalse(UTType.calendarEvent.conforms(to: .data))
        XCTAssertFalse(UTType.calendarEvent.conforms(to: .item))
        XCTAssertFalse(UTType.emailMessage.conforms(to: .data))
    }

    func testProbe_materializationExtensionFacts() {
        XCTAssertEqual(UTType.vCard.preferredFilenameExtension, "vcf")
        // 无扩展名标签 —— `wellKnownExtensionFallback` 表的存在理由。
        XCTAssertNil(UTType.calendarEvent.preferredFilenameExtension)
        XCTAssertNil(UTType.emailMessage.preferredFilenameExtension)
        XCTAssertNotNil(UTType.vCard.localizedDescription)
    }

    /// `UTType(_:)` 对非 UTI 字符串与未声明标识都返回 nil —— 不能指望用
    /// UTType 对任意 pasteboard 类型字符串做 conformance 判定。
    func testProbe_uttypeInit_nilForNonUTIAndUndeclaredIdentifiers() {
        XCTAssertNil(UTType("text/uri-list"))
        XCTAssertNil(UTType("com.openyoink.probe.undeclared-\(UUID().uuidString)"))
        XCTAssertNil(UTType("NSFilenamesPboardType"))
        // 对照：已声明类型正常解析且 conformance 可查。
        XCTAssertTrue(UTType("com.adobe.pdf")?.conforms(to: .data) ?? false)
    }

    // MARK: - 5. 已知缺口的行为基础：html-only item 读不出 plain text

    func testProbe_htmlOnlyItem_hasNoPlainTextButReadableHTMLData() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([PasteboardTypes.html], owner: nil)
        pasteboard.setData(Data("<b>hi</b>".utf8), forType: PasteboardTypes.html)

        let item = pasteboard.pasteboardItems?.first
        XCTAssertNil(item?.string(forType: .string)) // 主链文本阶段读不到 → 兜底 b 分支的存在理由
        XCTAssertNotNil(item?.data(forType: PasteboardTypes.html))
    }
}
