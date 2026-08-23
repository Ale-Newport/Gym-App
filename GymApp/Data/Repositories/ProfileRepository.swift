import Foundation
import SwiftData

/// Reads and writes the three singleton rows that describe the user: `UserProfile`, `UserSettings`
/// and `EquipmentProfile`, and turns them into the value-type snapshots the engines consume.
///
/// The singletons are created lazily on first access rather than seeded at launch. A first launch
/// that crashes before onboarding would otherwise leave a half-written profile behind, and a store
/// migration would have to guarantee the seed ran exactly once. "Fetch the row, create it if the
/// table is empty" has neither problem and is idempotent by construction.
///
/// Deliberate duplicate defence: if a store somehow ends up with two rows of a singleton (an
/// interrupted iCloud merge, a restored backup) exactly one is kept and the rest are removed, so the
/// app never silently starts writing to a second, invisible profile. The profile keeps the *oldest*
/// row, because its creation date is the user's join date; settings and equipment have no creation
/// date, so they keep the most recently updated row instead. Either way the choice is made by an
/// explicit sort, so it is the same on every launch.
@MainActor
struct ProfileRepository: Repository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Singletons

    /// The user profile, created on first access.
    func profile() throws -> UserProfile {
        var descriptor = FetchDescriptor<UserProfile>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        descriptor.fetchLimit = 8
        let rows = try fetch(descriptor)
        if let first = rows.first {
            try pruneDuplicates(rows)
            return first
        }
        let created = UserProfile()
        context.insert(created)
        try persist()
        return created
    }

    /// The settings row, created on first access.
    ///
    /// `UserSettings` carries no creation date, so duplicates are resolved by `updatedAt` instead:
    /// the row the user touched most recently is the one holding their current intent. Sorting also
    /// makes the choice deterministic — an unordered fetch would keep an arbitrary row, and which
    /// one it kept could change between launches.
    func settings() throws -> UserSettings {
        var descriptor = FetchDescriptor<UserSettings>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 8
        let rows = try fetch(descriptor)
        if let first = rows.first {
            try pruneDuplicates(rows)
            return first
        }
        let created = UserSettings()
        context.insert(created)
        try persist()
        return created
    }

    /// The equipment row, created on first access and seeded from its own default preset.
    ///
    /// `EquipmentProfile.availableEquipment` defaults to an empty array, which would mean "this user
    /// owns nothing" to every engine. Seeding from `preset.equipment` on creation makes the default
    /// state mean what the default preset says it means.
    /// Duplicates are resolved by `updatedAt`, for the same reason as `settings()`.
    func equipmentProfile() throws -> EquipmentProfile {
        var descriptor = FetchDescriptor<EquipmentProfile>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 8
        let rows = try fetch(descriptor)
        if let first = rows.first {
            try pruneDuplicates(rows)
            return first
        }
        let created = EquipmentProfile()
        created.availableEquipment = Array(created.preset.equipment).sorted { $0.rawValue < $1.rawValue }
        context.insert(created)
        try persist()
        return created
    }

    /// Keeps the first row and deletes any extras. Silent by design at the model layer, but logged.
    private func pruneDuplicates<T: PersistentModel>(_ rows: [T]) throws {
        guard rows.count > 1 else { return }
        AppLog.persistence.error("Found \(rows.count) singleton rows of \(String(describing: T.self), privacy: .public); keeping the first")
        for extra in rows.dropFirst() { context.delete(extra) }
        try persist()
    }

    // MARK: - Snapshots

    /// Builds the snapshot every training engine takes as its view of the user.
    ///
    /// `now` is injected rather than read from the clock inside the mapping so that the same store
    /// state always produces the same snapshot — age is the one field that would otherwise drift.
    func trainingProfileSnapshot(now: Date = Date(), calendar: Calendar = .current) throws -> TrainingProfileSnapshot {
        let profile = try profile()
        let equipment = try equipmentProfile()
        return trainingProfileSnapshot(profile: profile, equipment: equipment, now: now, calendar: calendar)
    }

    /// Pure mapping, exposed separately so it can be exercised without a store.
    func trainingProfileSnapshot(
        profile: UserProfile,
        equipment: EquipmentProfile,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TrainingProfileSnapshot {
        var snapshot = TrainingProfileSnapshot()
        snapshot.experience = profile.experience
        snapshot.techniqueConfidence = profile.techniqueConfidence
        // An empty goal list is possible before onboarding finishes; the engines need at least one,
        // and `generalFitness` is the least opinionated default.
        snapshot.goals = profile.goals.isEmpty ? [.generalFitness] : profile.goals
        // Groups and regions are merged by the model itself, so the engine only ever sees groups.
        snapshot.priorityGroups = profile.resolvedPriorityGroups
        snapshot.ageYears = Self.age(from: profile.birthDate, now: now, calendar: calendar)
        snapshot.biologicalSex = profile.biologicalSex
        snapshot.bodyWeightKg = profile.currentWeightKg
        // Availability drives split selection; falling back to the snapshot's own default rather
        // than to "zero days" keeps a pre-onboarding preview sensible.
        snapshot.availableWeekdays = profile.availableWeekdays.isEmpty
            ? TrainingProfileSnapshot().availableWeekdays
            : profile.availableWeekdays.sorted()
        snapshot.sessionMinutesCap = InputValidation.clampedSessionMinutes(profile.sessionMinutesCap)
        snapshot.cardioPreference = profile.cardioPreference
        snapshot.availableEquipment = Self.effectiveEquipment(from: equipment)
        snapshot.excludedExerciseIDs = Set(profile.excludedExerciseIDs)
        snapshot.mobilityLimitations = profile.mobilityLimitations
        snapshot.avoidedPatterns = Set(profile.avoidedMovementPatterns)
        snapshot.trainingExperienceMonths = max(0, profile.trainingExperienceMonths)
        return snapshot
    }

    /// What the user can actually train with right now.
    ///
    /// `EquipmentProfile.effectiveEquipment` already subtracts anything flagged as temporarily
    /// broken. The extra rule here is that the result is never empty: bodyweight is always available
    /// to a human being, and an empty set would make the exercise selector return nothing at all,
    /// which reads as a broken app rather than as an empty gym.
    static func effectiveEquipment(from equipment: EquipmentProfile) -> Set<Equipment> {
        let effective = equipment.effectiveEquipment
        if !effective.isEmpty { return effective }
        let fromPreset = equipment.preset.equipment.subtracting(equipment.temporarilyUnavailable)
        return fromPreset.isEmpty ? Equipment.homeMinimum : fromPreset
    }

    /// The equipment increments the load-rounding rules need, as a value type.
    func increments() throws -> EquipmentIncrements {
        try equipmentProfile().increments
    }

    /// Builds the snapshot the nutrition engines take as their view of the user.
    ///
    /// `trainingDaysPerWeek` comes from the user's stated availability rather than from what they
    /// actually did, because the energy target has to be set in advance of the week it covers.
    func nutritionProfileSnapshot(now: Date = Date(), calendar: Calendar = .current) throws -> NutritionProfileSnapshot {
        let profile = try profile()
        var snapshot = NutritionProfileSnapshot()
        snapshot.biologicalSex = profile.biologicalSex
        snapshot.ageYears = Self.age(from: profile.birthDate, now: now, calendar: calendar)
        snapshot.heightCm = profile.heightCm
        snapshot.weightKg = profile.currentWeightKg
        snapshot.targetWeightKg = profile.targetWeightKg
        snapshot.activityLevel = profile.activityLevel
        snapshot.goals = .init(profile.goals.isEmpty ? [.generalFitness] : profile.goals)
        snapshot.pace = profile.nutritionPace
        snapshot.dietType = profile.dietType
        // Tag lists are normalised on the way in, but a store written by an earlier build may hold
        // unnormalised values, so they are normalised again on the way out.
        snapshot.allergenTags = .init(InputValidation.normalisedTags(profile.allergenTags))
        snapshot.intoleranceTags = .init(InputValidation.normalisedTags(profile.intoleranceTags))
        snapshot.excludedFoodTags = .init(InputValidation.normalisedTags(profile.excludedFoodTags))
        snapshot.mealsPerDay = InputValidation.clampedMealsPerDay(profile.mealsPerDay)
        snapshot.trainingDaysPerWeek = InputValidation.clampedDaysPerWeek(
            profile.availableWeekdays.isEmpty ? 3 : profile.availableWeekdays.count
        )
        snapshot.weeklyFoodBudget = profile.weeklyFoodBudget
        return snapshot
    }

    /// Whole years between `birthDate` and `now`. `nil` when the user declined to give a birth date.
    static func age(from birthDate: Date?, now: Date, calendar: Calendar = .current) -> Int? {
        guard let birthDate, birthDate <= now else { return nil }
        return calendar.dateComponents([.year], from: birthDate, to: now).year
    }

    // MARK: - Profile updates

    /// Name, birth date and biological sex. Every argument is optional-in-the-Swift-sense *and*
    /// meaningful-as-nil, so each is wrapped in a double optional: `nil` means "leave alone",
    /// `.some(nil)` means "clear it".
    func updateIdentity(
        name: String?? = nil,
        birthDate: Date?? = nil,
        biologicalSex: BiologicalSex? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        let profile = try profile()
        if let name {
            // A name that trims to nothing is a clear, and a name that is too long is a mistake the
            // user should see rather than have silently truncated.
            if let raw = name, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                profile.name = try InputValidation.name(raw, field: "name")
            } else {
                profile.name = nil
            }
        }
        if let birthDate {
            if let date = birthDate {
                profile.birthDate = try InputValidation.birthDate(date, now: now, calendar: calendar)
            } else {
                profile.birthDate = nil
            }
        }
        if let biologicalSex { profile.biologicalSex = biologicalSex }
        profile.updatedAt = now
        try persist()
    }

    /// Height and body mass. Out-of-range values are refused rather than clamped: these two numbers
    /// feed every energy calculation in the app, so a silent clamp would produce a target that is
    /// quietly wrong for as long as the user leaves it.
    func updateBodyMetrics(
        heightCm: Double? = nil,
        currentWeightKg: Double? = nil,
        targetWeightKg: Double?? = nil,
        now: Date = Date()
    ) throws {
        let profile = try profile()
        if let heightCm { profile.heightCm = try InputValidation.height(cm: heightCm) }
        if let currentWeightKg {
            profile.currentWeightKg = try InputValidation.bodyMass(kg: currentWeightKg, field: "currentWeightKg")
        }
        if let targetWeightKg {
            if let target = targetWeightKg {
                profile.targetWeightKg = try InputValidation.bodyMass(kg: target, field: "targetWeightKg")
            } else {
                profile.targetWeightKg = nil
            }
        }
        profile.updatedAt = now
        try persist()
    }

    /// Experience, technique confidence and the self-reported months of training.
    func updateExperience(
        level: ExperienceLevel? = nil,
        months: Int? = nil,
        techniqueConfidence: TechniqueConfidence? = nil,
        now: Date = Date()
    ) throws {
        let profile = try profile()
        if let level { profile.experience = level }
        // A negative month count is meaningless but harmless, so it is clamped. The ceiling of 900
        // months (75 years) exists only to stop a mis-keyed value dominating any future heuristic.
        if let months { profile.trainingExperienceMonths = min(max(0, months), 900) }
        if let techniqueConfidence { profile.techniqueConfidence = techniqueConfidence }
        profile.updatedAt = now
        try persist()
    }

    /// Goals, priority groups and regions, and the self-reported daily activity level.
    func updateGoals(
        goals: [TrainingGoal]? = nil,
        priorityGroups: [MuscleGroup]? = nil,
        priorityRegions: [TrainingFocusRegion]? = nil,
        activityLevel: ActivityLevel? = nil,
        now: Date = Date()
    ) throws {
        let profile = try profile()
        if let goals { profile.goals = Self.deduplicated(goals) }
        if let priorityGroups { profile.priorityGroups = Self.deduplicated(priorityGroups) }
        if let priorityRegions { profile.priorityRegions = Self.deduplicated(priorityRegions) }
        if let activityLevel { profile.activityLevel = activityLevel }
        profile.updatedAt = now
        try persist()
    }

    /// Which days the user can train, how long a session may run, and when they prefer to train.
    func updateAvailability(
        weekdays: [Weekday]? = nil,
        sessionMinutesCap: Int? = nil,
        preferredTrainingTime: PreferredTrainingTime? = nil,
        cardioPreference: CardioPreference? = nil,
        now: Date = Date()
    ) throws {
        let profile = try profile()
        if let weekdays { profile.availableWeekdays = Self.deduplicated(weekdays).sorted() }
        if let sessionMinutesCap {
            profile.sessionMinutesCap = InputValidation.clampedSessionMinutes(sessionMinutesCap)
        }
        if let preferredTrainingTime { profile.preferredTrainingTime = preferredTrainingTime }
        if let cardioPreference { profile.cardioPreference = cardioPreference }
        profile.updatedAt = now
        try persist()
    }

    /// Mobility limitations and movement patterns to avoid.
    ///
    /// These are treated as scheduling constraints only. The app records what the user says they
    /// would rather not do; it does not interpret it, and it never records anything clinical.
    func updateRestrictions(
        mobilityLimitations: [MobilityLimitation]? = nil,
        avoidedPatterns: [MovementPattern]? = nil,
        now: Date = Date()
    ) throws {
        let profile = try profile()
        if let mobilityLimitations { profile.mobilityLimitations = Self.deduplicated(mobilityLimitations) }
        if let avoidedPatterns { profile.avoidedMovementPatterns = Self.deduplicated(avoidedPatterns) }
        profile.updatedAt = now
        try persist()
    }

    /// Diet, allergens and the food-budget preferences the meal recommender respects.
    func updateNutritionPreferences(
        dietType: DietType? = nil,
        allergenTags: [String]? = nil,
        intoleranceTags: [String]? = nil,
        excludedFoodTags: [String]? = nil,
        mealsPerDay: Int? = nil,
        pace: NutritionGoalPace? = nil,
        weeklyFoodBudget: Double?? = nil,
        now: Date = Date()
    ) throws {
        let profile = try profile()
        if let dietType { profile.dietType = dietType }
        if let allergenTags { profile.allergenTags = InputValidation.normalisedTags(allergenTags) }
        if let intoleranceTags { profile.intoleranceTags = InputValidation.normalisedTags(intoleranceTags) }
        if let excludedFoodTags { profile.excludedFoodTags = InputValidation.normalisedTags(excludedFoodTags) }
        if let mealsPerDay { profile.mealsPerDay = InputValidation.clampedMealsPerDay(mealsPerDay) }
        if let pace { profile.nutritionPace = pace }
        if let weeklyFoodBudget {
            if let budget = weeklyFoodBudget {
                try InputValidation.requireFinite(budget, field: "weeklyFoodBudget")
                profile.weeklyFoodBudget = max(0, budget)
            } else {
                profile.weeklyFoodBudget = nil
            }
        }
        profile.updatedAt = now
        try persist()
    }

    /// Exercises the user never wants programmed. Stored on the profile rather than as a preference
    /// row because it is a statement about the plan, not an opinion about the movement.
    func setExcludedExerciseIDs(_ ids: [String], now: Date = Date()) throws {
        let profile = try profile()
        profile.excludedExerciseIDs = Self.deduplicated(ids)
        profile.updatedAt = now
        try persist()
    }

    func addExcludedExerciseID(_ id: String, now: Date = Date()) throws {
        let profile = try profile()
        guard !profile.excludedExerciseIDs.contains(id) else { return }
        profile.excludedExerciseIDs.append(id)
        profile.updatedAt = now
        try persist()
    }

    func removeExcludedExerciseID(_ id: String, now: Date = Date()) throws {
        let profile = try profile()
        guard profile.excludedExerciseIDs.contains(id) else { return }
        profile.excludedExerciseIDs.removeAll { $0 == id }
        profile.updatedAt = now
        try persist()
    }

    /// Records a self-reported strength marker, replacing any existing one for the same exercise.
    func upsertStrengthSeed(exerciseID: String, weightKg: Double, reps: Int, now: Date = Date()) throws {
        let profile = try profile()
        let load = try InputValidation.load(kg: weightKg)
        let seed = StrengthSeed(
            exerciseID: exerciseID,
            weightKg: load,
            reps: InputValidation.clampedReps(reps)
        )
        profile.strengthSeeds.removeAll { $0.exerciseID == exerciseID }
        profile.strengthSeeds.append(seed)
        profile.updatedAt = now
        try persist()
    }

    func removeStrengthSeed(exerciseID: String, now: Date = Date()) throws {
        let profile = try profile()
        guard profile.strengthSeeds.contains(where: { $0.exerciseID == exerciseID }) else { return }
        profile.strengthSeeds.removeAll { $0.exerciseID == exerciseID }
        profile.updatedAt = now
        try persist()
    }

    /// Marks onboarding finished. Idempotent: re-running it does not move the completion date, so
    /// "member since" stays honest.
    func completeOnboarding(at date: Date = Date()) throws {
        let profile = try profile()
        guard profile.onboardingCompletedAt == nil else { return }
        profile.onboardingCompletedAt = date
        profile.updatedAt = date
        try persist()
    }

    /// Sends the user back through onboarding without discarding anything they have logged.
    func reopenOnboarding(now: Date = Date()) throws {
        let profile = try profile()
        profile.onboardingCompletedAt = nil
        profile.updatedAt = now
        try persist()
    }

    // MARK: - Equipment updates

    /// Applies a preset, or a bespoke equipment list.
    ///
    /// Choosing a preset overwrites the list; choosing individual items switches the preset to
    /// `.custom` so the UI does not claim the user is on a preset they have since edited.
    func updateEquipment(
        preset: GymSetupPreset? = nil,
        availableEquipment: Set<Equipment>? = nil,
        now: Date = Date()
    ) throws {
        let equipment = try equipmentProfile()
        if let preset {
            equipment.preset = preset
            if preset != .custom {
                equipment.availableEquipment = Self.sorted(preset.equipment)
            }
        }
        if let availableEquipment {
            equipment.availableEquipment = Self.sorted(availableEquipment)
            if preset == nil { equipment.preset = .custom }
        }
        // Anything no longer owned cannot still be "temporarily unavailable".
        let owned = Set(equipment.availableEquipment)
        equipment.temporarilyUnavailable = equipment.temporarilyUnavailable.filter { owned.contains($0) }
        equipment.updatedAt = now
        try persist()
    }

    /// Flags a piece of equipment as out of service, or puts it back.
    func setTemporarilyUnavailable(_ item: Equipment, unavailable: Bool, now: Date = Date()) throws {
        let equipment = try equipmentProfile()
        var current = Set(equipment.temporarilyUnavailable)
        if unavailable { current.insert(item) } else { current.remove(item) }
        equipment.temporarilyUnavailable = Self.sorted(current)
        equipment.updatedAt = now
        try persist()
    }

    func clearTemporarilyUnavailable(now: Date = Date()) throws {
        let equipment = try equipmentProfile()
        guard !equipment.temporarilyUnavailable.isEmpty else { return }
        equipment.temporarilyUnavailable = []
        equipment.updatedAt = now
        try persist()
    }

    /// The exact increments the user's gym stocks. Empty ladders are rejected, because
    /// `LoadRounding` would then have nothing to round onto and would fall back to a generic step.
    func updateIncrements(
        barbellBarWeightKg: Double? = nil,
        ezBarWeightKg: Double? = nil,
        availablePlatesKg: [Double]? = nil,
        availableDumbbellsKg: [Double]? = nil,
        kettlebellsKg: [Double]? = nil,
        machineIncrementKg: Double? = nil,
        cableIncrementKg: Double? = nil,
        now: Date = Date()
    ) throws {
        let equipment = try equipmentProfile()
        if let barbellBarWeightKg {
            equipment.barbellBarWeightKg = try InputValidation.load(kg: barbellBarWeightKg, field: "barbellBarWeightKg")
        }
        if let ezBarWeightKg {
            equipment.ezBarWeightKg = try InputValidation.load(kg: ezBarWeightKg, field: "ezBarWeightKg")
        }
        if let availablePlatesKg {
            equipment.availablePlatesKg = try Self.validatedLadder(availablePlatesKg, field: "availablePlatesKg")
        }
        if let availableDumbbellsKg {
            equipment.availableDumbbellsKg = try Self.validatedLadder(availableDumbbellsKg, field: "availableDumbbellsKg")
        }
        if let kettlebellsKg {
            equipment.kettlebellsKg = try Self.validatedLadder(kettlebellsKg, field: "kettlebellsKg")
        }
        if let machineIncrementKg {
            equipment.machineIncrementKg = try InputValidation.increment(
                kg: machineIncrementKg, field: "machineIncrementKg"
            )
        }
        if let cableIncrementKg {
            equipment.cableIncrementKg = try InputValidation.increment(
                kg: cableIncrementKg, field: "cableIncrementKg"
            )
        }
        equipment.updatedAt = now
        try persist()
    }

    // MARK: - Settings

    /// Applies a change to the settings row. Taking a closure keeps this repository from having to
    /// mirror three dozen toggles as three dozen parameters, and there is nothing to validate: every
    /// settings field is an enum or a boolean the UI already constrains.
    func updateSettings(now: Date = Date(), _ mutate: (UserSettings) -> Void) throws {
        let settings = try settings()
        mutate(settings)
        settings.defaultRestSeconds = InputValidation.clampedRestSeconds(settings.defaultRestSeconds)
        settings.defaultCompoundRestSeconds = InputValidation.clampedRestSeconds(settings.defaultCompoundRestSeconds)
        settings.defaultIsolationRestSeconds = InputValidation.clampedRestSeconds(settings.defaultIsolationRestSeconds)
        settings.targetRIROverride = settings.targetRIROverride.map(InputValidation.clampedRIR)
        settings.trainingReminderHour = min(max(0, settings.trainingReminderHour), 23)
        settings.trainingReminderMinute = min(max(0, settings.trainingReminderMinute), 59)
        settings.weightReminderHour = min(max(0, settings.weightReminderHour), 23)
        settings.mealReminderHours = settings.mealReminderHours.map { min(max(0, $0), 23) }.sorted()
        settings.dailyWaterTargetMl = min(max(0, settings.dailyWaterTargetMl), 10000)
        settings.updatedAt = now
        try persist()
    }

    /// The reps-in-reserve the app should aim for: the user's override if they set one, otherwise
    /// the conservative default for their experience level.
    func effectiveTargetRIR() throws -> Int {
        let settings = try settings()
        if let override = settings.targetRIROverride { return InputValidation.clampedRIR(override) }
        return try profile().experience.defaultRIR
    }

    // MARK: - Reset

    /// Deletes everything the user has ever entered and returns the app to a first-launch state.
    ///
    /// Ordered from the most dependent model to the least so cascade rules never have to fire twice,
    /// and committed as a single save: a reset that half-succeeded would be worse than one that
    /// failed outright.
    func resetAllData() throws {
        try deleteAll(SetRecord.self)
        try deleteAll(ExerciseSession.self)
        try deleteAll(WorkoutSession.self)
        try deleteAll(PlannedExercise.self)
        try deleteAll(WorkoutTemplate.self)
        try deleteAll(ProgramVersion.self)
        try deleteAll(TrainingProgram.self)
        try deleteAll(ProgressionState.self)
        try deleteAll(DeloadRecommendation.self)
        try deleteAll(ExercisePreference.self)
        try deleteAll(PersonalRecord.self)
        try deleteAll(BodyWeightEntry.self)
        try deleteAll(RecoveryEntry.self)
        try deleteAll(Achievement.self)
        try deleteAll(FoodLogEntry.self)
        try deleteAll(WaterLogEntry.self)
        try deleteAll(SavedMealItem.self)
        try deleteAll(SavedMeal.self)
        try deleteAll(RecipeIngredient.self)
        try deleteAll(Recipe.self)
        try deleteAll(NutritionTargetHistory.self)
        try deleteAll(DailyNutritionTarget.self)
        try deleteAll(FoodItem.self)
        try deleteAll(EquipmentProfile.self)
        try deleteAll(UserSettings.self)
        try deleteAll(UserProfile.self)
        try persist()
        AppLog.persistence.notice("All user data reset")
    }

    // MARK: - Helpers

    private static func deduplicated<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Equipment is stored as an array, so it is written in a stable order; otherwise every read of
    /// a `Set` would reorder the row and make diffs and previews noisy.
    private static func sorted(_ equipment: Set<Equipment>) -> [Equipment] {
        equipment.sorted { $0.rawValue < $1.rawValue }
    }

    /// A ladder of selectable loads: positive, de-duplicated, ascending, and never empty.
    private static func validatedLadder(_ values: [Double], field: String) throws -> [Double] {
        var seen = Set<Double>()
        var cleaned: [Double] = []
        for value in values where value.isFinite && value > 0 && value <= InputValidation.loadKg.upperBound {
            if seen.insert(value).inserted { cleaned.append(value) }
        }
        guard !cleaned.isEmpty else {
            throw RepositoryError.invalidInput(ValidationIssue(field: field, key: "validation.equipment.ladderEmpty"))
        }
        return cleaned.sorted()
    }
}
