import Foundation

// MARK: - Profile

enum BiologicalSex: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case male
    case female
    /// The user declined to say. Metabolic formulas fall back to the average of the two
    /// sex-specific constants rather than guessing.
    case unspecified

    var id: String { rawValue }
    var localizationKey: String { "sex.\(rawValue)" }
}

enum ExperienceLevel: String, CaseIterable, Codable, Hashable, Sendable, Identifiable, Comparable {
    case never
    case beginner
    case intermediate
    case advanced

    var id: String { rawValue }
    var localizationKey: String { "experience.\(rawValue)" }
    var detailLocalizationKey: String { "experience.\(rawValue).detail" }

    var rank: Int {
        switch self {
        case .never: 0
        case .beginner: 1
        case .intermediate: 2
        case .advanced: 3
        }
    }

    static func < (lhs: ExperienceLevel, rhs: ExperienceLevel) -> Bool { lhs.rank < rhs.rank }

    /// The hardest exercise difficulty this user should normally be programmed.
    var maximumDifficulty: Difficulty {
        switch self {
        case .never, .beginner: .beginner
        case .intermediate: .intermediate
        case .advanced: .advanced
        }
    }

    /// Conservative default reps-in-reserve. Novices train further from failure because their
    /// technique degrades first and their perception of effort is least reliable.
    var defaultRIR: Int {
        switch self {
        case .never: 4
        case .beginner: 3
        case .intermediate: 2
        case .advanced: 2
        }
    }
}

enum TechniqueConfidence: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case unfamiliar
    case learning
    case confident
    case coached

    var id: String { rawValue }
    var localizationKey: String { "technique.\(rawValue)" }
}

enum ActivityLevel: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case sedentary
    case light
    case moderate
    case active
    case veryActive

    var id: String { rawValue }
    var localizationKey: String { "activity.\(rawValue)" }
    var detailLocalizationKey: String { "activity.\(rawValue).detail" }

    /// Physical-activity multiplier applied to BMR to estimate maintenance energy.
    /// These are the conventional Harris–Benedict/Mifflin activity factors.
    var multiplier: Double {
        switch self {
        case .sedentary: 1.2
        case .light: 1.375
        case .moderate: 1.55
        case .active: 1.725
        case .veryActive: 1.9
        }
    }
}

// MARK: - Goals

enum TrainingGoal: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case buildMuscle
    case loseFat
    case recomposition
    case buildStrength
    case improveEndurance
    case maintain
    case generalFitness
    case targetMuscleGroup

    var id: String { rawValue }
    var localizationKey: String { "goal.\(rawValue)" }
    var detailLocalizationKey: String { "goal.\(rawValue).detail" }

    var symbolName: String {
        switch self {
        case .buildMuscle: "figure.strengthtraining.traditional"
        case .loseFat: "flame.fill"
        case .recomposition: "arrow.triangle.2.circlepath"
        case .buildStrength: "bolt.fill"
        case .improveEndurance: "wind"
        case .maintain: "equal.circle.fill"
        case .generalFitness: "heart.text.square.fill"
        case .targetMuscleGroup: "target"
        }
    }

    /// Rep range the goal biases towards for its primary compound work.
    var primaryRepRange: RepRange {
        switch self {
        case .buildStrength: .strength
        case .buildMuscle, .recomposition, .targetMuscleGroup: .hypertrophy
        case .loseFat: .hypertrophy
        case .improveEndurance: .endurance
        case .maintain, .generalFitness: .hypertrophyHeavy
        }
    }

    /// Weight-trend direction the nutrition engine should steer towards.
    var energyBalanceDirection: EnergyBalanceDirection {
        switch self {
        case .buildMuscle: .surplus
        case .loseFat: .deficit
        case .recomposition: .slightDeficit
        case .buildStrength: .maintenance
        case .improveEndurance, .maintain, .generalFitness, .targetMuscleGroup: .maintenance
        }
    }
}

enum EnergyBalanceDirection: String, Codable, Hashable, Sendable {
    case deficit
    case slightDeficit
    case maintenance
    case surplus
}

// MARK: - Availability

enum Weekday: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable, Comparable {
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7
    case sunday = 1

    var id: Int { rawValue }
    var localizationKey: String { "weekday.\(name)" }
    var shortLocalizationKey: String { "weekday.short.\(name)" }

    private var name: String {
        switch self {
        case .monday: "monday"
        case .tuesday: "tuesday"
        case .wednesday: "wednesday"
        case .thursday: "thursday"
        case .friday: "friday"
        case .saturday: "saturday"
        case .sunday: "sunday"
        }
    }

    /// Monday-first ordering, which is how training weeks are conventionally laid out.
    var orderIndex: Int {
        switch self {
        case .monday: 0
        case .tuesday: 1
        case .wednesday: 2
        case .thursday: 3
        case .friday: 4
        case .saturday: 5
        case .sunday: 6
        }
    }

    static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.orderIndex < rhs.orderIndex }

    static var orderedMondayFirst: [Weekday] {
        allCases.sorted()
    }

    /// The weekday of a given date, in the user's calendar.
    static func from(_ date: Date, calendar: Calendar = .current) -> Weekday {
        Weekday(rawValue: calendar.component(.weekday, from: date)) ?? .monday
    }
}

enum PreferredTrainingTime: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case earlyMorning
    case morning
    case midday
    case afternoon
    case evening
    case night
    case varies

    var id: String { rawValue }
    var localizationKey: String { "trainingTime.\(rawValue)" }

    /// Hour used to schedule the default training reminder.
    var reminderHour: Int {
        switch self {
        case .earlyMorning: 5
        case .morning: 8
        case .midday: 12
        case .afternoon: 16
        case .evening: 18
        case .night: 21
        case .varies: 17
        }
    }
}

enum CardioPreference: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case none
    case afterLifting
    case separateSessions
    case either

    var id: String { rawValue }
    var localizationKey: String { "cardio.\(rawValue)" }
}

enum GymSetupPreset: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case fullGym
    case limitedGym
    case homeGym
    case bodyweightOnly
    case custom

    var id: String { rawValue }
    var localizationKey: String { "gymPreset.\(rawValue)" }
    var detailLocalizationKey: String { "gymPreset.\(rawValue).detail" }

    var equipment: Set<Equipment> {
        switch self {
        case .fullGym: Equipment.fullGym
        case .limitedGym:
            [.bodyWeight, .dumbbell, .barbell, .ezBarbell, .cable, .smithMachine,
             .leverageMachine, .kettlebell, .band, .weighted, .assisted]
        case .homeGym: Equipment.typicalHomeGym
        case .bodyweightOnly: Equipment.homeMinimum
        case .custom: Equipment.typicalHomeGym
        }
    }
}

// MARK: - Restrictions

enum MobilityLimitation: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case overheadPressing
    case deepKneeFlexion
    case spinalLoading
    case hipHinge
    case wristExtension
    case shoulderExternalRotation
    case highImpact
    case gripIntensive

    var id: String { rawValue }
    var localizationKey: String { "limitation.\(rawValue)" }
    var detailLocalizationKey: String { "limitation.\(rawValue).detail" }

    /// Movement patterns this limitation makes unsuitable.
    var blockedPatterns: Set<MovementPattern> {
        switch self {
        case .overheadPressing: [.verticalPush]
        case .deepKneeFlexion: [.squat, .lunge]
        case .spinalLoading: [.hinge, .squat, .carry]
        case .hipHinge: [.hinge]
        case .wristExtension: [.wristExtension, .wristFlexion]
        case .shoulderExternalRotation: [.chestFly, .verticalPush]
        case .highImpact: [.cardio]
        case .gripIntensive: [.carry, .verticalPull]
        }
    }

    /// Extra equipment-independent tags to avoid.
    var blockedTags: Set<String> {
        switch self {
        case .overheadPressing: ["overhead"]
        case .deepKneeFlexion: ["deep_knee", "plyometric"]
        case .spinalLoading: ["axial_load"]
        case .hipHinge: ["hinge"]
        case .wristExtension: ["wrist_loaded"]
        case .shoulderExternalRotation: ["behind_neck", "deep_stretch_shoulder"]
        case .highImpact: ["plyometric", "jump"]
        case .gripIntensive: ["grip_limited"]
        }
    }
}

// MARK: - Feedback

enum ExerciseFeedback: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case love
    case like
    case neutral
    case dislike
    case neverRecommend

    var id: String { rawValue }
    var localizationKey: String { "exerciseFeedback.\(rawValue)" }

    var symbolName: String {
        switch self {
        case .love: "heart.fill"
        case .like: "hand.thumbsup.fill"
        case .neutral: "minus.circle"
        case .dislike: "hand.thumbsdown.fill"
        case .neverRecommend: "nosign"
        }
    }

    /// Multiplier applied to an exercise's selection score.
    var scoreMultiplier: Double {
        switch self {
        case .love: 1.35
        case .like: 1.15
        case .neutral: 1.0
        case .dislike: 0.55
        case .neverRecommend: 0.0
        }
    }
}

enum SessionEffortFeedback: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case easy
    case good
    case hard
    case exhausting

    var id: String { rawValue }
    var localizationKey: String { "sessionEffort.\(rawValue)" }

    var symbolName: String {
        switch self {
        case .easy: "tortoise.fill"
        case .good: "checkmark.circle.fill"
        case .hard: "flame.fill"
        case .exhausting: "exclamationmark.triangle.fill"
        }
    }

    /// Contribution to the rolling fatigue estimate, in arbitrary fatigue units.
    var fatigueDelta: Double {
        switch self {
        case .easy: -0.15
        case .good: 0.0
        case .hard: 0.15
        case .exhausting: 0.35
        }
    }
}

// MARK: - Units

enum UnitSystem: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }
    var localizationKey: String { "unitSystem.\(rawValue)" }
}

enum WeightUnit: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case kilograms = "kg"
    case pounds = "lb"

    var id: String { rawValue }
    var localizationKey: String { "weightUnit.\(rawValue)" }
    /// Kilograms per one unit.
    var kilogramsPerUnit: Double { self == .kilograms ? 1.0 : 0.45359237 }
}

enum HeightUnit: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case centimeters = "cm"
    case feetInches = "ft_in"

    var id: String { rawValue }
    var localizationKey: String { "heightUnit.\(rawValue)" }
}

enum DistanceUnit: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case kilometers = "km"
    case miles = "mi"

    var id: String { rawValue }
    var localizationKey: String { "distanceUnit.\(rawValue)" }
    var metersPerUnit: Double { self == .kilometers ? 1000 : 1609.344 }
}

enum EnergyUnit: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case kilocalories = "kcal"
    case kilojoules = "kJ"

    var id: String { rawValue }
    var localizationKey: String { "energyUnit.\(rawValue)" }
    var perKilocalorie: Double { self == .kilocalories ? 1.0 : 4.184 }
}

enum AppearancePreference: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var localizationKey: String { "appearance.\(rawValue)" }
}

// MARK: - Nutrition

enum DietType: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case omnivore
    case vegetarian
    case vegan
    case pescatarian
    case flexitarian

    var id: String { rawValue }
    var localizationKey: String { "diet.\(rawValue)" }

    /// Food tags this diet excludes. Matched against `FoodItem.dietaryTags`.
    var excludedTags: Set<String> {
        switch self {
        case .omnivore, .flexitarian: []
        case .vegetarian: ["meat", "poultry", "fish", "seafood"]
        case .vegan: ["meat", "poultry", "fish", "seafood", "dairy", "egg", "honey"]
        case .pescatarian: ["meat", "poultry"]
        }
    }
}

enum MealSlot: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case breakfast
    case lunch
    case dinner
    case snacks

    var id: String { rawValue }
    var localizationKey: String { "meal.\(rawValue)" }

    var symbolName: String {
        switch self {
        case .breakfast: "sunrise.fill"
        case .lunch: "sun.max.fill"
        case .dinner: "moon.stars.fill"
        case .snacks: "takeoutbag.and.cup.and.straw.fill"
        }
    }

    var sortIndex: Int {
        switch self {
        case .breakfast: 0
        case .lunch: 1
        case .dinner: 2
        case .snacks: 3
        }
    }

    /// Share of the daily energy budget this slot is expected to carry, used by meal suggestions.
    var defaultEnergyShare: Double {
        switch self {
        case .breakfast: 0.25
        case .lunch: 0.35
        case .dinner: 0.30
        case .snacks: 0.10
        }
    }
}

enum ServingUnit: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case grams = "g"
    case milliliters = "ml"
    case piece
    case serving

    var id: String { rawValue }
    var localizationKey: String { "servingUnit.\(rawValue)" }
    var isMassOrVolume: Bool { self == .grams || self == .milliliters }
}

enum NutritionGoalPace: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case slow
    case moderate
    case fast

    var id: String { rawValue }
    var localizationKey: String { "pace.\(rawValue)" }

    /// Target body-mass change per week as a fraction of body mass.
    /// Conservative on purpose: faster rates cost lean mass on a cut and add fat on a bulk.
    var weeklyBodyMassFraction: Double {
        switch self {
        case .slow: 0.0025
        case .moderate: 0.005
        case .fast: 0.0075
        }
    }
}

// MARK: - Scheduling

enum PlannedSessionStatus: String, CaseIterable, Codable, Hashable, Sendable {
    case planned
    case completed
    case skipped
    case rest
    case inProgress

    var localizationKey: String { "sessionStatus.\(rawValue)" }
}

enum SetKind: String, CaseIterable, Codable, Hashable, Sendable {
    case warmup
    case working
    case backoff
    case dropSet
    case amrap
    case calibration

    var localizationKey: String { "setKind.\(rawValue)" }

    /// Only working-type sets count towards weekly volume and progression decisions.
    var countsAsWorkingSet: Bool {
        switch self {
        case .working, .backoff, .amrap: true
        case .warmup, .dropSet, .calibration: false
        }
    }
}

enum CalibrationFeedback: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case tooEasy
    case correct
    case hard
    case tooHeavy

    var id: String { rawValue }
    var localizationKey: String { "calibration.\(rawValue)" }

    /// Multiplier applied to the attempted load for the next set.
    var loadMultiplier: Double {
        switch self {
        case .tooEasy: 1.15
        case .correct: 1.0
        case .hard: 0.95
        case .tooHeavy: 0.85
        }
    }
}

enum ProgressionStrategy: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case doubleProgression
    case loadProgression
    case repProgression
    case rirBased
    case volumeProgression

    var id: String { rawValue }
    var localizationKey: String { "progression.\(rawValue)" }
    var detailLocalizationKey: String { "progression.\(rawValue).detail" }
}

enum PersonalRecordKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case heaviestWeight
    case mostReps
    case estimatedOneRepMax
    case bestSetVolume
    case sessionVolume
    case longestDuration
    case longestDistance
    /// Assisted movements progress by *removing* assistance, so their strength record is the
    /// smallest counterweight the user has needed. It is the one record where a lower number wins.
    case lightestAssistance

    var id: String { rawValue }
    var localizationKey: String { "prKind.\(rawValue)" }

    /// True when a smaller value is the better result. Comparison, display and delta arithmetic all
    /// have to invert for these; today `lightestAssistance` is the only one.
    var lowerIsBetter: Bool { self == .lightestAssistance }

    var symbolName: String {
        switch self {
        case .heaviestWeight: "scalemass.fill"
        case .mostReps: "repeat"
        case .estimatedOneRepMax: "trophy.fill"
        case .bestSetVolume: "chart.bar.fill"
        case .sessionVolume: "sum"
        case .longestDuration: "timer"
        case .longestDistance: "figure.run"
        case .lightestAssistance: "arrow.down.circle.fill"
        }
    }
}

enum TimeRange: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case week
    case month
    case threeMonths
    case sixMonths
    case year
    case all

    var id: String { rawValue }
    var localizationKey: String { "range.\(rawValue)" }

    /// Number of days the range covers, or `nil` for "all time".
    var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .threeMonths: 90
        case .sixMonths: 180
        case .year: 365
        case .all: nil
        }
    }
}
