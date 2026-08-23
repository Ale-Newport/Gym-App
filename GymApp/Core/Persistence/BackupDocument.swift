import Foundation

/// The wire format for exports and backups.
///
/// These are plain `Codable` value types rather than the SwiftData models themselves, for two
/// reasons. First, a backup must survive schema changes: a future `SchemaV2` can rename a property
/// without breaking a file a user saved months ago, because the mapping lives in one place. Second,
/// relationships are flattened into ids here, so a backup is a readable document rather than an
/// object graph a human cannot inspect.
///
/// `schemaVersion` is checked on import. Files from a *newer* version are rejected rather than
/// partially applied.
struct BackupDocument: Codable, Sendable {
    var schemaVersion: Int
    var appVersion: String
    var exportedAt: Date

    var profile: ProfileExport?
    var settings: SettingsExport?
    var equipment: EquipmentExport?
    var preferences: [PreferenceExport]
    var programs: [ProgramExport]
    var sessions: [SessionExport]
    var personalRecords: [PersonalRecordExport]
    var bodyWeights: [BodyWeightExport]
    var recoveryEntries: [RecoveryExport]
    var progressionStates: [ProgressionStateExport]
    var customFoods: [FoodExport]
    var foodLog: [FoodLogExport]
    var savedMeals: [SavedMealExport]
    var recipes: [RecipeExport]
    var nutritionTargets: [NutritionTargetExport]
    var waterLog: [WaterExport]
    var achievements: [AchievementExport]

    /// A quick description used by the import preview so the user can see what they are about to
    /// restore before anything is written.
    var summaryCounts: [(labelKey: String, count: Int)] {
        [
            ("backup.count.programs", programs.count),
            ("backup.count.sessions", sessions.count),
            ("backup.count.records", personalRecords.count),
            ("backup.count.bodyWeights", bodyWeights.count),
            ("backup.count.foods", customFoods.count),
            ("backup.count.foodLog", foodLog.count),
            ("backup.count.savedMeals", savedMeals.count),
            ("backup.count.recipes", recipes.count),
        ]
    }
}

// MARK: - Scoped exports

struct TrainingExport: Codable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var sessions: [SessionExport]
}

struct NutritionExport: Codable, Sendable {
    var schemaVersion: Int
    var exportedAt: Date
    var entries: [FoodLogExport]
    var targets: [NutritionTargetExport]
}

// MARK: - Profile

struct ProfileExport: Codable, Sendable {
    var id: UUID
    var name: String?
    var birthDate: Date?
    var biologicalSex: BiologicalSex
    var heightCm: Double
    var currentWeightKg: Double
    var targetWeightKg: Double?
    var experience: ExperienceLevel
    var trainingExperienceMonths: Int
    var techniqueConfidence: TechniqueConfidence
    var strengthSeeds: [StrengthSeed]
    var goals: [TrainingGoal]
    var priorityGroups: [MuscleGroup]
    var priorityRegions: [TrainingFocusRegion]
    var activityLevel: ActivityLevel
    var availableWeekdays: [Weekday]
    var sessionMinutesCap: Int
    var preferredTrainingTime: PreferredTrainingTime
    var cardioPreference: CardioPreference
    var mobilityLimitations: [MobilityLimitation]
    var excludedExerciseIDs: [String]
    var avoidedMovementPatterns: [MovementPattern]
    var dietType: DietType
    var allergenTags: [String]
    var intoleranceTags: [String]
    var excludedFoodTags: [String]
    var mealsPerDay: Int
    var nutritionPace: NutritionGoalPace
    var weeklyFoodBudget: Double?
    var onboardingCompletedAt: Date?
    var createdAt: Date

    init(_ model: UserProfile) {
        id = model.id
        name = model.name
        birthDate = model.birthDate
        biologicalSex = model.biologicalSex
        heightCm = model.heightCm
        currentWeightKg = model.currentWeightKg
        targetWeightKg = model.targetWeightKg
        experience = model.experience
        trainingExperienceMonths = model.trainingExperienceMonths
        techniqueConfidence = model.techniqueConfidence
        strengthSeeds = model.strengthSeeds
        goals = model.goals
        priorityGroups = model.priorityGroups
        priorityRegions = model.priorityRegions
        activityLevel = model.activityLevel
        availableWeekdays = model.availableWeekdays
        sessionMinutesCap = model.sessionMinutesCap
        preferredTrainingTime = model.preferredTrainingTime
        cardioPreference = model.cardioPreference
        mobilityLimitations = model.mobilityLimitations
        excludedExerciseIDs = model.excludedExerciseIDs
        avoidedMovementPatterns = model.avoidedMovementPatterns
        dietType = model.dietType
        allergenTags = model.allergenTags
        intoleranceTags = model.intoleranceTags
        excludedFoodTags = model.excludedFoodTags
        mealsPerDay = model.mealsPerDay
        nutritionPace = model.nutritionPace
        weeklyFoodBudget = model.weeklyFoodBudget
        onboardingCompletedAt = model.onboardingCompletedAt
        createdAt = model.createdAt
    }

    func apply(to model: UserProfile) {
        model.name = name
        model.birthDate = birthDate
        model.biologicalSex = biologicalSex
        model.heightCm = heightCm
        model.currentWeightKg = currentWeightKg
        model.targetWeightKg = targetWeightKg
        model.experience = experience
        model.trainingExperienceMonths = trainingExperienceMonths
        model.techniqueConfidence = techniqueConfidence
        model.strengthSeeds = strengthSeeds
        model.goals = goals
        model.priorityGroups = priorityGroups
        model.priorityRegions = priorityRegions
        model.activityLevel = activityLevel
        model.availableWeekdays = availableWeekdays
        model.sessionMinutesCap = sessionMinutesCap
        model.preferredTrainingTime = preferredTrainingTime
        model.cardioPreference = cardioPreference
        model.mobilityLimitations = mobilityLimitations
        model.excludedExerciseIDs = excludedExerciseIDs
        model.avoidedMovementPatterns = avoidedMovementPatterns
        model.dietType = dietType
        model.allergenTags = allergenTags
        model.intoleranceTags = intoleranceTags
        model.excludedFoodTags = excludedFoodTags
        model.mealsPerDay = mealsPerDay
        model.nutritionPace = nutritionPace
        model.weeklyFoodBudget = weeklyFoodBudget
        model.onboardingCompletedAt = onboardingCompletedAt
        model.updatedAt = Date()
    }
}

struct SettingsExport: Codable, Sendable {
    var weightUnit: WeightUnit
    var heightUnit: HeightUnit
    var distanceUnit: DistanceUnit
    var energyUnit: EnergyUnit
    var appearance: AppearancePreference
    var languageOverride: AppLanguage?
    var defaultRestSeconds: Int
    var defaultCompoundRestSeconds: Int
    var defaultIsolationRestSeconds: Int
    var progressionStrategy: ProgressionStrategy
    var autoProgressionEnabled: Bool
    var deloadSuggestionsEnabled: Bool
    var autoRegulationEnabled: Bool
    var restTimerAutoStart: Bool
    var restTimerSoundEnabled: Bool
    var restTimerHapticsEnabled: Bool
    var keepScreenAwakeDuringWorkout: Bool
    var showAnimationsDuringWorkout: Bool
    var targetRIROverride: Int?
    var notificationsEnabled: Bool
    var trainingReminderEnabled: Bool
    var trainingReminderHour: Int
    var trainingReminderMinute: Int
    var restTimerNotificationEnabled: Bool
    var weightReminderEnabled: Bool
    var weightReminderHour: Int
    var mealReminderEnabled: Bool
    var mealReminderHours: [Int]
    var healthKitEnabled: Bool
    var nutritionEnabled: Bool
    var dynamicCalorieAdjustmentEnabled: Bool
    var waterTrackingEnabled: Bool
    var dailyWaterTargetMl: Double

    init(_ model: UserSettings) {
        weightUnit = model.weightUnit
        heightUnit = model.heightUnit
        distanceUnit = model.distanceUnit
        energyUnit = model.energyUnit
        appearance = model.appearance
        languageOverride = model.languageOverride
        defaultRestSeconds = model.defaultRestSeconds
        defaultCompoundRestSeconds = model.defaultCompoundRestSeconds
        defaultIsolationRestSeconds = model.defaultIsolationRestSeconds
        progressionStrategy = model.progressionStrategy
        autoProgressionEnabled = model.autoProgressionEnabled
        deloadSuggestionsEnabled = model.deloadSuggestionsEnabled
        autoRegulationEnabled = model.autoRegulationEnabled
        restTimerAutoStart = model.restTimerAutoStart
        restTimerSoundEnabled = model.restTimerSoundEnabled
        restTimerHapticsEnabled = model.restTimerHapticsEnabled
        keepScreenAwakeDuringWorkout = model.keepScreenAwakeDuringWorkout
        showAnimationsDuringWorkout = model.showAnimationsDuringWorkout
        targetRIROverride = model.targetRIROverride
        notificationsEnabled = model.notificationsEnabled
        trainingReminderEnabled = model.trainingReminderEnabled
        trainingReminderHour = model.trainingReminderHour
        trainingReminderMinute = model.trainingReminderMinute
        restTimerNotificationEnabled = model.restTimerNotificationEnabled
        weightReminderEnabled = model.weightReminderEnabled
        weightReminderHour = model.weightReminderHour
        mealReminderEnabled = model.mealReminderEnabled
        mealReminderHours = model.mealReminderHours
        healthKitEnabled = model.healthKitEnabled
        nutritionEnabled = model.nutritionEnabled
        dynamicCalorieAdjustmentEnabled = model.dynamicCalorieAdjustmentEnabled
        waterTrackingEnabled = model.waterTrackingEnabled
        dailyWaterTargetMl = model.dailyWaterTargetMl
    }

    func apply(to model: UserSettings) {
        model.weightUnit = weightUnit
        model.heightUnit = heightUnit
        model.distanceUnit = distanceUnit
        model.energyUnit = energyUnit
        model.appearance = appearance
        model.languageOverride = languageOverride
        model.defaultRestSeconds = defaultRestSeconds
        model.defaultCompoundRestSeconds = defaultCompoundRestSeconds
        model.defaultIsolationRestSeconds = defaultIsolationRestSeconds
        model.progressionStrategy = progressionStrategy
        model.autoProgressionEnabled = autoProgressionEnabled
        model.deloadSuggestionsEnabled = deloadSuggestionsEnabled
        model.autoRegulationEnabled = autoRegulationEnabled
        model.restTimerAutoStart = restTimerAutoStart
        model.restTimerSoundEnabled = restTimerSoundEnabled
        model.restTimerHapticsEnabled = restTimerHapticsEnabled
        model.keepScreenAwakeDuringWorkout = keepScreenAwakeDuringWorkout
        model.showAnimationsDuringWorkout = showAnimationsDuringWorkout
        model.targetRIROverride = targetRIROverride
        model.notificationsEnabled = notificationsEnabled
        model.trainingReminderEnabled = trainingReminderEnabled
        model.trainingReminderHour = trainingReminderHour
        model.trainingReminderMinute = trainingReminderMinute
        model.restTimerNotificationEnabled = restTimerNotificationEnabled
        model.weightReminderEnabled = weightReminderEnabled
        model.weightReminderHour = weightReminderHour
        model.mealReminderEnabled = mealReminderEnabled
        model.mealReminderHours = mealReminderHours
        model.healthKitEnabled = healthKitEnabled
        model.nutritionEnabled = nutritionEnabled
        model.dynamicCalorieAdjustmentEnabled = dynamicCalorieAdjustmentEnabled
        model.waterTrackingEnabled = waterTrackingEnabled
        model.dailyWaterTargetMl = dailyWaterTargetMl
        model.updatedAt = Date()
    }
}

struct EquipmentExport: Codable, Sendable {
    var preset: GymSetupPreset
    var availableEquipment: [Equipment]
    var barbellBarWeightKg: Double
    var ezBarWeightKg: Double
    var availablePlatesKg: [Double]
    var availableDumbbellsKg: [Double]
    var machineIncrementKg: Double
    var cableIncrementKg: Double
    var kettlebellsKg: [Double]

    init(_ model: EquipmentProfile) {
        preset = model.preset
        availableEquipment = model.availableEquipment
        barbellBarWeightKg = model.barbellBarWeightKg
        ezBarWeightKg = model.ezBarWeightKg
        availablePlatesKg = model.availablePlatesKg
        availableDumbbellsKg = model.availableDumbbellsKg
        machineIncrementKg = model.machineIncrementKg
        cableIncrementKg = model.cableIncrementKg
        kettlebellsKg = model.kettlebellsKg
    }

    func apply(to model: EquipmentProfile) {
        model.preset = preset
        model.availableEquipment = availableEquipment
        model.barbellBarWeightKg = barbellBarWeightKg
        model.ezBarWeightKg = ezBarWeightKg
        model.availablePlatesKg = availablePlatesKg
        model.availableDumbbellsKg = availableDumbbellsKg
        model.machineIncrementKg = machineIncrementKg
        model.cableIncrementKg = cableIncrementKg
        model.kettlebellsKg = kettlebellsKg
        model.updatedAt = Date()
    }
}

struct PreferenceExport: Codable, Sendable {
    var exerciseID: String
    var isFavorite: Bool
    var feedback: ExerciseFeedback
    var isExcluded: Bool
    var customIncrementKg: Double?
    var notes: String?
    var lastPerformedAt: Date?
    var timesPerformed: Int

    init(_ model: ExercisePreference) {
        exerciseID = model.exerciseID
        isFavorite = model.isFavorite
        feedback = model.feedback
        isExcluded = model.isExcluded
        customIncrementKg = model.customIncrementKg
        notes = model.notes
        lastPerformedAt = model.lastPerformedAt
        timesPerformed = model.timesPerformed
    }
}

// MARK: - Training

struct ProgramExport: Codable, Sendable {
    var id: UUID
    var title: String
    var splitKey: String
    var daysPerWeek: Int
    var isActive: Bool
    var isManuallyCreated: Bool
    var createdAt: Date
    var goals: [TrainingGoal]
    var experience: ExperienceLevel
    var priorityGroups: [MuscleGroup]
    var currentVersion: Int
    var completedWeeks: Int
    var mesocycleLengthWeeks: Int
    var templates: [TemplateExport]
    var versions: [ProgramVersionExport]

    init(_ model: TrainingProgram) {
        id = model.id
        title = model.title
        splitKey = model.splitKey
        daysPerWeek = model.daysPerWeek
        isActive = model.isActive
        isManuallyCreated = model.isManuallyCreated
        createdAt = model.createdAt
        goals = model.goals
        experience = model.experience
        priorityGroups = model.priorityGroups
        currentVersion = model.currentVersion
        completedWeeks = model.completedWeeks
        mesocycleLengthWeeks = model.mesocycleLengthWeeks
        templates = model.orderedTemplates.map(TemplateExport.init)
        versions = model.versions
            .sorted { $0.versionNumber < $1.versionNumber }
            .map(ProgramVersionExport.init)
    }
}

struct TemplateExport: Codable, Sendable {
    var id: UUID
    var orderIndex: Int
    var customTitle: String?
    var titleKey: String
    var weekday: Weekday?
    var estimatedMinutes: Int
    var focusGroups: [MuscleGroup]
    var pushPull: PushPullClass
    var isRestDay: Bool
    var exercises: [PlannedExerciseExport]

    init(_ model: WorkoutTemplate) {
        id = model.id
        orderIndex = model.orderIndex
        customTitle = model.customTitle
        titleKey = model.titleKey
        weekday = model.weekday
        estimatedMinutes = model.estimatedMinutes
        focusGroups = model.focusGroups
        pushPull = model.pushPull
        isRestDay = model.isRestDay
        exercises = model.orderedExercises.map(PlannedExerciseExport.init)
    }
}

struct PlannedExerciseExport: Codable, Sendable {
    var id: UUID
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
    var notes: String?
    var substitutedFromExerciseID: String?

    init(_ model: PlannedExercise) {
        id = model.id
        exerciseID = model.exerciseID
        orderIndex = model.orderIndex
        targetSets = model.targetSets
        repLower = model.repLower
        repUpper = model.repUpper
        restSeconds = model.restSeconds
        targetRIR = model.targetRIR
        targetDurationSeconds = model.targetDurationSeconds
        targetDistanceMeters = model.targetDistanceMeters
        isLocked = model.isLocked
        notes = model.notes
        substitutedFromExerciseID = model.substitutedFromExerciseID
    }
}

struct ProgramVersionExport: Codable, Sendable {
    var versionNumber: Int
    var createdAt: Date
    var reasonKey: String
    var reasonArguments: [String]

    init(_ model: ProgramVersion) {
        versionNumber = model.versionNumber
        createdAt = model.createdAt
        reasonKey = model.reasonKey
        reasonArguments = model.reasonArguments
    }
}

struct SessionExport: Codable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var status: String
    var titleSnapshot: String
    var templateID: UUID?
    var programID: UUID?
    var programVersion: Int
    var focusGroups: [MuscleGroup]
    var notes: String?
    var effortFeedback: SessionEffortFeedback?
    var activeSeconds: Int
    var totalVolumeKg: Double
    var completedSetCount: Int
    var plannedSetCount: Int
    var exercises: [ExerciseSessionExport]

    init(_ model: WorkoutSession) {
        id = model.id
        startedAt = model.startedAt
        endedAt = model.endedAt
        status = model.statusRaw
        titleSnapshot = model.titleSnapshot
        templateID = model.templateID
        programID = model.programID
        programVersion = model.programVersion
        focusGroups = model.focusGroups
        notes = model.notes
        effortFeedback = model.effortFeedback
        activeSeconds = model.activeSeconds
        totalVolumeKg = model.totalVolumeKg
        completedSetCount = model.completedSetCount
        plannedSetCount = model.plannedSetCount
        exercises = model.orderedExercises.map(ExerciseSessionExport.init)
    }
}

struct ExerciseSessionExport: Codable, Sendable {
    var id: UUID
    var exerciseID: String
    var exerciseNameSnapshot: String
    var orderIndex: Int
    var notes: String?
    var wasSkipped: Bool
    var substitutedFromExerciseID: String?
    var substitutionReasonKey: String?
    var targetRIR: Int
    var restSeconds: Int
    var trackingMode: TrackingMode
    var sets: [SetExport]

    init(_ model: ExerciseSession) {
        id = model.id
        exerciseID = model.exerciseID
        exerciseNameSnapshot = model.exerciseNameSnapshot
        orderIndex = model.orderIndex
        notes = model.notes
        wasSkipped = model.wasSkipped
        substitutedFromExerciseID = model.substitutedFromExerciseID
        substitutionReasonKey = model.substitutionReasonKey
        targetRIR = model.targetRIR
        restSeconds = model.restSeconds
        trackingMode = model.trackingMode
        sets = model.orderedSets.map(SetExport.init)
    }
}

struct SetExport: Codable, Sendable {
    var setIndex: Int
    var kind: SetKind
    var targetWeightKg: Double?
    var targetReps: Int?
    var targetDurationSeconds: Int?
    var weightKg: Double?
    var reps: Int?
    var durationSeconds: Int?
    var distanceMeters: Double?
    var rir: Int?
    var rpe: Double?
    var isCompleted: Bool
    var completedAt: Date?
    var notes: String?

    init(_ model: SetRecord) {
        setIndex = model.setIndex
        kind = model.kind
        targetWeightKg = model.targetWeightKg
        targetReps = model.targetReps
        targetDurationSeconds = model.targetDurationSeconds
        weightKg = model.weightKg
        reps = model.reps
        durationSeconds = model.durationSeconds
        distanceMeters = model.distanceMeters
        rir = model.rir
        rpe = model.rpe
        isCompleted = model.isCompleted
        completedAt = model.completedAt
        notes = model.notes
    }
}

struct PersonalRecordExport: Codable, Sendable {
    var exerciseID: String
    var exerciseNameSnapshot: String
    var kind: PersonalRecordKind
    var value: Double
    var repsContext: Int?
    var achievedAt: Date
    var previousValue: Double?

    init(_ model: PersonalRecord) {
        exerciseID = model.exerciseID
        exerciseNameSnapshot = model.exerciseNameSnapshot
        kind = model.kind
        value = model.value
        repsContext = model.repsContext
        achievedAt = model.achievedAt
        previousValue = model.previousValue
    }
}

struct BodyWeightExport: Codable, Sendable {
    var date: Date
    var weightKg: Double
    var isFromHealthKit: Bool
    var note: String?

    init(_ model: BodyWeightEntry) {
        date = model.date
        weightKg = model.weightKg
        isFromHealthKit = model.isFromHealthKit
        note = model.note
    }
}

struct RecoveryExport: Codable, Sendable {
    var date: Date
    var energy: Int?
    var sleepQuality: Int?
    var sleepHours: Double?
    var soreness: Int?
    var motivation: Int?
    var stress: Int?
    var note: String?
    var soreGroups: [MuscleGroup]

    init(_ model: RecoveryEntry) {
        date = model.date
        energy = model.energy
        sleepQuality = model.sleepQuality
        sleepHours = model.sleepHours
        soreness = model.soreness
        motivation = model.motivation
        stress = model.stress
        note = model.note
        soreGroups = model.soreGroups
    }
}

struct ProgressionStateExport: Codable, Sendable {
    var exerciseID: String
    var workingWeightKg: Double?
    var repLower: Int
    var repUpper: Int
    var consecutiveSuccesses: Int
    var consecutiveStalls: Int
    var consecutiveRegressions: Int
    var needsCalibration: Bool
    var lastPerformedAt: Date?
    var bestEstimatedOneRepMaxKg: Double?
    var strategy: ProgressionStrategy

    init(_ model: ProgressionState) {
        exerciseID = model.exerciseID
        workingWeightKg = model.workingWeightKg
        repLower = model.repLower
        repUpper = model.repUpper
        consecutiveSuccesses = model.consecutiveSuccesses
        consecutiveStalls = model.consecutiveStalls
        consecutiveRegressions = model.consecutiveRegressions
        needsCalibration = model.needsCalibration
        lastPerformedAt = model.lastPerformedAt
        bestEstimatedOneRepMaxKg = model.bestEstimatedOneRepMaxKg
        strategy = model.strategy
    }
}

// MARK: - Nutrition

struct FoodExport: Codable, Sendable {
    var id: UUID
    var catalogID: String?
    var name: String
    var brand: String?
    var barcode: String?
    var source: String
    var kilocaloriesPer100: Double
    var proteinGPer100: Double
    var carbsGPer100: Double
    var fatGPer100: Double
    var micronutrientsPer100: Micronutrients
    var basisUnit: ServingUnit
    var servings: [FoodServing]
    var gramsPerPiece: Double?
    var dietaryTags: [String]
    var allergenTags: [String]
    var roleTags: [String]
    var isFavorite: Bool
    var createdAt: Date

    init(_ model: FoodItem) {
        id = model.id
        catalogID = model.catalogID
        name = model.name
        brand = model.brand
        barcode = model.barcode
        source = model.sourceRaw
        kilocaloriesPer100 = model.kilocaloriesPer100
        proteinGPer100 = model.proteinGPer100
        carbsGPer100 = model.carbsGPer100
        fatGPer100 = model.fatGPer100
        micronutrientsPer100 = model.micronutrientsPer100
        basisUnit = model.basisUnit
        servings = model.servings
        gramsPerPiece = model.gramsPerPiece
        dietaryTags = model.dietaryTags
        allergenTags = model.allergenTags
        roleTags = model.roleTags
        isFavorite = model.isFavorite
        createdAt = model.createdAt
    }
}

struct FoodLogExport: Codable, Sendable {
    var id: UUID
    var dayKey: String
    var loggedAt: Date
    var mealSlot: MealSlot
    var orderIndex: Int
    var foodID: UUID?
    var foodNameSnapshot: String
    var brandSnapshot: String?
    var quantity: Double
    var unit: ServingUnit
    var servingIndex: Int?
    var macrosSnapshot: MacroNutrients
    var micronutrientsSnapshot: Micronutrients

    init(_ model: FoodLogEntry) {
        id = model.id
        dayKey = model.dayKey
        loggedAt = model.loggedAt
        mealSlot = model.mealSlot
        orderIndex = model.orderIndex
        foodID = model.foodID
        foodNameSnapshot = model.foodNameSnapshot
        brandSnapshot = model.brandSnapshot
        quantity = model.quantity
        unit = model.unit
        servingIndex = model.servingIndex
        macrosSnapshot = model.macrosSnapshot
        micronutrientsSnapshot = model.micronutrientsSnapshot
    }
}

struct SavedMealExport: Codable, Sendable {
    var id: UUID
    var name: String
    var defaultSlot: MealSlot
    var createdAt: Date
    var timesUsed: Int
    var isFavorite: Bool
    var items: [SavedMealItemExport]

    init(_ model: SavedMeal) {
        id = model.id
        name = model.name
        defaultSlot = model.defaultSlot
        createdAt = model.createdAt
        timesUsed = model.timesUsed
        isFavorite = model.isFavorite
        items = model.items
            .sorted { $0.orderIndex < $1.orderIndex }
            .map(SavedMealItemExport.init)
    }
}

struct SavedMealItemExport: Codable, Sendable {
    var foodID: UUID?
    var foodNameSnapshot: String
    var quantity: Double
    var unit: ServingUnit
    var servingIndex: Int?
    var orderIndex: Int

    init(_ model: SavedMealItem) {
        foodID = model.foodID
        foodNameSnapshot = model.foodNameSnapshot
        quantity = model.quantity
        unit = model.unit
        servingIndex = model.servingIndex
        orderIndex = model.orderIndex
    }
}

struct RecipeExport: Codable, Sendable {
    var id: UUID
    var name: String
    var servingsCount: Double
    var instructions: String?
    var preparationMinutes: Int?
    var createdAt: Date
    var isFavorite: Bool
    var tags: [String]
    var ingredients: [RecipeIngredientExport]

    init(_ model: Recipe) {
        id = model.id
        name = model.name
        servingsCount = model.servingsCount
        instructions = model.instructions
        preparationMinutes = model.preparationMinutes
        createdAt = model.createdAt
        isFavorite = model.isFavorite
        tags = model.tags
        ingredients = model.ingredients
            .sorted { $0.orderIndex < $1.orderIndex }
            .map(RecipeIngredientExport.init)
    }
}

struct RecipeIngredientExport: Codable, Sendable {
    var foodID: UUID?
    var foodNameSnapshot: String
    var quantity: Double
    var unit: ServingUnit
    var servingIndex: Int?
    var orderIndex: Int

    init(_ model: RecipeIngredient) {
        foodID = model.foodID
        foodNameSnapshot = model.foodNameSnapshot
        quantity = model.quantity
        unit = model.unit
        servingIndex = model.servingIndex
        orderIndex = model.orderIndex
    }
}

struct NutritionTargetExport: Codable, Sendable {
    var effectiveFrom: Date
    var kilocalories: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var isManualOverride: Bool
    var rationaleKey: String?
    var rationaleArguments: [String]
    var isActive: Bool
    var micronutrientGoals: Micronutrients

    init(_ model: DailyNutritionTarget) {
        effectiveFrom = model.effectiveFrom
        kilocalories = model.kilocalories
        proteinG = model.proteinG
        carbsG = model.carbsG
        fatG = model.fatG
        isManualOverride = model.isManualOverride
        rationaleKey = model.rationaleKey
        rationaleArguments = model.rationaleArguments
        isActive = model.isActive
        micronutrientGoals = model.micronutrientGoals
    }
}

struct WaterExport: Codable, Sendable {
    var dayKey: String
    var loggedAt: Date
    var milliliters: Double

    init(_ model: WaterLogEntry) {
        dayKey = model.dayKey
        loggedAt = model.loggedAt
        milliliters = model.milliliters
    }
}

struct AchievementExport: Codable, Sendable {
    var code: String
    var unlockedAt: Date
    var value: Double?
    var exerciseID: String?

    init(_ model: Achievement) {
        code = model.code
        unlockedAt = model.unlockedAt
        value = model.value
        exerciseID = model.exerciseID
    }
}
