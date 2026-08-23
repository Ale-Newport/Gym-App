import Foundation
import SwiftData
import WidgetKit

/// Keeps the widget's snapshot file in step with the app's state.
///
/// Called after any change a widget could show: finishing a workout, logging food, saving a weight,
/// regenerating a program. Writing is cheap (a ~1 KB atomic file write) and reloading timelines is
/// throttled by the system, so calling this liberally is safe.
@MainActor
final class SharedSnapshotWriter {
    private let store = SharedSnapshotStore.shared
    private var lastWrite: Date = .distantPast

    /// Rebuilds the snapshot from the database and asks WidgetKit to refresh.
    func refresh(context: ModelContext, catalog: ExerciseCatalog?) {
        var snapshot = SharedSnapshot()
        let calendar = Calendar.current
        let now = Date()

        let settings = (try? context.fetch(FetchDescriptor<UserSettings>()))?.first
        snapshot.usesPounds = settings?.weightUnit == .pounds
        snapshot.nutritionEnabled = settings?.nutritionEnabled ?? true

        // Active or upcoming session.
        let activeStatus = PlannedSessionStatus.inProgress.rawValue
        var activeDescriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == activeStatus },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        activeDescriptor.fetchLimit = 1
        if let active = (try? context.fetch(activeDescriptor))?.first {
            snapshot.hasActiveWorkout = true
            snapshot.activeWorkoutTitle = active.titleSnapshot
            snapshot.activeWorkoutStartedAt = active.startedAt
        }

        // Week counters.
        if let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) {
            let start = weekInterval.start
            let end = weekInterval.end
            let completed = PlannedSessionStatus.completed.rawValue
            let descriptor = FetchDescriptor<WorkoutSession>(
                predicate: #Predicate {
                    $0.statusRaw == completed && $0.startedAt >= start && $0.startedAt < end
                }
            )
            let sessions = (try? context.fetch(descriptor)) ?? []
            snapshot.completedWorkoutsThisWeek = sessions.count
            snapshot.completedSetsThisWeek = sessions.reduce(0) { $0 + $1.completedSetCount }
        }

        let program = (try? context.fetch(FetchDescriptor<TrainingProgram>()))?.first { $0.isActive }
        snapshot.plannedWorkoutsThisWeek = program?.daysPerWeek ?? 0

        if let next = program?.orderedTemplates.first(where: { !$0.isRestDay }) {
            snapshot.nextWorkoutTitle = next.customTitle ?? L(next.titleKey)
            snapshot.nextWorkoutFocus = next.focusGroups.map { L($0.localizationKey) }
            snapshot.nextWorkoutExerciseCount = next.plannedExercises.count
            snapshot.nextWorkoutEstimatedMinutes = next.estimatedMinutes
        }
        snapshot.isRestDay = program?.orderedTemplates.first?.isRestDay ?? false

        // Streak.
        snapshot.currentStreakDays = Self.currentStreak(context: context, calendar: calendar, now: now)

        // Nutrition.
        if snapshot.nutritionEnabled {
            let dayKey = DayKey.today
            let entries = (try? context.fetch(
                FetchDescriptor<FoodLogEntry>(predicate: #Predicate { $0.dayKey == dayKey })
            )) ?? []
            let totals = entries.reduce(MacroNutrients.zero) { $0 + $1.macrosSnapshot }
            snapshot.caloriesConsumed = totals.kilocalories
            snapshot.proteinConsumedG = totals.proteinG
            snapshot.carbsConsumedG = totals.carbsG
            snapshot.fatConsumedG = totals.fatG

            if let target = (try? context.fetch(FetchDescriptor<DailyNutritionTarget>()))?
                .first(where: { $0.isActive }) {
                snapshot.caloriesTarget = target.kilocalories
                snapshot.proteinTargetG = target.proteinG
                snapshot.carbsTargetG = target.carbsG
                snapshot.fatTargetG = target.fatG
            }
        }

        // Body weight.
        var weightDescriptor = FetchDescriptor<BodyWeightEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        weightDescriptor.fetchLimit = 14
        let weights = (try? context.fetch(weightDescriptor)) ?? []
        snapshot.latestWeightKg = weights.first?.weightKg
        if weights.count >= 3 {
            let recent = weights.prefix(7)
            snapshot.weightTrendKg = recent.reduce(0.0) { $0 + $1.weightKg } / Double(recent.count)
        }

        snapshot.generatedAt = now
        store.write(snapshot)
        lastWrite = now
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Longest run of consecutive days, counting back from today, that contain a completed session.
    /// A single rest day does not break a streak; two consecutive missed days do.
    private static func currentStreak(context: ModelContext, calendar: Calendar, now: Date) -> Int {
        let completed = PlannedSessionStatus.completed.rawValue
        var descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == completed },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        let sessions = (try? context.fetch(descriptor)) ?? []
        guard !sessions.isEmpty else { return 0 }

        let trainedDays = Set(sessions.map { calendar.startOfDay(for: $0.startedAt) })
        var streak = 0
        var cursor = calendar.startOfDay(for: now)
        var missedInARow = 0

        while missedInARow < 2 {
            if trainedDays.contains(cursor) {
                streak += 1
                missedInARow = 0
            } else {
                missedInARow += 1
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
            if streak == 0 && missedInARow >= 2 { break }
        }
        return streak
    }
}
