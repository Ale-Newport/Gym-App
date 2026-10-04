import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit

// MARK: - Supporting value types

/// What the user has typed for one set but not yet committed.
///
/// Drafts are held separately from `SetRecord` so an in-progress edit is never mistaken for a
/// performed set: nothing reaches the store until the user taps Complete. Every value is canonical
/// (kilograms, seconds, metres); unit conversion happens in the row, at the presentation edge.
struct SetDraft: Hashable, Sendable {
    var weightKg: Double?
    var reps: Int?
    var rir: Int?
    var durationSeconds: Int?
    var distanceMeters: Double?
}

/// A failure the user can do something about, carrying the retry that caused it.
///
/// Repository writes are the only thing here that can fail, and a failed write during a workout is
/// a lost set. So a failure is never swallowed and never merely reported: it always arrives with the
/// exact action to run again.
struct ActiveWorkoutFailure: Identifiable {
    let id = UUID()
    let message: String
    let retry: () -> Void
}

/// One record beaten during the session, ready to render.
struct SessionRecordSummary: Identifiable, Hashable {
    var id: String { exerciseID + kind.rawValue }
    let exerciseID: String
    let exerciseName: String
    let kind: PersonalRecordKind
    let value: Double
    let repsContext: Int?
    let previousValue: Double?
}

/// How this session compares with the last time the same session was performed.
struct SessionComparison: Hashable {
    let previousDate: Date
    let volumeDeltaKg: Double
    let setsDelta: Int
    let durationDeltaSeconds: Int
}

/// Everything the finish screen shows, computed once when the user asks to finish.
struct WorkoutSummary {
    var title: String
    var durationSeconds: Int
    var exercisesPerformed: Int
    var exercisesPlanned: Int
    var completedSets: Int
    var plannedSets: Int
    var totalVolumeKg: Double
    var carriesVolume: Bool
    var groupSets: [(group: MuscleGroup, sets: Double)]
    var records: [SessionRecordSummary]
    var comparison: SessionComparison?
}

/// Which modal the screen is showing. One enum rather than five booleans, because two of these
/// appearing at once is a bug rather than a state.
enum ActiveWorkoutSheet: Identifiable, Hashable {
    /// Swap the exercise held by this `ExerciseSession`.
    case substitute(UUID)
    /// Rate the calibration set just completed on this `ExerciseSession`.
    case calibrate(UUID)
    case edit
    case finish

    var id: String {
        switch self {
        case .substitute(let id): "substitute-\(id)"
        case .calibrate(let id): "calibrate-\(id)"
        case .edit: "edit"
        case .finish: "finish"
        }
    }
}

// MARK: - View model

/// Owns every piece of state the live workout screen has, and every write it makes.
///
/// Three rules shape this type:
///
/// - **Persist after every meaningful action.** A workout is logged over forty minutes on a phone
///   that may ring, lock, run out of battery or be force-quit. Every mutation goes straight through
///   `WorkoutRepository`, which commits before it returns, so the worst case is losing the number
///   the user is part-way through typing.
/// - **The view has no logic.** Progression, substitution, record detection and autoregulation are
///   engine calls; the view renders their results and reports taps back here.
/// - **Nothing fails silently.** Every repository call that can throw runs through `perform`, which
///   surfaces a retryable failure rather than leaving the user staring at a set that did not save.
@MainActor
@Observable
final class ActiveWorkoutViewModel {

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    // MARK: Identity and lifecycle state

    let workoutID: UUID
    private(set) var phase: Phase = .loading
    private(set) var session: WorkoutSession?

    /// Index into `orderedExercises`. Persisted as `resumeExerciseIndex` so a force-quit returns
    /// the user to the exercise they were on rather than to the top of the list.
    private(set) var currentIndex = 0

    /// Collapsing the animation is remembered for the length of the session only. It is a "give me
    /// more list on this screen right now" control, not a setting — a preference that outlived the
    /// workout would quietly remove the app's most useful feature.
    var isMediaCollapsed = false

    var presentedSheet: ActiveWorkoutSheet?
    var showsDiscardConfirmation = false
    var failure: ActiveWorkoutFailure?

    let restTimer = RestTimerModel()
    let holdTimer = HoldTimerModel()

    /// Shown for a couple of seconds after a rest period ends, so the end is legible even if the
    /// haptic was missed in a noisy gym.
    private(set) var restJustFinished = false

    // MARK: Derived caches

    private(set) var drafts: [UUID: SetDraft] = [:]
    private(set) var catalogByID: [String: Exercise] = [:]
    private(set) var decisions: [String: ProgressionDecision] = [:]
    private(set) var estimates: [String: LoadEstimate] = [:]
    private(set) var previousPerformance: [String: ExercisePerformance] = [:]
    private(set) var bests: [String: [PersonalRecordKind: Double]] = [:]
    /// Exercises whose first working set is a calibration set that has not been rated yet.
    private(set) var awaitingCalibration: Set<String> = []
    /// The explanation shown after a calibration verdict was applied, per exercise.
    private(set) var calibrationNotes: [String: Explanation] = [:]
    private(set) var lastCompletedSetID: UUID?
    private(set) var summary: WorkoutSummary?

    /// Exercise ids already in the session, so the substitution sheet never offers a duplicate.
    var sessionExerciseIDs: Set<String> {
        Set(orderedExercises.map(\.exerciseID))
    }

    // MARK: Injected collaborators

    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var environment: AppEnvironment?
    @ObservationIgnored private var settings: UserSettings?
    @ObservationIgnored private var equipmentProfile: EquipmentProfile?
    @ObservationIgnored private var profileSnapshot = TrainingProfileSnapshot()
    @ObservationIgnored private var increments = EquipmentIncrements.default
    @ObservationIgnored private var bodyWeightKg: Double = 75

    /// Start of the current uninterrupted foreground stretch, used to accumulate active seconds.
    @ObservationIgnored private var foregroundSince: Date?
    /// The exercise and set the running rest period belongs to, for the local notification body.
    @ObservationIgnored private var restContext: (exerciseName: String, setNumber: Int)?
    @ObservationIgnored private var restFinishedTask: Task<Void, Never>?
    @ObservationIgnored private var didDisableIdleTimer = false

    init(workoutID: UUID) {
        self.workoutID = workoutID
    }

    // MARK: - Access

    var orderedExercises: [ExerciseSession] { session?.orderedExercises ?? [] }

    var currentExercise: ExerciseSession? {
        let list = orderedExercises
        guard list.indices.contains(currentIndex) else { return list.first }
        return list[currentIndex]
    }

    func exercise(for record: ExerciseSession) -> Exercise? { catalogByID[record.exerciseID] }

    func decision(for record: ExerciseSession) -> ProgressionDecision? { decisions[record.exerciseID] }

    func estimate(for record: ExerciseSession) -> LoadEstimate? { estimates[record.exerciseID] }

    func calibrationNote(for record: ExerciseSession) -> Explanation? { calibrationNotes[record.exerciseID] }

    func lastPerformance(for record: ExerciseSession) -> ExercisePerformance? {
        previousPerformance[record.exerciseID]
    }

    func draft(for set: SetRecord) -> SetDraft { drafts[set.id] ?? SetDraft() }

    /// Whether the animation should play at all. The user can turn workout animations off in
    /// Settings; Reduce Motion is honoured separately, by the media view itself.
    var animationsEnabled: Bool { settings?.showAnimationsDuringWorkout ?? true }

    /// The ramp `LoadEstimator` suggests before the first working set of `record`.
    ///
    /// Empty for movements that carry no load and for light isolation work, where the first working
    /// set genuinely is the better warm-up.
    func warmupRamp(for record: ExerciseSession) -> [WarmupSet] {
        guard let exercise = catalogByID[record.exerciseID],
              let firstWorking = record.orderedSets.first(where: { $0.kind.countsAsWorkingSet }),
              let weight = draft(for: firstWorking).weightKg, weight > 0 else { return [] }
        return LoadEstimator.warmupSets(
            workingWeightKg: weight, exercise: exercise, increments: increments
        )
    }

    /// Sets completed across the whole session, counting working sets only — the number the
    /// progress strip and the Live Activity both report.
    var completedWorkingSets: Int {
        orderedExercises.reduce(0) { $0 + $1.completedWorkingSets.count }
    }

    var plannedWorkingSets: Int {
        orderedExercises.reduce(0) { $0 + $1.workingSets.count }
    }

    /// Seconds of training so far, excluding the time the app spent suspended.
    var activeSeconds: Int {
        let stored = session?.activeSeconds ?? 0
        guard let foregroundSince else { return stored }
        return stored + max(0, Int(Date().timeIntervalSince(foregroundSince)))
    }

    /// The next set the user is expected to log on `record` — the first incomplete one.
    func activeSet(in record: ExerciseSession) -> SetRecord? {
        record.orderedSets.first { !$0.isCompleted }
    }

    var isFinishAvailable: Bool { completedWorkingSets > 0 }

    // MARK: - Loading

    func load(context: ModelContext, environment: AppEnvironment) async {
        self.context = context
        self.environment = environment

        let workoutRepository = WorkoutRepository(context: context)
        let profileRepository = ProfileRepository(context: context)
        let preferenceRepository = ExercisePreferenceRepository(context: context)
        let progressRepository = ProgressRepository(context: context)

        do {
            guard let found = try fetchSession(context: context) else {
                phase = .failed(L("active.error.notFound"))
                return
            }
            guard found.status == .inProgress else {
                phase = .failed(L("active.error.alreadyFinished"))
                return
            }
            session = found

            let settings = try profileRepository.settings()
            self.settings = settings
            let profile = try profileRepository.profile()
            bodyWeightKg = profile.currentWeightKg
            equipmentProfile = try profileRepository.equipmentProfile()
            increments = try profileRepository.increments()
            profileSnapshot = try profileRepository.trainingProfileSnapshot()

            let exerciseIDs = found.orderedExercises.map(\.exerciseID)
            catalogByID = Dictionary(
                environment.catalog.exercises(ids: exerciseIDs).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            let histories = try workoutRepository.histories(forExerciseIDs: exerciseIDs)
            let states = try workoutRepository.progressionSnapshots(forExerciseIDs: exerciseIDs)
            bests = try progressRepository.bests(forExerciseIDs: exerciseIDs)
            for (id, history) in histories { previousPerformance[id] = history.mostRecent }

            // The estimator wants movements the user actually trains, not the whole catalogue. The
            // recently-performed list is both a good proxy for that and a single cheap query.
            let recentIDs = try preferenceRepository.recentlyPerformedIDs(limit: 40)
            let relatedHistories = try workoutRepository.histories(forExerciseIDs: recentIDs, sessionLimit: 4)

            for record in found.orderedExercises {
                guard let exercise = catalogByID[record.exerciseID] else { continue }
                let decision = ProgressionEngine.decide(ProgressionInput(
                    exercise: exercise,
                    state: states[record.exerciseID] ?? ProgressionStateSnapshot(exerciseID: record.exerciseID),
                    history: histories[record.exerciseID] ?? ExerciseHistorySnapshot(exerciseID: record.exerciseID),
                    targetRIR: record.targetRIR,
                    increments: increments,
                    strategy: settings.progressionStrategy,
                    bodyWeightKg: profile.currentWeightKg,
                    // A deload is applied when the program is generated, so a session that has
                    // already started is carrying deloaded targets. Cutting again here would take
                    // the load down twice for the same reason.
                    isDeloadWeek: false,
                    experience: profileSnapshot.experience,
                    goal: profileSnapshot.primaryGoal
                ))
                decisions[record.exerciseID] = decision

                if decision.requiresCalibration {
                    awaitingCalibration.insert(record.exerciseID)
                    estimates[record.exerciseID] = LoadEstimator.estimateStartingLoad(
                        exercise: exercise,
                        profile: profileSnapshot,
                        relatedHistories: relatedHistories,
                        catalog: environment.catalog.exercises,
                        increments: increments,
                        targetReps: decision.recommendedRepRange.upper,
                        strengthSeeds: profile.strengthSeeds
                    )
                }
            }

            seedAllDrafts()
            currentIndex = min(max(0, found.resumeExerciseIndex), max(0, found.orderedExercises.count - 1))
            phase = .ready

            restTimer.onFinished = { [weak self] in self?.handleRestFinished() }
            foregroundSince = Date()
            environment.activeWorkoutID = workoutID
            applyIdleTimerPolicy()
            startLiveActivity()
        } catch {
            AppLog.persistence.error("Active workout failed to load: \(String(describing: error), privacy: .public)")
            phase = .failed(L("active.error.load"))
        }
    }

    /// Re-runs the load after a failure. The screen always offers this rather than a dead end.
    func retryLoad() async {
        guard let context, let environment else { return }
        phase = .loading
        await load(context: context, environment: environment)
    }

    /// One targeted fetch by id.
    ///
    /// `WorkoutRepository` exposes "the session in progress" rather than "the session with this id",
    /// and the screen is always opened with an id — from a tab, a widget or a Live Activity. Rather
    /// than guess that the in-progress session is the requested one, this asks for exactly the row
    /// the caller named.
    private func fetchSession(context: ModelContext) throws -> WorkoutSession? {
        let id = workoutID
        let descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    // MARK: - Scene phase

    func handleScenePhase(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            foregroundSince = foregroundSince ?? Date()
            restTimer.refresh()
            cancelRestNotification()
            applyIdleTimerPolicy()
        case .inactive:
            break
        case .background:
            flushActiveSeconds()
            scheduleRestNotificationIfNeeded()
        @unknown default:
            break
        }
    }

    /// Banks the foreground stretch into the session. Called on background and before finishing, so
    /// the recorded duration is time spent training rather than wall-clock time since the start.
    private func flushActiveSeconds() {
        guard let session, let since = foregroundSince else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(since)))
        foregroundSince = nil
        guard elapsed > 0, let context else { return }
        try? WorkoutRepository(context: context).addActiveSeconds(elapsed, to: session)
    }

    func teardown() {
        flushActiveSeconds()
        restTimer.stop()
        holdTimer.reset()
        restFinishedTask?.cancel()
        cancelRestNotification()
        if didDisableIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = false
            didDisableIdleTimer = false
        }
    }

    private func applyIdleTimerPolicy() {
        let shouldStayAwake = settings?.keepScreenAwakeDuringWorkout ?? false
        guard shouldStayAwake != didDisableIdleTimer else { return }
        UIApplication.shared.isIdleTimerDisabled = shouldStayAwake
        didDisableIdleTimer = shouldStayAwake
    }

    // MARK: - Navigation

    func select(index: Int) {
        let list = orderedExercises
        guard list.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        holdTimer.reset()
        persistResumeIndex()
        updateLiveActivity()
    }

    func goToNextExercise() { select(index: currentIndex + 1) }
    func goToPreviousExercise() { select(index: currentIndex - 1) }

    private func persistResumeIndex() {
        guard let session, let context else { return }
        try? WorkoutRepository(context: context).setResumeIndex(currentIndex, on: session)
    }

    // MARK: - Drafts

    private func seedAllDrafts() {
        for record in orderedExercises {
            for set in record.orderedSets { seedDraft(for: set, in: record) }
        }
    }

    /// Pre-fills a row so the common case — the app's recommendation is right — is a single tap.
    ///
    /// Priority is: what the user already logged, then what the plan asked for, then what the
    /// progression engine recommends, then what they did last time. Only when all four are empty is
    /// the field left blank, which is the honest answer for a movement with no history.
    private func seedDraft(for set: SetRecord, in record: ExerciseSession) {
        let mode = record.trackingMode
        let decision = decisions[record.exerciseID]
        let previousTop = previousPerformance[record.exerciseID]?.topSet
        var draft = SetDraft()

        if mode.usesWeight {
            draft.weightKg = set.weightKg
                ?? set.targetWeightKg
                ?? decision?.recommendedWeightKg
                ?? estimates[record.exerciseID]?.weightKg
                ?? previousTop?.weightKg
        }
        if mode.usesReps {
            draft.reps = set.reps
                ?? set.targetReps
                ?? decision?.recommendedRepRange.upper
                ?? previousTop?.reps
        }
        if mode.usesDuration {
            let prescribed = decision.flatMap { decisionValue -> Int? in
                guard let exercise = catalogByID[record.exerciseID] else { return nil }
                return ProgressionEngine.prescribedSeconds(from: decisionValue, for: exercise)?.upper
            }
            draft.durationSeconds = set.durationSeconds
                ?? set.targetDurationSeconds
                ?? prescribed
                ?? previousTop?.durationSeconds
        }
        if mode.usesDistance {
            draft.distanceMeters = set.distanceMeters ?? previousTop?.distanceMeters
        }
        draft.rir = set.rir ?? decision?.targetRIR ?? record.targetRIR
        drafts[set.id] = draft
    }

    func updateDraft(_ set: SetRecord, _ mutate: (inout SetDraft) -> Void) {
        var draft = drafts[set.id] ?? SetDraft()
        mutate(&draft)
        drafts[set.id] = draft
    }

    /// The load step this exercise's equipment actually offers, used by the row's ± buttons.
    func loadStepKg(for record: ExerciseSession) -> Double {
        guard let exercise = catalogByID[record.exerciseID] else { return 2.5 }
        let step = LoadRounding.increment(for: exercise.metadata.loadability, profile: increments)
        return step > 0 ? step : 2.5
    }

    // MARK: - Set logging

    func completeSet(_ set: SetRecord) {
        guard let record = set.exerciseSession, let context else { return }
        let mode = record.trackingMode
        // A hold still running is the number the user means; bank it before writing.
        if holdTimer.isRunning(for: set.id) {
            let held = holdTimer.stop()
            updateDraft(set) { $0.durationSeconds = held }
        }
        let draft = draft(for: set)
        let repository = WorkoutRepository(context: context)
        let setNumber = set.setIndex + 1

        let saved = perform("active.error.save") { [weak self] in
            guard let self else { return }
            try repository.completeSet(
                set,
                weightKg: mode.usesWeight ? draft.weightKg : nil,
                reps: mode.usesReps ? draft.reps : nil,
                rir: self.recordsEffort(mode) ? draft.rir : nil,
                durationSeconds: mode.usesDuration ? draft.durationSeconds : nil,
                distanceMeters: mode.usesDistance ? draft.distanceMeters : nil
            )
        }
        guard saved else { return }

        Haptics.setCompleted()
        lastCompletedSetID = set.id
        holdTimer.reset()
        markRecords(on: record, repository: repository)
        persistResumeIndex()

        // A calibration verdict has to come before the rest timer: the answer decides what the next
        // set weighs, and asking after two minutes of rest is asking too late to be useful.
        if awaitingCalibration.contains(record.exerciseID), set.kind.countsAsWorkingSet {
            presentedSheet = .calibrate(record.id)
        } else if settings?.restTimerAutoStart ?? true, activeSet(in: record) != nil || nextExerciseExists {
            startRest(seconds: record.restSeconds, exerciseName: record.exerciseNameSnapshot, setNumber: setNumber)
        }
        updateLiveActivity()
    }

    private var nextExerciseExists: Bool { currentIndex + 1 < orderedExercises.count }

    /// RIR is asked for on everything except pure cardio, where "reps in reserve" has no meaning.
    /// On a hold it reads as "how many more seconds could you have kept it", which is exactly the
    /// signal the recovery and autoregulation engines want.
    private func recordsEffort(_ mode: TrackingMode) -> Bool { mode != .distanceAndDuration }

    /// Flags any personal record this exercise's work has now beaten.
    ///
    /// Detection runs against the bests captured when the screen opened, which cannot change while
    /// the session is running — nothing else writes records. The `PersonalRecord` rows themselves
    /// are only written when the workout is saved, so an abandoned session never leaves a record
    /// behind.
    private func markRecords(on record: ExerciseSession, repository: WorkoutRepository) {
        guard let exercise = catalogByID[record.exerciseID] else { return }
        let detected = PersonalRecordDetector.detect(
            performance: repository.performance(from: record),
            exercise: exercise,
            existing: bests[record.exerciseID] ?? [:]
        )
        guard !detected.isEmpty else { return }
        let ordered = record.orderedSets
        for entry in detected {
            guard let index = entry.setIndex, ordered.indices.contains(index) else { continue }
            let target = ordered[index]
            var kinds = target.achievedRecordKinds
            guard !kinds.contains(entry.kind) else { continue }
            kinds.append(entry.kind)
            try? repository.setAchievedRecords(kinds, on: target)
        }
    }

    func undoLastCompletion() {
        guard let context,
              let setID = lastCompletedSetID,
              let set = orderedExercises.flatMap(\.orderedSets).first(where: { $0.id == setID }),
              set.isCompleted else { return }
        let repository = WorkoutRepository(context: context)
        guard perform("active.error.save", { try repository.uncompleteSet(set) }) else { return }
        try? repository.setAchievedRecords([], on: set)
        lastCompletedSetID = nil
        restTimer.stop()
        cancelRestNotification()
        Haptics.tap()
        updateLiveActivity()
    }

    func uncomplete(_ set: SetRecord) {
        guard let context else { return }
        let repository = WorkoutRepository(context: context)
        guard perform("active.error.save", { try repository.uncompleteSet(set) }) else { return }
        try? repository.setAchievedRecords([], on: set)
        if lastCompletedSetID == set.id { lastCompletedSetID = nil }
        Haptics.tap()
        updateLiveActivity()
    }

    func addSet(to record: ExerciseSession, kind: SetKind = .working) {
        guard let context else { return }
        let repository = WorkoutRepository(context: context)
        var created: SetRecord?
        guard perform("active.error.save", {
            created = try repository.addSet(to: record, kind: kind)
        }) else { return }
        if let created { seedDraft(for: created, in: record) }
        Haptics.tap()
        updateLiveActivity()
    }

    func removeSet(_ set: SetRecord) {
        guard let context else { return }
        let repository = WorkoutRepository(context: context)
        let id = set.id
        guard perform("active.error.save", { try repository.removeSet(set) }) else { return }
        drafts[id] = nil
        if lastCompletedSetID == id { lastCompletedSetID = nil }
        Haptics.tap()
        updateLiveActivity()
    }

    /// Toggles a row between warm-up and working.
    ///
    /// Warm-ups are excluded from weekly volume and from progression, so the distinction has to be
    /// real in the store rather than a label in the UI. `WorkoutRepository` has no call that changes
    /// a set's kind, and the obvious workaround — add a replacement row, delete the original — would
    /// move set 1 to the end of the exercise, because sets are appended. So the kind is changed in
    /// place and committed through the repository's own save path, which is also what keeps the
    /// session's cached working-set counters honest.
    func toggleWarmup(_ set: SetRecord) {
        guard let context, let session, !set.isCompleted else { return }
        let repository = WorkoutRepository(context: context)
        let previousKind = set.kind
        set.kind = previousKind == .warmup ? .working : .warmup

        let working = session.orderedExercises.flatMap(\.workingSets)
        session.plannedSetCount = working.count
        session.completedSetCount = working.filter(\.isCompleted).count

        guard perform("active.error.save", { try repository.persist() }) else {
            set.kind = previousKind
            return
        }
        Haptics.selectionChanged()
        updateLiveActivity()
    }

    // MARK: - Rest

    func startRest(seconds: Int, exerciseName: String, setNumber: Int) {
        restJustFinished = false
        restFinishedTask?.cancel()
        restContext = (exerciseName, setNumber)
        restTimer.start(seconds: seconds)
        updateLiveActivity()
    }

    /// Starts rest for the current exercise using its own prescribed rest — the manual "start rest"
    /// control, for the user who wants a breather without having logged a set.
    func startRestForCurrentExercise() {
        guard let record = currentExercise else { return }
        let setNumber = (activeSet(in: record)?.setIndex ?? record.orderedSets.count) + 1
        startRest(seconds: record.restSeconds, exerciseName: record.exerciseNameSnapshot, setNumber: setNumber)
    }

    func adjustRest(by delta: Int) {
        guard restTimer.isRunning else { return }
        restTimer.adjust(by: delta)
        Haptics.tap()
        updateLiveActivity()
    }

    func skipRest() {
        restTimer.skip()
        restJustFinished = false
        cancelRestNotification()
        Haptics.tap()
        updateLiveActivity()
    }

    private func handleRestFinished() {
        if settings?.restTimerHapticsEnabled ?? true { Haptics.restFinished() }
        if settings?.restTimerSoundEnabled ?? true { RestAlertSound.play() }
        restJustFinished = true
        updateLiveActivity()
        restFinishedTask?.cancel()
        restFinishedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            self.restJustFinished = false
        }
    }

    /// Hands the countdown to the system when the app leaves the screen, so the user gets told their
    /// rest is over even with the phone in a pocket.
    private func scheduleRestNotificationIfNeeded() {
        guard restTimer.isRunning,
              let context = restContext,
              let settings, settings.notificationsEnabled, settings.restTimerNotificationEnabled,
              let service = environment?.notificationService else { return }
        let remaining = TimeInterval(restTimer.remainingSeconds)
        Task { await service.scheduleRestTimerCompletion(
            in: remaining,
            exerciseName: context.exerciseName,
            setNumber: context.setNumber
        ) }
    }

    private func cancelRestNotification() {
        guard let service = environment?.notificationService else { return }
        Task { await service.cancel(category: .restTimer) }
    }

    // MARK: - Calibration

    /// Applies the user's verdict on a calibration set to the rest of the exercise.
    ///
    /// The multipliers live on `CalibrationFeedback`, and `ProgressionEngine.applyCalibration` also
    /// guarantees the result moves at least one selectable step — otherwise a 5 % nudge on a coarse
    /// dumbbell ladder rounds straight back onto the load the user just told us was wrong.
    func applyCalibration(_ feedback: CalibrationFeedback, to record: ExerciseSession) {
        defer { presentedSheet = nil }
        awaitingCalibration.remove(record.exerciseID)
        guard let exercise = catalogByID[record.exerciseID] else { return }

        let attempted = record.orderedSets.last(where: { $0.isCompleted })?.weightKg
            ?? record.orderedSets.first.map { draft(for: $0).weightKg } ?? nil

        guard exercise.metadata.loadability.carriesExternalLoad, let attempted, attempted > 0 else {
            // Nothing to move on an unloadable movement; record the verdict as an explanation so the
            // screen still tells the user their answer was heard.
            calibrationNotes[record.exerciseID] = Explanation(
                "active.calibration.noted", [L(feedback.localizationKey)]
            )
            return
        }

        let adjusted = ProgressionEngine.applyCalibration(
            feedback,
            attemptedWeightKg: attempted,
            loadability: exercise.metadata.loadability,
            increments: increments
        )

        for set in record.orderedSets where !set.isCompleted {
            updateDraft(set) { $0.weightKg = adjusted }
        }

        let formatter = displayFormatter
        if abs(adjusted - attempted) < 0.01 {
            calibrationNotes[record.exerciseID] = Explanation(
                "active.calibration.held", [formatter.weight(attempted)]
            )
        } else {
            calibrationNotes[record.exerciseID] = Explanation(
                "active.calibration.adjusted",
                [formatter.weight(attempted), formatter.weight(adjusted), L(feedback.localizationKey)]
            )
        }
        Haptics.success()

        if settings?.restTimerAutoStart ?? true {
            let setNumber = (activeSet(in: record)?.setIndex ?? record.orderedSets.count) + 1
            startRest(seconds: record.restSeconds, exerciseName: record.exerciseNameSnapshot, setNumber: setNumber)
        }
    }

    /// The load a given verdict would produce, so the calibration sheet can show the number rather
    /// than only the adjective. `nil` for movements with no selectable load.
    func previewCalibration(_ feedback: CalibrationFeedback, for record: ExerciseSession) -> Double? {
        guard let exercise = catalogByID[record.exerciseID],
              exercise.metadata.loadability.carriesExternalLoad,
              let attempted = record.orderedSets.last(where: { $0.isCompleted })?.weightKg,
              attempted > 0 else { return nil }
        return ProgressionEngine.applyCalibration(
            feedback,
            attemptedWeightKg: attempted,
            loadability: exercise.metadata.loadability,
            increments: increments
        )
    }

    /// A formatter that follows the user's stored units. The view has one from the environment; the
    /// view model needs its own to build stored explanations.
    var displayFormatter: DisplayFormatter {
        DisplayFormatter(settings: settings, locale: LocalizationManager.shared.current.locale)
    }

    // MARK: - Structure changes

    func substitute(_ record: ExerciseSession, with exercise: Exercise, reason: SubstitutionReason?) {
        guard let context else { return }
        let repository = WorkoutRepository(context: context)
        let removedIDs = record.orderedSets.map(\.id)

        guard perform("active.error.save", {
            try repository.substitute(record, with: exercise, reason: reason)
        }) else { return }

        // The new movement's numbers have nothing to do with the old one's, so every cached
        // decision, target and draft for this slot is rebuilt from scratch.
        catalogByID[exercise.id] = exercise
        for id in removedIDs { drafts[id] = nil }
        awaitingCalibration.remove(record.exerciseID)
        calibrationNotes[record.exerciseID] = nil
        refreshPlan(for: record)
        Haptics.success()
        updateLiveActivity()
    }

    /// Recomputes the progression decision and drafts for one slot after it changed.
    private func refreshPlan(for record: ExerciseSession) {
        guard let context, let exercise = catalogByID[record.exerciseID] else { return }
        let repository = WorkoutRepository(context: context)
        let progressRepository = ProgressRepository(context: context)
        let history = (try? repository.history(forExerciseID: record.exerciseID))
            ?? ExerciseHistorySnapshot(exerciseID: record.exerciseID)
        let state = (try? repository.progressionSnapshots(forExerciseIDs: [record.exerciseID]))?[record.exerciseID]
            ?? ProgressionStateSnapshot(exerciseID: record.exerciseID)

        let decision = ProgressionEngine.decide(ProgressionInput(
            exercise: exercise,
            state: state,
            history: history,
            targetRIR: record.targetRIR,
            increments: increments,
            strategy: settings?.progressionStrategy ?? .doubleProgression,
            bodyWeightKg: bodyWeightKg,
            isDeloadWeek: false,
            experience: profileSnapshot.experience,
            goal: profileSnapshot.primaryGoal
        ))
        decisions[record.exerciseID] = decision
        previousPerformance[record.exerciseID] = history.mostRecent
        bests[record.exerciseID] = (try? progressRepository.bests(forExerciseID: record.exerciseID)) ?? [:]

        if decision.requiresCalibration {
            awaitingCalibration.insert(record.exerciseID)
            estimates[record.exerciseID] = LoadEstimator.estimateStartingLoad(
                exercise: exercise,
                profile: profileSnapshot,
                relatedHistories: [:],
                catalog: environment?.catalog.exercises ?? [],
                increments: increments,
                targetReps: decision.recommendedRepRange.upper,
                strengthSeeds: []
            )
        }
        for set in record.orderedSets { seedDraft(for: set, in: record) }
    }

    func setSkipped(_ skipped: Bool, on record: ExerciseSession) {
        guard let context else { return }
        let repository = WorkoutRepository(context: context)
        guard perform("active.error.save", { try repository.setSkipped(skipped, on: record) }) else { return }
        Haptics.selectionChanged()
        updateLiveActivity()
    }

    func moveExercises(from source: IndexSet, to destination: Int) {
        guard let context, let session else { return }
        let repository = WorkoutRepository(context: context)
        guard perform("active.error.save", {
            try repository.moveExercises(in: session, fromOffsets: source, toOffset: destination)
        }) else { return }
        currentIndex = min(currentIndex, max(0, orderedExercises.count - 1))
        persistResumeIndex()
        Haptics.selectionChanged()
    }

    @discardableResult
    func addExercise(_ exercise: Exercise) -> ExerciseSession? {
        guard let context, let session else { return nil }
        let repository = WorkoutRepository(context: context)
        let decision = decisions[exercise.id]
        let targetRIR = profileSnapshot.defaultTargetRIR
        var created: ExerciseSession?
        guard perform("active.error.save", {
            created = try repository.addExercise(
                exercise,
                to: session,
                sets: decision?.recommendedSets ?? 3,
                repRange: exercise.metadata.recommendedRepRange,
                restSeconds: exercise.metadata.defaultRestSeconds,
                targetRIR: targetRIR
            )
        }) else { return nil }
        catalogByID[exercise.id] = exercise
        if let created { refreshPlan(for: created) }
        Haptics.success()
        updateLiveActivity()
        return created
    }

    func removeExercise(_ record: ExerciseSession) {
        guard let context, let session else { return }
        let repository = WorkoutRepository(context: context)
        let removedIDs = record.orderedSets.map(\.id)
        guard perform("active.error.save", {
            try repository.removeExercise(record, from: session)
        }) else { return }
        for id in removedIDs { drafts[id] = nil }
        currentIndex = min(currentIndex, max(0, orderedExercises.count - 1))
        persistResumeIndex()
        Haptics.tap()
        updateLiveActivity()
    }

    /// Applies a mid-session structural change to the routine as well as to today.
    ///
    /// Only asked about for adding and removing an exercise, because those are the changes that
    /// genuinely recur. A set added because today felt good is autoregulation, not a routine change,
    /// and prompting for it would train the user to dismiss the question without reading it.
    func propagateToRoutine(_ change: RoutineChange) {
        guard let context, let session, let templateID = session.templateID else { return }
        let programRepository = ProgramRepository(context: context)
        _ = perform("active.error.save") {
            guard let program = try programRepository.activeProgram(),
                  let template = program.templates.first(where: { $0.id == templateID }) else { return }
            switch change {
            case .addExercise(let exerciseID, let sets, let repRange, let restSeconds, let targetRIR):
                _ = try programRepository.addExercise(
                    exerciseID: exerciseID,
                    to: template,
                    sets: sets,
                    repRange: repRange,
                    restSeconds: restSeconds,
                    targetRIR: targetRIR
                )
            case .removeExercise(let exerciseID):
                guard let planned = template.orderedExercises.first(where: { $0.exerciseID == exerciseID })
                else { return }
                try programRepository.removeExercise(planned)
            case .substitute(let fromID, let toID):
                guard let planned = template.orderedExercises.first(where: { $0.exerciseID == fromID })
                else { return }
                try programRepository.substitute(planned, withExerciseID: toID)
            }
            try programRepository.recordEngineChange(
                to: program, reason: Explanation("active.routine.changedDuringSession")
            )
        }
    }

    /// The routine-level edits the screen may propagate.
    enum RoutineChange {
        case addExercise(exerciseID: String, sets: Int, repRange: RepRange, restSeconds: Int, targetRIR: Int)
        case removeExercise(exerciseID: String)
        case substitute(fromExerciseID: String, toExerciseID: String)
    }

    /// Marks a piece of equipment permanently unavailable after a swap.
    ///
    /// Only ever called when the user explicitly chose "my gym does not have this" — the default is
    /// always "just for today", which touches nothing outside this session.
    func removeEquipmentFromGym(_ equipment: Equipment) {
        guard let context, let profile = equipmentProfile else { return }
        let profileRepository = ProfileRepository(context: context)
        var remaining = Set(profile.availableEquipment)
        remaining.remove(equipment)
        _ = perform("active.error.save") {
            try profileRepository.updateEquipment(availableEquipment: remaining)
        }
        equipmentProfile = try? profileRepository.equipmentProfile()
    }

    // MARK: - Finishing

    /// Builds the summary the finish screen shows. Pure reading — nothing is written until the user
    /// confirms, so backing out of the finish sheet leaves the session exactly as it was.
    func prepareSummary() {
        guard let session, let context else { return }
        let repository = WorkoutRepository(context: context)

        var records: [SessionRecordSummary] = []
        var groupSets: [MuscleGroup: Double] = [:]
        var completed = 0
        var planned = 0
        var performed = 0
        var volume = 0.0
        var carriesVolume = false

        for record in session.orderedExercises {
            let working = record.workingSets
            planned += working.count
            let done = working.filter(\.isCompleted)
            guard !record.wasSkipped, !done.isEmpty else { continue }
            performed += 1
            completed += done.count
            volume += done.reduce(0) { $0 + $1.volumeKg }

            guard let exercise = catalogByID[record.exerciseID] else { continue }
            if exercise.metadata.trackingMode.contributesToTonnage { carriesVolume = true }
            for (group, credit) in exercise.metadata.volumeContribution {
                groupSets[group, default: 0] += credit * Double(done.count)
            }
            for detected in PersonalRecordDetector.detect(
                performance: repository.performance(from: record),
                exercise: exercise,
                existing: bests[record.exerciseID] ?? [:]
            ) {
                records.append(SessionRecordSummary(
                    exerciseID: record.exerciseID,
                    exerciseName: record.exerciseNameSnapshot,
                    kind: detected.kind,
                    value: detected.value,
                    repsContext: detected.repsContext,
                    previousValue: detected.previousValue
                ))
            }
        }

        summary = WorkoutSummary(
            title: session.titleSnapshot,
            durationSeconds: activeSeconds,
            exercisesPerformed: performed,
            exercisesPlanned: session.exercises.count,
            completedSets: completed,
            plannedSets: planned,
            totalVolumeKg: volume,
            carriesVolume: carriesVolume,
            groupSets: groupSets.sorted { $0.value > $1.value }.map { (group: $0.key, sets: $0.value) },
            records: records,
            comparison: comparison(for: session, volume: volume, sets: completed, repository: repository)
        )
    }

    /// The last time this same session was performed, for a like-for-like comparison.
    ///
    /// Matched on the template when there is one and on the snapshotted title when there is not, so
    /// an ad-hoc "Push A" the user repeats still lines up with its predecessor.
    private func comparison(
        for session: WorkoutSession,
        volume: Double,
        sets: Int,
        repository: WorkoutRepository
    ) -> SessionComparison? {
        guard let previous = (try? repository.recentSessions(limit: 40))?.first(where: { candidate in
            guard candidate.id != session.id else { return false }
            if let templateID = session.templateID { return candidate.templateID == templateID }
            return candidate.titleSnapshot == session.titleSnapshot
        }) else { return nil }

        return SessionComparison(
            previousDate: previous.endedAt ?? previous.startedAt,
            volumeDeltaKg: volume - previous.totalVolumeKg,
            setsDelta: sets - previous.completedSetCount,
            durationDeltaSeconds: activeSeconds - previous.activeSeconds
        )
    }

    /// Closes the session out: writes the outcome, learns from it, and tells the rest of the system.
    ///
    /// Returns the adjustments the autoregulation engine proposed, so the finish screen can show the
    /// user what changed rather than making the next session mysteriously different.
    func finishWorkout(effort: SessionEffortFeedback) async -> [AutoregulationAdjustment] {
        guard let session, let context, let environment else { return [] }
        flushActiveSeconds()

        let repository = WorkoutRepository(context: context)
        let progressRepository = ProgressRepository(context: context)
        let preferenceRepository = ExercisePreferenceRepository(context: context)

        guard perform("active.error.finish", {
            try repository.finish(session, effort: effort, activeSeconds: session.activeSeconds)
        }) else { return [] }

        // Records first: they are the part of the session the user cares most about keeping.
        for record in summary?.records ?? [] {
            _ = try? progressRepository.recordPersonalRecord(
                exerciseID: record.exerciseID,
                exerciseName: record.exerciseName,
                kind: record.kind,
                value: record.value,
                repsContext: record.repsContext,
                sessionID: session.id,
                achievedAt: session.endedAt ?? Date()
            )
        }

        let performedIDs = session.orderedExercises
            .filter { !$0.wasSkipped && !$0.completedWorkingSets.isEmpty }
            .map(\.exerciseID)
        try? preferenceRepository.recordPerformed(exerciseIDs: performedIDs)

        await Task.yield()
        let outcome = repository.sessionOutcome(for: session, catalog: catalogByID)
        updateProgressionStates(for: performedIDs, repository: repository)

        await Task.yield()
        let adjustments = autoregulate(
            outcome: outcome,
            repository: repository,
            progressRepository: progressRepository
        )
        persistAdjustments(adjustments)

        if let settings, settings.healthKitEnabled, settings.healthKitWriteWorkouts {
            await environment.healthService.saveWorkout(
                start: session.startedAt,
                end: session.endedAt ?? Date()
            )
        }

        environment.snapshotWriter.refresh(context: context, catalog: environment.catalog)
        environment.liveActivityService.end()
        environment.activeWorkoutID = nil
        teardown()
        Haptics.success()
        return adjustments
    }

    /// Recomputes each exercise's progression state now that this session is part of its history, so
    /// the next session opens with a prescription that already knows what just happened.
    private func updateProgressionStates(for exerciseIDs: [String], repository: WorkoutRepository) {
        guard !exerciseIDs.isEmpty else { return }
        let histories = (try? repository.histories(forExerciseIDs: exerciseIDs)) ?? [:]
        let states = (try? repository.progressionSnapshots(forExerciseIDs: exerciseIDs)) ?? [:]

        for exerciseID in Set(exerciseIDs) {
            guard let exercise = catalogByID[exerciseID] else { continue }
            let decision = ProgressionEngine.decide(ProgressionInput(
                exercise: exercise,
                state: states[exerciseID] ?? ProgressionStateSnapshot(exerciseID: exerciseID),
                history: histories[exerciseID] ?? ExerciseHistorySnapshot(exerciseID: exerciseID),
                targetRIR: profileSnapshot.defaultTargetRIR,
                increments: increments,
                strategy: settings?.progressionStrategy ?? .doubleProgression,
                bodyWeightKg: bodyWeightKg,
                isDeloadWeek: false,
                experience: profileSnapshot.experience,
                goal: profileSnapshot.primaryGoal
            ))
            try? repository.apply(decision.updatedState, decision: decision.explanation)
        }
    }

    private func autoregulate(
        outcome: SessionOutcome,
        repository: WorkoutRepository,
        progressRepository: ProgressRepository
    ) -> [AutoregulationAdjustment] {
        guard settings?.autoRegulationEnabled ?? true else { return [] }

        let recent = (try? repository.recentSessions(limit: 12)) ?? []
        var outcomes = recent
            .filter { $0.id != outcome.sessionID }
            .map { repository.sessionOutcome(for: $0, catalog: catalogByID) }
        outcomes.append(outcome)

        let wellbeing = (try? progressRepository.wellbeingSnapshots(limit: 14)) ?? []
        let recovery = RecoveryEngine.snapshot(
            sessions: outcomes, wellbeing: wellbeing, profile: profileSnapshot
        )
        let targets = VolumeAllocator.targets(for: profileSnapshot, recovery: recovery, isDeloadWeek: false)
        return AutoregulationEngine.adjustments(
            after: outcome,
            recovery: recovery,
            targets: targets,
            profile: profileSnapshot,
            catalog: catalogByID
        )
    }

    /// Writes the structural half of the engine's proposals onto the template this session came
    /// from. Load changes are not written here: those live in `ProgressionState`, which
    /// `updateProgressionStates` has already brought up to date.
    private func persistAdjustments(_ adjustments: [AutoregulationAdjustment]) {
        guard !adjustments.isEmpty,
              let context,
              let templateID = session?.templateID else { return }
        let programRepository = ProgramRepository(context: context)
        guard let program = try? programRepository.activeProgram(),
              let template = program.templates.first(where: { $0.id == templateID }) else { return }

        let planned = programRepository.generatedSession(from: template)
        let adjusted = AutoregulationEngine.apply(adjustments, to: planned, catalog: catalogByID)
        var changed = false

        for slot in adjusted.exercises {
            guard let row = template.orderedExercises.first(where: { $0.orderIndex == slot.orderIndex }),
                  row.targetSets != slot.sets || row.restSeconds != slot.restSeconds else { continue }
            try? programRepository.updatePrescription(of: row, sets: slot.sets, restSeconds: slot.restSeconds)
            changed = true
        }
        if changed {
            _ = try? programRepository.recordEngineChange(
                to: program, reason: Explanation("active.autoreg.applied")
            )
        }
    }

    /// Exactly what a discard destroys, so the confirmation can say it out loud.
    var discardImpact: (sets: Int, seconds: Int) {
        (completedWorkingSets, activeSeconds)
    }

    func discard() {
        guard let session, let context, let environment else { return }
        let repository = WorkoutRepository(context: context)
        guard perform("active.error.discard", { try repository.discard(session) }) else { return }
        self.session = nil
        environment.liveActivityService.end()
        environment.activeWorkoutID = nil
        teardown()
        Haptics.warning()
    }

    // MARK: - Live Activity

    private func startLiveActivity() {
        guard let session, let environment else { return }
        environment.liveActivityService.reattach(workoutID: workoutID)
        environment.liveActivityService.start(
            workoutID: workoutID,
            title: session.titleSnapshot,
            state: liveActivityState()
        )
        updateLiveActivity()
    }

    private func updateLiveActivity() {
        guard let environment else { return }
        environment.liveActivityService.update(liveActivityState())
    }

    private func liveActivityState() -> WorkoutActivityAttributes.ContentState {
        let record = currentExercise
        let sets = record?.workingSets ?? []
        return WorkoutActivityAttributes.ContentState(
            exerciseName: record?.exerciseNameSnapshot ?? session?.titleSnapshot ?? "",
            setNumber: (sets.firstIndex { !$0.isCompleted }.map { $0 + 1 }) ?? sets.count,
            totalSets: sets.count,
            completedSets: completedWorkingSets,
            plannedSets: plannedWorkingSets,
            restEndsAt: restTimer.endsAt,
            workoutStartedAt: session?.startedAt ?? Date()
        )
    }

    // MARK: - Failure handling

    /// Runs a store write, surfacing a retryable failure instead of losing it.
    @discardableResult
    private func perform(_ messageKey: String, _ action: @escaping () throws -> Void) -> Bool {
        do {
            try action()
            failure = nil
            return true
        } catch {
            AppLog.persistence.error("Active workout write failed: \(String(describing: error), privacy: .public)")
            Haptics.error()
            failure = ActiveWorkoutFailure(message: L(messageKey)) { [weak self] in
                _ = self?.perform(messageKey, action)
            }
            return false
        }
    }
}
