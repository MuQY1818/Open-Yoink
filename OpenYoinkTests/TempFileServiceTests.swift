import Foundation
import XCTest
@testable import OpenYoink

/// TempFileService 的按龄 staging 清理（评审 P1：promise 共享 staging 不在
/// 回调中清理，由启动时按龄兜底）。
final class TempFileServiceTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenYoinkTests-TFS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 旧的 PromiseStaging 目录被删除，新建的与无关条目保留。
    func testCleanupStaleStagingDirectories_removesOnlyOldStaging() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let fileManager = FileManager.default

        let oldStaging = try service.createPromiseStagingDirectory()
        let newStaging = try service.createPromiseStagingDirectory()
        let materializedFile = directory.appendingPathComponent("\(UUID().uuidString)-photo.png")
        try "x".write(to: materializedFile, atomically: true, encoding: .utf8)
        // 把 oldStaging 的修改时间拨到两小时前。
        let twoHoursAgo = Date().addingTimeInterval(-7200)
        try fileManager.setAttributes([.modificationDate: twoHoursAgo], ofItemAtPath: oldStaging.path)

        service.cleanupStaleStagingDirectories(maxAge: 3600)

        XCTAssertFalse(fileManager.fileExists(atPath: oldStaging.path), "超龄 staging 应被清理")
        XCTAssertTrue(fileManager.fileExists(atPath: newStaging.path), "新 staging 必须保留")
        XCTAssertTrue(fileManager.fileExists(atPath: materializedFile.path), "非 staging 条目不受影响")
    }

    /// 清理的删除范围不越出托管目录语义：非 PromiseStaging 前缀的目录一律不动。
    func testCleanupStaleStagingDirectories_ignoresNonStagingDirectories() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let other = directory.appendingPathComponent("SomeOtherDir", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: other.path)

        service.cleanupStaleStagingDirectories(maxAge: 3600)

        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testCreatePromiseStagingDirectory_usesCleanupCompatibleName() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)

        let staging = try service.createPromiseStagingDirectory()
        var isDirectory: ObjCBool = false

        XCTAssertTrue(staging.lastPathComponent.hasPrefix("PromiseStaging-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// 常规 orphan 清理必须跳过仍可能有异步写入的 staging；过期回收只由
    /// cleanupStaleStagingDirectories 负责。
    func testCleanupOrphans_preservesPromiseStaging_butRemovesOrdinaryOrphan() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let staging = try service.createPromiseStagingDirectory()
        let orphan = try service.uniqueFileURL(suggestedName: "orphan.txt")
        try "x".write(to: orphan, atomically: true, encoding: .utf8)

        service.cleanupOrphans()

        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testCleanupOrphans_reportsRemovedItemsAndPreservesReferencedFile() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TempFileService(directoryURL: directory)
        let kept = try service.uniqueFileURL(suggestedName: "kept.bin")
        let orphan = try service.uniqueFileURL(suggestedName: "orphan.bin")
        try Data(repeating: 1, count: 4_096).write(to: kept)
        try Data(repeating: 2, count: 8_192).write(to: orphan)

        XCTAssertGreaterThan(service.storageUsage(), 0)
        let result = service.cleanupOrphans(keepingPaths: [kept.path])

        XCTAssertEqual(result.removedItemCount, 1)
        XCTAssertGreaterThan(result.reclaimedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
}
