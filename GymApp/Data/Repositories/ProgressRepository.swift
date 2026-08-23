import Foundation
import SwiftData

// MARK: - Aggregate value types

/// One training week, summarised.
struct WeeklyTrainingSummary: Hashable, Sendable, Identifiable {
    /// Start of the week, Monday by default. Doubles as the identity for charting.
    var weekStart: Date
    var sessionCount: Int = 0
    var tonnageKg: Double = 0
    var completedSets: Int = 0
    var plannedSets: Int = 0
    var activeSeconds: Int = 0

    var id: Date { weekStart }

    /// Fraction of the sets planned that were completed, 0…1.
    var setCompletionRate: Double {
        plannedSets > 0 ? Double(completedSets) / Double(plannedSets) : 0
    }
}

/// Hard sets per muscle group in one week, including fractional indirect credit.
struct WeeklyGroupVolume: Hashable, Sendable, Identifiable {
    var weekStart: Date
    var setsByGroup: [MuscleGroup: Double] = [:]

    var id: Date { weekStart }

    func sets(for group: MuscleGroup) -> Double { setsByGroup[group] ?? 0 }
    var totalSets: Double { setsByGroup.values.reduce(0, +) }
}

/// Planned versus actually done, over a date range.
struct AdherenceSummary: Hashable, Sendable {
    var plannedSessions: Int = 0
    var completedSessions: Int = 0
    /// Sessions the user began and did not finish.
    var abandonedSessions: Int = 0
    var plannedSets: Int = 0
    var completedSets: Int = 0

    /// Fraction of planned sessions completed, 0…1. Capped at 1 so an extra session does not report
    /// 140 % adherence, which reads as a bug rather than as enthusiasm.
    var sessionRate: Double {
        plannedSessions > 0 ? min(1, Double(completedSessions) / Double(plannedSessions)) : 0
    }

    var setRate: Double {
        plannedSets > 0 ? min(1, Double(completedSets) / Double(plannedSets)) : 0
    }
}

/// Consecutive-training figures for the progress tab.
///
/// The weekly streak is the headline number. A daily streak is a poor fit for strength training —
/// rest days are part of the programme, so a "streak" that punishes them would be encouraging the
/// wrong behaviour — but it is computed too because it is the right unit for a "three days in a row"
/// achievement.
struct TrainingStreaks: Hashable, Sendable {
    var currentWeekStreak: Int = 0
    var longestWeekStreak: Int = 0
    var currentDayStreak: Int = 0
    var longestDayStreak: Int = 0
    var lastSessionDate: Date?
}

// MARK: - Repository

/// Owns everything the Progress tab reads: body mass, personal records, wellbeing check-ins,
/// achievements, and the aggregations built on top of the session history.
///
/// The aggregations return plain value types rather than model rows so the charts can be rendered,
/// diffed and tested without a store, and so a chart never accidentally holds a live SwiftData
/// object across a context change.
@MainActor
struct ProgressRepository: Repository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Body mass

    /// Records a body-mass reading.
    ///
    /// `isFromHealthKit` matters for more than provenance: Health-sourced rows are never
    /// de-duplicated or edited by the app, because Health owns them and the app would only be
    /// fighting the next sync.
    @discardableResult
    func addBodyWeight(
        kg weightKg: Double,
        on date: Date = Date(),
        isFromHealthKit: Bool = false,
        note: String? = nil
    ) throws -> BodyWeightEntry {
        let mass = try InputValidation.bodyMass(kg: weightKg)
        let entry = BodyWeightEntry(date: date, weightKg: mass, isFromHealthKit: isFromHealthKit)
        entry.note = InputValidation.sanitisedNote(note)
        context.insert(entry)
        try persist()
        return entry
    }

    /// Readings inside `[from, to)`, oldest first — the order every chart and trend wants.
    func bodyWeightEntries(from start: Date, to end: Date) throws -> [BodyWeightEntry] {
        try fetch(FetchDescriptor<BodyWeightEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        ))
    }

    /// Every reading, oldest first.
    func allBodyWeightEntries() throws -> [BodyWeightEntry] {
        try fetch(FetchDescriptor<BodyWeightEntry>(sortBy: [SortDescriptor(\.date, order: .forward)]))
    }

    /// The most recent reading, whatever its source.
    func latestBodyWeight() throws -> BodyWeightEntry? {
        try fetchFirst(FetchDescriptor<BodyWeightEntry>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))
    }

    func deleteBodyWeight(_ entry: BodyWeightEntry) throws {
        context.delete(entry)
        try persist()
    }

    /// Removes duplicate manual readings taken on the same day, keeping the most recent.
    ///
    /// People weigh themselves twice when the first number surprises them. Two readings on one day
    /// then double that day's weight in any average that is not day-aware, which drags the trend
    /// line and, through it, the automatic calorie adjustment. Only *manual* rows are touched:
    /// several Health readings in a day are legitimate data owned by another app.
    ///
    /// Returns the number of rows removed.
    @discardableResult
    func deduplicateSameDayManualEntries(calendar: Calendar = .current) throws -> Int {
        let manual = try fetch(FetchDescriptor<BodyWeightEntry>(
            predicate: #Predicate { $0.isFromHealthKit == false },
            sortBy: [SortDescriptor(\.date, order: .forward)]
        ))
        var keeperByDay: [String: BodyWeightEntry] = [:]
        var removed = 0
        for entry in manual {
            let key = DayKey.make(from: entry.date, calendar: calendar)
            if let existing = keeperByDay[key] {
                // Later reading wins: it is the one the user was looking at when they stopped.
                let loser = existing.date <= entry.date ? existing : entry
                keeperByDay[key] = existing.date <= entry.date ? entry : existing
                context.delete(loser)
                removed += 1
            } else {
                keeperByDay[key] = entry
            }
        }
        if removed > 0 { try persist() }
        return removed
    }

    /// Body-mass readings as the trend analyser's value type, oldest first.
    ///
    /// Readings are passed through one-per-row rather than pre-averaged per day: `WeightTrendAnalyzer`
    /// owns the smoothing, and doing half of it here would make the analyser's window arithmetic
    /// depend on how the repository happened to bucket the input.
    /// Either bound may be omitted independently — "everything since January" and "everything up to
    /// the deload" are both things a chart asks for — so a missing bound becomes an open end rather
    /// than quietly widening the query to all time.
    func weightTrendPoints(from start: Date? = nil, to end: Date? = nil) throws -> [WeightTrendPoint] {
        let entries: [BodyWeightEntry]
        if start == nil, end == nil {
            entries = try allBodyWeightEntries()
        } else {
            entries = try bodyWeightEntries(from: start ?? .distantPast, to: end ?? .distantFuture)
        }
        return entries.map { WeightTrendPoint(date: $0.date, weightKg: $0.weightKg) }
    }

    // MARK: - Personal records

    /// The best value stored for each record kind on one exercise.
    func bests(forExerciseID exerciseID: String) throws -> [PersonalRecordKind: Double] {
        let records = try fetch(FetchDescriptor<PersonalRecord>(
            predicate: #Predicate { $0.exerciseID == exerciseID }
        ))
        return Self.reduceToBests(records)
    }

    /// Bests for many exercises in one fetch.
    func bests(forExerciseIDs exerciseIDs: [String]) throws -> [String: [PersonalRecordKind: Double]] {
        let ids = Array(Set(exerciseIDs))
        guard !ids.isEmpty else { return [:] }
        let records = try fetch(FetchDescriptor<PersonalRecord>(
            predicate: #Predicate { ids.contains($0.exerciseID) }
        ))
        return Dictionary(grouping: records, by: \.exerciseID).mapValues(Self.reduceToBests)
    }

    /// Stores a record the analytics engine detected.
    ///
    /// The previous best is looked up here and written into `previousValue`, which is what lets the
    /// UI say "+2.5 kg" instead of just "new record". A value that does not beat the stored best is
    /// rejected with `nil` rather than inserted: a "record" that is not a record would corrupt every
    /// delta that follows it.
    @discardableResult
    func recordPersonalRecord(
        exerciseID: String,
        exerciseName: String,
        kind: PersonalRecordKind,
        value: Double,
        repsContext: Int? = nil,
        sessionID: UUID? = nil,
        achievedAt: Date = Date()
    ) throws -> PersonalRecord? {
        try InputValidation.requireFinite(value, field: "recordValue")
        guard value > 0 else { return nil }

        let previous = try bests(forExerciseID: exerciseID)[kind]
        if let previous, value <= previous { return nil }

        let record = PersonalRecord()
        record.exerciseID = exerciseID
        record.exerciseNameSnapshot = exerciseName
        record.kind = kind
        record.value = value
        record.repsContext = repsContext.map(InputValidation.clampedReps)
        record.achievedAt = achievedAt
        record.sessionID = sessionID
        record.previousValue = previous
        context.insert(record)
        try persist()
        return record
    }

    /// Every stored record, newest first.
    func personalRecords(limit: Int = 100) throws -> [PersonalRecord] {
        var descriptor = FetchDescriptor<PersonalRecord>(
            sortBy: [SortDescriptor(\.achievedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try fetch(descriptor)
    }

    /// Records for one exercise, newest first.
    func personalRecords(forExerciseID exerciseID: String) throws -> [PersonalRecord] {
        try fetch(FetchDescriptor<PersonalRecord>(
            predicate: #Predicate { $0.exerciseID == exerciseID },
            sortBy: [SortDescriptor(\.achievedAt, order: .reverse)]
        ))
    }

    func deletePersonalRecord(_ record: PersonalRecord) throws {
        context.delete(record)
        try persist()
    }

    // MARK: - Wellbeing check-ins

    /// The check-in for a given day, if one exists.
    func checkIn(on date: Date, calendar: Calendar = .current) throws -> RecoveryEntry? {
        guard let interval = calendar.dateInterval(of: .day, for: date) else { return nil }
        let start = interval.start
        let end = interval.end
        return try fetchFirst(FetchDescriptor<RecoveryEntry>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        ))
    }

    /// Creates or updates the check-in for a day.
    ///
    /// One row per day: a check-in is a statement about how the day feels, and a second row would
    /// give the recovery engine two contradictory answers to weigh. Every field is separately
    /// optional so a user who only wants to answer "how did you sleep?" can.
    @discardableResult
    func upsertCheckIn(
        on date: Date = Date(),
        energy: Int?? = nil,
        sleepQuality: Int?? = nil,
        sleepHours: Double?? = nil,
        soreness: Int?? = nil,
        motivation: Int?? = nil,
        stress: Int?? = nil,
        soreGroups: [MuscleGroup]? = nil,
        note: String?? = nil,
        sessionID: UUID? = nil,
        calendar: Calendar = .current
    ) throws -> RecoveryEntry {
        let entry: RecoveryEntry
        if let existing = try checkIn(on: date, calendar: calendar) {
            entry = existing
        } else {
            entry = RecoveryEntry()
            entry.date = date
            context.insert(entry)
        }

        if let energy { entry.energy = energy.map(InputValidation.clampedWellbeingScore) }
        if let sleepQuality { entry.sleepQuality = sleepQuality.map(InputValidation.clampedWellbeingScore) }
        if let sleepHours { entry.sleepHours = sleepHours.map(InputValidation.clampedSleepHours) }
        if let soreness { entry.soreness = soreness.map(InputValidation.clampedWellbeingScore) }
        if let motivation { entry.motivation = motivation.map(InputValidation.clampedWellbeingScore) }
        if let stress { entry.stress = stress.map(InputValidation.clampedWellbeingScore) }
        if let soreGroups {
            var seen = Set<MuscleGroup>()
            entry.soreGroups = soreGroups.filter { seen.insert($0).inserted }
        }
        if let note { entry.note = InputValidation.sanitisedNote(note) }
        if let sessionID { entry.sessionID = sessionID }

        try persist()
        return entry
    }

    /// Recent check-ins, newest first.
    func recentCheckIns(limit: Int = 14) throws -> [RecoveryEntry] {
        var descriptor = FetchDescriptor<RecoveryEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = max(0, limit)
        return try fetch(descriptor)
    }

    /// Recent check-ins as the recovery engine's value type, newest first.
    func wellbeingSnapshots(limit: Int = 14) throws -> [WellbeingSnapshot] {
        try recentCheckIns(limit: limit).map(Self.snapshot(of:))
    }

    /// Converts one stored check-in into the value type the engines take.
    static func snapshot(of entry: RecoveryEntry) -> WellbeingSnapshot {
        WellbeingSnapshot(
            energy: entry.energy,
            sleepQuality: entry.sleepQuality,
            sleepHours: entry.sleepHours,
            soreness: entry.soreness,
            motivation: entry.motivation,
            stress: entry.stress,
            soreGroups: Set(entry.soreGroups),
            date: entry.date
        )
    }

    func deleteCheckIn(_ entry: RecoveryEntry) throws {
        context.delete(entry)
        try persist()
    }

    // MARK: - Session aggregations

    /// Completed sessions inside `[from, to)`, oldest first.
    func completedSessions(from start: Date, to end: Date) throws -> [WorkoutSession] {
        let completed = PlannedSessionStatus.completed.rawValue
        return try fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == completed && $0.startedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        ))
    }

    /// How many sessions were completed inside a range.
    func sessionCount(from start: Date, to end: Date) throws -> Int {
        let completed = PlannedSessionStatus.completed.rawValue
        return try count(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == completed && $0.startedAt >= start && $0.startedAt < end }
        ))
    }

    /// Sessions, tonnage and set counts bucketed by week, oldest week first.
    ///
    /// Weeks that contain no training are included as empty rows so a chart shows the gap instead of
    /// silently closing it — a missing week is exactly the thing the user needs to see.
    func weeklySummaries(
        from start: Date,
        to end: Date,
        calendar: Calendar = ProgressRepository.trainingCalendar()
    ) throws -> [WeeklyTrainingSummary] {
        let sessions = try completedSessions(from: start, to: end)
        var byWeek: [Date: WeeklyTrainingSummary] = [:]

        for weekStart in Self.weekStarts(from: start, to: end, calendar: calendar) {
            byWeek[weekStart] = WeeklyTrainingSummary(weekStart: weekStart)
        }
        for session in sessions {
            guard let weekStart = Self.weekStart(of: session.startedAt, calendar: calendar) else { continue }
            var summary = byWeek[weekStart] ?? WeeklyTrainingSummary(weekStart: weekStart)
            summary.sessionCount += 1
            summary.tonnageKg += session.totalVolumeKg
            summary.completedSets += session.completedSetCount
            summary.plannedSets += session.plannedSetCount
            summary.activeSeconds += session.activeSeconds
            byWeek[weekStart] = summary
        }
        return byWeek.values.sorted { $0.weekStart < $1.weekStart }
    }

    /// Sessions per week — the "workouts per week" chart.
    func workoutsPerWeek(
        from start: Date,
        to end: Date,
        calendar: Calendar = ProgressRepository.trainingCalendar()
    ) throws -> [WeeklyTrainingSummary] {
        try weeklySummaries(from: start, to: end, calendar: calendar)
    }

    /// Total tonnage per week, in kilograms.
    func weeklyTonnage(
        from start: Date,
        to end: Date,
        calendar: Calendar = ProgressRepository.trainingCalendar()
    ) throws -> [(weekStart: Date, tonnageKg: Double)] {
        try weeklySummaries(from: start, to: end, calendar: calendar)
            .map { ($0.weekStart, $0.tonnageKg) }
    }

    /// Hard sets per muscle group per week.
    ///
    /// `catalog` is required because a set's group attribution lives in the exercise metadata: one
    /// set of chin-ups is a full set of back and a fractional set of biceps, and only the catalogue
    /// knows the split. Sets belonging to an exercise the catalogue no longer ships are ignored
    /// rather than guessed at.
    func weeklySetsPerMuscleGroup(
        from start: Date,
        to end: Date,
        catalog: [String: Exercise],
        calendar: Calendar = ProgressRepository.trainingCalendar()
    ) throws -> [WeeklyGroupVolume] {
        let sessions = try completedSessions(from: start, to: end)
        var byWeek: [Date: WeeklyGroupVolume] = [:]
        for weekStart in Self.weekStarts(from: start, to: end, calendar: calendar) {
            byWeek[weekStart] = WeeklyGroupVolume(weekStart: weekStart)
        }

        for session in sessions {
            guard let weekStart = Self.weekStart(of: session.startedAt, calendar: calendar) else { continue }
            var bucket = byWeek[weekStart] ?? WeeklyGroupVolume(weekStart: weekStart)
            for record in session.exercises where !record.wasSkipped {
                guard let exercise = catalog[record.exerciseID] else { continue }
                let completed = record.completedWorkingSets.count
                guard completed > 0 else { continue }
                for (group, credit) in exercise.metadata.volumeContribution {
                    bucket.setsByGroup[group, default: 0] += credit * Double(completed)
                }
            }
            byWeek[weekStart] = bucket
        }
        return byWeek.values.sorted { $0.weekStart < $1.weekStart }
    }

    /// Planned versus completed over a range.
    ///
    /// `expectedSessionsPerWeek` comes from the active program. When it is `nil` — no program, or a
    /// purely ad-hoc trainer — adherence is measured against what the user actually started, which
    /// answers "did I finish what I began?" rather than "did I follow the plan?".
    func adherence(
        from start: Date,
        to end: Date,
        expectedSessionsPerWeek: Int? = nil,
        calendar: Calendar = ProgressRepository.trainingCalendar()
    ) throws -> AdherenceSummary {
        let allStatuses = try fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end }
        ))
        let finished = allStatuses.filter { $0.status == .completed }
        let abandoned = allStatuses.filter { $0.status == .skipped }

        var summary = AdherenceSummary()
        summary.completedSessions = finished.count
        summary.abandonedSessions = abandoned.count
        summary.plannedSets = allStatuses.reduce(0) { $0 + $1.plannedSetCount }
        summary.completedSets = allStatuses.reduce(0) { $0 + $1.completedSetCount }

        if let expectedSessionsPerWeek, expectedSessionsPerWeek > 0 {
            let weeks = max(1, Self.weekStarts(from: start, to: end, calendar: calendar).count)
            summary.plannedSessions = weeks * InputValidation.clampedDaysPerWeek(expectedSessionsPerWeek)
        } else {
            summary.plannedSessions = allStatuses.count
        }
        return summary
    }

    /// Weekly and daily training streaks.
    ///
    /// A streak is measured with a one-period grace: the current week counts even if the user has
    /// not trained *yet* this week, because it is only Monday. Without that, every streak in the app
    /// would reset at midnight on Sunday and read as a bug.
    func streaks(
        now: Date = Date(),
        calendar: Calendar = ProgressRepository.trainingCalendar()
    ) throws -> TrainingStreaks {
        let completed = PlannedSessionStatus.completed.rawValue
        let sessions = try fetch(FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == completed },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        ))
        guard !sessions.isEmpty else { return TrainingStreaks() }

        let trainedDays = Set(sessions.compactMap { calendar.dateInterval(of: .day, for: $0.startedAt)?.start })
        let trainedWeeks = Set(sessions.compactMap { Self.weekStart(of: $0.startedAt, calendar: calendar) })

        var result = TrainingStreaks()
        result.lastSessionDate = sessions.last?.startedAt
        result.longestDayStreak = Self.longestRun(of: trainedDays, step: .day, calendar: calendar)
        result.longestWeekStreak = Self.longestRun(of: trainedWeeks, step: .weekOfYear, calendar: calendar)
        result.currentDayStreak = Self.currentRun(
            of: trainedDays, endingAt: now, step: .day, calendar: calendar
        )
        result.currentWeekStreak = Self.currentRun(
            of: trainedWeeks, endingAt: now, step: .weekOfYear, calendar: calendar
        )
        return result
    }

    // MARK: - Achievements

    /// Unlocks an achievement the first time it is earned, and does nothing afterwards.
    ///
    /// Returns the new row, or `nil` when the code was already unlocked. Idempotency is the whole
    /// point: the detectors run after every session, and re-awarding "first workout" every Tuesday
    /// would be both wrong and insulting.
    @discardableResult
    func unlockIfAbsent(
        code: String,
        value: Double? = nil,
        exerciseID: String? = nil,
        at date: Date = Date()
    ) throws -> Achievement? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RepositoryError.invalidInput(ValidationIssue(field: "code", key: "validation.name.empty"))
        }
        if try isUnlocked(code: trimmed) { return nil }

        let achievement = Achievement(code: trimmed)
        achievement.unlockedAt = date
        achievement.value = value.flatMap { $0.isFinite ? $0 : nil }
        achievement.exerciseID = exerciseID
        context.insert(achievement)
        try persist()
        return achievement
    }

    func isUnlocked(code: String) throws -> Bool {
        try fetchFirst(FetchDescriptor<Achievement>(predicate: #Predicate { $0.code == code })) != nil
    }

    /// Every unlocked achievement, newest first.
    func unlockedAchievements() throws -> [Achievement] {
        try fetch(FetchDescriptor<Achievement>(sortBy: [SortDescriptor(\.unlockedAt, order: .reverse)]))
    }

    // MARK: - Calendar helpers

    /// The calendar used for every weekly bucket in the app.
    ///
    /// Forced to Monday-first regardless of locale, to match `Weekday.orderedMondayFirst` and the way
    /// training weeks are conventionally laid out. Letting the locale decide would mean a user in the
    /// United States and a user in Germany saw their identical training history bucketed differently.
    nonisolated static func trainingCalendar(base: Calendar = .current) -> Calendar {
        var calendar = base
        calendar.firstWeekday = 2
        return calendar
    }

    /// Start of the week containing `date`.
    nonisolated static func weekStart(of date: Date, calendar: Calendar) -> Date? {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start
    }

    /// Every week start between `start` and `end`, oldest first.
    nonisolated static func weekStarts(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        guard start < end, var cursor = weekStart(of: start, calendar: calendar) else { return [] }
        var result: [Date] = []
        // A hard iteration cap: ten years of weeks. A corrupt date pair must not spin forever.
        var guardCounter = 0
        while cursor < end && guardCounter < 520 {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor) else { break }
            cursor = next
            guardCounter += 1
        }
        return result
    }

    // MARK: - Private

    /// Keeps only the best value per record kind.
    ///
    /// "Best" is not always "largest": an assisted movement progresses by removing assistance, so
    /// `lightestAssistance` reduces with `min`. Getting this backwards would hand the detector a
    /// threshold that only ever loosens, and every assisted session would fire a record.
    private static func reduceToBests(_ records: [PersonalRecord]) -> [PersonalRecordKind: Double] {
        var bests: [PersonalRecordKind: Double] = [:]
        for record in records {
            if record.kind.lowerIsBetter {
                bests[record.kind] = min(bests[record.kind] ?? .greatestFiniteMagnitude, record.value)
            } else {
                bests[record.kind] = max(bests[record.kind] ?? -.greatestFiniteMagnitude, record.value)
            }
        }
        return bests
    }

    /// Longest run of consecutive periods present in `periods`.
    private static func longestRun(of periods: Set<Date>, step: Calendar.Component, calendar: Calendar) -> Int {
        guard !periods.isEmpty else { return 0 }
        let sorted = periods.sorted()
        var longest = 1
        var run = 1
        for index in 1..<sorted.count {
            let expected = calendar.date(byAdding: step, value: 1, to: sorted[index - 1])
            if let expected, calendar.isDate(expected, equalTo: sorted[index], toGranularity: step) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }
        return longest
    }

    /// Run of consecutive periods ending at, or one period before, the period containing `date`.
    ///
    /// The one-period grace is what makes "you have trained 6 weeks running" survive a Monday
    /// morning, and "3 days running" survive the hours before today's session.
    private static func currentRun(
        of periods: Set<Date>,
        endingAt date: Date,
        step: Calendar.Component,
        calendar: Calendar
    ) -> Int {
        let unit: Calendar.Component = step == .day ? .day : .weekOfYear
        guard var cursor = calendar.dateInterval(of: unit, for: date)?.start else { return 0 }
        if !periods.contains(cursor) {
            guard let previous = calendar.date(byAdding: step, value: -1, to: cursor) else { return 0 }
            cursor = previous
            guard periods.contains(cursor) else { return 0 }
        }
        var run = 0
        var guardCounter = 0
        while periods.contains(cursor) && guardCounter < 1000 {
            run += 1
            guard let previous = calendar.date(byAdding: step, value: -1, to: cursor) else { break }
            cursor = previous
            guardCounter += 1
        }
        return run
    }
}
