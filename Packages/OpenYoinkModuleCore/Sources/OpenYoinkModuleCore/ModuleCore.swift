import Foundation

/// Stable, forward-compatible identifier for a first-party Island module.
///
/// A string-backed value lets newer OpenYoink versions round-trip module
/// configuration through an older build without losing unknown identifiers.
public struct IslandModuleID: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral, Comparable
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct IslandModuleDescriptor: Identifiable, Equatable, Sendable {
    public let id: IslandModuleID
    public let title: String
    public let systemImage: String
    public let order: Int
    public let isCore: Bool

    public init(id: IslandModuleID, title: String, systemImage: String,
                order: Int, isCore: Bool) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.order = order
        self.isCore = isCore
    }
}

public enum IslandModuleAvailability: Equatable, Codable, Sendable {
    case available
    case unavailable(reason: String)
    case degraded(reason: String)
}

public enum IslandActivityPriority: Int, Comparable, Codable, Sendable {
    case shelfSummary = 10
    case selectedModule = 20
    case nowPlaying = 25
    case powerChange = 30
    case systemWarning = 35
    case criticalBattery = 40
    case timerFinished = 50
    case transfer = 60
    case userDrag = 70

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct IslandActivity: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let moduleID: IslandModuleID
    public let priority: IslandActivityPriority
    public let title: String
    public let detail: String?
    public let systemImage: String
    public let expiresAt: Date?

    public init(id: String, moduleID: IslandModuleID,
                priority: IslandActivityPriority, title: String,
                detail: String?, systemImage: String, expiresAt: Date?) {
        self.id = id
        self.moduleID = moduleID
        self.priority = priority
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.expiresAt = expiresAt
    }

    public func isActive(at date: Date) -> Bool {
        expiresAt.map { $0 > date } ?? true
    }
}

public enum IslandModuleEvent: Equatable, Sendable {
    case publishActivity(IslandActivity)
    case removeActivity(id: String)
    case removeAllActivities
    case availabilityChanged(IslandModuleAvailability)
}

/// Persisted user configuration. `enabledModuleIDs` is an ordered array rather
/// than a Set so unknown future identifiers survive a load/save round trip.
public struct IslandModuleConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumPinnedModules = 5

    public var version: Int
    public var enabledModuleIDs: [IslandModuleID]
    public var pinnedModuleIDs: [IslandModuleID]

    public init(version: Int = Self.currentVersion,
                enabledModuleIDs: [IslandModuleID],
                pinnedModuleIDs: [IslandModuleID]) {
        self.version = version
        self.enabledModuleIDs = enabledModuleIDs
        self.pinnedModuleIDs = pinnedModuleIDs
        normalize()
    }

    public func isEnabled(_ id: IslandModuleID) -> Bool {
        enabledModuleIDs.contains(id)
    }

    public func isPinned(_ id: IslandModuleID) -> Bool {
        pinnedModuleIDs.contains(id)
    }

    public mutating func setEnabled(_ enabled: Bool, for id: IslandModuleID) {
        if enabled {
            if !enabledModuleIDs.contains(id) { enabledModuleIDs.append(id) }
        } else {
            enabledModuleIDs.removeAll { $0 == id }
            pinnedModuleIDs.removeAll { $0 == id }
        }
        normalize()
    }

    public mutating func setPinned(_ pinned: Bool, for id: IslandModuleID) {
        if pinned {
            setEnabled(true, for: id)
            if !pinnedModuleIDs.contains(id) { pinnedModuleIDs.append(id) }
        } else {
            pinnedModuleIDs.removeAll { $0 == id }
        }
        normalize()
    }

    public mutating func movePinned(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.sorted().map { pinnedModuleIDs[$0] }
        for index in fromOffsets.sorted(by: >) { pinnedModuleIDs.remove(at: index) }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        var destination = max(0, min(pinnedModuleIDs.count,
                                     toOffset - removedBeforeDestination))
        for id in moving {
            pinnedModuleIDs.insert(id, at: destination)
            destination += 1
        }
        normalize()
    }

    public mutating func normalize() {
        enabledModuleIDs = Self.uniqued(enabledModuleIDs)
        pinnedModuleIDs = Array(
            Self.uniqued(pinnedModuleIDs)
                .filter { enabledModuleIDs.contains($0) }
                .prefix(Self.maximumPinnedModules)
        )
        version = max(version, Self.currentVersion)
    }

    private static func uniqued(_ ids: [IslandModuleID]) -> [IslandModuleID] {
        var seen = Set<IslandModuleID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
