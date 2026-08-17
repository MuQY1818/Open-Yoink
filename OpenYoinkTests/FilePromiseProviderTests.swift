import AppKit
import Synchronization
import XCTest
@testable import OpenYoink

/// FilePromiseProvider 的写入逻辑：用临时目录真实文件直接调 `writeCopy` 与
/// delegate 方法验证。真实拖拽会话链路（目标应用触发 writePromiseTo）列入
/// 手动回归清单（Finder / 浏览器上传测试页 / Mail）。
///
/// 测试类为 @MainActor（provider/AppKit 对象隔离一致），故不使用
/// setUp/tearDown（XCTestCase 的这两个 override 是非隔离的，访问 MainActor
/// 状态会产生告警）——每个用例就地构造 fixtures 并用 defer 清理；
/// `writeCopy` 本身是非隔离纯函数。
@MainActor
final class FilePromiseProviderTests: XCTestCase {
    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePayload(sourceURL: URL,
                             bookmark: Data? = nil,
                             suggestedName: String = "hello.txt",
                             promisedFileType: String = "public.plain-text") -> FilePromiseProvider.Payload {
        FilePromiseProvider.Payload(sourceURL: sourceURL,
                                    bookmark: bookmark,
                                    suggestedName: suggestedName,
                                    promisedFileType: promisedFileType)
    }

    // MARK: - writeCopy

    func testWriteCopy_copiesFileToDestination_andKeepsSource() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hello.txt")
        try "promise content".write(to: source, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("drop-target/hello.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        try FilePromiseProvider.writeCopy(of: makePayload(sourceURL: source),
                                          to: destination,
                                          bookmarkService: bookmarkService)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "promise content")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path),
                      "promise 落盘是 copy，源文件必须保留")
    }

    func testWriteCopy_withBookmark_resolvesAndCopies() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("bookmarked.txt")
        try "via bookmark".write(to: source, atomically: true, encoding: .utf8)
        let bookmark = try bookmarkService.createBookmark(for: source)
        let destination = directory.appendingPathComponent("out.txt")

        try FilePromiseProvider.writeCopy(of: makePayload(sourceURL: source, bookmark: bookmark),
                                          to: destination,
                                          bookmarkService: bookmarkService)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "via bookmark")
    }

    func testWriteCopy_folder_copiesRecursively() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceFolder = directory.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        try "nested".write(to: sourceFolder.appendingPathComponent("nested.txt"),
                           atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("docs-copy")

        try FilePromiseProvider.writeCopy(
            of: makePayload(sourceURL: sourceFolder,
                            suggestedName: "docs",
                            promisedFileType: "public.folder"),
            to: destination,
            bookmarkService: bookmarkService)

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("nested.txt"),
                                  encoding: .utf8), "nested")
    }

    func testWriteCopy_missingSource_throws() {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-\(UUID().uuidString)", isDirectory: true)
        let payload = makePayload(sourceURL: directory.appendingPathComponent("nonexistent.txt"))

        XCTAssertThrowsError(try FilePromiseProvider.writeCopy(
            of: payload,
            to: directory.appendingPathComponent("out.txt"),
            bookmarkService: bookmarkService))
    }

    // MARK: - Delegate

    func testDelegate_fileNameForType_returnsSuggestedName() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/hello.txt"),
                                 suggestedName: "报告 2026.txt"),
            bookmarkService: BookmarkService()
        )
        XCTAssertEqual(provider.delegate?.filePromiseProvider(provider, fileNameForType: "public.plain-text"),
                       "报告 2026.txt")
    }

    func testDelegate_operationQueue_isUserInitiated() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/hello.txt")),
            bookmarkService: BookmarkService()
        )
        let queue = provider.delegate?.operationQueue?(for: provider)
        XCTAssertEqual(queue?.qualityOfService, .userInitiated)
        XCTAssertFalse(queue === OperationQueue.main, "promise 写入不得在主队列")
    }

    func testDelegate_writePromiseTo_successReportsNilError() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hello.txt")
        try "delegate write".write(to: source, atomically: true, encoding: .utf8)
        let destination = directory.appendingPathComponent("out.txt")
        let provider = FilePromiseProvider(payload: makePayload(sourceURL: source),
                                           bookmarkService: bookmarkService)

        // delegate 方法的实现是同步写（真实会话中 AppKit 在写队列上调用它），
        // 测试中直接同步调用即可断言回调结果。
        let completionError = Mutex<Error??>(nil)
        provider.delegate?.filePromiseProvider(provider, writePromiseTo: destination) { error in
            completionError.withLock { $0 = error }
        }

        XCTAssertNil(try XCTUnwrap(completionError.withLock { $0 }))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "delegate write")
    }

    func testDelegate_writePromiseTo_failureReportsErrorWithoutCrashing() throws {
        let bookmarkService = BookmarkService()
        defer { bookmarkService.stopAccessingAll() }
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingSource = directory.appendingPathComponent("nonexistent.txt")
        let reportedError = Mutex<Error?>(nil)
        let completionError = Mutex<Error??>(nil)
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: missingSource),
            bookmarkService: bookmarkService,
            onError: { error in reportedError.withLock { $0 = error } }
        )

        provider.delegate?.filePromiseProvider(
            provider,
            writePromiseTo: directory.appendingPathComponent("out.txt")
        ) { error in
            completionError.withLock { $0 = error }
        }

        XCTAssertNotNil(try XCTUnwrap(completionError.withLock { $0 }),
                        "写失败必须把错误回传给接收应用")
        XCTAssertNotNil(reportedError.withLock { $0 },
                        "写失败必须上报 onError（预留 UI 订阅）")
    }

    // MARK: - 附加表示（fileURL / tiff）

    func testWritableTypes_fileURLFirstThenPromiseTypes() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/hello.txt")),
            bookmarkService: BookmarkService()
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OpenYoinkTests-\(UUID().uuidString)"))
        let types = provider.writableTypes(for: pasteboard)

        XCTAssertEqual(types.first, .fileURL, "fileURL 直接表示应在最前")
        XCTAssertTrue(types.contains { NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue) })
    }

    func testPasteboardPropertyList_fileURLServesAbsoluteString() {
        let provider = FilePromiseProvider(
            payload: makePayload(sourceURL: URL(fileURLWithPath: "/tmp/hello.txt")),
            bookmarkService: BookmarkService()
        )
        XCTAssertEqual(provider.pasteboardPropertyList(forType: .fileURL) as? String,
                       "file:///tmp/hello.txt")
    }
}
