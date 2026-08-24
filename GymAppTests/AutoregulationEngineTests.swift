import Foundation
import Testing

@testable import GymApp

// MARK: - Fixtures
//
// File-private so nothing collides with sibling test files. The engine is time-free, so the one
// fixed date below exists only to give the value types something reproducible to hold.

private let autoregNow = Date(timeIntervalSince1970: 1_750_000_000)

private func autoregUUID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
}

private func makeMetadata(
    difficulty: Difficulty = .beginner,
    loadability: Loadability = .barbell,
    fatigueCost: Double = 0.6,
    estimatedSetSeconds: Int = 45,
    volumeContribution: [MuscleGroup: Double]
) -> ExerciseMetadata {
    ExerciseMetadata(
        movementPattern: .horizontalPush,
        pushPull: .push,
        mechanic: .compound,
        difficulty: difficulty,
        laterality: .bilateral,
        loadability: loadability,
        trackingMode: .weightAndReps,
        stabilityDemand: 0.3,
        fatigueCost: fatigueCost,
        stimulusScore: 0.7,
        progressionSuitability: 0.8,
        recommendedRepRange: .hypertrophy,
        defaultRestSeconds: 90,
        estimatedSetSeconds: estimatedSetSeconds,
        isStretch: false,
        isPlyometric: false,
        isWarmupCandidate: false,
        volumeContribution: volumeContribution,
        substitutionTags: [],
        stapleScore: 0.5
    )
}

private func makeExercise(
    id: String,
    name: String,
    target: Muscle = .pectorals,
    difficulty: Difficulty = .beginner,
    loadability: Loadability = .barbell,
    fatigueCost: Double = 0.6,
    estimatedSetSeconds: Int = 45,
    volumeContribution: [MuscleGroup: Double]? = nil
) -> Exercise {
    Exercise(
        id: id,
        name: name,
        bodyPart: .chest,
        equipment: .barbell,
        target: target,
        synergist: nil,
        secondaryMuscles: [],
        mediaID: id,
        thumbnailFileName: "\(id).png",
        animationFileName: "\(id).gif",
        attribution: "test fixture",
        createdAt: Date(timeIntervalSince1970: 0),
        metadata: makeMetadata(
            difficulty: difficulty,
            loadability: loadability,
            fatigueCost: fatigueCost,
            estimatedSetSeconds: estimatedSetSeconds,
            volumeContribution: volumeContribution ?? [target.group: 1.0]
        )
    )
}

private let bench = makeExercise(id: "bench", name: "Barbell Bench Press")
private let fly = makeExercise(id: "fly", name: "Cable Fly", fatigueCost: 0.3)
private let squat = makeExercise(id: "squat", name: "Barbell Squat", target: .quads, fatigueCost: 0.9)
private let row = makeExercise(id: "row", name: "Barbell Row", target: .lats, fatigueCost: 0.7)
private let pullUp = makeExercise(
    id: "pullup", name: "Pull-up", target: .lats, difficulty: .advanced, loadability: .bodyweight
)

private let catalog: [String: Exercise] = Dictionary(
    uniqueKeysWithValues: [bench, fly, squat, row, pullUp].map { ($0.id, $0) }
)

private func makeSet(
    reps: Int?,
    target: Int? = 10,
    weight: Double? = 100,
    completed: Bool = true,
    kind: SetKind = .working
) -> PerformedSet {
    PerformedSet(
        kind: kind, weightKg: weight, reps: reps, targetReps: target, isCompleted: completed
    )
}

private func makePerformance(_ exerciseID: String, _ sets: [PerformedSet]) -> ExercisePerformance {
    ExercisePerformance(date: autoregNow, exerciseID: exerciseID, sets: sets)
}

private func makeOutcome(
    plannedSets: Int = 12,
    completedSets: Int = 12,
    substituted: [String: String] = [:],
    skipped: [String] = [],
    effort: SessionEffortFeedback? = nil,
    durationSeconds: Int = 3000,
    averageRIR: Double? = nil,
    groupSets: [MuscleGroup: Double] = [:],
    performances: [ExercisePerformance] = []
) -> SessionOutcome {
    SessionOutcome(
        sessionID: autoregUUID(1),
        date: autoregNow,
        plannedSets: plannedSets,
        completedSets: completedSets,
        skippedExerciseIDs: skipped,
        substitutedExerciseIDs: substituted,
        effortFeedback: effort,
        durationSeconds: durationSeconds,
        averageRIR: averageRIR,
        groupSets: groupSets,
        performances: performances
    )
}

private func makeTargets(
    minimum: [MuscleGroup: Double] = [:],
    target: [MuscleGroup: Double] = [:],
    maximum: [MuscleGroup: Double] = [:]
) -> VolumeTargets {
    VolumeTargets(minimum: minimum, target: target, maximum: maximum, frequency: [:])
}

private func makeProfile(
    experience: ExperienceLevel = .intermediate,
    sessionMinutesCap: Int = 60
) -> TrainingProfileSnapshot {
    var profile = TrainingProfileSnapshot()
    profile.experience = experience
    profile.sessionMinutesCap = sessionMinutesCap
    return profile
}

private func adjustments(
    outcome: SessionOutcome,
    recovery: RecoverySnapshot = .fresh,
    targets: VolumeTargets = VolumeTargets(minimum: [:], target: [:], maximum: [:], frequency: [:]),
    profile: TrainingProfileSnapshot? = nil
) -> [AutoregulationAdjustment] {
    AutoregulationEngine.adjustments(
        after: outcome,
        recovery: recovery,
        targets: targets,
        profile: profile ?? makeProfile(),
        catalog: catalog
    )
}

private func makeGeneratedExercise(
    _ exerciseID: String,
    orderIndex: Int = 0,
    sets: Int = 3,
    restSeconds: Int = 90,
    isLocked: Bool = false
) -> GeneratedExercise {
    GeneratedExercise(
        exerciseID: exerciseID,
        orderIndex: orderIndex,
        sets: sets,
        repRange: .hypertrophy,
        restSeconds: restSeconds,
        targetRIR: 2,
        isLocked: isLocked
    )
}

private func makeSession(
    estimatedMinutes: Int = 60,
    isRestDay: Bool = false,
    exercises: [GeneratedExercise]
) -> GeneratedSession {
    GeneratedSession(
        id: autoregUUID(50),
        orderIndex: 0,
        titleKey: "session.test",
        focusGroups: [.chest],
        pushPull: .push,
        estimatedMinutes: estimatedMinutes,
        isRestDay: isRestDay,
        exercises: exercises
    )
}

private func makeAdjustment(
    _ kind: AutoregulationAdjustment.Kind,
    exerciseID: String? = nil,
    muscleGroup: MuscleGroup? = nil,
    magnitude: Double
) -> AutoregulationAdjustment {
    AutoregulationAdjustment(
        id: autoregUUID(90),
        kind: kind,
        exerciseID: exerciseID,
        muscleGroup: muscleGroup,
        magnitude: magnitude,
        explanation: Explanation("test.adjustment")
    )
}

// MARK: - Load reductions

@Suite("Badly missed reps take the load down")
struct AutoregulationLoadReductionTests {

    @Test("Missing every rep target by a wide margin cuts the load by ten per cent")
    func everySetBadlyMissedEarnsTheSevereCut() throws {
        let outcome = makeOutcome(
            performances: [makePerformance("bench", [makeSet(reps: 6), makeSet(reps: 6), makeSet(reps: 6)])]
        )
        let result = adjustments(outcome: outcome)

        #expect(result.count == 1)
        let cut = try #require(result.first)
        #expect(cut.kind == .reduceLoad)
        #expect(cut.exerciseID == "bench")
        #expect(cut.muscleGroup == .chest)
        #expect(cut.magnitude == AutoregulationTuning.severeLoadCut)
        #expect(cut.explanation.key == "autoreg.reduceLoad.severe")
        #expect(cut.explanation.arguments == [bench.name])
    }

    @Test("Missing half the sets cuts the load by five per cent")
    func halfTheSetsMissedEarnsTheModerateCut() throws {
        let outcome = makeOutcome(
            performances: [
                makePerformance("bench", [
                    makeSet(reps: 7), makeSet(reps: 7), makeSet(reps: 10), makeSet(reps: 10)
                ])
            ]
        )
        let result = adjustments(outcome: outcome)

        #expect(result.count == 1)
        let cut = try #require(result.first)
        #expect(cut.kind == .reduceLoad)
        #expect(cut.magnitude == AutoregulationTuning.moderateLoadCut)
        #expect(cut.explanation.key == "autoreg.reduceLoad")
    }

    @Test("One rep short on a single set is a normal day, not a load cut")
    func oneRepShortIsNotAMiss() {
        let outcome = makeOutcome(
            performances: [makePerformance("bench", [makeSet(reps: 9), makeSet(reps: 10), makeSet(reps: 10)])]
        )
        #expect(adjustments(outcome: outcome).map(\.kind) == [.noChange])
    }

    @Test("An unfinished set counts as badly missed")
    func unfinishedSetsCountAsMissed() {
        let outcome = makeOutcome(
            performances: [
                makePerformance("bench", [
                    makeSet(reps: 10), makeSet(reps: nil, completed: false), makeSet(reps: nil, completed: false)
                ])
            ]
        )
        #expect(adjustments(outcome: outcome).first?.kind == .reduceLoad)
    }

    @Test("A single rated set is not enough evidence to change the load")
    func oneRatedSetIsNotEnoughEvidence() {
        let outcome = makeOutcome(performances: [makePerformance("bench", [makeSet(reps: 2)])])
        #expect(adjustments(outcome: outcome).map(\.kind) == [.noChange])
    }

    @Test("Sets with no rep target are not judged at all")
    func setsWithoutATargetAreIgnored() {
        let outcome = makeOutcome(
            performances: [
                makePerformance("bench", [
                    makeSet(reps: 2, target: nil), makeSet(reps: 2, target: nil), makeSet(reps: 2, target: nil)
                ])
            ]
        )
        #expect(adjustments(outcome: outcome).map(\.kind) == [.noChange])
    }

    @Test("A rep target of zero cannot divide the miss fraction")
    func zeroRepTargetIsIgnored() {
        let outcome = makeOutcome(
            performances: [
                makePerformance("bench", [
                    makeSet(reps: 0, target: 0), makeSet(reps: 0, target: 0), makeSet(reps: 0, target: 0)
                ])
            ]
        )
        #expect(adjustments(outcome: outcome).map(\.kind) == [.noChange])
    }

    @Test("Warm-up sets never drive a load change")
    func warmupSetsAreNotCounted() {
        let outcome = makeOutcome(
            performances: [
                makePerformance("bench", [
                    makeSet(reps: 2, kind: .warmup), makeSet(reps: 2, kind: .warmup), makeSet(reps: 2, kind: .warmup)
                ])
            ]
        )
        #expect(adjustments(outcome: outcome).map(\.kind) == [.noChange])
    }

    @Test("Taking load off a movement that carries none is not proposed")
    func bodyweightMovementsNeverGetALoadCut() throws {
        let outcome = makeOutcome(
            performances: [
                makePerformance("pullup", [
                    makeSet(reps: 4, weight: nil), makeSet(reps: 4, weight: nil), makeSet(reps: 4, weight: nil)
                ])
            ]
        )
        let result = adjustments(outcome: outcome)

        #expect(!result.contains { $0.kind == .reduceLoad })
        let swap = try #require(result.first)
        #expect(swap.kind == .swapExercise)
        #expect(swap.exerciseID == "pullup")
        #expect(swap.explanation.key == "autoreg.swap.failed")
    }

    @Test("An exercise the catalogue does not know is never named in a proposal")
    func unknownExercisesAreDroppedRatherThanNamedByID() {
        let outcome = makeOutcome(
            performances: [makePerformance("0025", [makeSet(reps: 4), makeSet(reps: 4), makeSet(reps: 4)])]
        )
        #expect(adjustments(outcome: outcome).map(\.kind) == [.noChange])
    }

    @Test("Sets of the same exercise are aggregated so it can only be lightened once")
    func loadCutsAreAggregatedPerExercise() {
        let outcome = makeOutcome(
            performances: [
                makePerformance("bench", [makeSet(reps: 6), makeSet(reps: 6)]),
                makePerformance("bench", [makeSet(reps: 6), makeSet(reps: 6)])
            ]
        )
        #expect(adjustments(outcome: outcome).filter { $0.kind == .reduceLoad }.count == 1)
    }
}

// MARK: - Rest versus load

@Suite("Rest is changed where the load is evidently right")
struct AutoregulationRestTests {

    @Test("Reps falling away after a good first set buys rest, not a lighter bar")
    func dropOffAfterAGoodFirstSetEarnsRestNotALoadCut() throws {
        let outcome = makeOutcome(
            performances: [makePerformance("bench", [makeSet(reps: 10), makeSet(reps: 8), makeSet(reps: 5)])]
        )
        let result = adjustments(outcome: outcome)

        #expect(!result.contains { $0.kind == .reduceLoad })
        #expect(result.count == 1)
        let rest = try #require(result.first)
        #expect(rest.kind == .restLonger)
        #expect(rest.exerciseID == "bench")
        #expect(rest.magnitude == AutoregulationTuning.extraRestSeconds)
        #expect(rest.explanation.key == "autoreg.restLonger")
        #expect(rest.explanation.arguments == [bench.name])
    }

    @Test("An exercise never gets a load cut and a rest change in the same session")
    func loadCutSuppressesTheRestChange() {
        // Even the first set fell short, so the load is the problem.
        let outcome = makeOutcome(
            performances: [makePerformance("bench", [makeSet(reps: 6), makeSet(reps: 5), makeSet(reps: 2)])]
        )
        let result = adjustments(outcome: outcome)
        #expect(result.contains { $0.kind == .reduceLoad })
        #expect(!result.contains { $0.kind == .restLonger })
    }

    @Test("Reps falling away because the load fell away is not a rest problem")
    func aDroppingLoadExplainsTheReps() {
        let outcome = makeOutcome(
            performances: [
                makePerformance("bench", [
                    makeSet(reps: 10, weight: 100), makeSet(reps: 8, weight: 80), makeSet(reps: 4, weight: 60)
                ])
            ]
        )
        #expect(!adjustments(outcome: outcome).contains { $0.kind == .restLonger })
    }

    @Test("Two sets are too few to call it a drop-off")
    func twoSetsAreNotADropOff() {
        let outcome = makeOutcome(
            performances: [makePerformance("bench", [makeSet(reps: 12, target: 8), makeSet(reps: 4, target: 8)])]
        )
        #expect(!adjustments(outcome: outcome).contains { $0.kind == .restLonger })
    }

    @Test("At most two rest changes come out of one session")
    func restChangesAreCappedAtTwo() {
        let dropOff = [makeSet(reps: 10), makeSet(reps: 8), makeSet(reps: 5)]
        let outcome = makeOutcome(
            performances: [
                makePerformance("bench", dropOff),
                makePerformance("fly", dropOff),
                makePerformance("row", dropOff)
            ]
        )
        #expect(adjustments(outcome: outcome).filter { $0.kind == .restLonger }.count
            == AutoregulationTuning.maximumRestSuggestions)
    }
}

// MARK: - Set removal

@Suite("High fatigue takes a set off")
struct AutoregulationSetRemovalTests {

    @Test("A group carrying serious fatigue loses one set")
    func highFatigueRemovesASet() throws {
        let recovery = RecoverySnapshot(fatigue: [.quads: 0.80], weeklySets: [.quads: 12])
        let outcome = makeOutcome(groupSets: [.quads: 6])
        let result = adjustments(
            outcome: outcome, recovery: recovery, targets: makeTargets(minimum: [.quads: 8])
        )

        #expect(result.count == 1)
        let removal = try #require(result.first)
        #expect(removal.kind == .removeSet)
        #expect(removal.muscleGroup == .quads)
        #expect(removal.magnitude == 1)
        #expect(removal.explanation.key == "autoreg.removeSet.fatigue")
    }

    @Test("Fatigue just below the threshold takes nothing off")
    func fatigueBelowTheThresholdRemovesNothing() {
        let recovery = RecoverySnapshot(fatigue: [.quads: 0.74], weeklySets: [.quads: 12])
        let result = adjustments(
            outcome: makeOutcome(groupSets: [.quads: 6]),
            recovery: recovery,
            targets: makeTargets(minimum: [.quads: 8])
        )
        #expect(result.map(\.kind) == [.noChange])
    }

    @Test("A set is never removed from a group already at its weekly minimum")
    func removalNeverBreachesTheWeeklyMinimum() {
        let recovery = RecoverySnapshot(fatigue: [.quads: 0.95], weeklySets: [.quads: 12])
        let result = adjustments(
            outcome: makeOutcome(groupSets: [.quads: 6]),
            recovery: recovery,
            targets: makeTargets(minimum: [.quads: 12])
        )
        #expect(result.map(\.kind) == [.noChange])
    }

    @Test("Only the single most fatigued group loses a set")
    func onlyOneGroupLosesASet() throws {
        let recovery = RecoverySnapshot(
            fatigue: [.quads: 0.80, .chest: 0.90], weeklySets: [.quads: 12, .chest: 12]
        )
        let result = adjustments(
            outcome: makeOutcome(groupSets: [.quads: 6, .chest: 6]),
            recovery: recovery,
            targets: makeTargets(minimum: [.quads: 8, .chest: 8])
        )
        let removals = result.filter { $0.kind == .removeSet }
        #expect(removals.count == 1)
        #expect(try #require(removals.first).muscleGroup == .chest)
    }

    @Test("A group the session did not train is never the one that loses a set")
    func untrainedGroupsAreNotTouched() {
        let recovery = RecoverySnapshot(fatigue: [.hamstrings: 0.95], weeklySets: [.hamstrings: 12])
        let result = adjustments(
            outcome: makeOutcome(groupSets: [.quads: 6]),
            recovery: recovery,
            targets: makeTargets(minimum: [.hamstrings: 4])
        )
        #expect(result.map(\.kind) == [.noChange])
    }
}

// MARK: - Set additions

@Suite("An easy session under target adds volume, carefully")
struct AutoregulationSetAdditionTests {

    private let easyRecovery = RecoverySnapshot(fatigue: [.chest: 0.2], weeklySets: [.chest: 8])

    @Test("An easy session below the weekly target adds exactly one set")
    func easySessionAddsOneSet() throws {
        let result = adjustments(
            outcome: makeOutcome(effort: .easy, groupSets: [.chest: 4]),
            recovery: easyRecovery,
            targets: makeTargets(target: [.chest: 14], maximum: [.chest: 20])
        )

        #expect(result.count == 1)
        let addition = try #require(result.first)
        #expect(addition.kind == .addSet)
        #expect(addition.muscleGroup == .chest)
        #expect(addition.magnitude == 1)
        #expect(addition.explanation.key == "autoreg.addSet")
    }

    @Test("Generous reps in reserve reads as easy even without a session rating")
    func generousRepsInReserveReadsAsEasy() {
        // Intermediate default target is 2 reps in reserve; 3.5 clears the 1.5 margin.
        let result = adjustments(
            outcome: makeOutcome(averageRIR: 3.5, groupSets: [.chest: 4]),
            recovery: easyRecovery,
            targets: makeTargets(target: [.chest: 14], maximum: [.chest: 20])
        )
        #expect(result.map(\.kind) == [.addSet])
    }

    @Test("Reps in reserve just inside the margin is not an easy session")
    func repsInReserveInsideTheMarginIsNotEasy() {
        let result = adjustments(
            outcome: makeOutcome(averageRIR: 3.49, groupSets: [.chest: 4]),
            recovery: easyRecovery,
            targets: makeTargets(target: [.chest: 14], maximum: [.chest: 20])
        )
        #expect(result.map(\.kind) == [.noChange])
    }

    @Test("A session the user called hard never adds volume, however generous the ratings look")
    func aSessionCalledHardNeverAddsVolume() {
        for verdict in [SessionEffortFeedback.hard, .exhausting] {
            let result = adjustments(
                outcome: makeOutcome(effort: verdict, averageRIR: 5, groupSets: [.chest: 4]),
                recovery: easyRecovery,
                targets: makeTargets(target: [.chest: 14], maximum: [.chest: 20])
            )
            #expect(!result.contains { $0.kind == .addSet })
        }
    }

    @Test("Volume is not added after a session the user did not finish")
    func unfinishedSessionsNeverAddVolume() {
        let result = adjustments(
            outcome: makeOutcome(plannedSets: 12, completedSets: 11, effort: .easy, groupSets: [.chest: 4]),
            recovery: easyRecovery,
            targets: makeTargets(target: [.chest: 14], maximum: [.chest: 20])
        )
        #expect(result.map(\.kind) == [.noChange])
    }

    @Test("A group already at its weekly target finds the room taken")
    func aGroupAtTargetGainsNothing() {
        let atTarget = RecoverySnapshot(fatigue: [.chest: 0.2], weeklySets: [.chest: 13.5])
        let result = adjustments(
            outcome: makeOutcome(effort: .easy, groupSets: [.chest: 4]),
            recovery: atTarget,
            targets: makeTargets(target: [.chest: 14], maximum: [.chest: 20])
        )
        #expect(result.map(\.kind) == [.noChange])
    }

    @Test("The set that lands exactly on the target is still allowed")
    func theSetThatLandsOnTargetIsAllowed() {
        let justUnder = RecoverySnapshot(fatigue: [.chest: 0.2], weeklySets: [.chest: 13])
        let result = adjustments(
            outcome: makeOutcome(effort: .easy, groupSets: [.chest: 4]),
            recovery: justUnder,
            targets: makeTargets(target: [.chest: 14], maximum: [.chest: 20])
        )
        #expect(result.map(\.kind) == [.addSet])
    }

    @Test("The ceiling binds when it sits below the target")
    func theMaximumBindsBelowTheTarget() {
        let result = adjustments(
            outcome: makeOutcome(effort: .easy, groupSets: [.chest: 4]),
            recovery: easyRecovery,
            targets: makeTargets(target: [.chest: 20], maximum: [.chest: 8])
        )
        #expect(result.map(\.kind) == [.noChange])
    }

    @Test("Volume only goes on a group that is genuinely recovered")
    func fatiguedGroupsGainNothing() {
        let borderline = RecoverySnapshot(fatigue: [.chest: 0.45], weeklySets: [.chest: 8])
        let tired = RecoverySnapshot(fatigue: [.chest: 0.46], weeklySets: [.chest: 8])
        let targets = makeTargets(target: [.chest: 14], maximum: [.chest: 20])

        #expect(adjustments(
            outcome: makeOutcome(effort: .easy, groupSets: [.chest: 4]),
            recovery: borderline, targets: targets
        ).map(\.kind) == [.addSet])
        #expect(adjustments(
            outcome: makeOutcome(effort: .easy, groupSets: [.chest: 4]),
            recovery: tired, targets: targets
        ).map(\.kind) == [.noChange])
    }

    @Test("A group with no weekly target never gains a set")
    func aGroupWithNoTargetGainsNothing() {
        let result = adjustments(
            outcome: makeOutcome(effort: .easy, groupSets: [.chest: 4]),
            recovery: easyRecovery,
            targets: makeTargets()
        )
        #expect(result.map(\.kind) == [.noChange])
    }

    @Test("At most two groups gain a set, one each")
    func atMostTwoGroupsGainASet() {
        let recovery = RecoverySnapshot(
            fatigue: [:], weeklySets: [.chest: 4, .quads: 4, .back: 4, .biceps: 4]
        )
        let targets = makeTargets(
            target: [.chest: 14, .quads: 14, .back: 14, .biceps: 14],
            maximum: [.chest: 20, .quads: 20, .back: 20, .biceps: 20]
        )
        let outcome = makeOutcome(
            effort: .easy, groupSets: [.chest: 4, .quads: 4, .back: 4, .biceps: 4]
        )
        let additions = adjustments(outcome: outcome, recovery: recovery, targets: targets)
            .filter { $0.kind == .addSet }

        #expect(additions.count == AutoregulationTuning.maximumAddSetGroups)
        #expect(Set(additions.compactMap(\.muscleGroup)).count == additions.count)
        #expect(additions.allSatisfy { $0.magnitude == 1 })
    }
}

// MARK: - Swaps

@Suite("Swap suggestions")
struct AutoregulationSwapTests {

    @Test("An exercise the user replaced mid-session is proposed for a permanent swap")
    func substitutedExerciseIsProposedForSwap() throws {
        let outcome = makeOutcome(substituted: ["bench": "fly"])
        let result = adjustments(outcome: outcome)

        #expect(result.count == 1)
        let swap = try #require(result.first)
        #expect(swap.kind == .swapExercise)
        #expect(swap.exerciseID == "bench")
        #expect(swap.magnitude == 0)
        #expect(swap.explanation.key == "autoreg.swap.substituted")
        #expect(swap.explanation.arguments == [bench.name])
    }

    @Test("An exercise lightened this session is never also proposed for replacement")
    func lightenedExercisesAreNotAlsoSwapped() {
        let outcome = makeOutcome(
            performances: [makePerformance("bench", [makeSet(reps: 4), makeSet(reps: 4), makeSet(reps: 4)])]
        )
        let result = adjustments(outcome: outcome)
        #expect(result.contains { $0.kind == .reduceLoad })
        #expect(!result.contains { $0.kind == .swapExercise })
    }

    @Test("An unloadable exercise that failed on every set is swapped whatever the user's experience")
    func failingUnloadableExerciseIsSwappedForEveryExperienceLevel() {
        let outcome = makeOutcome(
            performances: [
                makePerformance("pullup", [
                    makeSet(reps: 3, weight: nil), makeSet(reps: 3, weight: nil), makeSet(reps: 3, weight: nil)
                ])
            ]
        )
        for experience in [ExperienceLevel.beginner, .advanced] {
            let result = adjustments(outcome: outcome, profile: makeProfile(experience: experience))
            #expect(result.contains { $0.kind == .swapExercise && $0.exerciseID == "pullup" })
        }
    }

    @Test("A loadable exercise that failed on every set is lightened, not replaced")
    func failingLoadableExerciseIsLightenedRatherThanReplaced() {
        // Taking weight off is the gentler fix and deserves a session to work, so it wins even for
        // a movement the user should arguably not be programmed at all.
        let outcome = makeOutcome(
            performances: [makePerformance("squat", [makeSet(reps: 3), makeSet(reps: 3), makeSet(reps: 3)])]
        )
        let result = adjustments(outcome: outcome, profile: makeProfile(experience: .beginner))
        #expect(result.contains { $0.kind == .reduceLoad && $0.exerciseID == "squat" })
        #expect(!result.contains { $0.kind == .swapExercise })
    }

    @Test("At most two swaps are suggested from one session")
    func swapsAreCappedAtTwo() {
        let outcome = makeOutcome(substituted: ["bench": "x", "fly": "y", "row": "z", "squat": "w"])
        #expect(adjustments(outcome: outcome).filter { $0.kind == .swapExercise }.count
            == AutoregulationTuning.maximumSwapSuggestions)
    }

    @Test("A substituted exercise the catalogue does not know is silently dropped")
    func unknownSubstitutedExerciseIsDropped() {
        #expect(adjustments(outcome: makeOutcome(substituted: ["9999": "x"])).map(\.kind) == [.noChange])
    }
}

// MARK: - Session length

@Suite("An overrunning session is trimmed")
struct AutoregulationSessionTrimTests {

    @Test("A session thirty minutes past the cap is trimmed by the fifteen-minute maximum")
    func longOverrunIsTrimmedAtTheCeiling() throws {
        let outcome = makeOutcome(durationSeconds: 5400)
        let result = adjustments(outcome: outcome, profile: makeProfile(sessionMinutesCap: 60))

        #expect(result.count == 1)
        let trim = try #require(result.first)
        #expect(trim.kind == .shortenSession)
        #expect(trim.magnitude == AutoregulationTuning.maximumTrimMinutes)
        #expect(trim.explanation.key == "autoreg.shortenSession")
        // The sentence reports the overrun, not the trim.
        #expect(trim.explanation.arguments == ["30"])
    }

    @Test("A session inside the fifteen per cent tolerance is left alone")
    func smallOverrunsAreToleratedAsTimingNoise() {
        #expect(adjustments(
            outcome: makeOutcome(durationSeconds: 4140), profile: makeProfile(sessionMinutesCap: 60)
        ).map(\.kind) == [.noChange])
    }

    @Test("A session just past the tolerance is trimmed by the overrun itself")
    func modestOverrunIsTrimmedExactly() throws {
        let result = adjustments(
            outcome: makeOutcome(durationSeconds: 4200), profile: makeProfile(sessionMinutesCap: 60)
        )
        let trim = try #require(result.first)
        #expect(trim.kind == .shortenSession)
        #expect(trim.magnitude == 10)
        #expect(trim.explanation.arguments == ["10"])
    }

    @Test("A session cap of zero does not divide by zero")
    func zeroSessionCapIsHandled() {
        let result = adjustments(
            outcome: makeOutcome(durationSeconds: 30), profile: makeProfile(sessionMinutesCap: 0)
        )
        #expect(result.map(\.kind) == [.noChange])
    }

    @Test("An overrun that rounds to under a minute is not worth proposing")
    func subMinuteOverrunsAreNotProposed() {
        let result = adjustments(
            outcome: makeOutcome(durationSeconds: 70), profile: makeProfile(sessionMinutesCap: 1)
        )
        #expect(result.map(\.kind) == [.noChange])
    }

    @Test("A session of zero length is never trimmed")
    func zeroLengthSessionIsNotTrimmed() {
        #expect(adjustments(outcome: makeOutcome(durationSeconds: 0)).map(\.kind) == [.noChange])
    }
}

// MARK: - Nothing to say

@Suite("Nothing notable")
struct AutoregulationNoChangeTests {

    @Test("A session that went to plan returns a single noChange")
    func anUneventfulSessionReturnsNoChange() throws {
        let outcome = makeOutcome(
            effort: .good,
            groupSets: [.chest: 4],
            performances: [makePerformance("bench", [makeSet(reps: 10), makeSet(reps: 10), makeSet(reps: 10)])]
        )
        let result = adjustments(outcome: outcome)

        #expect(result.count == 1)
        let only = try #require(result.first)
        #expect(only.kind == .noChange)
        #expect(only.magnitude == 0)
        #expect(only.explanation.key == "autoreg.noChange")
        #expect(only.exerciseID == nil)
        #expect(only.muscleGroup == nil)
    }

    @Test("An empty session returns noChange rather than an empty list")
    func anEmptySessionReturnsNoChange() {
        #expect(adjustments(outcome: makeOutcome(plannedSets: 0, completedSets: 0)).map(\.kind) == [.noChange])
    }

    @Test("Identical inputs produce identical proposals, ids included")
    func proposalsAreDeterministic() {
        let outcome = makeOutcome(
            substituted: ["row": "fly"],
            effort: .easy,
            durationSeconds: 5400,
            groupSets: [.chest: 4, .quads: 6],
            performances: [makePerformance("bench", [makeSet(reps: 5), makeSet(reps: 5), makeSet(reps: 5)])]
        )
        let recovery = RecoverySnapshot(
            fatigue: [.quads: 0.9, .chest: 0.2], weeklySets: [.quads: 12, .chest: 8]
        )
        let targets = makeTargets(
            minimum: [.quads: 8], target: [.chest: 14], maximum: [.chest: 20]
        )

        let first = adjustments(outcome: outcome, recovery: recovery, targets: targets)
        let second = adjustments(outcome: outcome, recovery: recovery, targets: targets)
        #expect(first == second)
        #expect(Set(first.map(\.id)).count == first.count)
    }

    @Test("Safety-relevant proposals come first and the list is capped at six")
    func proposalsAreOrderedAndCapped() {
        let outcome = makeOutcome(
            substituted: ["row": "x", "squat": "y"],
            durationSeconds: 5400,
            groupSets: [.chest: 6, .quads: 6],
            performances: [
                makePerformance("bench", [makeSet(reps: 5), makeSet(reps: 5), makeSet(reps: 5)]),
                makePerformance("fly", [makeSet(reps: 5), makeSet(reps: 5), makeSet(reps: 5)])
            ]
        )
        let recovery = RecoverySnapshot(fatigue: [.quads: 0.9], weeklySets: [.quads: 12])
        let result = adjustments(
            outcome: outcome, recovery: recovery, targets: makeTargets(minimum: [.quads: 8])
        )

        #expect(result.count == AutoregulationTuning.maximumAdjustments)
        #expect(result.map(\.kind) == [
            .reduceLoad, .reduceLoad, .removeSet, .shortenSession, .swapExercise, .swapExercise
        ])
    }
}

// MARK: - apply

@Suite("apply changes only what a session plan can express")
struct AutoregulationApplyTests {

    @Test("A locked exercise is never touched, for any reason")
    func lockedExercisesAreNeverTouched() {
        let session = makeSession(exercises: [makeGeneratedExercise("bench", sets: 4, isLocked: true)])
        let result = AutoregulationEngine.apply(
            [
                makeAdjustment(.removeSet, muscleGroup: .chest, magnitude: 1),
                makeAdjustment(.addSet, muscleGroup: .chest, magnitude: 1),
                makeAdjustment(.restLonger, exerciseID: "bench", magnitude: 30),
                makeAdjustment(.shortenSession, magnitude: 15)
            ],
            to: session,
            catalog: catalog
        )

        #expect(result.exercises == session.exercises)
        #expect(result.estimatedMinutes == session.estimatedMinutes)
    }

    @Test("No exercise is ever reduced below one working set")
    func removalNeverGoesBelowOneSet() {
        let session = makeSession(exercises: [makeGeneratedExercise("bench", sets: 1)])
        let removals = Array(repeating: makeAdjustment(.removeSet, muscleGroup: .chest, magnitude: 1), count: 3)
        let result = AutoregulationEngine.apply(removals, to: session, catalog: catalog)

        #expect(result.exercises[0].sets == 1)
        #expect(result.estimatedMinutes == 60)
    }

    @Test("A trim never strips the last working set of an exercise")
    func trimNeverStripsTheLastSet() {
        let session = makeSession(
            estimatedMinutes: 60,
            exercises: [makeGeneratedExercise("bench", orderIndex: 0, sets: 1)]
        )
        let result = AutoregulationEngine.apply(
            [makeAdjustment(.shortenSession, magnitude: 15)], to: session, catalog: catalog
        )
        #expect(result.exercises[0].sets == 1)
    }

    @Test("At most one set is removed per exercise per call")
    func atMostOneSetPerExercisePerCall() {
        let session = makeSession(exercises: [makeGeneratedExercise("bench", sets: 4)])
        let removals = Array(repeating: makeAdjustment(.removeSet, muscleGroup: .chest, magnitude: 1), count: 3)
        let result = AutoregulationEngine.apply(removals, to: session, catalog: catalog)
        #expect(result.exercises[0].sets == 3)
    }

    @Test("At most three sets are removed across a session per call")
    func atMostThreeSetsPerSessionPerCall() {
        let session = makeSession(
            exercises: (0..<5).map { makeGeneratedExercise("bench", orderIndex: $0, sets: 4) }
        )
        let removals = Array(repeating: makeAdjustment(.removeSet, muscleGroup: .chest, magnitude: 1), count: 5)
        let result = AutoregulationEngine.apply(removals, to: session, catalog: catalog)
        #expect(result.totalSets == session.totalSets - AutoregulationTuning.maximumSetsRemovedPerSession)
    }

    @Test("A fatigue removal and a length trim cannot compound on one exercise")
    func removalAndTrimDoNotCompound() {
        let session = makeSession(exercises: [makeGeneratedExercise("bench", sets: 4)])
        let result = AutoregulationEngine.apply(
            [
                makeAdjustment(.removeSet, muscleGroup: .chest, magnitude: 1),
                makeAdjustment(.shortenSession, magnitude: 15)
            ],
            to: session,
            catalog: catalog
        )
        #expect(result.exercises[0].sets == 3)
    }

    @Test("An added set moves the estimate by exactly the time that set costs")
    func addedSetMovesTheEstimateExactly() {
        let session = makeSession(
            estimatedMinutes: 60, exercises: [makeGeneratedExercise("bench", sets: 3, restSeconds: 90)]
        )
        let result = AutoregulationEngine.apply(
            [makeAdjustment(.addSet, muscleGroup: .chest, magnitude: 1)], to: session, catalog: catalog
        )
        #expect(result.exercises[0].sets == 4)
        // 45 s of work plus 90 s of rest on a 3,600 s session.
        #expect(result.estimatedMinutes == 62)
    }

    @Test("A removed set moves the estimate by exactly the time that set cost")
    func removedSetMovesTheEstimateExactly() {
        let session = makeSession(
            estimatedMinutes: 60, exercises: [makeGeneratedExercise("bench", sets: 3, restSeconds: 90)]
        )
        let result = AutoregulationEngine.apply(
            [makeAdjustment(.removeSet, muscleGroup: .chest, magnitude: 1)], to: session, catalog: catalog
        )
        #expect(result.exercises[0].sets == 2)
        #expect(result.estimatedMinutes == 58)
    }

    @Test("Longer rest is paid by every set after the first")
    func restExtensionCostsEverySetAfterTheFirst() {
        let session = makeSession(
            estimatedMinutes: 60, exercises: [makeGeneratedExercise("bench", sets: 3, restSeconds: 90)]
        )
        let result = AutoregulationEngine.apply(
            [makeAdjustment(.restLonger, exerciseID: "bench", magnitude: 30)], to: session, catalog: catalog
        )
        #expect(result.exercises[0].restSeconds == 120)
        #expect(result.estimatedMinutes == 61)
    }

    @Test("Rest is capped at four minutes")
    func restIsCapped() {
        let session = makeSession(exercises: [makeGeneratedExercise("bench", sets: 3, restSeconds: 200)])
        let result = AutoregulationEngine.apply(
            [makeAdjustment(.restLonger, exerciseID: "bench", magnitude: 300)], to: session, catalog: catalog
        )
        #expect(result.exercises[0].restSeconds == AutoregulationTuning.maximumRestSeconds)
    }

    @Test("Sets are capped at six per exercise")
    func setsAreCappedPerExercise() {
        let session = makeSession(exercises: [makeGeneratedExercise("bench", sets: 6)])
        let result = AutoregulationEngine.apply(
            [makeAdjustment(.addSet, muscleGroup: .chest, magnitude: 1)], to: session, catalog: catalog
        )
        #expect(result.exercises[0].sets == 6)
        #expect(result.estimatedMinutes == 60)
    }

    @Test("The estimate never drops below ten minutes")
    func estimateHasATenMinuteFloor() {
        let session = makeSession(
            estimatedMinutes: 10,
            exercises: [
                makeGeneratedExercise("bench", orderIndex: 0, sets: 4),
                makeGeneratedExercise("fly", orderIndex: 1, sets: 4)
            ]
        )
        let removals = Array(repeating: makeAdjustment(.removeSet, muscleGroup: .chest, magnitude: 1), count: 3)
        let result = AutoregulationEngine.apply(removals, to: session, catalog: catalog)
        #expect(result.estimatedMinutes == 10)
    }

    @Test("A non-finite magnitude means no change rather than a trap")
    func nonFiniteMagnitudesAreRefused() {
        let session = makeSession(exercises: [makeGeneratedExercise("bench", sets: 3, restSeconds: 90)])
        for magnitude in [Double.nan, .infinity, -.infinity] {
            let result = AutoregulationEngine.apply(
                [
                    makeAdjustment(.restLonger, exerciseID: "bench", magnitude: magnitude),
                    makeAdjustment(.shortenSession, magnitude: magnitude)
                ],
                to: session,
                catalog: catalog
            )
            #expect(result.exercises[0].restSeconds == 90)
            #expect(result.exercises[0].sets == 3)
            #expect(result.estimatedMinutes == 60)
        }
    }

    @Test("An absurd magnitude is clamped rather than overflowing")
    func absurdMagnitudesAreClamped() {
        let session = makeSession(exercises: [makeGeneratedExercise("bench", sets: 4, restSeconds: 60)])
        let rested = AutoregulationEngine.apply(
            [makeAdjustment(.restLonger, exerciseID: "bench", magnitude: 1e30)], to: session, catalog: catalog
        )
        #expect(rested.exercises[0].restSeconds == AutoregulationTuning.maximumRestSeconds)

        let trimmed = AutoregulationEngine.apply(
            [makeAdjustment(.shortenSession, magnitude: 1e30)], to: session, catalog: catalog
        )
        #expect(trimmed.exercises[0].sets >= 1)
        #expect(trimmed.estimatedMinutes >= 10)
    }

    @Test("Load changes and swaps are no-ops for a session plan")
    func loadAndSwapAdjustmentsAreNoOps() {
        let session = makeSession(exercises: [makeGeneratedExercise("bench", sets: 3, restSeconds: 90)])
        let result = AutoregulationEngine.apply(
            [
                makeAdjustment(.reduceLoad, exerciseID: "bench", magnitude: 0.1),
                makeAdjustment(.increaseLoad, exerciseID: "bench", magnitude: 0.1),
                makeAdjustment(.swapExercise, exerciseID: "bench", magnitude: 0),
                makeAdjustment(.noChange, magnitude: 0)
            ],
            to: session,
            catalog: catalog
        )
        #expect(result == session)
    }

    @Test("A rest day and an empty session come back untouched")
    func restDaysAndEmptySessionsAreUntouched() {
        let restDay = makeSession(isRestDay: true, exercises: [makeGeneratedExercise("bench")])
        let empty = makeSession(exercises: [])
        let removal = [makeAdjustment(.removeSet, muscleGroup: .chest, magnitude: 1)]

        #expect(AutoregulationEngine.apply(removal, to: restDay, catalog: catalog) == restDay)
        #expect(AutoregulationEngine.apply(removal, to: empty, catalog: catalog) == empty)
    }

    @Test("An empty adjustment list leaves the session exactly as it was")
    func noAdjustmentsLeaveTheSessionAlone() {
        let session = makeSession(exercises: [makeGeneratedExercise("bench", sets: 3)])
        #expect(AutoregulationEngine.apply([], to: session, catalog: catalog) == session)
    }

    @Test("Volume is added to the cheapest movement for the group")
    func volumeIsAddedToTheCheapestMovement() {
        let session = makeSession(
            exercises: [
                makeGeneratedExercise("bench", orderIndex: 0, sets: 3),
                makeGeneratedExercise("fly", orderIndex: 1, sets: 3)
            ]
        )
        let result = AutoregulationEngine.apply(
            [makeAdjustment(.addSet, muscleGroup: .chest, magnitude: 1)], to: session, catalog: catalog
        )
        // fly has the lower fatigueCost.
        #expect(result.exercises[0].sets == 3)
        #expect(result.exercises[1].sets == 4)
    }

    @Test("Volume is removed from the most fatiguing movement for the group")
    func volumeIsRemovedFromTheMostFatiguingMovement() {
        let session = makeSession(
            exercises: [
                makeGeneratedExercise("bench", orderIndex: 0, sets: 3),
                makeGeneratedExercise("fly", orderIndex: 1, sets: 3)
            ]
        )
        let result = AutoregulationEngine.apply(
            [makeAdjustment(.removeSet, muscleGroup: .chest, magnitude: 1)], to: session, catalog: catalog
        )
        #expect(result.exercises[0].sets == 2)
        #expect(result.exercises[1].sets == 3)
    }

    @Test("An adjustment naming an exercise the session does not contain changes nothing")
    func unknownExerciseIDChangesNothing() {
        let session = makeSession(exercises: [makeGeneratedExercise("bench", sets: 3)])
        let result = AutoregulationEngine.apply(
            [makeAdjustment(.restLonger, exerciseID: "not-here", magnitude: 30)], to: session, catalog: catalog
        )
        #expect(result == session)
    }

    @Test("Applying the same adjustments twice is deterministic")
    func applyIsDeterministic() {
        let session = makeSession(
            exercises: [
                makeGeneratedExercise("bench", orderIndex: 0, sets: 4),
                makeGeneratedExercise("fly", orderIndex: 1, sets: 4)
            ]
        )
        let batch = [
            makeAdjustment(.restLonger, exerciseID: "bench", magnitude: 30),
            makeAdjustment(.addSet, muscleGroup: .chest, magnitude: 1),
            makeAdjustment(.removeSet, muscleGroup: .chest, magnitude: 1),
            makeAdjustment(.shortenSession, magnitude: 5)
        ]
        #expect(
            AutoregulationEngine.apply(batch, to: session, catalog: catalog)
                == AutoregulationEngine.apply(batch, to: session, catalog: catalog)
        )
    }
}
