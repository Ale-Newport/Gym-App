import Foundation
import Testing
@testable import GymApp

// MARK: - Helpers

/// Derives metadata from the same fields the dataset supplies, so every expectation below is a
/// statement about a real record rather than about the deriver's internals.
private func derive(
    _ name: String,
    bodyPart: BodyPart = .chest,
    equipment: Equipment = .barbell,
    target: Muscle = .pectorals,
    synergist: Muscle? = nil,
    secondary: [Muscle] = []
) -> ExerciseMetadata {
    ExerciseMetadataDeriver.derive(
        name: name,
        bodyPart: bodyPart,
        equipment: equipment,
        target: target,
        synergist: synergist,
        secondaryMuscles: secondary
    )
}

/// Metadata for a record that actually ships, looked up by dataset id.
private func bundledMetadata(_ id: String) throws -> ExerciseMetadata {
    try ExerciseDatasetFixture.exercise(id: id).metadata
}

// MARK: - Named classifications

@Suite("Metadata derivation of well-known exercises")
struct ExerciseMetadataNamedClassificationTests {

    @Test("Barbell bench press is a horizontal-push compound logged in weight and reps")
    func barbellBenchPress() throws {
        let metadata = try bundledMetadata("0025")
        #expect(metadata.movementPattern == .horizontalPush)
        #expect(metadata.mechanic == .compound)
        #expect(metadata.pushPull == .push)
        #expect(metadata.trackingMode == .weightAndReps)
        #expect(metadata.laterality == .bilateral)
        #expect(metadata.recommendedRepRange == RepRange(6, 10))
        #expect(metadata.defaultRestSeconds == 165)
        #expect(metadata.isStretch == false)
        #expect(metadata.isPlyometric == false)
    }

    @Test("Barbell full squat is a squat compound on the heavy 5–8 range with a long rest")
    func barbellFullSquat() throws {
        let metadata = try bundledMetadata("0043")
        #expect(metadata.movementPattern == .squat)
        #expect(metadata.mechanic == .compound)
        #expect(metadata.pushPull == .legs)
        #expect(metadata.recommendedRepRange == RepRange(5, 8))
        #expect(metadata.defaultRestSeconds == 210)
        #expect(metadata.substitutionTags.contains("axial_load"))
        #expect(metadata.substitutionTags.contains("deep_knee"))
    }

    @Test("A plank is tracked in seconds, never in reps")
    func plankIsDurationTracked() {
        let metadata = derive("plank", bodyPart: .waist, equipment: .bodyWeight, target: .abs)
        #expect(metadata.movementPattern == .coreAntiExtension)
        #expect(metadata.trackingMode == .duration)
        #expect(metadata.trackingMode.usesReps == false)
        #expect(metadata.pushPull == .core)
    }

    @Test("A weighted front plank stays duration-tracked despite carrying added load")
    func weightedPlankIsStillDurationTracked() throws {
        let metadata = try bundledMetadata("2135")
        #expect(metadata.movementPattern == .coreAntiExtension)
        #expect(metadata.trackingMode == .duration)
    }

    @Test("Run is cardio, tracked as distance and duration, and earns no lifting volume")
    func runIsCardio() throws {
        let metadata = try bundledMetadata("0685")
        #expect(metadata.movementPattern == .cardio)
        #expect(metadata.pushPull == .cardio)
        #expect(metadata.trackingMode == .distanceAndDuration)
        #expect(metadata.volumeContribution.isEmpty)
    }

    @Test("Dumbbell biceps curl is an elbow-flexion isolation")
    func dumbbellBicepsCurl() throws {
        let metadata = try bundledMetadata("0294")
        #expect(metadata.movementPattern == .elbowFlexion)
        #expect(metadata.mechanic == .isolation)
        #expect(metadata.pushPull == .pull)
        #expect(metadata.recommendedRepRange == RepRange(8, 14))
    }

    @Test("Hanging leg raise is core flexion, not a shoulder raise")
    func hangingLegRaiseIsCoreFlexion() throws {
        let metadata = try bundledMetadata("0472")
        #expect(metadata.movementPattern == .coreFlexion)
        #expect(metadata.movementPattern != .shoulderRaise)
        #expect(metadata.pushPull == .core)
    }

    @Test("Jump rope is duration work, not a distance-tracked run")
    func jumpRopeIsDurationNotDistance() throws {
        let metadata = try bundledMetadata("2612")
        #expect(metadata.movementPattern == .cardio)
        #expect(metadata.trackingMode == .duration)
        #expect(metadata.trackingMode.usesDistance == false)
        #expect(metadata.isPlyometric)
        #expect(metadata.volumeContribution.isEmpty, "cardio must not earn calf volume")
    }
}

// MARK: - Plural forms

@Suite("Metadata derivation handles the plural spellings in the dataset")
struct ExerciseMetadataPluralTests {

    @Test("Hip thrusts classify as hip thrusts")
    func hipThrustPlural() {
        let singular = derive("barbell hip thrust", bodyPart: .upperLegs, equipment: .barbell, target: .glutes)
        let plural = derive("barbell hip thrusts", bodyPart: .upperLegs, equipment: .barbell, target: .glutes)
        #expect(singular.movementPattern == .hipThrust)
        #expect(plural.movementPattern == .hipThrust)
    }

    @Test("The bundled plural record 'resistance band hip thrusts on knees' is a hip thrust")
    func bundledHipThrustPlural() throws {
        let metadata = try bundledMetadata("3236")
        #expect(metadata.movementPattern == .hipThrust)
        #expect(metadata.pushPull == .legs)
    }

    @Test("Glute bridges classify as hip thrusts in both spellings")
    func glutebridgePlural() {
        let singular = derive("glute bridge", bodyPart: .upperLegs, equipment: .bodyWeight, target: .glutes)
        let plural = derive("glute bridges", bodyPart: .upperLegs, equipment: .bodyWeight, target: .glutes)
        #expect(singular.movementPattern == .hipThrust)
        #expect(plural.movementPattern == .hipThrust)
    }

    @Test("Plural presses, curls and raises resolve to the same pattern as their singulars")
    func otherPluralsMatchTheirSingulars() {
        #expect(
            derive("barbell bench presses").movementPattern
                == derive("barbell bench press").movementPattern
        )
        #expect(
            derive("dumbbell biceps curls", bodyPart: .upperArms, equipment: .dumbbell, target: .biceps).movementPattern
                == derive("dumbbell biceps curl", bodyPart: .upperArms, equipment: .dumbbell, target: .biceps).movementPattern
        )
        #expect(
            derive("dumbbell lateral raises", bodyPart: .shoulders, equipment: .dumbbell, target: .delts).movementPattern
                == derive("dumbbell lateral raise", bodyPart: .shoulders, equipment: .dumbbell, target: .delts).movementPattern
        )
    }

    @Test("Plural matching never fires mid-token")
    func pluralMatchingDoesNotFireMidToken() {
        // "presses" must not be found inside "compressed", nor "row" inside "narrow".
        let matcher = NameMatcher("narrow grip compressed bar")
        #expect(matcher.has("press") == false)
        #expect(matcher.has("row") == false)
        #expect(matcher.has("bar"))
    }
}

// MARK: - Overloaded words

@Suite("Metadata derivation disambiguates overloaded exercise words")
struct ExerciseMetadataOverloadedWordTests {

    @Test("A lateral raise is a shoulder movement")
    func lateralRaiseIsShoulderWork() {
        let metadata = derive("dumbbell lateral raise", bodyPart: .shoulders, equipment: .dumbbell, target: .delts)
        #expect(metadata.movementPattern == .shoulderRaise)
    }

    @Test("A calf raise is a calf movement, never a shoulder raise")
    func calfRaiseIsCalfWork() {
        let metadata = derive("standing calf raise", bodyPart: .lowerLegs, equipment: .bodyWeight, target: .calves)
        #expect(metadata.movementPattern == .calfRaise)
    }

    @Test("A leg raise targeting the abs is core flexion")
    func legRaiseTargetingAbsIsCore() {
        let metadata = derive("lying leg raise", bodyPart: .waist, equipment: .bodyWeight, target: .abs)
        #expect(metadata.movementPattern == .coreFlexion)
    }

    @Test("A leg raise targeting the glutes is hip extension")
    func legRaiseTargetingGlutesIsHipThrust() {
        let metadata = derive("prone hip raise", bodyPart: .upperLegs, equipment: .bodyWeight, target: .glutes)
        #expect(metadata.movementPattern == .hipThrust)
    }

    @Test("A glute bridge is hip extension but a side bridge is lateral core work")
    func bridgeIsResolvedOnTheTargetMuscle() {
        let glute = derive("barbell glute bridge", bodyPart: .upperLegs, equipment: .barbell, target: .glutes)
        let side = derive("side bridge", bodyPart: .waist, equipment: .bodyWeight, target: .obliques)
        #expect(glute.movementPattern == .hipThrust)
        #expect(side.movementPattern == .coreLateralFlexion)
    }

    @Test("A triceps extension is elbow extension, a leg extension is knee extension, a hip extension is a hinge")
    func extensionIsResolvedBeforeTheGenericElbowRule() {
        let triceps = derive("cable triceps extension", bodyPart: .upperArms, equipment: .cable, target: .triceps)
        let leg = derive("lever leg extension", bodyPart: .upperLegs, equipment: .leverageMachine, target: .quads)
        let hip = derive("cable hip extension", bodyPart: .upperLegs, equipment: .cable, target: .glutes)
        #expect(triceps.movementPattern == .elbowExtension)
        #expect(leg.movementPattern == .kneeExtension)
        #expect(hip.movementPattern == .hinge)
    }

    @Test("An upright row is classified as a pull, not as a shoulder raise")
    func uprightRowIsAPull() {
        let metadata = derive("barbell upright row", bodyPart: .shoulders, equipment: .barbell, target: .delts)
        #expect(metadata.movementPattern == .horizontalPull)
    }

    @Test("A pullover is a vertical pull, not a row")
    func pulloverIsAVerticalPull() {
        let metadata = derive("dumbbell pullover", bodyPart: .back, equipment: .dumbbell, target: .lats)
        #expect(metadata.movementPattern == .verticalPull)
    }

    @Test("A thruster is classified by the press that limits it")
    func thrusterIsAVerticalPush() {
        let metadata = derive("barbell thruster", bodyPart: .upperLegs, equipment: .barbell, target: .quads)
        #expect(metadata.movementPattern == .verticalPush)
        #expect(metadata.substitutionTags.contains("overhead"))
    }

    @Test("A hamstring curl is knee flexion while a biceps curl is elbow flexion")
    func curlIsResolvedOnTheTargetMuscle() {
        let leg = derive("lever lying leg curl", bodyPart: .upperLegs, equipment: .leverageMachine, target: .hamstrings)
        let arm = derive("ez barbell curl", bodyPart: .upperArms, equipment: .ezBarbell, target: .biceps)
        #expect(leg.movementPattern == .kneeFlexion)
        #expect(arm.movementPattern == .elbowFlexion)
    }
}

// MARK: - Tracking mode

@Suite("Tracking mode derivation")
struct ExerciseTrackingModeTests {

    @Test("Stretches are held for time")
    func stretchIsDuration() {
        let metadata = derive("standing hamstring stretch", bodyPart: .upperLegs, equipment: .bodyWeight, target: .hamstrings)
        #expect(metadata.isStretch)
        #expect(metadata.movementPattern == .mobility)
        #expect(metadata.trackingMode == .duration)
    }

    @Test("Cardio on a machine records distance and duration")
    func cardioMachineIsDistanceAndDuration() {
        let metadata = derive(
            "walking on stepmill", bodyPart: .cardio, equipment: .stepmillMachine, target: .cardiovascularSystem
        )
        #expect(metadata.trackingMode == .distanceAndDuration)
    }

    @Test("An ergometer records distance even when the dataset files it under a body part")
    func ergometerIsDistanceRegardlessOfBodyPart() throws {
        // 2139 'hands bike' and 2142 'ski ergometer' are filed under chest and upper arms.
        let handsBike = try bundledMetadata("2139")
        let skiErgometer = try bundledMetadata("2142")
        #expect(handsBike.trackingMode == .distanceAndDuration)
        #expect(skiErgometer.trackingMode == .distanceAndDuration)
    }

    @Test("Held positions are duration-tracked whatever the equipment")
    func heldPositionsAreDuration() {
        #expect(derive("dead hang", bodyPart: .back, equipment: .bodyWeight, target: .lats).trackingMode == .duration)
        #expect(derive("wall sit", bodyPart: .upperLegs, equipment: .bodyWeight, target: .quads).trackingMode == .duration)
        #expect(derive("hollow hold", bodyPart: .waist, equipment: .bodyWeight, target: .abs).trackingMode == .duration)
    }

    @Test("A loaded carry records weight and time")
    func carryIsWeightAndDuration() {
        let metadata = derive("dumbbell farmers walk", bodyPart: .upperLegs, equipment: .dumbbell, target: .forearms)
        #expect(metadata.movementPattern == .carry)
        #expect(metadata.trackingMode == .weightAndDuration)
    }

    @Test("Assisted equipment records assisted bodyweight")
    func assistedEquipmentIsAssistedBodyweight() {
        let metadata = derive("assisted pull up", bodyPart: .back, equipment: .assisted, target: .lats)
        #expect(metadata.trackingMode == .assistedBodyweight)
        #expect(metadata.loadability == .assistedBodyweight)
    }

    @Test("Bodyweight strength movements allow added load rather than being reps-only")
    func bodyweightStrengthTakesAddedLoad() {
        let pushUp = derive("push up", bodyPart: .chest, equipment: .bodyWeight, target: .pectorals)
        let weighted = derive("weighted pull up", bodyPart: .back, equipment: .weighted, target: .lats)
        #expect(pushUp.trackingMode == .weightedBodyweight)
        #expect(pushUp.loadability == .bodyweight)
        #expect(weighted.trackingMode == .weightedBodyweight)
        #expect(weighted.loadability == .weightedBodyweight)
    }

    @Test("Bands, balls and ropes are reps-only because their load is not a number")
    func bandsAndBallsAreRepsOnly() {
        #expect(derive("band biceps curl", bodyPart: .upperArms, equipment: .band, target: .biceps).trackingMode == .repsOnly)
        #expect(
            derive("exercise ball crunch", bodyPart: .waist, equipment: .stabilityBall, target: .abs).trackingMode
                == .repsOnly
        )
    }

    @Test("Everything else records weight and reps")
    func defaultIsWeightAndReps() {
        #expect(derive("barbell bench press").trackingMode == .weightAndReps)
        #expect(
            derive("cable seated row", bodyPart: .back, equipment: .cable, target: .upperBack).trackingMode
                == .weightAndReps
        )
    }
}

// MARK: - Laterality and set timing

@Suite("Laterality and set-time estimation")
struct ExerciseLateralityTests {

    @Test("A bilateral compound's set time is midpoint reps × 3.5 s plus 25 s of set-up")
    func bilateralCompoundSetTime() throws {
        let metadata = try bundledMetadata("0025")
        let expected = Int((Double(metadata.recommendedRepRange.midpoint) * 3.5 + 25).rounded())
        #expect(metadata.laterality == .bilateral)
        #expect(metadata.estimatedSetSeconds == expected)
        #expect(metadata.estimatedSetSeconds == 53)
    }

    @Test("Unilateral work costs 1.7× the clock time of the same set count")
    func unilateralSetTimeIsMultiplied() {
        let bilateral = derive("dumbbell bent over row", bodyPart: .back, equipment: .dumbbell, target: .upperBack)
        let unilateral = derive("dumbbell one arm row", bodyPart: .back, equipment: .dumbbell, target: .upperBack)
        #expect(bilateral.laterality == .bilateral)
        #expect(unilateral.laterality == .unilateral)
        #expect(unilateral.recommendedRepRange == bilateral.recommendedRepRange)
        #expect(unilateral.estimatedSetSeconds == Int((Double(bilateral.estimatedSetSeconds) * 1.7).rounded()))
    }

    @Test("Alternating work is treated as unilateral for time budgeting")
    func alternatingCountsAsTwoSides() {
        let metadata = derive("dumbbell alternate biceps curl", bodyPart: .upperArms, equipment: .dumbbell, target: .biceps)
        #expect(metadata.laterality == .alternating)
        #expect(metadata.laterality.timeMultiplier == 1.7)
    }

    @Test("Every lunge pattern is unilateral even without a keyword")
    func lungesAreUnilateral() {
        #expect(derive("barbell lunge", bodyPart: .upperLegs, equipment: .barbell, target: .quads).laterality == .unilateral)
        #expect(
            derive("bulgarian split squat", bodyPart: .upperLegs, equipment: .bodyWeight, target: .quads).laterality
                == .unilateral
        )
    }

    @Test("Duration work is budgeted at 45 seconds a set and distance work at 300")
    func nonRepSetTimes() {
        let plank = derive("plank", bodyPart: .waist, equipment: .bodyWeight, target: .abs)
        let run = derive("run", bodyPart: .cardio, equipment: .bodyWeight, target: .cardiovascularSystem)
        #expect(plank.estimatedSetSeconds == 45)
        #expect(run.estimatedSetSeconds == 300)
    }
}

// MARK: - Continuous score rules

@Suite("Continuous score rules and their clamps")
struct ExerciseContinuousScoreTests {

    @Test("Stability demand is clamped at 1.0 when every modifier stacks")
    func stabilityDemandClampsAtOne() {
        let value = ExerciseMetadataDeriver.stabilityDemand(
            NameMatcher("standing overhead jump press"),
            equipment: .stabilityBall,
            laterality: .unilateral,
            isPlyometric: true
        )
        // 0.88 + 0.14 + 0.12 + 0.08 = 1.22 before clamping.
        #expect(value == 1.0)
    }

    @Test("Stability demand is clamped at 0.05 when the modifiers push it below zero")
    func stabilityDemandClampsAtFloor() {
        let value = ExerciseMetadataDeriver.stabilityDemand(
            NameMatcher("seated lever chest press"),
            equipment: .leverageMachine,
            laterality: .bilateral,
            isPlyometric: false
        )
        // 0.10 − 0.12 = −0.02 before clamping.
        #expect(value == 0.05)
    }

    @Test("Stability demand sits at its documented base for an unmodified barbell lift")
    func stabilityDemandUsesTheEquipmentBase() {
        let value = ExerciseMetadataDeriver.stabilityDemand(
            NameMatcher("barbell bench press"), equipment: .barbell, laterality: .bilateral, isPlyometric: false
        )
        #expect(abs(value - 0.52) < 0.0001)
    }

    @Test("Fatigue cost is clamped at 1.0 for a barbell hinge")
    func fatigueCostClampsAtOne() {
        let value = ExerciseMetadataDeriver.fatigueCost(
            pattern: .hinge, mechanic: .compound, equipment: .barbell,
            laterality: .bilateral, isStretch: false, isPlyometric: false
        )
        // 0.95 × 1.12 = 1.064 before clamping.
        #expect(value == 1.0)
    }

    @Test("Fatigue cost is clamped at 0.03 for band mobility work")
    func fatigueCostClampsAtFloor() {
        let value = ExerciseMetadataDeriver.fatigueCost(
            pattern: .mobility, mechanic: .isolation, equipment: .band,
            laterality: .bilateral, isStretch: false, isPlyometric: false
        )
        // 0.04 × 0.72 × 0.92 = 0.0265 before clamping.
        #expect(value == 0.03)
    }

    @Test("A stretch costs the documented floor of fatigue")
    func stretchFatigueIsTheFloor() {
        let value = ExerciseMetadataDeriver.fatigueCost(
            pattern: .squat, mechanic: .compound, equipment: .barbell,
            laterality: .bilateral, isStretch: true, isPlyometric: false
        )
        #expect(value == 0.03)
    }

    @Test("Progression suitability follows the documented ladder from barbell down to none")
    func progressionSuitabilityLadder() {
        func value(_ loadability: Loadability) -> Double {
            ExerciseMetadataDeriver.progressionSuitability(
                loadability: loadability, tracking: .weightAndReps, isStretch: false
            )
        }
        #expect(value(.barbell) == 1.00)
        #expect(value(.ezBar) == 0.92)
        #expect(value(.machineStack) == 0.90)
        #expect(value(.cableStack) == 0.88)
        #expect(value(.dumbbell) == 0.86)
        #expect(value(.weightedBodyweight) == 0.80)
        #expect(value(.assistedBodyweight) == 0.72)
        #expect(value(.kettlebell) == 0.58)
        #expect(value(.bodyweight) == 0.45)
        #expect(value(.band) == 0.32)
        #expect(value(.none) == 0.20)
        #expect(value(.barbell) > value(.dumbbell))
        #expect(value(.dumbbell) > value(.band))
    }

    @Test("Stimulus score follows its documented formula for a barbell compound")
    func stimulusScoreFormula() {
        let value = ExerciseMetadataDeriver.stimulusScore(
            mechanic: .compound, progression: 1.0, stability: 0.52, isStretch: false, tracking: .weightAndReps
        )
        // 0.45 + 0.18 + 0.28 × 1.0 − 0.35 × max(0, 0.52 − 0.55) = 0.91
        #expect(abs(value - 0.91) < 0.0001)
    }

    @Test("Stimulus score is penalised only once stability passes 0.55")
    func stimulusScorePenaltyStartsAtTheBoundary() {
        func value(stability: Double) -> Double {
            ExerciseMetadataDeriver.stimulusScore(
                mechanic: .compound, progression: 0.86, stability: stability,
                isStretch: false, tracking: .weightAndReps
            )
        }
        let atBoundary = value(stability: 0.55)
        let belowBoundary = value(stability: 0.40)
        let pastBoundary = value(stability: 0.72)
        #expect(abs(atBoundary - belowBoundary) < 0.0001, "no penalty may apply at or below 0.55")
        #expect(pastBoundary < atBoundary)
        #expect(abs(pastBoundary - (atBoundary - 0.35 * 0.17)) < 0.0001)
    }

    @Test("A compound outscores an isolation given identical loading and stability")
    func compoundOutscoresIsolation() {
        let compound = ExerciseMetadataDeriver.stimulusScore(
            mechanic: .compound, progression: 0.86, stability: 0.5, isStretch: false, tracking: .weightAndReps
        )
        let isolation = ExerciseMetadataDeriver.stimulusScore(
            mechanic: .isolation, progression: 0.86, stability: 0.5, isStretch: false, tracking: .weightAndReps
        )
        #expect(compound > isolation)
        #expect(abs((compound - isolation) - 0.06) < 0.0001)
    }
}

// MARK: - Volume contribution

@Suite("Volume contribution")
struct ExerciseVolumeContributionTests {

    @Test("A compound credits its target a full set and its helpers a half set")
    func compoundCreditsHalfSets() throws {
        let contribution = try bundledMetadata("0025").volumeContribution
        #expect(contribution[.chest] == 1.0)
        #expect(contribution[.triceps] == 0.5)
        #expect(contribution[.shoulders] == 0.5)
        #expect(contribution[.cardio] == nil)
    }

    @Test("An isolation credits its helpers a third of a set")
    func isolationCreditsThirds() throws {
        let contribution = try bundledMetadata("0294").volumeContribution
        #expect(contribution[.biceps] == 1.0)
        #expect(contribution[.forearms] == 0.33)
    }

    @Test("A group never earns more than one full set from a single exercise")
    func targetGroupIsCappedAtOne() {
        // Synergist and secondaries all roll up into the target's own group.
        let contribution = derive(
            "barbell bench press",
            bodyPart: .chest, equipment: .barbell, target: .pectorals,
            synergist: .serratusAnterior, secondary: [.serratusAnterior]
        ).volumeContribution
        #expect(contribution[.chest] == 1.0)
        #expect(contribution.values.allSatisfy { $0 <= 1.0 })
    }

    @Test("Stretches and cardio earn no volume at all")
    func stretchesAndCardioEarnNothing() throws {
        let stretch = derive("standing hamstring stretch", bodyPart: .upperLegs, equipment: .bodyWeight, target: .hamstrings)
        let run = try bundledMetadata("0685")
        let jumpRope = try bundledMetadata("2612")
        #expect(stretch.volumeContribution.isEmpty)
        #expect(run.volumeContribution.isEmpty)
        #expect(jumpRope.volumeContribution.isEmpty)
    }

    @Test("An exercise with no synergist and no secondaries credits only its target group")
    func loneTargetEarnsOnlyItsOwnGroup() {
        let contribution = derive(
            "machine chest press", bodyPart: .chest, equipment: .leverageMachine, target: .pectorals
        ).volumeContribution
        #expect(contribution == [.chest: 1.0])
    }
}

// MARK: - Substitution tags

@Suite("Substitution tags")
struct ExerciseSubstitutionTagTests {

    @Test("Every exercise is tagged with its own pattern and mechanic")
    func tagsAlwaysCarryPatternAndMechanic() {
        for exercise in ExerciseDatasetFixture.exercises {
            let tags = exercise.metadata.substitutionTags
            #expect(tags.contains(exercise.metadata.movementPattern.rawValue), "\(exercise.id) is missing its pattern tag")
            #expect(tags.contains(exercise.metadata.mechanic.rawValue), "\(exercise.id) is missing its mechanic tag")
        }
    }

    @Test("Overhead-loading movements are tagged overhead even when their pattern is not a press")
    func overheadIsTaggedFromKeywordsNotOnlyPattern() {
        let names = ["barbell clean and jerk", "barbell snatch", "barbell thruster", "kettlebell turkish get up"]
        for name in names {
            let metadata = derive(name, bodyPart: .upperLegs, equipment: .barbell, target: .quads)
            #expect(metadata.substitutionTags.contains("overhead"), "'\(name)' must be tagged overhead")
        }
    }

    @Test("A behind-the-neck pulldown is not tagged overhead but a behind-the-neck press is")
    func behindNeckOverheadTaggingDependsOnPattern() {
        let pulldown = derive("cable behind neck pulldown", bodyPart: .back, equipment: .cable, target: .lats)
        let press = derive("barbell behind neck press", bodyPart: .shoulders, equipment: .barbell, target: .delts)
        #expect(pulldown.substitutionTags.contains("overhead") == false)
        #expect(press.substitutionTags.contains("overhead"))
    }

    @Test("Grip and position tags follow the name")
    func gripAndPositionTags() {
        let metadata = derive(
            "incline close grip barbell bench press", bodyPart: .chest, equipment: .barbell, target: .pectorals
        )
        #expect(metadata.substitutionTags.contains("incline"))
        #expect(metadata.substitutionTags.contains("close_grip"))
        #expect(metadata.substitutionTags.contains("free_weight"))
        #expect(metadata.substitutionTags.contains("bar"))
        #expect(metadata.substitutionTags.contains("bilateral"))
    }

    @Test("A hanging movement is tagged grip-limited so grip limitations can filter it out")
    func hangingIsGripLimited() throws {
        let metadata = try bundledMetadata("0472")
        #expect(metadata.substitutionTags.contains("hanging"))
        #expect(metadata.substitutionTags.contains("grip_limited"))
    }
}

// MARK: - Totality across the whole catalogue

@Suite("Metadata derivation is total across the catalogue")
struct ExerciseMetadataTotalityTests {

    private var exercises: [Exercise] { ExerciseDatasetFixture.exercises }

    @Test("The catalogue actually loaded, so the totality checks mean something")
    func catalogueIsPopulated() {
        #expect(exercises.count == 1324)
    }

    @Test("Stability demand stays within its documented 0.05…1 range for every exercise")
    func stabilityDemandIsAlwaysInRange() {
        let out = exercises.filter { $0.metadata.stabilityDemand < 0.05 || $0.metadata.stabilityDemand > 1.0 }
        #expect(out.isEmpty, "\(out.count) exercises have an out-of-range stabilityDemand: \(out.prefix(5).map(\.id))")
    }

    @Test("Fatigue cost stays within its documented 0.03…1 range for every exercise")
    func fatigueCostIsAlwaysInRange() {
        let out = exercises.filter { $0.metadata.fatigueCost < 0.03 || $0.metadata.fatigueCost > 1.0 }
        #expect(out.isEmpty, "\(out.count) exercises have an out-of-range fatigueCost: \(out.prefix(5).map(\.id))")
    }

    @Test("Progression suitability stays within its documented 0.05…1 range for every exercise")
    func progressionSuitabilityIsAlwaysInRange() {
        let out = exercises.filter {
            $0.metadata.progressionSuitability < 0.05 || $0.metadata.progressionSuitability > 1.0
        }
        #expect(out.isEmpty, "\(out.count) exercises are out of range: \(out.prefix(5).map(\.id))")
    }

    @Test("Staple score stays within its documented 0.02…1 range for every exercise")
    func stapleScoreIsAlwaysInRange() {
        let out = exercises.filter { $0.metadata.stapleScore < 0.02 || $0.metadata.stapleScore > 1.0 }
        #expect(out.isEmpty, "\(out.count) exercises have an out-of-range stapleScore: \(out.prefix(5).map(\.id))")
    }

    @Test("Stimulus score stays within its documented 0.05…1 range for every exercise")
    func stimulusScoreIsAlwaysInRange() {
        // docs/fragments/metadata.md specifies `stimulusScore` as 0.05…1. Stretches short-circuit to
        // 0.02, which is below that floor — this assertion holds the code to the documented range.
        let out = exercises.filter { $0.metadata.stimulusScore < 0.05 || $0.metadata.stimulusScore > 1.0 }
        #expect(
            out.isEmpty,
            """
            \(out.count) exercises fall outside the documented 0.05…1 stimulusScore range, \
            e.g. \(out.prefix(3).map { "\($0.id) '\($0.name)' = \($0.metadata.stimulusScore)" })
            """
        )
    }

    @Test("Every rep-tracked exercise gets a sane rep range and everything else gets a single rep")
    func repRangesAreSane() {
        for exercise in exercises {
            let range = exercise.metadata.recommendedRepRange
            #expect(range.lower <= range.upper, "\(exercise.id) has an inverted rep range")
            if exercise.metadata.trackingMode.usesReps {
                #expect(range.lower >= 5, "\(exercise.id) recommends fewer than 5 reps: \(range)")
                #expect(range.upper <= 20, "\(exercise.id) recommends more than 20 reps: \(range)")
                #expect(range.contains(range.midpoint))
            } else {
                #expect(range == RepRange(1, 1), "\(exercise.id) is not rep-tracked but has range \(range)")
            }
        }
    }

    @Test("Every exercise gets a positive rest and set-time budget")
    func restAndSetTimesArePositive() {
        for exercise in exercises {
            #expect(exercise.metadata.defaultRestSeconds >= 20, "\(exercise.id) rests for \(exercise.metadata.defaultRestSeconds)s")
            #expect(exercise.metadata.defaultRestSeconds <= 210, "\(exercise.id) rests for \(exercise.metadata.defaultRestSeconds)s")
            #expect(exercise.metadata.estimatedSetSeconds > 0, "\(exercise.id) has a non-positive set time")
        }
    }

    @Test("Volume contribution is empty exactly for stretches, cardio and distance-tracked work")
    func volumeContributionIsEmptyOnlyWhereDocumented() {
        for exercise in exercises {
            let metadata = exercise.metadata
            let shouldBeEmpty = metadata.isStretch
                || metadata.movementPattern == .cardio
                || metadata.trackingMode == .distanceAndDuration
            #expect(
                metadata.volumeContribution.isEmpty == shouldBeEmpty,
                "\(exercise.id) '\(exercise.name)' contributes \(metadata.volumeContribution) "
                    + "(stretch: \(metadata.isStretch), pattern: \(metadata.movementPattern), "
                    + "tracking: \(metadata.trackingMode))"
            )
        }
    }

    @Test("Every volume credit is a positive fraction of at most one set, and cardio is never credited")
    func volumeCreditsAreFractionsOfASet() {
        for exercise in exercises {
            let contribution = exercise.metadata.volumeContribution
            #expect(contribution[.cardio] == nil, "\(exercise.id) credits volume to the cardio group")
            for (group, credit) in contribution {
                #expect(credit > 0, "\(exercise.id) credits \(group) a non-positive \(credit)")
                #expect(credit <= 1.0, "\(exercise.id) credits \(group) more than a full set: \(credit)")
            }
            if !contribution.isEmpty {
                #expect(contribution[exercise.primaryGroup] == 1.0, "\(exercise.id) does not credit its own target a full set")
            }
        }
    }

    @Test("Derivation is deterministic: the same record always produces the same metadata")
    func derivationIsDeterministic() {
        for exercise in exercises.prefix(200) {
            let again = ExerciseMetadataDeriver.derive(
                name: exercise.name,
                bodyPart: exercise.bodyPart,
                equipment: exercise.equipment,
                target: exercise.target,
                synergist: exercise.synergist,
                secondaryMuscles: exercise.secondaryMuscles
            )
            #expect(again == exercise.metadata, "\(exercise.id) derived differently on a second run")
        }
    }

    @Test("The derived distribution matches the figures documented for this dataset")
    func derivedDistributionMatchesTheDocumentedTable() {
        func count(_ predicate: (Exercise) -> Bool) -> Int { exercises.filter(predicate).count }

        #expect(count { $0.metadata.mechanic == .compound } == 663)
        #expect(count { $0.metadata.mechanic == .isolation } == 661)

        #expect(count { $0.metadata.trackingMode == .weightAndReps } == 820)
        #expect(count { $0.metadata.trackingMode == .weightedBodyweight } == 297)
        #expect(count { $0.metadata.trackingMode == .repsOnly } == 95)
        #expect(count { $0.metadata.trackingMode == .duration } == 89)
        #expect(count { $0.metadata.trackingMode == .distanceAndDuration } == 14)
        #expect(count { $0.metadata.trackingMode == .assistedBodyweight } == 7)
        #expect(count { $0.metadata.trackingMode == .weightAndDuration } == 2)

        #expect(count { $0.metadata.difficulty == .beginner } == 636)
        #expect(count { $0.metadata.difficulty == .intermediate } == 559)
        #expect(count { $0.metadata.difficulty == .advanced } == 129)

        #expect(count { $0.metadata.laterality == .bilateral } == 1083)
        #expect(count { $0.metadata.laterality == .unilateral } == 203)
        #expect(count { $0.metadata.laterality == .alternating } == 38)

        #expect(count { $0.metadata.pushPull == .pull } == 431)
        #expect(count { $0.metadata.pushPull == .push } == 353)
        #expect(count { $0.metadata.pushPull == .legs } == 273)
        #expect(count { $0.metadata.pushPull == .core } == 171)
        #expect(count { $0.metadata.pushPull == .neutral } == 67)
        #expect(count { $0.metadata.pushPull == .cardio } == 29)

        #expect(count { $0.metadata.volumeContribution.isEmpty } == 87)
        #expect(count { $0.metadata.isStretch } == 56)
    }
}
