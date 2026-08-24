import Foundation
import Testing
@testable import GymApp

/// Behaviour of `ProgressionEngine`, checked against `docs/fragments/progression.md`.
///
/// Everything here is pure value-in/value-out: no container, no clock, no randomness. Dates come
/// from `Fixtures.day(_:)` so a session ordering is explicit rather than implied by "now".
@Suite("Progression decisions")
struct ProgressionEngineTests {

    // MARK: - Fixtures

    private static let defaultIncrements = Fixtures.increments()

    private func barbellCompound(
        repRange: RepRange = .hypertrophy,
        name: String = "Barbell Bench Press"
    ) -> Exercise {
        Fixtures.exercise(
            id: "bench",
            name: name,
            metadata: Fixtures.metadata(
                movementPattern: .horizontalPush,
                mechanic: .compound,
                loadability: .barbell,
                trackingMode: .weightAndReps,
                recommendedRepRange: repRange
            )
        )
    }

    private func dumbbellIsolation() -> Exercise {
        Fixtures.exercise(
            id: "curl",
            name: "Dumbbell Curl",
            bodyPart: .upperArms,
            equipment: .dumbbell,
            target: .biceps,
            metadata: Fixtures.metadata(
                movementPattern: .elbowFlexion,
                pushPull: .pull,
                mechanic: .isolation,
                loadability: .dumbbell,
                trackingMode: .weightAndReps
            )
        )
    }

    private func machineCompound() -> Exercise {
        Fixtures.exercise(
            id: "leg-press",
            name: "Leg Press",
            bodyPart: .upperLegs,
            equipment: .leverageMachine,
            target: .quads,
            metadata: Fixtures.metadata(
                movementPattern: .squat,
                pushPull: .legs,
                mechanic: .compound,
                loadability: .machineStack,
                trackingMode: .weightAndReps
            )
        )
    }

    private func weightedDip() -> Exercise {
        Fixtures.exercise(
            id: "weighted-dip",
            name: "Weighted Dip",
            equipment: .weighted,
            metadata: Fixtures.metadata(
                movementPattern: .horizontalPush,
                mechanic: .compound,
                loadability: .weightedBodyweight,
                trackingMode: .weightedBodyweight
            )
        )
    }

    private func assistedPullUp() -> Exercise {
        Fixtures.exercise(
            id: "assisted-pullup",
            name: "Assisted Pull-Up",
            bodyPart: .back,
            equipment: .assisted,
            target: .lats,
            metadata: Fixtures.metadata(
                movementPattern: .verticalPull,
                pushPull: .pull,
                mechanic: .compound,
                loadability: .assistedBodyweight,
                trackingMode: .assistedBodyweight
            )
        )
    }

    private func pushUp() -> Exercise {
        Fixtures.exercise(
            id: "push-up",
            name: "Push-Up",
            equipment: .bodyWeight,
            metadata: Fixtures.metadata(
                movementPattern: .horizontalPush,
                mechanic: .compound,
                loadability: .bodyweight,
                trackingMode: .repsOnly
            )
        )
    }

    private func medicineBallSlam() -> Exercise {
        Fixtures.exercise(
            id: "ball-slam",
            name: "Medicine Ball Slam",
            bodyPart: .waist,
            equipment: .medicineBall,
            target: .abs,
            metadata: Fixtures.metadata(
                movementPattern: .coreFlexion,
                pushPull: .core,
                loadability: .fixedImplement,
                trackingMode: .weightAndReps
            )
        )
    }

    private func plank(estimatedSetSeconds: Int = 60) -> Exercise {
        Fixtures.exercise(
            id: "plank",
            name: "Plank",
            bodyPart: .waist,
            equipment: .bodyWeight,
            target: .abs,
            metadata: Fixtures.metadata(
                movementPattern: .coreAntiExtension,
                pushPull: .core,
                mechanic: .isolation,
                loadability: .bodyweight,
                trackingMode: .duration,
                estimatedSetSeconds: estimatedSetSeconds
            )
        )
    }

    private func farmersCarry(estimatedSetSeconds: Int = 45) -> Exercise {
        Fixtures.exercise(
            id: "carry",
            name: "Farmer's Walk",
            bodyPart: .upperLegs,
            equipment: .dumbbell,
            target: .forearms,
            metadata: Fixtures.metadata(
                movementPattern: .carry,
                pushPull: .legs,
                mechanic: .compound,
                loadability: .dumbbell,
                trackingMode: .weightAndDuration,
                estimatedSetSeconds: estimatedSetSeconds
            )
        )
    }

    private func state(
        exerciseID: String = "bench",
        weightKg: Double? = 60,
        repRange: RepRange = .hypertrophy,
        successes: Int = 0,
        stalls: Int = 0,
        regressions: Int = 0,
        needsCalibration: Bool = false,
        strategy: ProgressionStrategy = .doubleProgression
    ) -> ProgressionStateSnapshot {
        ProgressionStateSnapshot(
            exerciseID: exerciseID,
            workingWeightKg: weightKg,
            repRange: repRange,
            consecutiveSuccesses: successes,
            consecutiveStalls: stalls,
            consecutiveRegressions: regressions,
            needsCalibration: needsCalibration,
            strategy: strategy
        )
    }

    private func input(
        _ exercise: Exercise,
        state: ProgressionStateSnapshot,
        history: ExerciseHistorySnapshot,
        targetRIR: Int = 2,
        increments: EquipmentIncrements = ProgressionEngineTests.defaultIncrements,
        strategy: ProgressionStrategy = .doubleProgression,
        bodyWeightKg: Double = 80,
        isDeloadWeek: Bool = false,
        experience: ExperienceLevel = .intermediate
    ) -> ProgressionInput {
        ProgressionInput(
            exercise: exercise,
            state: state,
            history: history,
            targetRIR: targetRIR,
            increments: increments,
            strategy: strategy,
            bodyWeightKg: bodyWeightKg,
            isDeloadWeek: isDeloadWeek,
            experience: experience,
            goal: .generalFitness
        )
    }

    /// A history of identical sessions, newest first, one day apart.
    private func history(
        exerciseID: String = "bench",
        sessions: [[PerformedSet]]
    ) -> ExerciseHistorySnapshot {
        let performances = sessions.enumerated().map { index, sets in
            Fixtures.performance(
                date: Fixtures.day(-index), exerciseID: exerciseID, sets: sets
            )
        }
        return Fixtures.history(exerciseID: exerciseID, performances: performances)
    }

    // MARK: - Calibration

    @Test("An exercise with no history asks for a calibration set instead of guessing a load")
    func emptyHistoryRequiresCalibration() {
        let decision = ProgressionEngine.decide(
            input(barbellCompound(), state: state(), history: Fixtures.history(exerciseID: "bench"))
        )
        #expect(decision.action == .calibrate)
        #expect(decision.recommendedWeightKg == nil)
        #expect(decision.requiresCalibration)
        #expect(decision.explanation.key == "progression.explain.calibrate")
        #expect(decision.updatedState.needsCalibration)
    }

    @Test("A load the engine does not trust yet is calibrated before it is progressed")
    func needsCalibrationFlagRequiresCalibration() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(needsCalibration: true, strategy: .doubleProgression),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)])
        ))
        #expect(decision.action == .calibrate)
        #expect(decision.recommendedWeightKg == nil)
    }

    @Test("A missing working load is calibrated, not invented")
    func missingWorkingWeightRequiresCalibration() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(weightKg: nil),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)])
        ))
        #expect(decision.action == .calibrate)
        #expect(decision.recommendedWeightKg == nil)
    }

    @Test("Zero kilograms is not a working load on a barbell")
    func zeroIsNotAWorkingLoadOnABarbell() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(weightKg: 0),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)])
        ))
        #expect(decision.action == .calibrate)
    }

    @Test("Calibration clears the counters and keeps asking until it has been done")
    func calibrationResetsCounters() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(successes: 2, stalls: 3, regressions: 1, needsCalibration: true),
            history: Fixtures.history(exerciseID: "bench")
        ))
        #expect(decision.updatedState.consecutiveSuccesses == 0)
        #expect(decision.updatedState.consecutiveStalls == 0)
        #expect(decision.updatedState.consecutiveRegressions == 0)
        #expect(decision.updatedState.needsCalibration)
    }

    @Test("A movement with no load has nothing to calibrate and simply starts")
    func unloadedMovementSkipsCalibration() {
        let decision = ProgressionEngine.decide(input(
            pushUp(),
            state: state(exerciseID: "push-up", weightKg: nil, needsCalibration: true),
            history: Fixtures.history(exerciseID: "push-up")
        ))
        #expect(decision.action == .maintain)
        #expect(decision.recommendedWeightKg == nil)
        #expect(decision.requiresCalibration == false)
        #expect(decision.explanation.key == "progression.explain.startReps")
    }

    // MARK: - Double progression

    @Test("Hitting the top of the range on every set once banks the session and holds the load")
    func topOfRangeOnceBanksTheSession() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)])
        ))
        #expect(decision.action == .addReps)
        #expect(decision.recommendedWeightKg == 60)
        #expect(decision.updatedState.consecutiveSuccesses == 1)
        #expect(decision.explanation.key == "progression.explain.bankSession")
    }

    @Test("Hitting the top of the range on every set twice adds load and returns to the bottom")
    func topOfRangeTwiceIncreasesLoad() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(successes: 1),
            history: history(sessions: [
                Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2),
                Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)
            ])
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 62.5)
        // The window is unchanged, so the new target is its bottom: 62.5 kg is meant to be hard
        // at eight reps, and climbing back to twelve is what earns the next increase.
        #expect(decision.recommendedRepRange == RepRange(8, 12))
        #expect(decision.updatedState.repRange == RepRange(8, 12))
        #expect(decision.updatedState.consecutiveSuccesses == 0)
        #expect(decision.updatedState.consecutiveStalls == 0)
        #expect(decision.updatedState.consecutiveRegressions == 0)
    }

    @Test("Landing inside the range keeps the load and asks for more reps")
    func insideTheRangeKeepsTheLoad() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(successes: 1),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 10, rir: 2)])
        ))
        #expect(decision.action == .addReps)
        #expect(decision.recommendedWeightKg == 60)
        #expect(decision.explanation.key == "progression.explain.addReps")
        // A session that was not a qualifying success does not keep the bank.
        #expect(decision.updatedState.consecutiveSuccesses == 0)
    }

    @Test("Falling short of the bottom once is noise and the load holds")
    func missingTheBottomOnceHoldsTheLoad() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 6, rir: 0)])
        ))
        #expect(decision.action == .maintain)
        #expect(decision.recommendedWeightKg == 60)
        #expect(decision.updatedState.consecutiveRegressions == 1)
    }

    @Test("Falling short of the bottom twice takes ten percent off")
    func missingTheBottomTwiceReducesTheLoad() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(regressions: 1),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 6, rir: 0)])
        ))
        #expect(decision.action == .reduceLoad)
        // 60 − 10 % = 54, rounded onto the nearest pair of plates.
        #expect(decision.recommendedWeightKg == 55)
        #expect(decision.explanation.key == "progression.explain.reducedLoad")
        #expect(decision.updatedState.consecutiveRegressions == 0)
    }

    @Test("All the reps but too close to failure holds the load until the margin comes back")
    func topOfRangeWithoutTheMarginHoldsTheLoad() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(successes: 1),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 0)])
        ))
        #expect(decision.action == .addReps)
        #expect(decision.recommendedWeightKg == 60)
        #expect(decision.explanation.key == "progression.explain.holdForMargin")
        #expect(decision.updatedState.consecutiveSuccesses == 0)
    }

    @Test("Reps in reserve derived from RPE count as recorded evidence")
    func rpeIsReadAsRepsInReserve() {
        // RIR = 10 − RPE, so RPE 10 is zero in reserve and blocks the increase.
        let sets = (0..<3).map { _ in Fixtures.set(weightKg: 60, reps: 12, rpe: 10) }
        let decision = ProgressionEngine.decide(input(
            barbellCompound(), state: state(successes: 1), history: history(sessions: [sets])
        ))
        #expect(decision.explanation.key == "progression.explain.holdForMargin")
        #expect(decision.recommendedWeightKg == 60)
    }

    @Test("A set with no reps in reserve recorded is missing evidence, not evidence of failure")
    func missingRIRDoesNotBlockProgress() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(successes: 1),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 12, rir: nil)])
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 62.5)
    }

    @Test("A session in which no set reached the planned load says nothing about it")
    func aLighterThanPlannedSessionIsSilent() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(successes: 1, stalls: 2, regressions: 1),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 50, reps: 12, rir: 2)])
        ))
        #expect(decision.action == .maintain)
        #expect(decision.recommendedWeightKg == 60)
        #expect(decision.explanation.key == "progression.explain.lighterThanPlanned")
        // Counters are untouched: the session is silent, not negative.
        #expect(decision.updatedState.consecutiveSuccesses == 1)
        #expect(decision.updatedState.consecutiveStalls == 2)
        #expect(decision.updatedState.consecutiveRegressions == 1)
    }

    @Test("A deliberately lighter back-off set does not hold the session hostage")
    func backoffSetsDoNotBlockProgress() {
        let sets = [
            Fixtures.set(weightKg: 60, reps: 12, rir: 2),
            Fixtures.set(weightKg: 60, reps: 12, rir: 2),
            Fixtures.set(kind: .backoff, weightKg: 50, reps: 15, rir: 1)
        ]
        let decision = ProgressionEngine.decide(input(
            barbellCompound(), state: state(successes: 1), history: history(sessions: [sets])
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 62.5)
        // The back-off set still counts towards the prescribed set count.
        #expect(decision.recommendedSets == 3)
    }

    @Test("Four sessions inside the range with no improvement is a plateau, and the load steps back")
    func fourStallsReduceTheLoad() {
        let session = Fixtures.repSets(3, weightKg: 60, reps: 10, rir: 2)
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(stalls: 3),
            history: history(sessions: [session, session])
        ))
        #expect(decision.action == .reduceLoad)
        #expect(decision.recommendedWeightKg == 55)
        #expect(decision.explanation.key == "progression.explain.reducedLoadStall")
        #expect(decision.updatedState.consecutiveStalls == 0)
    }

    // MARK: - Step size and the caps

    @Test("A compound barbell lift takes 2.5 kg even where micro-plates exist")
    func compoundBarbellStepIsAPairOfSmallPlates() {
        // 0.5 kg plates give a 1 kg ladder, but half a kilogram on a bench press is noise.
        let increments = Fixtures.increments(availablePlatesKg: [25, 20, 15, 10, 5, 2.5, 1.25, 0.5])
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(successes: 1),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)]),
            increments: increments
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 63)
    }

    @Test("An isolation lift on the same bar takes the smallest step the gym stocks")
    func isolationTakesTheSmallestIncrement() {
        let increments = Fixtures.increments(availablePlatesKg: [25, 20, 15, 10, 5, 2.5, 1.25, 0.5])
        let curl = Fixtures.exercise(
            id: "barbell-curl",
            name: "Barbell Curl",
            bodyPart: .upperArms,
            equipment: .barbell,
            target: .biceps,
            metadata: Fixtures.metadata(
                movementPattern: .elbowFlexion,
                pushPull: .pull,
                mechanic: .isolation,
                loadability: .barbell,
                trackingMode: .weightAndReps
            )
        )
        let decision = ProgressionEngine.decide(input(
            curl,
            state: state(exerciseID: "barbell-curl", successes: 1),
            history: history(
                exerciseID: "barbell-curl",
                sessions: [Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)]
            ),
            increments: increments
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 61)
    }

    @Test("A jump bigger than a tenth of the load waits for one more good session")
    func oversizedJumpBanksAnExtraSession() {
        // The 2 kg gap on a 10 kg dumbbell is a 20 % increase, so the load waits.
        let decision = ProgressionEngine.decide(input(
            dumbbellIsolation(),
            state: state(exerciseID: "curl", weightKg: 10, successes: 1),
            history: history(
                exerciseID: "curl", sessions: [Fixtures.repSets(3, weightKg: 10, reps: 12, rir: 2)]
            )
        ))
        #expect(decision.action == .addReps)
        #expect(decision.recommendedWeightKg == 10)
        #expect(decision.explanation.key == "progression.explain.bankBeforeBigJump")
        #expect(decision.updatedState.consecutiveSuccesses == 2)
    }

    @Test("Once the extra session is banked the oversized jump is taken")
    func oversizedJumpIsTakenAfterTheExtraSession() {
        let decision = ProgressionEngine.decide(input(
            dumbbellIsolation(),
            state: state(exerciseID: "curl", weightKg: 10, successes: 2),
            history: history(
                exerciseID: "curl", sessions: [Fixtures.repSets(3, weightKg: 10, reps: 12, rir: 2)]
            )
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 12)
    }

    @Test("The cap tightens from ten to five percent above a hundred kilograms")
    func theCapTightensOnHeavyLoads() {
        let increments = Fixtures.increments(machineIncrementKg: 8)
        func decide(from weight: Double) -> ProgressionDecision {
            ProgressionEngine.decide(input(
                machineCompound(),
                state: state(exerciseID: "leg-press", weightKg: weight, successes: 1),
                history: history(
                    exerciseID: "leg-press",
                    sessions: [Fixtures.repSets(3, weightKg: weight, reps: 12, rir: 2)]
                ),
                increments: increments
            ))
        }

        // 8 kg on 96 kg is 8.3 % — inside the standard cap, so the second good session takes it.
        let light = decide(from: 96)
        #expect(light.action == .increaseLoad)
        #expect(light.recommendedWeightKg == 104)

        // The same 8 kg on 104 kg is 7.7 %, past the tighter cap that applies above 100 kg.
        let heavy = decide(from: 104)
        #expect(heavy.action == .addReps)
        #expect(heavy.recommendedWeightKg == 104)
        #expect(heavy.explanation.key == "progression.explain.bankBeforeBigJump")
    }

    // MARK: - Movements with no external load

    @Test("A bodyweight movement is never given a fabricated kilogram figure")
    func bodyweightMovementsNeverGetALoad() {
        let decision = ProgressionEngine.decide(input(
            pushUp(),
            state: state(exerciseID: "push-up", weightKg: nil),
            history: history(
                exerciseID: "push-up",
                sessions: [Fixtures.repSets(3, weightKg: nil, reps: 12, rir: 2)]
            )
        ))
        #expect(decision.recommendedWeightKg == nil)
        #expect(decision.updatedState.workingWeightKg == nil)
        #expect(decision.action == .addReps)
        // No load to add, so the rep window moves up instead.
        #expect(decision.recommendedRepRange == RepRange(10, 14))
    }

    @Test("An implement that weighs what it weighs offers no ladder, so it gets no load either")
    func fixedImplementsNeverGetALoad() {
        let decision = ProgressionEngine.decide(input(
            medicineBallSlam(),
            state: state(exerciseID: "ball-slam", weightKg: 8),
            history: history(
                exerciseID: "ball-slam",
                sessions: [Fixtures.repSets(3, weightKg: 8, reps: 12, rir: 2)]
            )
        ))
        #expect(decision.recommendedWeightKg == nil)
        #expect(decision.action == .addReps)
    }

    @Test("At the rep ceiling an unloaded movement gains a set rather than more reps")
    func unloadedMovementAddsASetAtTheRepCeiling() {
        let decision = ProgressionEngine.decide(input(
            pushUp(),
            state: state(exerciseID: "push-up", weightKg: nil, repRange: RepRange(30, 30)),
            history: history(
                exerciseID: "push-up",
                sessions: [Fixtures.repSets(3, weightKg: nil, reps: 30, rir: 2)]
            )
        ))
        #expect(decision.action == .addReps)
        #expect(decision.recommendedSets == 4)
        // The rep window deliberately stays put: thirty press-ups a set is not sent back to ten.
        #expect(decision.recommendedRepRange == RepRange(30, 30))
        #expect(decision.explanation.key == "progression.explain.addSetUnloaded")
    }

    @Test("At both ceilings the movement is declared outgrown rather than padded further")
    func unloadedMovementIsDeclaredOutgrown() {
        let decision = ProgressionEngine.decide(input(
            pushUp(),
            state: state(exerciseID: "push-up", weightKg: nil, repRange: RepRange(30, 30)),
            history: history(
                exerciseID: "push-up",
                sessions: [Fixtures.repSets(5, weightKg: nil, reps: 30, rir: 2)]
            )
        ))
        #expect(decision.action == .maintain)
        #expect(decision.explanation.key == "progression.explain.outgrown")
    }

    @Test("Two short sessions on an unloaded movement shorten the rep window")
    func unloadedShortfallShortensTheWindow() {
        let decision = ProgressionEngine.decide(input(
            pushUp(),
            state: state(
                exerciseID: "push-up", weightKg: nil, repRange: RepRange(10, 14), regressions: 1
            ),
            history: history(
                exerciseID: "push-up",
                sessions: [Fixtures.repSets(3, weightKg: nil, reps: 6, rir: 0)]
            )
        ))
        #expect(decision.action == .reduceLoad)
        #expect(decision.recommendedWeightKg == nil)
        #expect(decision.recommendedRepRange == RepRange(8, 12))
        #expect(decision.explanation.key == "progression.explain.reducedReps")
    }

    // MARK: - Weighted and assisted movements

    @Test("A weighted movement progresses the load added to the body, starting from zero")
    func weightedBodyweightProgressesTheAddedLoad() {
        let decision = ProgressionEngine.decide(input(
            weightedDip(),
            state: state(exerciseID: "weighted-dip", weightKg: 0, successes: 1),
            history: history(
                exerciseID: "weighted-dip",
                sessions: [Fixtures.repSets(3, weightKg: 0, reps: 12, rir: 2)]
            )
        ))
        // Bodyweight only is a real prescription, and the first added plate has no meaningful
        // percentage, so the cap cannot block it.
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 2.5)
    }

    @Test("An assisted movement gets harder by taking assistance away")
    func assistedMovementsRemoveAssistance() {
        let decision = ProgressionEngine.decide(input(
            assistedPullUp(),
            state: state(exerciseID: "assisted-pullup", weightKg: 40, successes: 1),
            history: history(
                exerciseID: "assisted-pullup",
                sessions: [Fixtures.repSets(3, weightKg: 40, reps: 12, rir: 2)]
            )
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 37.5)
    }

    @Test("An assisted movement backs off by adding assistance")
    func assistedShortfallAddsAssistance() {
        let decision = ProgressionEngine.decide(input(
            assistedPullUp(),
            state: state(exerciseID: "assisted-pullup", weightKg: 40, regressions: 1),
            history: history(
                exerciseID: "assisted-pullup",
                sessions: [Fixtures.repSets(3, weightKg: 40, reps: 6, rir: 0)]
            )
        ))
        #expect(decision.action == .reduceLoad)
        #expect(decision.recommendedWeightKg == 45)
    }

    @Test("On an assisted movement more help than planned is the lighter session")
    func assistedComparisonsRunBackwards() {
        let decision = ProgressionEngine.decide(input(
            assistedPullUp(),
            state: state(exerciseID: "assisted-pullup", weightKg: 40),
            history: history(
                exerciseID: "assisted-pullup",
                sessions: [Fixtures.repSets(3, weightKg: 45, reps: 12, rir: 2)]
            )
        ))
        #expect(decision.action == .maintain)
        #expect(decision.explanation.key == "progression.explain.lighterThanPlanned")
        #expect(decision.recommendedWeightKg == 40)
    }

    @Test("At the floor the engine says so instead of prescribing a lighter load that does not exist")
    func atTheFloorTheEngineSaysSo() {
        let decision = ProgressionEngine.decide(input(
            weightedDip(),
            state: state(exerciseID: "weighted-dip", weightKg: 0, regressions: 1),
            history: history(
                exerciseID: "weighted-dip",
                sessions: [Fixtures.repSets(3, weightKg: 0, reps: 5, rir: 0)]
            )
        ))
        #expect(decision.action == .maintain)
        #expect(decision.recommendedWeightKg == 0)
        #expect(decision.explanation.key == "progression.explain.atMinimumLoad")
    }

    // MARK: - Deload

    @Test("A deload week lightens the load and cuts the sets")
    func deloadWeekReducesLoadAndSets() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(successes: 1, stalls: 2, regressions: 1),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 10, rir: 2)]),
            isDeloadWeek: true
        ))
        #expect(decision.action == .deload)
        #expect(decision.recommendedWeightKg == 55)
        #expect(decision.recommendedSets == 2)
        // Staying far from failure is the point of the week.
        #expect(decision.targetRIR == 4)
    }

    @Test("A deload leaves the counters and the remembered load exactly where they were")
    func deloadLeavesTheCountersAlone() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(successes: 1, stalls: 2, regressions: 1),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 10, rir: 2)]),
            isDeloadWeek: true
        ))
        #expect(decision.updatedState.consecutiveSuccesses == 1)
        #expect(decision.updatedState.consecutiveStalls == 2)
        #expect(decision.updatedState.consecutiveRegressions == 1)
        #expect(decision.updatedState.workingWeightKg == 60)
    }

    @Test("A deload never deletes the movement: the set count floors at one")
    func deloadNeverGoesBelowOneSet() {
        let prescription = ProgressionEngine.deloadPrescription(
            from: state(),
            assessment: DeloadAssessment(
                shouldDeload: true, severity: 1, reasons: [],
                volumeReduction: 0.95, intensityReduction: 0.10
            ),
            loadability: .barbell,
            increments: ProgressionEngineTests.defaultIncrements,
            currentSets: 1
        )
        #expect(prescription.sets == 1)
    }

    @Test("A deload is a lighter week, not a different sport, so both reductions are clamped")
    func deloadClampsAnExtremeAssessment() {
        let prescription = ProgressionEngine.deloadPrescription(
            from: state(),
            assessment: DeloadAssessment(
                shouldDeload: true, severity: 1, reasons: [],
                volumeReduction: 0.90, intensityReduction: 0.90
            ),
            loadability: .barbell,
            increments: ProgressionEngineTests.defaultIncrements,
            currentSets: 5
        )
        // Intensity clamps at 35 %: 60 → 39 → 40 on the bar, not 6 kg.
        #expect(prescription.weightKg == 40)
        // Volume clamps at 60 %: five sets become two, not none.
        #expect(prescription.sets == 2)
    }

    @Test("A zero reduction means unspecified and the conventional deload is applied")
    func zeroReductionsFallBackToTheConventionalDeload() {
        let prescription = ProgressionEngine.deloadPrescription(
            from: state(),
            assessment: .none,
            loadability: .barbell,
            increments: ProgressionEngineTests.defaultIncrements,
            currentSets: 5
        )
        #expect(prescription.weightKg == 55)
        #expect(prescription.sets == 3)
    }

    @Test("An unassisted pull-up in a deload week gets assistance added")
    func deloadOfAnAssistedMovementAddsAssistance() {
        let unassisted = ProgressionEngine.deloadPrescription(
            from: state(exerciseID: "assisted-pullup", weightKg: 0),
            assessment: .none,
            loadability: .assistedBodyweight,
            increments: ProgressionEngineTests.defaultIncrements,
            currentSets: 3
        )
        #expect(unassisted.weightKg == 2.5)

        let assisted = ProgressionEngine.deloadPrescription(
            from: state(exerciseID: "assisted-pullup", weightKg: 20),
            assessment: .none,
            loadability: .assistedBodyweight,
            increments: ProgressionEngineTests.defaultIncrements,
            currentSets: 3
        )
        #expect(assisted.weightKg == 22.5)
    }

    @Test("A bodyweight-only movement comes back as zero, which is not the same as no load")
    func deloadOfABodyweightOnlyMovementReturnsZero() {
        let prescription = ProgressionEngine.deloadPrescription(
            from: state(exerciseID: "weighted-dip", weightKg: 0),
            assessment: .none,
            loadability: .weightedBodyweight,
            increments: ProgressionEngineTests.defaultIncrements,
            currentSets: 3
        )
        #expect(prescription.weightKg == 0)
    }

    @Test(
        "A movement with no selectable step has no lighter setting to name",
        arguments: [Loadability.fixedImplement, .bodyweight, .band, .none]
    )
    func deloadOfAnUnloadableMovementNamesNoWeight(loadability: Loadability) {
        let prescription = ProgressionEngine.deloadPrescription(
            from: state(weightKg: 8),
            assessment: .none,
            loadability: loadability,
            increments: ProgressionEngineTests.defaultIncrements,
            currentSets: 3
        )
        #expect(prescription.weightKg == nil)
        #expect(prescription.sets == 2)
    }

    @Test("A deload that rounds back onto the working load is stepped one increment further")
    func deloadThatRoundsBackIsSteppedFurther() {
        let increments = Fixtures.increments(machineIncrementKg: 20)
        let prescription = ProgressionEngine.deloadPrescription(
            from: state(exerciseID: "leg-press", weightKg: 100),
            assessment: .none,
            loadability: .machineStack,
            increments: increments,
            currentSets: 3
        )
        // 100 − 10 % = 90, which rounds back onto 100 on a 20 kg stack.
        #expect(prescription.weightKg == 80)
    }

    // MARK: - Calibration feedback

    @Test("A rejected load is never handed straight back, even on a coarse ladder")
    func calibrationAlwaysMovesAtLeastOneStep() {
        let increments = Fixtures.increments(machineIncrementKg: 20)
        // 100 × 0.95 = 95, which rounds back onto 100 on a 20 kg stack.
        let harder = ProgressionEngine.applyCalibration(
            .hard, attemptedWeightKg: 100, loadability: .machineStack, increments: increments
        )
        #expect(harder == 80)

        let easier = ProgressionEngine.applyCalibration(
            .tooEasy, attemptedWeightKg: 100, loadability: .machineStack, increments: increments
        )
        #expect(easier == 120)
    }

    @Test("Calibration on an assisted movement runs backwards")
    func calibrationInvertsForAssistedMovements() {
        // "Too easy" on an assisted pull-up means take the counterweight away.
        let result = ProgressionEngine.applyCalibration(
            .tooEasy,
            attemptedWeightKg: 40,
            loadability: .assistedBodyweight,
            increments: ProgressionEngineTests.defaultIncrements
        )
        #expect(result == 35)
    }

    @Test("A load the user called correct is kept")
    func calibrationKeepsACorrectLoad() {
        let result = ProgressionEngine.applyCalibration(
            .correct,
            attemptedWeightKg: 60,
            loadability: .barbell,
            increments: ProgressionEngineTests.defaultIncrements
        )
        #expect(result == 60)
    }

    @Test("There is nothing to calibrate on a movement with no selectable load")
    func calibrationOfAnUnloadableMovementIsAPassThrough() {
        let result = ProgressionEngine.applyCalibration(
            .tooEasy,
            attemptedWeightKg: 12.3,
            loadability: .bodyweight,
            increments: ProgressionEngineTests.defaultIncrements
        )
        #expect(result == 12.3)
    }

    @Test("A negative attempted load calibrates to zero rather than further negative")
    func calibrationOfANegativeLoadIsZero() {
        let result = ProgressionEngine.applyCalibration(
            .hard,
            attemptedWeightKg: -10,
            loadability: .barbell,
            increments: ProgressionEngineTests.defaultIncrements
        )
        #expect(result == 0)
    }

    // MARK: - Reps in reserve

    @Test("Novices keep at least two reps in reserve, everyone else at least one")
    func targetRIRIsClampedByExperience() {
        func targetRIR(_ experience: ExperienceLevel, requested: Int) -> Int {
            ProgressionEngine.decide(input(
                barbellCompound(),
                state: state(),
                history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 10)]),
                targetRIR: requested,
                experience: experience
            )).targetRIR
        }
        #expect(targetRIR(.never, requested: 0) == 2)
        #expect(targetRIR(.beginner, requested: 0) == 2)
        #expect(targetRIR(.beginner, requested: -5) == 2)
        #expect(targetRIR(.intermediate, requested: 0) == 1)
        #expect(targetRIR(.advanced, requested: 0) == 1)
        #expect(targetRIR(.advanced, requested: 12) == 5)
    }

    // MARK: - Other strategies

    @Test("Linear load progression adds load on the first qualifying session")
    func loadProgressionActsOnASingleSession() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(strategy: .loadProgression),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 8, rir: 2)]),
            strategy: .loadProgression
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 62.5)
        #expect(decision.updatedState.strategy == .loadProgression)
    }

    @Test("Rep progression shifts the window up instead of adding load")
    func repProgressionShiftsTheWindowUp() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)]),
            strategy: .repProgression
        ))
        #expect(decision.action == .addReps)
        #expect(decision.recommendedWeightKg == 60)
        #expect(decision.recommendedRepRange == RepRange(10, 14))
    }

    @Test("At the rep ceiling, rep progression converts to load and resets the window")
    func repProgressionConvertsToLoadAtTheCeiling() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(repRange: RepRange(30, 30)),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 30, rir: 2)]),
            strategy: .repProgression
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 62.5)
        #expect(decision.recommendedRepRange == RepRange(8, 12))
    }

    @Test("Volume progression adds a set, then converts to load at the set ceiling")
    func volumeProgressionAddsASetThenLoad() {
        let growing = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)]),
            strategy: .volumeProgression
        ))
        #expect(growing.action == .addReps)
        #expect(growing.recommendedSets == 4)
        #expect(growing.recommendedWeightKg == 60)

        let atCeiling = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(),
            history: history(sessions: [Fixtures.repSets(5, weightKg: 60, reps: 12, rir: 2)]),
            strategy: .volumeProgression
        ))
        #expect(atCeiling.action == .increaseLoad)
        #expect(atCeiling.recommendedWeightKg == 62.5)
        #expect(atCeiling.recommendedSets == 3)
    }

    @Test("RIR-based progression adds load when the user finished comfortably clear of failure")
    func rirBasedAddsLoadOnSpareCapacity() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 10, rir: 3)]),
            strategy: .rirBased
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 62.5)
    }

    @Test("RIR-based progression shaves five percent off after one session too close to failure")
    func rirBasedReducesLoadOnOvershoot() {
        let decision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 10, rir: 0)]),
            strategy: .rirBased
        ))
        #expect(decision.action == .reduceLoad)
        #expect(decision.recommendedWeightKg == 57.5)
        #expect(decision.explanation.key == "progression.explain.reducedLoadRIR")
    }

    // MARK: - Timed movements

    @Test("A timed movement carries seconds in the rep range, and says so through its accessor")
    func timedMovementsCarrySeconds() throws {
        let hold = plank()
        let decision = ProgressionEngine.decide(input(
            hold,
            state: state(exerciseID: "plank", weightKg: nil),
            history: Fixtures.history(exerciseID: "plank")
        ))
        // A stored window topping out at twelve cannot be seconds, so the movement's own set
        // length is used: 0.6 × 60 s rounded to five, up to 60 s.
        let seconds = try #require(ProgressionEngine.prescribedSeconds(from: decision, for: hold))
        #expect(seconds == RepRange(35, 60))
        #expect(decision.recommendedWeightKg == nil)

        // The same accessor refuses to reinterpret a rep range as seconds.
        let repDecision = ProgressionEngine.decide(input(
            barbellCompound(),
            state: state(),
            history: history(sessions: [Fixtures.repSets(3, weightKg: 60, reps: 10)])
        ))
        #expect(ProgressionEngine.prescribedSeconds(from: repDecision, for: barbellCompound()) == nil)
    }

    @Test("A hold that reaches the top of its window earns more time")
    func timedMovementExtendsItsWindow() {
        let sets = (0..<3).map { _ in Fixtures.set(durationSeconds: 60) }
        let decision = ProgressionEngine.decide(input(
            plank(),
            state: state(exerciseID: "plank", weightKg: nil, repRange: RepRange(35, 60)),
            history: history(exerciseID: "plank", sessions: [sets])
        ))
        #expect(decision.action == .addReps)
        #expect(decision.recommendedRepRange == RepRange(45, 70))
    }

    @Test("A three-minute plank is outgrown, and never becomes a fourth three-minute plank")
    func holdsNeverAddASetAtTheirCeiling() {
        let sets = (0..<3).map { _ in Fixtures.set(durationSeconds: 180) }
        let decision = ProgressionEngine.decide(input(
            plank(),
            state: state(exerciseID: "plank", weightKg: nil, repRange: RepRange(170, 180)),
            history: history(exerciseID: "plank", sessions: [sets])
        ))
        #expect(decision.action == .maintain)
        #expect(decision.recommendedSets == 3)
        #expect(decision.explanation.key == "progression.explain.outgrownDuration")
    }

    @Test("A loaded carry at its two-minute ceiling earns weight instead of more time")
    func carryEarnsWeightAtItsCeiling() {
        let sets = (0..<3).map { _ in Fixtures.set(weightKg: 20, durationSeconds: 120) }
        let decision = ProgressionEngine.decide(input(
            farmersCarry(),
            state: state(exerciseID: "carry", weightKg: 20, repRange: RepRange(110, 120)),
            history: history(exerciseID: "carry", sessions: [sets])
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.recommendedWeightKg == 22.5)
        // The clock restarts from the movement's own starting window.
        #expect(decision.recommendedRepRange == RepRange(25, 45))
    }

    // MARK: - Counters across a sequence

    @Test("Successes, stalls and regressions each count only their own kind of session")
    func countersTrackASequenceOfSessions() {
        let exercise = barbellCompound()
        let top = Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)
        let inside = Fixtures.repSets(3, weightKg: 62.5, reps: 10, rir: 2)
        let short = Fixtures.repSets(3, weightKg: 62.5, reps: 6, rir: 0)

        // One qualifying session banks a success.
        var current = state()
        var decision = ProgressionEngine.decide(input(
            exercise, state: current, history: history(sessions: [top])
        ))
        #expect(decision.updatedState.consecutiveSuccesses == 1)

        // The second takes the load and clears every counter.
        current = decision.updatedState
        decision = ProgressionEngine.decide(input(
            exercise, state: current, history: history(sessions: [top, top])
        ))
        #expect(decision.action == .increaseLoad)
        #expect(decision.updatedState.consecutiveSuccesses == 0)
        #expect(decision.updatedState.consecutiveStalls == 0)
        #expect(decision.updatedState.consecutiveRegressions == 0)

        // Inside the range with no improvement on the previous session is a stall, and stalls add up.
        current = decision.updatedState
        for expected in 1...3 {
            decision = ProgressionEngine.decide(input(
                exercise, state: current, history: history(sessions: [inside, inside])
            ))
            #expect(decision.action == .addReps)
            #expect(
                decision.updatedState.consecutiveStalls == expected,
                "expected \(expected) stalls, got \(decision.updatedState.consecutiveStalls)"
            )
            current = decision.updatedState
        }

        // Short of the bottom is a regression, and it does not inherit the stall count.
        decision = ProgressionEngine.decide(input(
            exercise, state: current, history: history(sessions: [short, inside])
        ))
        #expect(decision.action == .maintain)
        #expect(decision.updatedState.consecutiveRegressions == 1)
        #expect(decision.updatedState.consecutiveStalls == 0)

        // A second short session cuts the load and clears everything again.
        current = decision.updatedState
        decision = ProgressionEngine.decide(input(
            exercise, state: current, history: history(sessions: [short, short])
        ))
        #expect(decision.action == .reduceLoad)
        #expect(decision.updatedState.consecutiveRegressions == 0)
        #expect(decision.updatedState.consecutiveSuccesses == 0)
        #expect(decision.updatedState.consecutiveStalls == 0)
    }

    // MARK: - The product spec's worked scenario

    @Test("Session one banks, session two adds 2.5 kg, session three holds the new load")
    func threeSessionScenarioFromTheProductSpec() {
        // "Increased your bench press from 60 to 62.5 kg because you completed 3×12 twice with at
        // least 2 reps in reserve."
        let bench = barbellCompound()
        let sessionOne = Fixtures.performance(
            date: Fixtures.day(-4), exerciseID: bench.id,
            sets: Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)
        )
        let sessionTwo = Fixtures.performance(
            date: Fixtures.day(-2), exerciseID: bench.id,
            sets: Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)
        )

        let afterOne = ProgressionEngine.decide(input(
            bench,
            state: state(),
            history: Fixtures.history(exerciseID: bench.id, performances: [sessionOne])
        ))
        #expect(afterOne.action == .addReps)
        #expect(afterOne.recommendedWeightKg == 60)
        #expect(afterOne.updatedState.consecutiveSuccesses == 1)

        let afterTwo = ProgressionEngine.decide(input(
            bench,
            state: afterOne.updatedState,
            history: Fixtures.history(exerciseID: bench.id, performances: [sessionTwo, sessionOne])
        ))
        #expect(afterTwo.action == .increaseLoad)
        #expect(afterTwo.recommendedWeightKg == 62.5)
        #expect(afterTwo.explanation.key == "progression.explain.increasedLoad")
        // The explanation quotes the real numbers: name, old load, new load, sessions, sets, reps, RIR.
        #expect(afterTwo.explanation.arguments.contains("60 kg"))
        #expect(afterTwo.explanation.arguments.contains("62.5 kg"))

        // Session three is performed at the new load, at the bottom of the range, and holds it.
        let sessionThree = Fixtures.performance(
            date: Fixtures.day(0), exerciseID: bench.id,
            sets: Fixtures.repSets(3, weightKg: 62.5, reps: 8, rir: 2)
        )
        let afterThree = ProgressionEngine.decide(input(
            bench,
            state: afterTwo.updatedState,
            history: Fixtures.history(
                exerciseID: bench.id, performances: [sessionThree, sessionTwo, sessionOne]
            )
        ))
        #expect(afterThree.action == .addReps)
        #expect(afterThree.recommendedWeightKg == 62.5)
        #expect(afterThree.explanation.key == "progression.explain.addReps")
    }

    // MARK: - Determinism

    @Test("Identical input always produces an identical decision")
    func decisionsAreDeterministic() {
        let request = input(
            barbellCompound(),
            state: state(successes: 1),
            history: history(sessions: [
                Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2),
                Fixtures.repSets(3, weightKg: 60, reps: 12, rir: 2)
            ])
        )
        let first = ProgressionEngine.decide(request)
        for _ in 0..<20 {
            #expect(ProgressionEngine.decide(request) == first)
        }
    }
}
