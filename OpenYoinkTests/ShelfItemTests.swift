import XCTest
@testable import OpenYoink

final class ShelfItemTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testCodableRoundTrip_fullItem() throws {
        let item = ShelfItem(
            id: UUID(),
            kind: .image,
            path: "/tmp/photo.png",
            bookmark: Data([0x01, 0x02, 0x03]),
            displayName: "photo.png",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceApp: SourceAppInfo(bundleID: "com.apple.finder", name: "Finder")
        )

        let decoded = try decoder.decode(ShelfItem.self, from: encoder.encode(item))

        XCTAssertEqual(decoded, item)
    }

    func testCodableRoundTrip_nestedStack() throws {
        let fileChild = ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt")
        let textChild = ShelfItem(kind: .text, displayName: "note", text: "hello")
        let innerStack = ShelfItem(kind: .stack, displayName: "a.txt", children: [fileChild, textChild])
        let outer = ShelfItem(kind: .stack, displayName: "a.txt", children: [innerStack, fileChild])

        let decoded = try decoder.decode(ShelfItem.self, from: encoder.encode(outer))

        XCTAssertEqual(decoded, outer)
        XCTAssertEqual(decoded.children?.count, 2)
        XCTAssertEqual(decoded.children?.first?.kind, .stack)
        XCTAssertEqual(decoded.children?.first?.children?.count, 2)
        XCTAssertEqual(decoded.children?.first?.children?.last?.text, "hello")
    }

    func testCodableRoundTrip_textAndURLItems() throws {
        let text = ShelfItem(kind: .text, displayName: "snippet", text: "some text")
        let link = ShelfItem(kind: .url, displayName: "apple.com", urlString: "https://apple.com")

        XCTAssertEqual(try decoder.decode(ShelfItem.self, from: encoder.encode(text)), text)
        XCTAssertEqual(try decoder.decode(ShelfItem.self, from: encoder.encode(link)), link)
    }

    /// F-05: isCut 持久化（顶层与 stack 子项递归）。
    func testCodableRoundTrip_isCut_persistsIncludingStackChildren() throws {
        let cutChild = ShelfItem(kind: .file, path: "/tmp/cut.txt", displayName: "cut.txt", isCut: true)
        let stack = ShelfItem(kind: .stack, displayName: "cut.txt", children: [cutChild])
        let topLevel = ShelfItem(kind: .folder, path: "/tmp/cutdir", displayName: "cutdir", isCut: true)

        let decodedStack = try decoder.decode(ShelfItem.self, from: encoder.encode(stack))
        XCTAssertEqual(decodedStack, stack)
        XCTAssertEqual(decodedStack.children?.first?.isCut, true)
        XCTAssertEqual(try decoder.decode(ShelfItem.self, from: encoder.encode(topLevel)), topLevel)
    }

    /// Backward compatibility: a persisted item missing every optional field
    /// (as written by an older app version) must still decode.
    func testDecoding_missingOptionalFields_usesDefaults() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "kind": "file",
            "displayName": "report.pdf",
            "addedAt": 1700000000
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        let item = try decoder.decode(ShelfItem.self, from: data)

        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.displayName, "report.pdf")
        XCTAssertNil(item.path)
        XCTAssertNil(item.bookmark)
        XCTAssertNil(item.sourceApp)
        XCTAssertNil(item.text)
        XCTAssertNil(item.urlString)
        XCTAssertNil(item.children)
        XCTAssertFalse(item.isStale)
        XCTAssertFalse(item.isCut, "旧版 JSON 无 isCut 字段，解码应为 false（F-05 向后兼容）")
    }

    /// `isStale` is runtime-only and must never be written to disk.
    func testEncoding_excludesRuntimeOnlyIsStale() throws {
        var item = ShelfItem(kind: .file, path: "/tmp/gone.txt", displayName: "gone.txt")
        item.isStale = true

        let data = try encoder.encode(item)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(object["isStale"])
        let decoded = try decoder.decode(ShelfItem.self, from: data)
        XCTAssertFalse(decoded.isStale)
    }

    /// Raw values are persisted in shelf.json and must stay stable.
    func testItemKindRawValues_areStable() {
        XCTAssertEqual(ItemKind.file.rawValue, "file")
        XCTAssertEqual(ItemKind.folder.rawValue, "folder")
        XCTAssertEqual(ItemKind.text.rawValue, "text")
        XCTAssertEqual(ItemKind.image.rawValue, "image")
        XCTAssertEqual(ItemKind.url.rawValue, "url")
        XCTAssertEqual(ItemKind.stack.rawValue, "stack")
        XCTAssertEqual(ItemKind.allCases.count, 6)
    }

    func testFileURL_isDerivedFromPath() {
        let fileItem = ShelfItem(kind: .file, path: "/tmp/a.txt", displayName: "a.txt")
        XCTAssertEqual(fileItem.fileURL, URL(fileURLWithPath: "/tmp/a.txt"))

        let textItem = ShelfItem(kind: .text, displayName: "note", text: "hi")
        XCTAssertNil(textItem.fileURL)
    }
}
