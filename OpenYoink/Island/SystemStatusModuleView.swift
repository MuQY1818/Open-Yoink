import AppKit
import SwiftUI

struct IslandSystemStatusView: View {
    @Environment(SystemStatusModuleStore.self) private var store

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 9) {
            IslandModuleHeader(
                title: "System Status",
                subtitle: String(localized: "Read-only Mac status"),
                systemImage: "gauge.with.dots.needle.67percent"
            )

            LazyVGrid(columns: columns, spacing: 8) {
                metricCard(
                    title: "CPU",
                    value: percent(store.snapshot.cpuUsage),
                    detail: nil,
                    systemImage: "cpu"
                )
                metricCard(
                    title: "Memory",
                    value: memorySummary,
                    detail: pressureTitle,
                    systemImage: "memorychip"
                )
                metricCard(
                    title: "Network",
                    value: networkSummary,
                    detail: networkDetail,
                    systemImage: "network"
                )
                metricCard(
                    title: "Disk",
                    value: bytes(store.snapshot.diskAvailableBytes),
                    detail: String(localized: "available"),
                    systemImage: "internaldrive"
                )
                metricCard(
                    title: "Battery",
                    value: batterySummary,
                    detail: batteryDetail,
                    systemImage: "battery.75percent"
                )
                metricCard(
                    title: "Thermal",
                    value: thermalTitle,
                    detail: store.snapshot.isLowPowerModeEnabled
                        ? String(localized: "Low Power Mode") : nil,
                    systemImage: "thermometer.medium"
                )
            }

            if !store.alerts.isEmpty {
                alertStrip
            }

            applicationList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func metricCard(
        title: LocalizedStringKey,
        value: String,
        detail: String?,
        systemImage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.48))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.75)
                }
        }
    }

    private var alertStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(store.alerts) { alert in
                    HStack(spacing: 7) {
                        Image(systemName: alert.systemImage)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(alert.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.90))
                                .lineLimit(1)
                            if let detail = alert.detail {
                                Text(detail)
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(.white.opacity(0.48))
                                    .lineLimit(1)
                            }
                        }
                        Button("View Details") {}
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Button("Ignore Once") { store.ignoreAlert(id: alert.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background {
                        Capsule().fill(Color.orange.opacity(0.10))
                    }
                }
            }
        }
        .frame(height: 34)
    }

    private var applicationList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Highest usage applications")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.52))

            if store.snapshot.topApplications.isEmpty {
                Text("Not Available")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(maxWidth: .infinity, minHeight: 28)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 3) {
                        ForEach(store.snapshot.topApplications) { application in
                            HStack(spacing: 8) {
                                applicationIcon(application)
                                Text(application.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.86))
                                    .lineLimit(1)
                                Spacer()
                                Text(percent(application.cpuUsage))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.62))
                                    .frame(width: 42, alignment: .trailing)
                                Text(bytes(application.memoryBytes.map(Int64.init)))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.62))
                                    .frame(width: 58, alignment: .trailing)
                            }
                            .frame(height: 21)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: .infinity,
               alignment: .top)
        .layoutPriority(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.04))
        }
    }

    private var memorySummary: String {
        guard let used = store.snapshot.memoryUsedBytes,
              let total = store.snapshot.memoryTotalBytes else {
            return String(localized: "Not Available")
        }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .memory)) / \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .memory))"
    }

    private var networkSummary: String {
        guard let down = store.snapshot.networkDownloadBytesPerSecond,
              store.snapshot.networkUploadBytesPerSecond != nil else {
            return String(localized: "Not Available")
        }
        return "↓ \(rate(down))"
    }

    private var networkDetail: String? {
        guard let up = store.snapshot.networkUploadBytesPerSecond else { return nil }
        return "↑ \(rate(up))"
    }

    private var batterySummary: String {
        store.snapshot.battery.map { "\($0.percentage)%" }
            ?? String(localized: "Not Available")
    }

    private var batteryDetail: String? {
        guard let battery = store.snapshot.battery else { return nil }
        if battery.isCharging { return String(localized: "Charging") }
        return battery.isConnectedToPower
            ? String(localized: "Connected to Power")
            : String(localized: "On Battery")
    }

    private var pressureTitle: String? {
        switch store.snapshot.memoryPressure {
        case .normal: String(localized: "Normal")
        case .warning: String(localized: "Warning")
        case .critical: String(localized: "Critical")
        case .unavailable: nil
        }
    }

    private var thermalTitle: String {
        switch store.snapshot.thermalStatus {
        case .nominal: String(localized: "Nominal")
        case .fair: String(localized: "Fair")
        case .serious: String(localized: "Serious")
        case .critical: String(localized: "Critical")
        case .unavailable: String(localized: "Not Available")
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) }
            ?? String(localized: "Not Available")
    }

    private func bytes(_ value: Int64?) -> String {
        value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? String(localized: "Not Available")
    }

    private func rate(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) + "/s"
    }

    @ViewBuilder
    private func applicationIcon(_ application: SystemProcessMetric) -> some View {
        if let icon = NSRunningApplication(
            processIdentifier: application.processIdentifier
        )?.icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
        } else {
            Image(systemName: "app.fill")
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 17, height: 17)
        }
    }
}
