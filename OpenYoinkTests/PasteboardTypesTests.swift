import AppKit
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
}
