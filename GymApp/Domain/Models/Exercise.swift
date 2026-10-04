import Foundation

// MARK: - Catalogue record

/// One exercise from the bundled catalogue.
///
/// The catalogue is immutable, read-only reference data: it is loaded once from the app bundle and
/// held in memory as a value type. It deliberately is **not** a SwiftData model — 500 static
/// records would add nothing but migration risk and query cost. Everything the user creates
/// references an exercise by its `id`, which is stable across dataset upgrades.
struct Exercise: Identifiable, Hashable, Sendable {
    /// Zero-padded dataset identifier, e.g. `"0025"`. Stable across dataset versions.
    let id: String
    /// Canonical English name exactly as the dataset spells it.
    let name: String
    let bodyPart: BodyPart
    let equipment: Equipment
    /// Primary muscle the movement trains.
    let target: Muscle
    /// Primary synergist reported by the dataset, when it maps to a known muscle.
    let synergist: Muscle?
    /// Additional muscles involved, de-duplicated and excluding `target`.
    let secondaryMuscles: [Muscle]
    /// Id of the exercise in the Gym avatar project that rendered its media.
    let mediaID: String
    /// File name of the 240×240 JPEG thumbnail inside the media root.
    let thumbnailFileName: String
    /// File name of the 400×400 animated WebP inside the media root.
    let animationFileName: String
    /// Credit line for the media, as recorded in the dataset.
    let attribution: String
    let createdAt: Date
    /// Deterministically derived training properties. See `ExerciseMetadataDeriver`.
    let metadata: ExerciseMetadata

    static func == (lhs: Exercise, rhs: Exercise) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Every muscle the exercise touches, primary first.
    var allMuscles: [Muscle] {
        var seen: Set<Muscle> = [target]
        var result: [Muscle] = [target]
        if let synergist, seen.insert(synergist).inserted { result.append(synergist) }
        for muscle in secondaryMuscles where seen.insert(muscle).inserted { result.append(muscle) }
        return result
    }

    var primaryGroup: MuscleGroup { target.group }

    /// Groups that receive at least fractional volume from this exercise.
    var involvedGroups: [MuscleGroup] {
        Array(Set(allMuscles.map(\.group)))
    }
}

// MARK: - Derived metadata

/// Training properties the source dataset does not provide.
///
/// These are computed once, deterministically, by `ExerciseMetadataDeriver` from the fields the
/// dataset *does* provide (name, equipment, target, body part, secondary muscles). No network call
/// and no language model is involved, so the same dataset always produces the same metadata and
/// every value is unit-testable. See `docs/ALGORITHMS.md` for the full rule set.
struct ExerciseMetadata: Hashable, Sendable, Codable {
    var movementPattern: MovementPattern
    var pushPull: PushPullClass
    var mechanic: Mechanic
    var difficulty: Difficulty
    var laterality: Laterality
    var loadability: Loadability
    var trackingMode: TrackingMode

    /// How much balance/coordination the movement demands, 0…1. High values are penalised for
    /// beginners and for the fatigued end of a session.
    var stabilityDemand: Double
    /// Systemic cost of one hard set, 0…1. Drives session-level fatigue accounting.
    var fatigueCost: Double
    /// How much hypertrophy/strength stimulus one set delivers to the target, 0…1.
    var stimulusScore: Double
    /// How readily the movement can be loaded progressively, 0…1.
    var progressionSuitability: Double

    var recommendedRepRange: RepRange
    var defaultRestSeconds: Int
    /// Approximate seconds of work for a single set, excluding rest. Used for session budgeting.
    var estimatedSetSeconds: Int

    var isStretch: Bool
    var isPlyometric: Bool
    var isWarmupCandidate: Bool

    /// Fractional weekly-volume credit per muscle group. The target group scores 1.0; synergists
    /// and secondary muscles score 0.5 or 0.25 following the widely used direct/indirect
    /// convention. Documented in `docs/ALGORITHMS.md`.
    var volumeContribution: [MuscleGroup: Double]

    /// Free-form tags used by `ExerciseSubstitutionEngine` to find like-for-like swaps
    /// (e.g. `"press"`, `"incline"`, `"unilateral"`, `"machine"`).
    var substitutionTags: Set<String>

    /// A coarse "how central is this movement" score, 0…1. Compound barbell staples rank high;
    /// niche variations rank low. Used to break ties in exercise selection.
    var stapleScore: Double
}

extension ExerciseMetadata {
    /// Volume credit that a single working set of this exercise adds to `group`.
    func volumeCredit(for group: MuscleGroup) -> Double {
        volumeContribution[group] ?? 0
    }
}

// MARK: - Instructions

/// Step-by-step instructions for a single exercise in a single language.
struct ExerciseInstructions: Hashable, Sendable {
    let exerciseID: String
    let language: AppLanguage
    let steps: [String]

    var joined: String { steps.joined(separator: " ") }
}
