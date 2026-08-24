import Foundation
import Observation
import SwiftData
import SwiftUI

// MARK: - Routing

/// Destinations inside the Program area.
///
/// These live here rather than in `AppRouter` because nothing outside this folder links into a
/// session editor or a version list. A private route enum keeps the shared router free of screens
/// only one feature knows about, and every one of these pushes onto whichever tab's stack the
/// overview was presented in.
enum ProgramRoute: Hashable {
    case editor
    case settings
    case versions
    case templates
    case session(UUID)
    case exercise(String)
}

// MARK: - Weekly volume

/// Where one muscle group's planned volume sits relative to the window the allocator produced.
///
/// Three states rather than a boolean, because "not enough" and "past the recovery ceiling" call
/// for opposite advice and must never be shown with the same affordance.
enum VolumeStatus: String, Hashable, Sendable {
    case belowMinimum
    case inRange
    case aboveCeiling

    var localizationKey: String { "program.volume.status.\(rawValue)" }

    /// Every status carries a symbol as well as a tint: the chart must stay readable to a user who
    /// cannot separate amber from green.
    var symbolName: String {
        switch self {
        case .belowMinimum: "arrow.down.circle"
        case .inRange: "checkmark.circle"
        case .aboveCeiling: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .belowMinimum: .appRecovery
        case .inRange: .appSuccess
        case .aboveCeiling: .appWarning
        }
    }
}

/// One muscle group's row in the weekly volume chart.
///
/// All four numbers are weekly volume *credits*, the unit `VolumeAllocator` works in: a set of
/// bench press is one credit of chest and half a credit of triceps. Mixing credits and performed
/// sets in the same chart would make every compound look like it trained nothing but its target.
struct VolumeRow: Identifiable, Hashable, Sendable {
    let group: MuscleGroup
    let planned: Double
    let minimum: Double
    let target: Double
    let maximum: Double

    var id: MuscleGroup { group }

    /// Tolerance of half a set. Floating-point credit sums land on 11.999999 often enough that an
    /// exact comparison would flag a perfectly on-target program as under-dosed.
    private static let tolerance = 0.05

    var status: VolumeStatus {
        if planned > maximum + Self.tolerance { return .aboveCeiling }
        if planned + Self.tolerance < minimum { return .belowMinimum }
        return .inRange
    }

    /// The axis each bar is drawn against.
    ///
    /// Deliberately per-row rather than shared across the chart. A shared axis would size every bar
    /// against the back's ~20 credits and leave the adductors as an invisible sliver; normalising
    /// each group against its own recovery ceiling makes every bar answer the question the user is
    /// actually asking — "how close is this group to its limit?" — and keeps rows comparable as
    /// fractions rather than as absolute lengths.
    var axisMaximum: Double { max(maximum, planned, target, 1) * 1.08 }

    func fraction(of value: Double) -> Double {
        guard axisMaximum > 0 else { return 0 }
        return min(max(value / axisMaximum, 0), 1)
    }
}

// MARK: - Formatting

enum ProgramFormat {
    /// Volume credits, read as sets. Whole values lose the decimal, because "12 sets" is what a
    /// person says and "12.0 sets" is what a spreadsheet says.
    static func sets(_ credits: Double) -> String {
        let rounded = (credits * 10).rounded() / 10
        let digits = abs(rounded - rounded.rounded()) < 0.05 ? 0 : 1
        return Units.formatDecimal(rounded, digits: digits)
    }
}

// MARK: - Engine context

/// Everything the training engines need about the user, gathered once per load.
///
/// Built on the main actor from the repositories, then handed to engines that run off it. Keeping
/// it a `Sendable` value type is what lets program generation — which scores the whole catalogue
/// against every slot — happen without blocking the scroll.
struct ProgramContext: Sendable {
    var profile: TrainingProfileSnapshot
    var preferences: [String: ExercisePreferenceSnapshot]
    var histories: [String: ExerciseHistorySnapshot]
    var recovery: RecoverySnapshot
    var increments: EquipmentIncrements
    var recentlyUsedIDs: [String]
    /// Standing weekly targets, computed against a fully recovered week — see `ProgramViewModel`.
    var targets: VolumeTargets
    var weekIndex: Int
    var lockedExerciseIDs: Set<String>

    func request(isDeloadWeek: Bool = false, seed: UInt64 = 0x5EED) -> ProgrammingRequest {
        var request = ProgrammingRequest(profile: profile)
        request.preferences = preferences
        request.histories = histories
        request.recovery = recovery
        request.increments = increments
        request.weekIndex = weekIndex
        request.isDeloadWeek = isDeloadWeek
        request.recentlyUsedExerciseIDs = recentlyUsedIDs
        request.lockedExerciseIDs = lockedExerciseIDs
        request.randomSeed = seed
        return request
    }
}

// MARK: - Building a program from a chosen split

/// Fills the blueprints of a split the *user* picked, rather than the one the engine ranked first.
///
/// `WorkoutProgrammingEngine` chooses its own split and offers no way to override it, which is
/// correct for automatic generation and useless for a screen whose entire promise is that the user
/// may overrule the engine. So the structural decision — how many sessions, what each one trains,
/// how many sets each slot gets — comes from the `SelectedSplit` the user chose, and the hard part,
/// picking a specific exercise for each hole, still goes through `ExerciseRecommendationEngine`.
///
/// The prescriptions here are deliberately plainer than the engine's: rest and reps come from the
/// movement's own metadata rather than being bent by goal. The user reached this path by taking
/// manual control, and every number is editable in the session editor a tap away.
struct SplitProgramBuilder: Sendable {
    private let byID: [String: Exercise]
    private let recommender: ExerciseRecommendationEngine

    init(catalog: [Exercise]) {
        self.byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.recommender = ExerciseRecommendationEngine(catalog: catalog)
    }

    func build(split: SelectedSplit, request: ProgrammingRequest, mesocycleWeeks: Int) -> GeneratedProgram {
        let profile = request.profile
        let weekdays = SplitSelector.trainingWeekdays(profile: profile, count: split.blueprints.count)

        // Locked ids arrive as a Set. Sorting them first is not cosmetic: without it, two runs over
        // the same program would place the same pins in different slots.
        let locks = request.lockedExerciseIDs.sorted()
        var placed = Set<String>()
        var slotAssignment: [Int: [Int: String]] = [:]

        for (sessionIndex, blueprint) in split.blueprints.enumerated() {
            for (slotIndex, slot) in blueprint.slots.enumerated() {
                let match = locks.first { id in
                    guard !placed.contains(id), let exercise = byID[id] else { return false }
                    guard exercise.primaryGroup == slot.group else { return false }
                    if let mechanic = slot.mechanic, exercise.metadata.mechanic != mechanic { return false }
                    return true
                }
                guard let match else { continue }
                slotAssignment[sessionIndex, default: [:]][slotIndex] = match
                placed.insert(match)
            }
        }

        // A pin that fits no slot in the new structure is still the user's decision, so it is
        // appended to the session that trains it rather than quietly dropped.
        var extras: [Int: [String]] = [:]
        for id in locks where !placed.contains(id) {
            guard let exercise = byID[id] else { continue }
            let home = split.blueprints.firstIndex { $0.focusGroups.contains(exercise.primaryGroup) } ?? 0
            extras[home, default: []].append(id)
        }

        var weekSelected = Set<String>()
        var sessions: [GeneratedSession] = []

        for (sessionIndex, blueprint) in split.blueprints.enumerated() {
            var sessionSelected = Set<String>()
            var patternsUsed = Set<MovementPattern>()
            var exercises: [GeneratedExercise] = []

            for (slotIndex, slot) in blueprint.slots.enumerated() {
                var chosen: Exercise?
                var isLocked = false
                if let lockedID = slotAssignment[sessionIndex]?[slotIndex], let exercise = byID[lockedID] {
                    chosen = exercise
                    isLocked = true
                } else {
                    chosen = fill(
                        slot: slot,
                        lateInSession: Double(slotIndex) >= Double(blueprint.slots.count) * 0.6,
                        request: request,
                        excluding: sessionSelected.union(weekSelected),
                        patternsUsed: patternsUsed
                    )
                }
                guard let exercise = chosen else { continue }
                sessionSelected.insert(exercise.id)
                weekSelected.insert(exercise.id)
                patternsUsed.insert(exercise.metadata.movementPattern)

                // A slot that wanted a heavy compound but could only be filled with an isolation is
                // no longer the session's main lift, and must not inherit the primary treatment.
                var effective = slot
                if effective.isPrimary && exercise.metadata.mechanic == .isolation { effective.isPrimary = false }
                exercises.append(prescribe(
                    exercise, slot: effective, profile: profile,
                    orderIndex: exercises.count, isLocked: isLocked
                ))
            }

            for lockedID in extras[sessionIndex] ?? [] {
                guard let exercise = byID[lockedID], !sessionSelected.contains(lockedID) else { continue }
                sessionSelected.insert(lockedID)
                weekSelected.insert(lockedID)
                let slot = ExerciseSlot(
                    group: exercise.primaryGroup,
                    mechanic: exercise.metadata.mechanic,
                    preferredPattern: exercise.metadata.movementPattern,
                    sets: 3,
                    isPrimary: false
                )
                exercises.append(prescribe(
                    exercise, slot: slot, profile: profile,
                    orderIndex: exercises.count, isLocked: true
                ))
            }

            var focus: [MuscleGroup] = []
            var seen = Set<MuscleGroup>()
            for slot in blueprint.slots where slot.group != .cardio {
                if seen.insert(slot.group).inserted { focus.append(slot.group) }
            }

            sessions.append(GeneratedSession(
                orderIndex: sessionIndex,
                titleKey: blueprint.titleKey,
                weekday: sessionIndex < weekdays.count ? weekdays[sessionIndex] : nil,
                focusGroups: focus.isEmpty ? blueprint.focusGroups : focus,
                pushPull: blueprint.pushPull,
                estimatedMinutes: estimatedMinutes(sets: exercises.reduce(0) { $0 + $1.sets }),
                isRestDay: false,
                exercises: exercises
            ))
        }

        // Everything the user is not training becomes an explicit rest day, so the week reads as a
        // week rather than as a list of four workouts floating in space.
        let used = Set(sessions.compactMap(\.weekday))
        for weekday in Weekday.orderedMondayFirst where !used.contains(weekday) {
            sessions.append(GeneratedSession(
                orderIndex: sessions.count,
                titleKey: "session.title.rest",
                weekday: weekday,
                focusGroups: [],
                pushPull: .neutral,
                estimatedMinutes: 0,
                isRestDay: true
            ))
        }
        sessions.sort { lhs, rhs in
            let left = lhs.weekday?.orderIndex ?? 99
            let right = rhs.weekday?.orderIndex ?? 99
            if left != right { return left < right }
            return lhs.orderIndex < rhs.orderIndex
        }
        for index in sessions.indices { sessions[index].orderIndex = index }

        return GeneratedProgram(
            splitKey: split.key,
            daysPerWeek: split.daysPerWeek,
            sessions: sessions,
            weeklyVolume: VolumeAllocator.weeklyVolume(of: sessions, catalog: byID),
            explanations: [split.explanation],
            mesocycleLengthWeeks: mesocycleWeeks
        )
    }

    /// Finds an exercise for one slot, relaxing the slot's stylistic preferences before its
    /// structural ones — pattern first, then mechanic — so a user with an unusual equipment list
    /// still gets a session rather than a hole.
    private func fill(
        slot: ExerciseSlot,
        lateInSession: Bool,
        request: ProgrammingRequest,
        excluding: Set<String>,
        patternsUsed: Set<MovementPattern>
    ) -> Exercise? {
        let relaxations: [(MovementPattern?, Mechanic?)] = [
            (slot.preferredPattern, slot.mechanic),
            (nil, slot.mechanic),
            (nil, nil)
        ]
        for (pattern, mechanic) in relaxations {
            var selection = ExerciseSelectionRequest(targetGroup: slot.group, profile: request.profile)
            selection.preferredPattern = pattern
            selection.preferredMechanic = mechanic
            selection.preferences = request.preferences
            selection.histories = request.histories
            selection.alreadySelected = excluding
            selection.recentlyUsedIDs = Set(request.recentlyUsedExerciseIDs)
            selection.patternsUsed = patternsUsed
            selection.favorLowFatigue = lateInSession
            if let pick = recommender.best(selection, count: 1).first { return pick }
        }
        return nil
    }

    private func prescribe(
        _ exercise: Exercise,
        slot: ExerciseSlot,
        profile: TrainingProfileSnapshot,
        orderIndex: Int,
        isLocked: Bool
    ) -> GeneratedExercise {
        let metadata = exercise.metadata

        // The same margin rules the engine applies: a failed heavy compound is dangerous in a way a
        // failed cable curl is not, and a light isolation is exactly where training close to failure
        // is safe and productive.
        var rir = profile.defaultTargetRIR
        if slot.isPrimary && metadata.fatigueCost >= 0.70 { rir += 1 }
        if metadata.mechanic == .isolation && metadata.fatigueCost < 0.25 { rir -= 1 }

        var rest = Double(metadata.defaultRestSeconds) * VolumeAllocator.restFactor(for: profile.goals)
        if slot.isPrimary { rest *= 1.10 }

        var duration: Int?
        if metadata.trackingMode.usesDuration {
            duration = min(120, max(20, metadata.estimatedSetSeconds))
        }

        return GeneratedExercise(
            exerciseID: exercise.id,
            orderIndex: orderIndex,
            sets: max(1, min(5, slot.sets)),
            repRange: metadata.recommendedRepRange,
            restSeconds: min(300, max(30, Int(rest.rounded()))),
            targetRIR: min(5, max(1, rir)),
            targetDurationSeconds: duration,
            targetDistanceMeters: nil,
            isLocked: isLocked,
            rationale: isLocked
                ? Explanation("programming.rationale.locked")
                : (slot.isPrimary ? Explanation("programming.rationale.primary") : nil)
        )
    }

    /// Session length from the allocator's own time model, so a hand-picked split is budgeted the
    /// same way the generated one is.
    private func estimatedMinutes(sets: Int) -> Int {
        let seconds = Double(sets) * VolumeAllocator.averageSetSecondsIncludingRest
        return VolumeAllocator.sessionOverheadMinutes + Int((seconds / 60).rounded())
    }
}

// MARK: - View model

/// Owns everything the program screens read and every change they make.
///
/// One instance is created by `ProgramOverviewView` and handed down to the editor, the session
/// editor, settings, history and the template library. That is deliberate: the weekly volume chart
/// has to react to a set added three screens deep, and it can only do that if all of them are
/// looking at the same state.
///
/// Every mutation goes through `ProgramRepository`. The view model never touches a
/// `FetchDescriptor` and never saves a context itself, so the two invariants the repository
/// enforces — one active program, and history that is appended to but never erased — cannot be
/// broken from the UI.
@MainActor
@Observable
final class ProgramViewModel {

    enum Phase: Equatable {
        case loading
        /// Loaded successfully, but there is no program yet.
        case empty
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var program: TrainingProgram?
    private(set) var context: ProgramContext?
    private(set) var volumeRows: [VolumeRow] = []
    /// The reasoning behind the split this program actually uses.
    private(set) var splitExplanation: Explanation?
    /// Every structure the selector considered for this day count, best first.
    private(set) var candidateSplits: [SelectedSplit] = []
    /// Other programs the user has kept, newest first. Excludes the template library.
    private(set) var otherPrograms: [TrainingProgram] = []
    /// The program's history, newest first.
    private(set) var versions: [ProgramVersion] = []
    private(set) var catalogByID: [String: Exercise] = [:]

    /// True while an engine run or a multi-step write is in flight. Screens disable their
    /// destructive controls against it rather than showing a blocking spinner.
    private(set) var isWorking = false
    /// Surfaced as an alert. An action failing must not tear down a screen the user is working in.
    var actionError: String?
    /// Short confirmation of the last successful action.
    var notice: String?

    private var modelContext: ModelContext?
    private var catalog: ExerciseCatalog?

    // MARK: - Loading

    func load(modelContext: ModelContext, catalog: ExerciseCatalog) async {
        self.modelContext = modelContext
        self.catalog = catalog
        if phase != .ready { phase = .loading }
        // Let the loading state paint before the repositories start reading.
        await Task.yield()
        reload()
    }

    /// Re-reads everything from the store. Cheap enough to call after any mutation, and doing so is
    /// what keeps the chart, the session list and the version count in step with each other.
    func reload() {
        guard let modelContext, let catalog else { return }
        do {
            if catalogByID.count != catalog.exercises.count {
                catalogByID = Dictionary(
                    catalog.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
                )
            }
            let programs = ProgramRepository(context: modelContext)
            let active = try programs.activeProgram()
            program = active
            otherPrograms = try programs.allPrograms().filter {
                $0.id != active?.id && $0.splitKey != TemplateLibrary.splitKey
            }
            versions = active.map(programs.versions(of:)) ?? []

            let built = try buildContext(modelContext: modelContext, program: active)
            context = built
            candidateSplits = SplitSelector.candidates(
                daysPerWeek: built.profile.daysPerWeek, profile: built.profile
            )
            splitExplanation = active.flatMap { program in
                candidateSplits.first { $0.key == program.splitKey }?.explanation
            }
            recomputeVolume()
            phase = active == nil ? .empty : .ready
        } catch {
            phase = .failed(message(for: error))
        }
    }

    private func buildContext(modelContext: ModelContext, program: TrainingProgram?) throws -> ProgramContext {
        let profiles = ProfileRepository(context: modelContext)
        let workouts = WorkoutRepository(context: modelContext)
        let progress = ProgressRepository(context: modelContext)
        let preferences = ExercisePreferenceRepository(context: modelContext)

        let profile = try profiles.trainingProfileSnapshot()
        let outcomes = try workouts.recentSessions(limit: 12).map {
            workouts.sessionOutcome(for: $0, catalog: catalogByID)
        }
        let recovery = RecoveryEngine.snapshot(
            sessions: outcomes,
            wellbeing: try progress.wellbeingSnapshots(limit: 14),
            profile: profile
        )

        let plannedIDs = program?.templates.flatMap { $0.plannedExercises.map(\.exerciseID) } ?? []
        let recentIDs = try preferences.recentlyPerformedIDs(limit: 40)

        return ProgramContext(
            profile: profile,
            preferences: try preferences.snapshots(),
            histories: try workouts.histories(forExerciseIDs: plannedIDs + recentIDs),
            recovery: recovery,
            increments: try profiles.increments(),
            recentlyUsedIDs: recentIDs,
            // Targets are computed against a *fresh* week on purpose. The program is a standing
            // plan, and comparing it against a fatigue-adjusted target would make the identical,
            // unchanged program read as "too much" on a tired Monday and "too little" after a rest
            // week. Regeneration, further down, does pass the real recovery snapshot: adjusting the
            // plan for fatigue is the engine's job, not the chart's.
            targets: VolumeAllocator.targets(for: profile, recovery: .fresh, isDeloadWeek: false),
            weekIndex: program?.completedWeeks ?? 0,
            lockedExerciseIDs: Set(
                (program?.templates ?? [])
                    .flatMap(\.plannedExercises)
                    .filter(\.isLocked)
                    .map(\.exerciseID)
            )
        )
    }

    /// Recomputes planned volume from whatever is in the store right now.
    ///
    /// Called after every edit, which is what makes "add a set and watch the chart move" true
    /// rather than a claim. Summing credits across at most a few dozen slots costs nothing.
    func recomputeVolume() {
        guard let program, let context, let modelContext else { volumeRows = []; return }
        let repository = ProgramRepository(context: modelContext)
        let sessions = program.orderedTemplates.map(repository.generatedSession(from:))
        let planned = VolumeAllocator.weeklyVolume(of: sessions, catalog: catalogByID)

        volumeRows = MuscleGroup.volumeTracked.compactMap { group in
            let target = context.targets.target[group] ?? 0
            let plannedCredits = planned[group] ?? 0
            // Groups with neither a budget nor any planned work are noise, not information.
            guard target > 0.5 || plannedCredits > 0.5 else { return nil }
            return VolumeRow(
                group: group,
                planned: plannedCredits,
                minimum: context.targets.minimum[group] ?? 0,
                target: target,
                maximum: context.targets.maximum[group] ?? 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.target != rhs.target { return lhs.target > rhs.target }
            return lhs.group.rawValue < rhs.group.rawValue
        }
    }

    /// Rows for the groups a single session touches, used by the session editor.
    func volumeRows(touching groups: Set<MuscleGroup>) -> [VolumeRow] {
        volumeRows.filter { groups.contains($0.group) }
    }

    /// Groups that receive credit from a template, primary and indirect alike.
    func groups(in template: WorkoutTemplate) -> Set<MuscleGroup> {
        var result = Set(template.focusGroups)
        for planned in template.plannedExercises {
            guard let exercise = catalogByID[planned.exerciseID] else { continue }
            for (group, credit) in exercise.metadata.volumeContribution where credit > 0 {
                result.insert(group)
            }
        }
        return result
    }

    func exercise(_ id: String) -> Exercise? { catalogByID[id] }

    func template(_ id: UUID) -> WorkoutTemplate? {
        program?.templates.first { $0.id == id }
    }

    /// The engine's own first choice for this user, whether or not the program follows it.
    var recommendedSplit: SelectedSplit? { candidateSplits.first }

    var isFollowingRecommendedSplit: Bool {
        guard let program, let recommendedSplit else { return false }
        return program.splitKey == recommendedSplit.key
    }

    // MARK: - Generating and regenerating

    /// Runs the programming engine and writes the result.
    ///
    /// Creates the first program when there is none, and otherwise replaces the contents of the
    /// existing one so its identity and its whole version history survive. Locked exercises travel
    /// into the request, so the engine keeps them; sessions already performed are untouched,
    /// because a `WorkoutSession` copied its plan at the moment it started.
    func regenerate(reason: Explanation, isDeloadWeek: Bool = false, mesocycleWeeks: Int? = nil) async {
        guard let modelContext, let catalog, let context else { return }
        isWorking = true
        defer { isWorking = false }

        let request = context.request(isDeloadWeek: isDeloadWeek, seed: seed())
        let exercises = catalog.exercises
        var generated = await Task.detached(priority: .userInitiated) {
            WorkoutProgrammingEngine(catalog: exercises).generate(request)
        }.value
        if let mesocycleWeeks {
            generated.mesocycleLengthWeeks = InputValidation.clampedMesocycleWeeks(mesocycleWeeks)
        }

        do {
            let repository = ProgramRepository(context: modelContext)
            if let program {
                try repository.apply(generated, to: program, reason: reason)
            } else {
                try repository.install(
                    generated,
                    profile: context.profile,
                    title: L(generated.splitKey),
                    reason: reason
                )
            }
            notice = L("program.notice.regenerated")
            reload()
        } catch {
            actionError = message(for: error)
        }
    }

    /// Rebuilds the week around a split the user chose instead of the one the engine ranked first.
    func applySplit(_ split: SelectedSplit) async {
        guard let modelContext, let catalog, let context else { return }
        isWorking = true
        defer { isWorking = false }

        let request = context.request(seed: seed())
        let exercises = catalog.exercises
        let weeks = program?.mesocycleLengthWeeks ?? 5
        let generated = await Task.detached(priority: .userInitiated) {
            SplitProgramBuilder(catalog: exercises).build(
                split: split, request: request, mesocycleWeeks: weeks
            )
        }.value

        // The split's own name is resolved now rather than stored as a key, matching how the
        // repository records a clone's source title. A later language switch leaves this one line of
        // history in the language it was written in, which is the lesser of the two evils against
        // showing a raw identifier.
        let reason = Explanation("program.version.splitChanged", [L(split.key)])
        do {
            let repository = ProgramRepository(context: modelContext)
            if let program {
                try repository.apply(generated, to: program, reason: reason)
            } else {
                try repository.install(
                    generated, profile: context.profile, title: L(split.key), reason: reason
                )
            }
            notice = L("program.notice.splitChanged", L(split.key))
            reload()
        } catch {
            actionError = message(for: error)
        }
    }

    /// Rebuilds a single session against its own blueprint, keeping anything pinned inside it.
    func regenerateSession(_ template: WorkoutTemplate) async {
        guard let modelContext, let catalog, let context else { return }
        isWorking = true
        defer { isWorking = false }

        let repository = ProgramRepository(context: modelContext)
        let session = repository.generatedSession(from: template)
        let request = context.request(seed: seed())
        let exercises = catalog.exercises
        let rebuilt = await Task.detached(priority: .userInitiated) {
            WorkoutProgrammingEngine(catalog: exercises).regenerateSession(session, request: request)
        }.value

        do {
            for planned in template.orderedExercises {
                try repository.removeExercise(planned)
            }
            for slot in rebuilt.exercises.sorted(by: { $0.orderIndex < $1.orderIndex }) {
                try repository.addExercise(
                    exerciseID: slot.exerciseID,
                    to: template,
                    sets: slot.sets,
                    repRange: slot.repRange,
                    restSeconds: slot.restSeconds,
                    targetRIR: slot.targetRIR,
                    targetDurationSeconds: slot.targetDurationSeconds,
                    targetDistanceMeters: slot.targetDistanceMeters,
                    isLocked: slot.isLocked
                )
            }
            if let program {
                try repository.recordEngineChange(
                    to: program,
                    reason: Explanation("program.version.sessionRegenerated", [title(of: template)])
                )
            }
            notice = L("program.notice.sessionRegenerated")
            reload()
        } catch {
            actionError = message(for: error)
        }
    }

    /// A seed derived from the program's identity and how far through the mesocycle it is.
    ///
    /// Fixed per program and per week rather than random, so pressing "regenerate" twice without
    /// changing anything produces the same plan — a plan that reshuffles under an unchanged input
    /// is one the user cannot reason about. `hashValue` is deliberately not used: Swift seeds it
    /// per process, so it would produce a different plan after every app launch.
    private func seed() -> UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        guard let program else { return value }
        for byte in program.id.uuidString.utf8 {
            value = (value ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return value &+ UInt64(program.completedWeeks) &* 0x9E37_79B9
    }

    // MARK: - Program-level actions

    func createManualProgram(title: String, daysPerWeek: Int) {
        guard let modelContext, let context else { return }
        perform(.full) {
            try ProgramRepository(context: modelContext).createEmptyProgram(
                title: title,
                daysPerWeek: daysPerWeek,
                profile: context.profile
            )
            self.notice = L("program.notice.created")
        }
    }

    func cloneCurrentProgram(title: String) {
        guard let modelContext, let program else { return }
        perform(.full) {
            try ProgramRepository(context: modelContext).clone(program, title: title)
            self.notice = L("program.notice.cloned")
        }
    }

    func activate(_ program: TrainingProgram) {
        guard let modelContext else { return }
        perform(.full) {
            try ProgramRepository(context: modelContext).activate(program)
            self.notice = L("program.notice.activated", program.title)
        }
    }

    func delete(_ program: TrainingProgram) {
        guard let modelContext else { return }
        perform(.full) { try ProgramRepository(context: modelContext).delete(program) }
    }

    func renameProgram(to title: String) {
        guard let modelContext, let program else { return }
        perform { try ProgramRepository(context: modelContext).rename(program, to: title) }
    }

    // MARK: - Sessions

    func addSession(isRestDay: Bool, weekday: Weekday?) {
        guard let modelContext, let program else { return }
        perform {
            try ProgramRepository(context: modelContext).addTemplate(
                to: program,
                titleKey: isRestDay ? "session.title.rest" : "session.untitled",
                weekday: weekday,
                estimatedMinutes: isRestDay ? 10 : 60,
                isRestDay: isRestDay
            )
        }
    }

    func duplicateSession(_ template: WorkoutTemplate) {
        guard let modelContext else { return }
        perform { try ProgramRepository(context: modelContext).duplicateTemplate(template) }
    }

    func deleteSession(_ template: WorkoutTemplate) {
        guard let modelContext else { return }
        perform { try ProgramRepository(context: modelContext).deleteTemplate(template) }
    }

    func moveSessions(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let modelContext, let program else { return }
        perform {
            try ProgramRepository(context: modelContext).moveTemplates(
                in: program, fromOffsets: source, toOffset: destination
            )
        }
    }

    func renameSession(_ template: WorkoutTemplate, to title: String?) {
        guard let modelContext else { return }
        perform { try ProgramRepository(context: modelContext).renameTemplate(template, to: title) }
    }

    func setWeekday(_ weekday: Weekday?, on template: WorkoutTemplate) {
        guard let modelContext else { return }
        perform { try ProgramRepository(context: modelContext).setWeekday(weekday, on: template) }
    }

    /// How long a session will take, computed from what is in it right now.
    ///
    /// `WorkoutTemplate.estimatedMinutes` is a figure frozen at generation time, and the moment the
    /// user adds two sets it is a lie. Recomputing it for display costs nothing and means the number
    /// on screen always describes the plan on screen. The 40 s per exercise is the same setup
    /// allowance `WorkoutProgrammingEngine` budgets: finding the bench, setting the pin, loading the
    /// bar.
    func estimatedMinutes(of template: WorkoutTemplate) -> Int {
        guard !template.isRestDay else { return 0 }
        var seconds = 0.0
        for planned in template.plannedExercises {
            let work = Double(
                planned.targetDurationSeconds
                    ?? catalogByID[planned.exerciseID]?.metadata.estimatedSetSeconds
                    ?? 45
            )
            seconds += Double(planned.targetSets) * (work + Double(planned.restSeconds)) + 40
        }
        guard seconds > 0 else { return 0 }
        return VolumeAllocator.sessionOverheadMinutes + Int((seconds / 60).rounded())
    }

    /// The name to show for a session: the user's own if they set one, the catalogue title if not.
    func title(of template: WorkoutTemplate) -> String {
        if let custom = template.customTitle, !custom.isEmpty { return custom }
        return L(template.titleKey)
    }

    // MARK: - Exercises inside a session

    func addExercise(_ exerciseID: String, to template: WorkoutTemplate) {
        guard let modelContext else { return }
        let exercise = catalogByID[exerciseID]
        perform {
            try ProgramRepository(context: modelContext).addExercise(
                exerciseID: exerciseID,
                to: template,
                sets: 3,
                repRange: exercise?.metadata.recommendedRepRange ?? .hypertrophy,
                restSeconds: exercise?.metadata.defaultRestSeconds ?? 120,
                targetRIR: self.context?.profile.defaultTargetRIR ?? 2,
                targetDurationSeconds: (exercise?.metadata.trackingMode.usesDuration ?? false)
                    ? min(120, max(20, exercise?.metadata.estimatedSetSeconds ?? 45))
                    : nil
            )
        }
    }

    func removeExercise(_ planned: PlannedExercise) {
        guard let modelContext else { return }
        perform { try ProgramRepository(context: modelContext).removeExercise(planned) }
    }

    func moveExercises(in template: WorkoutTemplate, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let modelContext else { return }
        perform {
            try ProgramRepository(context: modelContext).moveExercises(
                in: template, fromOffsets: source, toOffset: destination
            )
        }
    }

    func setLocked(_ locked: Bool, on planned: PlannedExercise) {
        guard let modelContext else { return }
        perform { try ProgramRepository(context: modelContext).setLocked(locked, on: planned) }
    }

    func updatePrescription(
        of planned: PlannedExercise,
        sets: Int? = nil,
        repRange: RepRange? = nil,
        restSeconds: Int? = nil,
        targetRIR: Int? = nil,
        targetDurationSeconds: Int?? = nil,
        notes: String?? = nil
    ) {
        guard let modelContext else { return }
        perform {
            try ProgramRepository(context: modelContext).updatePrescription(
                of: planned,
                sets: sets,
                repRange: repRange,
                restSeconds: restSeconds,
                targetRIR: targetRIR,
                targetDurationSeconds: targetDurationSeconds,
                notes: notes
            )
        }
    }

    /// Swaps the movement in a slot, keeping the dose. Optionally records the user's reason as
    /// standing feedback, so the same swap does not have to be made again next month.
    func substitute(_ planned: PlannedExercise, with exerciseID: String, reason: SubstitutionReason?) {
        guard let modelContext else { return }
        perform {
            let repository = ProgramRepository(context: modelContext)
            let replaced = planned.exerciseID
            try repository.substitute(planned, withExerciseID: exerciseID)
            if reason == .dislike {
                try ExercisePreferenceRepository(context: modelContext)
                    .setFeedback(.dislike, forExerciseID: replaced)
            }
            if let program = self.program {
                try repository.recordEngineChange(
                    to: program,
                    reason: Explanation("program.version.exerciseSwapped", [
                        self.catalogByID[replaced]?.name.localizedCapitalized ?? replaced,
                        self.catalogByID[exerciseID]?.name.localizedCapitalized ?? exerciseID
                    ])
                )
            }
        }
    }

    /// Puts the engine's original choice back into a slot the user swapped.
    func restoreRecommendation(for planned: PlannedExercise) {
        guard let modelContext, let original = planned.substitutedFromExerciseID else { return }
        perform {
            try ProgramRepository(context: modelContext).substitute(planned, withExerciseID: original)
            self.notice = L("program.notice.restored")
        }
    }

    // MARK: - Standing exercise opinions

    func isFavorite(_ exerciseID: String) -> Bool {
        context?.preferences[exerciseID]?.isFavorite ?? false
    }

    func isExcluded(_ exerciseID: String) -> Bool {
        context?.preferences[exerciseID]?.isExcluded ?? false
    }

    func setFavorite(_ isFavorite: Bool, exerciseID: String) {
        guard let modelContext else { return }
        perform {
            try ExercisePreferenceRepository(context: modelContext)
                .setFavorite(isFavorite, forExerciseID: exerciseID)
        }
    }

    /// Excludes an exercise from every future recommendation. The slot it occupied is left alone —
    /// removing it silently would be the app overruling the user in the middle of their own edit.
    func setExcluded(_ isExcluded: Bool, exerciseID: String) {
        guard let modelContext else { return }
        perform {
            try ExercisePreferenceRepository(context: modelContext)
                .setExcluded(isExcluded, forExerciseID: exerciseID)
            self.notice = isExcluded
                ? L("program.notice.excluded")
                : L("program.notice.excludeCleared")
        }
    }

    // MARK: - Version history

    /// Reading a stored version can fail — an older build may have saved a row whose blob would not
    /// encode — and the history screen has to say so per row rather than refusing to open.
    enum SnapshotOutcome {
        case snapshot(ProgramSnapshot)
        case failure(String)
    }

    func snapshot(of version: ProgramVersion) -> SnapshotOutcome {
        guard let modelContext else { return .failure(L("program.error.generic")) }
        do {
            return .snapshot(try ProgramRepository(context: modelContext).snapshot(of: version))
        } catch {
            return .failure(message(for: error))
        }
    }

    // MARK: - Templates

    /// Saves a session into the template library, exercises and prescriptions included.
    func saveAsTemplate(_ template: WorkoutTemplate) {
        guard let modelContext, let context else { return }
        perform {
            let repository = ProgramRepository(context: modelContext)
            let library = try TemplateLibrary.container(in: repository, profile: context.profile)
            let copy = try repository.addTemplate(
                to: library,
                titleKey: template.titleKey,
                customTitle: template.customTitle ?? L(template.titleKey),
                weekday: nil,
                focusGroups: template.focusGroups,
                pushPull: template.pushPull,
                estimatedMinutes: template.estimatedMinutes,
                isRestDay: template.isRestDay
            )
            for planned in template.orderedExercises {
                try repository.addExercise(
                    exerciseID: planned.exerciseID,
                    to: copy,
                    sets: planned.targetSets,
                    repRange: planned.repRange,
                    restSeconds: planned.restSeconds,
                    targetRIR: planned.targetRIR,
                    targetDurationSeconds: planned.targetDurationSeconds,
                    targetDistanceMeters: planned.targetDistanceMeters,
                    isLocked: planned.isLocked,
                    notes: planned.notes
                )
            }
            self.notice = L("program.notice.templateSaved")
        }
    }

    /// Every saved template, in the order they were saved.
    func savedTemplates() -> [WorkoutTemplate] {
        guard let modelContext else { return [] }
        do {
            let repository = ProgramRepository(context: modelContext)
            return try TemplateLibrary.existingContainer(in: repository)?.orderedTemplates ?? []
        } catch {
            return []
        }
    }

    /// Adds a saved template to the active program as a new session.
    func applyTemplate(_ template: WorkoutTemplate) {
        guard let modelContext, let program else { return }
        perform {
            let repository = ProgramRepository(context: modelContext)
            let session = try repository.addTemplate(
                to: program,
                titleKey: template.titleKey,
                customTitle: template.customTitle,
                weekday: nil,
                focusGroups: template.focusGroups,
                pushPull: template.pushPull,
                estimatedMinutes: template.estimatedMinutes,
                isRestDay: template.isRestDay
            )
            for planned in template.orderedExercises {
                try repository.addExercise(
                    exerciseID: planned.exerciseID,
                    to: session,
                    sets: planned.targetSets,
                    repRange: planned.repRange,
                    restSeconds: planned.restSeconds,
                    targetRIR: planned.targetRIR,
                    targetDurationSeconds: planned.targetDurationSeconds,
                    targetDistanceMeters: planned.targetDistanceMeters,
                    isLocked: planned.isLocked,
                    notes: planned.notes
                )
            }
            self.notice = L("program.notice.templateApplied")
        }
    }

    func duplicateTemplate(_ template: WorkoutTemplate) {
        guard let modelContext else { return }
        perform { try ProgramRepository(context: modelContext).duplicateTemplate(template) }
    }

    func deleteTemplate(_ template: WorkoutTemplate) {
        guard let modelContext else { return }
        perform { try ProgramRepository(context: modelContext).deleteTemplate(template) }
    }

    // MARK: - Settings that feed the engines

    /// Writes the availability, priority and progression settings the engines read, then reloads so
    /// the recommended split and the volume targets on screen reflect them immediately.
    func updateTrainingSettings(
        weekdays: [Weekday],
        sessionMinutes: Int,
        priorityGroups: [MuscleGroup],
        progressionStrategy: ProgressionStrategy,
        deloadSuggestionsEnabled: Bool,
        autoProgressionEnabled: Bool
    ) {
        guard let modelContext else { return }
        perform(.full) {
            let profiles = ProfileRepository(context: modelContext)
            try profiles.updateAvailability(weekdays: weekdays, sessionMinutesCap: sessionMinutes)
            try profiles.updateGoals(priorityGroups: priorityGroups)
            try profiles.updateSettings { settings in
                settings.progressionStrategy = progressionStrategy
                settings.deloadSuggestionsEnabled = deloadSuggestionsEnabled
                settings.autoProgressionEnabled = autoProgressionEnabled
            }
        }
    }

    func currentSettings() -> UserSettings? {
        guard let modelContext else { return nil }
        return try? ProfileRepository(context: modelContext).settings()
    }

    // MARK: - Plumbing

    /// How much has to be recomputed after a mutation.
    ///
    /// This distinction is not premature optimisation. `reload()` rebuilds the whole engine context
    /// — recent sessions, per-exercise history, a fresh recovery snapshot — and a set stepper can
    /// fire ten times in two seconds. Prescription edits therefore take the cheap path, which
    /// touches only the numbers that can actually have changed; anything that alters who the user is
    /// or which program is active takes the full one.
    enum Refresh {
        case light
        case full
    }

    /// Runs a store mutation, refreshes derived state, and turns any failure into an alert rather
    /// than into a screen the user cannot leave.
    private func perform(_ refresh: Refresh = .light, _ work: () throws -> Void) {
        do {
            try work()
            switch refresh {
            case .light: refreshDerived()
            case .full: reload()
            }
        } catch {
            actionError = message(for: error)
        }
    }

    /// In-memory recomputation after an edit: the volume chart, the version list, the set of pinned
    /// exercises, and the user's standing opinions. No engine runs and no history is re-read.
    private func refreshDerived() {
        guard let modelContext else { return }
        if var updated = context {
            updated.lockedExerciseIDs = Set(
                (program?.templates ?? [])
                    .flatMap(\.plannedExercises)
                    .filter(\.isLocked)
                    .map(\.exerciseID)
            )
            if let preferences = try? ExercisePreferenceRepository(context: modelContext).snapshots() {
                updated.preferences = preferences
            }
            context = updated
        }
        if let program {
            versions = ProgramRepository(context: modelContext).versions(of: program)
        }
        recomputeVolume()
    }

    private func message(for error: Error) -> String {
        if let repositoryError = error as? RepositoryError {
            if let detail = repositoryError.diagnosticDetail {
                AppLog.persistence.error("Program action failed: \(detail, privacy: .public)")
            }
            return repositoryError.explanation.text
        }
        return L("program.error.generic")
    }
}

// MARK: - Template library

/// Where saved session templates live.
///
/// A template is a `WorkoutTemplate`, and a `WorkoutTemplate` only exists inside a
/// `TrainingProgram`. Rather than inventing a second storage mechanism that backup and export would
/// not know about, the library is an ordinary inactive program identified by its split key. It is
/// filtered out of every program list in this feature, never activated, and travels with the user's
/// data for free.
enum TemplateLibrary {
    /// Marker that distinguishes the library from a real plan. Never shown to the user as a split.
    static let splitKey = "program.library.marker"

    @MainActor
    static func existingContainer(in repository: ProgramRepository) throws -> TrainingProgram? {
        try repository.allPrograms().first { $0.splitKey == splitKey }
    }

    @MainActor
    static func container(
        in repository: ProgramRepository,
        profile: TrainingProfileSnapshot
    ) throws -> TrainingProgram {
        if let existing = try existingContainer(in: repository) { return existing }
        return try repository.createEmptyProgram(
            title: L("program.library.title"),
            splitKey: splitKey,
            daysPerWeek: 1,
            profile: profile,
            activate: false
        )
    }
}
