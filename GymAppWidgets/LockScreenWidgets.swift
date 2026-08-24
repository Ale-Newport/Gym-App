import WidgetKit
import SwiftUI

/// The Lock Screen and StandBy family.
///
/// One widget rather than three so the user adds "Forge" once and picks the shape that fits the
/// slot they have. Accessory widgets are rendered by the system in a vibrant, effectively
/// monochrome style, so nothing here uses colour to carry meaning: every state is spelled out in
/// text or in a glyph.
struct LockScreenWidget: Widget {
    static let kind = "ForgeLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            LockScreenWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName(Text(L("widget.lockScreen.displayName")))
        .description(Text(L("widget.lockScreen.description")))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Family switch

struct LockScreenWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            LockScreenRectangularView(entry: entry)
        case .accessoryInline:
            LockScreenInlineView(entry: entry)
        default:
            LockScreenCircularView(entry: entry)
        }
    }
}

// MARK: - Shared decisions

/// Which of the two things the Lock Screen has room for is worth showing right now.
///
/// Training wins whenever there is a plan to measure against, because that is the reason the user
/// added a gym app to their Lock Screen. Nutrition takes the slot when there is no programme, or
/// once the week's sessions are all done.
enum LockScreenSubject {
    case training(completed: Int, planned: Int)
    case nutrition(consumed: Double, target: Double)
    case none

    static func resolve(_ entry: SnapshotEntry) -> LockScreenSubject {
        let snapshot = entry.snapshot
        guard entry.isLive else { return .none }
        let weekIsCurrent = snapshot.coversWeek(of: entry.date)
        if weekIsCurrent, snapshot.plannedWorkoutsThisWeek > 0,
           snapshot.completedWorkoutsThisWeek < snapshot.plannedWorkoutsThisWeek {
            return .training(
                completed: snapshot.completedWorkoutsThisWeek,
                planned: snapshot.plannedWorkoutsThisWeek
            )
        }
        if snapshot.hasNutritionTarget, snapshot.coversDay(of: entry.date) {
            return .nutrition(consumed: snapshot.caloriesConsumed, target: snapshot.caloriesTarget)
        }
        if weekIsCurrent, snapshot.plannedWorkoutsThisWeek > 0 {
            return .training(
                completed: snapshot.completedWorkoutsThisWeek,
                planned: snapshot.plannedWorkoutsThisWeek
            )
        }
        return .none
    }

    var fraction: Double {
        switch self {
        case .training(let completed, let planned):
            planned > 0 ? min(1, Double(completed) / Double(planned)) : 0
        case .nutrition(let consumed, let target):
            target > 0 ? min(1, max(0, consumed / target)) : 0
        case .none:
            0
        }
    }
}

// MARK: - Circular

/// A completion ring: the week's sessions, or the day's calories once training is done.
struct LockScreenCircularView: View {
    let entry: SnapshotEntry

    private var subject: LockScreenSubject { .resolve(entry) }

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Gauge(value: subject.fraction) {
                Image(systemName: symbolName)
            } currentValueLabel: {
                Text(centerText)
                    .font(.widgetNumeric(13, weight: .semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .gaugeStyle(.accessoryCircularCapacity)
        }
        .widgetURL(destination)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var symbolName: String {
        switch subject {
        case .training: "figure.strengthtraining.traditional"
        case .nutrition: "fork.knife"
        case .none: "flame"
        }
    }

    private var centerText: String {
        switch subject {
        case .training(let completed, let planned):
            L("widget.week.progress", completed, planned)
        case .nutrition:
            L("widget.percent", Int((subject.fraction * 100).rounded()))
        case .none:
            "—"
        }
    }

    private var destination: URL {
        switch subject {
        case .training: WidgetLink.todayWorkout
        case .nutrition: WidgetLink.nutritionToday
        case .none: WidgetLink.todayWorkout
        }
    }

    private var accessibilityLabel: String {
        switch subject {
        case .training(let completed, let planned):
            L("widget.accessibility.weekProgress", completed, planned)
        case .nutrition(let consumed, let target):
            L("widget.accessibility.calories", WidgetFormat.whole(consumed), WidgetFormat.whole(target))
        case .none:
            L("widget.unavailable.title")
        }
    }
}

// MARK: - Rectangular

/// The next session, or what is left of today's energy budget.
struct LockScreenRectangularView: View {
    let entry: SnapshotEntry

    private var snapshot: SharedSnapshot { entry.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(overline)
                .font(.widgetOverline)
                .textCase(.uppercase)
                .widgetAccentable()
                .lineLimit(1)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(destination)
        .accessibilityElement(children: .combine)
    }

    private var overline: String {
        if !entry.isLive { return L("app.name") }
        if snapshot.hasActiveWorkout { return L("widget.inProgress.label") }
        if snapshot.hasPlannedWorkout { return L("widget.nextUp") }
        if snapshot.isRestDay { return L("widget.restDay.title") }
        if snapshot.hasNutritionTarget, snapshot.coversDay(of: entry.date) {
            return L("widget.nutrition.today")
        }
        return L("app.name")
    }

    private var title: String {
        if !entry.isLive { return L("widget.unavailable.title") }
        if snapshot.hasActiveWorkout {
            return snapshot.activeWorkoutTitle ?? L("widget.workout.generic")
        }
        if snapshot.hasPlannedWorkout {
            return snapshot.nextWorkoutTitle ?? L("widget.workout.generic")
        }
        if snapshot.hasNutritionTarget, snapshot.coversDay(of: entry.date) {
            return snapshot.isOverCalories
                ? L("widget.calories.over", WidgetFormat.whole(abs(snapshot.caloriesRemaining)))
                : L("widget.calories.remaining", WidgetFormat.whole(max(0, snapshot.caloriesRemaining)))
        }
        if snapshot.isRestDay { return L("widget.restDay.message") }
        return L("widget.noProgram.title")
    }

    private var detail: String? {
        if !entry.isLive { return L("widget.unavailable.message") }
        if snapshot.hasActiveWorkout { return nil }
        if snapshot.hasPlannedWorkout {
            var parts: [String] = []
            if snapshot.nextWorkoutExerciseCount > 0 {
                parts.append(LPlural("widget.exercises", snapshot.nextWorkoutExerciseCount))
            }
            if snapshot.nextWorkoutEstimatedMinutes > 0 {
                parts.append(L("widget.minutes", snapshot.nextWorkoutEstimatedMinutes))
            }
            let line = parts.joined(separator: " · ")
            return line.isEmpty ? (snapshot.focusLine.isEmpty ? nil : snapshot.focusLine) : line
        }
        if snapshot.hasNutritionTarget, snapshot.coversDay(of: entry.date) {
            return L("widget.calories.consumedOfTarget",
                     WidgetFormat.whole(snapshot.caloriesConsumed),
                     WidgetFormat.whole(snapshot.caloriesTarget))
        }
        return nil
    }

    private var destination: URL {
        if snapshot.hasActiveWorkout { return WidgetLink.resumeWorkout }
        if snapshot.hasPlannedWorkout { return WidgetLink.startWorkout }
        if snapshot.hasNutritionTarget { return WidgetLink.nutritionToday }
        return WidgetLink.todayWorkout
    }
}

// MARK: - Inline

/// One line, above the clock. Whatever is most time-sensitive right now.
struct LockScreenInlineView: View {
    let entry: SnapshotEntry

    private var snapshot: SharedSnapshot { entry.snapshot }

    var body: some View {
        Label {
            Text(summary)
        } icon: {
            Image(systemName: symbolName)
        }
        .widgetURL(destination)
        .accessibilityLabel(Text(summary))
    }

    private var summary: String {
        guard entry.isLive else { return L("widget.unavailable.title") }
        if snapshot.hasActiveWorkout { return L("widget.inline.active") }
        if snapshot.hasPlannedWorkout {
            return L("widget.inline.next", snapshot.nextWorkoutTitle ?? L("widget.workout.generic"))
        }
        if snapshot.isRestDay { return L("widget.restDay.title") }
        if snapshot.hasNutritionTarget, snapshot.coversDay(of: entry.date) {
            return snapshot.isOverCalories
                ? L("widget.calories.over", WidgetFormat.whole(abs(snapshot.caloriesRemaining)))
                : L("widget.calories.remaining", WidgetFormat.whole(max(0, snapshot.caloriesRemaining)))
        }
        return L("widget.noProgram.title")
    }

    private var symbolName: String {
        guard entry.isLive else { return "flame" }
        if snapshot.hasActiveWorkout { return "record.circle" }
        if snapshot.hasPlannedWorkout { return "figure.strengthtraining.traditional" }
        if snapshot.isRestDay { return "moon.zzz.fill" }
        if snapshot.hasNutritionTarget { return "fork.knife" }
        return "flame"
    }

    private var destination: URL {
        if snapshot.hasActiveWorkout { return WidgetLink.resumeWorkout }
        if snapshot.hasPlannedWorkout { return WidgetLink.startWorkout }
        if snapshot.hasNutritionTarget { return WidgetLink.nutritionToday }
        return WidgetLink.todayWorkout
    }
}

// MARK: - Previews

#Preview("Circular", as: .accessoryCircular) {
    LockScreenWidget()
} timeline: {
    SnapshotEntry.placeholder()
}

#Preview("Rectangular", as: .accessoryRectangular) {
    LockScreenWidget()
} timeline: {
    SnapshotEntry.placeholder()
    SnapshotEntry(date: Date(), snapshot: .activeWorkoutSample, isLive: true)
}

#Preview("Inline", as: .accessoryInline) {
    LockScreenWidget()
} timeline: {
    SnapshotEntry.placeholder()
    SnapshotEntry(date: Date(), snapshot: .restDaySample, isLive: true)
}
