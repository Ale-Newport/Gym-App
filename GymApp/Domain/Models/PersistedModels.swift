import Foundation
import SwiftData

// MARK: - Profile

/// The single row describing who the user is. Everything the engines need about the person lives
/// here; nothing derived is stored, so changing a field immediately changes every recommendation.
@Model
final class UserProfile {
    #Index<UserProfile>([\.createdAt])

    var id: UUID = UUID()
    var name: String?
    var birthDate: Date?
    var biologicalSex: BiologicalSex = BiologicalSex.unspecified
    /// Canonical unit: centimetres. All UI conversion happens at the edge.
    var heightCm: Double = 175
    /// Canonical unit: kilograms.
    var currentWeightKg: Double = 75
    var targetWeightKg: Double?

    var experience: ExperienceLevel = ExperienceLevel.beginner
    /// How long the user has trained, in months. Complements `experience`.
    var trainingExperienceMonths: Int = 0
    var techniqueConfidence: TechniqueConfidence = TechniqueConfidence.learning
    /// Self-reported strength markers, keyed by exercise id. Optional and only used to seed
    /// first-session load estimates.
    var strengthSeeds: [StrengthSeed] = []

    var goals: [TrainingGoal] = []
    var priorityGroups: [MuscleGroup] = []
    var priorityRegions: [TrainingFocusRegion] = []
    var activityLevel: ActivityLevel = ActivityLevel.moderate

    // Availability
    var availableWeekdays: [Weekday] = []
    var sessionMinutesCap: Int = 60
    var preferredTrainingTime: PreferredTrainingTime = PreferredTrainingTime.evening
    var cardioPreference: CardioPreference = CardioPreference.either

    // Restrictions
    var mobilityLimitations: [MobilityLimitation] = []
    /// Exercise ids the user never wants programmed.
    var excludedExerciseIDs: [String] = []
    var avoidedMovementPatterns: [MovementPattern] = []

    // Nutrition preferences
    var dietType: DietType = DietType.omnivore
    var allergenTags: [String] = []
    var intoleranceTags: [String] = []
    var excludedFoodTags: [String] = []
    var mealsPerDay: Int = 4
    var nutritionPace: NutritionGoalPace = NutritionGoalPace.moderate
    /// Optional weekly food budget the meal recommender respects, in the user's currency.
    var weeklyFoodBudget: Double?

    var onboardingCompletedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}

    var isOnboarded: Bool { onboardingCompletedAt != nil }

    var ageYears: Int? {
        guard let birthDate else { return nil }
        return Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
    }

    /// The full set of muscle groups the user has asked to emphasise, groups and regions merged.
    var resolvedPriorityGroups: [MuscleGroup] {
        var seen = Set<MuscleGroup>()
        var result: [MuscleGroup] = []
        for group in priorityGroups where seen.insert(group).inserted { result.append(group) }
        for region in priorityRegions {
            for group in region.groups where seen.insert(group).inserted { result.append(group) }
        }
        return result
    }

    var primaryGoal: TrainingGoal { goals.first ?? .generalFitness }
}

/// A self-reported strength marker used only to seed the very first load recommendation.
struct StrengthSeed: Codable, Hashable, Sendable, Identifiable {
    var id: String { exerciseID }
    var exerciseID: String
    var weightKg: Double
    var reps: Int
}

// MARK: - Equipment

/// What the user can actually train with, plus the exact increments their gym stocks.
@Model
final class EquipmentProfile {
    var id: UUID = UUID()
    var preset: GymSetupPreset = GymSetupPreset.fullGym
    var availableEquipment: [Equipment] = []
    /// Equipment temporarily unavailable (a broken machine), cleared by the user.
    var temporarilyUnavailable: [Equipment] = []

    // Load increments, all in kilograms.
    var barbellBarWeightKg: Double = 20
    var ezBarWeightKg: Double = 10
    var availablePlatesKg: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]
    /// Dumbbells the gym stocks. Empty means "assume a continuous 2 kg ladder".
    var availableDumbbellsKg: [Double] = [
        2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22.5, 25, 27.5, 30, 32.5, 35, 37.5, 40, 45, 50
    ]
    var machineIncrementKg: Double = 5
    var cableIncrementKg: Double = 2.5
    var kettlebellsKg: [Double] = [8, 12, 16, 20, 24, 28, 32]
    var updatedAt: Date = Date()

    init() {}

    var effectiveEquipment: Set<Equipment> {
        Set(availableEquipment).subtracting(temporarilyUnavailable)
    }
}

// MARK: - Settings

/// Everything the user can toggle. One row.
@Model
final class UserSettings {
    var id: UUID = UUID()

    var weightUnit: WeightUnit = WeightUnit.kilograms
    var heightUnit: HeightUnit = HeightUnit.centimeters
    var distanceUnit: DistanceUnit = DistanceUnit.kilometers
    var energyUnit: EnergyUnit = EnergyUnit.kilocalories
    var appearance: AppearancePreference = AppearancePreference.system
    /// `nil` follows the device language.
    var languageOverride: AppLanguage?

    // Training defaults
    var defaultRestSeconds: Int = 120
    var defaultCompoundRestSeconds: Int = 180
    var defaultIsolationRestSeconds: Int = 75
    var progressionStrategy: ProgressionStrategy = ProgressionStrategy.doubleProgression
    var autoProgressionEnabled: Bool = true
    var deloadSuggestionsEnabled: Bool = true
    var autoRegulationEnabled: Bool = true
    var restTimerAutoStart: Bool = true
    var restTimerSoundEnabled: Bool = true
    var restTimerHapticsEnabled: Bool = true
    var keepScreenAwakeDuringWorkout: Bool = true
    var showAnimationsDuringWorkout: Bool = true
    var targetRIROverride: Int?

    // Notifications
    var notificationsEnabled: Bool = false
    var trainingReminderEnabled: Bool = false
    var trainingReminderHour: Int = 18
    var trainingReminderMinute: Int = 0
    var restTimerNotificationEnabled: Bool = true
    var weightReminderEnabled: Bool = false
    var weightReminderHour: Int = 8
    var mealReminderEnabled: Bool = false
    var mealReminderHours: [Int] = [9, 14, 20]

    // Health
    var healthKitEnabled: Bool = false
    var healthKitWriteWorkouts: Bool = true
    var healthKitReadBodyMass: Bool = true
    var healthKitReadActiveEnergy: Bool = true
    var healthKitReadSteps: Bool = true
    var healthKitReadSleep: Bool = false

    // Nutrition
    var nutritionEnabled: Bool = true
    var dynamicCalorieAdjustmentEnabled: Bool = true
    var waterTrackingEnabled: Bool = true
    var dailyWaterTargetMl: Double = 2500

    var hasSeenWorkoutCoachMarks: Bool = false
    var updatedAt: Date = Date()

    init() {}
}

// MARK: - Per-exercise preferences

/// The user's standing opinion about one exercise. Absent means "no opinion".
@Model
final class ExercisePreference {
    #Unique<ExercisePreference>([\.exerciseID])
    #Index<ExercisePreference>([\.exerciseID])

    var exerciseID: String = ""
    var isFavorite: Bool = false
    var feedback: ExerciseFeedback = ExerciseFeedback.neutral
    /// Permanently excluded from automatic selection. Still browsable in the library.
    var isExcluded: Bool = false
    /// Custom load increment for this movement, in kilograms, overriding the equipment default.
    var customIncrementKg: Double?
    var notes: String?
    var lastPerformedAt: Date?
    var timesPerformed: Int = 0
    var updatedAt: Date = Date()

    init(exerciseID: String) {
        self.exerciseID = exerciseID
    }

    var scoreMultiplier: Double {
        if isExcluded { return 0 }
        return feedback.scoreMultiplier * (isFavorite ? 1.2 : 1.0)
    }
}

// MARK: - Program

/// A generated (or hand-built) training program. Exactly one program is active at a time; older
/// programs are retained so their history stays readable.
@Model
final class TrainingProgram {
    #Index<TrainingProgram>([\.createdAt], [\.isActive])

    var id: UUID = UUID()
    var title: String = ""
    /// Localisation key describing the split, e.g. `"split.pushPullLegs"`.
    var splitKey: String = "split.custom"
    var daysPerWeek: Int = 3
    var isActive: Bool = true
    var isManuallyCreated: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Program-level goal snapshot, so a later goal change does not rewrite this program's intent.
    var goals: [TrainingGoal] = []
    var experience: ExperienceLevel = ExperienceLevel.beginner
    var priorityGroups: [MuscleGroup] = []
    var currentVersion: Int = 1
    /// Week index since the program started; drives deload cadence.
    var completedWeeks: Int = 0
    var mesocycleLengthWeeks: Int = 5

    @Relationship(deleteRule: .cascade, inverse: \WorkoutTemplate.program)
    var templates: [WorkoutTemplate] = []

    @Relationship(deleteRule: .cascade, inverse: \ProgramVersion.program)
    var versions: [ProgramVersion] = []

    init() {}

    var orderedTemplates: [WorkoutTemplate] {
        templates.sorted { $0.orderIndex < $1.orderIndex }
    }
}

/// An immutable record of what the program looked like at a point in time and why it changed.
/// Requirement: the engine may rewrite a program, but it may never erase what came before.
@Model
final class ProgramVersion {
    var id: UUID = UUID()
    var versionNumber: Int = 1
    var createdAt: Date = Date()
    /// Localisation key for the human-readable reason, e.g. `"explain.volumeIncreased"`.
    var reasonKey: String = ""
    /// Arguments substituted into `reasonKey`, already localised at render time.
    var reasonArguments: [String] = []
    /// JSON snapshot of the templates at this version. Rendered read-only in program history.
    var snapshotJSON: Data?
    var program: TrainingProgram?

    init() {}
}

/// One reusable session plan inside a program.
@Model
final class WorkoutTemplate {
    var id: UUID = UUID()
    var orderIndex: Int = 0
    /// Free-text name if the user renamed it; otherwise `titleKey` is used.
    var customTitle: String?
    var titleKey: String = "session.untitled"
    /// Optional fixed weekday. `nil` means "any available day, in order".
    var weekday: Weekday?
    var estimatedMinutes: Int = 60
    var focusGroups: [MuscleGroup] = []
    var pushPull: PushPullClass = PushPullClass.neutral
    var isRestDay: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var program: TrainingProgram?

    @Relationship(deleteRule: .cascade, inverse: \PlannedExercise.template)
    var plannedExercises: [PlannedExercise] = []

    init() {}

    var orderedExercises: [PlannedExercise] {
        plannedExercises.sorted { $0.orderIndex < $1.orderIndex }
    }

    var totalPlannedSets: Int {
        plannedExercises.reduce(0) { $0 + $1.targetSets }
    }
}

/// One exercise slot inside a template.
@Model
final class PlannedExercise {
    var id: UUID = UUID()
    var exerciseID: String = ""
    var orderIndex: Int = 0
    var targetSets: Int = 3
    var repLower: Int = 8
    var repUpper: Int = 12
    var restSeconds: Int = 120
    var targetRIR: Int = 2
    /// Seconds per set for time-based movements.
    var targetDurationSeconds: Int?
    var targetDistanceMeters: Double?
    /// When true the programming engine will not swap or drop this exercise.
    var isLocked: Bool = false
    var notes: String?
    /// Set if this slot replaced a different exercise, for explainability.
    var substitutedFromExerciseID: String?
    var template: WorkoutTemplate?

    init() {}

    var repRange: RepRange {
        get { RepRange(repLower, repUpper) }
        set { repLower = newValue.lower; repUpper = newValue.upper }
    }
}

// MARK: - Sessions

/// A workout the user actually performed (or is performing). A session is a **snapshot**: it copies
/// the plan at the moment it starts, so editing the template afterwards never rewrites history.
@Model
final class WorkoutSession {
    #Index<WorkoutSession>([\.startedAt], [\.statusRaw])

    var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date?
    /// Stored as a raw string so SwiftData predicates can filter on it directly.
    var statusRaw: String = PlannedSessionStatus.inProgress.rawValue
    var titleSnapshot: String = ""
    var templateID: UUID?
    var programID: UUID?
    var programVersion: Int = 1
    var focusGroups: [MuscleGroup] = []
    var notes: String?
    var effortFeedback: SessionEffortFeedback?
    /// Total accumulated rest + work seconds, excluding time the app spent in the background.
    var activeSeconds: Int = 0
    /// Cached tonnage in kilograms so history lists do not have to recompute it.
    var totalVolumeKg: Double = 0
    var completedSetCount: Int = 0
    var plannedSetCount: Int = 0
    /// Index of the exercise the user was on, so an interrupted session resumes in place.
    var resumeExerciseIndex: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \ExerciseSession.workout)
    var exercises: [ExerciseSession] = []

    init() {}

    var status: PlannedSessionStatus {
        get { PlannedSessionStatus(rawValue: statusRaw) ?? .planned }
        set { statusRaw = newValue.rawValue }
    }

    var orderedExercises: [ExerciseSession] {
        exercises.sorted { $0.orderIndex < $1.orderIndex }
    }

    var durationSeconds: Int {
        if let endedAt { return max(0, Int(endedAt.timeIntervalSince(startedAt))) }
        return max(0, Int(Date().timeIntervalSince(startedAt)))
    }
}

/// One exercise as performed inside a session.
@Model
final class ExerciseSession {
    var id: UUID = UUID()
    var exerciseID: String = ""
    /// Name captured when the session started. Keeps old sessions readable even if the catalogue
    /// changes or the exercise is later replaced in the template.
    var exerciseNameSnapshot: String = ""
    var orderIndex: Int = 0
    var notes: String?
    var wasSkipped: Bool = false
    /// Populated when the user swapped this exercise mid-session.
    var substitutedFromExerciseID: String?
    var substitutionReasonKey: String?
    var targetRIR: Int = 2
    var restSeconds: Int = 120
    var trackingMode: TrackingMode = TrackingMode.weightAndReps
    var workout: WorkoutSession?

    @Relationship(deleteRule: .cascade, inverse: \SetRecord.exerciseSession)
    var sets: [SetRecord] = []

    init() {}

    var orderedSets: [SetRecord] {
        sets.sorted { $0.setIndex < $1.setIndex }
    }

    var workingSets: [SetRecord] {
        orderedSets.filter { $0.kind.countsAsWorkingSet }
    }

    var completedWorkingSets: [SetRecord] {
        workingSets.filter(\.isCompleted)
    }
}

/// One set. The atom of the entire training history.
@Model
final class SetRecord {
    var id: UUID = UUID()
    var setIndex: Int = 0
    var kind: SetKind = SetKind.working

    /// What the engine asked for.
    var targetWeightKg: Double?
    var targetReps: Int?
    var targetDurationSeconds: Int?

    /// What the user actually did.
    var weightKg: Double?
    var reps: Int?
    var durationSeconds: Int?
    var distanceMeters: Double?

    /// Reps in reserve, 0…5+. Mutually informative with `rpe`; either may be nil.
    var rir: Int?
    var rpe: Double?
    var isCompleted: Bool = false
    var completedAt: Date?
    var notes: String?
    /// Set when this specific set beat a stored personal record.
    var achievedRecordKinds: [PersonalRecordKind] = []
    var exerciseSession: ExerciseSession?

    init() {}

    /// Tonnage for this set, in kilograms. Zero unless both a load and reps were recorded.
    var volumeKg: Double {
        guard let weightKg, let reps, weightKg > 0, reps > 0 else { return 0 }
        return weightKg * Double(reps)
    }
}

// MARK: - Records and body metrics

@Model
final class PersonalRecord {
    #Index<PersonalRecord>([\.exerciseID], [\.achievedAt])

    var id: UUID = UUID()
    var exerciseID: String = ""
    var exerciseNameSnapshot: String = ""
    var kind: PersonalRecordKind = PersonalRecordKind.heaviestWeight
    /// Canonical value: kg for load, reps for reps, kg for e1RM, kg for volume, seconds, metres.
    var value: Double = 0
    /// Context for weight records: the reps performed at that weight.
    var repsContext: Int?
    var achievedAt: Date = Date()
    var sessionID: UUID?
    /// The value this record superseded, for "+2.5 kg" style deltas.
    var previousValue: Double?

    init() {}
}

@Model
final class BodyWeightEntry {
    #Index<BodyWeightEntry>([\.date])

    var id: UUID = UUID()
    var date: Date = Date()
    var weightKg: Double = 0
    /// True when the row came from HealthKit rather than manual entry.
    var isFromHealthKit: Bool = false
    var note: String?

    init() {}
    init(date: Date, weightKg: Double, isFromHealthKit: Bool = false) {
        self.date = date
        self.weightKg = weightKg
        self.isFromHealthKit = isFromHealthKit
    }
}

/// Optional daily wellbeing check-in. Feeds `RecoveryEngine`; never used for anything medical.
@Model
final class RecoveryEntry {
    #Index<RecoveryEntry>([\.date])

    var id: UUID = UUID()
    var date: Date = Date()
    /// 1…5 scales. `nil` means the user skipped that question.
    var energy: Int?
    var sleepQuality: Int?
    var sleepHours: Double?
    var soreness: Int?
    var motivation: Int?
    var stress: Int?
    var note: String?
    /// Muscle groups the user reported as sore.
    var soreGroups: [MuscleGroup] = []
    var sessionID: UUID?

    init() {}
}

// MARK: - Progression state

/// Per-exercise memory used by `ProgressionEngine`. Separated from `ExercisePreference` because it
/// is engine-owned state, not a user opinion.
@Model
final class ProgressionState {
    #Unique<ProgressionState>([\.exerciseID])
    #Index<ProgressionState>([\.exerciseID])

    var exerciseID: String = ""
    var workingWeightKg: Double?
    var repLower: Int = 8
    var repUpper: Int = 12
    var consecutiveSuccesses: Int = 0
    var consecutiveStalls: Int = 0
    var consecutiveRegressions: Int = 0
    /// True until the user has completed one honest set at a sensible load.
    var needsCalibration: Bool = true
    var lastPerformedAt: Date?
    var bestEstimatedOneRepMaxKg: Double?
    var strategy: ProgressionStrategy = ProgressionStrategy.doubleProgression
    /// Set when the engine deliberately held or cut load, so the UI can explain itself.
    var lastDecisionKey: String?
    var lastDecisionArguments: [String] = []
    var updatedAt: Date = Date()

    init(exerciseID: String) {
        self.exerciseID = exerciseID
    }

    var repRange: RepRange {
        get { RepRange(repLower, repUpper) }
        set { repLower = newValue.lower; repUpper = newValue.upper }
    }
}

/// A deload the engine proposed, and what the user decided.
@Model
final class DeloadRecommendation {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var reasonKeys: [String] = []
    var severity: Double = 0
    /// `nil` while undecided.
    var acceptedAt: Date?
    var declinedAt: Date?
    var postponedUntil: Date?
    var appliesToWeekStarting: Date?
    var volumeReduction: Double = 0.4
    var intensityReduction: Double = 0.1

    init() {}

    var isPending: Bool {
        acceptedAt == nil && declinedAt == nil &&
            (postponedUntil.map { $0 <= Date() } ?? true)
    }
}
