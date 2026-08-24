import Foundation
import Observation
import SwiftData

// MARK: - Supporting value types

/// One self-reported strength marker while it is being typed. Loads are held canonically in
/// kilograms; the field the user sees converts at the edge like everything else.
struct StrengthSeedDraft: Hashable, Sendable {
    var weightKg: Double?
    var reps: Int?

    /// A seed is only worth storing when both halves are present: a load with no rep count says
    /// nothing about strength, and `LoadEstimator` would have to invent the missing half.
    var isUsable: Bool { (weightKg ?? 0) > 0 && (reps ?? 0) > 0 }
}

/// A benchmark lift matched against the catalogue, ready to be offered as a strength seed.
struct StrengthSeedOption: Identifiable, Hashable, Sendable {
    var labelKey: String
    var exercise: Exercise
    var id: String { exercise.id }
}

/// What the generation step produced, kept as plain values so the review screen can render the
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

// MARK: - View model

/// Owns every answer the onboarding flow collects, the rules that decide when an answer is usable,
/// and the writes that turn the finished draft into a working app.
///
/// The draft is held here rather than in the step views for one reason: the answers are
/// interdependent. Training days change the split, equipment changes which exercises exist, the
/// goal changes the calorie direction. A step view that owned its own slice of state could not see
/// those relationships, and the review screen could not show them back.
///
/// Answers are written to the store as each step is left, not batched at the end. Onboarding is the
/// longest uninterrupted stretch of typing the app will ever ask for, and losing it to a phone call
/// is not a failure mode worth designing in.
@MainActor
@Observable
final class OnboardingViewModel {

    // MARK: Navigation

    private(set) var plan: OnboardingStepPlan = .firstRun
    private(set) var step: OnboardingStep = .welcome
    private(set) var isReturningUser = false
    private var didLoad = false

    /// Set when the user walks back into a question after a program has already been built, so the
    /// generation step knows the plan on file no longer matches the answers on screen.
    private(set) var needsRegeneration = false

    /// A persistence failure, shown inline with a retry rather than as an alert.
    var errorMessage: String?

    // MARK: Draft — identity and body

    var name: String = ""
    /// Date of birth is optional, and the nutrition engine says so in its own explanation when it is
    /// missing rather than quietly assuming an age.
    var wantsBirthDate: Bool = true
    var birthDate: Date = OnboardingViewModel.defaultBirthDate
    var biologicalSex: BiologicalSex = .unspecified

    var weightUnit: WeightUnit = .kilograms {
        didSet { if weightUnit != oldValue { applyWeightUnitDefaults(previous: oldValue) } }
    }
    var heightUnit: HeightUnit = .centimeters

    var heightCm: Double? = 175
    var currentWeightKg: Double? = 75
    var wantsTargetWeight: Bool = false
    var targetWeightKg: Double?

    // MARK: Draft — goals

    /// Ordered: the first goal is the primary one and drives the rep ranges and the energy balance.
    var goals: [TrainingGoal] = []
    var priorityGroups: [MuscleGroup] = []
    var priorityRegions: [TrainingFocusRegion] = []

    // MARK: Draft — experience

    var experience: ExperienceLevel = .beginner {
        didSet { if experience != oldValue { alignTrainingMonths(to: experience, from: oldValue) } }
    }
    var trainingMonths: Int? = 6
    var techniqueConfidence: TechniqueConfidence = .learning
    var wantsStrengthSeeds = false
    var strengthSeeds: [String: StrengthSeedDraft] = [:]
    private(set) var strengthSeedOptions: [StrengthSeedOption] = []

    // MARK: Draft — availability

    var availableWeekdays: Set<Weekday> = Set(OnboardingSchedule.suggestedWeekdays(count: 3))
    var sessionMinutes: Int = 60
    var preferredTrainingTime: PreferredTrainingTime = .evening
    var cardioPreference: CardioPreference = .either
    var activityLevel: ActivityLevel = .moderate

    // MARK: Draft — equipment

    var equipmentPreset: GymSetupPreset = .fullGym
    var selectedEquipment: Set<Equipment> = Equipment.fullGym
    var barbellBarWeightKg: Double? = 20
    var ezBarWeightKg: Double? = 10
    var selectedPlatesKg: Set<Double> = Set(EquipmentIncrements.default.availablePlatesKg)
    var dumbbellStepKg: Double = 2.5
    var kettlebellsKg: Set<Double> = Set(EquipmentIncrements.default.kettlebellsKg)
    var machineIncrementKg: Double? = 5
    var cableIncrementKg: Double? = 2.5

    // MARK: Draft — restrictions

    var mobilityLimitations: Set<MobilityLimitation> = []
    var avoidedPatterns: Set<MovementPattern> = []
    var excludedExerciseIDs: [String] = []

    // MARK: Draft — nutrition

    var nutritionEnabled = true
    var dietType: DietType = .omnivore
    var allergenTags: Set<String> = []
    var intoleranceTags: Set<String> = []
    var excludedFoodTags: Set<String> = []
    var customFoodTags: [String] = []
    var mealsPerDay: Int = 4
    var nutritionPace: NutritionGoalPace = .moderate
    var wantsBudget = false
    var weeklyFoodBudget: Double?

    // MARK: Generation

    private(set) var generation: OnboardingGenerationState = .idle

    private static var defaultBirthDate: Date {
        Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
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
            wantsBirthDate = profile.birthDate != nil
            birthDate = profile.birthDate ?? Self.defaultBirthDate
            biologicalSex = profile.biologicalSex
            heightCm = profile.heightCm
            currentWeightKg = profile.currentWeightKg
            targetWeightKg = profile.targetWeightKg
            wantsTargetWeight = profile.targetWeightKg != nil

            goals = profile.goals
            priorityGroups = profile.priorityGroups
            priorityRegions = profile.priorityRegions

            experience = profile.experience
            trainingMonths = profile.trainingExperienceMonths
            techniqueConfidence = profile.techniqueConfidence
            strengthSeeds = Dictionary(
                profile.strengthSeeds.map { ($0.exerciseID, StrengthSeedDraft(weightKg: $0.weightKg, reps: $0.reps)) },
                uniquingKeysWith: { first, _ in first }
            )
            wantsStrengthSeeds = !strengthSeeds.isEmpty

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
            excludedExerciseIDs = profile.excludedExerciseIDs

            dietType = profile.dietType
            allergenTags = Set(profile.allergenTags)
            intoleranceTags = Set(profile.intoleranceTags)
            excludedFoodTags = Set(profile.excludedFoodTags)
            customFoodTags = profile.excludedFoodTags.filter { !OnboardingOptions.excludableFoodTags.contains($0) }
            mealsPerDay = profile.mealsPerDay
            nutritionPace = profile.nutritionPace
            weeklyFoodBudget = profile.weeklyFoodBudget
            wantsBudget = profile.weeklyFoodBudget != nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Matches the benchmark lifts against the loaded catalogue. Cheap, and idempotent.
    func prepareStrengthSeeds(catalog: ExerciseCatalog) {
        guard strengthSeedOptions.isEmpty, catalog.isLoaded else { return }
        var used = Set<String>()
        var options: [StrengthSeedOption] = []
        for entry in OnboardingOptions.strengthSeedQueries {
            for term in entry.terms {
                let matches = catalog.search(term, limit: 12).filter { !used.contains($0.id) }
                // Prefer a result whose name actually contains the phrase; the search index is
                // fuzzy on purpose and its best score is not always the canonical lift.
                let match = matches.first { $0.name.localizedCaseInsensitiveContains(term) } ?? matches.first
                if let match {
                    used.insert(match.id)
                    options.append(StrengthSeedOption(labelKey: entry.labelKey, exercise: match))
                    break
                }
            }
        }
        strengthSeedOptions = options
    }

    // MARK: - Navigation

    var canGoBack: Bool { plan.previous(before: step) != nil }
    var canSkip: Bool { step.isSkippable }

    var progress: Double { plan.progress(at: step) }

    /// "Step 3 of 7", or `nil` on the screens that ask nothing.
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

    /// Moves past an optional step without demanding an answer.
    func skip(context: ModelContext) {
        guard step.isSkippable, let next = plan.next(after: step) else { return }
        _ = persist(step, context: context)
        move(to: next)
    }

    /// Jumps straight to a step. Used by the review screen's per-section edit buttons.
    func jump(to destination: OnboardingStep) {
        guard plan.steps.contains(destination) else { return }
        move(to: destination)
    }

    private func move(to destination: OnboardingStep) {
        // Editing an answer after the program exists invalidates it. The flag is what makes the
        // generation step re-run instead of showing a plan built from superseded answers.
        if destination.collectsInput, generation.result != nil {
            needsRegeneration = true
        }
        errorMessage = nil
        step = destination
    }

    // MARK: - Validation

    /// Field order used to pick which of several problems to name first.
    private static let fieldOrder = [
        "heightCm", "currentWeightKg", "targetWeightKg", "birthDate", "goals", "priorityGroups",
        "availableWeekdays", "sessionMinutes", "selectedEquipment", "plates", "machineIncrementKg",
        "cableIncrementKg", "barbellBarWeightKg", "ezBarWeightKg", "mealsPerDay", "weeklyFoodBudget"
    ]

    /// Every problem on `step`, keyed by the field it belongs to, so a control can show its own hint
    /// underneath itself as well as next to the button.
    func issues(for step: OnboardingStep) -> [String: String] {
        var issues: [String: String] = [:]
        switch step {
        case .basics:
            if let message = rangeIssue(heightCm, range: InputValidation.heightCm, unitKey: "onboarding.unit.cm") {
                issues["heightCm"] = message
            }
            if let message = rangeIssue(currentWeightKg, range: InputValidation.bodyMassKg, unitKey: "onboarding.unit.kg") {
                issues["currentWeightKg"] = message
            }
            if wantsTargetWeight,
               let message = rangeIssue(targetWeightKg, range: InputValidation.bodyMassKg, unitKey: "onboarding.unit.kg") {
                issues["targetWeightKg"] = message
            }
            if wantsBirthDate {
                let years = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? -1
                if !InputValidation.ageYears.contains(years) {
                    issues["birthDate"] = L(
                        "onboarding.hint.age",
                        InputValidation.ageYears.lowerBound, InputValidation.ageYears.upperBound
                    )
                }
            }
        case .goals:
            if goals.isEmpty { issues["goals"] = L("onboarding.hint.goalsEmpty") }
            if goals.contains(.targetMuscleGroup), priorityGroups.isEmpty, priorityRegions.isEmpty {
                issues["priorityGroups"] = L("onboarding.hint.priorityRequired")
            }
        case .availability:
            if availableWeekdays.isEmpty { issues["availableWeekdays"] = L("onboarding.hint.daysEmpty") }
            if !InputValidation.sessionMinutes.contains(sessionMinutes) {
                issues["sessionMinutes"] = L(
                    "onboarding.hint.sessionMinutes",
                    InputValidation.sessionMinutes.lowerBound, InputValidation.sessionMinutes.upperBound
                )
            }
        case .equipment:
            if selectedEquipment.isEmpty { issues["selectedEquipment"] = L("onboarding.hint.equipmentEmpty") }
            if usesBarbell, selectedPlatesKg.isEmpty { issues["plates"] = L("onboarding.hint.platesEmpty") }
            if usesBarbell,
               let message = rangeIssue(barbellBarWeightKg, range: InputValidation.loadKg, unitKey: "onboarding.unit.kg") {
                issues["barbellBarWeightKg"] = message
            }
            if selectedEquipment.contains(.ezBarbell),
               let message = rangeIssue(ezBarWeightKg, range: InputValidation.loadKg, unitKey: "onboarding.unit.kg") {
                issues["ezBarWeightKg"] = message
            }
            if usesMachines, let message = incrementIssue(machineIncrementKg) {
                issues["machineIncrementKg"] = message
            }
            if selectedEquipment.contains(.cable), let message = incrementIssue(cableIncrementKg) {
                issues["cableIncrementKg"] = message
            }
        case .nutrition:
            guard nutritionEnabled else { break }
            if !InputValidation.mealsPerDay.contains(mealsPerDay) {
                issues["mealsPerDay"] = L(
                    "onboarding.hint.mealsPerDay",
                    InputValidation.mealsPerDay.lowerBound, InputValidation.mealsPerDay.upperBound
                )
            }
            if wantsBudget, let budget = weeklyFoodBudget, !budget.isFinite || budget <= 0 {
                issues["weeklyFoodBudget"] = L("onboarding.hint.budget")
            }
            if wantsBudget, weeklyFoodBudget == nil {
                issues["weeklyFoodBudget"] = L("onboarding.hint.budget")
            }
        case .welcome, .experience, .restrictions, .generating, .summary:
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
            lower = Units.formatWeight(kilograms: range.lowerBound, unit: weightUnit, includeUnit: false, fractionDigits: 0)
            upper = Units.formatWeight(kilograms: range.upperBound, unit: weightUnit, includeUnit: false, fractionDigits: 0)
            return L("onboarding.hint.range", lower, upper, weightUnit.rawValue)
        }
        lower = Units.formatDecimal(range.lowerBound, digits: 0)
        upper = Units.formatDecimal(range.upperBound, digits: 0)
        return L("onboarding.hint.range", lower, upper, L(unitKey))
    }

    private func incrementIssue(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return L("onboarding.hint.missingNumber") }
        guard !InputValidation.loadIncrementKg.contains(value) else { return nil }
        let lower = Units.formatWeight(
            kilograms: InputValidation.loadIncrementKg.lowerBound, unit: weightUnit, includeUnit: false, fractionDigits: 2
        )
        let upper = Units.formatWeight(
            kilograms: InputValidation.loadIncrementKg.upperBound, unit: weightUnit, includeUnit: false, fractionDigits: 0
        )
        return L("onboarding.hint.range", lower, upper, weightUnit.rawValue)
    }

    // MARK: - Derived answers

    var daysPerWeek: Int { max(1, availableWeekdays.count) }

    var usesBarbell: Bool {
        !selectedEquipment.isDisjoint(with: [.barbell, .olympicBarbell, .trapBar, .smithMachine])
    }

    var usesMachines: Bool {
        !selectedEquipment.isDisjoint(with: [.leverageMachine, .sledMachine])
    }

    var usesDumbbells: Bool { selectedEquipment.contains(.dumbbell) }
    var usesKettlebells: Bool { selectedEquipment.contains(.kettlebell) }

    /// Groups and regions merged, in the order the user picked them, for the review screen.
    var resolvedPriorityGroups: [MuscleGroup] {
        var seen = Set<MuscleGroup>()
        var result: [MuscleGroup] = []
        for group in priorityGroups where seen.insert(group).inserted { result.append(group) }
        for region in priorityRegions {
            for group in region.groups where seen.insert(group).inserted { result.append(group) }
        }
        return result
    }

    /// How many exercises the current equipment selection makes available. Every exercise in the
    /// dataset carries exactly one piece of equipment, so summing the per-equipment counts is exact
    /// rather than an approximation.
    func exerciseCount(for equipment: Set<Equipment>, catalog: ExerciseCatalog) -> Int {
        equipment.reduce(0) { $0 + catalog.count(forEquipment: $1) }
    }

    func unlockedExerciseCount(catalog: ExerciseCatalog) -> Int {
        exerciseCount(for: selectedEquipment, catalog: catalog)
    }

    /// Patterns already ruled out by the mobility answers, which the pattern picker shows as
    /// pre-selected and locked so the user is not asked the same question twice.
    var patternsImpliedByLimitations: Set<MovementPattern> {
        mobilityLimitations.reduce(into: Set<MovementPattern>()) { $0.formUnion($1.blockedPatterns) }
    }

    // MARK: - Draft mutation

    func toggleGoal(_ goal: TrainingGoal) {
        if let index = goals.firstIndex(of: goal) {
            goals.remove(at: index)
        } else {
            // Four goals is already more than a single program can serve; past that the engine is
            // being asked to optimise for everything, which optimises for nothing.
            guard goals.count < 4 else { return }
            goals.append(goal)
        }
    }

    func togglePriorityGroup(_ group: MuscleGroup) {
        if let index = priorityGroups.firstIndex(of: group) {
            priorityGroups.remove(at: index)
        } else if priorityGroups.count < 4 {
            priorityGroups.append(group)
        }
    }

    func togglePriorityRegion(_ region: TrainingFocusRegion) {
        if let index = priorityRegions.firstIndex(of: region) {
            priorityRegions.remove(at: index)
        } else if priorityRegions.count < 2 {
            priorityRegions.append(region)
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

    func toggleEquipment(_ item: Equipment) {
        if selectedEquipment.contains(item) {
            selectedEquipment.remove(item)
        } else {
            selectedEquipment.insert(item)
        }
        // Bodyweight is always true of a human being; letting it be switched off produces a profile
        // where the selector legitimately has nothing to return.
        selectedEquipment.insert(.bodyWeight)
        equipmentPreset = .custom
    }

    func toggleLimitation(_ limitation: MobilityLimitation) {
        if mobilityLimitations.contains(limitation) {
            mobilityLimitations.remove(limitation)
        } else {
            mobilityLimitations.insert(limitation)
        }
        // Patterns implied by a limitation are derived, never stored twice: dropping them from the
        // explicit set keeps "what the user chose" and "what follows from it" separable.
        avoidedPatterns.subtract(patternsImpliedByLimitations)
    }

    func togglePattern(_ pattern: MovementPattern) {
        guard !patternsImpliedByLimitations.contains(pattern) else { return }
        if avoidedPatterns.contains(pattern) {
            avoidedPatterns.remove(pattern)
        } else {
            avoidedPatterns.insert(pattern)
        }
    }

    func toggleExcludedExercise(_ id: String) {
        if let index = excludedExerciseIDs.firstIndex(of: id) {
            excludedExerciseIDs.remove(at: index)
        } else {
            excludedExerciseIDs.append(id)
        }
    }

    func toggleTag(_ tag: String, in set: ReferenceWritableKeyPath<OnboardingViewModel, Set<String>>) {
        if self[keyPath: set].contains(tag) {
            self[keyPath: set].remove(tag)
        } else {
            self[keyPath: set].insert(tag)
        }
    }

    func addCustomFoodTag(_ raw: String) {
        let cleaned = InputValidation.normalisedTags([raw])
        guard let tag = cleaned.first, !customFoodTags.contains(tag) else { return }
        customFoodTags.append(tag)
        excludedFoodTags.insert(tag)
    }

    func removeCustomFoodTag(_ tag: String) {
        customFoodTags.removeAll { $0 == tag }
        excludedFoodTags.remove(tag)
    }

    /// Clears the optional strength seeds. Wired to the section's Skip control.
    func clearStrengthSeeds() {
        strengthSeeds = [:]
        wantsStrengthSeeds = false
    }

    // MARK: - Unit-aware bindings

    /// Everything below converts at the presentation edge. The draft itself never holds a pound.

    var currentWeightDisplay: Double? {
        get { currentWeightKg.map { Units.display(kilograms: $0, unit: weightUnit) } }
        set { currentWeightKg = newValue.map { Units.kilograms(fromDisplay: $0, unit: weightUnit) } }
    }

    var targetWeightDisplay: Double? {
        get { targetWeightKg.map { Units.display(kilograms: $0, unit: weightUnit) } }
        set { targetWeightKg = newValue.map { Units.kilograms(fromDisplay: $0, unit: weightUnit) } }
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

    var barbellBarWeightDisplay: Double? {
        get { barbellBarWeightKg.map { Units.display(kilograms: $0, unit: weightUnit) } }
        set { barbellBarWeightKg = newValue.map { Units.kilograms(fromDisplay: $0, unit: weightUnit) } }
    }

    var ezBarWeightDisplay: Double? {
        get { ezBarWeightKg.map { Units.display(kilograms: $0, unit: weightUnit) } }
        set { ezBarWeightKg = newValue.map { Units.kilograms(fromDisplay: $0, unit: weightUnit) } }
    }

    var machineIncrementDisplay: Double? {
        get { machineIncrementKg.map { Units.display(kilograms: $0, unit: weightUnit) } }
        set { machineIncrementKg = newValue.map { Units.kilograms(fromDisplay: $0, unit: weightUnit) } }
    }

    var cableIncrementDisplay: Double? {
        get { cableIncrementKg.map { Units.display(kilograms: $0, unit: weightUnit) } }
        set { cableIncrementKg = newValue.map { Units.kilograms(fromDisplay: $0, unit: weightUnit) } }
    }

    func seedWeightDisplay(for exerciseID: String) -> Double? {
        strengthSeeds[exerciseID]?.weightKg.map { Units.display(kilograms: $0, unit: weightUnit) }
    }

    func setSeedWeightDisplay(_ value: Double?, for exerciseID: String) {
        var draft = strengthSeeds[exerciseID] ?? StrengthSeedDraft()
        draft.weightKg = value.map { Units.kilograms(fromDisplay: $0, unit: weightUnit) }
        strengthSeeds[exerciseID] = draft
    }

    func setSeedReps(_ value: Int?, for exerciseID: String) {
        var draft = strengthSeeds[exerciseID] ?? StrengthSeedDraft()
        draft.reps = value.map { InputValidation.clampedReps($0) }
        strengthSeeds[exerciseID] = draft
    }

    /// The plate sizes offered, in the user's own unit. A gym stocked in pounds has 45s and 35s, not
    /// 20 kg plates, so offering the metric ladder to an imperial user is offering the wrong gym.
    var plateOptionsKg: [Double] {
        weightUnit == .kilograms
            ? OnboardingOptions.plateOptionsKg
            : OnboardingOptions.plateOptionsLb.map { $0 * WeightUnit.pounds.kilogramsPerUnit }
    }

    var dumbbellStepOptionsKg: [Double] {
        weightUnit == .kilograms
            ? OnboardingOptions.dumbbellStepOptionsKg
            : OnboardingOptions.dumbbellStepOptionsLb.map { $0 * WeightUnit.pounds.kilogramsPerUnit }
    }

    var kettlebellOptionsKg: [Double] {
        weightUnit == .kilograms
            ? OnboardingOptions.kettlebellOptionsKg
            : OnboardingOptions.kettlebellOptionsLb.map { $0 * WeightUnit.pounds.kilogramsPerUnit }
    }

    func togglePlate(_ kilograms: Double) {
        if let existing = selectedPlatesKg.first(where: { abs($0 - kilograms) < 0.001 }) {
            selectedPlatesKg.remove(existing)
        } else {
            selectedPlatesKg.insert(kilograms)
        }
    }

    func isPlateSelected(_ kilograms: Double) -> Bool {
        selectedPlatesKg.contains { abs($0 - kilograms) < 0.001 }
    }

    func toggleKettlebell(_ kilograms: Double) {
        if let existing = kettlebellsKg.first(where: { abs($0 - kilograms) < 0.001 }) {
            kettlebellsKg.remove(existing)
        } else {
            kettlebellsKg.insert(kilograms)
        }
    }

    func isKettlebellSelected(_ kilograms: Double) -> Bool {
        kettlebellsKg.contains { abs($0 - kilograms) < 0.001 }
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
            kettlebellsKg = Set(OnboardingOptions.kettlebellOptionsLb.map { $0 * poundsPerKg })
        } else {
            barbellBarWeightKg = 20
            ezBarWeightKg = 10
            machineIncrementKg = 5
            cableIncrementKg = 2.5
            dumbbellStepKg = 2.5
            selectedPlatesKg = Set(EquipmentIncrements.default.availablePlatesKg)
            kettlebellsKg = Set(EquipmentIncrements.default.kettlebellsKg)
        }
        AppLog.app.debug("Onboarding units changed from \(previous.rawValue, privacy: .public) to \(self.weightUnit.rawValue, privacy: .public)")
    }

    /// Keeps the months-of-training figure honest when the level changes: somebody who has just
    /// said they have never trained should not be left holding "6 months".
    private func alignTrainingMonths(to level: ExperienceLevel, from previous: ExperienceLevel) {
        switch level {
        case .never: trainingMonths = 0
        case .beginner where (trainingMonths ?? 0) == 0 || previous == .never: trainingMonths = 6
        case .intermediate where (trainingMonths ?? 0) < 12: trainingMonths = 18
        case .advanced where (trainingMonths ?? 0) < 36: trainingMonths = 48
        default: break
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
            case .welcome, .generating, .summary:
                break
            case .basics:
                try repository.updateIdentity(
                    name: .some(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name),
                    birthDate: .some(wantsBirthDate ? birthDate : nil),
                    biologicalSex: biologicalSex
                )
                try repository.updateBodyMetrics(
                    heightCm: heightCm,
                    currentWeightKg: currentWeightKg,
                    targetWeightKg: .some(wantsTargetWeight ? targetWeightKg : nil)
                )
                try repository.updateSettings { settings in
                    settings.weightUnit = self.weightUnit
                    settings.heightUnit = self.heightUnit
                    // Distance and energy have no question of their own; deriving them from the
                    // mass unit is what every user expects and none of them wants to be asked.
                    settings.distanceUnit = self.weightUnit == .kilograms ? .kilometers : .miles
                }
            case .goals:
                try repository.updateGoals(
                    goals: goals,
                    priorityGroups: priorityGroups,
                    priorityRegions: priorityRegions
                )
            case .experience:
                try repository.updateExperience(
                    level: experience,
                    months: trainingMonths ?? 0,
                    techniqueConfidence: techniqueConfidence
                )
                try persistStrengthSeeds(repository)
            case .availability:
                try repository.updateAvailability(
                    weekdays: Array(availableWeekdays),
                    sessionMinutesCap: sessionMinutes,
                    preferredTrainingTime: preferredTrainingTime,
                    cardioPreference: cardioPreference
                )
                try repository.updateGoals(activityLevel: activityLevel)
                try repository.updateSettings { settings in
                    settings.trainingReminderHour = self.preferredTrainingTime.reminderHour
                    settings.trainingReminderMinute = 0
                }
            case .equipment:
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
            case .restrictions:
                try repository.updateRestrictions(
                    mobilityLimitations: Array(mobilityLimitations),
                    avoidedPatterns: Array(avoidedPatterns)
                )
                try repository.setExcludedExerciseIDs(excludedExerciseIDs)
            case .nutrition:
                try repository.updateNutritionPreferences(
                    dietType: dietType,
                    allergenTags: Array(allergenTags),
                    intoleranceTags: Array(intoleranceTags),
                    excludedFoodTags: Array(excludedFoodTags),
                    mealsPerDay: mealsPerDay,
                    pace: nutritionPace,
                    weeklyFoodBudget: .some(wantsBudget ? weeklyFoodBudget : nil)
                )
                try repository.updateSettings { settings in
                    settings.nutritionEnabled = self.nutritionEnabled
                    settings.dynamicCalorieAdjustmentEnabled = self.nutritionEnabled
                    settings.waterTrackingEnabled = self.nutritionEnabled
                }
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.message(for: error)
            AppLog.app.error("Onboarding step \(step.rawValue, privacy: .public) failed to save: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func persistStrengthSeeds(_ repository: ProfileRepository) throws {
        for option in strengthSeedOptions {
            let draft = strengthSeeds[option.exercise.id]
            if wantsStrengthSeeds, let draft, draft.isUsable, let weight = draft.weightKg, let reps = draft.reps {
                try repository.upsertStrengthSeed(exerciseID: option.exercise.id, weightKg: weight, reps: reps)
            } else {
                try repository.removeStrengthSeed(exerciseID: option.exercise.id)
            }
        }
    }

    /// Re-writes every step. Used before generating and before finishing, so a step the user jumped
    /// over from the review screen can never be the one answer that never reached the store.
    @discardableResult
    func persistAll(context: ModelContext) -> Bool {
        for step in plan.steps where step.collectsInput {
            guard persist(step, context: context) else { return false }
        }
        return true
    }

    // MARK: - Program generation

    /// True when the generation step should do work rather than show what it already produced.
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

            generation = .ready(OnboardingProgramResult(
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

            generation = .ready(OnboardingProgramResult(
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
    /// app over the moment it is set, so this is the last thing that happens.
    @discardableResult
    func finish(context: ModelContext) -> Bool {
        guard persistAll(context: context) else { return false }
        do {
            try ProfileRepository(context: context).completeOnboarding()
            Haptics.success()
            return true
        } catch {
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
