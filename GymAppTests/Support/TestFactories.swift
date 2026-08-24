import Foundation
@testable import GymApp

/// Shared builders for the value types the training engines consume.
///
/// Every helper defaults every field and exposes named parameters only for the handful a test
/// actually varies, so a test body reads as the one fact it pins down rather than as a wall of
/// construction. Nothing here touches SwiftData, the clock or randomness — dates come from
/// `Fixtures.day(_:)`, which counts whole days from a fixed reference instant, so two runs of the
/// same test always see the same inputs.
///
/// Owned by the progression/1RM/records/load-estimation suites. Read it freely; change it with
/// care, because other suites build on the same defaults.
enum Fixtures {

    // MARK: - Deterministic dates

    /// A fixed instant, so no test ever reads the wall clock. 2023-11-14T22:13:20Z.
    static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// `offset` whole days from `referenceDate`. Negative values are earlier.
    static func day(_ offset: Int) -> Date {
        referenceDate.addingTimeInterval(Double(offset) * 86_400)
    }

    // MARK: - Exercise

    /// Derived training metadata with plausible defaults for a bilateral barbell compound.
    ///
    /// The four fields that actually steer the engines are `loadability` (which ladder of loads
    /// exists), `trackingMode` (reps vs seconds vs distance), `mechanic` (set ceilings and warm-up
    /// rules) and `movementPattern` (which body-mass fraction and strength ratio apply).
    static func metadata(
        movementPattern: MovementPattern = .horizontalPush,
        pushPull: PushPullClass = .push,
        mechanic: Mechanic = .compound,
        difficulty: Difficulty = .beginner,
        laterality: Laterality = .bilateral,
        loadability: Loadability = .barbell,
        trackingMode: TrackingMode = .weightAndReps,
        stabilityDemand: Double = 0.5,
        fatigueCost: Double = 0.5,
        stimulusScore: Double = 0.6,
        progressionSuitability: Double = 0.8,
        recommendedRepRange: RepRange = .hypertrophy,
        defaultRestSeconds: Int = 180,
        estimatedSetSeconds: Int = 45,
        isStretch: Bool = false,
        isPlyometric: Bool = false,
        isWarmupCandidate: Bool = false,
        volumeContribution: [MuscleGroup: Double] = [:],
        substitutionTags: Set<String> = [],
        stapleScore: Double = 0.5
    ) -> ExerciseMetadata {
        ExerciseMetadata(
            movementPattern: movementPattern,
            pushPull: pushPull,
            mechanic: mechanic,
            difficulty: difficulty,
            laterality: laterality,
            loadability: loadability,
            trackingMode: trackingMode,
            stabilityDemand: stabilityDemand,
            fatigueCost: fatigueCost,
            stimulusScore: stimulusScore,
            progressionSuitability: progressionSuitability,
            recommendedRepRange: recommendedRepRange,
            defaultRestSeconds: defaultRestSeconds,
            estimatedSetSeconds: estimatedSetSeconds,
            isStretch: isStretch,
            isPlyometric: isPlyometric,
            isWarmupCandidate: isWarmupCandidate,
            volumeContribution: volumeContribution,
            substitutionTags: substitutionTags,
            stapleScore: stapleScore
        )
    }

    /// A catalogue record. Media fields are empty strings — no engine reads them.
    static func exercise(
        id: String = "test-0001",
        name: String = "Test Exercise",
        bodyPart: BodyPart = .chest,
        equipment: Equipment = .barbell,
        target: Muscle = .pectorals,
        synergist: Muscle? = nil,
        secondaryMuscles: [Muscle] = [],
        metadata: ExerciseMetadata = Fixtures.metadata()
    ) -> Exercise {
        Exercise(
            id: id,
            name: name,
            bodyPart: bodyPart,
            equipment: equipment,
            target: target,
            synergist: synergist,
            secondaryMuscles: secondaryMuscles,
            mediaID: "",
            thumbnailFileName: "",
            animationFileName: "",
            attribution: "",
            createdAt: referenceDate,
            metadata: metadata
        )
    }

    // MARK: - Logged work

    /// One set as performed. `kind` defaults to `.working` and `isCompleted` to `true`, which are
    /// the only combination the engines draw conclusions from.
    static func set(
        kind: SetKind = .working,
        weightKg: Double? = nil,
        reps: Int? = nil,
        rir: Int? = nil,
        rpe: Double? = nil,
        durationSeconds: Int? = nil,
        distanceMeters: Double? = nil,
        targetReps: Int? = nil,
        targetWeightKg: Double? = nil,
        isCompleted: Bool = true
    ) -> PerformedSet {
        PerformedSet(
            kind: kind,
            weightKg: weightKg,
            reps: reps,
            rir: rir,
            rpe: rpe,
            durationSeconds: durationSeconds,
            distanceMeters: distanceMeters,
            targetReps: targetReps,
            targetWeightKg: targetWeightKg,
            isCompleted: isCompleted
        )
    }

    /// `count` identical completed working sets — the shape of an ordinary logged session.
    static func repSets(
        _ count: Int,
        weightKg: Double? = nil,
        reps: Int,
        rir: Int? = nil
    ) -> [PerformedSet] {
        (0..<max(0, count)).map { _ in
            set(weightKg: weightKg, reps: reps, rir: rir)
        }
    }

    /// One session's work on one exercise.
    static func performance(
        date: Date = Fixtures.day(0),
        exerciseID: String = "test-0001",
        sets: [PerformedSet]
    ) -> ExercisePerformance {
        ExercisePerformance(date: date, exerciseID: exerciseID, sets: sets, sessionID: nil)
    }

    /// An exercise's history. `performances` must be newest first, which is the contract every
    /// engine relies on.
    static func history(
        exerciseID: String = "test-0001",
        performances: [ExercisePerformance] = [],
        bestEstimatedOneRepMaxKg: Double? = nil,
        lastPerformedAt: Date? = nil,
        totalSessions: Int? = nil
    ) -> ExerciseHistorySnapshot {
        ExerciseHistorySnapshot(
            exerciseID: exerciseID,
            performances: performances,
            bestEstimatedOneRepMaxKg: bestEstimatedOneRepMaxKg,
            lastPerformedAt: lastPerformedAt ?? performances.first?.date,
            totalSessions: totalSessions ?? performances.count
        )
    }

    // MARK: - User

    /// The user, as the engines see them. Body weight matters to `LoadEstimator`; experience
    /// matters to both the ratio table and the reps-in-reserve floor.
    static func profile(
        experience: ExperienceLevel = .beginner,
        biologicalSex: BiologicalSex = .male,
        bodyWeightKg: Double = 80,
        goals: [TrainingGoal] = [.generalFitness],
        availableEquipment: Set<Equipment> = Equipment.fullGym
    ) -> TrainingProfileSnapshot {
        var snapshot = TrainingProfileSnapshot()
        snapshot.experience = experience
        snapshot.biologicalSex = biologicalSex
        snapshot.bodyWeightKg = bodyWeightKg
        snapshot.goals = goals
        snapshot.availableEquipment = availableEquipment
        return snapshot
    }

    // MARK: - Equipment

    /// The gym's load ladder. Defaults mirror `EquipmentIncrements.default`: a 20 kg bar with
    /// 1.25 kg plates (so a 2.5 kg smallest barbell step), a 2 kg dumbbell ladder that widens at
    /// the top, and 5 kg machine / 2.5 kg cable stacks.
    static func increments(
        barbellBarWeightKg: Double = 20,
        ezBarWeightKg: Double = 10,
        availablePlatesKg: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25],
        availableDumbbellsKg: [Double] = [
            2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22.5, 25, 27.5, 30, 32.5, 35, 37.5, 40, 45, 50
        ],
        kettlebellsKg: [Double] = [8, 12, 16, 20, 24, 28, 32],
        machineIncrementKg: Double = 5,
        cableIncrementKg: Double = 2.5
    ) -> EquipmentIncrements {
        EquipmentIncrements(
            barbellBarWeightKg: barbellBarWeightKg,
            ezBarWeightKg: ezBarWeightKg,
            availablePlatesKg: availablePlatesKg,
            availableDumbbellsKg: availableDumbbellsKg,
            kettlebellsKg: kettlebellsKg,
            machineIncrementKg: machineIncrementKg,
            cableIncrementKg: cableIncrementKg
        )
    }
}
