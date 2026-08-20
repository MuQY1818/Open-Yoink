import SwiftUI

struct IslandBatteryView: View {
    @Environment(PowerSourceMonitor.self) private var powerMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            IslandModuleHeader(
                title: "Battery",
                subtitle: nil,
                systemImage: batterySymbol
            )
            if powerMonitor.snapshot.hasBattery {
                HStack(spacing: 22) {
                    BatteryChargeRing(
                        percentage: powerMonitor.snapshot.percentage,
                        tint: batteryTint,
                        reduceMotion: reduceMotion
                    )

                    VStack(alignment: .leading, spacing: 9) {
                        Image(systemName: statusSymbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(batteryTint)
                            .frame(width: 42, height: 42)
                            .background {
                                Circle().fill(batteryTint.opacity(0.13))
                            }

                        Text(powerStatus)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(IslandVisualStyle.primaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(IslandVisualStyle.cardFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(IslandVisualStyle.hairline, lineWidth: 1)
                        }
                }
            } else {
                IslandEmptyState(
                    title: "Not applicable",
                    message: "This Mac does not report an internal battery.",
                    systemImage: "desktopcomputer"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var statusSymbol: String {
        if powerMonitor.snapshot.isCharging { return "bolt.fill" }
        if powerMonitor.snapshot.isConnectedToPower { return "powerplug.fill" }
        return batterySymbol
    }

    private var batterySymbol: String {
        switch powerMonitor.snapshot.percentage {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...65: return "battery.50percent"
        case 66...90: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var batteryTint: Color {
        if powerMonitor.snapshot.percentage <= 10 { return .red }
        if powerMonitor.snapshot.percentage <= 20 { return .orange }
        return .green
    }

    private var powerStatus: String {
        if powerMonitor.snapshot.isCharging { return String(localized: "Charging") }
        if powerMonitor.snapshot.isConnectedToPower { return String(localized: "Connected to power") }
        return String(localized: "Running on battery")
    }
}
private struct BatteryChargeRing: View {
    let percentage: Int
    let tint: Color
    let reduceMotion: Bool

    private var progress: Double {
        min(max(Double(percentage) / 100, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.09), lineWidth: 8)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.62), tint, tint.opacity(0.88)],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.30), radius: 5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35),
                           value: progress)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(percentage)")
                    .font(.system(size: 31, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandVisualStyle.primaryText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(IslandVisualStyle.secondaryText)
            }
        }
        .frame(width: 108, height: 108)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery"))
        .accessibilityValue(Text("\(percentage) percent"))
    }
}
