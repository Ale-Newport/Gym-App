import Foundation
import Observation
import SwiftData

// MARK: - Supporting value types

/// What the generation step produced, kept as plain values so the result screen can render the
/// program without touching SwiftData a second time.
struct OnboardingProgramResult: Hashable, Sendable {
    var programTitle: String
    var splitKey: String
    var daysPerWeek: Int
    var sessions: [GeneratedSession]
    var weeklyVolume: [MuscleGroup: Double]
    var explanations: [Explanation]
    var energyTargets: EnergyTargets?
    /// True when the engine failed and the user chose to build the program by hand instead.
    var isManual: Bool = false

    var trainingSessions: [GeneratedSession] { sessions.filter { !$0.isRestDay } }
    var totalWeeklySets: Int { trainingSessions.reduce(0) { $0 + $1.totalSets } }
}

enum OnboardingGenerationState: Hashable, Sendable {
    case idle
    case running
    case ready(OnboardingProgramResult)
    case failed(String)

    var result: OnboardingProgramResult? {
        if case .ready(let result) = self { return result }
        return nil
    }

    var isRunning: Bool { self == .running }
}

/// What the user decided about notifications, which is a different thing from what iOS allows.
///
/// Reminders are only ever switched on after the user said yes on our own screen *and* iOS said
/// yes to the system prompt. The two answers are kept apart so a refusal at either gate is
/// recorded as exactly that, and so the interface never shows a reminder as enabled while the
/// system is dropping it.
enum OnboardingNotificationOutcome: Hashable, Sendable {
    /// The reminders step has not been answered yet.
    case notAsked
    /// The user chose not to receive reminders. iOS was not asked.
    case declined
    /// The user said yes and iOS refused (now or earlier).
    case deniedBySystem
    /// The user said yes and iOS agreed.
    case granted
}

// MARK: - View model

/// Owns every answer the onboarding flow collects, the rules that decide when an answer is usable,
/// and the writes that turn the finished draft into a working app.
///
/// The draft is held here rather than in the step views for one reason: the answers are
/// interdependent. Training days change the split, equipment changes which exercises exist, the
/// goal changes the calorie direction. A step view that owned its own slice of state could not see
/// those relationships.
///
/// Answers are written to the store as each step is left, not batched at the end. Onboarding is the
/// longest uninterrupted stretch of typing the app will ever ask for, and losing it to a phone call
/// is not a failure mode worth designing in.
///
/// Fields the flow does not ask about — plate sizes, diet, exclusions, strength seeds — are never
/// touched: they keep whatever the profile already holds, so re-running the flow from Settings
/// cannot overwrite a refinement made there.
@MainActor
@Observable
final class OnboardingViewModel {

    // MARK: Navigation

    private(set) var plan: OnboardingStepPlan = .firstRun
    private(set) var step: OnboardingStep = .welcome
    private(set) var isReturningUser = false
    private var didLoad = false

    /// Set when the user walks back into a question after a program has already been built, so the
    /// result step knows the plan on file no longer matches the answers on screen.
    private(set) var needsRegeneration = false

    /// A persistence failure, shown inline with a retry rather than as an alert.
    var errorMessage: String?

    // MARK: Draft — about you

    var name: String = ""
    var birthDate: Date = OnboardingViewModel.defaultBirthDate
    var biologicalSex: BiologicalSex = .unspecified

    var weightUnit: WeightUnit = .kilograms {
        didSet { if weightUnit != oldValue { applyWeightUnitDefaults(previous: oldValue) } }
    }
    var heightUnit: HeightUnit = .centimeters

    var heightCm: Double? = 175
    var currentWeightKg: Double? = 75

    // MARK: Draft — goal and level

    /// Ordered: the first goal is the primary one and drives the rep ranges and the energy balance.
    /// The flow offers one choice; a profile that already holds more keeps them until a different
    /// goal is picked.
    var goals: [TrainingGoal] = []
    var priorityGroups: [MuscleGroup] = []
    var priorityRegions: [TrainingFocusRegion] = []
    var nutritionEnabled = true

    var experience: ExperienceLevel = .beginner {
        didSet { if experience != oldValue { alignTrainingMonths(to: experience, from: oldValue) } }
    }
    var trainingMonths: Int? = 6
    var techniqueConfidence: TechniqueConfidence = .learning

    // MARK: Draft — week

    var availableWeekdays: Set<Weekday> = Set(OnboardingSchedule.suggestedWeekdays(count: 3))
    var sessionMinutes: Int = 60
    var preferredTrainingTime: PreferredTrainingTime = .evening
    var cardioPreference: CardioPreference = .either
    var activityLevel: ActivityLevel = .moderate

    // MARK: Draft — gear

    var equipmentPreset: GymSetupPreset = .fullGym
    var selectedEquipment: Set<Equipment> = Equipment.fullGym
    var barbellBarWeightKg: Double? = 20
    var ezBarWeightKg: Double? = 10
    var selectedPlatesKg: Set<Double> = Set(EquipmentIncrements.default.availablePlatesKg)
    var dumbbellStepKg: Double = 2.5
    var kettlebellsKg: Set<Double> = Set(EquipmentIncrements.default.kettlebellsKg)
    var machineIncrementKg: Double? = 5
    var cableIncrementKg: Double? = 2.5

    var mobilityLimitations: Set<MobilityLimitation> = []
    var avoidedPatterns: Set<MovementPattern> = []

    // MARK: Draft — reminders

    var wantsTrainingReminder = true
    var reminderTime: Date = OnboardingViewModel.time(hour: OnboardingSchedule.defaultReminderHour, minute: 0)
    var wantsRestAlert = true
    private(set) var notificationOutcome: OnboardingNotificationOutcome = .notAsked

    // MARK: Generation

    private(set) var generation: OnboardingGenerationState = .idle

    private static var defaultBirthDate: Date {
        Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    }

    private static func time(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    // MARK: - Loading

    /// Hydrates the draft from whatever is already on file.
    ///
    /// This matters twice: `AppBootstrap` creates the singleton rows before onboarding is ever
    /// shown, and Settings can send an existing user back through the flow. In both cases the flow
    /// must open on the user's real answers, not on the defaults.
    func load(context: ModelContext) {
        guard !didLoad else { return }
        didLoad = true
        do {
            let repository = ProfileRepository(context: context)
            let profile = try repository.profile()
            let settings = try repository.settings()
            let equipment = try repository.equipmentProfile()

            weightUnit = settings.weightUnit
            heightUnit = settings.heightUnit
            nutritionEnabled = settings.nutritionEnabled

            // A profile that already carries answers belongs to somebody re-running the flow. The
            // goal list is the tell: nothing else in `UserProfile` starts out empty *and* is
            // impossible to leave the flow without.
            isReturningUser = !profile.goals.isEmpty
            plan = .plan(isReturningUser: isReturningUser)
            step = plan.first

            name = profile.name ?? ""
            birthDate = profile.birthDate ?? Self.defaultBirthDate
            biologicalSex = profile.biologicalSex
            heightCm = profile.heightCm
            currentWeightKg = profile.currentWeightKg

            goals = profile.goals
            priorityGroups = profile.priorityGroups
            priorityRegions = profile.priorityRegions

            experience = profile.experience
            trainingMonths = profile.trainingExperienceMonths
            techniqueConfidence = profile.techniqueConfidence

            if !profile.availableWeekdays.isEmpty { availableWeekdays = Set(profile.availableWeekdays) }
            sessionMinutes = profile.sessionMinutesCap
            preferredTrainingTime = profile.preferredTrainingTime
            cardioPreference = profile.cardioPreference
            activityLevel = profile.activityLevel

            equipmentPreset = equipment.preset
            selectedEquipment = Set(equipment.availableEquipment)
            if selectedEquipment.isEmpty { selectedEquipment = equipment.preset.equipment }
            barbellBarWeightKg = equipment.barbellBarWeightKg
            ezBarWeightKg = equipment.ezBarWeightKg
            selectedPlatesKg = Set(equipment.availablePlatesKg)
            kettlebellsKg = Set(equipment.kettlebellsKg)
            machineIncrementKg = equipment.machineIncrementKg
            cableIncrementKg = equipment.cableIncrementKg
            dumbbellStepKg = Self.inferredDumbbellStep(from: equipment.availableDumbbellsKg)

            mobilityLimitations = Set(profile.mobilityLimitations)
            avoidedPatterns = Set(profile.avoidedMovementPatterns)

            if isReturningUser {
                wantsTrainingReminder = settings.trainingReminderEnabled
                reminderTime = Self.time(hour: settings.trainingReminderHour, minute: settings.trainingReminderMinute)
                wantsRestAlert = settings.restTimerNotificationEnabled
                notificationOutcome = settings.notificationsEnabled ? .granted : .notAsked
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    // MARK: - Navigation

    var canGoBack: Bool { plan.previous(before: step) != nil }

    var progress: Double { plan.progress(at: step) }

    /// "Step 3 of 5", or `nil` on the screens that ask nothing.
    var stepCounter: String? {
        guard let number = plan.questionNumber(of: step) else { return nil }
        return L("onboarding.progress.counter", number, plan.questionCount)
    }

    /// The reason the primary button is disabled, or `nil` when it is not. Shown next to the button:
    /// a control that refuses to work without saying why is a bug, not a validation strategy.
    var blockingHint: String? {
        let issues = issues(for: step)
        guard !issues.isEmpty else { return nil }
        // Fields are checked in a fixed order so the hint does not flicker between two problems.
        for field in Self.fieldOrder where issues[field] != nil { return issues[field] }
        return issues.values.sorted().first
    }

    var canAdvance: Bool { blockingHint == nil }

    func advance(context: ModelContext) {
        guard canAdvance else { return }
        guard persist(step, context: context) else { return }
        guard let next = plan.next(after: step) else { return }
        move(to: next)
    }

    func goBack() {
        guard let previous = plan.previous(before: step) else { return }
        move(to: previous)
    }

    private func move(to destination: OnboardingStep) {
        // Editing an answer after the program exists invalidates it. The flag is what makes the
        // result step re-run instead of showing a plan built from superseded answers.
        if destination.collectsInput, generation.result != nil {
            needsRegeneration = true
        }
        errorMessage = nil
        step = destination
    }

    // MARK: - Validation

    /// Field order used to pick which of several problems to name first.
    private static let fieldOrder = [
        "heightCm", "currentWeightKg", "birthDate", "goals", "priorityGroups",
        "availableWeekdays", "sessionMinutes", "selectedEquipment",
    ]

    /// Every problem on `step`, keyed by the field it belongs to, so a control can show its own hint
    /// underneath itself as well as next to the button.
    func issues(for step: OnboardingStep) -> [String: String] {
        var issues: [String: String] = [:]
        switch step {
        case .about:
            if let message = rangeIssue(heightCm, range: InputValidation.heightCm, unitKey: "onboarding.unit.cm") {
                issues["heightCm"] = message
            }
            if let message = rangeIssue(
                currentWeightKg, range: InputValidation.bodyMassKg, unitKey: "onboarding.unit.kg")
            {
                issues["currentWeightKg"] = message
            }
            let years = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? -1
            if !InputValidation.ageYears.contains(years) {
                issues["birthDate"] = L(
                    "start.hint.age",
                    InputValidation.ageYears.lowerBound, InputValidation.ageYears.upperBound
                )
            }
        case .goal:
            if goals.isEmpty { issues["goals"] = L("start.hint.goalEmpty") }
            if goals.contains(.targetMuscleGroup), priorityGroups.isEmpty, priorityRegions.isEmpty {
                issues["priorityGroups"] = L("onboarding.hint.priorityRequired")
            }
        case .week:
            if availableWeekdays.isEmpty { issues["availableWeekdays"] = L("onboarding.hint.daysEmpty") }
            if !InputValidation.sessionMinutes.contains(sessionMinutes) {
                issues["sessionMinutes"] = L(
                    "onboarding.hint.sessionMinutes",
                    InputValidation.sessionMinutes.lowerBound, InputValidation.sessionMinutes.upperBound
                )
            }
        case .gear:
            if selectedEquipment.isEmpty { issues["selectedEquipment"] = L("onboarding.hint.equipmentEmpty") }
        case .welcome, .reminders, .ready:
            break
        }
        return issues
    }

    func hint(for field: String) -> String? { issues(for: step)[field] }

    /// A missing or out-of-range number, phrased in the user's own unit.
    private func rangeIssue(_ value: Double?, range: ClosedRange<Double>, unitKey: String) -> String? {
        guard let value, value.isFinite else { return L("onboarding.hint.missingNumber") }
        guard !range.contains(value) else { return nil }
        let lower: String
        let upper: String
        if unitKey == "onboarding.unit.kg" {
            lower = Units.formatWeight(
                kilograms: range.lowerBound, unit: weightUnit, includeUnit: false, fractionDigits: 0)
            upper = Units.formatWeight(
                kilograms: range.upperBound, unit: weightUnit, includeUnit: false, fractionDigits: 0)
            return L("onboarding.hint.range", lower, upper, weightUnit.rawValue)
        }
        lower = Units.formatDecimal(range.lowerBound, digits: 0)
        upper = Units.formatDecimal(range.upperBound, digits: 0)
        return L("onboarding.hint.range", lower, upper, L(unitKey))
    }

    // MARK: - Derived answers

    var daysPerWeek: Int { max(1, availableWeekdays.count) }

    /// How many exercises the current equipment selection makes available. Every exercise in the
    /// dataset carries exactly one piece of equipment, so summing the per-equipment counts is exact
    /// rather than an approximation.
    func exerciseCount(for equipment: Set<Equipment>, catalog: ExerciseCatalog) -> Int {
        equipment.reduce(0) { $0 + catalog.count(forEquipment: $1) }
    }

    /// True when the user has said yes to at least one reminder on our own screen.
    var wantsAnyReminder: Bool { wantsTrainingReminder || wantsRestAlert }

    // MARK: - Draft mutation

    /// Makes `goal` the one goal. A different choice replaces the whole list, because the flow
    /// shows a single selection and a hidden second goal would shape a program the user never saw
    /// themselves ask for.
    func selectGoal(_ goal: TrainingGoal) {
        guard goals.first != goal || goals.count > 1 else { return }
        goals = [goal]
        if goal != .targetMuscleGroup {
            priorityGroups = []
            priorityRegions = []
        }
    }

    func togglePriorityGroup(_ group: MuscleGroup) {
        if let index = priorityGroups.firstIndex(of: group) {
            priorityGroups.remove(at: index)
        } else if priorityGroups.count < 4 {
            priorityGroups.append(group)
        }
    }

    /// Applies a days-per-week choice by seeding well-spaced days, keeping whatever the user has
    /// already chosen when the count has not changed.
    func setDaysPerWeek(_ count: Int) {
        let clamped = InputValidation.clampedDaysPerWeek(count)
        guard clamped != availableWeekdays.count else { return }
        availableWeekdays = Set(OnboardingSchedule.suggestedWeekdays(count: clamped))
    }

    func toggleWeekday(_ day: Weekday) {
        if availableWeekdays.contains(day) {
            // Never let the user reach zero training days from a tap; the constraint is explained
            // by the hint under the picker rather than by a control that silently does nothing.
            guard availableWeekdays.count > 1 else { return }
            availableWeekdays.remove(day)
        } else {
            availableWeekdays.insert(day)
        }
    }

    func applyEquipmentPreset(_ preset: GymSetupPreset) {
        equipmentPreset = preset
        guard preset != .custom else { return }
        selectedEquipment = preset.equipment
    }

    func toggleLimitation(_ limitation: MobilityLimitation) {
        if mobilityLimitations.contains(limitation) {
            mobilityLimitations.remove(limitation)
        } else {
            mobilityLimitations.insert(limitation)
        }
    }

    /// Records the answer to the reminders step. Called by the view once the system prompt, if it
    /// was needed, has been answered.
    func recordNotificationOutcome(_ outcome: OnboardingNotificationOutcome) {
        notificationOutcome = outcome
    }

    // MARK: - Unit-aware bindings

    /// Everything below converts at the presentation edge. The draft itself never holds a pound.

    /// Metric or imperial as one choice. People think in systems, not in a mass unit and a length
    /// unit, and offering the two separately only invites "kilograms and feet".
    var unitSystem: UnitSystem {
        get { weightUnit == .kilograms ? .metric : .imperial }
        set {
            weightUnit = newValue == .metric ? .kilograms : .pounds
            heightUnit = newValue == .metric ? .centimeters : .feetInches
        }
    }

    /// Whole years, derived from the birth date the profile stores. Setting it re-derives the date.
    var ageYears: Int? {
        get { Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year }
        set {
            guard let newValue else { return }
            birthDate = Calendar.current.date(byAdding: .year, value: -newValue, to: Date()) ?? birthDate
        }
    }

    var currentWeightDisplay: Double? {
        get { currentWeightKg.map { Units.display(kilograms: $0, unit: weightUnit) } }
        set { currentWeightKg = newValue.map { Units.kilograms(fromDisplay: $0, unit: weightUnit) } }
    }

    var heightFeet: Int? {
        get { heightCm.map { Units.feetAndInches(fromCentimeters: $0).feet } }
        set {
            let parts = Units.feetAndInches(fromCentimeters: heightCm ?? 175)
            heightCm = Units.centimeters(fromFeet: newValue ?? 0, inches: parts.inches.rounded())
        }
    }

    var heightInches: Int? {
        get { heightCm.map { Int(Units.feetAndInches(fromCentimeters: $0).inches.rounded()) } }
        set {
            let parts = Units.feetAndInches(fromCentimeters: heightCm ?? 175)
            // 12 inches is a foot; wrapping rather than clamping is what the user means when they
            // step past the end of the ladder.
            let inches = min(max(newValue ?? 0, 0), 11)
            heightCm = Units.centimeters(fromFeet: parts.feet, inches: Double(inches))
        }
    }

    /// The time the reminder fires, as hour and minute components.
    var reminderComponents: (hour: Int, minute: Int) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        return (parts.hour ?? OnboardingSchedule.defaultReminderHour, parts.minute ?? 0)
    }

    /// Swapping units re-seeds the gym's hardware, because the hardware genuinely differs: a pound
    /// gym has a 45 lb bar and 45/35/25 lb plates, not a 20 kg bar rounded to 44.1 lb.
    private func applyWeightUnitDefaults(previous: WeightUnit) {
        let poundsPerKg = WeightUnit.pounds.kilogramsPerUnit
        if weightUnit == .pounds {
            barbellBarWeightKg = 45 * poundsPerKg
            ezBarWeightKg = 25 * poundsPerKg
            machineIncrementKg = 10 * poundsPerKg
            cableIncrementKg = 5 * poundsPerKg
            dumbbellStepKg = 5 * poundsPerKg
            selectedPlatesKg = Set([45, 35, 25, 10, 5, 2.5].map { $0 * poundsPerKg })
            kettlebellsKg = Set([10, 15, 20, 25, 35, 45, 55, 70].map { $0 * poundsPerKg })
        } else {
            barbellBarWeightKg = 20
            ezBarWeightKg = 10
            machineIncrementKg = 5
            cableIncrementKg = 2.5
            dumbbellStepKg = 2.5
            selectedPlatesKg = Set(EquipmentIncrements.default.availablePlatesKg)
            kettlebellsKg = Set(EquipmentIncrements.default.kettlebellsKg)
        }
        AppLog.app.debug(
            "Onboarding units changed from \(previous.rawValue, privacy: .public) to \(self.weightUnit.rawValue, privacy: .public)"
        )
    }

    /// Keeps the months-of-training figure and the technique answer honest when the level changes:
    /// somebody who has just said they have never trained should not be left holding "6 months",
    /// and somebody who says "advanced" should not be programmed as still learning the lifts.
    private func alignTrainingMonths(to level: ExperienceLevel, from previous: ExperienceLevel) {
        switch level {
        case .never:
            trainingMonths = 0
            techniqueConfidence = .unfamiliar
        case .beginner:
            if (trainingMonths ?? 0) == 0 || previous == .never { trainingMonths = 6 }
            techniqueConfidence = .learning
        case .intermediate:
            if (trainingMonths ?? 0) < 12 { trainingMonths = 18 }
            techniqueConfidence = .confident
        case .advanced:
            if (trainingMonths ?? 0) < 36 { trainingMonths = 48 }
            techniqueConfidence = .confident
        }
    }

    /// The smallest gap in a stored dumbbell ladder, used to re-seed the step control on reload.
    private static func inferredDumbbellStep(from ladder: [Double]) -> Double {
        let sorted = ladder.sorted()
        guard sorted.count >= 2 else { return 2.5 }
        var smallest = Double.greatestFiniteMagnitude
        for index in 1..<sorted.count { smallest = min(smallest, sorted[index] - sorted[index - 1]) }
        return smallest.isFinite && smallest > 0 ? smallest : 2.5
    }

    // MARK: - Persistence

    /// Writes the answers belonging to one step. Returns `false` and sets `errorMessage` on failure,
    /// which is what stops the flow advancing past an answer that did not make it to disk.
    @discardableResult
    func persist(_ step: OnboardingStep, context: ModelContext) -> Bool {
        let repository = ProfileRepository(context: context)
        do {
            switch step {
            case .welcome, .ready:
                break
            case .about:
                try repository.updateIdentity(
                    name: .some(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name),
                    birthDate: .some(birthDate),
                    biologicalSex: biologicalSex
                )
                // The target weight is not asked here; leaving it out keeps whatever is on file.
                try repository.updateBodyMetrics(
                    heightCm: heightCm,
                    currentWeightKg: currentWeightKg
                )
                try repository.updateSettings { settings in
                    settings.weightUnit = self.weightUnit
                    settings.heightUnit = self.heightUnit
                    // Distance and energy have no question of their own; deriving them from the
                    // mass unit is what every user expects and none of them wants to be asked.
                    settings.distanceUnit = self.weightUnit == .kilograms ? .kilometers : .miles
                }
            case .goal:
                try repository.updateGoals(
                    goals: goals,
                    priorityGroups: priorityGroups,
                    priorityRegions: priorityRegions
                )
                try repository.updateExperience(
                    level: experience,
                    months: trainingMonths ?? 0,
                    techniqueConfidence: techniqueConfidence
                )
                try repository.updateSettings { settings in
                    settings.nutritionEnabled = self.nutritionEnabled
                    settings.dynamicCalorieAdjustmentEnabled = self.nutritionEnabled
                    settings.waterTrackingEnabled = self.nutritionEnabled
                }
            case .week:
                try repository.updateAvailability(
                    weekdays: Array(availableWeekdays),
                    sessionMinutesCap: sessionMinutes,
                    preferredTrainingTime: preferredTrainingTime,
                    cardioPreference: cardioPreference
                )
                try repository.updateGoals(activityLevel: activityLevel)
            case .gear:
                try repository.updateEquipment(preset: equipmentPreset, availableEquipment: selectedEquipment)
                try repository.updateIncrements(
                    barbellBarWeightKg: barbellBarWeightKg,
                    ezBarWeightKg: ezBarWeightKg,
                    availablePlatesKg: selectedPlatesKg.isEmpty ? nil : Array(selectedPlatesKg),
                    availableDumbbellsKg: OnboardingOptions.dumbbellLadder(step: dumbbellStepKg),
                    kettlebellsKg: kettlebellsKg.isEmpty ? nil : Array(kettlebellsKg),
                    machineIncrementKg: machineIncrementKg,
                    cableIncrementKg: cableIncrementKg
                )
                try repository.updateRestrictions(
                    mobilityLimitations: Array(mobilityLimitations),
                    avoidedPatterns: Array(avoidedPatterns)
                )
            case .reminders:
                // Nothing is switched on without consent on both gates: the user's yes on our
                // screen and the system's yes at its prompt.
                let isGranted = notificationOutcome == .granted
                let time = reminderComponents
                try repository.updateSettings { settings in
                    settings.notificationsEnabled = isGranted
                    settings.trainingReminderEnabled = isGranted && self.wantsTrainingReminder
                    settings.trainingReminderHour = time.hour
                    settings.trainingReminderMinute = time.minute
                    settings.restTimerNotificationEnabled = self.wantsRestAlert
                }
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            AppLog.app.error(
                "Onboarding step \(step.rawValue, privacy: .public) failed to save: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// Re-writes every step. Used before generating and before finishing, so a step the user jumped
    /// over can never be the one answer that never reached the store.
    @discardableResult
    func persistAll(context: ModelContext) -> Bool {
        for step in plan.steps where step.collectsInput {
            guard persist(step, context: context) else { return false }
        }
        return true
    }

    /// Schedules the reminders the user agreed to. A no-op unless both gates said yes, because
    /// `NotificationService.applySettings` clears the queue whenever notifications are off.
    func applyNotificationSchedule(service: NotificationService, context: ModelContext) async {
        guard let settings = try? ProfileRepository(context: context).settings() else { return }
        await service.applySettings(settings, weekdays: Weekday.orderedMondayFirst.filter(availableWeekdays.contains))
    }

    // MARK: - Program generation

    /// True when the result step should do work rather than show what it already produced.
    var shouldGenerate: Bool {
        switch generation {
        case .idle, .failed: true
        case .running: false
        case .ready: needsRegeneration
        }
    }

    /// Builds the program and the nutrition targets, and persists both.
    ///
    /// The engine call itself is pure and CPU-bound over the whole catalogue, so it runs off the
    /// main actor; everything that touches SwiftData stays on it.
    func generateProgram(context: ModelContext, catalog: ExerciseCatalog) async {
        guard !generation.isRunning else { return }
        generation = .running
        errorMessage = nil

        guard persistAll(context: context) else {
            generation = .failed(errorMessage ?? L("common.error"))
            return
        }

        do {
            let profileRepository = ProfileRepository(context: context)
            let snapshot = try profileRepository.trainingProfileSnapshot()
            let increments = try profileRepository.increments()

            var request = ProgrammingRequest(profile: snapshot)
            request.increments = increments

            let exercises = catalog.exercises
            guard !exercises.isEmpty else {
                generation = .failed(L("onboarding.generate.error.catalog"))
                return
            }

            let generated = await Task.detached(priority: .userInitiated) {
                WorkoutProgrammingEngine(catalog: exercises).generate(request)
            }.value

            guard !generated.trainingSessions.isEmpty else {
                generation = .failed(L("onboarding.generate.error.empty"))
                return
            }

            let title = L("onboarding.program.title", L(generated.splitKey))
            let programRepository = ProgramRepository(context: context)
            // Re-running onboarding rewrites the plan the user is already on rather than stacking a
            // second program beside it, so the version history stays a single readable line. A
            // hand-built program is never overwritten: the user made it, the engine did not.
            if let existing = try programRepository.activeProgram(), !existing.isManuallyCreated {
                try programRepository.apply(generated, to: existing, reason: Explanation("explain.programCreated"))
                try programRepository.rename(existing, to: title)
            } else {
                try programRepository.install(
                    generated,
                    profile: snapshot,
                    title: title,
                    reason: Explanation("explain.programCreated")
                )
            }

            let energy = try persistNutritionTargets(context: context, profileRepository: profileRepository)

            generation = .ready(
                OnboardingProgramResult(
                    programTitle: title,
                    splitKey: generated.splitKey,
                    daysPerWeek: generated.daysPerWeek,
                    sessions: generated.sessions,
                    weeklyVolume: generated.weeklyVolume,
                    explanations: generated.explanations,
                    energyTargets: energy
                ))
            needsRegeneration = false
            Haptics.success()
        } catch {
            AppLog.app.error("Onboarding generation failed: \(String(describing: error), privacy: .public)")
            generation = .failed(Self.message(for: error))
        }
    }

    /// The escape hatch when generation fails: an empty program with the right shape, which the
    /// program editor can fill in. The user still leaves onboarding with a working app.
    func createManualProgram(context: ModelContext) {
        do {
            let profileRepository = ProfileRepository(context: context)
            let snapshot = try profileRepository.trainingProfileSnapshot()
            let title = L("onboarding.program.manualTitle")
            let programRepository = ProgramRepository(context: context)
            try programRepository.createEmptyProgram(
                title: title,
                daysPerWeek: daysPerWeek,
                profile: snapshot
            )
            // Nutrition does not depend on the catalogue, so it is still worth computing here.
            let energy = try? persistNutritionTargets(context: context, profileRepository: profileRepository)

            generation = .ready(
                OnboardingProgramResult(
                    programTitle: title,
                    splitKey: "split.custom",
                    daysPerWeek: daysPerWeek,
                    sessions: [],
                    weeklyVolume: [:],
                    explanations: [Explanation("onboarding.generate.manualExplanation")],
                    energyTargets: energy ?? nil,
                    isManual: true
                ))
            needsRegeneration = false
        } catch {
            generation = .failed(Self.message(for: error))
        }
    }

    /// Computes and stores the daily energy target. Returns `nil` when the user turned nutrition off
    /// — in that case no target is written at all, rather than a target nobody asked for.
    @discardableResult
    private func persistNutritionTargets(
        context: ModelContext,
        profileRepository: ProfileRepository
    ) throws -> EnergyTargets? {
        guard nutritionEnabled else { return nil }
        let snapshot = try profileRepository.nutritionProfileSnapshot()
        let targets = NutritionRecommendationEngine.targets(for: snapshot)
        let nutritionRepository = NutritionRepository(context: context)
        try nutritionRepository.replaceActiveTarget(
            kilocalories: targets.kilocalories,
            proteinG: targets.proteinG,
            carbsG: targets.carbsG,
            fatG: targets.fatG,
            isManualOverride: false,
            rationale: targets.explanations.first,
            reason: Explanation("onboarding.nutrition.targetReason"),
            wasAutomatic: true
        )
        return targets
    }

    // MARK: - Completion

    /// Marks onboarding finished. `RootView` watches `onboardingCompletedAt` and swaps the whole
    /// app over the moment it is set, so this is the last thing that happens. The guided tour is
    /// queued first, so the main screen opens with it already waiting.
    @discardableResult
    func finish(context: ModelContext) -> Bool {
        guard persistAll(context: context) else { return false }
        do {
            // The guide is for people meeting the app for the first time. Somebody who has just
            // re-run setup from Settings already knows where everything is.
            if !isReturningUser { GuidedTourStore.markPending() }
            try ProfileRepository(context: context).completeOnboarding()
            Haptics.success()
            return true
        } catch {
            GuidedTourStore.clearPending()
            errorMessage = Self.message(for: error)
            return false
        }
    }

    // MARK: - Errors

    static func message(for error: Error) -> String {
        if let repositoryError = error as? RepositoryError {
            return repositoryError.explanation.text
        }
        return L("common.error")
    }
}
