import Foundation
import Testing
@testable import GymApp

/// Behaviour of `LoadEstimator` — the first working load for a movement with no history, and the
/// warm-up ramp that leads into it.
@Suite("First-load estimation")
struct LoadEstimatorTests {

    // MARK: - Fixtures

    private let increments = Fixtures.increments()

    private var barbellBench: Exercise {
        Fixtures.exercise(
            id: "bench-barbell",
            name: "Barbell Bench Press",
            equipment: .barbell,
            target: .pectorals,
            metadata: Fixtures.metadata(
                movementPattern: .horizontalPush,
                loadability: .barbell,
                trackingMode: .weightAndReps
            )
        )
    }

    private var dumbbellBench: Exercise {
        Fixtures.exercise(
            id: "bench-dumbbell",
            name: "Dumbbell Bench Press",
            equipment: .dumbbell,
            target: .pectorals,
            metadata: Fixtures.metadata(
                movementPattern: .horizontalPush,
                loadability: .dumbbell,
                trackingMode: .weightAndReps
            )
        )
    }

    private var barbellSquat: Exercise {
        Fixtures.exercise(
            id: "squat-barbell",
            name: "Barbell Back Squat",
            bodyPart: .upperLegs,
            equipment: .barbell,
            target: .quads,
            metadata: Fixtures.metadata(
                movementPattern: .squat,
                pushPull: .legs,
                loadability: .barbell,
                trackingMode: .weightAndReps
            )
        )
    }

    private func startingLoad(
        for exercise: Exercise,
        profile: TrainingProfileSnapshot = Fixtures.profile(),
        relatedHistories: [String: ExerciseHistorySnapshot] = [:],
        catalog: [Exercise] = [],
        targetReps: Int = 8,
        seeds: [StrengthSeed] = []
    ) -> LoadEstimate? {
        LoadEstimator.estimateStartingLoad(
            exercise: exercise,
            profile: profile,
            relatedHistories: relatedHistories,
            catalog: catalog,
            increments: increments,
            targetReps: targetReps,
            strengthSeeds: seeds
        )
    }

    /// A load the user can actually select on this implement, given the gym's ladder.
    private func isSelectable(_ weight: Double, on loadability: Loadability) -> Bool {
        switch loadability {
        case .barbell, .ezBar:
            let bar = loadability == .barbell ? increments.barbellBarWeightKg : increments.ezBarWeightKg
            guard weight >= bar - 1e-9 else { return false }
            let plate = increments.availablePlatesKg.min() ?? 1.25
            let perSideUnits = (weight - bar) / 2 / plate
            return abs(perSideUnits - perSideUnits.rounded()) < 1e-6
        case .dumbbell:
            return increments.availableDumbbellsKg.contains { abs($0 - weight) < 1e-9 }
        case .kettlebell:
            return increments.kettlebellsKg.contains { abs($0 - weight) < 1e-9 }
        case .machineStack:
            let units = weight / increments.machineIncrementKg
            return abs(units - units.rounded()) < 1e-6
        case .cableStack:
            let units = weight / increments.cableIncrementKg
            return abs(units - units.rounded()) < 1e-6
        case .weightedBodyweight, .assistedBodyweight:
            let units = weight / 2.5
            return abs(units - units.rounded()) < 1e-6
        case .band, .bodyweight, .fixedImplement, .none:
            return true
        }
    }

    // MARK: - Tier 1: the user's own strength seed

    @Test("A strength seed for this exercise beats every other source")
    func strengthSeedWins() throws {
        // The history says something quite different (140 kg × 5), so a seed-derived answer is
        // distinguishable from a history-derived one.
        let history = Fixtures.history(
            exerciseID: barbellBench.id,
            performances: [Fixtures.performance(
                exerciseID: barbellBench.id,
                sets: Fixtures.repSets(3, weightKg: 140, reps: 5)
            )],
            totalSessions: 8
        )
        let estimate = try #require(startingLoad(
            for: barbellBench,
            relatedHistories: [barbellBench.id: history],
            catalog: [barbellBench],
            seeds: [StrengthSeed(exerciseID: barbellBench.id, weightKg: 100, reps: 5)]
        ))

        // 100 × 5 → e1RM 114.58 → 8-rep fraction 0.7975 → × 0.95 safety → 86.8 → 87.5 on the bar.
        #expect(estimate.weightKg == 87.5)
        #expect(estimate.confidence == 0.80)
        #expect(estimate.requiresCalibration == false)
        #expect(estimate.explanation.key == "loadEstimate.explain.fromSeed")
    }

    @Test("A seed the user's own numbers cannot support is clamped at four times body mass")
    func absurdSeedIsClampedBySanityCeiling() throws {
        let profile = Fixtures.profile(bodyWeightKg: 80)
        let estimate = try #require(startingLoad(
            for: barbellBench,
            profile: profile,
            seeds: [StrengthSeed(exerciseID: barbellBench.id, weightKg: 1_000, reps: 1)]
        ))
        #expect(estimate.weightKg <= profile.bodyWeightKg * 4)
        #expect(estimate.weightKg == 242.5)
    }

    @Test("A seed with an impossible rep count is ignored rather than trusted")
    func unusableSeedFallsThroughToTheNextTier() throws {
        let estimate = try #require(startingLoad(
            for: barbellBench,
            seeds: [StrengthSeed(exerciseID: barbellBench.id, weightKg: 100, reps: 0)]
        ))
        // Falls through to the body-weight ratio table, whose confidence is far lower.
        #expect(estimate.explanation.key == "loadEstimate.explain.fromBodyWeight")
    }

    // MARK: - Tier 2: a related lift

    @Test("A related exercise is carried across with its transfer coefficient and rated for it")
    func relatedLiftIsUsedWithATransferCoefficient() throws {
        let history = Fixtures.history(
            exerciseID: barbellBench.id,
            performances: [Fixtures.performance(
                exerciseID: barbellBench.id,
                sets: Fixtures.repSets(3, weightKg: 100, reps: 5)
            )],
            totalSessions: 4
        )
        let estimate = try #require(startingLoad(
            for: dumbbellBench,
            relatedHistories: [barbellBench.id: history],
            catalog: [barbellBench, dumbbellBench]
        ))

        // 0.62 across implements, −0.04 for different equipment, four sessions of data.
        #expect(abs(estimate.confidence - 0.58) < 1e-9)
        // Below the 0.60 threshold, so a number carried across implements always gets rated.
        #expect(estimate.requiresCalibration)
        #expect(estimate.explanation.key == "loadEstimate.explain.fromRelated")
        // The dumbbell coefficient is 0.42 per bell, so the per-hand load is well under the bar's.
        #expect(estimate.weightKg == 37.5)
        #expect(isSelectable(estimate.weightKg, on: .dumbbell))
    }

    @Test("The user's own history on this exact movement is trusted without a calibration set")
    func ownHistoryIsTrustedStraightAway() throws {
        let history = Fixtures.history(
            exerciseID: barbellBench.id,
            performances: [Fixtures.performance(
                exerciseID: barbellBench.id,
                sets: Fixtures.repSets(3, weightKg: 100, reps: 5)
            )],
            totalSessions: 4
        )
        let estimate = try #require(startingLoad(
            for: barbellBench,
            relatedHistories: [barbellBench.id: history],
            catalog: [barbellBench]
        ))
        #expect(abs(estimate.confidence - 0.88) < 1e-9)
        #expect(estimate.requiresCalibration == false)
        #expect(estimate.explanation.key == "loadEstimate.explain.fromOwnHistory")
        #expect(estimate.weightKg == 87.5)
    }

    @Test("One session of data is an anecdote and is discounted against four")
    func confidenceScalesWithDataSufficiency() throws {
        func confidence(sessions: Int) throws -> Double {
            let history = Fixtures.history(
                exerciseID: barbellBench.id,
                performances: [Fixtures.performance(
                    exerciseID: barbellBench.id,
                    sets: Fixtures.repSets(1, weightKg: 100, reps: 5)
                )],
                totalSessions: sessions
            )
            return try #require(startingLoad(
                for: barbellBench,
                relatedHistories: [barbellBench.id: history],
                catalog: [barbellBench]
            )).confidence
        }

        let one = try confidence(sessions: 1)
        let four = try confidence(sessions: 4)
        let ten = try confidence(sessions: 10)
        #expect(abs(one - 0.88 * 0.625) < 1e-9)
        #expect(abs(four - 0.88) < 1e-9)
        // The sufficiency scale is capped at four sessions.
        #expect(abs(ten - four) < 1e-9)
    }

    @Test("An unrelated movement in the history is not used, however much of it there is")
    func unrelatedHistoryIsIgnored() throws {
        let squatHistory = Fixtures.history(
            exerciseID: barbellSquat.id,
            performances: [Fixtures.performance(
                exerciseID: barbellSquat.id,
                sets: Fixtures.repSets(5, weightKg: 180, reps: 5)
            )],
            totalSessions: 40
        )
        let estimate = try #require(startingLoad(
            for: barbellBench,
            relatedHistories: [barbellSquat.id: squatHistory],
            catalog: [barbellSquat, barbellBench]
        ))
        // A 180 kg squat says nothing about a bench press, so the ratio table answers instead.
        #expect(estimate.explanation.key == "loadEstimate.explain.fromBodyWeight")
    }

    @Test("Two equally good sources always resolve the same way")
    func estimationIsDeterministicAcrossRuns() throws {
        let catalog = [barbellBench, dumbbellBench, barbellSquat]
        var histories: [String: ExerciseHistorySnapshot] = [:]
        for id in [barbellBench.id, barbellSquat.id] {
            histories[id] = Fixtures.history(
                exerciseID: id,
                performances: [Fixtures.performance(
                    exerciseID: id, sets: Fixtures.repSets(3, weightKg: 100, reps: 5)
                )],
                totalSessions: 4
            )
        }
        let first = startingLoad(for: dumbbellBench, relatedHistories: histories, catalog: catalog)
        for _ in 0..<20 {
            #expect(startingLoad(for: dumbbellBench, relatedHistories: histories, catalog: catalog) == first)
        }
    }

    // MARK: - Tier 3: the population ratio table

    @Test("With nothing to go on the ratio table answers and demands a calibration set")
    func nothingToGoOnDemandsCalibration() throws {
        // The worked example from the spec: 80 kg beginner male, barbell bench, 8 reps.
        // 0.55 × 80 = 44 kg 1RM → × 0.7975 = 35.1 → × 0.90 = 31.6 → 32.5 kg on the bar.
        let estimate = try #require(startingLoad(
            for: barbellBench,
            profile: Fixtures.profile(experience: .beginner, biologicalSex: .male, bodyWeightKg: 80)
        ))
        #expect(estimate.weightKg == 32.5)
        #expect(estimate.confidence == 0.45)
        #expect(estimate.requiresCalibration)
        #expect(estimate.explanation.key == "loadEstimate.explain.fromBodyWeight")
    }

    @Test("Population data fits a novice better than an advanced lifter, and says so")
    func ratioTableConfidenceDropsPastBeginner() throws {
        let novice = try #require(startingLoad(
            for: barbellBench, profile: Fixtures.profile(experience: .never)
        ))
        let advanced = try #require(startingLoad(
            for: barbellBench, profile: Fixtures.profile(experience: .advanced)
        ))
        #expect(novice.confidence == 0.45)
        #expect(advanced.confidence == 0.36)
        #expect(novice.requiresCalibration)
        #expect(advanced.requiresCalibration)
        // A stronger user still gets a heavier first guess.
        #expect(advanced.weightKg > novice.weightKg)
    }

    @Test("Declining to state a sex lands between the two sex-specific constants")
    func unspecifiedSexTakesTheMidpoint() throws {
        func load(_ sex: BiologicalSex) throws -> Double {
            try #require(startingLoad(
                for: barbellSquat,
                profile: Fixtures.profile(experience: .beginner, biologicalSex: sex, bodyWeightKg: 80)
            )).weightKg
        }
        let male = try load(.male)
        let female = try load(.female)
        let unspecified = try load(.unspecified)
        #expect(female < unspecified)
        #expect(unspecified < male)
    }

    @Test("A body weight outside 30–250 kg is a typo and is clamped")
    func absurdBodyWeightIsClamped() throws {
        func load(_ bodyWeightKg: Double) throws -> Double {
            try #require(startingLoad(
                for: barbellBench, profile: Fixtures.profile(bodyWeightKg: bodyWeightKg)
            )).weightKg
        }
        #expect(try load(500) == (try load(250)))
        #expect(try load(1) == (try load(30)))
        #expect(try load(0) == (try load(30)))
    }

    // MARK: - Movements with no ladder of loads

    @Test(
        "A movement with no selectable load gets no number at all",
        arguments: [Loadability.bodyweight, .band, .none, .fixedImplement]
    )
    func unloadableMovementsReturnNil(loadability: Loadability) {
        let exercise = Fixtures.exercise(
            metadata: Fixtures.metadata(loadability: loadability, trackingMode: .repsOnly)
        )
        #expect(startingLoad(for: exercise) == nil)
    }

    // MARK: - Conservatism and rounding

    @Test("The estimate is always lighter than the evidence it came from")
    func estimatesErrLight() throws {
        let seed = StrengthSeed(exerciseID: barbellBench.id, weightKg: 100, reps: 5)
        let eightRep = try #require(startingLoad(for: barbellBench, targetReps: 8, seeds: [seed]))
        #expect(eightRep.weightKg < seed.weightKg)

        let single = try #require(startingLoad(for: barbellBench, targetReps: 1, seeds: [seed]))
        let twelve = try #require(startingLoad(for: barbellBench, targetReps: 12, seeds: [seed]))
        #expect(single.weightKg > eightRep.weightKg)
        #expect(eightRep.weightKg > twelve.weightKg)
        // Even a single is shaved below the estimated maximum.
        let oneRepMax = try #require(OneRepMaxCalculator.estimate(weightKg: 100, reps: 5))
        #expect(single.weightKg < oneRepMax)
    }

    @Test(
        "Every estimate lands on a load the gym can actually be set to",
        arguments: [Loadability.barbell, .ezBar, .dumbbell, .kettlebell, .machineStack, .cableStack]
    )
    func estimatesRoundOntoSelectableLoads(loadability: Loadability) throws {
        let exercise = Fixtures.exercise(
            metadata: Fixtures.metadata(loadability: loadability, trackingMode: .weightAndReps)
        )
        for reps in [1, 5, 8, 12, 20, 30] {
            let estimate = try #require(startingLoad(for: exercise, targetReps: reps))
            #expect(
                isSelectable(estimate.weightKg, on: loadability),
                "\(estimate.weightKg) kg is not selectable on \(loadability) at \(reps) reps"
            )
        }
    }

    @Test("A nonsensical rep target is clamped rather than refused")
    func repTargetIsClamped() throws {
        let seed = [StrengthSeed(exerciseID: barbellBench.id, weightKg: 100, reps: 5)]
        let zero = try #require(startingLoad(for: barbellBench, targetReps: 0, seeds: seed))
        let one = try #require(startingLoad(for: barbellBench, targetReps: 1, seeds: seed))
        let huge = try #require(startingLoad(for: barbellBench, targetReps: 500, seeds: seed))
        let thirty = try #require(startingLoad(for: barbellBench, targetReps: 30, seeds: seed))
        #expect(zero.weightKg == one.weightKg)
        #expect(huge.weightKg == thirty.weightKg)
    }

    // MARK: - Warm-up ramp

    private func rampExercise(
        mechanic: Mechanic = .compound,
        loadability: Loadability = .barbell,
        repRange: RepRange = .hypertrophy,
        restSeconds: Int = 180
    ) -> Exercise {
        Fixtures.exercise(
            metadata: Fixtures.metadata(
                mechanic: mechanic,
                loadability: loadability,
                recommendedRepRange: repRange,
                defaultRestSeconds: restSeconds
            )
        )
    }

    @Test("A heavy compound gets four rungs from 40 % to 85 % with descending reps")
    func heavyCompoundRampMatchesTheDocumentedTable() {
        let ramp = LoadEstimator.warmupSets(
            workingWeightKg: 100, exercise: rampExercise(), increments: increments
        )
        #expect(ramp.map(\.weightKg) == [40, 55, 70, 85])
        #expect(ramp.map(\.reps) == [12, 8, 5, 3])
        // Short rests early, a fuller one before the working set, quantised to quarter-minutes.
        #expect(ramp.map(\.restSeconds) == [45, 45, 45, 90])
    }

    @Test("A mid-weight compound gets three rungs and a light one gets two")
    func rampCountFollowsTheWorkingLoad() {
        let mid = LoadEstimator.warmupSets(
            workingWeightKg: 50, exercise: rampExercise(), increments: increments
        )
        #expect(mid.map(\.weightKg) == [20, 30, 40])

        let light = LoadEstimator.warmupSets(
            workingWeightKg: 25,
            exercise: rampExercise(loadability: .dumbbell),
            increments: increments
        )
        #expect(light.map(\.weightKg) == [12, 18])
    }

    @Test("The ramp ascends and always ends below the working load")
    func rampAscendsAndStaysBelowTheWorkingLoad() {
        for working in [22.5, 25.0, 40.0, 60.0, 82.5, 100.0, 140.0, 200.0] {
            let ramp = LoadEstimator.warmupSets(
                workingWeightKg: working, exercise: rampExercise(), increments: increments
            )
            #expect(!ramp.isEmpty, "a \(working) kg compound should get a ramp")
            var previous = 0.0
            var previousReps = Int.max
            for rung in ramp {
                #expect(rung.weightKg > previous, "ramp did not ascend at \(working) kg")
                #expect(rung.weightKg < working, "a ramp rung reached the working load")
                #expect(rung.reps >= 2)
                #expect(rung.reps <= previousReps, "ramp reps did not descend at \(working) kg")
                previous = rung.weightKg
                previousReps = rung.reps
            }
        }
    }

    @Test("Light isolation work is its own warm-up and is skipped entirely")
    func lightIsolationSkipsTheRamp() {
        for working in [2.5, 10.0, 15.0, 19.5] {
            let ramp = LoadEstimator.warmupSets(
                workingWeightKg: working,
                exercise: rampExercise(mechanic: .isolation, loadability: .dumbbell),
                increments: increments
            )
            #expect(ramp.isEmpty, "a \(working) kg isolation movement should get no ramp")
        }
    }

    @Test("Isolation work above the threshold gets a single rung at 60 %")
    func heavyIsolationGetsOneRung() throws {
        let ramp = LoadEstimator.warmupSets(
            workingWeightKg: 30,
            exercise: rampExercise(mechanic: .isolation, loadability: .machineStack, restSeconds: 90),
            increments: increments
        )
        #expect(ramp.count == 1)
        let rung = try #require(ramp.first)
        #expect(rung.weightKg == 20)
        #expect(rung.reps == 7)
        #expect(rung.restSeconds == 60)
    }

    @Test("An assisted movement ramps the other way: more assistance first, never less")
    func assistedRampIsMirrored() {
        let assisted = Fixtures.exercise(
            metadata: Fixtures.metadata(
                loadability: .assistedBodyweight, trackingMode: .assistedBodyweight
            )
        )
        let ramp = LoadEstimator.warmupSets(
            workingWeightKg: 40, exercise: assisted, increments: increments
        )
        // Mirrored about 1, so the two rungs land at 1.5× and 1.25× the working assistance.
        #expect(ramp.map(\.weightKg) == [60, 50])
        for rung in ramp {
            #expect(rung.weightKg > 40, "an assisted warm-up rung must carry more assistance")
        }
    }

    @Test("The rep ladder is anchored on the movement's own top of range")
    func rampRepsAreAnchoredOnTheMovementsRepRange() throws {
        let ramp = LoadEstimator.warmupSets(
            workingWeightKg: 100,
            exercise: rampExercise(repRange: .strength),
            increments: increments
        )
        let first = try #require(ramp.first)
        // A five-rep squat does not get a twelve-rep warm-up.
        #expect(first.reps <= 6)
        #expect(ramp.allSatisfy { $0.reps >= 2 })
    }

    @Test("A movement with no selectable load gets no ramp")
    func unloadableMovementsGetNoRamp() {
        for loadability in [Loadability.bodyweight, .band, .none, .fixedImplement] {
            let exercise = Fixtures.exercise(
                metadata: Fixtures.metadata(loadability: loadability, trackingMode: .repsOnly)
            )
            let ramp = LoadEstimator.warmupSets(
                workingWeightKg: 40, exercise: exercise, increments: increments
            )
            #expect(ramp.isEmpty, "\(loadability) should get no warm-up ramp")
        }
    }

    @Test("A zero, negative or non-finite working load produces no ramp")
    func degenerateWorkingLoadsProduceNoRamp() {
        for working in [0.0, -50.0, Double.nan, Double.infinity] {
            let ramp = LoadEstimator.warmupSets(
                workingWeightKg: working, exercise: rampExercise(), increments: increments
            )
            #expect(ramp.isEmpty, "a working load of \(working) should get no ramp")
        }
    }

    @Test("Every ramp rung lands on a selectable load")
    func rampRungsAreSelectable() {
        for loadability in [Loadability.barbell, .dumbbell, .machineStack, .cableStack] {
            let ramp = LoadEstimator.warmupSets(
                workingWeightKg: 100,
                exercise: rampExercise(loadability: loadability),
                increments: increments
            )
            for rung in ramp {
                #expect(
                    isSelectable(rung.weightKg, on: loadability),
                    "\(rung.weightKg) kg is not selectable on \(loadability)"
                )
            }
        }
    }
}
