import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import OpenYoink

/// PasteboardTypes 能力探测与优先级（纯函数，不构造 pasteboard 实例）。
final class PasteboardTypesTests: XCTestCase {
    // MARK: - Category detection

    func testSupports_fileURL() {
        XCTAssertTrue(PasteboardTypes.supports(.fileURL, types: [.fileURL]))
        XCTAssertFalse(PasteboardTypes.supports(.fileURL, types: [.string]))
    }

    func testSupports_textCoversPlainHTMLRTF() {
        for type in [PasteboardTypes.plainText, .html, .rtf] {
            XCTAssertTrue(PasteboardTypes.supports(.text, types: [type]), "\(type.rawValue) should count as text")
        }
        XCTAssertFalse(PasteboardTypes.supports(.text, types: [.png]))
    }

    func testSupports_imageCoversPNGTIFFGeneric() {
        for type in PasteboardTypes.imageTypes {
            XCTAssertTrue(PasteboardTypes.supports(.image, types: [type]), "\(type.rawValue) should count as image")
        }
    }

    func testSupports_url() {
        XCTAssertTrue(PasteboardTypes.supports(.url, types: [PasteboardTypes.url]))
        XCTAssertFalse(PasteboardTypes.supports(.url, types: [.string]))
    }

    func testSupports_filePromise() {
        XCTAssertFalse(PasteboardTypes.filePromiseTypes.isEmpty)
        XCTAssertTrue(PasteboardTypes.supports(.filePromise, types: PasteboardTypes.filePromiseTypes))
        XCTAssertFalse(PasteboardTypes.supports(.filePromise, types: [.fileURL]))
    }

    // MARK: - Priority (F-03: promise → fileURL → image → url → text)

    func testPreferredCategory_promiseBeatsEverything() {
        let types = PasteboardTypes.filePromiseTypes + [.fileURL, .png, PasteboardTypes.url, .string]
        XCTAssertEqual(PasteboardTypes.preferredCategory(in: types), .filePromise)
    }

    /// 文本与 fileURL 同时存在时按顺序取 fileURL。
    func testPreferredCategory_fileURLBeatsText() {
        XCTAssertEqual(PasteboardTypes.preferredCategory(in: [.string, .fileURL]), .fileURL)
    }

    func testPreferredCategory_imageBeatsURLAndText() {
        XCTAssertEqual(PasteboardTypes.preferredCategory(in: [.string, PasteboardTypes.url, .tiff]), .image)
    }

    func testPreferredCategory_urlBeatsText() {
        XCTAssertEqual(PasteboardTypes.preferredCategory(in: [.string, PasteboardTypes.url]), .url)
    }

    func testPreferredCategory_textIsLastResort() {
        XCTAssertEqual(PasteboardTypes.preferredCategory(in: [.html, .rtf]), .text)
    }

    func testPreferredCategory_emptyOrUnknownTypes_returnsNil() {
        XCTAssertNil(PasteboardTypes.preferredCategory(in: []))
        XCTAssertNil(PasteboardTypes.preferredCategory(in: [NSPasteboard.PasteboardType("com.example.unknown")]))
    }

    // MARK: - Image type preference

    func testPreferredImageType_prefersPNGOverTIFF() {
        XCTAssertEqual(PasteboardTypes.preferredImageType(in: [.tiff, .png]), .png)
        XCTAssertEqual(PasteboardTypes.preferredImageType(in: [.tiff]), .tiff)
        XCTAssertNil(PasteboardTypes.preferredImageType(in: [.string]))
    }

    // MARK: - Registration set

    func testDragInTypes_coversAllCategories() {
        let registered = PasteboardTypes.dragInTypes
        for category in PasteboardTypes.Category.allCases {
            XCTAssertTrue(PasteboardTypes.supports(category, types: registered),
                          "dragInTypes should register \(category)")
        }
    }

    // MARK: - 任务一：宽兜底注册与「Drop everything」判定

    /// 注册清单放宽：URL 变体 + 无 conformance 的具体类型 + 泛型兜底全部在列。
    func testDragInTypes_includesWideNetFallbacks() {
        let registered = PasteboardTypes.dragInTypes
        for type in [PasteboardTypes.text, PasteboardTypes.uriList, PasteboardTypes.vCard,
                     PasteboardTypes.calendarEvent, PasteboardTypes.emailMessage,
                     PasteboardTypes.data, PasteboardTypes.item, PasteboardTypes.content,
                     PasteboardTypes.fileContents] {
            XCTAssertTrue(registered.contains(type), "dragInTypes should register \(type.rawValue)")
        }
    }

    /// 「Drop everything」高亮语义：声明任意类型即接受；零类型才拒绝。
    func testHasImportableContent_acceptsAnythingWithDeclaredTypes() {
        XCTAssertFalse(PasteboardTypes.hasImportableContent(in: []))
        XCTAssertTrue(PasteboardTypes.hasImportableContent(in: [.string]))
        XCTAssertTrue(PasteboardTypes.hasImportableContent(in: [PasteboardTypes.uriList]))
        XCTAssertTrue(PasteboardTypes.hasImportableContent(
            in: [NSPasteboard.PasteboardType("com.example.unknown")]))
    }

    // MARK: - 任务一：通用物化候选挑选（纯函数）

    /// 主链/专门分支已处理的类型不进入候选。
    func testMaterializationCandidates_excludesHandledElsewhereTypes() {
        let handled: [NSPasteboard.PasteboardType] =
            [.fileURL, PasteboardTypes.url, .string, PasteboardTypes.html, PasteboardTypes.rtf]
            + [PasteboardTypes.uriList] + PasteboardTypes.filePromiseTypes
        XCTAssertTrue(PasteboardTypes.materializationCandidates(in: handled).isEmpty)
    }

    /// tier 归属：带扩展名的具体 UTI → 1；无扩展名的具体 UTI → 2；
    /// 未声明标识 / 泛型信号类型 → 3。
    func testMaterializationCandidates_tierAssignment() {
        XCTAssertEqual(PasteboardTypes.materializationCandidates(in: [PasteboardTypes.vCard]),
                       [.init(type: PasteboardTypes.vCard, tier: 1)])
        XCTAssertEqual(PasteboardTypes.materializationCandidates(in: [PasteboardTypes.calendarEvent]),
                       [.init(type: PasteboardTypes.calendarEvent, tier: 2)])
        XCTAssertEqual(PasteboardTypes.materializationCandidates(in: [PasteboardTypes.emailMessage]),
                       [.init(type: PasteboardTypes.emailMessage, tier: 2)])
        let unknown = NSPasteboard.PasteboardType("com.openyoink.test.undeclared")
        XCTAssertEqual(PasteboardTypes.materializationCandidates(in: [unknown]),
                       [.init(type: unknown, tier: 3)])
        XCTAssertEqual(PasteboardTypes.materializationCandidates(in: [PasteboardTypes.data]),
                       [.init(type: PasteboardTypes.data, tier: 3)])
    }

    /// 排序：tier1 优先，同梯队保持声明顺序；文本族（conforms to .text 且无
    /// 扩展名）不入选 —— 交给字符串兜底分支。
    func testMaterializationCandidates_orderingAndTextExclusion() {
        let unknown = NSPasteboard.PasteboardType("com.openyoink.test.undeclared")
        let utf16 = NSPasteboard.PasteboardType("public.utf16-plain-text")
        let candidates = PasteboardTypes.materializationCandidates(
            in: [unknown, PasteboardTypes.calendarEvent, PasteboardTypes.vCard, utf16])
        XCTAssertEqual(candidates, [.init(type: PasteboardTypes.vCard, tier: 1),
                                    .init(type: PasteboardTypes.calendarEvent, tier: 2),
                                    .init(type: unknown, tier: 3)])
    }

    // MARK: - 任务一：物化扩展名与显示名

    func testMaterializationFileExtension_preferredThenKnownTableThenDat() {
        XCTAssertEqual(PasteboardTypes.materializationFileExtension(for: PasteboardTypes.vCard), "vcf")
        XCTAssertEqual(PasteboardTypes.materializationFileExtension(for: PasteboardTypes.calendarEvent), "ics")
        XCTAssertEqual(PasteboardTypes.materializationFileExtension(for: PasteboardTypes.emailMessage), "eml")
        let unknown = NSPasteboard.PasteboardType("com.openyoink.test.undeclared")
        XCTAssertEqual(PasteboardTypes.materializationFileExtension(for: unknown), "dat")
    }

    func testMaterializedDisplayBaseName_typeDescriptionOrLocalizedFallback() {
        XCTAssertEqual(PasteboardTypes.materializedDisplayBaseName(for: PasteboardTypes.vCard),
                       UTType.vCard.localizedDescription)
        let unknown = NSPasteboard.PasteboardType("com.openyoink.test.undeclared")
        XCTAssertEqual(PasteboardTypes.materializedDisplayBaseName(for: unknown),
                       String(localized: "Dropped Item"))
    }
}
