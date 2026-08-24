import WidgetKit
import SwiftUI

// MARK: - Entry

/// One rendering of the shared snapshot at a point in time.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedSnapshot
    /// `false` when the App Group container held no snapshot — the entitlement is unavailable, the
    /// app has never run, or the file was written by a newer schema. The widgets then show a neutral
    /// message instead of the sample content in `SharedSnapshot.placeholder`, because presenting
    /// invented numbers as the user's own is worse than presenting none.
    let isLive: Bool

    static func placeholder(at date: Date = Date()) -> SnapshotEntry {
        SnapshotEntry(date: date, snapshot: .placeholder, isLive: true)
    }
}

// MARK: - Provider

/// The timeline provider behind every static Forge widget.
///
/// There is one provider rather than one per widget because they all read the same ~1 KB file: the
/// snapshot is written by the app whenever anything a widget could show changes, and that write
/// reloads all timelines. The refresh policy below is therefore only a safety net for the cases the
/// app cannot signal — the clock crossing midnight, or the app not having run for a while — and it
/// is kept deliberately modest so the widget does not spend the system's refresh budget re-reading
/// a file that has not changed.
struct SnapshotProvider: TimelineProvider {

    func placeholder(in context: Context) -> SnapshotEntry {
        // The redacted skeleton the system shows while a widget is being added: sample data gives
        // it the right shape.
        .placeholder()
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        // In the widget gallery the widget must always look like a working one, so the preview path
        // uses sample data even when the App Group is empty.
        completion(context.isPreview ? .placeholder() : Self.currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = Self.currentEntry()
        let refresh = Self.nextRefresh(after: entry.date, snapshot: entry.snapshot)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    /// Reads the App Group, falling back to the placeholder marked as not live.
    static func currentEntry(now: Date = Date()) -> SnapshotEntry {
        if let snapshot = SharedSnapshotStore.shared.read() {
            return SnapshotEntry(date: now, snapshot: snapshot, isLive: true)
        }
        return SnapshotEntry(date: now, snapshot: .placeholder, isLive: false)
    }

    /// When the system should come back.
    ///
    /// Midnight is the one moment the widget's content changes without the app doing anything — the
    /// nutrition day rolls over — so it is always a candidate. A running workout gets a shorter
    /// interval so a session that finishes while the phone is locked does not leave a stale card for
    /// half an hour.
    static func nextRefresh(
        after date: Date,
        snapshot: SharedSnapshot,
        calendar: Calendar = .current
    ) -> Date {
        let interval: TimeInterval = snapshot.hasActiveWorkout ? 15 * 60 : 30 * 60
        let periodic = date.addingTimeInterval(interval)
        guard let midnight = calendar.nextDate(
            after: date,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) else {
            return periodic
        }
        return min(periodic, midnight)
    }
}

// MARK: - Derived values

/// Everything the widget views need to know that is a function of the snapshot rather than of the
/// layout. Keeping it here means the views stay declarative and the arithmetic is written once.
extension SharedSnapshot {

    // MARK: Freshness

    /// True when the snapshot was written on `date`'s calendar day.
    ///
    /// Matters for anything that resets daily. A snapshot written last night is a perfectly good
    /// source for "next workout" but says nothing about what has been eaten today, and showing
    /// yesterday's calories under today's date would be a quiet lie.
    func coversDay(of date: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(generatedAt, inSameDayAs: date)
    }

    /// True when the snapshot was written in the same week as `date`, which is what the
    /// completed-versus-planned counters are scoped to.
    func coversWeek(of date: Date, calendar: Calendar = .current) -> Bool {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return true }
        return week.contains(generatedAt)
    }

    // MARK: Training

    /// A session is worth showing when it has a name and today is not a programmed rest day.
    var hasPlannedWorkout: Bool {
        guard let title = nextWorkoutTitle, !title.isEmpty else { return false }
        return !isRestDay
    }

    /// Focus groups, trimmed to what fits on a widget.
    func focusGroups(limit: Int) -> [String] {
        Array(nextWorkoutFocus.filter { !$0.isEmpty }.prefix(limit))
    }

    /// How many focus groups were dropped by `focusGroups(limit:)`.
    func hiddenFocusCount(limit: Int) -> Int {
        max(0, nextWorkoutFocus.filter { !$0.isEmpty }.count - limit)
    }

    /// Focus groups as one line, for the tight layouts.
    var focusLine: String {
        nextWorkoutFocus.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var weekFraction: Double {
        guard plannedWorkoutsThisWeek > 0 else { return 0 }
        return min(1, Double(completedWorkoutsThisWeek) / Double(plannedWorkoutsThisWeek))
    }

    // MARK: Nutrition

    /// True when there is a real daily energy target to measure against.
    var hasNutritionTarget: Bool { nutritionEnabled && caloriesTarget > 0 }

    /// Positive when there is budget left, negative once the target is passed.
    var caloriesRemaining: Double { caloriesTarget - caloriesConsumed }

    var isOverCalories: Bool { caloriesTarget > 0 && caloriesConsumed > caloriesTarget }

    var calorieFraction: Double {
        guard caloriesTarget > 0 else { return 0 }
        return min(1, max(0, caloriesConsumed / caloriesTarget))
    }
}

// MARK: - Preview fixtures

/// Variants of `SharedSnapshot.placeholder` for the `#Preview` timelines. Each one is a state the
/// widgets have to handle correctly, so they are worth being able to look at side by side.
extension SharedSnapshot {

    /// Mid-session: the small and medium training widgets swap to an elapsed timer.
    static var activeWorkoutSample: SharedSnapshot {
        var snapshot = SharedSnapshot.placeholder
        snapshot.hasActiveWorkout = true
        snapshot.activeWorkoutTitle = "Upper Body A"
        snapshot.activeWorkoutStartedAt = Date().addingTimeInterval(-22 * 60)
        return snapshot
    }

    /// A programmed rest day.
    static var restDaySample: SharedSnapshot {
        var snapshot = SharedSnapshot.placeholder
        snapshot.isRestDay = true
        snapshot.nextWorkoutTitle = nil
        snapshot.nextWorkoutFocus = []
        return snapshot
    }

    /// Onboarded but with no programme and no nutrition targets yet.
    static var emptyPlanSample: SharedSnapshot {
        var snapshot = SharedSnapshot()
        snapshot.generatedAt = Date()
        return snapshot
    }

    /// Past the day's energy target, which the bars flag in amber rather than clamping silently.
    static var overTargetSample: SharedSnapshot {
        var snapshot = SharedSnapshot.placeholder
        snapshot.caloriesConsumed = 2860
        snapshot.proteinConsumedG = 188
        snapshot.carbsConsumedG = 310
        snapshot.fatConsumedG = 91
        return snapshot
    }
}
