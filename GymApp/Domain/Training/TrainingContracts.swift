import Foundation

// MARK: - Explanation

/// A human-readable reason for an automatic decision.
///
/// Stored as a localisation key plus already-formatted arguments rather than as finished text, so
/// the same stored decision reads correctly after the user switches language. Every engine that
/// changes something the user did not ask for must return one of these — a recommendation the user
/// cannot interrogate is a recommendation they cannot sensibly overrule.
struct Explanation: Hashable, Sendable, Codable {
    let key: String
    let arguments: [String]

    init(_ key: String, _ arguments: [String] = []) {
        self.key = key
        self.arguments = arguments
    }

    /// Resolves the explanation against the active language.
    @MainActor
    var text: String {
        let template = LocalizationManager.shared.localized(key)
        guard !arguments.isEmpty else { return template }
        return String(format: template, arguments: arguments)
    }
}

// MARK: - Snapshots of user state

/// Everything the training engines need to know about the user, as a value type.
///
/// Engines never touch SwiftData. They take snapshots in and return plain results, which is what
/// makes every algorithm in this folder testable in isolation and free of persistence concerns.
struct TrainingProfileSnapshot: Hashable, Sendable {
    var experience: ExperienceLevel = .beginner
    var techniqueConfidence: TechniqueConfidence = .learning
    var goals: [TrainingGoal] = [.generalFitness]
    var priorityGroups: [MuscleGroup] = []
    var ageYears: Int?
    var biologicalSex: BiologicalSex = .unspecified
    var bodyWeightKg: Double = 75
    var availableWeekdays: [Weekday] = [.monday, .wednesday, .friday]
    var sessionMinutesCap: Int = 60
    var cardioPreference: CardioPreference = .either
    var availableEquipment: Set<Equipment> = Equipment.fullGym
    var excludedExerciseIDs: Set<String> = []
    var mobilityLimitations: [MobilityLimitation] = []
    var avoidedPatterns: Set<MovementPattern> = []
    var trainingExperienceMonths: Int = 0

    var primaryGoal: TrainingGoal { goals.first ?? .generalFitness }

    /// Conservative reps-in-reserve default for this user.
    var defaultTargetRIR: Int { experience.defaultRIR }

    /// Days per week the user can train.
    var daysPerWeek: Int { max(1, min(availableWeekdays.count, 7)) }
}

/// The user's standing opinion about one exercise, as a value type.
struct ExercisePreferenceSnapshot: Hashable, Sendable {
    var exerciseID: String
    var isFavorite: Bool = false
    var feedback: ExerciseFeedback = .neutral
    var isExcluded: Bool = false
    var customIncrementKg: Double?
    var timesPerformed: Int = 0
    var lastPerformedAt: Date?

    var scoreMultiplier: Double {
        if isExcluded { return 0 }
        return feedback.scoreMultiplier * (isFavorite ? 1.2 : 1.0)
    }
}

/// One set as actually performed.
struct PerformedSet: Hashable, Sendable {
    var kind: SetKind = .working
    var weightKg: Double?
    var reps: Int?
    var rir: Int?
    var rpe: Double?
    var durationSeconds: Int?
    var distanceMeters: Double?
    var targetReps: Int?
    var targetWeightKg: Double?
    var isCompleted: Bool = true

    var volumeKg: Double {
        guard let weightKg, let reps, weightKg > 0, reps > 0 else { return 0 }
        return weightKg * Double(reps)
    }

    /// Effective reps-in-reserve, derived from RPE when RIR was not recorded.
    /// RPE and RIR are two views of the same scale: RIR = 10 − RPE.
    var effectiveRIR: Double? {
        if let rir { return Double(rir) }
        if let rpe { return max(0, 10 - rpe) }
        return nil
    }
}

/// One session's worth of work on a single exercise.
struct ExercisePerformance: Hashable, Sendable {
    var date: Date
    var exerciseID: String
    var sets: [PerformedSet]
    var sessionID: UUID?

    var workingSets: [PerformedSet] { sets.filter { $0.kind.countsAsWorkingSet && $0.isCompleted } }
    var totalVolumeKg: Double { workingSets.reduce(0) { $0 + $1.volumeKg } }
    var topSet: PerformedSet? { workingSets.max { ($0.weightKg ?? 0) < ($1.weightKg ?? 0) } }
}

/// A single exercise's history, newest session first.
struct ExerciseHistorySnapshot: Hashable, Sendable {
    var exerciseID: String
    /// Newest first. Engines only ever look at the most recent few sessions.
    var performances: [ExercisePerformance] = []
    var bestEstimatedOneRepMaxKg: Double?
    var lastPerformedAt: Date?
    var totalSessions: Int = 0

    var mostRecent: ExercisePerformance? { performances.first }
}

/// Engine-owned progression memory for one exercise, as a value type.
struct ProgressionStateSnapshot: Hashable, Sendable {
    var exerciseID: String
    var workingWeightKg: Double?
    var repRange: RepRange = .hypertrophy
    var consecutiveSuccesses: Int = 0
    var consecutiveStalls: Int = 0
    var consecutiveRegressions: Int = 0
    var needsCalibration: Bool = true
    var strategy: ProgressionStrategy = .doubleProgression
    var bestEstimatedOneRepMaxKg: Double?
    var lastPerformedAt: Date?
}

// MARK: - Recovery

/// Per-muscle-group recovery state produced by `RecoveryEngine`.
struct RecoverySnapshot: Hashable, Sendable {
    /// 0 = fully recovered, 1 = maximally fatigued.
    var fatigue: [MuscleGroup: Double] = [:]
    /// Whole days since the group last received a hard stimulus. `nil` means "never".
    var daysSinceStimulus: [MuscleGroup: Int] = [:]
    /// Weekly hard-set count per group over the trailing seven days.
    var weeklySets: [MuscleGroup: Double] = [:]
    /// 0…1 whole-body readiness, blending group fatigue with subjective check-ins.
    var systemicReadiness: Double = 1.0
    /// Sessions completed in the last seven days.
    var recentSessionCount: Int = 0

    func fatigue(for group: MuscleGroup) -> Double { fatigue[group] ?? 0 }
    func readiness(for group: MuscleGroup) -> Double { 1 - fatigue(for: group) }

    static let fresh = RecoverySnapshot()
}

/// The subjective check-in, as a value type.
struct WellbeingSnapshot: Hashable, Sendable {
    var energy: Int?
    var sleepQuality: Int?
    var sleepHours: Double?
    var soreness: Int?
    var motivation: Int?
    var stress: Int?
    var soreGroups: Set<MuscleGroup> = []
    var date: Date = Date()
}

// MARK: - Programming

/// Everything `WorkoutProgrammingEngine` needs to build a program.
struct ProgrammingRequest: Sendable {
    var profile: TrainingProfileSnapshot
    var preferences: [String: ExercisePreferenceSnapshot] = [:]
    var histories: [String: ExerciseHistorySnapshot] = [:]
    var recovery: RecoverySnapshot = .fresh
    var increments: EquipmentIncrements = .default
    /// Which week of the mesocycle this is, counting from 0.
    var weekIndex: Int = 0
    var isDeloadWeek: Bool = false
    /// Exercise ids that appeared in recent sessions, used to keep variety.
    var recentlyUsedExerciseIDs: [String] = []
    /// Exercises the user pinned so the engine must keep them.
    var lockedExerciseIDs: Set<String> = []
    /// Deterministic tie-breaker seed. Fixing it makes generation reproducible in tests.
    var randomSeed: UInt64 = 0x5EED
}

/// One exercise slot in a generated session.
struct GeneratedExercise: Hashable, Sendable, Identifiable {
    var id: String { exerciseID + "#\(orderIndex)" }
    var exerciseID: String
    var orderIndex: Int
    var sets: Int
    var repRange: RepRange
    var restSeconds: Int
    var targetRIR: Int
    var targetDurationSeconds: Int?
    var targetDistanceMeters: Double?
    var isLocked: Bool = false
    var rationale: Explanation?
}

/// One generated session.
struct GeneratedSession: Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var orderIndex: Int
    var titleKey: String
    var customTitle: String?
    var weekday: Weekday?
    var focusGroups: [MuscleGroup]
    var pushPull: PushPullClass
    var estimatedMinutes: Int
    var isRestDay: Bool = false
    var exercises: [GeneratedExercise] = []

    var totalSets: Int { exercises.reduce(0) { $0 + $1.sets } }
}

/// The engine's output.
struct GeneratedProgram: Hashable, Sendable {
    var splitKey: String
    var daysPerWeek: Int
    var sessions: [GeneratedSession]
    /// Planned weekly hard sets per muscle group, including fractional indirect credit.
    var weeklyVolume: [MuscleGroup: Double]
    var explanations: [Explanation]
    var mesocycleLengthWeeks: Int = 5

    var trainingSessions: [GeneratedSession] { sessions.filter { !$0.isRestDay } }
}

// MARK: - Progression

enum ProgressionAction: String, Hashable, Sendable, Codable {
    /// Add load; the rep target resets to the bottom of the range.
    case increaseLoad
    /// Keep the load and aim for more reps inside the range.
    case addReps
    /// Repeat the same prescription.
    case maintain
    /// Back the load off after repeated failures.
    case reduceLoad
    /// No usable history — run a calibration set first.
    case calibrate
    /// Deliberately lighter, because this is a deload week.
    case deload

    var localizationKey: String { "progressionAction.\(rawValue)" }
}

struct ProgressionInput: Sendable {
    var exercise: Exercise
    var state: ProgressionStateSnapshot
    var history: ExerciseHistorySnapshot
    var targetRIR: Int
    var increments: EquipmentIncrements
    var strategy: ProgressionStrategy = .doubleProgression
    var bodyWeightKg: Double = 75
    var isDeloadWeek: Bool = false
    var experience: ExperienceLevel = .beginner
    var goal: TrainingGoal = .generalFitness
}

struct ProgressionDecision: Hashable, Sendable {
    var action: ProgressionAction
    /// `nil` for movements that carry no external load.
    var recommendedWeightKg: Double?
    var recommendedRepRange: RepRange
    var recommendedSets: Int?
    var targetRIR: Int
    var explanation: Explanation
    var updatedState: ProgressionStateSnapshot
    /// True when the user should be asked to rate the first set's difficulty.
    var requiresCalibration: Bool = false
}

// MARK: - Substitution

enum SubstitutionReason: String, CaseIterable, Hashable, Sendable, Identifiable {
    case machineUnavailable
    case machineOccupied
    case preferDumbbell
    case preferBarbell
    case preferCable
    case bodyweightOnly
    case dislike
    case easier
    case harder
    case sameMuscleDifferentExercise
    case jointDiscomfort

    var id: String { rawValue }
    var localizationKey: String { "substitution.\(rawValue)" }

    var symbolName: String {
        switch self {
        case .machineUnavailable: "xmark.circle"
        case .machineOccupied: "person.2.fill"
        case .preferDumbbell: "dumbbell.fill"
        case .preferBarbell: "figure.strengthtraining.traditional"
        case .preferCable: "gearshape.2.fill"
        case .bodyweightOnly: "figure.stand"
        case .dislike: "hand.thumbsdown"
        case .easier: "arrow.down.circle"
        case .harder: "arrow.up.circle"
        case .sameMuscleDifferentExercise: "arrow.triangle.2.circlepath"
        case .jointDiscomfort: "bandage.fill"
        }
    }
}

struct SubstitutionRequest: Sendable {
    var original: Exercise
    var reason: SubstitutionReason?
    var availableEquipment: Set<Equipment>
    var profile: TrainingProfileSnapshot
    var preferences: [String: ExercisePreferenceSnapshot] = [:]
    var histories: [String: ExerciseHistorySnapshot] = [:]
    /// Exercises already in today's session, which should not be offered twice.
    var exercisesInSession: Set<String> = []
    var limit: Int = 20
}

struct SubstitutionCandidate: Hashable, Sendable, Identifiable {
    var id: String { exercise.id }
    var exercise: Exercise
    /// 0…1 overall suitability.
    var score: Double
    /// 0…1 similarity to the original movement.
    var similarity: Double
    /// Short reasons this is a sensible swap, best first.
    var reasons: [Explanation]
    /// True when the exercise trains the exact same target muscle.
    var matchesTarget: Bool
    /// True when the exercise uses the same movement pattern.
    var matchesPattern: Bool
}

// MARK: - Autoregulation

/// What the engine learned from a finished session.
struct SessionOutcome: Hashable, Sendable {
    var sessionID: UUID
    var date: Date
    var plannedSets: Int
    var completedSets: Int
    var skippedExerciseIDs: [String]
    var substitutedExerciseIDs: [String: String]
    var effortFeedback: SessionEffortFeedback?
    var durationSeconds: Int
    var averageRIR: Double?
    var groupSets: [MuscleGroup: Double]
    var performances: [ExercisePerformance]

    var completionRate: Double {
        plannedSets > 0 ? Double(completedSets) / Double(plannedSets) : 0
    }
}

/// An adjustment the engine proposes for the next session.
struct AutoregulationAdjustment: Hashable, Sendable, Identifiable {
    enum Kind: String, Hashable, Sendable {
        case addSet
        case removeSet
        case reduceLoad
        case increaseLoad
        case swapExercise
        case shortenSession
        case restLonger
        case noChange
    }

    var id: UUID = UUID()
    var kind: Kind
    var exerciseID: String?
    var muscleGroup: MuscleGroup?
    var magnitude: Double
    var explanation: Explanation
}

// MARK: - Deload

struct DeloadAssessment: Hashable, Sendable {
    var shouldDeload: Bool
    /// 0…1 confidence in the recommendation.
    var severity: Double
    var reasons: [Explanation]
    /// Fraction of weekly sets to remove, 0…1.
    var volumeReduction: Double
    /// Fraction of load to remove, 0…1.
    var intensityReduction: Double

    static let none = DeloadAssessment(
        shouldDeload: false, severity: 0, reasons: [], volumeReduction: 0, intensityReduction: 0
    )
}

// MARK: - Weekly volume targets

/// Weekly hard-set targets per muscle group, produced by `VolumeAllocator`.
struct VolumeTargets: Hashable, Sendable {
    /// Minimum sets per week that still produce progress.
    var minimum: [MuscleGroup: Double]
    /// The number the program aims for.
    var target: [MuscleGroup: Double]
    /// The ceiling beyond which recovery, not stimulus, becomes the limit.
    var maximum: [MuscleGroup: Double]
    /// Times per week the group should be trained.
    var frequency: [MuscleGroup: Int]

    func target(for group: MuscleGroup) -> Double { target[group] ?? 0 }
    func frequency(for group: MuscleGroup) -> Int { frequency[group] ?? 0 }
}
