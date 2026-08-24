import Foundation
import Observation
import SwiftData
import SwiftUI

// MARK: - Shared screen state

/// The four states every screen in this feature renders explicitly.
///
/// `empty` is deliberately distinct from `content`: "you have no program yet" and "your program has
/// nothing on today" are different messages with different ways forward, and collapsing them into an
/// empty content list would leave the user staring at a blank screen with nothing to do.
enum HubScreenState: Equatable {
    case loading
    case content
    case empty
    case failed(String)
}

// MARK: - Value types

/// One editable line of today's plan.
///
/// This is a *draft*, not a stored row. Everything the user changes on the Today screen changes the
/// session that is about to be created, never the template behind it — editing today's squat sets
/// must not silently rewrite every future leg day. The program editor is where the plan itself is
/// changed, and it is a different screen on purpose.
struct HubPlannedItem: Identifiable, Hashable {
    let id: UUID
    var exerciseID: String
    var name: String
    var trackingMode: TrackingMode
    var sets: Int
    var repRange: RepRange
    /// Recommended load in kilograms. `nil` for movements that carry no external load.
    var weightKg: Double?
    var restSeconds: Int
    var targetRIR: Int
    /// Why the engine asked for this load. Absent only when there is no progression state yet.
    var rationale: Explanation?
    /// Set when the user needs to find a working load before the engine can have an opinion.
    var requiresCalibration: Bool
    /// The template slot this row came from. `nil` when the user added it here and now.
    var templateSlotID: UUID?
    /// The exercise the template originally asked for, when the user swapped it before starting.
    var substitutedFrom: String?
    var substitutionReason: SubstitutionReason?

    var isSubstituted: Bool { substitutedFrom != nil }
}

/// Today's session, resolved and ready to edit.
struct HubTodayPlan {
    var templateID: UUID?
    var title: String
    var focusGroups: [MuscleGroup]
    var estimatedMinutes: Int
    var items: [HubPlannedItem]
    /// Programme-level notes: a deload week, a session the user is repeating.
    var notes: [Explanation]

    var totalSets: Int { items.reduce(0) { $0 + $1.sets } }
}

/// A template offered as a quick-start option.
struct HubTemplateOption: Identifiable, Hashable {
    let id: UUID
    var title: String
    var focusGroups: [MuscleGroup]
    var exerciseCount: Int
    var totalSets: Int
    var estimatedMinutes: Int
    var weekday: Weekday?
}

/// One finished session, flattened for a list row.
struct HubSessionSummary: Identifiable, Hashable {
    let id: UUID
    var title: String
    var date: Date
    var durationSeconds: Int
    var volumeKg: Double
    var completedSets: Int
    var plannedSets: Int
    var focusGroups: [MuscleGroup]
    var status: PlannedSessionStatus
    var hasPersonalRecord: Bool
    var templateID: UUID?
    /// Exercise names as performed, used by the search field.
    var exerciseNames: [String]
}

/// The identity of an exercise the user asked to swap before starting.
struct HubSubstitutionTarget: Identifiable, Hashable {
    /// The draft row's id — the swap has to land on the row the user tapped, not on the first row
    /// that happens to hold the same exercise.
    let id: UUID
    var exerciseID: String
}

// MARK: - Calendar

/// What one day on the training calendar is.
///
/// Every state carries a distinct SF Symbol as well as a colour, because a calendar that separates
/// "done" from "missed" by hue alone is unreadable to a large minority of users and unreadable to
/// anybody in bright sunlight outside a gym.
enum HubDayState: String, Hashable {
    case completed
    case inProgress
    case planned
    case missed
    case rest
    case none

    var symbolName: String? {
        switch self {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "play.circle.fill"
        case .planned: "circle.dashed"
        case .missed: "exclamationmark.circle.fill"
        case .rest: "moon.zzz.fill"
        case .none: nil
        }
    }

    var localizationKey: String { "workoutHub.calendar.state.\(rawValue)" }
}

/// One cell of the month grid or the week strip.
struct HubCalendarDay: Identifiable, Hashable {
    var date: Date
    var dayNumber: Int
    var isToday: Bool
    var isInVisibleMonth: Bool
    var state: HubDayState
    var title: String?
    var focusGroups: [MuscleGroup]
    var sessionID: UUID?
    var templateID: UUID?

    var id: Date { date }
}

// MARK: - Rescheduling

/// Rebuilds the remainder of a training week after a session is missed.
///
/// The product rule is explicit: **a missed day must not invalidate the routine.** Two naive
/// responses both break it. Dropping the session quietly deletes a week's worth of volume for
/// whatever it trained. Shoving every remaining session forward by one day stacks two sessions that
/// share a muscle group onto consecutive days, which is worse training than the miss was.
///
/// So the sessions still owed this week are re-seated into the days the user actually has left, and
/// each candidate day is scored on two axes: how far the session drifts from the day it was meant to
/// fall on, and how much recovery it steals from a session that already trained the same muscles.
/// Conflict is weighted far above drift — a day of drift costs nothing, a shared muscle group
/// trained twice in 24 hours costs a week of progress.
///
/// When the week genuinely has no room left the overflow sessions are *not* forced anywhere; they
/// keep their day and are reported as landing next week. Saying so is honest; inventing a Sunday
/// double session is not.
enum SessionRescheduler {

    /// One session still owed this week.
    struct SessionInput: Hashable {
        var templateID: UUID
        var title: String
        var weekday: Weekday?
        var focusGroups: [MuscleGroup]
        var orderIndex: Int
    }

    struct Move: Identifiable, Hashable {
        var id: UUID { templateID }
        var templateID: UUID
        var title: String
        var from: Weekday?
        var to: Weekday
        /// True when this session could not fit in the days left and is simply picked up next week.
        var waitsForNextWeek: Bool
        var explanation: Explanation

        /// Nothing to persist when the day did not actually change.
        var changesSchedule: Bool { from != to && !waitsForNextWeek }
    }

    struct Plan: Identifiable, Hashable {
        let id = UUID()
        var moves: [Move]
        var summary: Explanation

        var hasChanges: Bool { moves.contains(where: \.changesSchedule) }
    }

    /// How much recovery a session steals from one trained the given number of days earlier.
    /// Back-to-back is the case that matters; two days apart is a mild cost; three is nothing.
    private static func proximity(dayGap: Int) -> Double {
        switch abs(dayGap) {
        case 0: 1.0
        case 1: 1.0
        case 2: 0.4
        default: 0.0
        }
    }

    /// Fraction of the muscle groups the two sessions share, 0…1.
    private static func overlap(_ groups: [MuscleGroup], _ other: Set<MuscleGroup>) -> Double {
        guard !groups.isEmpty, !other.isEmpty else { return 0 }
        let shared = groups.filter(other.contains).count
        return Double(shared) / Double(max(groups.count, other.count))
    }

    /// A shared muscle group on an adjacent day costs six times what a day of drift costs. The gap
    /// is deliberately wide: drift is an inconvenience, insufficient recovery is a training error.
    private static let conflictWeight = 6.0
    private static let driftWeight = 1.0

    /// - Parameters:
    ///   - pending: sessions still owed this week — the missed one first, then the rest in
    ///     programme order.
    ///   - availableDays: the weekdays the user said they can train.
    ///   - trainedGroups: muscle groups already trained this week, keyed by the day they fell on.
    ///   - today: the first weekday a session may be placed on.
    static func plan(
        pending: [SessionInput],
        availableDays: [Weekday],
        trainedGroups: [Weekday: Set<MuscleGroup>],
        today: Weekday
    ) -> Plan {
        // Days already spent training are not slots, whatever the availability list says.
        var freeSlots = availableDays
            .filter { $0.orderIndex >= today.orderIndex && trainedGroups[$0] == nil }
            .sorted()

        var occupied = trainedGroups
        var moves: [Move] = []

        for session in pending {
            guard !freeSlots.isEmpty else {
                // The week is full. The session keeps its day and is trained next week.
                let day = session.weekday ?? today
                moves.append(Move(
                    templateID: session.templateID,
                    title: session.title,
                    from: session.weekday,
                    to: day,
                    waitsForNextWeek: true,
                    explanation: Explanation(
                        "workoutHub.reschedule.nextWeek",
                        [session.title, L(day.localizationKey)]
                    )
                ))
                continue
            }

            // Drift is measured from where the session was meant to be, or from today when its day
            // has already gone by.
            let anchor = max(session.weekday?.orderIndex ?? today.orderIndex, today.orderIndex)

            var bestIndex = 0
            var bestCost = Double.greatestFiniteMagnitude
            var bestConflict = 0.0
            for (index, slot) in freeSlots.enumerated() {
                var conflict = 0.0
                for (day, groups) in occupied {
                    let cost = overlap(session.focusGroups, groups)
                        * proximity(dayGap: slot.orderIndex - day.orderIndex)
                    conflict = max(conflict, cost)
                }
                let drift = Double(abs(slot.orderIndex - anchor))
                let cost = conflict * conflictWeight + drift * driftWeight
                if cost < bestCost {
                    bestCost = cost
                    bestIndex = index
                    bestConflict = conflict
                }
            }

            let chosen = freeSlots.remove(at: bestIndex)
            occupied[chosen] = Set(session.focusGroups)

            let explanation: Explanation
            if chosen == session.weekday {
                explanation = Explanation(
                    "workoutHub.reschedule.kept", [session.title, L(chosen.localizationKey)]
                )
            } else if bestConflict > 0.01, let earliest = freeSlots.first, earliest.orderIndex < chosen.orderIndex {
                // The obvious slot was passed over to protect recovery — say which muscles, because
                // "we moved it and will not tell you why" is exactly the behaviour this app avoids.
                let group = session.focusGroups.first.map { L($0.localizationKey) } ?? session.title
                explanation = Explanation(
                    "workoutHub.reschedule.spacing",
                    [session.title, L(chosen.localizationKey), L(earliest.localizationKey), group]
                )
            } else {
                explanation = Explanation(
                    "workoutHub.reschedule.moved",
                    [session.title, session.weekday.map { L($0.localizationKey) } ?? L("common.notSet"),
                     L(chosen.localizationKey)]
                )
            }

            moves.append(Move(
                templateID: session.templateID,
                title: session.title,
                from: session.weekday,
                to: chosen,
                waitsForNextWeek: false,
                explanation: explanation
            ))
        }

        let summaryKey = moves.contains(where: \.changesSchedule)
            ? "workoutHub.reschedule.summary"
            : "workoutHub.reschedule.summaryNoChange"
        return Plan(moves: moves, summary: Explanation(summaryKey))
    }
}

// MARK: - Shared helpers

/// Small resolutions shared by every screen in the hub.
@MainActor
enum HubFormat {
    /// A template's display name: the user's own name if they set one, otherwise the generated one.
    static func title(of template: WorkoutTemplate) -> String {
        if let custom = template.customTitle, !custom.isEmpty { return custom }
        return L(template.titleKey)
    }

    /// The load step the plus/minus buttons should use, in the user's unit.
    static func loadStep(for unit: WeightUnit) -> Double {
        unit == .kilograms ? 2.5 : 5
    }
}

// MARK: - Hub view model

/// Owns the Workout tab's landing state: what is planned for today, what is already running, and
/// the options the quick-start sheet offers.
@MainActor
@Observable
final class WorkoutHubViewModel {

    private(set) var state: HubScreenState = .loading
    private(set) var plan: HubTodayPlan?
    private(set) var hasProgram = false
    /// True when today's slot in the program is a rest day rather than a missing session.
    private(set) var isRestDay = false
    private(set) var inProgressSessionID: UUID?
    private(set) var inProgressTitle: String?
    private(set) var quickStartOptions: [HubTemplateOption] = []
    private(set) var lastSession: HubSessionSummary?
    /// True while a start is in flight, so a double tap cannot create two sessions.
    private(set) var isStarting = false

    var isPresentingQuickStart = false
    var isPresentingExercisePicker = false
    var substitutionTarget: HubSubstitutionTarget?
    var errorMessage: String?

    private var context: ModelContext?
    private var catalogByID: [String: Exercise] = [:]
    private var template: WorkoutTemplate?
    private var program: TrainingProgram?

    // MARK: Loading

    func load(context: ModelContext, catalog: ExerciseCatalog, now: Date = Date()) async {
        self.context = context
        self.catalogByID = Dictionary(catalog.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        do {
            let workouts = WorkoutRepository(context: context)
            let programs = ProgramRepository(context: context)
            let profiles = ProfileRepository(context: context)

            if let running = try workouts.inProgressSession() {
                inProgressSessionID = running.id
                inProgressTitle = running.titleSnapshot
            } else {
                inProgressSessionID = nil
                inProgressTitle = nil
            }

            lastSession = try workouts.recentSessions(limit: 1).first.map(Self.summary(of:))

            guard let active = try programs.activeProgram() else {
                program = nil
                template = nil
                plan = nil
                hasProgram = false
                quickStartOptions = []
                state = .empty
                return
            }

            program = active
            hasProgram = true
            quickStartOptions = active.orderedTemplates
                .filter { !$0.isRestDay }
                .map(Self.option(for:))

            let weekday = Weekday.from(now)
            let todays = active.orderedTemplates.first { $0.weekday == weekday && !$0.isRestDay }
            template = todays

            guard let todays else {
                // A day the program deliberately leaves clear is a rest day, not a hole.
                isRestDay = active.orderedTemplates.contains { $0.weekday == weekday && $0.isRestDay }
                    || !active.orderedTemplates.isEmpty
                plan = nil
                state = .empty
                return
            }

            isRestDay = false
            plan = try buildPlan(
                for: todays,
                program: active,
                workouts: workouts,
                profiles: profiles,
                now: now
            )
            state = .content
        } catch let error as RepositoryError {
            AppLog.training.error("Workout hub load failed: \(error.diagnosticDetail ?? "-", privacy: .public)")
            state = .failed(error.explanation.text)
        } catch {
            AppLog.training.error("Workout hub load failed: \(String(describing: error), privacy: .public)")
            state = .failed(L("workoutHub.error.load"))
        }
    }

    /// Resolves the prescription for every slot in today's template.
    ///
    /// The progression engine is asked once per exercise with the batched history and state it needs,
    /// so a twelve-exercise session costs two fetches rather than twenty-four.
    private func buildPlan(
        for template: WorkoutTemplate,
        program: TrainingProgram,
        workouts: WorkoutRepository,
        profiles: ProfileRepository,
        now: Date
    ) throws -> HubTodayPlan {
        let planned = template.orderedExercises
        let ids = planned.map(\.exerciseID)
        let histories = try workouts.histories(forExerciseIDs: ids)
        let states = try workouts.progressionSnapshots(forExerciseIDs: ids)
        let profile = try profiles.profile()
        let settings = try profiles.settings()
        let increments = try profiles.increments()
        let targetRIR = try profiles.effectiveTargetRIR()

        // The deload falls on the last week of the mesocycle. Derived rather than stored so a user
        // who changes the block length sees the change take effect immediately.
        let isDeloadWeek = program.mesocycleLengthWeeks > 1
            && (program.completedWeeks + 1) % program.mesocycleLengthWeeks == 0

        var items: [HubPlannedItem] = []
        for slot in planned {
            guard let exercise = catalogByID[slot.exerciseID] else {
                // An exercise the catalogue no longer ships still has to be shown, or the user would
                // silently train one movement fewer than the plan says.
                items.append(HubPlannedItem(
                    id: slot.id,
                    exerciseID: slot.exerciseID,
                    name: slot.exerciseID,
                    trackingMode: .weightAndReps,
                    sets: slot.targetSets,
                    repRange: slot.repRange,
                    weightKg: nil,
                    restSeconds: slot.restSeconds,
                    targetRIR: slot.targetRIR,
                    rationale: Explanation("workoutHub.today.exerciseMissing"),
                    requiresCalibration: false,
                    templateSlotID: slot.id,
                    substitutedFrom: slot.substitutedFromExerciseID,
                    substitutionReason: nil
                ))
                continue
            }

            let decision = ProgressionEngine.decide(ProgressionInput(
                exercise: exercise,
                state: states[slot.exerciseID] ?? ProgressionStateSnapshot(
                    exerciseID: slot.exerciseID, repRange: slot.repRange
                ),
                history: histories[slot.exerciseID] ?? ExerciseHistorySnapshot(exerciseID: slot.exerciseID),
                targetRIR: settings.targetRIROverride ?? targetRIR,
                increments: increments,
                strategy: settings.progressionStrategy,
                bodyWeightKg: profile.currentWeightKg,
                isDeloadWeek: isDeloadWeek,
                experience: profile.experience,
                goal: profile.primaryGoal
            ))

            // The user's own plan wins on set count unless the engine deliberately changed it —
            // adding a set is a progression decision, and it carries an explanation when it happens.
            let sets = settings.autoProgressionEnabled
                ? (decision.recommendedSets ?? slot.targetSets)
                : slot.targetSets

            items.append(HubPlannedItem(
                id: slot.id,
                exerciseID: slot.exerciseID,
                name: exercise.name,
                trackingMode: exercise.metadata.trackingMode,
                sets: InputValidation.clampedSets(sets),
                repRange: settings.autoProgressionEnabled ? decision.recommendedRepRange : slot.repRange,
                weightKg: settings.autoProgressionEnabled ? decision.recommendedWeightKg : nil,
                restSeconds: slot.restSeconds,
                targetRIR: decision.targetRIR,
                rationale: settings.autoProgressionEnabled ? decision.explanation : nil,
                requiresCalibration: decision.requiresCalibration,
                templateSlotID: slot.id,
                substitutedFrom: slot.substitutedFromExerciseID,
                substitutionReason: nil
            ))
        }

        var notes: [Explanation] = []
        if isDeloadWeek {
            notes.append(Explanation(
                "workoutHub.today.deloadWeek", [String(program.mesocycleLengthWeeks)]
            ))
        }
        if !settings.autoProgressionEnabled {
            notes.append(Explanation("workoutHub.today.autoProgressionOff"))
        }

        return HubTodayPlan(
            templateID: template.id,
            title: HubFormat.title(of: template),
            focusGroups: template.focusGroups,
            estimatedMinutes: template.estimatedMinutes,
            items: items,
            notes: notes
        )
    }

    // MARK: Editing the draft

    func setSets(_ value: Int, for itemID: UUID) {
        mutate(itemID) { $0.sets = InputValidation.clampedSets(value) }
    }

    func setRepRange(_ range: RepRange, for itemID: UUID) {
        mutate(itemID) { $0.repRange = InputValidation.clampedRepRange(range) }
    }

    func setWeight(_ kilograms: Double?, for itemID: UUID) {
        mutate(itemID) { $0.weightKg = kilograms.map { max(0, $0) } }
    }

    func setTargetRIR(_ value: Int, for itemID: UUID) {
        mutate(itemID) { $0.targetRIR = InputValidation.clampedRIR(value) }
    }

    func remove(itemID: UUID) {
        plan?.items.removeAll { $0.id == itemID }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard var current = plan else { return }
        current.items = RepositoryOrdering.moved(current.items, fromOffsets: source, toOffset: destination)
        plan = current
    }

    /// Appends an exercise the user picked. Its prescription starts from the catalogue's own
    /// recommendation, which is a better guess than three sets of ten for a plank.
    func addExercise(_ exercise: Exercise) {
        guard var current = plan else { return }
        current.items.append(HubPlannedItem(
            id: UUID(),
            exerciseID: exercise.id,
            name: exercise.name,
            trackingMode: exercise.metadata.trackingMode,
            sets: 3,
            repRange: exercise.metadata.recommendedRepRange,
            weightKg: nil,
            restSeconds: exercise.metadata.defaultRestSeconds,
            targetRIR: 2,
            rationale: Explanation("workoutHub.today.addedByYou"),
            requiresCalibration: false,
            templateSlotID: nil,
            substitutedFrom: nil,
            substitutionReason: nil
        ))
        plan = current
    }

    func substitute(itemID: UUID, with exercise: Exercise, reason: SubstitutionReason?) {
        mutate(itemID) { item in
            guard item.exerciseID != exercise.id else { return }
            if item.substitutedFrom == nil {
                item.substitutedFrom = item.exerciseID
            } else if item.substitutedFrom == exercise.id {
                item.substitutedFrom = nil
            }
            item.exerciseID = exercise.id
            item.name = exercise.name
            item.trackingMode = exercise.metadata.trackingMode
            item.restSeconds = exercise.metadata.defaultRestSeconds
            item.repRange = exercise.metadata.recommendedRepRange
            // The outgoing movement's load says nothing about the incoming one's.
            item.weightKg = nil
            item.substitutionReason = reason
            item.rationale = Explanation(
                "workoutHub.today.substituted", [reason.map { L($0.localizationKey) } ?? L("common.none")]
            )
        }
    }

    /// The exercises already in today's plan, so the substitution sheet never offers a duplicate.
    var plannedExerciseIDs: Set<String> {
        Set(plan?.items.map(\.exerciseID) ?? [])
    }

    private func mutate(_ itemID: UUID, _ change: (inout HubPlannedItem) -> Void) {
        guard var current = plan, let index = current.items.firstIndex(where: { $0.id == itemID }) else { return }
        change(&current.items[index])
        plan = current
    }

    // MARK: Starting

    /// Creates today's session and hands its id to the router, which presents the logger over the
    /// whole tab.
    func startPlannedSession(router: AppRouter, now: Date = Date()) {
        guard !isStarting, let context, let plan else { return }
        isStarting = true
        defer { isStarting = false }

        do {
            let workouts = WorkoutRepository(context: context)
            let session: WorkoutSession
            if let template {
                var targets: [String: SessionExerciseTarget] = [:]
                for item in plan.items where item.templateSlotID != nil {
                    // Keyed by what the *template* holds: a row swapped in the draft is still stored
                    // under the original exercise until the session exists and can be substituted.
                    targets[item.substitutedFrom ?? item.exerciseID] = SessionExerciseTarget(
                        weightKg: item.weightKg,
                        repRange: item.repRange,
                        sets: item.sets,
                        targetRIR: item.targetRIR,
                        restSeconds: item.restSeconds
                    )
                }
                session = try workouts.startSession(
                    from: template, catalog: catalogByID, targets: targets, title: plan.title, now: now
                )
                try reconcile(session: session, with: plan, workouts: workouts)
            } else {
                session = try workouts.startEmptySession(title: plan.title, now: now)
                for item in plan.items {
                    guard let exercise = catalogByID[item.exerciseID] else { continue }
                    _ = try workouts.addExercise(
                        exercise, to: session, sets: item.sets, repRange: item.repRange,
                        restSeconds: item.restSeconds, targetRIR: item.targetRIR,
                        targetWeightKg: item.weightKg
                    )
                }
            }
            present(session, router: router)
        } catch {
            report(error)
        }
    }

    /// Brings the session the repository created into line with the draft the user edited.
    ///
    /// `startSession` copies the template verbatim, which is correct — it is the snapshot rule. The
    /// user's additions, removals, swaps and reordering are applied on top afterwards, so the plan
    /// they approved is the plan they get without the template ever being touched.
    private func reconcile(
        session: WorkoutSession,
        with plan: HubTodayPlan,
        workouts: WorkoutRepository
    ) throws {
        var remaining = plan.items.filter { $0.templateSlotID != nil }
        var recordIDByItem: [UUID: UUID] = [:]

        for record in session.orderedExercises {
            let match = remaining.firstIndex { ($0.substitutedFrom ?? $0.exerciseID) == record.exerciseID }
            guard let index = match else {
                try workouts.removeExercise(record, from: session)
                continue
            }
            let item = remaining.remove(at: index)
            if item.exerciseID != record.exerciseID, let exercise = catalogByID[item.exerciseID] {
                try workouts.substitute(
                    record, with: exercise, reason: item.substitutionReason, targetWeightKg: item.weightKg
                )
            }
            recordIDByItem[item.id] = record.id
        }

        for item in plan.items where item.templateSlotID == nil {
            guard let exercise = catalogByID[item.exerciseID] else { continue }
            let record = try workouts.addExercise(
                exercise, to: session, sets: item.sets, repRange: item.repRange,
                restSeconds: item.restSeconds, targetRIR: item.targetRIR, targetWeightKg: item.weightKg
            )
            recordIDByItem[item.id] = record.id
        }

        let ordered = plan.items.compactMap { recordIDByItem[$0.id] }
        if !ordered.isEmpty {
            try workouts.reorderExercises(in: session, orderedIDs: ordered)
        }
    }

    /// Quick start: an empty session with nothing in it but a name.
    func startEmptySession(router: AppRouter, now: Date = Date()) {
        guard !isStarting, let context else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let workouts = WorkoutRepository(context: context)
            let session = try workouts.startEmptySession(title: L("workoutHub.quickStart.emptyTitle"), now: now)
            present(session, router: router)
        } catch {
            report(error)
        }
    }

    /// Quick start: any template from the program, whatever day it normally falls on.
    func startTemplate(id templateID: UUID, router: AppRouter, now: Date = Date()) {
        guard !isStarting, let context, let program else { return }
        guard let template = program.templates.first(where: { $0.id == templateID }) else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            let workouts = WorkoutRepository(context: context)
            let session = try workouts.startSession(
                from: template, catalog: catalogByID, title: HubFormat.title(of: template), now: now
            )
            present(session, router: router)
        } catch {
            report(error)
        }
    }

    /// Quick start: do the last session again. Falls back to an empty session with the same name
    /// when the original was itself ad hoc.
    func repeatLastSession(router: AppRouter, now: Date = Date()) {
        guard !isStarting, let context, let last = lastSession else { return }
        if let templateID = last.templateID, program?.templates.contains(where: { $0.id == templateID }) == true {
            startTemplate(id: templateID, router: router, now: now)
            return
        }
        isStarting = true
        defer { isStarting = false }
        do {
            let workouts = WorkoutRepository(context: context)
            let session = try workouts.startEmptySession(title: last.title, now: now)
            present(session, router: router)
        } catch {
            report(error)
        }
    }

    func resumeInProgressSession(router: AppRouter) {
        guard let id = inProgressSessionID else { return }
        router.presentedWorkoutID = id
    }

    private func present(_ session: WorkoutSession, router: AppRouter) {
        inProgressSessionID = session.id
        inProgressTitle = session.titleSnapshot
        isPresentingQuickStart = false
        router.presentedWorkoutID = session.id
        Haptics.success()
    }

    private func report(_ error: Error) {
        if let repositoryError = error as? RepositoryError {
            AppLog.training.error("Workout start failed: \(repositoryError.diagnosticDetail ?? "-", privacy: .public)")
            errorMessage = repositoryError.explanation.text
        } else {
            AppLog.training.error("Workout start failed: \(String(describing: error), privacy: .public)")
            errorMessage = L("workoutHub.error.start")
        }
        Haptics.error()
    }

    // MARK: Mapping

    static func option(for template: WorkoutTemplate) -> HubTemplateOption {
        HubTemplateOption(
            id: template.id,
            title: HubFormat.title(of: template),
            focusGroups: template.focusGroups,
            exerciseCount: template.plannedExercises.count,
            totalSets: template.totalPlannedSets,
            estimatedMinutes: template.estimatedMinutes,
            weekday: template.weekday
        )
    }

    static func summary(of session: WorkoutSession, hasPersonalRecord: Bool = false) -> HubSessionSummary {
        HubSessionSummary(
            id: session.id,
            title: session.titleSnapshot,
            date: session.startedAt,
            durationSeconds: session.activeSeconds > 0 ? session.activeSeconds : session.durationSeconds,
            volumeKg: session.totalVolumeKg,
            completedSets: session.completedSetCount,
            plannedSets: session.plannedSetCount,
            focusGroups: session.focusGroups,
            status: session.status,
            hasPersonalRecord: hasPersonalRecord,
            templateID: session.templateID,
            exerciseNames: session.orderedExercises.map(\.exerciseNameSnapshot)
        )
    }
}

// MARK: - Calendar view model

/// Owns the month grid, the week strip and every schedule change the user can make from them.
///
/// **Where the schedule lives.** The store has no per-date scheduled-session row: a program assigns
/// each template a weekday, and the calendar projects that weekly assignment forwards. Moving a
/// session therefore changes the template's weekday, which is a permanent change to the routine
/// rather than a one-week exception — and the copy says so, because a user who always misses
/// Wednesday should have their plan move, not fight it every week.
@MainActor
@Observable
final class TrainingCalendarViewModel {

    private(set) var state: HubScreenState = .loading
    private(set) var monthDays: [HubCalendarDay] = []
    private(set) var weekDays: [HubCalendarDay] = []
    private(set) var visibleMonth: Date = Date()
    private(set) var hasProgram = false
    private(set) var monthSessionCount = 0

    var selectedDate: Date?
    var pendingReschedule: SessionRescheduler.Plan?
    var errorMessage: String?
    var statusMessage: String?

    private var context: ModelContext?
    private var catalog: ExerciseCatalog?
    private var program: TrainingProgram?
    private var now: Date = Date()
    private let calendar = ProgressRepository.trainingCalendar()

    var selectedDay: HubCalendarDay? {
        guard let selectedDate else { return nil }
        return (monthDays + weekDays).first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
    }

    /// The weekdays the user said they can train, used by every schedule action.
    private(set) var availableWeekdays: [Weekday] = Weekday.orderedMondayFirst

    /// Sessions the user can drop onto an empty day.
    private(set) var schedulableTemplates: [HubTemplateOption] = []

    // MARK: Loading

    func load(context: ModelContext, catalog: ExerciseCatalog, now: Date = Date()) async {
        self.context = context
        self.catalog = catalog
        self.now = now
        if state == .loading {
            visibleMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        }
        rebuild()
    }

    func showMonth(offsetBy months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: visibleMonth) else { return }
        visibleMonth = calendar.dateInterval(of: .month, for: next)?.start ?? next
        rebuild()
    }

    func showCurrentMonth() {
        visibleMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        rebuild()
    }

    /// Rebuilds both grids from the store. Cheap enough to run on every change: one fetch of the
    /// month's sessions plus the program's templates, which is a few dozen rows.
    private func rebuild() {
        guard let context else { return }
        do {
            let programs = ProgramRepository(context: context)
            let profiles = ProfileRepository(context: context)
            program = try programs.activeProgram()
            hasProgram = program != nil
            schedulableTemplates = (program?.orderedTemplates ?? [])
                .filter { !$0.isRestDay }
                .map(WorkoutHubViewModel.option(for:))
            availableWeekdays = {
                let stored = (try? profiles.profile().availableWeekdays) ?? []
                return stored.isEmpty ? Weekday.orderedMondayFirst : stored.sorted()
            }()

            guard let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth) else {
                state = .failed(L("workoutHub.error.calendar"))
                return
            }

            // The grid shows leading and trailing days from the neighbouring months, so the fetch
            // has to cover them too or those cells would always look empty.
            let gridStart = startOfGrid(for: monthInterval.start)
            let gridEnd = calendar.date(byAdding: .day, value: 42, to: gridStart) ?? monthInterval.end
            let sessions = try sessions(from: gridStart, to: gridEnd, context: context)
            monthSessionCount = sessions.filter {
                $0.status == .completed && monthInterval.contains($0.startedAt)
            }.count

            monthDays = (0..<42).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
                return day(for: date, sessions: sessions, monthStart: monthInterval.start)
            }

            let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            weekDays = (0..<7).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
                return day(for: date, sessions: sessions, monthStart: monthInterval.start, forcesVisible: true)
            }

            state = hasProgram ? .content : .empty
        } catch let error as RepositoryError {
            state = .failed(error.explanation.text)
        } catch {
            state = .failed(L("workoutHub.error.calendar"))
        }
    }

    /// The Monday on or before the first of the month.
    private func startOfGrid(for monthStart: Date) -> Date {
        let weekday = calendar.component(.weekday, from: monthStart)
        // `firstWeekday` is 2 (Monday) for the training calendar, so the offset wraps Sunday to 6.
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: monthStart) ?? monthStart
    }

    /// Every session that touches the grid, whatever its status — the calendar has to show the ones
    /// that were abandoned as well as the ones that were finished.
    private func sessions(from start: Date, to end: Date, context: ModelContext) throws -> [WorkoutSession] {
        let descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw RepositoryError.fetchFailed(underlying: String(describing: error))
        }
    }

    private func day(
        for date: Date,
        sessions: [WorkoutSession],
        monthStart: Date,
        forcesVisible: Bool = false
    ) -> HubCalendarDay {
        let dayNumber = calendar.component(.day, from: date)
        let isToday = calendar.isDate(date, inSameDayAs: now)
        let inMonth = forcesVisible || calendar.isDate(date, equalTo: monthStart, toGranularity: .month)

        if let session = sessions.first(where: { calendar.isDate($0.startedAt, inSameDayAs: date) }) {
            let state: HubDayState = switch session.status {
            case .completed: .completed
            case .inProgress: .inProgress
            default: .missed
            }
            return HubCalendarDay(
                date: date, dayNumber: dayNumber, isToday: isToday, isInVisibleMonth: inMonth,
                state: state, title: session.titleSnapshot, focusGroups: session.focusGroups,
                sessionID: session.id, templateID: session.templateID
            )
        }

        let weekday = Weekday.from(date, calendar: calendar)
        let template = program?.orderedTemplates.first { $0.weekday == weekday && !$0.isRestDay }

        guard let program, let template else {
            // Nothing scheduled. Inside the program's lifetime that is a rest day; outside it there
            // simply was no plan yet, and pretending otherwise would invent a history.
            let started = calendar.startOfDay(for: program?.createdAt ?? date)
            let state: HubDayState = (program != nil && date >= started) ? .rest : .none
            return HubCalendarDay(
                date: date, dayNumber: dayNumber, isToday: isToday, isInVisibleMonth: inMonth,
                state: state, title: nil, focusGroups: [], sessionID: nil, templateID: nil
            )
        }

        let today = calendar.startOfDay(for: now)
        let thisDay = calendar.startOfDay(for: date)
        let programStart = calendar.startOfDay(for: program.createdAt)
        let state: HubDayState
        if thisDay >= today {
            state = .planned
        } else if thisDay >= programStart {
            state = .missed
        } else {
            state = .none
        }

        return HubCalendarDay(
            date: date, dayNumber: dayNumber, isToday: isToday, isInVisibleMonth: inMonth,
            state: state, title: HubFormat.title(of: template), focusGroups: template.focusGroups,
            sessionID: nil, templateID: template.id
        )
    }

    // MARK: Schedule changes

    /// Moves a session to another weekday.
    func move(templateID: UUID, to weekday: Weekday) {
        guard let context, let template = template(id: templateID) else { return }
        do {
            let programs = ProgramRepository(context: context)
            let from = template.weekday
            try programs.setWeekday(weekday, on: template)
            if let program {
                try programs.recordEngineChange(
                    to: program,
                    reason: Explanation(
                        "workoutHub.calendar.movedReason",
                        [HubFormat.title(of: template),
                         from.map { L($0.localizationKey) } ?? L("common.notSet"),
                         L(weekday.localizationKey)]
                    )
                )
            }
            statusMessage = L(
                "workoutHub.calendar.movedConfirmation",
                HubFormat.title(of: template), L(weekday.localizationKey)
            )
            Haptics.success()
            rebuild()
        } catch {
            report(error)
        }
    }

    /// Shifts a session to the previous training day the user has available.
    func bringForward(templateID: UUID) {
        guard let template = template(id: templateID), let current = template.weekday else { return }
        guard let target = neighbourDay(of: current, forward: false) else {
            statusMessage = L("workoutHub.calendar.noEarlierDay")
            return
        }
        move(templateID: templateID, to: target)
    }

    /// Shifts a session to the next training day the user has available.
    func postpone(templateID: UUID) {
        guard let template = template(id: templateID), let current = template.weekday else { return }
        guard let target = neighbourDay(of: current, forward: true) else {
            statusMessage = L("workoutHub.calendar.noLaterDay")
            return
        }
        move(templateID: templateID, to: target)
    }

    /// The next or previous available weekday that is not already taken by another session.
    private func neighbourDay(of weekday: Weekday, forward: Bool) -> Weekday? {
        let taken = Set((program?.orderedTemplates.compactMap(\.weekday) ?? []).filter { $0 != weekday })
        let ordered = Weekday.orderedMondayFirst
        guard let index = ordered.firstIndex(of: weekday) else { return nil }
        let steps = 1..<ordered.count
        for step in steps {
            let offset = forward ? step : -step
            let candidate = ordered[((index + offset) % ordered.count + ordered.count) % ordered.count]
            if availableWeekdays.contains(candidate) && !taken.contains(candidate) { return candidate }
        }
        return nil
    }

    /// Rebuilds one session's exercises from the programming engine, keeping anything the user
    /// pinned. The dose is regenerated with it — a new set of movements needs its own prescription.
    func regenerate(templateID: UUID) {
        guard let context, let catalog, let program, let template = template(id: templateID) else { return }
        do {
            let programs = ProgramRepository(context: context)
            let profiles = ProfileRepository(context: context)
            let workouts = WorkoutRepository(context: context)
            let preferences = ExercisePreferenceRepository(context: context)
            let progress = ProgressRepository(context: context)

            let profile = try profiles.trainingProfileSnapshot(now: now)
            let byID = Dictionary(catalog.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let recentOutcomes = try workouts.recentSessions(limit: 20)
                .map { workouts.sessionOutcome(for: $0, catalog: byID) }
            let recovery = RecoveryEngine.snapshot(
                sessions: recentOutcomes,
                wellbeing: try progress.wellbeingSnapshots(),
                profile: profile,
                now: now
            )
            let lockedIDs = Set(template.orderedExercises.filter(\.isLocked).map(\.exerciseID))

            var request = ProgrammingRequest(profile: profile)
            request.preferences = try preferences.snapshots()
            request.histories = try workouts.histories(
                forExerciseIDs: catalog.exercises.map(\.id), sessionLimit: 6
            )
            request.recovery = recovery
            request.increments = try profiles.increments()
            request.weekIndex = program.completedWeeks
            request.isDeloadWeek = program.mesocycleLengthWeeks > 1
                && (program.completedWeeks + 1) % program.mesocycleLengthWeeks == 0
            request.recentlyUsedExerciseIDs = try preferences.recentlyPerformedIDs(limit: 40)
            request.lockedExerciseIDs = lockedIDs
            // Seeded from the template so regenerating twice in a row does not produce the same
            // session again — the user asked for something different.
            request.randomSeed = UInt64(truncatingIfNeeded: template.id.hashValue) ^ UInt64(Date().timeIntervalSince1970)

            let engine = WorkoutProgrammingEngine(catalog: catalog.exercises)
            let generated = engine.generate(request)
            let replacement = generated.trainingSessions.first { $0.orderIndex == template.orderIndex }
                ?? generated.trainingSessions.first
            guard let replacement, !replacement.exercises.isEmpty else {
                statusMessage = L("workoutHub.calendar.regenerateEmpty")
                return
            }

            for slot in template.orderedExercises where !slot.isLocked {
                try programs.removeExercise(slot)
            }
            for slot in replacement.exercises.sorted(by: { $0.orderIndex < $1.orderIndex })
            where !lockedIDs.contains(slot.exerciseID) {
                _ = try programs.addExercise(
                    exerciseID: slot.exerciseID,
                    to: template,
                    sets: slot.sets,
                    repRange: slot.repRange,
                    restSeconds: slot.restSeconds,
                    targetRIR: slot.targetRIR,
                    targetDurationSeconds: slot.targetDurationSeconds,
                    targetDistanceMeters: slot.targetDistanceMeters
                )
            }
            try programs.recordEngineChange(
                to: program,
                reason: Explanation("workoutHub.calendar.regeneratedReason", [HubFormat.title(of: template)])
            )
            statusMessage = L("workoutHub.calendar.regenerateConfirmation", HubFormat.title(of: template))
            Haptics.success()
            rebuild()
        } catch {
            report(error)
        }
    }

    // MARK: Missed sessions

    /// Builds — but does not apply — a plan for the rest of the week after a missed day.
    func prepareReschedule(for date: Date) {
        guard let program else { return }
        let missedDay = Weekday.from(date, calendar: calendar)
        let today = Weekday.from(now, calendar: calendar)

        guard let missed = program.orderedTemplates.first(where: { $0.weekday == missedDay && !$0.isRestDay }) else {
            statusMessage = L("workoutHub.calendar.nothingToReschedule")
            return
        }

        // What is already in the bank this week, so the rescheduler can protect recovery.
        var trained: [Weekday: Set<MuscleGroup>] = [:]
        for day in weekDays where day.state == .completed {
            trained[Weekday.from(day.date, calendar: calendar), default: []].formUnion(day.focusGroups)
        }

        // The missed session gets first pick, then anything still due later this week.
        var pending: [SessionRescheduler.SessionInput] = [
            SessionRescheduler.SessionInput(
                templateID: missed.id, title: HubFormat.title(of: missed),
                weekday: missed.weekday, focusGroups: missed.focusGroups, orderIndex: missed.orderIndex
            )
        ]
        for template in program.orderedTemplates where !template.isRestDay && template.id != missed.id {
            guard let weekday = template.weekday, weekday.orderIndex >= today.orderIndex else { continue }
            guard trained[weekday] == nil else { continue }
            pending.append(SessionRescheduler.SessionInput(
                templateID: template.id, title: HubFormat.title(of: template),
                weekday: weekday, focusGroups: template.focusGroups, orderIndex: template.orderIndex
            ))
        }

        pendingReschedule = SessionRescheduler.plan(
            pending: pending,
            availableDays: availableWeekdays,
            trainedGroups: trained,
            today: today
        )
    }

    /// Commits a prepared plan. Only the days that actually changed are written.
    func applyReschedule(_ plan: SessionRescheduler.Plan) {
        guard let context, let program else { return }
        do {
            let programs = ProgramRepository(context: context)
            var changed = 0
            for move in plan.moves where move.changesSchedule {
                guard let template = template(id: move.templateID) else { continue }
                try programs.setWeekday(move.to, on: template)
                changed += 1
            }
            if changed > 0 {
                try programs.recordEngineChange(
                    to: program, reason: Explanation("workoutHub.reschedule.versionReason")
                )
                statusMessage = L("workoutHub.reschedule.applied")
                Haptics.success()
            } else {
                statusMessage = L("workoutHub.reschedule.noChangeNeeded")
            }
            pendingReschedule = nil
            rebuild()
        } catch {
            report(error)
        }
    }

    private func template(id: UUID) -> WorkoutTemplate? {
        program?.templates.first { $0.id == id }
    }

    private func report(_ error: Error) {
        if let repositoryError = error as? RepositoryError {
            AppLog.training.error("Calendar change failed: \(repositoryError.diagnosticDetail ?? "-", privacy: .public)")
            errorMessage = repositoryError.explanation.text
        } else {
            AppLog.training.error("Calendar change failed: \(String(describing: error), privacy: .public)")
            errorMessage = L("workoutHub.error.schedule")
        }
        Haptics.error()
    }
}

// MARK: - History view model

/// Reverse-chronological training history, grouped by month, searchable and filterable.
@MainActor
@Observable
final class WorkoutHistoryViewModel {

    /// One month of sessions.
    struct MonthGroup: Identifiable, Hashable {
        var monthStart: Date
        var sessions: [HubSessionSummary]
        var id: Date { monthStart }

        var sessionCount: Int { sessions.count }
        var volumeKg: Double { sessions.reduce(0) { $0 + $1.volumeKg } }
    }

    private(set) var state: HubScreenState = .loading
    private(set) var groups: [MonthGroup] = []
    private(set) var totalSessionCount = 0

    var searchText = "" { didSet { if searchText != oldValue { regroup() } } }
    var range: TimeRange = .all { didSet { if range != oldValue { regroup() } } }

    private var all: [HubSessionSummary] = []
    private let calendar = ProgressRepository.trainingCalendar()
    private var now = Date()

    /// The number of sessions loaded before filtering. Two years of five-a-week training is roughly
    /// 500 rows, which is well inside what a single fetch and an in-memory filter can carry.
    private let fetchLimit = 500

    func load(context: ModelContext, now: Date = Date()) async {
        self.now = now
        do {
            let workouts = WorkoutRepository(context: context)
            let progress = ProgressRepository(context: context)
            // Personal records already carry their session id, so the badge costs one fetch rather
            // than a walk over every set of every session in the list.
            let recordSessions = Set(try progress.personalRecords(limit: fetchLimit).compactMap(\.sessionID))
            let sessions = try workouts.recentSessions(limit: fetchLimit)
            all = sessions.map {
                WorkoutHubViewModel.summary(of: $0, hasPersonalRecord: recordSessions.contains($0.id))
            }
            totalSessionCount = all.count
            regroup()
        } catch let error as RepositoryError {
            state = .failed(error.explanation.text)
        } catch {
            state = .failed(L("workoutHub.error.history"))
        }
    }

    private func regroup() {
        let cutoff = range.days.flatMap { calendar.date(byAdding: .day, value: -$0, to: now) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filtered = all.filter { summary in
            if let cutoff, summary.date < cutoff { return false }
            guard !query.isEmpty else { return true }
            if summary.title.lowercased().contains(query) { return true }
            return summary.exerciseNames.contains { $0.lowercased().contains(query) }
        }

        var buckets: [Date: [HubSessionSummary]] = [:]
        for summary in filtered {
            let month = calendar.dateInterval(of: .month, for: summary.date)?.start ?? summary.date
            buckets[month, default: []].append(summary)
        }
        groups = buckets
            .map { MonthGroup(monthStart: $0.key, sessions: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.monthStart > $1.monthStart }

        if all.isEmpty {
            state = .empty
        } else {
            state = groups.isEmpty ? .empty : .content
        }
    }

    /// True when the list is empty because of the filters rather than because nothing was ever done.
    var isFilteredEmpty: Bool { groups.isEmpty && !all.isEmpty }
}

// MARK: - Session detail view model

/// One performed session, exactly as it happened, plus how it compares with the last time.
@MainActor
@Observable
final class WorkoutSessionDetailViewModel {

    /// One set, frozen for display.
    struct SetLine: Identifiable, Hashable {
        let id: UUID
        var index: Int
        var kind: SetKind
        var isCompleted: Bool
        var weightKg: Double?
        var reps: Int?
        var durationSeconds: Int?
        var distanceMeters: Double?
        var rir: Int?
        var targetWeightKg: Double?
        var targetReps: Int?
        var records: [PersonalRecordKind]
    }

    /// One exercise, exactly as performed.
    struct ExerciseLine: Identifiable, Hashable {
        let id: UUID
        var exerciseID: String
        var name: String
        var trackingMode: TrackingMode
        var wasSkipped: Bool
        var substitutedFromName: String?
        var substitutionReasonKey: String?
        var notes: String?
        var sets: [SetLine]
        var volumeKg: Double
        /// Tonnage on the same exercise in the previous performance of this session, when there was
        /// one. `nil` means "first time", which is not the same as "no improvement".
        var previousVolumeKg: Double?
        var previousTopSet: String?
    }

    private(set) var state: HubScreenState = .loading
    private(set) var title = ""
    private(set) var date = Date()
    private(set) var status: PlannedSessionStatus = .completed
    private(set) var durationSeconds = 0
    private(set) var volumeKg: Double = 0
    private(set) var completedSets = 0
    private(set) var plannedSets = 0
    private(set) var effort: SessionEffortFeedback?
    private(set) var focusGroups: [MuscleGroup] = []
    private(set) var exercises: [ExerciseLine] = []
    private(set) var records: [PersonalRecord] = []

    /// The previous performance of the same planned session, for the comparison block.
    private(set) var previousDate: Date?
    private(set) var previousVolumeKg: Double?
    private(set) var previousDurationSeconds: Int?
    private(set) var previousCompletedSets: Int?

    /// Notes are the one field history allows to change: what happened is a fact, what the user
    /// thought about it is not.
    var notes: String = ""
    var errorMessage: String?
    private(set) var isSavingNotes = false
    /// What is actually in the store, so the save button only offers itself when there is a change.
    private(set) var savedNotes: String = ""

    var hasUnsavedNotes: Bool {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
            != savedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var session: WorkoutSession?
    private var context: ModelContext?

    func load(sessionID: UUID, context: ModelContext, catalog: ExerciseCatalog) async {
        self.context = context
        do {
            // `WorkoutRepository` has no fetch-by-id, and adding one would mean editing a file this
            // feature does not own, so the descriptor lives here — read-only, and nothing else in
            // the screen touches the store directly.
            var descriptor = FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == sessionID })
            descriptor.fetchLimit = 1
            guard let session = try context.fetch(descriptor).first else {
                state = .failed(L("workoutHub.detail.notFound"))
                return
            }
            self.session = session

            title = session.titleSnapshot
            date = session.startedAt
            status = session.status
            durationSeconds = session.activeSeconds > 0 ? session.activeSeconds : session.durationSeconds
            volumeKg = session.totalVolumeKg
            completedSets = session.completedSetCount
            plannedSets = session.plannedSetCount
            effort = session.effortFeedback
            focusGroups = session.focusGroups
            notes = session.notes ?? ""
            savedNotes = notes

            let previous = try previousSession(like: session, context: context)
            previousDate = previous?.startedAt
            previousVolumeKg = previous?.totalVolumeKg
            previousDurationSeconds = previous.map { $0.activeSeconds > 0 ? $0.activeSeconds : $0.durationSeconds }
            previousCompletedSets = previous?.completedSetCount

            let previousByExercise = Dictionary(
                (previous?.orderedExercises ?? []).map { ($0.exerciseID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            exercises = session.orderedExercises.map { record in
                line(for: record, previous: previousByExercise[record.exerciseID], catalog: catalog)
            }

            let progress = ProgressRepository(context: context)
            records = try progress.personalRecords(limit: 200).filter { $0.sessionID == session.id }

            state = .content
        } catch let error as RepositoryError {
            state = .failed(error.explanation.text)
        } catch {
            state = .failed(L("workoutHub.error.detail"))
        }
    }

    /// The last time the user trained this same planned session, before this one.
    private func previousSession(like session: WorkoutSession, context: ModelContext) throws -> WorkoutSession? {
        guard let templateID = session.templateID else { return nil }
        let started = session.startedAt
        let completed = PlannedSessionStatus.completed.rawValue
        var descriptor = FetchDescriptor<WorkoutSession>(
            predicate: #Predicate {
                $0.templateID == templateID && $0.startedAt < started && $0.statusRaw == completed
            },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func line(
        for record: ExerciseSession,
        previous: ExerciseSession?,
        catalog: ExerciseCatalog
    ) -> ExerciseLine {
        let sets = record.orderedSets.map { set in
            SetLine(
                id: set.id,
                index: set.setIndex,
                kind: set.kind,
                isCompleted: set.isCompleted,
                weightKg: set.weightKg,
                reps: set.reps,
                durationSeconds: set.durationSeconds,
                distanceMeters: set.distanceMeters,
                rir: set.rir,
                targetWeightKg: set.targetWeightKg,
                targetReps: set.targetReps,
                records: set.achievedRecordKinds
            )
        }
        let previousTop = previous?.completedWorkingSets
            .max { ($0.weightKg ?? 0) < ($1.weightKg ?? 0) }

        return ExerciseLine(
            id: record.id,
            exerciseID: record.exerciseID,
            name: record.exerciseNameSnapshot,
            trackingMode: record.trackingMode,
            wasSkipped: record.wasSkipped,
            substitutedFromName: record.substitutedFromExerciseID.map {
                catalog.exercise(id: $0)?.name ?? $0
            },
            substitutionReasonKey: record.substitutionReasonKey,
            notes: record.notes,
            sets: sets,
            volumeKg: record.completedWorkingSets.reduce(0) { $0 + $1.volumeKg },
            previousVolumeKg: previous.map { previousRecord in
                previousRecord.completedWorkingSets.reduce(0) { $0 + $1.volumeKg }
            },
            previousTopSet: previousTop.flatMap { set in
                guard let weight = set.weightKg, let reps = set.reps else { return nil }
                return "\(Units.formatDecimal(weight, digits: 1)) × \(reps)"
            }
        )
    }

    /// Saves the user's note. The only write this screen performs.
    func saveNotes() {
        guard let context, let session else { return }
        isSavingNotes = true
        defer { isSavingNotes = false }
        do {
            try WorkoutRepository(context: context).setNotes(notes, on: session)
            savedNotes = session.notes ?? ""
            notes = savedNotes
            Haptics.success()
        } catch let error as RepositoryError {
            errorMessage = error.explanation.text
        } catch {
            errorMessage = L("workoutHub.error.saveNotes")
        }
    }

    var completionRate: Double {
        plannedSets > 0 ? min(1, Double(completedSets) / Double(plannedSets)) : 0
    }

    var hasComparison: Bool { previousDate != nil }
}
