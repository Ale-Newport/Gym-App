import Foundation
import SwiftData

// MARK: - Version snapshot

/// The JSON payload stored in `ProgramVersion.snapshotJSON`.
///
/// A program version has to stay readable after the templates it described have been rewritten, so
/// it cannot be a set of relationships — it has to be a frozen copy. JSON is used rather than a
/// second family of `@Model` rows because a version is never queried, only read back whole, and
/// because a flat blob costs nothing to migrate.
///
/// The encoder uses `.sortedKeys`, and the payload holds no dates, so encoding the same program
/// state twice produces byte-identical data. That keeps version comparison meaningful.
struct ProgramSnapshot: Codable, Hashable, Sendable {

    /// One template, frozen.
    struct Template: Codable, Hashable, Sendable {
        var orderIndex: Int
        var titleKey: String
        var customTitle: String?
        var weekdayRawValue: Int?
        var estimatedMinutes: Int
        var focusGroups: [MuscleGroup]
        var pushPull: PushPullClass
        var isRestDay: Bool
        var exercises: [Exercise]
    }

    /// One planned exercise, frozen. Named `Exercise` inside `ProgramSnapshot` so it never collides
    /// with the catalogue's `Exercise`; it is a prescription, not a catalogue record.
    struct Exercise: Codable, Hashable, Sendable {
        var exerciseID: String
        var orderIndex: Int
        var targetSets: Int
        var repLower: Int
        var repUpper: Int
        var restSeconds: Int
        var targetRIR: Int
        var targetDurationSeconds: Int?
        var targetDistanceMeters: Double?
        var isLocked: Bool
        var substitutedFromExerciseID: String?
        var notes: String?
    }

    var versionNumber: Int
    var title: String
    var splitKey: String
    var daysPerWeek: Int
    var mesocycleLengthWeeks: Int
    var templates: [Template]
}

// MARK: - Repository

/// Owns everything to do with a training plan: the generated program, its templates, the exercise
/// slots inside them, and the immutable version history behind them.
///
/// Two invariants are enforced here and nowhere else.
///
/// 1. **Exactly one program is active.** Activating one deactivates the rest in the same save, so a
///    crash can never leave two active programs for the home screen to choose between.
/// 2. **The engine may rewrite a program, but never erase what came before.** Every engine-driven
///    change bumps `currentVersion` and appends a `ProgramVersion` holding a full JSON copy, so the
///    question "what did my plan look like in week 3, and why did it change?" always has an answer.
@MainActor
struct ProgramRepository: Repository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Fetching

    /// The single active program, or `nil` before the first one is generated.
    func activeProgram() throws -> TrainingProgram? {
        let descriptor = FetchDescriptor<TrainingProgram>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let active = try fetch(descriptor)
        // Defence in depth: if a previous crash left two rows active, keep the newest and stand the
        // others down rather than letting the rest of the app pick arbitrarily.
        if active.count > 1 {
            AppLog.persistence.error("Found \(active.count) active programs; keeping the newest")
            for stale in active.dropFirst() { stale.isActive = false }
            try persist()
        }
        return active.first
    }

    /// Every program, newest first. Inactive programs are retained so their history stays readable.
    func allPrograms() throws -> [TrainingProgram] {
        try fetch(FetchDescriptor<TrainingProgram>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))
    }

    func program(id: UUID) throws -> TrainingProgram? {
        try fetchFirst(FetchDescriptor<TrainingProgram>(predicate: #Predicate { $0.id == id }))
    }

    /// Makes `program` the active one and deactivates every other program in a single save.
    func activate(_ program: TrainingProgram, now: Date = Date()) throws {
        for other in try allPrograms() where other.id != program.id {
            other.isActive = false
        }
        program.isActive = true
        program.updatedAt = now
        try persist()
    }

    /// Versions of a program, newest first.
    ///
    /// A version number can legitimately carry two rows — the shape a version was created with, and
    /// the shape it had grown into by the time it was replaced — so the sort falls through to the
    /// creation date and then to the id. Without those tie-breaks the history list would reorder
    /// itself between reads, which is the one thing an audit trail may not do.
    func versions(of program: TrainingProgram) -> [ProgramVersion] {
        program.versions.sorted { lhs, rhs in
            if lhs.versionNumber != rhs.versionNumber { return lhs.versionNumber > rhs.versionNumber }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    /// Decodes a stored version back into a readable snapshot.
    func snapshot(of version: ProgramVersion) throws -> ProgramSnapshot {
        guard let data = version.snapshotJSON else {
            throw RepositoryError.notFound(entity: "programVersionSnapshot")
        }
        do {
            return try JSONDecoder().decode(ProgramSnapshot.self, from: data)
        } catch {
            throw RepositoryError.snapshotCodingFailed(underlying: String(describing: error))
        }
    }

    // MARK: - Persisting a generated program

    /// Writes a freshly generated program into the store and makes it active.
    ///
    /// The program keeps a copy of the goals, experience level and priorities it was built from.
    /// That is not redundancy: if the user changes their goal next month, this program's *intent*
    /// must not retroactively change, or its history stops making sense.
    @discardableResult
    func install(
        _ generated: GeneratedProgram,
        profile: TrainingProfileSnapshot,
        title: String,
        reason: Explanation,
        now: Date = Date()
    ) throws -> TrainingProgram {
        let program = TrainingProgram()
        program.title = try InputValidation.name(title, field: "programTitle")
        program.splitKey = generated.splitKey
        program.daysPerWeek = InputValidation.clampedDaysPerWeek(generated.daysPerWeek)
        program.isActive = true
        program.isManuallyCreated = false
        program.createdAt = now
        program.updatedAt = now
        program.goals = profile.goals
        program.experience = profile.experience
        program.priorityGroups = profile.priorityGroups
        program.currentVersion = 1
        program.completedWeeks = 0
        program.mesocycleLengthWeeks = InputValidation.clampedMesocycleWeeks(generated.mesocycleLengthWeeks)
        context.insert(program)

        for session in generated.sessions.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            makeTemplate(from: session, in: program, now: now)
        }

        for other in try allPrograms() where other.id != program.id {
            other.isActive = false
        }

        appendVersion(to: program, reason: reason, now: now)
        try persist()
        return program
    }

    /// Replaces the contents of an existing program with a regenerated plan.
    ///
    /// Used when an engine rewrites the plan — a deload, a volume change, a split change. The
    /// program row and its history survive; only the templates are replaced, and the previous shape
    /// is preserved in the version that is appended.
    func apply(
        _ generated: GeneratedProgram,
        to program: TrainingProgram,
        reason: Explanation,
        now: Date = Date()
    ) throws {
        // Snapshot the *outgoing* shape first, so the history contains what was replaced as well as
        // what replaced it. The outgoing row carries a generic reason; the incoming row appended at
        // the end of this method carries the caller's actual explanation.
        //
        // It is appended only when the program has actually drifted since the newest stored version.
        // After an engine-driven change nothing has: the newest row already holds exactly this
        // shape, and writing it again would put two rows with the same version number and
        // byte-identical payloads into the history on every regeneration. After hand editing —
        // adding a template, changing a prescription, none of which bump the version — it has, and
        // the row is the only record of what the user built.
        appendVersionIfChanged(to: program, reason: Explanation("program.version.superseded"), now: now)

        for template in program.templates { context.delete(template) }
        program.templates = []

        program.splitKey = generated.splitKey
        program.daysPerWeek = InputValidation.clampedDaysPerWeek(generated.daysPerWeek)
        program.mesocycleLengthWeeks = InputValidation.clampedMesocycleWeeks(generated.mesocycleLengthWeeks)
        program.updatedAt = now

        for session in generated.sessions.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            makeTemplate(from: session, in: program, now: now)
        }

        program.currentVersion += 1
        appendVersion(to: program, reason: reason, now: now)
        try persist()
    }

    /// Bumps the version and records the current shape. Call after any engine-driven edit that did
    /// not go through `apply(_:to:reason:)` — an autoregulated set change, a swapped exercise.
    @discardableResult
    func recordEngineChange(
        to program: TrainingProgram,
        reason: Explanation,
        now: Date = Date()
    ) throws -> ProgramVersion {
        program.currentVersion += 1
        program.updatedAt = now
        let version = appendVersion(to: program, reason: reason, now: now)
        try persist()
        return version
    }

    /// Appends a version row holding the program's current shape. Not saved here: callers batch it
    /// with whatever else they changed, so a version is never committed without its change.
    @discardableResult
    private func appendVersion(
        to program: TrainingProgram,
        reason: Explanation,
        now: Date
    ) -> ProgramVersion {
        appendVersion(to: program, reason: reason, now: now, snapshot: encodeSnapshot(of: program))
    }

    @discardableResult
    private func appendVersion(
        to program: TrainingProgram,
        reason: Explanation,
        now: Date,
        snapshot: Data?
    ) -> ProgramVersion {
        let version = ProgramVersion()
        version.versionNumber = program.currentVersion
        version.createdAt = now
        version.reasonKey = reason.key
        version.reasonArguments = reason.arguments
        version.snapshotJSON = snapshot
        context.insert(version)
        version.program = program
        return version
    }

    /// Appends a version row only when the program's current shape differs from the newest one
    /// already recorded. This is what the byte-identical encoding buys: "has anything changed?" is a
    /// data comparison rather than a guess, so the history gains a row exactly when there is
    /// something new in it to read.
    @discardableResult
    private func appendVersionIfChanged(
        to program: TrainingProgram,
        reason: Explanation,
        now: Date
    ) -> ProgramVersion? {
        let snapshot = encodeSnapshot(of: program)
        if let newest = versions(of: program).first, newest.snapshotJSON == snapshot { return nil }
        return appendVersion(to: program, reason: reason, now: now, snapshot: snapshot)
    }

    /// Encodes the program's templates. Returns `nil` on an encoding failure rather than throwing:
    /// losing the readable copy of a version is regrettable, but refusing to save the user's new
    /// program because its history blob would not encode is worse.
    private func encodeSnapshot(of program: TrainingProgram) -> Data? {
        let snapshot = ProgramSnapshot(
            versionNumber: program.currentVersion,
            title: program.title,
            splitKey: program.splitKey,
            daysPerWeek: program.daysPerWeek,
            mesocycleLengthWeeks: program.mesocycleLengthWeeks,
            templates: program.orderedTemplates.map { template in
                ProgramSnapshot.Template(
                    orderIndex: template.orderIndex,
                    titleKey: template.titleKey,
                    customTitle: template.customTitle,
                    weekdayRawValue: template.weekday?.rawValue,
                    estimatedMinutes: template.estimatedMinutes,
                    focusGroups: template.focusGroups,
                    pushPull: template.pushPull,
                    isRestDay: template.isRestDay,
                    exercises: template.orderedExercises.map { planned in
                        ProgramSnapshot.Exercise(
                            exerciseID: planned.exerciseID,
                            orderIndex: planned.orderIndex,
                            targetSets: planned.targetSets,
                            repLower: planned.repLower,
                            repUpper: planned.repUpper,
                            restSeconds: planned.restSeconds,
                            targetRIR: planned.targetRIR,
                            targetDurationSeconds: planned.targetDurationSeconds,
                            targetDistanceMeters: planned.targetDistanceMeters,
                            isLocked: planned.isLocked,
                            substitutedFromExerciseID: planned.substitutedFromExerciseID,
                            notes: planned.notes
                        )
                    }
                )
            }
        )
        let encoder = JSONEncoder()
        // Sorted keys make two encodings of the same state byte-identical, which is what lets a test
        // assert that "nothing changed" really means nothing changed.
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(snapshot)
        } catch {
            AppLog.persistence.error("Program snapshot encoding failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Manual programs

    /// Creates an empty program the user will fill in by hand.
    @discardableResult
    func createEmptyProgram(
        title: String,
        splitKey: String = "split.custom",
        daysPerWeek: Int,
        profile: TrainingProfileSnapshot,
        activate makeActive: Bool = true,
        now: Date = Date()
    ) throws -> TrainingProgram {
        let program = TrainingProgram()
        program.title = try InputValidation.name(title, field: "programTitle")
        program.splitKey = splitKey
        program.daysPerWeek = InputValidation.clampedDaysPerWeek(daysPerWeek)
        program.isManuallyCreated = true
        program.isActive = makeActive
        program.createdAt = now
        program.updatedAt = now
        program.goals = profile.goals
        program.experience = profile.experience
        program.priorityGroups = profile.priorityGroups
        context.insert(program)

        if makeActive {
            for other in try allPrograms() where other.id != program.id { other.isActive = false }
        }
        appendVersion(to: program, reason: Explanation("program.version.createdManually"), now: now)
        try persist()
        return program
    }

    /// Copies a program, its templates and its exercise slots. The copy starts at version 1 with a
    /// fresh history: it is a new plan that happens to have the same shape, not a continuation.
    @discardableResult
    func clone(
        _ source: TrainingProgram,
        title: String,
        activate makeActive: Bool = false,
        now: Date = Date()
    ) throws -> TrainingProgram {
        let copy = TrainingProgram()
        copy.title = try InputValidation.name(title, field: "programTitle")
        copy.splitKey = source.splitKey
        copy.daysPerWeek = source.daysPerWeek
        copy.isManuallyCreated = source.isManuallyCreated
        copy.isActive = makeActive
        copy.createdAt = now
        copy.updatedAt = now
        copy.goals = source.goals
        copy.experience = source.experience
        copy.priorityGroups = source.priorityGroups
        copy.currentVersion = 1
        copy.completedWeeks = 0
        copy.mesocycleLengthWeeks = source.mesocycleLengthWeeks
        context.insert(copy)

        for template in source.orderedTemplates {
            copyTemplate(template, into: copy, orderIndex: template.orderIndex, now: now)
        }

        if makeActive {
            for other in try allPrograms() where other.id != copy.id { other.isActive = false }
        }
        appendVersion(to: copy, reason: Explanation("program.version.clonedFrom", [source.title]), now: now)
        try persist()
        return copy
    }

    /// Deletes a program outright. Cascades to its templates, exercises and versions.
    func delete(_ program: TrainingProgram) throws {
        context.delete(program)
        try persist()
    }

    func rename(_ program: TrainingProgram, to title: String, now: Date = Date()) throws {
        program.title = try InputValidation.name(title, field: "programTitle")
        program.updatedAt = now
        try persist()
    }

    /// Advances the mesocycle counter. Called once per completed training week.
    func recordCompletedWeek(of program: TrainingProgram, now: Date = Date()) throws {
        program.completedWeeks += 1
        program.updatedAt = now
        try persist()
    }

    // MARK: - Templates

    /// Adds a session slot to a program, appended at the end.
    @discardableResult
    func addTemplate(
        to program: TrainingProgram,
        titleKey: String = "session.untitled",
        customTitle: String? = nil,
        weekday: Weekday? = nil,
        focusGroups: [MuscleGroup] = [],
        pushPull: PushPullClass = .neutral,
        estimatedMinutes: Int = 60,
        isRestDay: Bool = false,
        now: Date = Date()
    ) throws -> WorkoutTemplate {
        let template = WorkoutTemplate()
        template.orderIndex = (program.templates.map(\.orderIndex).max() ?? -1) + 1
        template.titleKey = titleKey
        template.customTitle = InputValidation.sanitisedNote(customTitle)
        template.weekday = weekday
        template.focusGroups = focusGroups
        template.pushPull = pushPull
        template.estimatedMinutes = InputValidation.clampedSessionMinutes(estimatedMinutes)
        template.isRestDay = isRestDay
        template.createdAt = now
        template.updatedAt = now
        context.insert(template)
        template.program = program
        program.updatedAt = now
        try persist()
        return template
    }

    /// Duplicates a template inside its own program, placed immediately after the original.
    @discardableResult
    func duplicateTemplate(_ template: WorkoutTemplate, now: Date = Date()) throws -> WorkoutTemplate {
        guard let program = template.program else {
            throw RepositoryError.notFound(entity: "program")
        }
        let copy = copyTemplate(template, into: program, orderIndex: template.orderIndex + 1, now: now)
        // Everything after the original shifts down one so the copy has a slot of its own.
        for sibling in program.orderedTemplates
        where sibling.id != copy.id && sibling.orderIndex >= copy.orderIndex {
            sibling.orderIndex += 1
        }
        reindexTemplates(of: program)
        program.updatedAt = now
        try persist()
        return copy
    }

    /// Sets or clears the user's own name for a session. Clearing falls back to `titleKey`.
    func renameTemplate(_ template: WorkoutTemplate, to customTitle: String?, now: Date = Date()) throws {
        if let customTitle, !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            template.customTitle = try InputValidation.name(customTitle, field: "sessionTitle")
        } else {
            template.customTitle = nil
        }
        template.updatedAt = now
        try persist()
    }

    /// Reorders the templates of a program to match `orderedIDs`. Ids not present keep their
    /// relative order behind the listed ones, so a stale list can never drop a session.
    func reorderTemplates(in program: TrainingProgram, orderedIDs: [UUID], now: Date = Date()) throws {
        let ordered = RepositoryOrdering.sorted(
            program.templates, matching: orderedIDs, id: \.id, currentIndex: \.orderIndex
        )
        for (index, template) in ordered.enumerated() { template.orderIndex = index }
        program.updatedAt = now
        try persist()
    }

    /// Moves templates the way a SwiftUI `List` reports a drag.
    func moveTemplates(
        in program: TrainingProgram,
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        now: Date = Date()
    ) throws {
        let ordered = RepositoryOrdering.moved(
            program.orderedTemplates, fromOffsets: source, toOffset: destination
        )
        for (index, template) in ordered.enumerated() { template.orderIndex = index }
        program.updatedAt = now
        try persist()
    }

    func deleteTemplate(_ template: WorkoutTemplate, now: Date = Date()) throws {
        let program = template.program
        context.delete(template)
        if let program {
            program.templates.removeAll { $0.id == template.id }
            reindexTemplates(of: program)
            program.updatedAt = now
        }
        try persist()
    }

    /// Sets the fixed weekday of a session, or clears it so the session floats.
    func setWeekday(_ weekday: Weekday?, on template: WorkoutTemplate, now: Date = Date()) throws {
        template.weekday = weekday
        template.updatedAt = now
        try persist()
    }

    // MARK: - Planned exercises

    /// Adds an exercise slot to a template, appended at the end.
    @discardableResult
    func addExercise(
        exerciseID: String,
        to template: WorkoutTemplate,
        sets: Int = 3,
        repRange: RepRange = .hypertrophy,
        restSeconds: Int = 120,
        targetRIR: Int = 2,
        targetDurationSeconds: Int? = nil,
        targetDistanceMeters: Double? = nil,
        isLocked: Bool = false,
        notes: String? = nil,
        now: Date = Date()
    ) throws -> PlannedExercise {
        let planned = PlannedExercise()
        planned.exerciseID = exerciseID
        planned.orderIndex = (template.plannedExercises.map(\.orderIndex).max() ?? -1) + 1
        planned.targetSets = InputValidation.clampedSets(sets)
        planned.repRange = InputValidation.clampedRepRange(repRange)
        planned.restSeconds = InputValidation.clampedRestSeconds(restSeconds)
        planned.targetRIR = InputValidation.clampedRIR(targetRIR)
        planned.targetDurationSeconds = targetDurationSeconds.map(InputValidation.clampedSetDurationSeconds)
        planned.targetDistanceMeters = targetDistanceMeters.map(InputValidation.clampedDistanceMeters)
        planned.isLocked = isLocked
        planned.notes = InputValidation.sanitisedNote(notes)
        context.insert(planned)
        planned.template = template
        template.updatedAt = now
        template.program?.updatedAt = now
        try persist()
        return planned
    }

    func removeExercise(_ planned: PlannedExercise, now: Date = Date()) throws {
        let template = planned.template
        context.delete(planned)
        if let template {
            template.plannedExercises.removeAll { $0.id == planned.id }
            reindexExercises(of: template)
            template.updatedAt = now
            template.program?.updatedAt = now
        }
        try persist()
    }

    /// Reorders exercises inside a template to match `orderedIDs`.
    func reorderExercises(in template: WorkoutTemplate, orderedIDs: [UUID], now: Date = Date()) throws {
        let ordered = RepositoryOrdering.sorted(
            template.plannedExercises, matching: orderedIDs, id: \.id, currentIndex: \.orderIndex
        )
        for (index, planned) in ordered.enumerated() { planned.orderIndex = index }
        template.updatedAt = now
        try persist()
    }

    func moveExercises(
        in template: WorkoutTemplate,
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        now: Date = Date()
    ) throws {
        let ordered = RepositoryOrdering.moved(
            template.orderedExercises, fromOffsets: source, toOffset: destination
        )
        for (index, planned) in ordered.enumerated() { planned.orderIndex = index }
        template.updatedAt = now
        try persist()
    }

    /// Pins an exercise so the programming engine leaves it alone.
    func setLocked(_ locked: Bool, on planned: PlannedExercise, now: Date = Date()) throws {
        planned.isLocked = locked
        planned.template?.updatedAt = now
        try persist()
    }

    /// Edits the prescription. Every argument is optional so the caller changes one field without
    /// having to restate the other five.
    func updatePrescription(
        of planned: PlannedExercise,
        sets: Int? = nil,
        repRange: RepRange? = nil,
        restSeconds: Int? = nil,
        targetRIR: Int? = nil,
        targetDurationSeconds: Int?? = nil,
        targetDistanceMeters: Double?? = nil,
        notes: String?? = nil,
        now: Date = Date()
    ) throws {
        if let sets { planned.targetSets = InputValidation.clampedSets(sets) }
        if let repRange { planned.repRange = InputValidation.clampedRepRange(repRange) }
        if let restSeconds { planned.restSeconds = InputValidation.clampedRestSeconds(restSeconds) }
        if let targetRIR { planned.targetRIR = InputValidation.clampedRIR(targetRIR) }
        if let targetDurationSeconds {
            planned.targetDurationSeconds = targetDurationSeconds.map(InputValidation.clampedSetDurationSeconds)
        }
        if let targetDistanceMeters {
            planned.targetDistanceMeters = targetDistanceMeters.map(InputValidation.clampedDistanceMeters)
        }
        if let notes { planned.notes = InputValidation.sanitisedNote(notes) }
        planned.template?.updatedAt = now
        planned.template?.program?.updatedAt = now
        try persist()
    }

    /// Swaps the exercise in a slot, recording what it replaced so the change can be explained and
    /// undone. The prescription is deliberately kept: a swap changes the movement, not the dose.
    func substitute(
        _ planned: PlannedExercise,
        withExerciseID exerciseID: String,
        now: Date = Date()
    ) throws {
        guard exerciseID != planned.exerciseID else { return }
        // Only the *original* is remembered. Swapping A → B → C should still say "instead of A",
        // because A is what the plan asked for.
        if planned.substitutedFromExerciseID == nil {
            planned.substitutedFromExerciseID = planned.exerciseID
        } else if planned.substitutedFromExerciseID == exerciseID {
            // Swapping back to the original clears the marker rather than claiming a substitution.
            planned.substitutedFromExerciseID = nil
        }
        planned.exerciseID = exerciseID
        planned.template?.updatedAt = now
        planned.template?.program?.updatedAt = now
        try persist()
    }

    // MARK: - Conversion back to value types

    /// Turns a stored template back into the value type the engines and the workout logger use.
    func generatedSession(from template: WorkoutTemplate) -> GeneratedSession {
        GeneratedSession(
            id: template.id,
            orderIndex: template.orderIndex,
            titleKey: template.titleKey,
            customTitle: template.customTitle,
            weekday: template.weekday,
            focusGroups: template.focusGroups,
            pushPull: template.pushPull,
            estimatedMinutes: template.estimatedMinutes,
            isRestDay: template.isRestDay,
            exercises: template.orderedExercises.map { planned in
                GeneratedExercise(
                    exerciseID: planned.exerciseID,
                    orderIndex: planned.orderIndex,
                    sets: planned.targetSets,
                    repRange: planned.repRange,
                    restSeconds: planned.restSeconds,
                    targetRIR: planned.targetRIR,
                    targetDurationSeconds: planned.targetDurationSeconds,
                    targetDistanceMeters: planned.targetDistanceMeters,
                    isLocked: planned.isLocked,
                    rationale: nil
                )
            }
        )
    }

    /// Turns a stored program back into a `GeneratedProgram`.
    ///
    /// `weeklyVolume` is recomputed from the catalogue rather than stored, because the metadata that
    /// defines a set's volume credit ships with the app and can change with a dataset update; a
    /// stored figure would go stale silently. Passing an empty catalogue yields an empty volume map.
    func generatedProgram(from program: TrainingProgram, catalog: [String: Exercise] = [:]) -> GeneratedProgram {
        let sessions = program.orderedTemplates.map(generatedSession(from:))
        var weeklyVolume: [MuscleGroup: Double] = [:]
        for session in sessions where !session.isRestDay {
            for slot in session.exercises {
                guard let exercise = catalog[slot.exerciseID] else { continue }
                for (group, credit) in exercise.metadata.volumeContribution {
                    weeklyVolume[group, default: 0] += credit * Double(slot.sets)
                }
            }
        }
        return GeneratedProgram(
            splitKey: program.splitKey,
            daysPerWeek: program.daysPerWeek,
            sessions: sessions,
            weeklyVolume: weeklyVolume,
            explanations: [],
            mesocycleLengthWeeks: program.mesocycleLengthWeeks
        )
    }

    // MARK: - Private helpers

    /// Materialises one generated session as a template plus its exercise rows.
    @discardableResult
    private func makeTemplate(
        from session: GeneratedSession,
        in program: TrainingProgram,
        now: Date
    ) -> WorkoutTemplate {
        let template = WorkoutTemplate()
        template.orderIndex = session.orderIndex
        template.titleKey = session.titleKey
        template.customTitle = session.customTitle
        template.weekday = session.weekday
        template.estimatedMinutes = InputValidation.clampedSessionMinutes(session.estimatedMinutes)
        template.focusGroups = session.focusGroups
        template.pushPull = session.pushPull
        template.isRestDay = session.isRestDay
        template.createdAt = now
        template.updatedAt = now
        context.insert(template)
        template.program = program

        for slot in session.exercises.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            let planned = PlannedExercise()
            planned.exerciseID = slot.exerciseID
            planned.orderIndex = slot.orderIndex
            planned.targetSets = InputValidation.clampedSets(slot.sets)
            planned.repRange = InputValidation.clampedRepRange(slot.repRange)
            planned.restSeconds = InputValidation.clampedRestSeconds(slot.restSeconds)
            planned.targetRIR = InputValidation.clampedRIR(slot.targetRIR)
            planned.targetDurationSeconds = slot.targetDurationSeconds.map(InputValidation.clampedSetDurationSeconds)
            planned.targetDistanceMeters = slot.targetDistanceMeters.map(InputValidation.clampedDistanceMeters)
            planned.isLocked = slot.isLocked
            context.insert(planned)
            planned.template = template
        }
        return template
    }

    /// Deep-copies a template into `program` at `orderIndex`.
    @discardableResult
    private func copyTemplate(
        _ source: WorkoutTemplate,
        into program: TrainingProgram,
        orderIndex: Int,
        now: Date
    ) -> WorkoutTemplate {
        let copy = WorkoutTemplate()
        copy.orderIndex = orderIndex
        copy.titleKey = source.titleKey
        copy.customTitle = source.customTitle
        copy.weekday = source.weekday
        copy.estimatedMinutes = source.estimatedMinutes
        copy.focusGroups = source.focusGroups
        copy.pushPull = source.pushPull
        copy.isRestDay = source.isRestDay
        copy.createdAt = now
        copy.updatedAt = now
        context.insert(copy)
        copy.program = program

        for planned in source.orderedExercises {
            let plannedCopy = PlannedExercise()
            plannedCopy.exerciseID = planned.exerciseID
            plannedCopy.orderIndex = planned.orderIndex
            plannedCopy.targetSets = planned.targetSets
            plannedCopy.repLower = planned.repLower
            plannedCopy.repUpper = planned.repUpper
            plannedCopy.restSeconds = planned.restSeconds
            plannedCopy.targetRIR = planned.targetRIR
            plannedCopy.targetDurationSeconds = planned.targetDurationSeconds
            plannedCopy.targetDistanceMeters = planned.targetDistanceMeters
            plannedCopy.isLocked = planned.isLocked
            plannedCopy.notes = planned.notes
            plannedCopy.substitutedFromExerciseID = planned.substitutedFromExerciseID
            context.insert(plannedCopy)
            plannedCopy.template = copy
        }
        return copy
    }

    /// Renumbers template order indices to 0…n−1. Gaps are harmless for sorting but make "insert
    /// after this one" arithmetic fragile, so they are closed after every structural change.
    private func reindexTemplates(of program: TrainingProgram) {
        for (index, template) in program.orderedTemplates.enumerated() { template.orderIndex = index }
    }

    private func reindexExercises(of template: WorkoutTemplate) {
        for (index, planned) in template.orderedExercises.enumerated() { planned.orderIndex = index }
    }
}
