import Foundation
import SwiftData

// MARK: - Session start targets

/// The prescription for one exercise at the moment a session starts.
///
/// Supplied by the progression engine when it has an opinion, and omitted when it does not — in
/// which case the template's own numbers are used. Kept as a value type so starting a workout never
/// requires the repository to know how progression works.
struct SessionExerciseTarget: Hashable, Sendable {
    var weightKg: Double?
    var repRange: RepRange?
    var sets: Int?
    var targetRIR: Int?
    var restSeconds: Int?

    init(
        weightKg: Double? = nil,
        repRange: RepRange? = nil,
        sets: Int? = nil,
        targetRIR: Int? = nil,
        restSeconds: Int? = nil
    ) {
        self.weightKg = weightKg
        self.repRange = repRange
        self.sets = sets
        self.targetRIR = targetRIR
        self.restSeconds = restSeconds
    }
}

// MARK: - Repository

/// Owns the workout in progress and everything ever performed.
///
/// **A session is a snapshot, not a view of the plan.** When a session starts it copies the title,
/// the exercise ids, the exercise *names* and the set targets out of the template. Editing the
/// template afterwards — or a dataset update renaming an exercise, or the programming engine
/// swapping a movement out — can then never rewrite what the user actually did last Tuesday. This is
/// the single most important rule in this file: history is written once and never derived again.
///
/// **Everything is saved immediately.** A workout is logged over forty minutes on a phone that may
/// ring, lock, run out of battery or be force-quit. Every mutating method here commits before it
/// returns, so the worst case a user can hit is losing the set they were mid-way through typing.
@MainActor
struct WorkoutRepository: Repository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Starting and resuming

    /// Starts a session from a template, snapshotting everything it needs to stay readable forever.
    ///
    /// `catalog` supplies the exercise names and tracking modes. It is a parameter rather than a
    /// dependency because the catalogue is a main-actor observable object owned by the app, and a
    /// repository that reached out to it would be untestable.
    @discardableResult
    func startSession(
        from template: WorkoutTemplate,
        catalog: [String: Exercise],
        targets: [String: SessionExerciseTarget] = [:],
        title: String? = nil,
        now: Date = Date()
    ) throws -> WorkoutSession {
        let session = WorkoutSession()
        session.startedAt = now
        session.status = .inProgress
        session.titleSnapshot = resolvedTitle(for: template, override: title)
        session.templateID = template.id
        session.programID = template.program?.id
        session.programVersion = template.program?.currentVersion ?? 1
        session.focusGroups = template.focusGroups
        session.resumeExerciseIndex = 0
        context.insert(session)

        var plannedSets = 0
        for planned in template.orderedExercises {
            let target = targets[planned.exerciseID]
            let exercise = catalog[planned.exerciseID]
            let setCount = InputValidation.clampedSets(target?.sets ?? planned.targetSets)
            let repRange = InputValidation.clampedRepRange(target?.repRange ?? planned.repRange)

            let record = ExerciseSession()
            record.exerciseID = planned.exerciseID
            // The name is copied, never looked up later: an exercise the catalogue no longer ships
            // must still read as itself in a two-year-old session.
            record.exerciseNameSnapshot = exercise?.name ?? planned.exerciseID
            record.orderIndex = planned.orderIndex
            record.wasSkipped = false
            record.substitutedFromExerciseID = planned.substitutedFromExerciseID
            record.targetRIR = InputValidation.clampedRIR(target?.targetRIR ?? planned.targetRIR)
            record.restSeconds = InputValidation.clampedRestSeconds(target?.restSeconds ?? planned.restSeconds)
            record.trackingMode = exercise?.metadata.trackingMode ?? .weightAndReps
            context.insert(record)
            record.workout = session

            for index in 0..<setCount {
                let set = SetRecord()
                set.setIndex = index
                set.kind = .working
                set.targetWeightKg = target?.weightKg
                // The top of the range is stored as the rep target: under double progression the
                // instruction is "reach the top of the range, then the load goes up", so that is the
                // number the user should be chasing on every set.
                set.targetReps = (exercise?.metadata.trackingMode.usesReps ?? true) ? repRange.upper : nil
                set.targetDurationSeconds = planned.targetDurationSeconds
                context.insert(set)
                set.exerciseSession = record
                plannedSets += 1
            }
        }

        session.plannedSetCount = plannedSets
        try persist()
        return session
    }

    /// Starts a session with no template behind it — the "just train" path.
    @discardableResult
    func startEmptySession(title: String, now: Date = Date()) throws -> WorkoutSession {
        let session = WorkoutSession()
        session.startedAt = now
        session.status = .inProgress
        session.titleSnapshot = try InputValidation.name(title, field: "sessionTitle")
        context.insert(session)
        try persist()
        return session
    }

    /// The session the user is part-way through, if there is one.
    ///
    /// Only one can exist at a time; if a crash left more than one behind, the newest wins and the
    /// rest are abandoned rather than silently resumed out of order.
    func inProgressSession() throws -> WorkoutSession? {
        let inProgress = PlannedSessionStatus.inProgress.rawValue
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == inProgress },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        let sessions = try fetch(descriptor)
        if sessions.count > 1 {
            AppLog.persistence.error("Found \(sessions.count) in-progress sessions; abandoning the older ones")
            for stale in sessions.dropFirst() { stale.status = .skipped }
            try persist()
        }
        return sessions.first
    }

    /// Remembers which exercise the user was on, so an interrupted session resumes in place.
    func setResumeIndex(_ index: Int, on session: WorkoutSession) throws {
        session.resumeExerciseIndex = max(0, index)
        try persist()
    }

    /// Adds elapsed active seconds. Accumulated rather than derived from the wall clock so time the
    /// app spent in the background does not inflate the session duration.
    func addActiveSeconds(_ seconds: Int, to session: WorkoutSession) throws {
        guard seconds > 0 else { return }
        session.activeSeconds += seconds
        try persist()
    }

    func setNotes(_ notes: String?, on session: WorkoutSession) throws {
        session.notes = InputValidation.sanitisedNote(notes)
        try persist()
    }

    // MARK: - Mid-session structure

    /// Adds an exercise to a running session, appended at the end.
    @discardableResult
    func addExercise(
        _ exercise: Exercise,
        to session: WorkoutSession,
        sets: Int = 3,
        repRange: RepRange? = nil,
        restSeconds: Int? = nil,
        targetRIR: Int = 2,
        targetWeightKg: Double? = nil
    ) throws -> ExerciseSession {
        let record = ExerciseSession()
        record.exerciseID = exercise.id
        record.exerciseNameSnapshot = exercise.name
        record.orderIndex = (session.exercises.map(\.orderIndex).max() ?? -1) + 1
        record.targetRIR = InputValidation.clampedRIR(targetRIR)
        record.restSeconds = InputValidation.clampedRestSeconds(restSeconds ?? exercise.metadata.defaultRestSeconds)
        record.trackingMode = exercise.metadata.trackingMode
        context.insert(record)
        record.workout = session

        let range = InputValidation.clampedRepRange(repRange ?? exercise.metadata.recommendedRepRange)
        for index in 0..<InputValidation.clampedSets(sets) {
            let set = SetRecord()
            set.setIndex = index
            set.kind = .working
            set.targetWeightKg = targetWeightKg
            set.targetReps = exercise.metadata.trackingMode.usesReps ? range.upper : nil
            context.insert(set)
            set.exerciseSession = record
        }
        session.plannedSetCount = workingSetRows(in: session).count
        try persist()
        return record
    }

    /// Removes an exercise from a running session entirely, along with its sets.
    func removeExercise(_ record: ExerciseSession, from session: WorkoutSession) throws {
        context.delete(record)
        session.exercises.removeAll { $0.id == record.id }
        for (index, remaining) in session.orderedExercises.enumerated() { remaining.orderIndex = index }
        session.plannedSetCount = workingSetRows(in: session).count
        session.resumeExerciseIndex = min(session.resumeExerciseIndex, max(0, session.exercises.count - 1))
        try persist()
    }

    /// Reorders the exercises of a running session to match `orderedIDs`.
    func reorderExercises(in session: WorkoutSession, orderedIDs: [UUID]) throws {
        let ordered = RepositoryOrdering.sorted(
            session.exercises, matching: orderedIDs, id: \.id, currentIndex: \.orderIndex
        )
        for (index, record) in ordered.enumerated() { record.orderIndex = index }
        try persist()
    }

    func moveExercises(in session: WorkoutSession, fromOffsets source: IndexSet, toOffset destination: Int) throws {
        let ordered = RepositoryOrdering.moved(
            session.orderedExercises, fromOffsets: source, toOffset: destination
        )
        for (index, record) in ordered.enumerated() { record.orderIndex = index }
        try persist()
    }

    /// Marks an exercise skipped, or unskips it. The sets stay in place so the decision is
    /// reversible and so the planned volume the user did not do is still visible.
    func setSkipped(_ skipped: Bool, on record: ExerciseSession) throws {
        record.wasSkipped = skipped
        try persist()
    }

    func setNotes(_ notes: String?, on record: ExerciseSession) throws {
        record.notes = InputValidation.sanitisedNote(notes)
        try persist()
    }

    /// Swaps an exercise mid-session, recording what it replaced and why.
    ///
    /// The completed sets of the outgoing exercise are kept — they were genuinely performed — and
    /// only the untouched sets are re-targeted, because the new movement's load has nothing to do
    /// with the old one's.
    func substitute(
        _ record: ExerciseSession,
        with exercise: Exercise,
        reason: SubstitutionReason?,
        targetWeightKg: Double? = nil
    ) throws {
        guard record.exerciseID != exercise.id else { return }
        if record.substitutedFromExerciseID == nil {
            record.substitutedFromExerciseID = record.exerciseID
        } else if record.substitutedFromExerciseID == exercise.id {
            record.substitutedFromExerciseID = nil
        }
        record.exerciseID = exercise.id
        record.exerciseNameSnapshot = exercise.name
        record.trackingMode = exercise.metadata.trackingMode
        record.restSeconds = InputValidation.clampedRestSeconds(exercise.metadata.defaultRestSeconds)
        record.substitutionReasonKey = reason?.localizationKey

        let range = exercise.metadata.recommendedRepRange
        for set in record.orderedSets where !set.isCompleted {
            set.targetWeightKg = targetWeightKg
            set.targetReps = exercise.metadata.trackingMode.usesReps ? range.upper : nil
        }
        try persist()
    }

    // MARK: - Sets

    /// Appends a set to an exercise, copying the previous set's targets so the common case — "one
    /// more of those" — needs no typing.
    @discardableResult
    func addSet(
        to record: ExerciseSession,
        kind: SetKind = .working,
        targetWeightKg: Double? = nil,
        targetReps: Int? = nil,
        targetDurationSeconds: Int? = nil
    ) throws -> SetRecord {
        let previous = record.orderedSets.last
        let set = SetRecord()
        set.setIndex = (record.sets.map(\.setIndex).max() ?? -1) + 1
        set.kind = kind
        set.targetWeightKg = try (targetWeightKg ?? previous?.targetWeightKg).map { try InputValidation.load(kg: $0) }
        set.targetReps = (targetReps ?? previous?.targetReps).map(InputValidation.clampedReps)
        set.targetDurationSeconds = (targetDurationSeconds ?? previous?.targetDurationSeconds)
            .map(InputValidation.clampedSetDurationSeconds)
        context.insert(set)
        set.exerciseSession = record
        if let session = record.workout {
            session.plannedSetCount = workingSetRows(in: session).count
        }
        try persist()
        return set
    }

    func removeSet(_ set: SetRecord) throws {
        let record = set.exerciseSession
        let session = record?.workout
        context.delete(set)
        if let record {
            record.sets.removeAll { $0.id == set.id }
            for (index, remaining) in record.orderedSets.enumerated() { remaining.setIndex = index }
        }
        if let session {
            session.plannedSetCount = workingSetRows(in: session).count
            session.completedSetCount = workingSetRows(in: session).filter(\.isCompleted).count
        }
        try persist()
    }

    /// Records what the user actually did on one set.
    ///
    /// Every field is optional because the tracking mode decides which of them exist: a plank has a
    /// duration and no reps, a treadmill run has a distance and no load. Nothing is inferred — a
    /// value the user did not enter is stored as `nil`, not as zero.
    func completeSet(
        _ set: SetRecord,
        weightKg: Double? = nil,
        reps: Int? = nil,
        rir: Int? = nil,
        rpe: Double? = nil,
        durationSeconds: Int? = nil,
        distanceMeters: Double? = nil,
        notes: String? = nil,
        now: Date = Date()
    ) throws {
        if let weightKg { set.weightKg = try InputValidation.load(kg: weightKg) }
        if let reps { set.reps = InputValidation.clampedReps(reps) }
        if let rir { set.rir = InputValidation.clampedRIR(rir) }
        if let rpe { set.rpe = InputValidation.clampedRPE(rpe) }
        if let durationSeconds { set.durationSeconds = InputValidation.clampedSetDurationSeconds(durationSeconds) }
        if let distanceMeters { set.distanceMeters = InputValidation.clampedDistanceMeters(distanceMeters) }
        if let notes { set.notes = InputValidation.sanitisedNote(notes) }
        set.isCompleted = true
        set.completedAt = now

        if let session = set.exerciseSession?.workout {
            session.completedSetCount = workingSetRows(in: session).filter(\.isCompleted).count
            session.totalVolumeKg = tonnage(of: session)
        }
        try persist()
    }

    /// Undoes a completion without discarding what was typed, so a mis-tap is a one-tap fix.
    func uncompleteSet(_ set: SetRecord) throws {
        set.isCompleted = false
        set.completedAt = nil
        if let session = set.exerciseSession?.workout {
            session.completedSetCount = workingSetRows(in: session).filter(\.isCompleted).count
            session.totalVolumeKg = tonnage(of: session)
        }
        try persist()
    }

    /// Attaches the personal records a set achieved. Detection belongs to the analytics engine; the
    /// repository only writes down what it was told.
    func setAchievedRecords(_ kinds: [PersonalRecordKind], on set: SetRecord) throws {
        set.achievedRecordKinds = kinds
        try persist()
    }

    // MARK: - Finishing

    /// Closes a session and caches the figures the history list would otherwise recompute on every
    /// scroll.
    ///
    /// `activeSeconds` is passed in rather than derived: only the timer that ran during the workout
    /// knows how much of the wall-clock gap was actually spent training.
    func finish(
        _ session: WorkoutSession,
        effort: SessionEffortFeedback? = nil,
        activeSeconds: Int? = nil,
        notes: String? = nil,
        now: Date = Date()
    ) throws {
        session.status = .completed
        session.endedAt = now
        if let activeSeconds { session.activeSeconds = max(0, activeSeconds) }
        if session.activeSeconds == 0 {
            // Nothing reported a timer — fall back to the wall clock so the session is not recorded
            // as having taken no time at all.
            session.activeSeconds = max(0, Int(now.timeIntervalSince(session.startedAt)))
        }
        session.effortFeedback = effort
        if let notes { session.notes = InputValidation.sanitisedNote(notes) }

        let working = workingSetRows(in: session)
        session.plannedSetCount = working.count
        session.completedSetCount = working.filter(\.isCompleted).count
        session.totalVolumeKg = tonnage(of: session)
        try persist()
    }

    /// Throws a session away. Used for "I started this by mistake"; there is nothing to preserve,
    /// because a discarded session is not history the user wants.
    func discard(_ session: WorkoutSession) throws {
        context.delete(session)
        try persist()
    }

    /// Marks a session as abandoned without deleting it — the user walked out but wants the record.
    func abandon(_ session: WorkoutSession, now: Date = Date()) throws {
        session.status = .skipped
        session.endedAt = now
        let working = workingSetRows(in: session)
        session.plannedSetCount = working.count
        session.completedSetCount = working.filter(\.isCompleted).count
        session.totalVolumeKg = tonnage(of: session)
        try persist()
    }

    // MARK: - Outcome

    /// Summarises a finished session for the autoregulation and recovery engines.
    ///
    /// `catalog` is required because per-group set attribution lives in the exercise metadata: a set
    /// of dumbbell rows is one set of back and half a set of biceps, and only the catalogue knows
    /// that. Skipped exercises contribute nothing to the group totals but still count as planned.
    func sessionOutcome(for session: WorkoutSession, catalog: [String: Exercise]) -> SessionOutcome {
        var groupSets: [MuscleGroup: Double] = [:]
        var performances: [ExercisePerformance] = []
        var skipped: [String] = []
        var substituted: [String: String] = [:]
        var rirTotal = 0.0
        var rirCount = 0
        var completedSets = 0
        var plannedSets = 0

        let date = session.endedAt ?? session.startedAt

        for record in session.orderedExercises {
            let working = record.workingSets
            plannedSets += working.count

            if let original = record.substitutedFromExerciseID {
                substituted[original] = record.exerciseID
            }
            if record.wasSkipped {
                skipped.append(record.exerciseID)
                continue
            }

            let completed = working.filter(\.isCompleted)
            completedSets += completed.count

            for set in completed {
                if let rir = performedSet(from: set).effectiveRIR {
                    rirTotal += rir
                    rirCount += 1
                }
            }

            if let exercise = catalog[record.exerciseID], !completed.isEmpty {
                for (group, credit) in exercise.metadata.volumeContribution {
                    groupSets[group, default: 0] += credit * Double(completed.count)
                }
            }

            performances.append(ExercisePerformance(
                date: date,
                exerciseID: record.exerciseID,
                sets: record.orderedSets.map(performedSet(from:)),
                sessionID: session.id
            ))
        }

        return SessionOutcome(
            sessionID: session.id,
            date: date,
            plannedSets: plannedSets,
            completedSets: completedSets,
            skippedExerciseIDs: skipped,
            substitutedExerciseIDs: substituted,
            effortFeedback: session.effortFeedback,
            durationSeconds: session.activeSeconds > 0 ? session.activeSeconds : session.durationSeconds,
            averageRIR: rirCount > 0 ? rirTotal / Double(rirCount) : nil,
            groupSets: groupSets,
            performances: performances
        )
    }

    // MARK: - History

    /// Completed sessions, newest first.
    func recentSessions(limit: Int = 20) throws -> [WorkoutSession] {
        let completed = PlannedSessionStatus.completed.rawValue
        var descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == completed },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try fetch(descriptor)
    }

    /// Completed sessions that started inside `[from, to)`, newest first.
    func sessions(from start: Date, to end: Date) throws -> [WorkoutSession] {
        let completed = PlannedSessionStatus.completed.rawValue
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.statusRaw == completed && $0.startedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try fetch(descriptor)
    }

    /// Every session in which an exercise was performed, newest first.
    ///
    /// De-duplicated by session: an exercise can hold two slots in one workout — a second block, or
    /// a back-off after a heavy top set — and that is still one session the user trained it in.
    func sessions(forExerciseID exerciseID: String, limit: Int = 20) throws -> [WorkoutSession] {
        let records = try exerciseSessions(forExerciseIDs: [exerciseID])
        var seen = Set<UUID>()
        var sessions: [WorkoutSession] = []
        for record in records {
            guard let session = record.workout, session.status == .completed else { continue }
            guard seen.insert(session.id).inserted else { continue }
            sessions.append(session)
        }
        sessions.sort { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
            return lhs.id.uuidString > rhs.id.uuidString
        }
        return limit > 0 ? Array(sessions.prefix(limit)) : sessions
    }

    /// The history snapshot the progression engine needs for one exercise.
    func history(forExerciseID exerciseID: String, sessionLimit: Int = 10) throws -> ExerciseHistorySnapshot {
        try histories(forExerciseIDs: [exerciseID], sessionLimit: sessionLimit)[exerciseID]
            ?? ExerciseHistorySnapshot(exerciseID: exerciseID)
    }

    /// History snapshots for many exercises at once.
    ///
    /// The programming engine asks for dozens of exercises before it builds a week, so this must not
    /// be N queries. One fetch pulls every `ExerciseSession` row for the whole id set, and the
    /// grouping, ordering and truncation happen in memory. The full result set is used for the
    /// all-time figures (`totalSessions`, best estimated one-rep max) while only the newest
    /// `sessionLimit` performances are handed to the engine, which never looks further back than a
    /// handful of sessions.
    ///
    /// **One performance per session.** Two rows for the same exercise in one workout — a second
    /// block, a back-off after a heavy top set — are one session's work on that movement, so their
    /// sets are merged. Counting them separately would inflate `totalSessions`, and would hand the
    /// progression engine two same-day performances where it expects one per session, shortening the
    /// window it actually reasons over.
    func histories(
        forExerciseIDs exerciseIDs: [String],
        sessionLimit: Int = 10
    ) throws -> [String: ExerciseHistorySnapshot] {
        let unique = Array(Set(exerciseIDs))
        guard !unique.isEmpty else { return [:] }

        // Ordered by position in the workout so merged sets read in the order they were performed.
        let records = try exerciseSessions(forExerciseIDs: unique).sorted { $0.orderIndex < $1.orderIndex }
        var byExercise: [String: [UUID: ExercisePerformance]] = [:]

        for record in records {
            guard let session = record.workout, session.status == .completed, !record.wasSkipped else { continue }
            let sets = record.orderedSets.map(performedSet(from:))
            guard sets.contains(where: { $0.isCompleted }) else { continue }
            var bySession = byExercise[record.exerciseID] ?? [:]
            if var existing = bySession[session.id] {
                existing.sets.append(contentsOf: sets)
                bySession[session.id] = existing
            } else {
                bySession[session.id] = ExercisePerformance(
                    date: session.endedAt ?? session.startedAt,
                    exerciseID: record.exerciseID,
                    sets: sets,
                    sessionID: session.id
                )
            }
            byExercise[record.exerciseID] = bySession
        }

        var result: [String: ExerciseHistorySnapshot] = [:]
        for exerciseID in unique {
            // Two sessions can share a timestamp, so the id breaks the tie and keeps the order the
            // engine sees stable between reads.
            let bySession = byExercise[exerciseID] ?? [:]
            let all = Array(bySession.values).sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date > rhs.date }
                return (lhs.sessionID?.uuidString ?? "") > (rhs.sessionID?.uuidString ?? "")
            }
            var snapshot = ExerciseHistorySnapshot(exerciseID: exerciseID)
            snapshot.performances = sessionLimit > 0 ? Array(all.prefix(sessionLimit)) : all
            snapshot.totalSessions = all.count
            snapshot.lastPerformedAt = all.first?.date
            snapshot.bestEstimatedOneRepMaxKg = Self.bestEstimatedOneRepMax(in: all)
            result[exerciseID] = snapshot
        }
        return result
    }

    /// Every stored `ExerciseSession` row for the given exercises. One fetch, whatever the id count.
    ///
    /// `ExerciseSession` carries no store index on `exerciseID`, so this is a scan of the exercise
    /// rows — which is still one scan for the whole id set rather than one per exercise, and is why
    /// every caller here batches its ids instead of looping.
    private func exerciseSessions(forExerciseIDs exerciseIDs: [String]) throws -> [ExerciseSession] {
        let ids = Array(Set(exerciseIDs))
        guard !ids.isEmpty else { return [] }
        let descriptor = FetchDescriptor<ExerciseSession>(
            predicate: #Predicate { ids.contains($0.exerciseID) }
        )
        return try fetch(descriptor)
    }

    // MARK: - Progression state

    /// The engine's memory for one exercise, created on first use.
    @discardableResult
    func progressionState(forExerciseID exerciseID: String) throws -> ProgressionState {
        let descriptor = FetchDescriptor<ProgressionState>(
            predicate: #Predicate { $0.exerciseID == exerciseID }
        )
        if let existing = try fetchFirst(descriptor) { return existing }
        let created = ProgressionState(exerciseID: exerciseID)
        context.insert(created)
        try persist()
        return created
    }

    /// Progression rows for many exercises in one fetch. Missing rows are simply absent: the caller
    /// treats an absent state as "needs calibration", which is what a new exercise is.
    func progressionStates(forExerciseIDs exerciseIDs: [String]) throws -> [String: ProgressionState] {
        let ids = Array(Set(exerciseIDs))
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<ProgressionState>(
            predicate: #Predicate { ids.contains($0.exerciseID) }
        )
        return Dictionary(try fetch(descriptor).map { ($0.exerciseID, $0) }) { first, _ in first }
    }

    /// Value-type progression state for many exercises. Ids with no stored row get a fresh snapshot
    /// so the engine never has to special-case a missing key.
    func progressionSnapshots(forExerciseIDs exerciseIDs: [String]) throws -> [String: ProgressionStateSnapshot] {
        let stored = try progressionStates(forExerciseIDs: exerciseIDs)
        var result: [String: ProgressionStateSnapshot] = [:]
        for exerciseID in Set(exerciseIDs) {
            result[exerciseID] = stored[exerciseID].map(Self.snapshot(of:))
                ?? ProgressionStateSnapshot(exerciseID: exerciseID)
        }
        return result
    }

    /// Writes an engine decision back, together with the explanation that justified it.
    ///
    /// The explanation is stored as a key plus arguments rather than as text, so the reason the app
    /// held a load back still reads correctly after the user switches language.
    func apply(
        _ snapshot: ProgressionStateSnapshot,
        decision: Explanation? = nil,
        now: Date = Date()
    ) throws {
        let state = try progressionState(forExerciseID: snapshot.exerciseID)
        state.workingWeightKg = try snapshot.workingWeightKg.map { try InputValidation.load(kg: $0) }
        state.repRange = InputValidation.clampedRepRange(snapshot.repRange)
        state.consecutiveSuccesses = max(0, snapshot.consecutiveSuccesses)
        state.consecutiveStalls = max(0, snapshot.consecutiveStalls)
        state.consecutiveRegressions = max(0, snapshot.consecutiveRegressions)
        state.needsCalibration = snapshot.needsCalibration
        state.strategy = snapshot.strategy
        state.bestEstimatedOneRepMaxKg = snapshot.bestEstimatedOneRepMaxKg
        state.lastPerformedAt = snapshot.lastPerformedAt
        if let decision {
            state.lastDecisionKey = decision.key
            state.lastDecisionArguments = decision.arguments
        }
        state.updatedAt = now
        try persist()
    }

    /// Converts a stored progression row into the value type the engines take.
    static func snapshot(of state: ProgressionState) -> ProgressionStateSnapshot {
        ProgressionStateSnapshot(
            exerciseID: state.exerciseID,
            workingWeightKg: state.workingWeightKg,
            repRange: state.repRange,
            consecutiveSuccesses: state.consecutiveSuccesses,
            consecutiveStalls: state.consecutiveStalls,
            consecutiveRegressions: state.consecutiveRegressions,
            needsCalibration: state.needsCalibration,
            strategy: state.strategy,
            bestEstimatedOneRepMaxKg: state.bestEstimatedOneRepMaxKg,
            lastPerformedAt: state.lastPerformedAt
        )
    }

    // MARK: - Conversions

    /// Converts one stored set into the value type the engines consume.
    func performedSet(from set: SetRecord) -> PerformedSet {
        PerformedSet(
            kind: set.kind,
            weightKg: set.weightKg,
            reps: set.reps,
            rir: set.rir,
            rpe: set.rpe,
            durationSeconds: set.durationSeconds,
            distanceMeters: set.distanceMeters,
            targetReps: set.targetReps,
            targetWeightKg: set.targetWeightKg,
            isCompleted: set.isCompleted
        )
    }

    /// Converts one stored exercise session into the value type the engines consume.
    func performance(from record: ExerciseSession) -> ExercisePerformance {
        let session = record.workout
        return ExercisePerformance(
            date: session.map { $0.endedAt ?? $0.startedAt } ?? Date(timeIntervalSince1970: 0),
            exerciseID: record.exerciseID,
            sets: record.orderedSets.map(performedSet(from:)),
            sessionID: session?.id
        )
    }

    // MARK: - Private

    /// Resolves the title a session will carry forever. The user's own name for the session wins;
    /// otherwise the template's key is localised once, here, at the moment it is snapshotted.
    private func resolvedTitle(for template: WorkoutTemplate, override: String?) -> String {
        if let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override
        }
        if let custom = template.customTitle, !custom.isEmpty { return custom }
        return LocalizationManager.shared.localized(template.titleKey)
    }

    /// Every set row in a session that counts towards volume, skipped exercises included — a set the
    /// user planned and did not do is still a set they planned.
    private func workingSetRows(in session: WorkoutSession) -> [SetRecord] {
        session.exercises.flatMap { $0.sets }.filter { $0.kind.countsAsWorkingSet }
    }

    /// Cached tonnage for a session, in kilograms.
    ///
    /// Only tracking modes where `weight × reps` means something contribute. An assisted pull-up
    /// records the *assistance*, so counting it as tonnage would reward the user for making the
    /// movement easier, and a treadmill run has no load at all.
    private func tonnage(of session: WorkoutSession) -> Double {
        session.exercises.reduce(0) { total, record in
            guard !record.wasSkipped, record.trackingMode.contributesToTonnage else { return total }
            return total + record.completedWorkingSets.reduce(0) { $0 + $1.volumeKg }
        }
    }

    /// Best estimated one-rep max across a set of performances, in kilograms.
    ///
    /// Delegates to `OneRepMaxCalculator`, which owns the formulas and the reliability bounds. The
    /// repository deliberately does not reimplement the arithmetic: there must be exactly one answer
    /// in the app to "what is this lifter's estimated max", or the number on the progress chart and
    /// the number the progression engine reasons about will drift apart.
    static func bestEstimatedOneRepMax(in performances: [ExercisePerformance]) -> Double? {
        var best: Double?
        for performance in performances {
            guard let estimate = OneRepMaxCalculator.bestEstimate(from: performance.sets) else { continue }
            if estimate > (best ?? 0) { best = estimate }
        }
        return best
    }
}
