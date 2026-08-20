import SwiftUI

struct IslandTimerView: View {
    private enum Page: Hashable {
        case timer
        case history
    }

    @Environment(IslandTimerStore.self) private var timerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var customMinutes = 25
    @State private var page: Page = .timer

    var body: some View {
        VStack(spacing: 10) {
            IslandModuleHeader(
                title: "Timer",
                subtitle: page == .timer
                    ? timerSubtitle
                    : String(localized: "Focus history"),
                systemImage: timerStore.mode.systemImage
            )
            .overlay(alignment: .trailing) {
                timerPageSwitcher
            }

            Group {
                if page == .timer {
                    timerControls
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                } else {
                    IslandFocusHistoryView()
                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            customMinutes = timerStore.mode.defaultMinutes
        }
        .onChange(of: timerStore.mode) { _, mode in
            customMinutes = mode.defaultMinutes
        }
    }

    private var timerControls: some View {
        HStack(spacing: 18) {
            IslandTimerDial(
                timeText: timerDisplayText,
                stateText: timerDialState,
                systemImage: timerStateSymbol,
                remainingFraction: timerDialRemainingFraction,
                tint: timerTint,
                tick: timerStore.tick,
                isRunning: isRunning,
                reduceMotion: reduceMotion
            )
            .frame(width: 146, height: 146)

            VStack(spacing: 7) {
                if timerStore.state == .idle {
                    timerModeSelector
                    timerIntention
                    timerPresets
                    timerSetupRow
                } else {
                    timerStatusSummary
                    timerRunningControls
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
    }

    private var timerPageSwitcher: some View {
        HStack(spacing: 2) {
            timerPageButton(.timer,
                            systemImage: "timer",
                            accessibilityLabel: "Timer controls")
            timerPageButton(.history,
                            systemImage: "chart.dots.scatter",
                            accessibilityLabel: "Focus history")
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay {
            Capsule().strokeBorder(IslandVisualStyle.hairline, lineWidth: 1)
        }
    }

    private func timerPageButton(
        _ target: Page,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey
    ) -> some View {
        let selected = page == target
        return Button {
            if reduceMotion {
                page = target
            } else {
                withAnimation(.smooth(duration: 0.26)) {
                    page = target
                }
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.white : IslandVisualStyle.tertiaryText)
                .frame(width: 27, height: 24)
                .background {
                    if selected {
                        Capsule().fill(Color.white.opacity(0.11))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(Text(accessibilityLabel))
        .modifier(IslandSelectedAccessibilityModifier(selected: selected))
    }

    private var timerModeSelector: some View {
        HStack(spacing: 5) {
            ForEach(IslandTimerStore.Mode.allCases, id: \.self) { mode in
                let isSelected = timerStore.mode == mode
                Button {
                    timerStore.selectMode(mode)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 9, weight: .bold))
                        Text(mode.title)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Color.white : IslandVisualStyle.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background {
                        Capsule()
                            .fill(isSelected ? modeTint(mode).opacity(0.24)
                                             : IslandVisualStyle.controlFill)
                            .overlay {
                                Capsule().strokeBorder(
                                    isSelected ? modeTint(mode).opacity(0.64)
                                               : IslandVisualStyle.hairline,
                                    lineWidth: 1
                                )
                            }
                    }
                }
                .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
                .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
            }
        }
    }

    @ViewBuilder
    private var timerIntention: some View {
        if timerStore.mode == .focus {
            HStack(spacing: 7) {
                Image(systemName: "scope")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(timerTint)
                TextField(String(localized: "What will you focus on?"), text: goalBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IslandVisualStyle.primaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(Capsule().fill(Color.white.opacity(0.065)))
            .overlay {
                Capsule().strokeBorder(timerTint.opacity(0.20), lineWidth: 1)
            }
        } else {
            HStack(spacing: 7) {
                Image(systemName: timerStore.mode.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(timerStore.mode == .shortBreak
                     ? String(localized: "Take a breath")
                     : String(localized: "Step away and recharge"))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(timerTint)
            .padding(.horizontal, 10)
            .frame(height: 29)
            .background(Capsule().fill(timerTint.opacity(0.075)))
            .overlay {
                Capsule().strokeBorder(timerTint.opacity(0.18), lineWidth: 1)
            }
        }
    }

    private var timerPresets: some View {
        HStack(spacing: 5) {
            ForEach(modePresets, id: \.self) { minutes in
                let isSelected = customMinutes == minutes
                Button {
                    if reduceMotion {
                        customMinutes = minutes
                    } else {
                        withAnimation(.snappy(duration: 0.22)) {
                            customMinutes = minutes
                        }
                    }
                } label: {
                    Text("\(minutes)m")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected
                                         ? Color.white
                                         : IslandVisualStyle.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 27)
                        .background {
                            Capsule()
                                .fill(isSelected
                                      ? AnyShapeStyle(LinearGradient(
                                        colors: [timerTint.opacity(0.92),
                                                 timerTint.opacity(0.58)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                      ))
                                      : AnyShapeStyle(IslandVisualStyle.controlFill))
                                .overlay {
                                    Capsule().strokeBorder(
                                        isSelected ? Color.white.opacity(0.20)
                                            : IslandVisualStyle.hairline,
                                        lineWidth: 1
                                    )
                                }
                        }
                }
                .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
                .accessibilityLabel(Text("\(minutes) minutes"))
                .modifier(IslandSelectedAccessibilityModifier(selected: isSelected))
            }
        }
    }

    private var timerSetupRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                compactControlButton("minus") {
                    customMinutes = max(1, customMinutes - 1)
                }
                Text("\(customMinutes) min")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(IslandVisualStyle.primaryText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(minWidth: 58)
                compactControlButton("plus") {
                    customMinutes = min(180, customMinutes + 1)
                }
            }
            .padding(.horizontal, 3)
            .background(Capsule().fill(IslandVisualStyle.controlFill))

            Spacer(minLength: 4)

            Button {
                timerStore.start(minutes: Double(customMinutes))
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .frame(height: 35)
                    .background {
                        Capsule().fill(Color.white)
                    }
                    .shadow(color: timerTint.opacity(0.32), radius: 8, y: 3)
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        }
    }

    private var timerStatusSummary: some View {
        HStack(spacing: 9) {
            Image(systemName: timerStateSymbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(timerTint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(timerTint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(timerDialState)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(IslandVisualStyle.primaryText)
                Text(timerStatusDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IslandVisualStyle.tertiaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Capsule().fill(timerTint.opacity(0.08)))
        .overlay {
            Capsule().strokeBorder(timerTint.opacity(0.16), lineWidth: 1)
        }
    }

    private var timerRunningControls: some View {
        HStack(spacing: 10) {
            timerPrimaryAction
            Button(role: .destructive) { timerStore.reset() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Capsule().fill(IslandVisualStyle.controlFill))
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var timerSubtitle: String {
        switch timerStore.state {
        case .idle: return String(localized: "Ready to flow")
        case .running: return timerStore.mode.title
        case .paused: return String(localized: "Paused")
        case .finished: return String(localized: "Timer finished")
        }
    }

    private var timerDisplayText: String {
        if timerStore.state == .idle {
            return String(format: "%02d:00", customMinutes)
        }
        return timerStore.formattedRemaining
    }

    private var timerDialRemainingFraction: Double {
        timerStore.state == .idle ? 1 : timerStore.remainingFraction
    }

    private var isRunning: Bool {
        if case .running = timerStore.state { return true }
        return false
    }

    private var timerDialState: String {
        switch timerStore.state {
        case .idle, .running: return timerStore.mode.title
        case .paused: return String(localized: "Paused")
        case .finished: return String(localized: "Time's up")
        }
    }

    private var timerStatusDetail: String {
        let trimmedGoal = timerStore.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        switch timerStore.state {
        case .idle: return String(localized: "Ready to flow")
        case .running where timerStore.mode == .focus && !trimmedGoal.isEmpty:
            return trimmedGoal
        case .running: return String(localized: "Countdown is running")
        case .paused: return String(localized: "Continue whenever you're ready")
        case .finished: return String(localized: "Your timer is complete")
        }
    }

    private var timerStateSymbol: String {
        switch timerStore.state {
        case .idle: return timerStore.mode.systemImage
        case .running: return "hourglass.bottomhalf.filled"
        case .paused: return "pause.fill"
        case .finished: return "checkmark"
        }
    }

    private var timerTint: Color {
        switch timerStore.state {
        case .idle, .running, .paused: return modeTint(timerStore.mode)
        case .finished: return .green
        }
    }

    private var modePresets: [Int] {
        switch timerStore.mode {
        case .focus: [15, 25, 45]
        case .shortBreak: [5, 10, 15]
        case .longBreak: [15, 20, 30]
        }
    }

    private var goalBinding: Binding<String> {
        Binding(get: { timerStore.goal }, set: { timerStore.setGoal($0) })
    }

    private func modeTint(_ mode: IslandTimerStore.Mode) -> Color {
        switch mode {
        case .focus: Color(red: 0.22, green: 0.86, blue: 0.48)
        case .shortBreak: Color(red: 0.26, green: 0.67, blue: 1.0)
        case .longBreak: Color(red: 0.66, green: 0.43, blue: 0.98)
        }
    }

    @ViewBuilder
    private var timerPrimaryAction: some View {
        switch timerStore.state {
        case .running:
            timerStateButton("Pause", systemImage: "pause.fill") { timerStore.pause() }
        case .paused:
            timerStateButton("Resume", systemImage: "play.fill") { timerStore.resume() }
        case .finished:
            timerStateButton("Done", systemImage: "checkmark") {
                timerStore.acknowledgeFinished()
            }
        case .idle:
            EmptyView()
        }
    }

    private func timerStateButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Capsule().fill(timerTint))
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
    }

    private func compactControlButton(
        _ symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
    }
}
private struct IslandFocusHistoryView: View {
    private struct Cell: Equatable {
        let date: Date
        let period: IslandFocusPeriod
    }

    @Environment(IslandTimerStore.self) private var timerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var weekOffset = 0
    @State private var hoveredCell: Cell?
    @State private var selectedCell: Cell?

    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            focusSummary

            VStack(spacing: 10) {
                weekNavigation
                heatmap
                heatmapLegend
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
    }

    private var focusSummary: some View {
        let cell = hoveredCell ?? selectedCell
        let summaryDate = cell?.date ?? Date()
        let summaryPeriod = cell?.period
        let duration = IslandFocusStatistics.duration(
            timerStore.sessions,
            on: summaryDate,
            period: summaryPeriod,
            calendar: calendar
        )
        let sessionCount = IslandFocusStatistics.sessions(
            timerStore.sessions,
            on: summaryDate,
            period: summaryPeriod,
            calendar: calendar
        ).count
        let summaryTint = summaryPeriod?.tint ?? focusGreen

        return VStack(alignment: .leading, spacing: 5) {
            Text(summaryTitle(for: cell))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(summaryTint)
                .textCase(.uppercase)
                .lineLimit(1)

            Text(focusDurationText(duration))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(IslandVisualStyle.primaryText)
                .monospacedDigit()
                .contentTransition(.numericText())

            Label(
                String.localizedStringWithFormat(
                    String(localized: "%lld focus sessions"),
                    sessionCount
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(IslandVisualStyle.secondaryText)
            .lineLimit(1)

            Label(
                String.localizedStringWithFormat(
                    String(localized: "%lld day streak"),
                    IslandFocusStatistics.currentStreak(
                        timerStore.sessions,
                        at: Date(),
                        calendar: calendar
                    )
                ),
                systemImage: "flame.fill"
            )
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(focusGreen)
            .lineLimit(1)

            if timerStore.sessions.isEmpty {
                Text("Complete a focus session to start your map.")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(IslandVisualStyle.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(width: 136, alignment: .leading)
        .frame(minHeight: 138, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay {
                    LinearGradient(
                        colors: [summaryTint.opacity(0.11), .clear, .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16,
                                                style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
                }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: cell)
    }

    private var weekNavigation: some View {
        HStack(spacing: 6) {
            Button {
                changeWeek(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(Text("Previous week"))

            Spacer(minLength: 0)

            Text(weekRangeText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(IslandVisualStyle.secondaryText)
                .monospacedDigit()
                .contentTransition(.numericText())

            Spacer(minLength: 0)

            Button {
                changeWeek(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(IslandPressFeedbackStyle(reduceMotion: reduceMotion))
            .disabled(weekOffset >= 0)
            .opacity(weekOffset >= 0 ? 0.26 : 1)
            .accessibilityLabel(Text("Next week"))
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(IslandVisualStyle.secondaryText)
    }

    private var heatmap: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(spacing: 4) {
                Color.clear.frame(width: 18, height: 12)
                ForEach(IslandFocusPeriod.allCases, id: \.self) { period in
                    Image(systemName: period.systemImage)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(period.tint.opacity(0.78))
                        .frame(width: 18, height: 25)
                        .accessibilityHidden(true)
                }
            }

            ForEach(Array(weekDays.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 4) {
                    Text(day, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(calendar.isDateInToday(day)
                                         ? Color.white
                                         : IslandVisualStyle.tertiaryText)
                        .frame(height: 12)

                    ForEach(IslandFocusPeriod.allCases, id: \.self) { period in
                        heatCell(day: day, period: period)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var heatmapLegend: some View {
        HStack(spacing: 10) {
            ForEach(IslandFocusPeriod.allCases, id: \.self) { period in
                Label(period.title, systemImage: period.systemImage)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(period.tint.opacity(0.76))
            }
            Spacer(minLength: 0)
            Text("Focus time")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(IslandVisualStyle.tertiaryText)
        }
        .lineLimit(1)
    }

    private func heatCell(day: Date, period: IslandFocusPeriod) -> some View {
        let cell = Cell(date: day, period: period)
        let duration = IslandFocusStatistics.duration(
            timerStore.sessions,
            on: day,
            period: period,
            calendar: calendar
        )
        let count = IslandFocusStatistics.sessions(
            timerStore.sessions,
            on: day,
            period: period,
            calendar: calendar
        ).count
        let isHighlighted = hoveredCell == cell || selectedCell == cell
        let intensity = min(max(duration / 3_600, 0), 1)

        return Button {
            selectedCell = selectedCell == cell ? nil : cell
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(duration > 0
                      ? period.tint.opacity(0.20 + intensity * 0.72)
                      : Color.white.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isHighlighted
                                ? Color.white.opacity(0.78)
                                : Color.white.opacity(duration > 0 ? 0.12 : 0.045),
                            lineWidth: isHighlighted ? 1.2 : 1
                        )
                }
                .shadow(color: duration > 0
                        ? period.tint.opacity(0.16 + intensity * 0.18)
                        : .clear,
                        radius: 4)
                .frame(maxWidth: .infinity, minHeight: 25, maxHeight: 25)
                .scaleEffect(isHighlighted && !reduceMotion ? 1.055 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredCell = hovering ? cell : (hoveredCell == cell ? nil : hoveredCell)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14),
                   value: isHighlighted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(cellAccessibilityLabel(cell)))
        .accessibilityValue(Text(
            String.localizedStringWithFormat(
                String(localized: "%lld focus sessions"),
                count
            ) + ", " + focusDurationText(duration)
        ))
        .modifier(IslandSelectedAccessibilityModifier(selected: selectedCell == cell))
    }

    private var weekStart: Date {
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .weekOfYear,
                             value: weekOffset,
                             to: currentWeek) ?? currentWeek
    }

    private var weekDays: [Date] {
        (0..<7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: weekStart)
        }
    }

    private var weekRangeText: String {
        guard let end = weekDays.last else { return "" }
        let startText = weekStart.formatted(.dateTime.month(.abbreviated).day())
        let endText = end.formatted(.dateTime.month(.abbreviated).day())
        return "\(startText) – \(endText)"
    }

    private func changeWeek(by amount: Int) {
        let target = min(0, weekOffset + amount)
        if reduceMotion {
            weekOffset = target
        } else {
            withAnimation(.smooth(duration: 0.24)) {
                weekOffset = target
            }
        }
        hoveredCell = nil
        selectedCell = nil
    }

    private func summaryTitle(for cell: Cell?) -> String {
        guard let cell else { return String(localized: "Today") }
        let date = cell.date.formatted(.dateTime.month(.abbreviated).day())
        return "\(date) · \(cell.period.title)"
    }

    private func cellAccessibilityLabel(_ cell: Cell) -> String {
        let date = cell.date.formatted(.dateTime.year().month().day().weekday(.wide))
        return "\(date), \(cell.period.title)"
    }

    private func focusDurationText(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration.rounded() / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    private var focusGreen: Color {
        Color(red: 0.22, green: 0.86, blue: 0.48)
    }
}

private extension IslandFocusPeriod {
    var title: String {
        switch self {
        case .morning: String(localized: "Morning")
        case .afternoon: String(localized: "Afternoon")
        case .evening: String(localized: "Evening")
        }
    }

    var systemImage: String {
        switch self {
        case .morning: "sunrise.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "moon.stars.fill"
        }
    }

    var tint: Color {
        switch self {
        case .morning: Color(red: 1.0, green: 0.70, blue: 0.34)
        case .afternoon: Color(red: 0.22, green: 0.86, blue: 0.48)
        case .evening: Color(red: 0.66, green: 0.43, blue: 0.98)
        }
    }
}

private struct IslandTimerDial: View {
    let timeText: String
    let stateText: String
    let systemImage: String
    let remainingFraction: Double
    let tint: Color
    let tick: Int
    let isRunning: Bool
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let fraction = min(max(remainingFraction, 0), 1)
            let radius = diameter / 2 - 9
            let radians = (fraction * 360 - 90) * Double.pi / 180

            ZStack {
                Circle()
                    .stroke(tint.opacity(isRunning ? 0.12 : 0.07), lineWidth: 1)
                    .scaleEffect(1.075)
                    .shadow(color: tint.opacity(isRunning ? 0.22 : 0.08), radius: 9)
                Circle()
                    .fill(RadialGradient(
                        colors: [tint.opacity(isRunning ? 0.18 : 0.10),
                                 Color.black.opacity(0.02)],
                        center: .center,
                        startRadius: 2,
                        endRadius: diameter * 0.54
                    ))
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        AngularGradient(
                            colors: [tint.opacity(0.46), tint, tint.opacity(0.72)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(isRunning ? 0.52 : 0.28),
                            radius: isRunning ? 7 : 4)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.38),
                               value: fraction)

                if isRunning {
                    Circle()
                        .trim(from: 0.02, to: 0.16)
                        .stroke(
                            AngularGradient(
                                colors: [.clear, tint.opacity(0.22), .white, .clear],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(reduceMotion
                                                 ? -48
                                                 : Double(tick % 120) * 9 - 90))
                        .scaleEffect(1.075)
                        .shadow(color: tint.opacity(0.55), radius: 5)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.72),
                                   value: tick)
                }

                if fraction > 0.001 && fraction < 0.999 {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .shadow(color: tint, radius: 5)
                        .offset(x: cos(radians) * radius,
                                y: sin(radians) * radius)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.38),
                                   value: fraction)
                }

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: systemImage)
                        Text(stateText.uppercased())
                    }
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint)

                    Text(timeText)
                        .font(.system(size: 31, weight: .semibold, design: .rounded))
                        .foregroundStyle(IslandVisualStyle.primaryText)
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.22),
                                   value: timeText)
                }
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(isRunning && !reduceMotion && tick.isMultiple(of: 2) ? 1.009 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.34), value: tick)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(stateText), \(timeText)"))
    }
}
