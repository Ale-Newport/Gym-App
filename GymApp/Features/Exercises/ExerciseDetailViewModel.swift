import Foundation
import Observation
import SwiftData

// MARK: - Trend

/// What the strength chart is plotting.
enum ExerciseTrendMetric: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Estimated one-rep max. The fairest single number for "am I getting stronger", because it
    /// folds load and reps together instead of rewarding only one of them.
    case oneRepMax
    /// Heaviest working set of the session.
    case topSet
    /// Session tonnage for this movement.
    case volume

    var id: String { rawValue }
    var localizationKey: String { "exercises.trend.\(rawValue)" }
}

/// One session's worth of this exercise, reduced to the figures the chart plots.
struct ExerciseTrendPoint: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date
    let estimatedOneRepMaxKg: Double?
    let topSetWeightKg: Double?
    let topSetReps: Int?
    let volumeKg: Double
    let workingSets: Int

    func value(for metric: ExerciseTrendMetric) -> Double? {
        switch metric {
        case .oneRepMax: estimatedOneRepMaxKg
        case .topSet: topSetWeightKg
        case .volume: volumeKg > 0 ? volumeKg : nil
        }
    }
}

/// One plotted point. Values stay canonical (kilograms); the chart converts at the axis so a unit
/// change never has to travel back through the view model.
struct ExerciseTrendSample: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date
    let valueKg: Double
}

/// One template the user can drop this exercise into.
struct TemplateChoice: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let programTitle: String
    let exerciseCount: Int
    let isInActiveProgram: Bool
}

// MARK: - View model

/// Drives the exercise detail screen: the catalogue record, the user's opinion of it, their history
/// with it, and every action they can take on it.
///
/// The screen is read-mostly but every control writes through a repository, so the view holds no
/// SwiftData objects and never has to reason about save failures — a repository error becomes a
/// message with a retry attached.
@MainActor
@Observable
final class ExerciseDetailViewModel {

    enum Phase: Equatable {
        case loading
        case ready
        /// The id is not in the catalogue — a stale deep link, or a dataset that no longer ships it.
        case missing
        case failed(String)
    }

    /// A short-lived confirmation or failure, with an optional way forward attached.
    struct Banner: Identifiable, Equatable {
        enum Follow: Equatable {
            case none
            case openWorkoutTab
            case openActiveWorkout(UUID)
        }

        let id = UUID()
        let message: String
        var isError = false
        var follow: Follow = .none
    }

    let exerciseID: String

    private(set) var phase: Phase = .loading
    private(set) var exercise: Exercise?

    private(set) var instructions: [String] = []
    private(set) var isLoadingInstructions = true

    private(set) var isFavorite = false
    private(set) var isExcluded = false
    private(set) var feedback: ExerciseFeedback = .neutral
    private(set) var timesPerformed = 0
    private(set) var lastPerformedAt: Date?

    private(set) var history = ExerciseHistorySnapshot(exerciseID: "")
    private(set) var bests: [PersonalRecordKind: Double] = [:]
    private(set) var trend: [ExerciseTrendPoint] = []

    private(set) var alternatives: [SubstitutionCandidate] = []
    private(set) var isLoadingAlternatives = false
    private(set) var templateChoices: [TemplateChoice] = []

    var trendMetric: ExerciseTrendMetric = .oneRepMax
    var banner: Banner?

    /// How far back the detail chart looks. Sixty sessions is well over a year of training one
    /// movement twice a week, and keeps the fetch and the chart both small.
    private static let historyDepth = 60

    init(exerciseID: String) {
        self.exerciseID = exerciseID
    }

    // MARK: - Loading

    func load(
        catalog: ExerciseCatalog,
        instructionStore: ExerciseInstructionStore,
        context: ModelContext,
        language: AppLanguage
    ) async {
        guard let exercise = catalog.exercise(id: exerciseID) else {
            switch catalog.state {
            case .loaded: phase = .missing
            case .failed(let message): phase = .failed(message)
            case .idle, .loading: phase = .loading
            }
            return
        }
        self.exercise = exercise

        do {
            try loadStoredState(context: context)
            phase = .ready
        } catch {
            phase = .failed(Self.message(for: error))
            return
        }

        // Instructions live in a per-language file parsed by an actor off the main thread. They load
        // after the rest so the hero and the facts are on screen immediately.
        isLoadingInstructions = true
        instructions = await instructionStore.steps(for: exerciseID, language: language)
        isLoadingInstructions = false
    }

    /// Re-reads everything that can change while the screen is open.
    func reload(context: ModelContext) {
        do {
            try loadStoredState(context: context)
            if phase != .ready { phase = .ready }
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func loadStoredState(context: ModelContext) throws {
        let preferences = ExercisePreferenceRepository(context: context)
        if let stored = try preferences.existingPreference(for: exerciseID) {
            isFavorite = stored.isFavorite
            isExcluded = stored.isExcluded
            feedback = stored.feedback
            timesPerformed = stored.timesPerformed
            lastPerformedAt = stored.lastPerformedAt
        } else {
            isFavorite = false
            isExcluded = false
            feedback = .neutral
            timesPerformed = 0
            lastPerformedAt = nil
        }

        let workouts = WorkoutRepository(context: context)
        history = try workouts.history(forExerciseID: exerciseID, sessionLimit: Self.historyDepth)

        let progress = ProgressRepository(context: context)
        bests = try progress.bests(forExerciseID: exerciseID)

        trend = Self.makeTrend(from: history)
    }

    // MARK: - Derived history

    var hasHistory: Bool { !history.performances.isEmpty }

    /// The heaviest completed working set ever recorded, with the reps that earned it.
    var bestSet: (weightKg: Double, reps: Int)? {
        var best: (weightKg: Double, reps: Int)?
        for performance in history.performances {
            for set in performance.workingSets {
                guard let weight = set.weightKg, let reps = set.reps, weight > 0, reps > 0 else { continue }
                if weight > (best?.weightKg ?? 0) { best = (weight, reps) }
            }
        }
        return best
    }

    /// The load carried on the most recent session's top set.
    var lastLoadKg: Double? {
        history.performances.first?.topSet?.weightKg
    }

    var lastPerformanceReps: Int? {
        history.performances.first?.topSet?.reps
    }

    /// Best estimated one-rep max, preferring the stored personal record so the number on this
    /// screen and the number on the Progress tab can never disagree.
    var estimatedOneRepMaxKg: Double? {
        let stored = bests[.estimatedOneRepMax]
        let derived = history.bestEstimatedOneRepMaxKg
        switch (stored, derived) {
        case let (value?, other?): return max(value, other)
        case let (value?, nil): return value
        case let (nil, value?): return value
        default: return nil
        }
    }

    var totalVolumeKg: Double {
        history.performances.reduce(0) { $0 + $1.totalVolumeKg }
    }

    var totalSessions: Int { history.totalSessions }

    /// Oldest first, because a chart that reads right-to-left is a chart nobody reads.
    private static func makeTrend(from history: ExerciseHistorySnapshot) -> [ExerciseTrendPoint] {
        history.performances
            .sorted { $0.date < $1.date }
            .compactMap { performance in
                let working = performance.workingSets
                guard !working.isEmpty else { return nil }
                let top = working.max { ($0.weightKg ?? 0) < ($1.weightKg ?? 0) }
                return ExerciseTrendPoint(
                    // Sessions imported from a backup can arrive without an id; the timestamp is
                    // then unique enough to keep the chart's rows stable across a redraw.
                    id: performance.sessionID?.uuidString ?? String(performance.date.timeIntervalSince1970),
                    date: performance.date,
                    estimatedOneRepMaxKg: OneRepMaxCalculator.bestEstimate(from: working),
                    topSetWeightKg: top?.weightKg,
                    topSetReps: top?.reps,
                    volumeKg: performance.totalVolumeKg,
                    workingSets: working.count
                )
            }
    }

    /// The plottable points for one metric, oldest first. Sessions where the metric is meaningless
    /// — a bodyweight movement has no load — are absent rather than plotted as zero.
    func samples(for metric: ExerciseTrendMetric) -> [ExerciseTrendSample] {
        trend.compactMap { point in
            point.value(for: metric).map {
                ExerciseTrendSample(id: point.id, date: point.date, valueKg: $0)
            }
        }
    }

    /// True when the chosen metric has at least two points — one point is a dot, not a trend.
    func hasChartData(for metric: ExerciseTrendMetric) -> Bool {
        samples(for: metric).count >= 2
    }

    /// Metrics that actually carry data, so the picker never offers an empty chart.
    var availableMetrics: [ExerciseTrendMetric] {
        ExerciseTrendMetric.allCases.filter(hasChartData(for:))
    }

    // MARK: - Opinions

    func toggleFavorite(context: ModelContext) {
        perform(context: context) { repositories in
            try repositories.preferences.setFavorite(!isFavorite, forExerciseID: exerciseID)
            isFavorite.toggle()
            Haptics.tap()
            banner = Banner(message: isFavorite
                ? L("exercises.action.favorited")
                : L("exercises.action.unfavorited"))
        }
    }

    func setFeedback(_ value: ExerciseFeedback, context: ModelContext) {
        guard value != feedback else { return }
        perform(context: context) { repositories in
            try repositories.preferences.setFeedback(value, forExerciseID: exerciseID)
            feedback = value
            Haptics.selectionChanged()
            banner = Banner(message: L("exercises.action.feedbackSaved", L(value.localizationKey)))
        }
    }

    /// Excludes the exercise from everything the app chooses on the user's behalf.
    ///
    /// Written to both stores on purpose. The preference row is what the library and the scoring
    /// pass read; the profile's list is what `TrainingProfileSnapshot` carries into the programming
    /// engine. Keeping them in step here means "never program this" means the same thing to every
    /// caller, rather than depending on which of the two a given engine happens to consult.
    func toggleExcluded(context: ModelContext) {
        let newValue = !isExcluded
        perform(context: context) { repositories in
            try repositories.preferences.setExcluded(newValue, forExerciseID: exerciseID)
            if newValue {
                try repositories.profile.addExcludedExerciseID(exerciseID)
            } else {
                try repositories.profile.removeExcludedExerciseID(exerciseID)
            }
            isExcluded = newValue
            Haptics.tap()
            banner = Banner(message: newValue
                ? L("exercises.action.excluded")
                : L("exercises.action.included"))
        }
    }

    // MARK: - Adding to a session or a plan

    /// Adds the exercise to whatever "today" means right now.
    ///
    /// A workout in progress wins: the user is standing in the gym and means *this* session. With no
    /// session running the exercise goes into the plan for today — the template whose weekday
    /// matches, or the first training day of the active program — and the confirmation names the
    /// session it landed in, so the user is never left guessing where it went.
    func addToTodaysWorkout(context: ModelContext) {
        guard let exercise else { return }
        perform(context: context) { repositories in
            if let session = try repositories.workouts.inProgressSession() {
                try repositories.workouts.addExercise(
                    exercise,
                    to: session,
                    repRange: exercise.metadata.recommendedRepRange,
                    restSeconds: exercise.metadata.defaultRestSeconds
                )
                Haptics.success()
                banner = Banner(
                    message: L("exercises.action.addedToSession", exercise.name.localizedCapitalized),
                    follow: .openActiveWorkout(session.id)
                )
                return
            }

            guard let program = try repositories.programs.activeProgram(),
                  let template = Self.todaysTemplate(in: program) else {
                banner = Banner(message: L("exercises.action.noPlan"), follow: .openWorkoutTab)
                return
            }

            try repositories.programs.addExercise(
                exerciseID: exerciseID,
                to: template,
                repRange: exercise.metadata.recommendedRepRange,
                restSeconds: exercise.metadata.defaultRestSeconds
            )
            Haptics.success()
            banner = Banner(message: L(
                "exercises.action.addedToTemplate",
                exercise.name.localizedCapitalized,
                Self.title(of: template)
            ))
        }
    }

    /// Every training day the user could add this exercise to, active program first.
    func loadTemplateChoices(context: ModelContext) {
        perform(context: context) { repositories in
            let programs = try repositories.programs.allPrograms()
            templateChoices = programs.flatMap { program in
                program.orderedTemplates
                    .filter { !$0.isRestDay }
                    .map { template in
                        TemplateChoice(
                            id: template.id,
                            title: Self.title(of: template),
                            programTitle: program.title,
                            exerciseCount: template.plannedExercises.count,
                            isInActiveProgram: program.isActive
                        )
                    }
            }
            .sorted { lhs, rhs in
                if lhs.isInActiveProgram != rhs.isInActiveProgram { return lhs.isInActiveProgram }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    func addToTemplate(_ choice: TemplateChoice, context: ModelContext) {
        guard let exercise else { return }
        perform(context: context) { repositories in
            guard let template = try Self.template(withID: choice.id, using: repositories.programs) else {
                banner = Banner(message: L("exercises.action.templateGone"), isError: true)
                return
            }
            try repositories.programs.addExercise(
                exerciseID: exerciseID,
                to: template,
                repRange: exercise.metadata.recommendedRepRange,
                restSeconds: exercise.metadata.defaultRestSeconds
            )
            Haptics.success()
            banner = Banner(message: L(
                "exercises.action.addedToTemplate",
                exercise.name.localizedCapitalized,
                choice.title
            ))
        }
    }

    // MARK: - Alternatives

    /// Runs the substitution engine for this exercise.
    ///
    /// The engine indexes the whole catalogue in its initialiser, so it is built and run on a
    /// background task: nothing about finding alternatives needs the main actor, and the sheet
    /// should not wait on a thousand-record pass to draw its first frame.
    func loadAlternatives(catalog: ExerciseCatalog, context: ModelContext) async {
        guard let exercise, !isLoadingAlternatives else { return }
        isLoadingAlternatives = true
        defer { isLoadingAlternatives = false }

        let records = catalog.exercises
        let request: SubstitutionRequest
        do {
            let profileRepository = ProfileRepository(context: context)
            let profile = try profileRepository.trainingProfileSnapshot()
            let preferences = try ExercisePreferenceRepository(context: context).snapshots()
            request = SubstitutionRequest(
                original: exercise,
                reason: nil,
                availableEquipment: profile.availableEquipment,
                profile: profile,
                preferences: preferences,
                limit: 12
            )
        } catch {
            banner = Banner(message: Self.message(for: error), isError: true)
            return
        }

        alternatives = await Task.detached(priority: .userInitiated) {
            ExerciseSubstitutionEngine(catalog: records).alternatives(for: request)
        }.value
    }

    // MARK: - Support

    /// The repositories one action needs, built once per action rather than held, so the view model
    /// never outlives a model context.
    private struct Repositories {
        let preferences: ExercisePreferenceRepository
        let profile: ProfileRepository
        let workouts: WorkoutRepository
        let programs: ProgramRepository

        init(context: ModelContext) {
            preferences = ExercisePreferenceRepository(context: context)
            profile = ProfileRepository(context: context)
            workouts = WorkoutRepository(context: context)
            programs = ProgramRepository(context: context)
        }
    }

    /// Runs a store mutation and turns any failure into a message the user can act on. Every action
    /// on this screen goes through here so none of them can fail silently.
    private func perform(context: ModelContext, _ body: (Repositories) throws -> Void) {
        do {
            try body(Repositories(context: context))
        } catch {
            Haptics.error()
            banner = Banner(message: Self.message(for: error), isError: true)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? RepositoryError)?.explanation.text ?? L("common.error")
    }

    private static func title(of template: WorkoutTemplate) -> String {
        if let custom = template.customTitle, !custom.isEmpty { return custom }
        return L(template.titleKey)
    }

    /// The training day the exercise should join when no session is running.
    private static func todaysTemplate(in program: TrainingProgram) -> WorkoutTemplate? {
        let training = program.orderedTemplates.filter { !$0.isRestDay }
        let today = Weekday.from(Date())
        return training.first { $0.weekday == today } ?? training.first
    }

    private static func template(withID id: UUID, using repository: ProgramRepository) throws -> WorkoutTemplate? {
        for program in try repository.allPrograms() {
            if let match = program.templates.first(where: { $0.id == id }) { return match }
        }
        return nil
    }
}
