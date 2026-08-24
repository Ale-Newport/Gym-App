import Foundation
import Observation
import SwiftData
import SwiftUI

/// Everything the Home dashboard knows, and every action it can take.
///
/// The dashboard reads from five repositories and three engines. Doing that inside a `View` would
/// mean recomputing a recovery snapshot on every layout pass, so all of it lives here: the view
/// renders value types and calls methods, and never touches the store or an engine itself.
///
/// Two rules shape the loading path. **Cards appear only when they have something to say**, so each
/// section resolves to an optional and a `nil` simply removes the card rather than rendering an
/// empty shell. And **the expensive parts run off the main actor**: the repositories must stay on
/// it (SwiftData), but the recovery and deload engines are pure functions over `Sendable` values,
/// so they are handed to a detached task while the main actor keeps scrolling at 120 Hz.
@MainActor
@Observable
final class HomeViewModel {

    // MARK: - Screen state

    enum Phase: Equatable {
        case loading
        case content
        /// The dashboard could not be built. Always paired with a retry.
        case failed(Explanation)
    }

    /// What the user should do about training, right now. Exactly one of these is true at a time,
    /// which is what keeps the Today card from ever showing two competing calls to action.
    enum TodayState: Equatable {
        case noProgram
        case scheduled(Scheduled)
        case inProgress(InProgress)
        case completed(Completed)
        case rest(Rest)
    }

    struct Scheduled: Equatable {
        var templateID: UUID
        var title: String
        var focusGroups: [MuscleGroup]
        var exerciseCount: Int
        var setCount: Int
        var estimatedMinutes: Int
        /// True when an accepted deload is in force, so the card can say the session starts lighter.
        var isEasyWeek: Bool
    }

    struct InProgress: Equatable {
        var sessionID: UUID
        var title: String
        var completedSets: Int
        var plannedSets: Int
        var startedAt: Date

        var fraction: Double {
            plannedSets > 0 ? min(1, Double(completedSets) / Double(plannedSets)) : 0
        }
    }

    struct Completed: Equatable {
        var sessionID: UUID
        var title: String
        var completedSets: Int
        var durationSeconds: Int
        var volumeKg: Double
    }

    struct Rest: Equatable {
        /// The next training session in the plan, so a rest day still points somewhere.
        var nextTitle: String?
        var nextWeekday: Weekday?
        /// An optional mobility movement to offer instead of a session.
        var stretchExerciseID: String?
        var stretchName: String?
    }

    struct NutritionSummary: Equatable {
        var consumed: MacroNutrients
        /// `nil` until the user has a daily target, which is a genuinely different card.
        var target: MacroNutrients?
        var waterMilliliters: Double
        var waterTargetMilliliters: Double
        var isWaterTracked: Bool

        /// Signed: negative means the user has gone past the target, which is information they want.
        var remainingKilocalories: Double {
            (target?.kilocalories ?? 0) - consumed.kilocalories
        }
    }

    struct ProgressSummary: Equatable {
        var latestWeightKg: Double?
        /// Seven-day moving average — the number to show as "your weight".
        var trendWeightKg: Double?
        /// Signed kg per week from the trailing regression. `nil` when the data cannot support one.
        var weeklyChangeKg: Double?
        var sessionsThisWeek: Int
        /// `0` when there is no program to measure against.
        var plannedSessionsPerWeek: Int
        var weekStreak: Int
        var longestWeekStreak: Int
        /// Start-of-day dates in the last seven days that contain a completed session.
        var trainedDays: Set<Date>
    }

    struct RecoverySummary: Equatable {
        var readiness: Double
        var summary: Explanation
        var readyGroups: [MuscleGroup]
        var recoveringGroups: [MuscleGroup]
        var hasCheckedInToday: Bool
    }

    struct DeloadPrompt: Equatable {
        var recommendationID: UUID
        /// First entry is the engine's summary; the rest are the individual signals that fired.
        var reasons: [Explanation]
    }

    /// An accepted deload, in force for the current week.
    struct ActiveDeload: Equatable {
        var volumeReduction: Double
        var intensityReduction: Double
    }

    enum DeloadResponse {
        case accept
        case postpone
        case decline
    }

    // MARK: - Published state

    private(set) var phase: Phase = .loading
    private(set) var today: TodayState = .noProgram
    private(set) var nutrition: NutritionSummary?
    private(set) var progress: ProgressSummary?
    private(set) var recovery: RecoverySummary?
    private(set) var deload: DeloadPrompt?
    private(set) var activeDeload: ActiveDeload?
    /// True while a mutating action runs, so the primary button can show it is working without the
    /// whole screen collapsing back into its loading state.
    private(set) var isBusy = false
    /// A failure from an action rather than from loading. Shown inline; the screen stays usable.
    private(set) var actionFailure: Explanation?

    /// The greeting needs the name, and only the name.
    private(set) var userName: String?

    /// Quick-add volume for the water button. One glass, which is what people count in.
    static let quickWaterMilliliters: Double = 250

    private var context: ModelContext?
    private var environment: AppEnvironment?
    private var hasLoadedOnce = false

    // MARK: - Wiring

    /// Called once from the view's `task`. Later refreshes reuse the stored collaborators.
    func bootstrap(context: ModelContext, environment: AppEnvironment) async {
        self.context = context
        self.environment = environment
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        await refresh()
    }

    /// Recomputes every card. Safe to call as often as the user pulls to refresh.
    func refresh(now: Date = Date()) async {
        guard let context, let environment else { return }
        do {
            try await rebuild(context: context, environment: environment, now: now)
            phase = .content
        } catch let error as RepositoryError {
            AppLog.app.error("Home refresh failed: \(error.diagnosticDetail ?? "-", privacy: .public)")
            phase = .failed(error.explanation)
        } catch {
            AppLog.app.error("Home refresh failed: \(String(describing: error), privacy: .public)")
            phase = .failed(Explanation("home.error.load"))
        }
    }

    /// True when there is genuinely nothing to show — no program, no history and nutrition off.
    /// This is the only case that earns a full-screen empty state; every other combination has at
    /// least one card worth rendering.
    var isEmpty: Bool {
        today == .noProgram && nutrition == nil && recovery == nil
            && (progress.map { $0.sessionsThisWeek == 0 && $0.latestWeightKg == nil } ?? true)
    }

    func dismissActionFailure() { actionFailure = nil }

    // MARK: - Loading

    private func rebuild(context: ModelContext, environment: AppEnvironment, now: Date) async throws {
        let calendar = ProgressRepository.trainingCalendar()
        let profileRepo = ProfileRepository(context: context)
        let programRepo = ProgramRepository(context: context)
        let workoutRepo = WorkoutRepository(context: context)
        let progressRepo = ProgressRepository(context: context)

        let profile = try profileRepo.profile()
        let settings = try profileRepo.settings()
        userName = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        let catalogByID = Dictionary(
            environment.catalog.exercises.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let program = try programRepo.activeProgram()
        let activeSession = try workoutRepo.inProgressSession()

        // One window covers both the "this week" counters and the seven-day streak dots, so the
        // dashboard never fetches the same sessions twice.
        let weekStart = ProgressRepository.weekStart(of: now, calendar: calendar) ?? calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)
        let windowStart = min(weekStart, sevenDaysAgo)
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let windowSessions = try progressRepo.completedSessions(from: windowStart, to: windowEnd)

        // MARK: Deload state, which the Today card needs before it can describe the session
        let deloadStore = DeloadDecisionStore(context: context)
        let deloadRows = try deloadStore.recent()
        let thisWeekRow = deloadRows.first { row in
            guard let applies = row.appliesToWeekStarting else { return false }
            return calendar.isDate(applies, inSameDayAs: weekStart)
        }
        activeDeload = thisWeekRow.flatMap { row in
            row.acceptedAt == nil ? nil : ActiveDeload(
                volumeReduction: row.volumeReduction,
                intensityReduction: row.intensityReduction
            )
        }

        today = makeTodayState(
            program: program,
            activeSession: activeSession,
            sessionsToday: windowSessions.filter { calendar.isDate($0.startedAt, inSameDayAs: now) },
            catalog: environment.catalog,
            now: now,
            calendar: calendar
        )

        // MARK: Progress
        let trendPoints = try progressRepo.weightTrendPoints()
        let analysis = WeightTrendAnalyzer.analyze(entries: trendPoints, now: now, calendar: calendar)
        let streaks = try progressRepo.streaks(now: now, calendar: calendar)
        progress = ProgressSummary(
            latestWeightKg: try progressRepo.latestBodyWeight()?.weightKg,
            trendWeightKg: analysis.currentTrendKg,
            weeklyChangeKg: analysis.hasEnoughData ? analysis.weeklyChangeKg : nil,
            sessionsThisWeek: windowSessions.filter { $0.startedAt >= weekStart }.count,
            plannedSessionsPerWeek: program?.daysPerWeek ?? 0,
            weekStreak: streaks.currentWeekStreak,
            longestWeekStreak: streaks.longestWeekStreak,
            trainedDays: Set(
                windowSessions
                    .filter { $0.startedAt >= sevenDaysAgo }
                    .map { calendar.startOfDay(for: $0.startedAt) }
            )
        )

        // MARK: Nutrition
        if settings.nutritionEnabled {
            let nutritionRepo = NutritionRepository(context: context)
            let day = try nutritionRepo.progress(for: DayKey.make(from: now, calendar: calendar))
            nutrition = NutritionSummary(
                consumed: day.consumed,
                target: day.target,
                waterMilliliters: day.waterMilliliters,
                waterTargetMilliliters: settings.dailyWaterTargetMl,
                isWaterTracked: settings.waterTrackingEnabled
            )
        } else {
            nutrition = nil
        }

        // MARK: Recovery and deload
        //
        // Both engines want the same recent history, so it is gathered once. Twenty-four sessions
        // is more than the ten-day fatigue look-back and the twenty-eight-day deload window need,
        // and bounds the work on a user with years of training behind them.
        let recentSessions = try workoutRepo.recentSessions(limit: 24)
        let outcomes = recentSessions.map { workoutRepo.sessionOutcome(for: $0, catalog: catalogByID) }
        let wellbeing = try progressRepo.wellbeingSnapshots(limit: 14)
        let profileSnapshot = profileRepo.trainingProfileSnapshot(
            profile: profile,
            equipment: try profileRepo.equipmentProfile(),
            now: now,
            calendar: calendar
        )

        let snapshot = await Task.detached(priority: .userInitiated) {
            RecoveryEngine.snapshot(
                sessions: outcomes, wellbeing: wellbeing, profile: profileSnapshot, now: now
            )
        }.value

        let hasCheckedIn = try progressRepo.checkIn(on: now, calendar: calendar) != nil
        // The recovery card earns its place once there is anything to say: either the app has seen
        // some training, or the check-in has not been offered yet today.
        if snapshot.recentSessionCount > 0 || !outcomes.isEmpty || !hasCheckedIn {
            recovery = RecoverySummary(
                readiness: snapshot.systemicReadiness,
                summary: RecoveryEngine.readinessSummary(snapshot),
                readyGroups: Array(RecoveryEngine.readyGroups(snapshot).prefix(6)),
                recoveringGroups: snapshot.fatigue
                    .filter { $0.value >= 0.5 }
                    .sorted { $0.value > $1.value }
                    .prefix(4)
                    .map(\.key),
                hasCheckedInToday: hasCheckedIn
            )
        } else {
            recovery = nil
        }

        deload = try await makeDeloadPrompt(
            settings: settings,
            outcomes: outcomes,
            wellbeing: wellbeing,
            recovery: snapshot,
            profileSnapshot: profileSnapshot,
            workoutRepo: workoutRepo,
            deloadStore: deloadStore,
            rows: deloadRows,
            existingRow: thisWeekRow,
            weekStart: weekStart,
            now: now,
            calendar: calendar
        )
    }

    // MARK: Today

    private func makeTodayState(
        program: TrainingProgram?,
        activeSession: WorkoutSession?,
        sessionsToday: [WorkoutSession],
        catalog: ExerciseCatalog,
        now: Date,
        calendar: Calendar
    ) -> TodayState {
        if let activeSession {
            return .inProgress(InProgress(
                sessionID: activeSession.id,
                title: activeSession.titleSnapshot,
                completedSets: activeSession.completedSetCount,
                plannedSets: activeSession.plannedSetCount,
                startedAt: activeSession.startedAt
            ))
        }

        // Anything finished today outranks the plan: telling somebody to start a workout they have
        // already done is the fastest way to make a dashboard feel like it is not paying attention.
        if let done = sessionsToday.max(by: { $0.startedAt < $1.startedAt }) {
            return .completed(Completed(
                sessionID: done.id,
                title: done.titleSnapshot,
                completedSets: done.completedSetCount,
                durationSeconds: done.activeSeconds > 0 ? done.activeSeconds : done.durationSeconds,
                volumeKg: done.totalVolumeKg
            ))
        }

        guard let program, !program.orderedTemplates.isEmpty else { return .noProgram }
        let templates = program.orderedTemplates

        guard let template = todaysTemplate(in: templates, now: now, calendar: calendar),
              !template.isRestDay
        else {
            return .rest(makeRestState(templates: templates, catalog: catalog, now: now, calendar: calendar))
        }

        return .scheduled(Scheduled(
            templateID: template.id,
            title: title(of: template),
            focusGroups: template.focusGroups,
            exerciseCount: template.plannedExercises.count,
            setCount: template.totalPlannedSets,
            estimatedMinutes: template.estimatedMinutes,
            isEasyWeek: activeDeload != nil
        ))
    }

    /// Which template belongs to today.
    ///
    /// A program that pins templates to weekdays is authoritative — if nothing is pinned to today,
    /// today is a rest day. A program with no weekdays at all is a rotation, so the next template
    /// after the one most recently trained is due.
    private func todaysTemplate(
        in templates: [WorkoutTemplate],
        now: Date,
        calendar: Calendar
    ) -> WorkoutTemplate? {
        let hasSchedule = templates.contains { $0.weekday != nil }
        if hasSchedule {
            let weekday = Weekday.from(now, calendar: calendar)
            return templates.first { $0.weekday == weekday }
        }
        return nextInRotation(templates)
    }

    /// The next template in an unscheduled rotation, skipping rest days.
    private func nextInRotation(_ templates: [WorkoutTemplate]) -> WorkoutTemplate? {
        guard let context else { return templates.first { !$0.isRestDay } }
        let repo = WorkoutRepository(context: context)
        let lastTemplateID = (try? repo.recentSessions(limit: 8))?
            .first(where: { session in templates.contains { $0.id == session.templateID } })?
            .templateID
        guard let lastTemplateID,
              let lastIndex = templates.firstIndex(where: { $0.id == lastTemplateID })
        else {
            return templates.first { !$0.isRestDay }
        }
        for offset in 1...templates.count {
            let candidate = templates[(lastIndex + offset) % templates.count]
            if !candidate.isRestDay { return candidate }
        }
        return nil
    }

    private func makeRestState(
        templates: [WorkoutTemplate],
        catalog: ExerciseCatalog,
        now: Date,
        calendar: Calendar
    ) -> Rest {
        let todayWeekday = Weekday.from(now, calendar: calendar)
        let training = templates.filter { !$0.isRestDay }
        // The next pinned session after today, wrapping into next week if today is the last one.
        let upcoming = training
            .filter { $0.weekday != nil }
            .min { lhs, rhs in
                distance(from: todayWeekday, to: lhs.weekday!) < distance(from: todayWeekday, to: rhs.weekday!)
            } ?? training.first

        let stretch = suggestedStretch(from: catalog, now: now, calendar: calendar)
        return Rest(
            nextTitle: upcoming.map(title(of:)),
            nextWeekday: upcoming?.weekday,
            stretchExerciseID: stretch?.id,
            stretchName: stretch?.name.localizedCapitalized
        )
    }

    /// Days from `from` to `to` going forwards through the week, 1…7. Today itself counts as seven
    /// so "next up" never points at a session that has already been and gone.
    private func distance(from: Weekday, to: Weekday) -> Int {
        let delta = to.orderIndex - from.orderIndex
        return delta > 0 ? delta : delta + 7
    }

    /// A mobility movement to offer on a rest day.
    ///
    /// Chosen by day of year rather than at random so the suggestion is stable for the whole day —
    /// a card that swaps its advice every time the screen refreshes reads as broken.
    private func suggestedStretch(from catalog: ExerciseCatalog, now: Date, calendar: Calendar) -> Exercise? {
        let candidates = catalog.exercises(pattern: .mobility)
            .filter { $0.equipment == .bodyWeight }
            .sorted { $0.id < $1.id }
        guard !candidates.isEmpty else { return nil }
        let day = calendar.ordinality(of: .day, in: .year, for: now) ?? 1
        return candidates[day % candidates.count]
    }

    private func title(of template: WorkoutTemplate) -> String {
        if let custom = template.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return custom
        }
        return L(template.titleKey)
    }

    // MARK: Deload

    private func makeDeloadPrompt(
        settings: UserSettings,
        outcomes: [SessionOutcome],
        wellbeing: [WellbeingSnapshot],
        recovery: RecoverySnapshot,
        profileSnapshot: TrainingProfileSnapshot,
        workoutRepo: WorkoutRepository,
        deloadStore: DeloadDecisionStore,
        rows: [DeloadRecommendation],
        existingRow: DeloadRecommendation?,
        weekStart: Date,
        now: Date,
        calendar: Calendar
    ) async throws -> DeloadPrompt? {
        guard settings.deloadSuggestionsEnabled else { return nil }

        // A decision already exists for this week. Honour it rather than asking again — and note
        // that a postponed row becomes pending again once its date passes, which is the point.
        if let existingRow {
            guard existingRow.isPending else { return nil }
            return DeloadPrompt(
                recommendationID: existingRow.id,
                reasons: existingRow.reasonKeys.map { Explanation($0) }
            )
        }

        // `DeloadEngine` refuses to have an opinion below six sessions in twenty-eight days. Check
        // that here too, because clearing the gate is what makes the per-exercise history fetch —
        // the most expensive query on this screen — worth running at all.
        let recentCount = outcomes.filter {
            now.timeIntervalSince($0.date) / 86400 <= DeloadTuning.historyWindowDays
        }.count
        guard recentCount >= DeloadTuning.minimumSessionsForOpinion else { return nil }

        let exerciseIDs = Array(Set(outcomes.flatMap { $0.performances.map(\.exerciseID) }))
        let histories = try workoutRepo.histories(forExerciseIDs: exerciseIDs, sessionLimit: 6)
        let weeksSinceDeload = weeksSinceLastDeload(rows: rows, outcomes: outcomes, now: now, calendar: calendar)

        let assessment = await Task.detached(priority: .utility) {
            DeloadEngine.assess(
                sessions: outcomes,
                histories: histories,
                recovery: recovery,
                wellbeing: wellbeing,
                weeksSinceLastDeload: weeksSinceDeload,
                profile: profileSnapshot,
                now: now
            )
        }.value

        guard assessment.shouldDeload else { return nil }

        // The recommendation is recorded the moment it is made, not when it is answered: a
        // suggestion the user never sees again because they closed the app is a suggestion the app
        // has no record of having made.
        let row = try deloadStore.create(assessment: assessment, weekStart: weekStart, now: now)
        return DeloadPrompt(recommendationID: row.id, reasons: assessment.reasons)
    }

    /// Hard weeks since the last accepted deload, or since training began if there has never been
    /// one. Capped at a year so a returning user's first week does not read as a fifty-week block.
    private func weeksSinceLastDeload(
        rows: [DeloadRecommendation],
        outcomes: [SessionOutcome],
        now: Date,
        calendar: Calendar
    ) -> Int {
        let reference = rows.compactMap(\.acceptedAt).max() ?? outcomes.map(\.date).min()
        guard let reference else { return 0 }
        let weeks = calendar.dateComponents([.weekOfYear], from: reference, to: now).weekOfYear ?? 0
        return min(52, max(0, weeks))
    }

    // MARK: - Actions

    /// Starts today's scheduled session and returns its id so the caller can present it.
    ///
    /// The prescription is computed here rather than left to the template: the progression engine
    /// is the only thing that knows what load the user earned last time, and a session that opens
    /// on last month's numbers is a session the user has to correct by hand.
    func startScheduledSession() async -> UUID? {
        guard case .scheduled(let plan) = today, let context, let environment else { return nil }
        isBusy = true
        actionFailure = nil
        defer { isBusy = false }

        do {
            let programRepo = ProgramRepository(context: context)
            let workoutRepo = WorkoutRepository(context: context)
            let profileRepo = ProfileRepository(context: context)

            guard let template = try programRepo.activeProgram()?
                .orderedTemplates.first(where: { $0.id == plan.templateID })
            else {
                await refresh()
                return nil
            }

            let catalogByID = Dictionary(
                environment.catalog.exercises.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let targets = try sessionTargets(
                for: template,
                catalog: catalogByID,
                workoutRepo: workoutRepo,
                profileRepo: profileRepo
            )

            let session = try workoutRepo.startSession(from: template, catalog: catalogByID, targets: targets)
            environment.activeWorkoutID = session.id
            environment.snapshotWriter.refresh(context: context, catalog: environment.catalog)
            await refresh()
            return session.id
        } catch {
            report(error)
            return nil
        }
    }

    /// A session with nothing programmed in it — the rest-day "I still fancy moving" path.
    func startLightSession() async -> UUID? {
        guard let context, let environment else { return nil }
        isBusy = true
        actionFailure = nil
        defer { isBusy = false }

        do {
            let session = try WorkoutRepository(context: context)
                .startEmptySession(title: L("home.today.lightSession"))
            environment.activeWorkoutID = session.id
            environment.snapshotWriter.refresh(context: context, catalog: environment.catalog)
            await refresh()
            return session.id
        } catch {
            report(error)
            return nil
        }
    }

    /// Builds the per-exercise prescription for a session about to start.
    private func sessionTargets(
        for template: WorkoutTemplate,
        catalog: [String: Exercise],
        workoutRepo: WorkoutRepository,
        profileRepo: ProfileRepository
    ) throws -> [String: SessionExerciseTarget] {
        let planned = template.orderedExercises
        let ids = planned.map(\.exerciseID)
        guard !ids.isEmpty else { return [:] }

        let states = try workoutRepo.progressionSnapshots(forExerciseIDs: ids)
        let histories = try workoutRepo.histories(forExerciseIDs: ids, sessionLimit: 6)
        let increments = try profileRepo.increments()
        let profile = try profileRepo.profile()
        let settings = try profileRepo.settings()
        let targetRIR = try profileRepo.effectiveTargetRIR()
        let easyWeek = activeDeload

        var targets: [String: SessionExerciseTarget] = [:]
        for slot in planned {
            guard let exercise = catalog[slot.exerciseID] else { continue }
            let decision = ProgressionEngine.decide(ProgressionInput(
                exercise: exercise,
                state: states[slot.exerciseID] ?? ProgressionStateSnapshot(exerciseID: slot.exerciseID),
                history: histories[slot.exerciseID] ?? ExerciseHistorySnapshot(exerciseID: slot.exerciseID),
                targetRIR: targetRIR,
                increments: increments,
                strategy: settings.progressionStrategy,
                bodyWeightKg: profile.currentWeightKg,
                isDeloadWeek: easyWeek != nil,
                experience: profile.experience,
                goal: profile.primaryGoal
            ))

            // The engine prescribes the load; the accepted deload prescribes the volume. Applying
            // the cut here rather than inside the engine keeps "how much lighter" in one place —
            // the recommendation the user actually agreed to.
            var sets = decision.recommendedSets ?? slot.targetSets
            if let easyWeek {
                sets = max(1, Int((Double(sets) * (1 - easyWeek.volumeReduction)).rounded()))
            }

            targets[slot.exerciseID] = SessionExerciseTarget(
                weightKg: decision.recommendedWeightKg,
                repRange: decision.recommendedRepRange,
                sets: sets,
                targetRIR: decision.targetRIR,
                restSeconds: slot.restSeconds
            )
        }
        return targets
    }

    /// Generates and installs a program from what the app already knows about the user.
    func generateProgram() async {
        guard let context, let environment else { return }
        isBusy = true
        actionFailure = nil
        defer { isBusy = false }

        do {
            let profileRepo = ProfileRepository(context: context)
            let programRepo = ProgramRepository(context: context)
            let workoutRepo = WorkoutRepository(context: context)

            let snapshot = try profileRepo.trainingProfileSnapshot()
            let recent = try workoutRepo.recentSessions(limit: 8)
            let recentIDs = recent.flatMap { $0.orderedExercises.map(\.exerciseID) }
            var request = ProgrammingRequest(profile: snapshot)
            request.increments = try profileRepo.increments()
            request.recentlyUsedExerciseIDs = Array(Set(recentIDs))
            // Standing opinions matter even on a first program: an exercise the user has already
            // excluded must not appear in the week they are about to be handed.
            request.preferences = try ExercisePreferenceRepository(context: context).snapshots()

            let exercises = environment.catalog.exercises
            let generated = await Task.detached(priority: .userInitiated) {
                WorkoutProgrammingEngine(catalog: exercises).generate(request)
            }.value

            try programRepo.install(
                generated,
                profile: snapshot,
                title: L(generated.splitKey),
                reason: Explanation("explain.programCreated")
            )
            environment.snapshotWriter.refresh(context: context, catalog: environment.catalog)
            Haptics.success()
            await refresh()
        } catch {
            report(error)
        }
    }

    /// Logs one glass of water. Only the nutrition card changes, so only it is recomputed.
    func logWater() async {
        guard let context, nutrition?.isWaterTracked == true else { return }
        do {
            let repo = NutritionRepository(context: context)
            try repo.addWater(milliliters: Self.quickWaterMilliliters)
            let day = try repo.progress(for: DayKey.today)
            nutrition?.waterMilliliters = day.waterMilliliters
            Haptics.tap()
        } catch {
            report(error)
        }
    }

    /// Writes the daily check-in. Every field is optional: a user who only wants to answer one
    /// question has still told the recovery engine something true.
    func saveCheckIn(energy: Int?, sleepQuality: Int?, soreness: Int?, motivation: Int?) async {
        guard let context else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try ProgressRepository(context: context).upsertCheckIn(
                energy: energy,
                sleepQuality: sleepQuality,
                soreness: soreness,
                motivation: motivation
            )
            Haptics.success()
            await refresh()
        } catch {
            report(error)
        }
    }

    /// Records the user's answer to a deload recommendation.
    func respondToDeload(_ response: DeloadResponse) async {
        guard let context, let prompt = deload else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let store = DeloadDecisionStore(context: context)
            try store.record(response, forRecommendation: prompt.recommendationID)
            Haptics.selectionChanged()
            await refresh()
        } catch {
            report(error)
        }
    }

    /// Called when the active-workout screen closes, so the dashboard reflects what just happened
    /// and the widget stops advertising a session that has finished.
    func handleWorkoutDismissed() async {
        if let context, let environment {
            environment.activeWorkoutID = nil
            environment.snapshotWriter.refresh(context: context, catalog: environment.catalog)
        }
        await refresh()
    }

    // MARK: - Private

    private func report(_ error: Error) {
        if let repositoryError = error as? RepositoryError {
            AppLog.app.error("Home action failed: \(repositoryError.diagnosticDetail ?? "-", privacy: .public)")
            actionFailure = repositoryError.explanation
        } else {
            AppLog.app.error("Home action failed: \(String(describing: error), privacy: .public)")
            actionFailure = Explanation("home.error.action")
        }
        Haptics.error()
    }
}

// MARK: - Deload persistence

/// The one store this screen writes that no repository owns yet.
///
/// Kept as a `Repository` rather than as loose `FetchDescriptor`s in the view model so it inherits
/// the same save-or-throw behaviour as every other write in the app: a deload the user accepted and
/// the app failed to record is a deload that silently never happens.
private struct DeloadDecisionStore: Repository {
    let context: ModelContext

    /// Recent recommendations, newest first. The table holds one row per proposal, so a small
    /// window covers everything the dashboard needs to reason about.
    func recent(limit: Int = 12) throws -> [DeloadRecommendation] {
        var descriptor = FetchDescriptor<DeloadRecommendation>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(1, limit)
        return try fetch(descriptor)
    }

    @discardableResult
    func create(
        assessment: DeloadAssessment,
        weekStart: Date,
        now: Date = Date()
    ) throws -> DeloadRecommendation {
        let row = DeloadRecommendation()
        row.createdAt = now
        row.severity = assessment.severity
        // Keys only: `DeloadRecommendation.reasonKeys` is `[String]`, so a stored reason that took
        // arguments reads as its unformatted sentence later. The prompt shown now uses the live
        // assessment, which still carries them.
        row.reasonKeys = assessment.reasons.map(\.key)
        row.volumeReduction = assessment.volumeReduction
        row.intensityReduction = assessment.intensityReduction
        row.appliesToWeekStarting = weekStart
        context.insert(row)
        try persist()
        return row
    }

    func record(
        _ response: HomeViewModel.DeloadResponse,
        forRecommendation id: UUID,
        now: Date = Date()
    ) throws {
        guard let row = try recent().first(where: { $0.id == id }) else {
            throw RepositoryError.notFound(entity: "deloadRecommendation")
        }
        switch response {
        case .accept:
            row.acceptedAt = now
            row.declinedAt = nil
            row.postponedUntil = nil
        case .postpone:
            // A week is the natural unit: the recommendation is about a training week, so "not now"
            // means "ask me when the next one starts".
            row.postponedUntil = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        case .decline:
            row.declinedAt = now
        }
        try persist()
    }
}

// MARK: - Small helpers

private extension String {
    /// `nil` for a string that is empty, so optional-chaining reads naturally.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
