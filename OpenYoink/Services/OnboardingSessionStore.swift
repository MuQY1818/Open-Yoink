import Foundation

/// 快速上手练习的独立、可恢复状态。这里只保存随机令牌、阶段和练习卡 id；
/// 文件路径始终由 `Tutorial/<session-id>/` 推导，永不信任磁盘 JSON 提供路径。
final class OnboardingSessionStore {
    struct Record: Codable, Equatable, Sendable {
        enum Phase: String, Codable, Sendable {
            case awaitingImport
            case awaitingExport
        }

        var sessionID: UUID
        var token: String
        var phase: Phase
        var tutorialItemID: UUID?
        var createdAt: Date
    }

    enum StoreError: Error, Equatable {
        case invalidSessionDirectory
    }

    static let tutorialFileName = "OpenYoink 练习文件.txt"

    let rootURL: URL
    private let fileManager: FileManager

    private var recordURL: URL { rootURL.appendingPathComponent("tutorial-session.json") }

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.rootURL = rootURL
            ?? AppDirectories.applicationSupport().appendingPathComponent("Tutorial", isDirectory: true)
        self.fileManager = fileManager
    }

    func begin() throws -> Record {
        try discardAll()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let record = Record(sessionID: UUID(),
                            token: UUID().uuidString,
                            phase: .awaitingImport,
                            tutorialItemID: nil,
                            createdAt: Date())
        let directory = try sessionDirectory(for: record.sessionID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        let contents = String(localized: "This practice file was created by OpenYoink. You can delete it safely.")
        try Data(contents.utf8).write(to: tutorialFileURL(for: record), options: .atomic)
        try save(record)
        return record
    }

    /// 返回结构和路径均有效的未完成 session。损坏记录只返回 nil；调用方可
    /// 用 `discardAll()` 清掉完全位于 Tutorial 根目录内的残留后重新开始。
    func load() -> Record? {
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              !record.token.isEmpty,
              (record.phase == .awaitingImport || record.tutorialItemID != nil),
              (try? sessionDirectory(for: record.sessionID)) != nil else {
            return nil
        }
        return record
    }

    func markAwaitingExport(_ record: Record, tutorialItemID: UUID) throws -> Record {
        var updated = record
        updated.phase = .awaitingExport
        updated.tutorialItemID = tutorialItemID
        try save(updated)
        return updated
    }

    func tutorialFileURL(for record: Record) -> URL {
        rootURL
            .appendingPathComponent(record.sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.tutorialFileName, isDirectory: false)
    }

    /// 删除单个 session。删除前严格验证目录是 Tutorial 根目录的 UUID 直属
    /// 子目录；任何外部路径都不会被接受。
    func discard(_ record: Record) throws {
        let directory = try sessionDirectory(for: record.sessionID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        if fileManager.fileExists(atPath: recordURL.path) {
            try fileManager.removeItem(at: recordURL)
        }
    }

    /// 清理全部教程残留。目标是构造时固定的 Tutorial 根目录本身，不从
    /// 持久化数据读取，因此不会扩大到 Application Support 或用户目录。
    func discardAll() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
    }

    func isTutorialFile(_ url: URL, for record: Record) -> Bool {
        url.standardizedFileURL == tutorialFileURL(for: record).standardizedFileURL
    }

    private func save(_ record: Record) throws {
        _ = try sessionDirectory(for: record.sessionID)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    private func sessionDirectory(for sessionID: UUID) throws -> URL {
        let root = rootURL.standardizedFileURL
        let directory = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .standardizedFileURL
        guard directory.deletingLastPathComponent() == root,
              UUID(uuidString: directory.lastPathComponent) == sessionID else {
            throw StoreError.invalidSessionDirectory
        }
        return directory
    }
}
