import AppKit
import Darwin
import Foundation
import IOKit.ps
import Observation

enum SystemMemoryPressure: String, Codable, Sendable, Equatable {
    case normal
    case warning
    case critical
    case unavailable
}

enum SystemThermalStatus: String, Codable, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unavailable
}

struct SystemProcessMetric: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let processIdentifier: Int32
    let name: String
    let bundleIdentifier: String?
    let cpuUsage: Double?
    let memoryBytes: UInt64?
}

struct SystemBatteryMetric: Codable, Sendable, Equatable {
    let percentage: Int
    let isCharging: Bool
    let isConnectedToPower: Bool
}

struct SystemSnapshot: Codable, Sendable, Equatable {
    var sampledAt: Date
    var cpuUsage: Double?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64?
    var memoryPressure: SystemMemoryPressure
    var diskAvailableBytes: Int64?
    var diskTotalBytes: Int64?
    var networkDownloadBytesPerSecond: Double?
    var networkUploadBytesPerSecond: Double?
    var battery: SystemBatteryMetric?
    var thermalStatus: SystemThermalStatus
    var isLowPowerModeEnabled: Bool
    var topApplications: [SystemProcessMetric]

    static func unavailable(at date: Date = Date()) -> Self {
        .init(
            sampledAt: date,
            cpuUsage: nil,
            memoryUsedBytes: nil,
            memoryTotalBytes: nil,
            memoryPressure: .unavailable,
            diskAvailableBytes: nil,
            diskTotalBytes: nil,
            networkDownloadBytesPerSecond: nil,
            networkUploadBytesPerSecond: nil,
            battery: nil,
            thermalStatus: .unavailable,
            isLowPowerModeEnabled: false,
            topApplications: []
        )
    }
}

protocol SystemStatusProviding: Sendable {
    func sample() async -> SystemSnapshot
}

struct SystemCPUTicks: Sendable, Equatable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64
}

struct SystemNetworkCounters: Sendable, Equatable {
    var received: UInt64
    var sent: UInt64
}

enum SystemMetricMath {
    static func wrappingDelta(previous: UInt64, current: UInt64) -> UInt64 {
        wrappingDelta(previous: previous, current: current, maximum: .max)
    }

    static func wrappingDelta(
        previous: UInt64,
        current: UInt64,
        maximum: UInt64
    ) -> UInt64 {
        current >= previous
            ? current - previous
            : (maximum - previous) + current + 1
    }

    static func cpuUsage(previous: SystemCPUTicks, current: SystemCPUTicks) -> Double? {
        let maximum = UInt64(UInt32.max)
        let user = wrappingDelta(previous: previous.user, current: current.user,
                                 maximum: maximum)
        let system = wrappingDelta(previous: previous.system, current: current.system,
                                   maximum: maximum)
        let idle = wrappingDelta(previous: previous.idle, current: current.idle,
                                 maximum: maximum)
        let nice = wrappingDelta(previous: previous.nice, current: current.nice,
                                 maximum: maximum)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return min(1, max(0, Double(user + system + nice) / Double(total)))
    }

    static func networkRates(
        previous: SystemNetworkCounters,
        current: SystemNetworkCounters,
        elapsed: TimeInterval
    ) -> (download: Double, upload: Double)? {
        guard elapsed > 0 else { return nil }
        return (
            Double(wrappingDelta(previous: previous.received, current: current.received))
                / elapsed,
            Double(wrappingDelta(previous: previous.sent, current: current.sent))
                / elapsed
        )
    }

    static func memoryUsedPages(
        active: UInt64,
        wired: UInt64,
        compressor: UInt64,
        purgeable: UInt64
    ) -> UInt64 {
        active - min(active, purgeable) + wired + compressor
    }
}

enum SystemRefreshPolicy {
    static func interval(
        isSelectedAndExpanded: Bool,
        isLowPowerModeEnabled: Bool,
        thermalStatus: SystemThermalStatus
    ) -> Duration {
        if isLowPowerModeEnabled || thermalStatus == .serious || thermalStatus == .critical {
            return .seconds(15)
        }
        return isSelectedAndExpanded ? .seconds(1) : .seconds(5)
    }
}

actor SystemStatusSampler: SystemStatusProviding {
    private struct RunningApp: Sendable {
        let pid: pid_t
        let name: String
        let bundleIdentifier: String?
    }

    private struct ProcessCounter: Sendable {
        let cpuNanoseconds: UInt64
        let sampledAt: Date
    }

    private let now: @Sendable () -> Date
    private var previousCPUTicks: SystemCPUTicks?
    private var previousNetworkCounters: SystemNetworkCounters?
    private var previousNetworkDate: Date?
    private var previousProcessCounters: [pid_t: ProcessCounter] = [:]
    private var cachedDisk: (available: Int64?, total: Int64?) = (nil, nil)
    private var diskSampleDate: Date?

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func sample() async -> SystemSnapshot {
        let date = now()
        let cpuTicks = Self.readCPUTicks()
        let cpuUsage = previousCPUTicks.flatMap { previous in
            cpuTicks.flatMap { SystemMetricMath.cpuUsage(previous: previous, current: $0) }
        }
        previousCPUTicks = cpuTicks

        let memory = Self.readMemory()
        let networkCounters = Self.readNetworkCounters()
        var downloadRate: Double?
        var uploadRate: Double?
        if let previousNetworkCounters,
           let previousNetworkDate,
           let networkCounters,
           let rates = SystemMetricMath.networkRates(
                previous: previousNetworkCounters,
                current: networkCounters,
                elapsed: date.timeIntervalSince(previousNetworkDate)
           ) {
            downloadRate = rates.download
            uploadRate = rates.upload
        }
        previousNetworkCounters = networkCounters
        previousNetworkDate = date

        if diskSampleDate.map({ date.timeIntervalSince($0) >= 30 }) ?? true {
            cachedDisk = Self.readDisk()
            diskSampleDate = date
        }

        let applications = await Self.runningApplications()
        let topApplications = readTopApplications(applications, at: date)
        let power = Self.readBattery()

        return SystemSnapshot(
            sampledAt: date,
            cpuUsage: cpuUsage,
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total,
            // High occupancy is not the same thing as memory pressure on
            // macOS. DispatchSourceMemoryPressure below owns warning/critical
            // transitions; this initial value remains normal until an actual
            // system pressure event says otherwise.
            memoryPressure: .normal,
            diskAvailableBytes: cachedDisk.available,
            diskTotalBytes: cachedDisk.total,
            networkDownloadBytesPerSecond: downloadRate,
            networkUploadBytesPerSecond: uploadRate,
            battery: power,
            thermalStatus: Self.thermalStatus,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            topApplications: topApplications
        )
    }

    private static func readCPUTicks() -> SystemCPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return SystemCPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    private static func readMemory() -> (used: UInt64?, total: UInt64?) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (nil, ProcessInfo.processInfo.physicalMemory) }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return (nil, ProcessInfo.processInfo.physicalMemory)
        }
        // Match the user-facing macOS "memory used" concept: active,
        // non-purgeable pages plus wired memory and the physical pages occupied
        // by the compressor. Inactive file cache is reclaimable and compressed
        // source pages must not be counted a second time.
        let usedPages = SystemMetricMath.memoryUsedPages(
            active: UInt64(stats.active_count),
            wired: UInt64(stats.wire_count),
            compressor: UInt64(stats.compressor_page_count),
            purgeable: UInt64(stats.purgeable_count)
        )
        return (usedPages * UInt64(pageSize), ProcessInfo.processInfo.physicalMemory)
    }

    private static func readNetworkCounters() -> SystemNetworkCounters? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            received &+= UInt64(data.pointee.ifi_ibytes)
            sent &+= UInt64(data.pointee.ifi_obytes)
        }
        return SystemNetworkCounters(received: received, sent: sent)
    }

    private static func readDisk() -> (available: Int64?, total: Int64?) {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        else { return (nil, nil) }
        return (
            values.volumeAvailableCapacityForImportantUsage,
            values.volumeTotalCapacity.map(Int64.init)
        )
    }

    private static func runningApplications() async -> [RunningApp] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { application in
                guard application.activationPolicy == .regular,
                      !application.isTerminated else { return nil }
                return RunningApp(
                    pid: application.processIdentifier,
                    name: application.localizedName ?? String(localized: "Unknown App"),
                    bundleIdentifier: application.bundleIdentifier
                )
            }
        }
    }

    private func readTopApplications(
        _ applications: [RunningApp],
        at date: Date
    ) -> [SystemProcessMetric] {
        var nextCounters: [pid_t: ProcessCounter] = [:]
        var metrics: [SystemProcessMetric] = []
        for application in applications {
            var info = proc_taskinfo()
            let expectedSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(
                    application.pid,
                    PROC_PIDTASKINFO,
                    0,
                    pointer,
                    expectedSize
                )
            }
            guard result == expectedSize else { continue }
            let cpuNanoseconds = info.pti_total_user &+ info.pti_total_system
            nextCounters[application.pid] = .init(
                cpuNanoseconds: cpuNanoseconds,
                sampledAt: date
            )
            let cpuUsage: Double? = if let previous = previousProcessCounters[application.pid] {
                Double(SystemMetricMath.wrappingDelta(
                    previous: previous.cpuNanoseconds,
                    current: cpuNanoseconds
                )) / max(1, date.timeIntervalSince(previous.sampledAt) * 1_000_000_000)
            } else {
                nil
            }
            metrics.append(.init(
                id: application.bundleIdentifier ?? "pid:\(application.pid)",
                processIdentifier: application.pid,
                name: application.name,
                bundleIdentifier: application.bundleIdentifier,
                cpuUsage: cpuUsage,
                memoryBytes: info.pti_resident_size
            ))
        }
        previousProcessCounters = nextCounters
        return metrics.sorted { lhs, rhs in
            let lhsScore = max(lhs.cpuUsage ?? 0, Double(lhs.memoryBytes ?? 0) / 4_000_000_000)
            let rhsScore = max(rhs.cpuUsage ?? 0, Double(rhs.memoryBytes ?? 0) / 4_000_000_000)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.prefix(3).map { $0 }
    }

    private static func readBattery() -> SystemBatteryMetric? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            return .init(
                percentage: min(100, max(0, Int(
                    (Double(current) / Double(maximum) * 100).rounded()
                ))),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isConnectedToPower: description[kIOPSPowerSourceStateKey] as? String
                    == kIOPSACPowerValue
            )
        }
        return nil
    }

    private static var thermalStatus: SystemThermalStatus {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unavailable
        }
    }
}

struct SystemApplicationAlertEvaluator: Sendable {
    private var cpuThresholdStart: [String: Date] = [:]
    private var cooldownUntil: [String: Date] = [:]

    mutating func alerts(
        for snapshot: SystemSnapshot,
        at date: Date
    ) -> [SystemProcessMetric] {
        let memoryThreshold = max(
            UInt64(2 * 1_024 * 1_024 * 1_024),
            UInt64(Double(snapshot.memoryTotalBytes ?? 0) * 0.15)
        )
        var result: [SystemProcessMetric] = []
        let currentIDs = Set(snapshot.topApplications.map(\.id))
        cpuThresholdStart = cpuThresholdStart.filter { currentIDs.contains($0.key) }

        for application in snapshot.topApplications {
            if let until = cooldownUntil[application.id], until > date { continue }
            let memoryExceeded = (application.memoryBytes ?? 0) > memoryThreshold
            let cpuExceeded = (application.cpuUsage ?? 0) > 0.8
            if cpuExceeded {
                let began = cpuThresholdStart[application.id] ?? date
                cpuThresholdStart[application.id] = began
                if date.timeIntervalSince(began) >= 60 || memoryExceeded {
                    result.append(application)
                    cooldownUntil[application.id] = date.addingTimeInterval(15 * 60)
                    cpuThresholdStart.removeValue(forKey: application.id)
                }
            } else {
                cpuThresholdStart.removeValue(forKey: application.id)
                if memoryExceeded {
                    result.append(application)
                    cooldownUntil[application.id] = date.addingTimeInterval(15 * 60)
                }
            }
        }
        return result
    }
}

@MainActor
@Observable
final class SystemStatusModuleStore: IslandModuleRuntime {
    let descriptor = IslandModuleDescriptor(
        id: .system,
        title: String(localized: "System Status"),
        systemImage: "gauge.with.dots.needle.67percent",
        order: 4,
        isCore: false
    )
    let events: AsyncStream<IslandModuleEvent>

    private let provider: any SystemStatusProviding
    private let isSelectedAndExpanded: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let continuation: AsyncStream<IslandModuleEvent>.Continuation
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var immediateRefreshTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored nonisolated(unsafe) private var memoryPressureSource:
        DispatchSourceMemoryPressure?
    @ObservationIgnored nonisolated(unsafe) private var batteryRunLoopSource: CFRunLoopSource?
    private var applicationAlertEvaluator = SystemApplicationAlertEvaluator()
    private var publishedWarningIDs: Set<String> = []
    private var ignoredWarningIDs: Set<String> = []
    private var eventMemoryPressure: SystemMemoryPressure?

    private(set) var snapshot = SystemSnapshot.unavailable()
    private(set) var isRunning = false
    private(set) var alerts: [IslandActivity] = []

    init(
        provider: any SystemStatusProviding = SystemStatusSampler(),
        isSelectedAndExpanded: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.provider = provider
        self.isSelectedAndExpanded = isSelectedAndExpanded
        self.now = now
        var capturedContinuation: AsyncStream<IslandModuleEvent>.Continuation?
        events = AsyncStream { continuation in capturedContinuation = continuation }
        continuation = capturedContinuation!
    }

    deinit {
        samplingTask?.cancel()
        immediateRefreshTask?.cancel()
        memoryPressureSource?.cancel()
        if let batteryRunLoopSource { CFRunLoopSourceInvalidate(batteryRunLoopSource) }
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        registerNotifications()
        startMemoryPressureMonitoring()
        startBatteryMonitoring()
        samplingTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                await self.refresh()
                let interval = SystemRefreshPolicy.interval(
                    isSelectedAndExpanded: self.isSelectedAndExpanded(),
                    isLowPowerModeEnabled: self.snapshot.isLowPowerModeEnabled,
                    thermalStatus: self.snapshot.thermalStatus
                )
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        samplingTask?.cancel()
        samplingTask = nil
        immediateRefreshTask?.cancel()
        immediateRefreshTask = nil
        unregisterNotifications()
        stopMemoryPressureMonitoring()
        stopBatteryMonitoring()
        alerts = []
        publishedWarningIDs = []
        continuation.yield(.removeAllActivities)
    }

    func refresh() async {
        guard isRunning else { return }
        snapshot = await provider.sample()
        if let eventMemoryPressure { snapshot.memoryPressure = eventMemoryPressure }
        evaluateWarnings()
    }

    func ignoreAlert(id: String) {
        ignoredWarningIDs.insert(id)
        continuation.yield(.removeActivity(id: id))
        alerts.removeAll { $0.id == id }
    }

    private func requestImmediateRefresh() {
        guard isRunning else { return }
        immediateRefreshTask?.cancel()
        immediateRefreshTask = Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    private func registerNotifications() {
        guard notificationTokens.isEmpty else { return }
        let names: [Notification.Name] = [
            Notification.Name.NSProcessInfoPowerStateDidChange,
            Notification.Name("NSProcessInfoThermalStateDidChangeNotification"),
        ]
        notificationTokens = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.requestImmediateRefresh() }
            }
        }
    }

    private func unregisterNotifications() {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens = []
    }

    /// Deterministic seam used by the DispatchSource bridge and unit tests.
    func processMemoryPressureEvent(_ pressure: SystemMemoryPressure) {
        eventMemoryPressure = pressure
        snapshot.memoryPressure = pressure
        evaluateWarnings()
    }

    private func startMemoryPressureMonitoring() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let pressure: SystemMemoryPressure
            if source.data.contains(.critical) {
                pressure = .critical
            } else if source.data.contains(.warning) {
                pressure = .warning
            } else {
                pressure = .normal
            }
            MainActor.assumeIsolated {
                self?.processMemoryPressureEvent(pressure)
            }
        }
        memoryPressureSource = source
        source.resume()
    }

    private func stopMemoryPressureMonitoring() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        eventMemoryPressure = nil
    }

    private func startBatteryMonitoring() {
        guard batteryRunLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanaged = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let store = Unmanaged<SystemStatusModuleStore>
                .fromOpaque(context)
                .takeUnretainedValue()
            Task { @MainActor in store.requestImmediateRefresh() }
        }, context) else { return }
        let source = unmanaged.takeRetainedValue()
        batteryRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func stopBatteryMonitoring() {
        guard let batteryRunLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), batteryRunLoopSource, .commonModes)
        CFRunLoopSourceInvalidate(batteryRunLoopSource)
        self.batteryRunLoopSource = nil
    }

    private func evaluateWarnings() {
        let date = now()
        var next: [IslandActivity] = []
        if snapshot.memoryPressure == .warning || snapshot.memoryPressure == .critical {
            next.append(.init(
                id: "system.memory-pressure",
                moduleID: .system,
                priority: .systemWarning,
                title: snapshot.memoryPressure == .critical
                    ? String(localized: "Memory pressure is critical")
                    : String(localized: "Memory pressure is high"),
                detail: String(localized: "View system details"),
                systemImage: "memorychip",
                expiresAt: nil
            ))
        }
        if snapshot.thermalStatus == .serious || snapshot.thermalStatus == .critical {
            next.append(.init(
                id: "system.thermal",
                moduleID: .system,
                priority: .systemWarning,
                title: snapshot.thermalStatus == .critical
                    ? String(localized: "Mac thermal state is critical")
                    : String(localized: "Mac thermal state is serious"),
                detail: String(localized: "Performance may be reduced"),
                systemImage: "thermometer.high",
                expiresAt: nil
            ))
        }
        if let available = snapshot.diskAvailableBytes,
           let total = snapshot.diskTotalBytes,
           total > 0,
           available < 20_000_000_000,
           Double(available) / Double(total) < 0.10 {
            next.append(.init(
                id: "system.disk-space",
                moduleID: .system,
                priority: .systemWarning,
                title: String(localized: "Disk space is low"),
                detail: ByteCountFormatter.string(fromByteCount: available, countStyle: .file),
                systemImage: "externaldrive.badge.exclamationmark",
                expiresAt: nil
            ))
        }
        for application in applicationAlertEvaluator.alerts(for: snapshot, at: date) {
            next.append(.init(
                id: "system.application.\(application.id)",
                moduleID: .system,
                priority: .systemWarning,
                title: String(localized: "\(application.name) is using significant resources"),
                detail: Self.applicationDetail(application),
                systemImage: "app.badge",
                expiresAt: date.addingTimeInterval(12)
            ))
        }

        let currentConditionIDs = Set(next.map(\.id))
        ignoredWarningIDs.formIntersection(currentConditionIDs)
        let visible = next.filter { !ignoredWarningIDs.contains($0.id) }
        let nextIDs = Set(visible.map(\.id))
        for removedID in publishedWarningIDs.subtracting(nextIDs) {
            continuation.yield(.removeActivity(id: removedID))
        }
        for activity in visible { continuation.yield(.publishActivity(activity)) }
        publishedWarningIDs = nextIDs
        alerts = visible
    }

    private static func applicationDetail(_ application: SystemProcessMetric) -> String {
        let cpu = application.cpuUsage.map { String(format: "CPU %.0f%%", $0 * 100) }
        let memory = application.memoryBytes.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory)
        }
        return [cpu, memory].compactMap { $0 }.joined(separator: " · ")
    }
}
