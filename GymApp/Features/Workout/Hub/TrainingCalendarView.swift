import SwiftData
import SwiftUI

/// The training calendar: a week strip for "what is left of this week" and a month grid for the
/// longer view.
///
/// Every day state is drawn with a distinct symbol as well as a distinct colour. That is not
/// decoration: a calendar that separates "trained" from "missed" by hue alone is unreadable to
/// roughly one man in twelve, and the legend below the grid names every state in words.
struct TrainingCalendarView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model = TrainingCalendarViewModel()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Metrics.spacing4), count: 7)

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.state {
            case .loading:
                LoadingStateView(message: L("workoutHub.calendar.loading"))
            case .failed(let message):
                ScrollView {
                    ErrorStateView(message: message, retryTitle: L("common.retry")) { reload() }
                        .readableWidth()
                }
            case .empty:
                ScrollView {
                    EmptyStateView(
                        systemImage: "calendar.badge.exclamationmark",
                        title: L("workoutHub.calendar.noProgramTitle"),
                        message: L("workoutHub.calendar.noProgramMessage")
                    ) {
                        Button(L("workoutHub.today.buildProgram")) {
                            router.workoutPath.append(WorkoutHubRoute.program)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: 320)
                    }
                    .readableWidth()
                    .screenPadding()
                }
            case .content:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $model.pendingReschedule) { plan in
            RescheduleSheet(plan: plan) { model.applyReschedule($0) }
        }
        .alert(
            L("workoutHub.error.title"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button(L("common.done")) { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
        .task { await reloadAsync() }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                weekStrip
                monthCard
                legend

                if let message = model.statusMessage {
                    InsetGroup {
                        HStack(alignment: .top, spacing: Metrics.spacing8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.appSuccess)
                                .font(.footnote)
                                .padding(.top, 2)
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Metrics.spacing8)
                            Button {
                                model.statusMessage = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                                    .minimumTapTarget()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(L("common.close")))
                        }
                    }
                }

                if let day = model.selectedDay {
                    dayDetail(day)
                }
            }
            .screenPadding()
            .padding(.bottom, Metrics.spacing32)
            .readableWidth()
        }
    }

    // MARK: Week strip

    private var weekStrip: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            SectionHeader(
                L("workoutHub.calendar.thisWeek"),
                subtitle: L("workoutHub.calendar.thisWeekSubtitle")
            )
            HStack(spacing: Metrics.spacing6) {
                ForEach(model.weekDays) { day in
                    Button {
                        select(day)
                    } label: {
                        VStack(spacing: Metrics.spacing4) {
                            Text(L(Weekday.from(day.date).shortLocalizationKey))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.appTextTertiary)
                            HubDayBadge(day: day, isSelected: isSelected(day), size: 34)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Metrics.gymTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(accessibilityLabel(for: day)))
                    .accessibilityAddTraits(isSelected(day) ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    // MARK: Month grid

    private var monthCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                HStack {
                    Button {
                        model.showMonth(offsetBy: -1)
                    } label: {
                        Image(systemName: "chevron.left").minimumTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("workoutHub.calendar.previousMonth")))

                    Spacer()

                    Button {
                        model.showCurrentMonth()
                    } label: {
                        Text(monthTitle)
                            .font(.appCardTitle)
                            .foregroundStyle(Color.appTextPrimary)
                            .frame(minHeight: Metrics.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("workoutHub.calendar.jumpToToday", monthTitle)))

                    Spacer()

                    Button {
                        model.showMonth(offsetBy: 1)
                    } label: {
                        Image(systemName: "chevron.right").minimumTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("workoutHub.calendar.nextMonth")))
                }

                HStack(spacing: Metrics.spacing4) {
                    ForEach(Weekday.orderedMondayFirst) { weekday in
                        Text(L(weekday.shortLocalizationKey))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.appTextTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .accessibilityHidden(true)

                LazyVGrid(columns: columns, spacing: Metrics.spacing8) {
                    ForEach(model.monthDays) { day in
                        Button {
                            select(day)
                        } label: {
                            HubDayBadge(day: day, isSelected: isSelected(day), size: 32)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: Metrics.minimumTapTarget)
                                .opacity(day.isInVisibleMonth ? 1 : 0.35)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(accessibilityLabel(for: day)))
                        .accessibilityAddTraits(isSelected(day) ? [.isButton, .isSelected] : .isButton)
                    }
                }

                Text(L("workoutHub.calendar.monthSummary", model.monthSessionCount))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text(L("workoutHub.calendar.legend"))
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
            FlowLayout {
                ForEach([HubDayState.completed, .planned, .missed, .rest, .inProgress], id: \.self) { state in
                    HStack(spacing: Metrics.spacing4) {
                        Image(systemName: state.symbolName ?? "circle")
                            .font(.caption2)
                            .foregroundStyle(HubDayBadge.tint(for: state))
                        Text(L(state.localizationKey))
                            .font(.caption2)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .padding(.horizontal, Metrics.spacing8)
                    .padding(.vertical, Metrics.spacing4)
                    .background(Color.appFill, in: Capsule())
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Selected day

    @ViewBuilder
    private func dayDetail(_ day: HubCalendarDay) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatter.weekdayAndDate(day.date))
                        .font(.appCardTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Metrics.spacing6) {
                        if let symbol = day.state.symbolName {
                            Image(systemName: symbol)
                                .font(.caption)
                                .foregroundStyle(HubDayBadge.tint(for: day.state))
                        }
                        Text(L(day.state.localizationKey))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }

                if let title = day.title {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !day.focusGroups.isEmpty {
                    FlowLayout {
                        ForEach(day.focusGroups, id: \.self) { group in
                            MuscleGroupBadge(group: group)
                        }
                    }
                }

                dayActions(day)
            }
        }
    }

    @ViewBuilder
    private func dayActions(_ day: HubCalendarDay) -> some View {
        switch day.state {
        case .completed, .inProgress:
            if let sessionID = day.sessionID {
                Button {
                    router.workoutPath.append(WorkoutHubRoute.session(sessionID))
                } label: {
                    Label(L("workoutHub.calendar.openSession"), systemImage: "chevron.right")
                }
                .buttonStyle(PrimaryButtonStyle())
            }

        case .missed:
            ExplanationNote(
                text: L("workoutHub.calendar.missedExplanation"),
                systemImage: "arrow.uturn.forward",
                tint: .appWarning
            )
            Button {
                model.prepareReschedule(for: day.date)
            } label: {
                Label(L("workoutHub.calendar.reschedule"), systemImage: "arrow.triangle.branch")
            }
            .buttonStyle(PrimaryButtonStyle())
            if let templateID = day.templateID {
                moveMenu(templateID: templateID)
            }

        case .planned:
            if let templateID = day.templateID {
                VStack(spacing: Metrics.spacing8) {
                    HStack(spacing: Metrics.spacing8) {
                        Button {
                            model.bringForward(templateID: templateID)
                        } label: {
                            Label(L("workoutHub.calendar.bringForward"), systemImage: "arrow.left")
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button {
                            model.postpone(templateID: templateID)
                        } label: {
                            Label(L("workoutHub.calendar.postpone"), systemImage: "arrow.right")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    moveMenu(templateID: templateID)
                    Button {
                        model.regenerate(templateID: templateID)
                    } label: {
                        Label(L("workoutHub.calendar.regenerate"), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Text(L("workoutHub.calendar.movePersists"))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .rest, .none:
            if day.date >= Calendar.current.startOfDay(for: Date()) {
                scheduleHereMenu(on: day.date)
            } else {
                Text(L("workoutHub.calendar.nothingHappened"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func moveMenu(templateID: UUID) -> some View {
        Menu {
            ForEach(Weekday.orderedMondayFirst) { weekday in
                Button(L(weekday.localizationKey)) {
                    model.move(templateID: templateID, to: weekday)
                }
            }
        } label: {
            Label(L("workoutHub.calendar.moveTo"), systemImage: "calendar.badge.clock")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appTextPrimary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Metrics.minimumTapTarget)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                        .fill(Color.appFill)
                )
        }
        .accessibilityLabel(Text(L("workoutHub.calendar.moveTo")))
    }

    /// A day with nothing on it is still actionable: any session in the program can be moved onto it.
    private func scheduleHereMenu(on date: Date) -> some View {
        let weekday = Weekday.from(date)
        return Menu {
            ForEach(model.schedulableTemplates) { option in
                Button(option.title) {
                    model.move(templateID: option.id, to: weekday)
                }
            }
        } label: {
            Label(L("workoutHub.calendar.scheduleHere"), systemImage: "plus.circle")
                .font(.headline)
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Metrics.gymTapTarget)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                        .fill(Color.appAccent)
                )
        }
        .disabled(model.schedulableTemplates.isEmpty)
        .accessibilityLabel(Text(L("workoutHub.calendar.scheduleHere")))
    }

    // MARK: - Helpers

    private var monthTitle: String {
        model.visibleMonth.formatted(.dateTime.month(.wide).year().locale(formatter.locale))
    }

    private func isSelected(_ day: HubCalendarDay) -> Bool {
        guard let selected = model.selectedDate else { return false }
        return Calendar.current.isDate(selected, inSameDayAs: day.date)
    }

    private func select(_ day: HubCalendarDay) {
        model.statusMessage = nil
        model.selectedDate = isSelected(day) ? nil : day.date
        Haptics.selectionChanged()
    }

    private func accessibilityLabel(for day: HubCalendarDay) -> String {
        var parts = [formatter.weekdayAndDate(day.date), L(day.state.localizationKey)]
        if let title = day.title { parts.append(title) }
        if day.isToday { parts.insert(L("common.today"), at: 0) }
        return parts.joined(separator: ", ")
    }

    private func reload() {
        Task { await reloadAsync() }
    }

    private func reloadAsync() async {
        await model.load(context: modelContext, catalog: environment.catalog)
    }
}

// MARK: - Day badge

/// One day, drawn as a number with its state symbol beneath it.
struct HubDayBadge: View {
    let day: HubCalendarDay
    let isSelected: Bool
    var size: CGFloat = 32

    static func tint(for state: HubDayState) -> Color {
        switch state {
        case .completed: .appSuccess
        case .inProgress: .appAccent
        case .planned: .appAccent
        case .missed: .appWarning
        case .rest: .appRecovery
        case .none: .appTextTertiary
        }
    }

    var body: some View {
        VStack(spacing: 1) {
            Text("\(day.dayNumber)")
                .font(.footnote.weight(day.isToday ? .bold : .regular))
                .foregroundStyle(day.isToday ? Color.appAccent : Color.appTextPrimary)
            if let symbol = day.state.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(Self.tint(for: day.state))
            } else {
                // Keeps every cell the same height so the grid does not jitter as months change.
                Image(systemName: "circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.clear)
            }
        }
        .frame(minWidth: size, minHeight: size)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                .fill(isSelected ? Color.appAccentMuted : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.appAccent : (day.isToday ? Color.appAccent.opacity(0.4) : .clear),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
    }
}

// MARK: - Reschedule sheet

/// Shows exactly what a reschedule would do before it does it.
///
/// The plan is never applied silently. A user whose week has been rearranged behind their back has
/// no way to tell a smart app from a broken one, so every move is listed with the sentence that
/// justifies it and the whole thing needs one deliberate confirmation.
private struct RescheduleSheet: View {
    let plan: SessionRescheduler.Plan
    let onApply: (SessionRescheduler.Plan) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing16) {
                    ExplanationNote(text: plan.summary.text, systemImage: "arrow.triangle.branch")

                    if plan.moves.isEmpty {
                        EmptyStateView(
                            systemImage: "checkmark.circle",
                            title: L("workoutHub.reschedule.nothingTitle"),
                            message: L("workoutHub.reschedule.nothingMessage")
                        )
                    } else {
                        LazyVStack(spacing: Metrics.spacing12) {
                            ForEach(plan.moves) { move in
                                Card {
                                    VStack(alignment: .leading, spacing: Metrics.spacing8) {
                                        HStack(spacing: Metrics.spacing8) {
                                            Image(systemName: move.waitsForNextWeek
                                                  ? "arrow.turn.down.right"
                                                  : (move.changesSchedule ? "arrow.right" : "checkmark"))
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(move.changesSchedule ? Color.appAccent : Color.appSuccess)
                                            Text(move.title)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(Color.appTextPrimary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Text(move.explanation.text)
                                            .font(.footnote)
                                            .foregroundStyle(Color.appTextSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }

                    Text(L("workoutHub.reschedule.footnote"))
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .screenPadding()
                .padding(.vertical, Metrics.spacing16)
                .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(L("workoutHub.reschedule.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.apply")) {
                        onApply(plan)
                        dismiss()
                    }
                    .disabled(!plan.hasChanges)
                }
            }
        }
    }
}

#Preview("Calendar") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            TrainingCalendarView()
                .navigationTitle(L("workoutHub.section.calendar"))
        }
    }
}
