import Foundation
import OSLog

/// 一条「最近拖出」记录：item 摘要 + 时间。
struct RecentEntry: Codable, Equatable, Identifiable, Sendable {
    /// 每条记录独立 id（同一 ShelfItem 可反复拖出，不能复用 item.id）。
    var id: UUID
    var displayName: String
    var kind: ItemKind
    /// 文件类项目的最后已知路径（S10 菜单可据此「在 Finder 显示」/重新入架）。
    var path: String?
    var urlString: String?
    /// 文本项目摘要（前 100 字符）。
    var textPreview: String?
    var draggedOutAt: Date

    init(item: ShelfItem, draggedOutAt: Date, id: UUID = UUID()) {
        self.id = id
        self.displayName = item.displayName
        self.kind = item.kind
        self.path = item.path
        self.urlString = item.urlString
        self.textPreview = item.text.map { String($0.prefix(100)) }
        self.draggedOutAt = draggedOutAt
    }
}

/// 轻量最近拖出历史（实施计划 §2.2 `RecentItemsService`）：内存数组 + JSON
/// 持久化（`Application Support/OpenYoink/recents.json`，与 shelf.json 并列的
/// 独立文件），上限 20 条，最新在前。
///
/// 写盘沿用 PersistenceController 的原子写思路（临时文件 + rename），但不做
/// 防抖 —— 拖出是低频事件，同步写一个小 JSON 足够。损坏的文件只记日志、
/// 回退为空历史，绝不崩溃。菜单栏「最近项目」接入在 S10；本步只提供 API。
@MainActor
@Observable
final class RecentItemsService {
    /// 历史上限（条）。
    static let maxEntryCount = 20

    /// 当前历史，最新在前。
    private(set) var entries: [RecentEntry] = []

    /// 存储目录；测试中注入临时目录。
    let directoryURL: URL

    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "RecentItems")

    private var fileURL: URL {
        directoryURL.appendingPathComponent("recents.json")
    }

    private static let currentSchemaVersion = 1

    /// 与 PersistenceController 相同的日期格式（ISO8601 带毫秒，文件可读）。
    /// 非隔离：编码/解码闭包在非隔离上下文执行。
    private nonisolated static func makeDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeDateFormatter().string(from: date))
        }
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = makeDateFormatter().date(from: string)
                ?? ISO8601DateFormatter().date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(string)"
            )
        }
        return decoder
    }()

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? AppDirectories.applicationSupport()
        self.entries = loadEntries()
    }

    // MARK: - Recording

    /// 记录一批拖出的项目（本批次插到最前，批内保持拖拽顺序），裁剪到上限
    /// 并立即落盘。空输入忽略。
    func record(_ items: [ShelfItem], at date: Date = Date()) {
        guard !items.isEmpty else { return }
        entries.insert(contentsOf: items.map { RecentEntry(item: $0, draggedOutAt: date) }, at: 0)
        if entries.count > Self.maxEntryCount {
            entries.removeLast(entries.count - Self.maxEntryCount)
        }
        saveToDiskOrLog()
    }

    /// 清空历史（S10 菜单预留）。
    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        saveToDiskOrLog()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable, Sendable {
        var schemaVersion: Int
        var entries: [RecentEntry]
    }

    /// 启动时读取；文件缺失或损坏回退为空历史（记日志，不抛出）。
    private func loadEntries() -> [RecentEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            if snapshot.schemaVersion > Self.currentSchemaVersion {
                logger.warning("recents.json schema v\(snapshot.schemaVersion) is newer than supported v\(Self.currentSchemaVersion); decoding best-effort")
            }
            return snapshot.entries
        } catch {
            logger.error("Failed to load \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func saveToDiskOrLog() {
        do {
            try writeToDisk()
        } catch {
            logger.error("Failed to save \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 原子写：编码到同目录临时文件，再 rename 覆盖目标（思路与
    /// PersistenceController 一致，独立文件不做防抖）。
    private func writeToDisk() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let snapshot = Snapshot(schemaVersion: Self.currentSchemaVersion, entries: entries)
        let data = try encoder.encode(snapshot)
        let temporaryURL = directoryURL.appendingPathComponent("recents.json.tmp")
        try data.write(to: temporaryURL)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: fileURL)
    }
}
