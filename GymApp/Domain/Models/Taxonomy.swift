import Foundation

// MARK: - Body part

/// The ten body-part buckets used by the source dataset.
///
/// The raw values are exactly the strings that appear in `exercises.core.json`, so decoding is a
/// direct lookup and an unrecognised value degrades to `.other` instead of dropping the record.
enum BodyPart: String, CaseIterable, Codable, Hashable, Sendable {
    case back
    case cardio
    case chest
    case lowerArms = "lower arms"
    case lowerLegs = "lower legs"
    case neck
    case shoulders
    case upperArms = "upper arms"
    case upperLegs = "upper legs"
    case waist
    case other

    init(datasetValue: String) {
        self = BodyPart(rawValue: datasetValue.lowercased()) ?? .other
    }

    var localizationKey: String { "bodyPart.\(rawValue.replacingOccurrences(of: " ", with: "_"))" }

    var symbolName: String {
        switch self {
        case .back: "figure.strengthtraining.functional"
        case .cardio: "heart.fill"
        case .chest: "figure.arms.open"
        case .lowerArms: "hand.raised.fill"
        case .lowerLegs: "shoe.fill"
        case .neck: "person.bust"
        case .shoulders: "figure.arms.open"
        case .upperArms: "figure.strengthtraining.traditional"
        case .upperLegs: "figure.run"
        case .waist: "figure.core.training"
        case .other: "figure.mixed.cardio"
        }
    }
}

// MARK: - Muscles

/// A canonical muscle. The dataset uses three overlapping vocabularies (`target`, `muscle_group`,
/// `secondary_muscles`) with 19, 29 and 40 distinct spellings respectively — for example `traps`
/// and `trapezius`, or `lats` and `latissimus dorsi`, refer to the same muscle. `Muscle` is the
/// normalised union; `init(datasetValue:)` owns every alias so the rest of the app never sees a
/// raw string.
enum Muscle: String, CaseIterable, Codable, Hashable, Sendable {
    case abs
    case obliques
    case lowerBack
    case lats
    case upperBack
    case rhomboids
    case traps
    case levatorScapulae
    case delts
    case rearDelts
    case rotatorCuff
    case pectorals
    case serratusAnterior
    case biceps
    case brachialis
    case triceps
    case forearms
    case quads
    case hamstrings
    case glutes
    case adductors
    case abductors
    case hipFlexors
    case calves
    case soleus
    case tibialisAnterior
    case ankles
    case neck
    case cardiovascularSystem

    /// Maps every spelling the dataset uses onto a canonical muscle.
    ///
    /// Unknown spellings return `nil` rather than silently collapsing into a wrong bucket — the
    /// dataset audit surfaces those, and volume accounting simply ignores them.
    init?(datasetValue raw: String) {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "abs", "abdominals", "lower abs", "core": self = .abs
        case "obliques": self = .obliques
        case "lower back", "spine", "erector spinae": self = .lowerBack
        case "lats", "latissimus dorsi": self = .lats
        case "upper back", "back": self = .upperBack
        case "rhomboids": self = .rhomboids
        case "traps", "trapezius": self = .traps
        case "levator scapulae": self = .levatorScapulae
        case "delts", "deltoids", "shoulders": self = .delts
        case "rear deltoids", "rear delts", "posterior deltoids": self = .rearDelts
        case "rotator cuff": self = .rotatorCuff
        case "pectorals", "chest", "upper chest", "pecs": self = .pectorals
        case "serratus anterior": self = .serratusAnterior
        case "biceps": self = .biceps
        case "brachialis": self = .brachialis
        case "triceps": self = .triceps
        case "forearms", "wrist flexors", "wrist extensors", "wrists", "grip muscles", "hands":
            self = .forearms
        case "quads", "quadriceps": self = .quads
        case "hamstrings": self = .hamstrings
        case "glutes": self = .glutes
        case "adductors", "inner thighs", "groin": self = .adductors
        case "abductors": self = .abductors
        case "hip flexors": self = .hipFlexors
        case "calves", "gastrocnemius": self = .calves
        case "soleus": self = .soleus
        case "shins", "tibialis anterior": self = .tibialisAnterior
        case "ankles", "ankle stabilizers", "feet": self = .ankles
        case "sternocleidomastoid", "neck": self = .neck
        case "cardiovascular system": self = .cardiovascularSystem
        default: return nil
        }
    }

    var localizationKey: String { "muscle.\(rawValue)" }

    /// The volume bucket this muscle contributes to. Several anatomically distinct muscles share a
    /// bucket because programming decisions are made per bucket, not per muscle head.
    var group: MuscleGroup {
        switch self {
        case .pectorals, .serratusAnterior: .chest
        case .lats, .upperBack, .rhomboids: .back
        case .traps, .levatorScapulae: .traps
        case .delts, .rearDelts, .rotatorCuff: .shoulders
        case .biceps, .brachialis: .biceps
        case .triceps: .triceps
        case .forearms: .forearms
        case .quads: .quads
        case .hamstrings: .hamstrings
        case .glutes: .glutes
        case .adductors: .adductors
        case .abductors: .abductors
        case .calves, .soleus, .tibialisAnterior, .ankles: .calves
        case .abs, .hipFlexors: .abs
        case .obliques: .obliques
        case .lowerBack: .lowerBack
        case .neck: .neck
        case .cardiovascularSystem: .cardio
        }
    }
}

/// The unit in which weekly volume, frequency and recovery are tracked.
enum MuscleGroup: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case chest
    case back
    case traps
    case shoulders
    case biceps
    case triceps
    case forearms
    case quads
    case hamstrings
    case glutes
    case adductors
    case abductors
    case calves
    case abs
    case obliques
    case lowerBack
    case neck
    case cardio

    var id: String { rawValue }
    var localizationKey: String { "muscleGroup.\(rawValue)" }

    /// Groups a user can meaningfully choose to prioritise during onboarding.
    static var selectablePriorities: [MuscleGroup] {
        [.chest, .back, .shoulders, .biceps, .triceps, .forearms,
         .quads, .hamstrings, .glutes, .calves, .abs, .obliques, .traps]
    }

    /// Groups that carry a weekly volume budget. `cardio` and `neck` are programmed separately.
    static var volumeTracked: [MuscleGroup] {
        allCases.filter { $0 != .cardio && $0 != .neck }
    }

    var isUpperBody: Bool {
        switch self {
        case .chest, .back, .traps, .shoulders, .biceps, .triceps, .forearms, .neck: true
        default: false
        }
    }

    var isLowerBody: Bool {
        switch self {
        case .quads, .hamstrings, .glutes, .adductors, .abductors, .calves: true
        default: false
        }
    }

    var isCore: Bool {
        switch self {
        case .abs, .obliques, .lowerBack: true
        default: false
        }
    }

    /// Small muscles recover faster and tolerate more frequency but less absolute volume.
    var isSmallMuscle: Bool {
        switch self {
        case .biceps, .triceps, .forearms, .calves, .abs, .obliques, .traps,
             .adductors, .abductors, .neck, .lowerBack: true
        case .chest, .back, .shoulders, .quads, .hamstrings, .glutes, .cardio: false
        }
    }

    /// Approximate hours needed before the group is ready for another hard stimulus.
    /// Used as the baseline in `RecoveryEngine`, then modulated by session hardness.
    var baselineRecoveryHours: Double {
        switch self {
        case .quads, .hamstrings, .glutes, .back: 60
        case .chest, .shoulders: 52
        case .lowerBack: 60
        case .biceps, .triceps, .traps, .adductors, .abductors: 44
        case .forearms, .calves, .abs, .obliques, .neck: 34
        case .cardio: 20
        }
    }

    var symbolName: String {
        switch self {
        case .chest: "figure.arms.open"
        case .back, .traps: "figure.strengthtraining.functional"
        case .shoulders: "figure.boxing"
        case .biceps, .triceps, .forearms: "figure.strengthtraining.traditional"
        case .quads, .hamstrings, .glutes, .adductors, .abductors: "figure.squat"
        case .calves: "shoe.fill"
        case .abs, .obliques, .lowerBack: "figure.core.training"
        case .neck: "person.bust"
        case .cardio: "heart.fill"
        }
    }
}

/// A coarse region the user can prioritise. Regions expand into concrete `MuscleGroup`s so the
/// programming engine only ever reasons about groups.
enum TrainingFocusRegion: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case arms
    case upperBody
    case lowerBody
    case fullBody
    case core
    case posteriorChain

    var id: String { rawValue }
    var localizationKey: String { "focusRegion.\(rawValue)" }

    var groups: [MuscleGroup] {
        switch self {
        case .arms: [.biceps, .triceps, .forearms]
        case .upperBody: [.chest, .back, .shoulders, .biceps, .triceps, .traps]
        case .lowerBody: [.quads, .hamstrings, .glutes, .calves]
        case .fullBody: MuscleGroup.volumeTracked
        case .core: [.abs, .obliques, .lowerBack]
        case .posteriorChain: [.back, .hamstrings, .glutes, .lowerBack, .traps]
        }
    }
}

// MARK: - Equipment

/// Every equipment string present in the dataset, plus `.other` as a safety net.
enum Equipment: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case bodyWeight = "body weight"
    case dumbbell
    case barbell
    case ezBarbell = "ez barbell"
    case olympicBarbell = "olympic barbell"
    case trapBar = "trap bar"
    case cable
    case leverageMachine = "leverage machine"
    case smithMachine = "smith machine"
    case sledMachine = "sled machine"
    case kettlebell
    case band
    case resistanceBand = "resistance band"
    case weighted
    case assisted
    case stabilityBall = "stability ball"
    case bosuBall = "bosu ball"
    case medicineBall = "medicine ball"
    case rope
    case roller
    case wheelRoller = "wheel roller"
    case hammer
    case tire
    case stationaryBike = "stationary bike"
    case ellipticalMachine = "elliptical machine"
    case stepmillMachine = "stepmill machine"
    case skiergMachine = "skierg machine"
    case upperBodyErgometer = "upper body ergometer"
    case other

    var id: String { rawValue }

    init(datasetValue: String) {
        self = Equipment(rawValue: datasetValue.lowercased()) ?? .other
    }

    var localizationKey: String {
        "equipment.\(rawValue.replacingOccurrences(of: " ", with: "_"))"
    }

    /// Equipment shown as a top-level toggle during onboarding. The long tail (tire, hammer,
    /// ergometers…) is folded into `additionalEquipment` to keep the picker usable.
    static var primarySelectable: [Equipment] {
        [.bodyWeight, .dumbbell, .barbell, .ezBarbell, .cable, .leverageMachine,
         .smithMachine, .kettlebell, .band, .resistanceBand, .stabilityBall, .weighted,
         .assisted, .medicineBall, .bosuBall, .rope, .sledMachine, .trapBar,
         .olympicBarbell, .roller, .wheelRoller]
    }

    static var additionalSelectable: [Equipment] {
        allCases.filter { !primarySelectable.contains($0) && $0 != .other }
    }

    /// Equipment available in a room with nothing but a floor.
    static var homeMinimum: Set<Equipment> { [.bodyWeight] }

    /// A sensible "I have a full commercial gym" selection.
    static var fullGym: Set<Equipment> {
        Set(allCases.filter { $0 != .other })
    }

    /// A typical home setup: adjustable dumbbells, a bar, bands and a ball.
    static var typicalHomeGym: Set<Equipment> {
        [.bodyWeight, .dumbbell, .barbell, .ezBarbell, .band, .resistanceBand,
         .kettlebell, .stabilityBall, .weighted, .roller, .wheelRoller, .medicineBall]
    }

    var symbolName: String {
        switch self {
        case .bodyWeight, .assisted: "figure.strengthtraining.functional"
        case .dumbbell, .weighted: "dumbbell.fill"
        case .barbell, .ezBarbell, .olympicBarbell, .trapBar, .smithMachine: "figure.strengthtraining.traditional"
        case .cable, .leverageMachine, .sledMachine: "gearshape.2.fill"
        case .kettlebell: "figure.cross.training"
        case .band, .resistanceBand, .rope: "line.diagonal"
        case .stabilityBall, .bosuBall, .medicineBall: "circle.circle.fill"
        case .roller, .wheelRoller: "circle.dashed"
        case .hammer: "hammer.fill"
        case .tire: "circle.hexagongrid.fill"
        case .stationaryBike: "bicycle"
        case .ellipticalMachine, .stepmillMachine, .skiergMachine, .upperBodyErgometer: "figure.elliptical"
        case .other: "questionmark.circle"
        }
    }

    /// How load is added, which determines the increments `ProgressionEngine` may recommend.
    var loadability: Loadability {
        switch self {
        case .barbell, .olympicBarbell, .trapBar, .smithMachine: .barbell
        case .ezBarbell: .ezBar
        case .dumbbell: .dumbbell
        case .kettlebell: .kettlebell
        case .cable: .cableStack
        case .leverageMachine, .sledMachine: .machineStack
        case .band, .resistanceBand: .band
        case .weighted: .weightedBodyweight
        case .assisted: .assistedBodyweight
        case .bodyWeight, .stabilityBall, .bosuBall, .roller, .wheelRoller, .rope: .bodyweight
        case .medicineBall, .hammer, .tire: .fixedImplement
        case .stationaryBike, .ellipticalMachine, .stepmillMachine, .skiergMachine, .upperBodyErgometer: .none
        case .other: .none
        }
    }
}

// MARK: - Movement classification

enum MovementPattern: String, CaseIterable, Codable, Hashable, Sendable {
    case horizontalPush
    case verticalPush
    case horizontalPull
    case verticalPull
    case squat
    case hinge
    case lunge
    case carry
    case hipThrust
    case kneeFlexion
    case kneeExtension
    case hipAbduction
    case hipAdduction
    case calfRaise
    case elbowFlexion
    case elbowExtension
    case shoulderRaise
    case chestFly
    case shrug
    case wristFlexion
    case wristExtension
    case coreFlexion
    case coreAntiExtension
    case coreRotation
    case coreLateralFlexion
    case neckMovement
    case cardio
    case mobility
    case other

    var localizationKey: String { "movementPattern.\(rawValue)" }

    /// Patterns that oppose one another. Used to keep push/pull volume balanced.
    var antagonist: MovementPattern? {
        switch self {
        case .horizontalPush: .horizontalPull
        case .horizontalPull: .horizontalPush
        case .verticalPush: .verticalPull
        case .verticalPull: .verticalPush
        case .kneeExtension: .kneeFlexion
        case .kneeFlexion: .kneeExtension
        case .elbowFlexion: .elbowExtension
        case .elbowExtension: .elbowFlexion
        case .hipAbduction: .hipAdduction
        case .hipAdduction: .hipAbduction
        case .wristFlexion: .wristExtension
        case .wristExtension: .wristFlexion
        case .squat: .hinge
        case .hinge: .squat
        default: nil
        }
    }
}

enum PushPullClass: String, CaseIterable, Codable, Hashable, Sendable {
    case push
    case pull
    case legs
    case core
    case cardio
    case neutral

    var localizationKey: String { "pushPull.\(rawValue)" }
}

enum Mechanic: String, CaseIterable, Codable, Hashable, Sendable {
    case compound
    case isolation

    var localizationKey: String { "mechanic.\(rawValue)" }
}

enum Laterality: String, CaseIterable, Codable, Hashable, Sendable {
    case bilateral
    case unilateral
    case alternating

    var localizationKey: String { "laterality.\(rawValue)" }

    /// Unilateral work costs roughly double the clock time for the same set count.
    var timeMultiplier: Double {
        switch self {
        case .bilateral: 1.0
        case .unilateral, .alternating: 1.7
        }
    }
}

enum Difficulty: String, CaseIterable, Codable, Hashable, Sendable, Comparable {
    case beginner
    case intermediate
    case advanced

    var localizationKey: String { "difficulty.\(rawValue)" }

    var rank: Int {
        switch self {
        case .beginner: 0
        case .intermediate: 1
        case .advanced: 2
        }
    }

    static func < (lhs: Difficulty, rhs: Difficulty) -> Bool { lhs.rank < rhs.rank }
}

/// How load is added to a movement — the input to the plate/dumbbell rounding rules.
enum Loadability: String, CaseIterable, Codable, Hashable, Sendable {
    case barbell
    case ezBar
    case dumbbell
    case kettlebell
    case cableStack
    case machineStack
    case band
    case bodyweight
    case weightedBodyweight
    case assistedBodyweight
    case fixedImplement
    case none

    var localizationKey: String { "loadability.\(rawValue)" }

    /// Whether a numeric load is meaningful at all for this movement.
    var carriesExternalLoad: Bool {
        switch self {
        case .bodyweight, .none, .band: false
        default: true
        }
    }
}

/// What a set of this exercise is measured in. Derived per exercise so the logger never asks for
/// reps on a plank or a weight on a treadmill run.
enum TrackingMode: String, CaseIterable, Codable, Hashable, Sendable {
    /// External load × repetitions. The default for most of the catalogue.
    case weightAndReps
    /// Repetitions only — unloadable bodyweight movements.
    case repsOnly
    /// Bodyweight plus optional added load (weighted pull-up, dip).
    case weightedBodyweight
    /// Bodyweight minus machine/band assistance (assisted pull-up).
    case assistedBodyweight
    /// Held for time (plank, hollow hold, static stretch).
    case duration
    /// Time on a machine or track, with optional distance.
    case distanceAndDuration
    /// Loaded carries: weight plus distance or time.
    case weightAndDuration

    var localizationKey: String { "trackingMode.\(rawValue)" }

    var usesReps: Bool {
        switch self {
        case .weightAndReps, .repsOnly, .weightedBodyweight, .assistedBodyweight: true
        case .duration, .distanceAndDuration, .weightAndDuration: false
        }
    }

    var usesWeight: Bool {
        switch self {
        case .weightAndReps, .weightedBodyweight, .assistedBodyweight, .weightAndDuration: true
        case .repsOnly, .duration, .distanceAndDuration: false
        }
    }

    var usesDuration: Bool {
        switch self {
        case .duration, .distanceAndDuration, .weightAndDuration: true
        default: false
        }
    }

    var usesDistance: Bool { self == .distanceAndDuration }

    /// `weight × reps` is only a meaningful volume figure when both are actually recorded.
    var contributesToTonnage: Bool {
        switch self {
        case .weightAndReps, .weightedBodyweight: true
        default: false
        }
    }
}

/// An inclusive repetition target window, e.g. 8–12.
struct RepRange: Codable, Hashable, Sendable, CustomStringConvertible {
    var lower: Int
    var upper: Int

    init(_ lower: Int, _ upper: Int) {
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
    }

    var description: String { lower == upper ? "\(lower)" : "\(lower)–\(upper)" }
    var midpoint: Int { (lower + upper) / 2 }
    func contains(_ reps: Int) -> Bool { reps >= lower && reps <= upper }

    static let strength = RepRange(3, 6)
    static let hypertrophy = RepRange(8, 12)
    static let hypertrophyHeavy = RepRange(6, 10)
    static let hypertrophyLight = RepRange(12, 20)
    static let endurance = RepRange(15, 25)
}
