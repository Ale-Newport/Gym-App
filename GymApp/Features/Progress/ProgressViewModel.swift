import Foundation
import Observation
import SwiftData
import SwiftUI

// MARK: - Shared plumbing

/// Where a Progress screen is in its load cycle.
///
/// `content` and "content is empty" are deliberately separate: an empty chart after a successful
/// load is a real, designed state, not a failure, and conflating the two is how apps end up showing
/// a spinner forever to a user who simply has not trained yet.
enum ProgressLoadPhase: Equatable {
    case loading
    case content
    case failed(String)
}

/// Turns a thrown error into something a person can read.
enum ProgressFailure {
    @MainActor
    static func message(_ error: Error) -> String {
        if let repositoryError = error as? RepositoryError {
            AppLog.persistence.error("Progress load failed: \(repositoryError.diagnosticDetail ?? "-", privacy: .public)")
            return repositoryError.explanation.text
        }
        AppLog.app.error("Progress load failed: \(String(describing: error), privacy: .public)")
        return L("common.error")
    }
}

// MARK: - Row value types

/// One body-mass reading, detached from SwiftData so charts and lists never hold a live row.
struct BodyWeightRow: Identifiable, Hashable, Sendable {
    var id: UUID
    var date: Date
    var weightKg: Double
    var isFromHealthKit: Bool
    var note: String?
}

/// One stored personal record, flattened for display.
struct PersonalRecordRow: Identifiable, Hashable, Sendable {
    var id: UUID
    var exerciseID: String
    var exerciseName: String
    var kind: PersonalRecordKind
    var value: Double
    var previousValue: Double?
    var repsContext: Int?
    var achievedAt: Date

    /// Signed improvement over the record this one replaced, in the record's own unit.
    ///
    /// Inverted for `lightestAssistance`, where progress means *less*: without the flip the screen
    /// would congratulate an assisted-pull-up user with "−5 kg" and read as a regression.
    var delta: Double? {
        guard let previousValue else { return nil }
        return kind.lowerIsBetter ? previousValue - value : value - previousValue
    }
}

/// Every record held on one exercise.
struct PersonalRecordGroup: Identifiable, Hashable, Sendable {
    var id: String { exerciseID }
    var exerciseID: String
    var exerciseName: String
    var records: [PersonalRecordRow]
    var mostRecent: Date
}

/// An exercise the user has actually trained inside the selected range.
struct TrainedExercise: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var sessionCount: Int
    var lastPerformed: Date
}

/// One week of adherence, as the chart consumes it.
struct AdherenceWeek: Identifiable, Hashable, Sendable {
    var weekStart: Date
    var completedSessions: Int
    var plannedSessions: Int
    var completedSets: Int
    var plannedSets: Int

    var id: Date { weekStart }
}

/// One day of food logging measured against the target.
struct NutritionDay: Identifiable, Hashable, Sendable {
    var date: Date
    var dayKey: String
    var macros: MacroNutrients
    var entryCount: Int

    var id: String { dayKey }
    var isLogged: Bool { entryCount > 0 }
}

// MARK: - Hub

/// Feeds the Progress landing screen.
///
/// Loads the headline figures for every area of the tab in one pass, so the hub never fires eight
/// separate loads that each re-read the same session rows.
@MainActor
@Observable
final class ProgressHubViewModel {
    private(set) var phase: ProgressLoadPhase = .loading

    private(set) var sessionCount = 0
    private(set) var tonnageKg: Double = 0
    private(set) var completedSets = 0
    private(set) var activeSeconds = 0
    private(set) var streaks = TrainingStreaks()
    private(set) var adherence = AdherenceSummary()

    private(set) var weightTrendPoints: [DatedValue] = []
    private(set) var weightAnalysis = WeightTrendAnalysis()
    private(set) var latestWeightKg: Double?

    private(set) var recentRecords: [PersonalRecordRow] = []
    private(set) var recordCountInRange = 0
    private(set) var unlockedAchievements = 0
    private(set) var totalAchievements = AchievementCatalog.definitions.count
    private(set) var nutritionDaysLogged = 0
    private(set) var daysInRange = 0

    /// True once the store holds anything at all worth charting.
    private(set) var hasAnyData = false

    func load(context: ModelContext, range: ProgressRangeStore, now: Date = Date()) async {
        phase = .loading
        let progress = ProgressRepository(context: context)
        let interval = range.interval(now: now)

        do {
            // The earliest datum bounds the "All" range for every chart on the tab, so it is
            // established here, once, before anything else reads the interval.
            let allWeights = try progress.allBodyWeightEntries()
            let firstSession = try progress.completedSessions(from: .distantPast, to: .distantFuture).first
            range.earliestDataDate = [allWeights.first?.date, firstSession?.startedAt].compactMap { $0 }.min()

            let sessions = try progress.completedSessions(from: interval.start, to: interval.end)
            sessionCount = sessions.count
            tonnageKg = sessions.reduce(0) { $0 + $1.totalVolumeKg }
            completedSets = sessions.reduce(0) { $0 + $1.completedSetCount }
            activeSeconds = sessions.reduce(0) { $0 + $1.activeSeconds }
            streaks = try progress.streaks(now: now)

            let expected = try ProgramRepository(context: context).activeProgram()?.daysPerWeek
            adherence = try progress.adherence(
                from: interval.start, to: interval.end, expectedSessionsPerWeek: expected
            )

            let readings = allWeights.map { WeightTrendPoint(date: $0.date, weightKg: $0.weightKg) }
            latestWeightKg = allWeights.last?.weightKg
            // The moving average has to see every reading, not just the ones inside the range, or
            // the first week of any window would be averaged over a partial window and read low.
            weightAnalysis = await Self.analyze(readings, now: now)
            weightTrendPoints = weightAnalysis.movingAverage
                .filter { interval.contains($0.date) }
                .map { DatedValue(date: $0.date, value: $0.weightKg) }

            let records = try progress.personalRecords(limit: 200)
            let inRange = records.filter { interval.contains($0.achievedAt) }
            recordCountInRange = inRange.count
            recentRecords = Array(inRange.prefix(3)).map(Self.row(from:))

            unlockedAchievements = try progress.unlockedAchievements().count
            let days = try NutritionRangeLoader.days(context: context, interval: interval)
            nutritionDaysLogged = days.filter(\.isLogged).count
            daysInRange = days.count

            hasAnyData = !allWeights.isEmpty || firstSession != nil || nutritionDaysLogged > 0
            phase = .content
        } catch {
            phase = .failed(ProgressFailure.message(error))
        }
    }

    /// Runs the trend maths off the main actor: it is O(readings) twice over and the tab is the one
    /// place in the app where a user can hold several years of daily weigh-ins.
    nonisolated static func analyze(_ points: [WeightTrendPoint], now: Date) async -> WeightTrendAnalysis {
        await Task.detached(priority: .userInitiated) {
            WeightTrendAnalyzer.analyze(entries: points, now: now)
        }.value
    }

    static func row(from record: PersonalRecord) -> PersonalRecordRow {
        PersonalRecordRow(
            id: record.id,
            exerciseID: record.exerciseID,
            exerciseName: record.exerciseNameSnapshot,
            kind: record.kind,
            value: record.value,
            previousValue: record.previousValue,
            repsContext: record.repsContext,
            achievedAt: record.achievedAt
        )
    }
}

// MARK: - Body weight

@MainActor
@Observable
final class BodyWeightViewModel {
    private(set) var phase: ProgressLoadPhase = .loading
    private(set) var rows: [BodyWeightRow] = []
    private(set) var readings: [DatedValue] = []
    private(set) var movingAverage: [DatedValue] = []
    private(set) var analysis = WeightTrendAnalysis()
    private(set) var goalWeightKg: Double?
    private(set) var isHealthEnabled = false
    var isImporting = false
    /// Result of the last Health import, shown inline and cleared on the next import.
    var importSummary: String?

    /// Live rows kept only so a swipe-to-delete can reach the object it is deleting.
    private var models: [UUID: BodyWeightEntry] = [:]

    var latest: BodyWeightRow? { rows.last }

    func load(context: ModelContext, range: ProgressRangeStore, now: Date = Date()) async {
        phase = .loading
        let progress = ProgressRepository(context: context)
        let interval = range.interval(now: now)
        do {
            let all = try progress.allBodyWeightEntries()
            // `nil` has to keep meaning "no history anywhere". Folding the two optionals through
            // `.distantFuture` turned "no weigh-ins yet" into a real date in the far future, and
            // `interval(now:)` then clamped "All" to a single day for the whole tab.
            range.earliestDataDate = [range.earliestDataDate, all.first?.date].compactMap { $0 }.min()
            models = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

            let points = all.map { WeightTrendPoint(date: $0.date, weightKg: $0.weightKg) }
            analysis = await ProgressHubViewModel.analyze(points, now: now)

            rows = all
                .filter { interval.contains($0.date) }
                .map {
                    BodyWeightRow(
                        id: $0.id, date: $0.date, weightKg: $0.weightKg,
                        isFromHealthKit: $0.isFromHealthKit, note: $0.note
                    )
                }
            readings = rows.map { DatedValue(date: $0.date, value: $0.weightKg) }
            movingAverage = analysis.movingAverage
                .filter { interval.contains($0.date) }
                .map { DatedValue(date: $0.date, value: $0.weightKg) }

            let profileRepository = ProfileRepository(context: context)
            goalWeightKg = try profileRepository.profile().targetWeightKg
            isHealthEnabled = try profileRepository.settings().healthKitEnabled
            phase = .content
        } catch {
            phase = .failed(ProgressFailure.message(error))
        }
    }

    func delete(_ row: BodyWeightRow, context: ModelContext, range: ProgressRangeStore) async {
        guard let model = models[row.id] else { return }
        do {
            try ProgressRepository(context: context).deleteBodyWeight(model)
            await load(context: context, range: range)
        } catch {
            phase = .failed(ProgressFailure.message(error))
        }
    }

    /// Pulls body-mass samples from Health and stores the ones the app does not already hold.
    ///
    /// De-duplication is by day *and* source: Health owns its own rows, so re-importing a day that
    /// already has a Health reading would double it in every average. Manual readings are left
    /// alone — a user who weighed themselves on a different scale is entitled to keep both.
    func importFromHealth(
        service: HealthService,
        context: ModelContext,
        range: ProgressRangeStore,
        now: Date = Date()
    ) async {
        guard !isImporting else { return }
        isImporting = true
        importSummary = nil
        defer { isImporting = false }

        if service.availability != .authorized {
            guard await service.requestAuthorization() else {
                importSummary = L("progress.weight.health.denied")
                return
            }
        }

        let since = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
        let samples = await service.bodyMassSamples(since: since)
        guard !samples.isEmpty else {
            importSummary = L("progress.weight.health.nothing")
            return
        }

        do {
            let progress = ProgressRepository(context: context)
            let existing = try progress.allBodyWeightEntries()
            let takenDays = Set(
                existing.filter(\.isFromHealthKit).map { DayKey.make(from: $0.date) }
            )
            var imported = 0
            for sample in samples where !takenDays.contains(DayKey.make(from: sample.date)) {
                // A sample outside the plausible range is another app's bad data, not ours to fix.
                guard InputValidation.bodyMassKg.contains(sample.kilograms) else { continue }
                try progress.addBodyWeight(kg: sample.kilograms, on: sample.date, isFromHealthKit: true)
                imported += 1
            }
            importSummary = imported > 0
                ? L("progress.weight.health.imported", imported)
                : L("progress.weight.health.upToDate")
            await load(context: context, range: range, now: now)
        } catch {
            importSummary = ProgressFailure.message(error)
        }
    }
}

// MARK: - Body weight entry

@MainActor
@Observable
final class BodyWeightEntryViewModel {
    /// Held in the user's own unit; converted to canonical kilograms only on save.
    var displayedWeight: Double?
    var date = Date()
    var note = ""
    var errorMessage: String?
    private(set) var isSaving = false
    private(set) var lastWeightKg: Double?

    func prepare(context: ModelContext, formatter: DisplayFormatter) {
        guard displayedWeight == nil else { return }
        // Seeding with the last reading turns the common case — "same as yesterday, give or take" —
        // into two taps of the stepper rather than typing a three-digit number one-handed.
        let latest = try? ProgressRepository(context: context).latestBodyWeight()
        lastWeightKg = latest?.weightKg
        displayedWeight = latest.map { formatter.weightValue($0.weightKg) }
    }

    var canSave: Bool {
        guard let displayedWeight else { return false }
        return displayedWeight > 0 && !isSaving
    }

    /// Returns true when the entry was stored.
    func save(context: ModelContext, formatter: DisplayFormatter) -> Bool {
        guard let displayedWeight else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let kilograms = formatter.kilograms(fromDisplayed: displayedWeight)
            try ProgressRepository(context: context).addBodyWeight(
                kg: kilograms, on: date, isFromHealthKit: false,
                note: note.isEmpty ? nil : note
            )
            Haptics.success()
            errorMessage = nil
            return true
        } catch {
            Haptics.error()
            errorMessage = ProgressFailure.message(error)
            return false
        }
    }
}

// MARK: - Strength

@MainActor
@Observable
final class StrengthProgressViewModel {
    private(set) var phase: ProgressLoadPhase = .loading
    private(set) var trainedExercises: [TrainedExercise] = []
    var selectedExerciseID: String?

    private(set) var oneRepMaxPoints: [DatedValue] = []
    private(set) var topSetPoints: [DatedValue] = []
    private(set) var records: [PersonalRecordRow] = []
    private(set) var totalVolumeKg: Double = 0
    private(set) var sessionCount = 0
    private(set) var bestOneRepMaxKg: Double?
    private(set) var latestTopSetKg: Double?

    /// True when the exercise has been trained but never with a load and rep count an estimate can
    /// be built from — a timed plank, say. The screen says so rather than drawing an empty chart.
    private(set) var isUnestimable = false

    func load(context: ModelContext, range: ProgressRangeStore, now: Date = Date()) async {
        phase = .loading
        let interval = range.interval(now: now)
        do {
            let sessions = try ProgressRepository(context: context)
                .completedSessions(from: interval.start, to: interval.end)

            var counts: [String: (name: String, sessions: Set<UUID>, last: Date)] = [:]
            for session in sessions {
                for record in session.exercises where !record.wasSkipped {
                    guard record.completedWorkingSets.isEmpty == false else { continue }
                    var entry = counts[record.exerciseID]
                        ?? (record.exerciseNameSnapshot, [], session.startedAt)
                    entry.sessions.insert(session.id)
                    entry.last = max(entry.last, session.startedAt)
                    if entry.name.isEmpty { entry.name = record.exerciseNameSnapshot }
                    counts[record.exerciseID] = entry
                }
            }
            trainedExercises = counts
                .map { TrainedExercise(id: $0.key, name: $0.value.name, sessionCount: $0.value.sessions.count, lastPerformed: $0.value.last) }
                .sorted { lhs, rhs in
                    if lhs.sessionCount != rhs.sessionCount { return lhs.sessionCount > rhs.sessionCount }
                    return lhs.name < rhs.name
                }

            if let selectedExerciseID, trainedExercises.contains(where: { $0.id == selectedExerciseID }) {
                // Keep the user's choice across a range change whenever it still has data.
            } else {
                selectedExerciseID = trainedExercises.first?.id
            }
            rebuildSeries(from: sessions, context: context)
            phase = .content
        } catch {
            phase = .failed(ProgressFailure.message(error))
        }
    }

    func select(_ exerciseID: String, context: ModelContext, range: ProgressRangeStore, now: Date = Date()) async {
        selectedExerciseID = exerciseID
        do {
            let interval = range.interval(now: now)
            let sessions = try ProgressRepository(context: context)
                .completedSessions(from: interval.start, to: interval.end)
            rebuildSeries(from: sessions, context: context)
        } catch {
            phase = .failed(ProgressFailure.message(error))
        }
    }

    /// Builds the two series for the selected exercise.
    ///
    /// One point per *session*, not per set: a session's top set and its best estimate are the two
    /// numbers that describe how strong the user was that day, and plotting every set would bury
    /// them under warm-ups and back-offs.
    private func rebuildSeries(from sessions: [WorkoutSession], context: ModelContext) {
        guard let exerciseID = selectedExerciseID else {
            oneRepMaxPoints = []
            topSetPoints = []
            records = []
            totalVolumeKg = 0
            sessionCount = 0
            bestOneRepMaxKg = nil
            latestTopSetKg = nil
            isUnestimable = false
            return
        }

        let workoutRepository = WorkoutRepository(context: context)
        var estimates: [DatedValue] = []
        var topSets: [DatedValue] = []
        var volume: Double = 0
        var sessionsSeen = 0

        for session in sessions {
            let records = session.exercises.filter { $0.exerciseID == exerciseID && !$0.wasSkipped }
            guard !records.isEmpty else { continue }
            let performed = records.flatMap { $0.orderedSets.map(workoutRepository.performedSet(from:)) }
            let completed = performed.filter { $0.isCompleted && $0.kind.countsAsWorkingSet }
            guard !completed.isEmpty else { continue }

            sessionsSeen += 1
            volume += completed.reduce(0) { $0 + $1.volumeKg }
            let date = session.endedAt ?? session.startedAt

            if let heaviest = completed.compactMap(\.weightKg).max(), heaviest > 0 {
                topSets.append(DatedValue(date: date, value: heaviest))
            }
            if let estimate = OneRepMaxCalculator.bestEstimate(from: completed) {
                estimates.append(DatedValue(date: date, value: estimate))
            }
        }

        oneRepMaxPoints = estimates.sorted { $0.date < $1.date }
        topSetPoints = topSets.sorted { $0.date < $1.date }
        totalVolumeKg = volume
        sessionCount = sessionsSeen
        bestOneRepMaxKg = estimates.map(\.value).max()
        latestTopSetKg = topSetPoints.last?.value
        isUnestimable = sessionsSeen > 0 && estimates.isEmpty && topSets.isEmpty

        let stored = (try? ProgressRepository(context: context).personalRecords(forExerciseID: exerciseID)) ?? []
        self.records = stored.map(ProgressHubViewModel.row(from:))
    }
}

// MARK: - Volume

@MainActor
@Observable
final class VolumeProgressViewModel {
    private(set) var phase: ProgressLoadPhase = .loading
    private(set) var weeklyGroupVolume: [WeeklyGroupVolume] = []
    private(set) var weeklyTonnage: [DatedValue] = []
    private(set) var targets = VolumeTargets(minimum: [:], target: [:], maximum: [:], frequency: [:])
    private(set) var trainedGroups: [MuscleGroup] = []
    var selectedGroup: MuscleGroup = .chest

    /// Sets and target for the most recent complete-enough week, ordered by shortfall so the group
    /// most behind its target is the first thing the user reads.
    private(set) var latestWeek: [(group: MuscleGroup, sets: Double, target: Double)] = []
    private(set) var latestWeekStart: Date?

    func load(context: ModelContext, range: ProgressRangeStore, catalog: [String: Exercise], now: Date = Date()) async {
        phase = .loading
        let progress = ProgressRepository(context: context)
        let interval = range.weekAlignedInterval(now: now)
        do {
            weeklyGroupVolume = try progress.weeklySetsPerMuscleGroup(
                from: interval.start, to: interval.end, catalog: catalog
            )
            weeklyTonnage = try progress.weeklySummaries(from: interval.start, to: interval.end)
                .map { DatedValue(date: $0.weekStart, value: $0.tonnageKg) }

            // The reference line is the target for a *normal* week: fatigue and deload modifiers
            // describe one particular week, and using them here would make the same past week's bar
            // move against a line that shifted for reasons the chart cannot show.
            let profile = try ProfileRepository(context: context).trainingProfileSnapshot(now: now)
            targets = VolumeAllocator.targets(for: profile, recovery: RecoverySnapshot(), isDeloadWeek: false)

            let touched = weeklyGroupVolume.reduce(into: Set<MuscleGroup>()) { result, week in
                for (group, sets) in week.setsByGroup where sets > 0 { result.insert(group) }
            }
            trainedGroups = MuscleGroup.volumeTracked.filter { touched.contains($0) }
            if !trainedGroups.contains(selectedGroup) {
                selectedGroup = trainedGroups.first ?? .chest
            }

            if let last = weeklyGroupVolume.last {
                latestWeekStart = last.weekStart
                latestWeek = trainedGroups
                    .map { ($0, last.sets(for: $0), targets.target(for: $0)) }
                    .sorted { lhs, rhs in
                        let lhsShortfall = lhs.1 - lhs.2
                        let rhsShortfall = rhs.1 - rhs.2
                        if lhsShortfall != rhsShortfall { return lhsShortfall < rhsShortfall }
                        return lhs.0.rawValue < rhs.0.rawValue
                    }
            } else {
                latestWeekStart = nil
                latestWeek = []
            }
            phase = .content
        } catch {
            phase = .failed(ProgressFailure.message(error))
        }
    }

    /// Weekly sets for one group, for the focus chart.
    func series(for group: MuscleGroup) -> [DatedValue] {
        weeklyGroupVolume.map { DatedValue(date: $0.weekStart, value: $0.sets(for: group)) }
    }
}

// MARK: - Adherence

@MainActor
@Observable
final class AdherenceViewModel {
    private(set) var phase: ProgressLoadPhase = .loading
    private(set) var summary = AdherenceSummary()
    private(set) var weeks: [AdherenceWeek] = []
    private(set) var expectedSessionsPerWeek: Int?
    private(set) var nutritionDaysLogged = 0
    private(set) var daysInRange = 0
    private(set) var weighInDays = 0

    var nutritionRate: Double {
        daysInRange > 0 ? min(1, Double(nutritionDaysLogged) / Double(daysInRange)) : 0
    }

    /// The one-line message at the top of the screen.
    ///
    /// Deliberately never negative. Adherence data is at its least flattering exactly when somebody
    /// is having a hard month, and a fitness app that picks that moment to say "you failed" is one
    /// the user deletes. The worst thing this screen ever says is "every session counts".
    var encouragementKey: String {
        guard summary.completedSessions > 0 else { return "progress.adherence.encourage.start" }
        switch summary.sessionRate {
        case 0.9...: return "progress.adherence.encourage.excellent"
        case 0.7..<0.9: return "progress.adherence.encourage.strong"
        case 0.4..<0.7: return "progress.adherence.encourage.steady"
        default: return "progress.adherence.encourage.building"
        }
    }

    func load(context: ModelContext, range: ProgressRangeStore, now: Date = Date()) async {
        phase = .loading
        let progress = ProgressRepository(context: context)
        let interval = range.weekAlignedInterval(now: now)
        do {
            expectedSessionsPerWeek = try ProgramRepository(context: context).activeProgram()?.daysPerWeek
            summary = try progress.adherence(
                from: interval.start, to: interval.end, expectedSessionsPerWeek: expectedSessionsPerWeek
            )
            let summaries = try progress.weeklySummaries(from: interval.start, to: interval.end)
            weeks = summaries.map {
                AdherenceWeek(
                    weekStart: $0.weekStart,
                    completedSessions: $0.sessionCount,
                    // With no program there is no plan to measure against, so the "planned" series
                    // falls back to what the user actually did rather than inventing a quota.
                    plannedSessions: expectedSessionsPerWeek ?? $0.sessionCount,
                    completedSets: $0.completedSets,
                    plannedSets: $0.plannedSets
                )
            }

            let days = try NutritionRangeLoader.days(context: context, interval: interval)
            nutritionDaysLogged = days.filter(\.isLogged).count
            daysInRange = days.count
            let readings = try progress.bodyWeightEntries(from: interval.start, to: interval.end)
            weighInDays = Set(readings.map { DayKey.make(from: $0.date) }).count
            phase = .content
        } catch {
            phase = .failed(ProgressFailure.message(error))
        }
    }
}

// MARK: - Records

@MainActor
@Observable
final class PersonalRecordsViewModel {
    private(set) var phase: ProgressLoadPhase = .loading
    private(set) var groups: [PersonalRecordGroup] = []
    private(set) var totalRecords = 0
    var kindFilter: PersonalRecordKind?

    /// Kinds actually present in the data, so the filter never offers an empty result.
    private(set) var availableKinds: [PersonalRecordKind] = []

    func load(context: ModelContext, range: ProgressRangeStore, now: Date = Date()) async {
        phase = .loading
        let interval = range.interval(now: now)
        do {
            let stored = try ProgressRepository(context: context).personalRecords(limit: 500)
            let inRange = stored.filter { interval.contains($0.achievedAt) }
            totalRecords = inRange.count
            availableKinds = PersonalRecordKind.allCases.filter { kind in
                inRange.contains { $0.kind == kind }
            }
            if let kindFilter, !availableKinds.contains(kindFilter) { self.kindFilter = nil }

            let filtered = kindFilter.map { kind in inRange.filter { $0.kind == kind } } ?? inRange
            groups = Dictionary(grouping: filtered.map(ProgressHubViewModel.row(from:)), by: \.exerciseID)
                .map { exerciseID, rows in
                    let sorted = rows.sorted { $0.achievedAt > $1.achievedAt }
                    return PersonalRecordGroup(
                        exerciseID: exerciseID,
                        exerciseName: sorted.first?.exerciseName ?? exerciseID,
                        records: sorted,
                        mostRecent: sorted.first?.achievedAt ?? .distantPast
                    )
                }
                .sorted { $0.mostRecent > $1.mostRecent }
            phase = .content
        } catch {
            phase = .failed(ProgressFailure.message(error))
        }
    }

    func setFilter(_ kind: PersonalRecordKind?, context: ModelContext, range: ProgressRangeStore) async {
        kindFilter = kind
        await load(context: context, range: range)
    }
}

// MARK: - Nutrition

/// Reads the food log for a date range and buckets it into days.
///
/// `NutritionRepository` answers "what happened on this day?", which is the right shape for the
/// nutrition tab and the wrong shape here — a year of days would be 365 fetches. One ranged fetch
/// over the indexed `loggedAt` column replaces them.
enum NutritionRangeLoader {

    @MainActor
    static func days(
        context: ModelContext,
        interval: DateInterval,
        calendar: Calendar = .current
    ) throws -> [NutritionDay] {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<FoodLogEntry>(
            predicate: #Predicate { $0.loggedAt >= start && $0.loggedAt < end },
            sortBy: [SortDescriptor(\.loggedAt, order: .forward)]
        )
        let entries: [FoodLogEntry]
        do {
            entries = try context.fetch(descriptor)
        } catch {
            throw RepositoryError.fetchFailed(underlying: String(describing: error))
        }

        var byDay: [String: (macros: MacroNutrients, count: Int)] = [:]
        for entry in entries {
            let key = DayKey.make(from: entry.loggedAt, calendar: calendar)
            let existing = byDay[key] ?? (.zero, 0)
            byDay[key] = (existing.macros + entry.macrosSnapshot, existing.count + 1)
        }

        // Every day in the range is emitted, logged or not: a gap in the log is the single most
        // useful thing this chart can show, and skipping empty days would close it silently.
        var result: [NutritionDay] = []
        var cursor = calendar.startOfDay(for: start)
        var guardCounter = 0
        while cursor < end && guardCounter < 800 {
            let key = DayKey.make(from: cursor, calendar: calendar)
            let bucket = byDay[key] ?? (.zero, 0)
            result.append(NutritionDay(date: cursor, dayKey: key, macros: bucket.macros, entryCount: bucket.count))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            guardCounter += 1
        }
        return result
    }
}

/// The three macronutrients, as a chartable series identity.
enum MacroKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case protein
    case carbs
    case fat

    var id: String { rawValue }
    var localizationKey: String { "progress.macro.\(rawValue)" }

    /// Kilocalories per gram, using the 4/4/9 convention the rest of the app derives energy with.
    var kilocaloriesPerGram: Double {
        switch self {
        case .protein, .carbs: 4
        case .fat: 9
        }
    }

    func grams(in macros: MacroNutrients) -> Double {
        switch self {
        case .protein: macros.proteinG
        case .carbs: macros.carbsG
        case .fat: macros.fatG
        }
    }

    var color: Color {
        switch self {
        case .protein: .appAccent
        case .carbs: .appRecovery
        case .fat: .appWarning
        }
    }
}

/// One macro's energy contribution on one day.
struct MacroEnergyPoint: Identifiable, Hashable, Sendable {
    var date: Date
    var macro: MacroKind
    var kilocalories: Double
    var grams: Double

    var id: String { "\(macro.rawValue)-\(date.timeIntervalSince1970)" }
}

@MainActor
@Observable
final class NutritionProgressViewModel {
    private(set) var phase: ProgressLoadPhase = .loading
    private(set) var days: [NutritionDay] = []
    private(set) var target: MacroNutrients?
    private(set) var loggedDays: [NutritionDay] = []

    /// Averages are taken over *logged* days only. Including days with no food at all would drag
    /// the average towards zero and tell the user they are eating half of what they eat.
    var averageMacros: MacroNutrients? {
        guard !loggedDays.isEmpty else { return nil }
        let total = loggedDays.reduce(MacroNutrients.zero) { $0 + $1.macros }
        return total * (1 / Double(loggedDays.count))
    }

    var weeklyAverages: [DatedValue] {
        let calendar = ProgressRepository.trainingCalendar()
        var byWeek: [Date: (sum: Double, count: Int)] = [:]
        for day in loggedDays {
            guard let weekStart = ProgressRepository.weekStart(of: day.date, calendar: calendar) else { continue }
            let existing = byWeek[weekStart] ?? (0, 0)
            byWeek[weekStart] = (existing.sum + day.macros.kilocalories, existing.count + 1)
        }
        return byWeek.keys.sorted().map { week in
            let bucket = byWeek[week] ?? (0, 1)
            return DatedValue(date: week, value: bucket.count > 0 ? bucket.sum / Double(bucket.count) : 0)
        }
    }

    /// Daily energy split by macronutrient, for the stacked chart.
    ///
    /// Stacked in *kilocalories*, not grams: stacking grams would put a gram of fat next to a gram
    /// of carbohydrate as if they were the same thing, and the resulting total would mean nothing.
    /// In kilocalories the stack height is the day's energy, which is the number the target is set
    /// in and the one the user is trying to read.
    var macroEnergyPoints: [MacroEnergyPoint] {
        loggedDays.flatMap { day in
            MacroKind.allCases.map { macro in
                let grams = macro.grams(in: day.macros)
                return MacroEnergyPoint(
                    date: day.date,
                    macro: macro,
                    kilocalories: grams * macro.kilocaloriesPerGram,
                    grams: grams
                )
            }
        }
    }

    /// How close the average day sat to the target, as a signed kcal difference.
    var averageEnergyDelta: Double? {
        guard let target, let averageMacros, target.kilocalories > 0 else { return nil }
        return averageMacros.kilocalories - target.kilocalories
    }

    func load(context: ModelContext, range: ProgressRangeStore, now: Date = Date()) async {
        phase = .loading
        do {
            let interval = range.interval(now: now)
            days = try NutritionRangeLoader.days(context: context, interval: interval)
            loggedDays = days.filter(\.isLogged)
            target = try NutritionRepository(context: context).activeTarget()?.macros
            phase = .content
        } catch {
            phase = .failed(ProgressFailure.message(error))
        }
    }
}

// MARK: - Achievements

/// What a milestone is measured against.
enum AchievementMeasure: Hashable, Sendable {
    case sessions(Int)
    case dayStreak(Int)
    case weekStreak(Int)
    case liftKg(Double)
    case tonnageKg(Double)
    case weighIns(Int)
    case nutritionDays(Int)

    var threshold: Double {
        switch self {
        case .sessions(let value), .dayStreak(let value), .weekStreak(let value),
             .weighIns(let value), .nutritionDays(let value):
            Double(value)
        case .liftKg(let value), .tonnageKg(let value):
            value
        }
    }
}

/// One milestone the app will award.
struct AchievementDefinition: Identifiable, Hashable, Sendable {
    let code: String
    let symbolName: String
    let measure: AchievementMeasure
    let titleKey: String
    let detailKey: String

    var id: String { code }
}

/// A milestone plus the user's standing against it.
struct AchievementBadge: Identifiable, Hashable, Sendable {
    let definition: AchievementDefinition
    let currentValue: Double
    let unlockedAt: Date?

    var id: String { definition.code }
    var isUnlocked: Bool { unlockedAt != nil }

    /// 0…1 towards the threshold, for the ring on a locked badge.
    var fraction: Double {
        let threshold = definition.measure.threshold
        guard threshold > 0 else { return isUnlocked ? 1 : 0 }
        return min(1, max(0, currentValue / threshold))
    }
}

/// Everything the milestone rules are evaluated against.
struct AchievementFacts: Hashable, Sendable {
    var completedSessions = 0
    var currentDayStreak = 0
    var longestDayStreak = 0
    var currentWeekStreak = 0
    var longestWeekStreak = 0
    var heaviestLiftKg: Double = 0
    var lifetimeTonnageKg: Double = 0
    var weighInCount = 0
    var nutritionDaysLogged = 0

    func value(for measure: AchievementMeasure) -> Double {
        switch measure {
        case .sessions: Double(completedSessions)
        // Streak milestones read the *longest* run, never the current one: an award that vanishes
        // the week somebody takes a holiday is a punishment dressed as a reward.
        case .dayStreak: Double(longestDayStreak)
        case .weekStreak: Double(longestWeekStreak)
        case .liftKg: heaviestLiftKg
        case .tonnageKg: lifetimeTonnageKg
        case .weighIns: Double(weighInCount)
        case .nutritionDays: Double(nutritionDaysLogged)
        }
    }
}

/// The milestones the app ships.
///
/// Kept short and adult on purpose. Every entry marks something a lifter would actually mention out
/// loud; there is no "opened the app three times" badge, because a reward for nothing devalues the
/// ones that mean something.
enum AchievementCatalog {
    static let definitions: [AchievementDefinition] = [
        AchievementDefinition(
            code: "first_workout", symbolName: "figure.strengthtraining.traditional",
            measure: .sessions(1),
            titleKey: "achievement.firstWorkout.title", detailKey: "achievement.firstWorkout.detail"
        ),
        AchievementDefinition(
            code: "workouts_10", symbolName: "10.circle", measure: .sessions(10),
            titleKey: "achievement.sessions.title", detailKey: "achievement.sessions.detail"
        ),
        AchievementDefinition(
            code: "workouts_50", symbolName: "50.circle", measure: .sessions(50),
            titleKey: "achievement.sessions.title", detailKey: "achievement.sessions.detail"
        ),
        AchievementDefinition(
            code: "workouts_100", symbolName: "100.circle", measure: .sessions(100),
            titleKey: "achievement.sessions.title", detailKey: "achievement.sessions.detail"
        ),
        AchievementDefinition(
            code: "workouts_250", symbolName: "trophy", measure: .sessions(250),
            titleKey: "achievement.sessions.title", detailKey: "achievement.sessions.detail"
        ),
        AchievementDefinition(
            code: "days_3", symbolName: "flame", measure: .dayStreak(3),
            titleKey: "achievement.dayStreak.title", detailKey: "achievement.dayStreak.detail"
        ),
        AchievementDefinition(
            code: "streak_4", symbolName: "calendar", measure: .weekStreak(4),
            titleKey: "achievement.weekStreak.title", detailKey: "achievement.weekStreak.detail"
        ),
        AchievementDefinition(
            code: "streak_7", symbolName: "calendar.badge.checkmark", measure: .weekStreak(7),
            titleKey: "achievement.weekStreak.title", detailKey: "achievement.weekStreak.detail"
        ),
        AchievementDefinition(
            code: "streak_12", symbolName: "calendar.badge.clock", measure: .weekStreak(12),
            titleKey: "achievement.weekStreak.title", detailKey: "achievement.weekStreak.detail"
        ),
        AchievementDefinition(
            code: "first_60kg_lift", symbolName: "scalemass", measure: .liftKg(60),
            titleKey: "achievement.lift.title", detailKey: "achievement.lift.detail"
        ),
        AchievementDefinition(
            code: "first_100kg_lift", symbolName: "scalemass.fill", measure: .liftKg(100),
            titleKey: "achievement.lift.title", detailKey: "achievement.lift.detail"
        ),
        AchievementDefinition(
            code: "first_140kg_lift", symbolName: "medal", measure: .liftKg(140),
            titleKey: "achievement.lift.title", detailKey: "achievement.lift.detail"
        ),
        AchievementDefinition(
            code: "volume_100t", symbolName: "chart.bar", measure: .tonnageKg(100_000),
            titleKey: "achievement.tonnage.title", detailKey: "achievement.tonnage.detail"
        ),
        AchievementDefinition(
            code: "volume_500t", symbolName: "chart.bar.fill", measure: .tonnageKg(500_000),
            titleKey: "achievement.tonnage.title", detailKey: "achievement.tonnage.detail"
        ),
        AchievementDefinition(
            code: "weighins_30", symbolName: "figure.stand", measure: .weighIns(30),
            titleKey: "achievement.weighIns.title", detailKey: "achievement.weighIns.detail"
        ),
        AchievementDefinition(
            code: "nutrition_30", symbolName: "fork.knife", measure: .nutritionDays(30),
            titleKey: "achievement.nutritionDays.title", detailKey: "achievement.nutritionDays.detail"
        ),
    ]
}

@MainActor
@Observable
final class AchievementsViewModel {
    private(set) var phase: ProgressLoadPhase = .loading
    private(set) var badges: [AchievementBadge] = []
    private(set) var facts = AchievementFacts()

    var unlockedCount: Int { badges.filter(\.isUnlocked).count }

    /// Loads the facts, awards anything newly earned, then publishes the badges.
    ///
    /// Achievements are always measured over the whole history rather than the selected range: a
    /// lifetime milestone that disappeared when the user tapped "7D" would be nonsense.
    func load(context: ModelContext, now: Date = Date()) async {
        phase = .loading
        let progress = ProgressRepository(context: context)
        do {
            let sessions = try progress.completedSessions(from: .distantPast, to: .distantFuture)
            let streaks = try progress.streaks(now: now)
            let records = try progress.personalRecords(limit: 500)
            let weighIns = try progress.allBodyWeightEntries()
            let nutritionInterval = DateInterval(
                start: sessions.first?.startedAt ?? Calendar.current.date(byAdding: .year, value: -2, to: now) ?? now,
                end: now.addingTimeInterval(86_400)
            )
            let nutritionDays = try NutritionRangeLoader.days(context: context, interval: nutritionInterval)

            facts = AchievementFacts(
                completedSessions: sessions.count,
                currentDayStreak: streaks.currentDayStreak,
                longestDayStreak: streaks.longestDayStreak,
                currentWeekStreak: streaks.currentWeekStreak,
                longestWeekStreak: streaks.longestWeekStreak,
                heaviestLiftKg: records.filter { $0.kind == .heaviestWeight }.map(\.value).max() ?? 0,
                lifetimeTonnageKg: sessions.reduce(0) { $0 + $1.totalVolumeKg },
                weighInCount: Set(weighIns.map { DayKey.make(from: $0.date) }).count,
                nutritionDaysLogged: nutritionDays.filter(\.isLogged).count
            )

            var unlockedAt: [String: Date] = [:]
            for achievement in try progress.unlockedAchievements() {
                unlockedAt[achievement.code] = achievement.unlockedAt
            }
            for definition in AchievementCatalog.definitions {
                let value = facts.value(for: definition.measure)
                guard value >= definition.measure.threshold, unlockedAt[definition.code] == nil else { continue }
                if let awarded = try progress.unlockIfAbsent(code: definition.code, value: value, at: now) {
                    unlockedAt[definition.code] = awarded.unlockedAt
                }
            }

            badges = AchievementCatalog.definitions.map { definition in
                AchievementBadge(
                    definition: definition,
                    currentValue: facts.value(for: definition.measure),
                    unlockedAt: unlockedAt[definition.code]
                )
            }
            phase = .content
        } catch {
            phase = .failed(ProgressFailure.message(error))
        }
    }
}
