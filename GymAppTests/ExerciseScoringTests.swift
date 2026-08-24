import Foundation
import Testing
@testable import GymApp

// MARK: - Shared fixtures

/// Hand-built value-type fixtures for the three selection engines.
///
/// Every test states its own preconditions through these helpers rather than leaning on the
/// shipping dataset, so a change to the catalogue can never silently change what a rule test means.
/// The dataset is used only where a test is explicitly about the real catalogue.
enum SelectionFixture {

    /// A fixed instant, used wherever a date is structurally required but behaviourally irrelevant.
    /// None of these engines reads a clock; pinning the date keeps that honest.
    static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func metadata(
        pattern: MovementPattern = .horizontalPush,
        pushPull: PushPullClass = .push,
        mechanic: Mechanic = .compound,
        difficulty: Difficulty = .beginner,
        laterality: Laterality = .bilateral,
        loadability: Loadability = .barbell,
        tracking: TrackingMode = .weightAndReps,
        stability: Double = 0.40,
        fatigue: Double = 0.40,
        stimulus: Double = 0.60,
        progression: Double = 0.70,
        repRange: RepRange = .hypertrophy,
        restSeconds: Int = 120,
        setSeconds: Int = 45,
        isStretch: Bool = false,
        isPlyometric: Bool = false,
        isWarmupCandidate: Bool = false,
        volume: [MuscleGroup: Double] = [.chest: 1.0, .triceps: 0.5],
        tags: Set<String> = ["press", "compound"],
        staple: Double = 0.50
    ) -> ExerciseMetadata {
        ExerciseMetadata(
            movementPattern: pattern,
            pushPull: pushPull,
            mechanic: mechanic,
            difficulty: difficulty,
            laterality: laterality,
            loadability: loadability,
            trackingMode: tracking,
            stabilityDemand: stability,
            fatigueCost: fatigue,
            stimulusScore: stimulus,
            progressionSuitability: progression,
            recommendedRepRange: repRange,
            defaultRestSeconds: restSeconds,
            estimatedSetSeconds: setSeconds,
            isStretch: isStretch,
            isPlyometric: isPlyometric,
            isWarmupCandidate: isWarmupCandidate,
            volumeContribution: volume,
            substitutionTags: tags,
            stapleScore: staple
        )
    }

    static func exercise(
        id: String,
        name: String? = nil,
        bodyPart: BodyPart = .chest,
        equipment: Equipment = .barbell,
        target: Muscle = .pectorals,
        synergist: Muscle? = .triceps,
        secondary: [Muscle] = [.delts],
        metadata: ExerciseMetadata = SelectionFixture.metadata()
    ) -> Exercise {
        Exercise(
            id: id,
            name: name ?? "Fixture \(id)",
            bodyPart: bodyPart,
            equipment: equipment,
            target: target,
            synergist: synergist,
            secondaryMuscles: secondary,
            mediaID: "media-\(id)",
            thumbnailFileName: "\(id).jpg",
            animationFileName: "\(id).gif",
            attribution: "fixture",
            createdAt: referenceDate,
            metadata: metadata
        )
    }

    static func profile(
        experience: ExperienceLevel = .intermediate,
        technique: TechniqueConfidence = .confident,
        goals: [TrainingGoal] = [.buildMuscle],
        priorities: [MuscleGroup] = [],
        equipment: Set<Equipment> = Equipment.fullGym,
        excludedIDs: Set<String> = [],
        limitations: [MobilityLimitation] = [],
        avoidedPatterns: Set<MovementPattern> = []
    ) -> TrainingProfileSnapshot {
        var profile = TrainingProfileSnapshot()
        profile.experience = experience
        profile.techniqueConfidence = technique
        profile.goals = goals
        profile.priorityGroups = priorities
        profile.availableEquipment = equipment
        profile.excludedExerciseIDs = excludedIDs
        profile.mobilityLimitations = limitations
        profile.avoidedPatterns = avoidedPatterns
        return profile
    }

    static func request(
        target: MuscleGroup = .chest,
        pattern: MovementPattern? = nil,
        mechanic: Mechanic? = nil,
        profile: TrainingProfileSnapshot = SelectionFixture.profile(),
        preferences: [String: ExercisePreferenceSnapshot] = [:],
        histories: [String: ExerciseHistorySnapshot] = [:],
        alreadySelected: Set<String> = [],
        recentlyUsed: Set<String> = [],
        patternsUsed: Set<MovementPattern> = [],
        favorLowFatigue: Bool = false,
        requiresLoadable: Bool = false
    ) -> ExerciseSelectionRequest {
        var request = ExerciseSelectionRequest(targetGroup: target, profile: profile)
        request.preferredPattern = pattern
        request.preferredMechanic = mechanic
        request.preferences = preferences
        request.histories = histories
        request.alreadySelected = alreadySelected
        request.recentlyUsedIDs = recentlyUsed
        request.patternsUsed = patternsUsed
        request.favorLowFatigue = favorLowFatigue
        request.requiresLoadableMovement = requiresLoadable
        return request
    }

    static func preference(
        _ id: String,
        favorite: Bool = false,
        feedback: ExerciseFeedback = .neutral,
        excluded: Bool = false,
        timesPerformed: Int = 0
    ) -> ExercisePreferenceSnapshot {
        var preference = ExercisePreferenceSnapshot(exerciseID: id)
        preference.isFavorite = favorite
        preference.feedback = feedback
        preference.isExcluded = excluded
        preference.timesPerformed = timesPerformed
        return preference
    }

    static func performedSet(
        weightKg: Double? = nil,
        reps: Int? = nil,
        durationSeconds: Int? = nil,
        kind: SetKind = .working,
        isCompleted: Bool = true
    ) -> PerformedSet {
        PerformedSet(
            kind: kind,
            weightKg: weightKg,
            reps: reps,
            rir: nil,
            rpe: nil,
            durationSeconds: durationSeconds,
            distanceMeters: nil,
            targetReps: nil,
            targetWeightKg: nil,
            isCompleted: isCompleted
        )
    }

    /// A history whose sessions are ordered newest first, exactly as the contract requires.
    static func history(
        id: String,
        sessions: [[PerformedSet]],
        totalSessions: Int? = nil
    ) -> ExerciseHistorySnapshot {
        var history = ExerciseHistorySnapshot(exerciseID: id)
        history.performances = sessions.enumerated().map { index, sets in
            ExercisePerformance(
                date: referenceDate.addingTimeInterval(-86_400 * Double(index)),
                exerciseID: id,
                sets: sets,
                sessionID: nil
            )
        }
        history.totalSessions = totalSessions ?? sessions.count
        history.lastPerformedAt = sessions.isEmpty ? nil : referenceDate
        return history
    }

    /// Named components of a breakdown, so a range failure says which factor broke.
    static func components(of breakdown: ExerciseScoreBreakdown) -> [(name: String, value: Double)] {
        [
            ("targetMatch", breakdown.targetMatch),
            ("secondaryUtility", breakdown.secondaryUtility),
            ("goalSuitability", breakdown.goalSuitability),
            ("equipmentAvailability", breakdown.equipmentAvailability),
            ("userPreference", breakdown.userPreference),
            ("historicalPerformance", breakdown.historicalPerformance),
            ("movementDiversity", breakdown.movementDiversity),
            ("progressionSuitability", breakdown.progressionSuitability),
            ("fatigueEfficiency", breakdown.fatigueEfficiency),
            ("experienceSuitability", breakdown.experienceSuitability),
            ("stapleBonus", breakdown.stapleBonus),
            ("priorityBonus", breakdown.priorityBonus),
            ("recentRepetitionPenalty", breakdown.recentRepetitionPenalty),
            ("exclusionPenalty", breakdown.exclusionPenalty)
        ]
    }
}

/// The real, shipping catalogue, loaded once from the host application's bundle.
///
/// Only tests that are explicitly about the shipping dataset — similarity reference values,
/// catalogue-wide invariants and performance — should touch this.
enum SelectionCatalogue {

    static let exercises: [Exercise] = {
        let importer = ExerciseDatasetImporter(bundle: .main)
        guard let manifest = try? importer.loadManifest(),
              let loaded = try? importer.loadExercises(expecting: manifest) else { return [] }
        return loaded
    }()

    static let byID: [String: Exercise] = Dictionary(
        exercises.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static let recommendation = ExerciseRecommendationEngine(catalog: exercises)
    static let substitution = ExerciseSubstitutionEngine(catalog: exercises)

    /// Dataset ids used as fixed reference points. Ids are stable across dataset versions; names
    /// are not unique, so nothing here looks an exercise up by name.
    static let barbellBenchPressID = "0025"
    static let dumbbellBenchPressID = "0289"
    static let leverChestPressID = "0576"
    static let barbellFullSquatID = "0043"
    static let leverLyingLegCurlID = "0586"

    static func exercise(_ id: String) -> Exercise? { byID[id] }
}

// MARK: - Eligibility

@Suite("Exercise eligibility gates")
struct ExerciseEligibilityTests {

    private func blocked(_ exercise: Exercise, _ request: ExerciseSelectionRequest) -> String? {
        ExerciseScoring.isEligible(exercise, request: request).reason?.key
    }

    @Test("An exercise the user has all the equipment for is eligible with no reason attached")
    func eligibleExerciseCarriesNoBlockingReason() {
        let exercise = SelectionFixture.exercise(id: "a")
        let gate = ExerciseScoring.isEligible(exercise, request: SelectionFixture.request())
        #expect(gate.eligible)
        #expect(gate.reason == nil)
    }

    @Test("Equipment the user does not have blocks the exercise")
    func missingEquipmentBlocksTheExercise() {
        let exercise = SelectionFixture.exercise(id: "a", equipment: .barbell)
        let request = SelectionFixture.request(
            profile: SelectionFixture.profile(equipment: [.dumbbell, .bodyWeight])
        )
        #expect(blocked(exercise, request) == "selection.blocked.equipment")
    }

    @Test("An explicitly excluded exercise id blocks the exercise")
    func excludedIdentifierBlocksTheExercise() {
        let exercise = SelectionFixture.exercise(id: "a")
        let request = SelectionFixture.request(
            profile: SelectionFixture.profile(excludedIDs: ["a"])
        )
        #expect(blocked(exercise, request) == "selection.blocked.excluded")
    }

    @Test("Never-recommend feedback blocks the exercise with its own reason")
    func neverRecommendFeedbackBlocksTheExercise() {
        let exercise = SelectionFixture.exercise(id: "a")
        let request = SelectionFixture.request(
            preferences: ["a": SelectionFixture.preference("a", feedback: .neverRecommend)]
        )
        #expect(blocked(exercise, request) == "selection.blocked.neverRecommend")
    }

    @Test("A preference-level exclusion blocks the exercise")
    func preferenceExclusionBlocksTheExercise() {
        let exercise = SelectionFixture.exercise(id: "a")
        let request = SelectionFixture.request(
            preferences: ["a": SelectionFixture.preference("a", excluded: true)]
        )
        #expect(blocked(exercise, request) == "selection.blocked.excluded")
    }

    @Test("An avoided movement pattern blocks the exercise")
    func avoidedPatternBlocksTheExercise() {
        let exercise = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(pattern: .horizontalPush)
        )
        let request = SelectionFixture.request(
            profile: SelectionFixture.profile(avoidedPatterns: [.horizontalPush])
        )
        #expect(blocked(exercise, request) == "selection.blocked.avoidedPattern")
    }

    @Test("A mobility limitation blocks every exercise using the pattern it rules out")
    func mobilityLimitationBlocksThePattern() {
        let overhead = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(pattern: .verticalPush)
        )
        let request = SelectionFixture.request(
            target: .shoulders,
            profile: SelectionFixture.profile(limitations: [.overheadPressing])
        )
        #expect(blocked(overhead, request) == "selection.blocked.limitation")
    }

    @Test("A mobility limitation blocks a tagged variation even when its pattern is allowed")
    func mobilityLimitationBlocksATaggedVariation() {
        // `shoulderExternalRotation` rules out chest flyes and vertical pushes by pattern; the
        // "behind_neck" tag is the only thing that distinguishes this horizontal push.
        let behindNeck = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(
                pattern: .horizontalPush,
                tags: ["press", "behind_neck"]
            )
        )
        let plain = SelectionFixture.exercise(
            id: "b",
            metadata: SelectionFixture.metadata(pattern: .horizontalPush, tags: ["press"])
        )
        let request = SelectionFixture.request(
            profile: SelectionFixture.profile(limitations: [.shoulderExternalRotation])
        )
        #expect(blocked(behindNeck, request) == "selection.blocked.limitation")
        #expect(blocked(plain, request) == nil)
    }

    @Test("A stretch is never offered for a working slot")
    func stretchIsBlockedInAWorkingSlot() {
        let stretch = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(isStretch: true)
        )
        #expect(blocked(stretch, SelectionFixture.request()) == "selection.blocked.stretch")
    }

    @Test("A stretch is allowed when the caller explicitly permits one")
    func stretchIsAllowedWhenTheCallerPermitsIt() {
        let stretch = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(isStretch: true)
        )
        let reason = ExerciseScoring.blockingReason(
            for: stretch,
            equipment: [stretch.equipment],
            excludedIDs: [],
            preference: nil,
            avoidedPatterns: [],
            limitations: [],
            unavailableIDs: [],
            allowsStretch: true,
            requiresLoadableMovement: false
        )
        #expect(reason == nil)
    }

    @Test("An exercise already chosen for this session is not offered twice")
    func alreadySelectedExerciseIsBlocked() {
        let exercise = SelectionFixture.exercise(id: "a")
        let request = SelectionFixture.request(alreadySelected: ["a"])
        #expect(blocked(exercise, request) == "selection.blocked.alreadyInSession")
    }

    @Test("A slot that requires load rejects a movement that is not both weighted and counted")
    func unloadableMovementIsBlockedWhenTheSlotRequiresLoad() {
        let plank = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(tracking: .duration)
        )
        let bodyweight = SelectionFixture.exercise(
            id: "b",
            metadata: SelectionFixture.metadata(tracking: .repsOnly)
        )
        let loadable = SelectionFixture.exercise(
            id: "c",
            metadata: SelectionFixture.metadata(tracking: .weightAndReps)
        )
        let request = SelectionFixture.request(requiresLoadable: true)
        #expect(blocked(plank, request) == "selection.blocked.notLoadable")
        #expect(blocked(bodyweight, request) == "selection.blocked.notLoadable")
        #expect(blocked(loadable, request) == nil)
    }

    @Test("An unloadable movement is fine when the slot does not require load")
    func unloadableMovementIsAllowedWhenTheSlotDoesNotRequireLoad() {
        let plank = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(tracking: .duration)
        )
        #expect(blocked(plank, SelectionFixture.request()) == nil)
    }

    @Test("When several gates fire the most specific reason is the one reported")
    func mostSpecificBlockingReasonWins() {
        let exercise = SelectionFixture.exercise(id: "a", equipment: .barbell)
        let everything = SelectionFixture.request(
            profile: SelectionFixture.profile(
                equipment: [.dumbbell],
                excludedIDs: ["a"],
                avoidedPatterns: [.horizontalPush]
            ),
            preferences: ["a": SelectionFixture.preference("a", feedback: .neverRecommend)],
            alreadySelected: ["a"]
        )
        #expect(blocked(exercise, everything) == "selection.blocked.alreadyInSession")

        // Dropping the session gate exposes the next one down, and so on.
        let withoutSession = SelectionFixture.request(
            profile: SelectionFixture.profile(
                equipment: [.dumbbell],
                excludedIDs: ["a"],
                avoidedPatterns: [.horizontalPush]
            ),
            preferences: ["a": SelectionFixture.preference("a", feedback: .neverRecommend)]
        )
        #expect(blocked(exercise, withoutSession) == "selection.blocked.excluded")

        let withoutExclusion = SelectionFixture.request(
            profile: SelectionFixture.profile(
                equipment: [.dumbbell],
                avoidedPatterns: [.horizontalPush]
            ),
            preferences: ["a": SelectionFixture.preference("a", feedback: .neverRecommend)]
        )
        #expect(blocked(exercise, withoutExclusion) == "selection.blocked.neverRecommend")

        let equipmentOnly = SelectionFixture.request(
            profile: SelectionFixture.profile(
                equipment: [.dumbbell],
                avoidedPatterns: [.horizontalPush]
            )
        )
        #expect(blocked(exercise, equipmentOnly) == "selection.blocked.equipment")
    }

    @Test("A disqualified exercise still explains itself instead of vanishing")
    func disqualifiedExerciseScoresZeroAndSaysWhy() {
        let exercise = SelectionFixture.exercise(id: "a", equipment: .barbell)
        let request = SelectionFixture.request(
            profile: SelectionFixture.profile(equipment: [.dumbbell])
        )
        let breakdown = ExerciseScoring.score(exercise, request: request)
        #expect(breakdown.isDisqualified)
        #expect(breakdown.total == 0)
        #expect(breakdown.exclusionPenalty == 1)
        #expect(breakdown.disqualificationReason?.key == "selection.blocked.equipment")
    }
}

// MARK: - Component ranges

@Suite("Exercise score component ranges")
struct ExerciseScoreRangeTests {

    /// A deliberately extreme cross-product: every metadata value at both ends of its range and at
    /// the midpoint, against every experience level and several slot shapes.
    private static let metadataMatrix: [ExerciseMetadata] = {
        var result: [ExerciseMetadata] = []
        for stability in [0.0, 0.5, 1.0] {
            for fatigue in [0.0, 0.5, 1.0] {
                for stimulus in [0.0, 1.0] {
                    for progression in [0.0, 1.0] {
                        for difficulty in Difficulty.allCases {
                            for tracking in [TrackingMode.weightAndReps, .duration, .repsOnly] {
                                result.append(
                                    SelectionFixture.metadata(
                                        mechanic: stimulus > 0 ? .compound : .isolation,
                                        difficulty: difficulty,
                                        tracking: tracking,
                                        stability: stability,
                                        fatigue: fatigue,
                                        stimulus: stimulus,
                                        progression: progression,
                                        repRange: stimulus > 0 ? .strength : .endurance,
                                        volume: stimulus > 0
                                            ? [.chest: 1.0, .triceps: 0.5, .shoulders: 0.5]
                                            : [:],
                                        tags: stimulus > 0 ? ["press", "machine"] : [],
                                        staple: progression
                                    )
                                )
                            }
                        }
                    }
                }
            }
        }
        return result
    }()

    private static let requestMatrix: [ExerciseSelectionRequest] = {
        var result: [ExerciseSelectionRequest] = []
        for experience in ExperienceLevel.allCases {
            for technique in TechniqueConfidence.allCases {
                let profile = SelectionFixture.profile(
                    experience: experience,
                    technique: technique,
                    goals: [.buildStrength, .buildMuscle, .improveEndurance],
                    priorities: [.chest, .triceps, .back]
                )
                result.append(
                    SelectionFixture.request(
                        pattern: .horizontalPush,
                        mechanic: .compound,
                        profile: profile,
                        preferences: ["x": SelectionFixture.preference("x", favorite: true, feedback: .love)],
                        recentlyUsed: ["x"],
                        patternsUsed: [.horizontalPush, .horizontalPull],
                        favorLowFatigue: true
                    )
                )
                result.append(
                    SelectionFixture.request(
                        profile: SelectionFixture.profile(
                            experience: experience,
                            technique: technique,
                            goals: [],
                            priorities: []
                        ),
                        preferences: ["x": SelectionFixture.preference("x", feedback: .dislike)]
                    )
                )
            }
        }
        return result
    }()

    @Test("Every score component and the total stay inside 0…1 across an extreme input matrix")
    func everyComponentStaysInsideTheUnitInterval() {
        for metadata in Self.metadataMatrix {
            let exercise = SelectionFixture.exercise(id: "x", metadata: metadata)
            for request in Self.requestMatrix {
                let breakdown = ExerciseScoring.score(exercise, request: request)
                for component in SelectionFixture.components(of: breakdown) {
                    #expect(
                        component.value >= 0 && component.value <= 1,
                        "\(component.name) was \(component.value) for \(metadata)"
                    )
                }
                #expect(
                    breakdown.total >= 0 && breakdown.total <= 1,
                    "total was \(breakdown.total) for \(metadata)"
                )
            }
        }
    }

    @Test("Every score component stays inside 0…1 for every record in the shipping catalogue")
    func everyComponentStaysInRangeForTheRealCatalogue() throws {
        let catalogue = SelectionCatalogue.exercises
        try #require(!catalogue.isEmpty, "The shipping catalogue failed to load from the bundle")

        let requests = [
            SelectionFixture.request(target: .chest),
            SelectionFixture.request(
                target: .back,
                pattern: .verticalPull,
                mechanic: .compound,
                profile: SelectionFixture.profile(
                    experience: .never,
                    technique: .unfamiliar,
                    goals: [.loseFat, .improveEndurance],
                    priorities: [.back, .biceps]
                ),
                favorLowFatigue: true
            ),
            SelectionFixture.request(
                target: .quads,
                profile: SelectionFixture.profile(experience: .advanced, technique: .coached)
            )
        ]

        for exercise in catalogue {
            for request in requests {
                let breakdown = ExerciseScoring.score(exercise, request: request)
                for component in SelectionFixture.components(of: breakdown) {
                    #expect(
                        component.value >= 0 && component.value <= 1,
                        "\(component.name) was \(component.value) for \(exercise.id) \(exercise.name)"
                    )
                }
                #expect(breakdown.total >= 0 && breakdown.total <= 1)
            }
        }
    }

    @Test("A prioritised group's best options approach the ceiling without ever crossing it")
    func priorityBonusNeverPushesTheTotalAboveOne() {
        let perfect = SelectionFixture.exercise(
            id: "x",
            metadata: SelectionFixture.metadata(
                difficulty: .beginner,
                stability: 0,
                fatigue: 0.05,
                stimulus: 1,
                progression: 1,
                repRange: .hypertrophy,
                volume: [.chest: 1.0, .triceps: 1.0, .shoulders: 1.0],
                tags: ["machine", "supported"],
                staple: 1
            )
        )
        let request = SelectionFixture.request(
            pattern: .horizontalPush,
            mechanic: .compound,
            profile: SelectionFixture.profile(
                experience: .beginner,
                technique: .coached,
                goals: [.buildMuscle],
                priorities: [.chest, .triceps, .shoulders]
            ),
            preferences: ["x": SelectionFixture.preference("x", favorite: true, feedback: .love)]
        )
        let breakdown = ExerciseScoring.score(perfect, request: request)
        #expect(breakdown.total <= 1)
        #expect(breakdown.total > 0.8)
    }

    @Test("Clamping refuses non-finite values rather than propagating them")
    func clampingHandlesNonFiniteValues() {
        #expect(ExerciseScoring.clamp01(-5) == 0)
        #expect(ExerciseScoring.clamp01(5) == 1)
        #expect(ExerciseScoring.clamp01(0.25) == 0.25)
        #expect(ExerciseScoring.clamp01(.nan) == 0)
        #expect(ExerciseScoring.clamp01(.infinity) == 0)
        #expect(ExerciseScoring.clamp01(-.infinity) == 0)
    }
}

// MARK: - Individual factors

@Suite("Exercise score factors")
struct ExerciseScoreFactorTests {

    private let tolerance = 1e-9

    @Test("Target match is full for a direct hit and the volume credit for indirect work")
    func targetMatchReflectsHowDirectlyTheExerciseTrainsTheGroup() {
        let direct = SelectionFixture.exercise(
            id: "a",
            target: .pectorals,
            metadata: SelectionFixture.metadata(volume: [.chest: 1.0, .triceps: 0.5])
        )
        let indirect = SelectionFixture.exercise(
            id: "b",
            target: .triceps,
            metadata: SelectionFixture.metadata(volume: [.triceps: 1.0, .chest: 0.5])
        )
        let unrelated = SelectionFixture.exercise(
            id: "c",
            target: .calves,
            metadata: SelectionFixture.metadata(volume: [.calves: 1.0])
        )
        let request = SelectionFixture.request(target: .chest)

        #expect(ExerciseScoring.score(direct, request: request).targetMatch == 1)
        #expect(ExerciseScoring.score(indirect, request: request).targetMatch == 0.5)
        #expect(ExerciseScoring.score(unrelated, request: request).targetMatch == 0)
    }

    @Test("A missing opinion and a neutral opinion both score exactly neutral")
    func preferenceScoreTreatsSilenceAsNeutral() {
        #expect(ExerciseScoring.preferenceScore(nil) == 0.5)
        #expect(ExerciseScoring.preferenceScore(SelectionFixture.preference("a")) == 0.5)
    }

    @Test("Preference maps monotonically from never-recommend up to a loved favourite")
    func preferenceScoreIsMonotone() {
        let disliked = ExerciseScoring.preferenceScore(SelectionFixture.preference("a", feedback: .dislike))
        let liked = ExerciseScoring.preferenceScore(SelectionFixture.preference("a", feedback: .like))
        let loved = ExerciseScoring.preferenceScore(SelectionFixture.preference("a", feedback: .love))
        let lovedFavourite = ExerciseScoring.preferenceScore(
            SelectionFixture.preference("a", favorite: true, feedback: .love)
        )
        let excluded = ExerciseScoring.preferenceScore(SelectionFixture.preference("a", excluded: true))

        #expect(excluded == 0)
        #expect(disliked < 0.5)
        #expect(liked > 0.5)
        #expect(loved > liked)
        #expect(lovedFavourite > loved)
        #expect(abs(lovedFavourite - 0.81) < tolerance)
        #expect(lovedFavourite <= 1)
    }

    @Test("History is neutral when there is none, one session, or nothing comparable")
    func historicalPerformanceStaysNeutralWithoutUsableData() {
        #expect(ExerciseScoring.historicalPerformance(nil) == 0.5)

        let empty = SelectionFixture.history(id: "a", sessions: [])
        #expect(ExerciseScoring.historicalPerformance(empty) == 0.5)

        let single = SelectionFixture.history(
            id: "a",
            sessions: [[SelectionFixture.performedSet(weightKg: 100, reps: 5)]]
        )
        #expect(ExerciseScoring.historicalPerformance(single) == 0.5)

        // Sessions with no usable sets at all cannot produce a proxy.
        let unusable = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(weightKg: nil, reps: nil)],
                [SelectionFixture.performedSet(weightKg: nil, reps: nil)]
            ]
        )
        #expect(ExerciseScoring.historicalPerformance(unusable) == 0.5)

        // Only working sets count, so a pair of warm-ups is still no evidence.
        let warmupsOnly = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(weightKg: 100, reps: 5, kind: .warmup)],
                [SelectionFixture.performedSet(weightKg: 50, reps: 5, kind: .warmup)]
            ]
        )
        #expect(ExerciseScoring.historicalPerformance(warmupsOnly) == 0.5)
    }

    @Test("History rises with demonstrated progress and falls with regression, saturating at both ends")
    func historicalPerformanceFollowsTheTrend() {
        // Newest first: 102 kg now against 100 kg then is +2 %, worth +0.10.
        let slightGain = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(weightKg: 102, reps: 5)],
                [SelectionFixture.performedSet(weightKg: 100, reps: 5)]
            ]
        )
        #expect(abs(ExerciseScoring.historicalPerformance(slightGain) - 0.6) < 1e-6)

        let bigGain = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(weightKg: 150, reps: 5)],
                [SelectionFixture.performedSet(weightKg: 100, reps: 5)]
            ]
        )
        #expect(abs(ExerciseScoring.historicalPerformance(bigGain) - 0.9) < 1e-6)

        let slightLoss = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(weightKg: 96, reps: 5)],
                [SelectionFixture.performedSet(weightKg: 100, reps: 5)]
            ]
        )
        #expect(abs(ExerciseScoring.historicalPerformance(slightLoss) - 0.3) < 1e-6)

        let collapse = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(weightKg: 50, reps: 5)],
                [SelectionFixture.performedSet(weightKg: 100, reps: 5)]
            ]
        )
        #expect(abs(ExerciseScoring.historicalPerformance(collapse) - 0.15) < 1e-6)
    }

    @Test("Two sessions measured in different units are declined rather than divided")
    func historicalPerformanceDeclinesToCompareIncompatibleUnits() {
        let mixed = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(weightKg: 100, reps: 5)],
                [SelectionFixture.performedSet(weightKg: nil, reps: 12)]
            ]
        )
        #expect(ExerciseScoring.historicalPerformance(mixed) == 0.5)

        let secondsAgainstReps = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(durationSeconds: 60)],
                [SelectionFixture.performedSet(weightKg: nil, reps: 12)]
            ]
        )
        #expect(ExerciseScoring.historicalPerformance(secondsAgainstReps) == 0.5)
    }

    @Test("Unloadable work is compared in reps, then in held seconds")
    func historicalPerformanceFallsBackToRepsThenSeconds() {
        let reps = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(reps: 12), SelectionFixture.performedSet(reps: 12)],
                [SelectionFixture.performedSet(reps: 10), SelectionFixture.performedSet(reps: 10)]
            ]
        )
        #expect(ExerciseScoring.historicalPerformance(reps) > 0.5)

        let seconds = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(durationSeconds: 45)],
                [SelectionFixture.performedSet(durationSeconds: 60)]
            ]
        )
        #expect(ExerciseScoring.historicalPerformance(seconds) < 0.5)
    }

    @Test("The one-rep-max estimate is capped at twenty reps so a light high-rep day is not a record")
    func strengthProxyCapsRepsAtTwenty() {
        let cappedPair = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(weightKg: 100, reps: 30)],
                [SelectionFixture.performedSet(weightKg: 100, reps: 20)]
            ]
        )
        #expect(ExerciseScoring.historicalPerformance(cappedPair) == 0.5)
    }

    @Test("A zero-weight session cannot divide the trend by zero")
    func historicalPerformanceSurvivesAZeroProxy() {
        let zeroOldest = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(weightKg: 100, reps: 5)],
                [SelectionFixture.performedSet(weightKg: 0, reps: 0)]
            ]
        )
        let value = ExerciseScoring.historicalPerformance(zeroOldest)
        #expect(value == 0.5)
        #expect(value.isFinite)
    }

    @Test("Only the five most recent sessions colour today's choice")
    func historicalPerformanceLooksAtAFiveSessionWindow() {
        // Newest first. The sixth session is ancient and must not be the comparison point.
        let history = SelectionFixture.history(
            id: "a",
            sessions: [
                [SelectionFixture.performedSet(weightKg: 104, reps: 5)],
                [SelectionFixture.performedSet(weightKg: 103, reps: 5)],
                [SelectionFixture.performedSet(weightKg: 102, reps: 5)],
                [SelectionFixture.performedSet(weightKg: 101, reps: 5)],
                [SelectionFixture.performedSet(weightKg: 100, reps: 5)],
                [SelectionFixture.performedSet(weightKg: 10, reps: 5)]
            ]
        )
        // 104 against 100 is +4 %, not +940 %.
        #expect(abs(ExerciseScoring.historicalPerformance(history) - 0.7) < 1e-6)
    }

    @Test("Movement diversity follows the documented table")
    func movementDiversityMatchesTheTable() {
        let exercise = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(pattern: .horizontalPush)
        )

        func diversity(pattern preferred: MovementPattern?, used: Set<MovementPattern>) -> Double {
            ExerciseScoring.score(
                exercise,
                request: SelectionFixture.request(pattern: preferred, patternsUsed: used)
            ).movementDiversity
        }

        #expect(abs(diversity(pattern: .horizontalPush, used: []) - 1.00) < tolerance)
        #expect(abs(diversity(pattern: .horizontalPush, used: [.horizontalPush]) - 0.60) < tolerance)
        #expect(abs(diversity(pattern: nil, used: []) - 0.75) < tolerance)
        #expect(abs(diversity(pattern: nil, used: [.horizontalPush]) - 0.20) < tolerance)
        #expect(abs(diversity(pattern: .verticalPull, used: []) - 0.50) < tolerance)
        #expect(abs(diversity(pattern: .verticalPull, used: [.horizontalPush]) - 0.10) < tolerance)
    }

    @Test("Covering the antagonist of a trained pattern earns a nudge")
    func movementDiversityRewardsBalancingTheSession() {
        let push = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(pattern: .horizontalPush)
        )
        let plain = ExerciseScoring.score(
            push, request: SelectionFixture.request(patternsUsed: [])
        ).movementDiversity
        let balancing = ExerciseScoring.score(
            push, request: SelectionFixture.request(patternsUsed: [.horizontalPull])
        ).movementDiversity

        #expect(abs(plain - 0.75) < tolerance)
        #expect(abs(balancing - 0.87) < tolerance)
        #expect(balancing > plain)
    }

    @Test("Fatigue efficiency survives a zero fatigue cost and a zero stimulus")
    func fatigueEfficiencyHandlesZeroInputs() {
        func efficiency(stimulus: Double, fatigue: Double, favorLowFatigue: Bool = false) -> Double {
            let exercise = SelectionFixture.exercise(
                id: "a",
                metadata: SelectionFixture.metadata(fatigue: fatigue, stimulus: stimulus)
            )
            return ExerciseScoring.score(
                exercise,
                request: SelectionFixture.request(favorLowFatigue: favorLowFatigue)
            ).fatigueEfficiency
        }

        // The floor of 0.05 on fatigue cost is what stops the division by zero.
        let free = efficiency(stimulus: 0.5, fatigue: 0)
        let expectedFree: Double = 10.0 / 11.0
        #expect(abs(free - expectedFree) < 1e-9)

        let nothing = efficiency(stimulus: 0, fatigue: 0)
        #expect(nothing == 0)
        #expect(nothing.isFinite)

        // Equal stimulus and fatigue sits exactly at the midpoint.
        #expect(abs(efficiency(stimulus: 0.5, fatigue: 0.5) - 0.5) < 1e-9)

        // A nearly-full session blends in the absolute cost.
        let blended = efficiency(stimulus: 0.5, fatigue: 0.5, favorLowFatigue: true)
        let expectedBlend: Double = 0.55 * 0.5 + 0.45 * 0.5
        #expect(abs(blended - expectedBlend) < 1e-9)
        let cheap = efficiency(stimulus: 0.5, fatigue: 0.1, favorLowFatigue: true)
        #expect(cheap > blended)
    }

    @Test("A movement graded above the user is demoted rather than banned")
    func difficultyOvershootIsADemotionNotABan() {
        let advanced = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(difficulty: .advanced)
        )
        let request = SelectionFixture.request(
            profile: SelectionFixture.profile(experience: .beginner, technique: .learning)
        )
        let breakdown = ExerciseScoring.score(advanced, request: request)

        #expect(!breakdown.isDisqualified)
        #expect(breakdown.total > 0)
        // Two grades above a beginner's ceiling: 0.12 × 2.
        #expect(abs(breakdown.exclusionPenalty - 0.24) < 1e-9)
    }

    @Test("An untrained user is kept further from the edge, and the penalty still has a ceiling")
    func untrainedUsersGetTheLargerOvershootPenaltyUpToTheCeiling() {
        let advanced = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(difficulty: .advanced)
        )
        let never = ExerciseScoring.score(
            advanced,
            request: SelectionFixture.request(
                profile: SelectionFixture.profile(experience: .never, technique: .learning)
            )
        )
        let beginner = ExerciseScoring.score(
            advanced,
            request: SelectionFixture.request(
                profile: SelectionFixture.profile(experience: .beginner, technique: .learning)
            )
        )

        // 0.12 × 2 × 1.5 = 0.36, which is also the ceiling.
        #expect(abs(never.exclusionPenalty - 0.36) < 1e-9)
        #expect(never.exclusionPenalty > beginner.exclusionPenalty)
        #expect(never.total < beginner.total)
    }

    @Test("Coaching raises the difficulty ceiling and being self-taught lowers it")
    func techniqueConfidenceShiftsTheDifficultyCeiling() {
        let intermediate = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(difficulty: .intermediate)
        )

        func penalty(_ technique: TechniqueConfidence) -> Double {
            ExerciseScoring.score(
                intermediate,
                request: SelectionFixture.request(
                    profile: SelectionFixture.profile(experience: .beginner, technique: technique)
                )
            ).exclusionPenalty
        }

        #expect(penalty(.coached) == 0)
        #expect(abs(penalty(.learning) - 0.12) < 1e-9)
        #expect(abs(penalty(.confident) - 0.12) < 1e-9)
        #expect(abs(penalty(.unfamiliar) - 0.24) < 1e-9)
    }

    @Test("A novice is steered away from balance-limited movements; an experienced lifter is not")
    func stabilityDemandOnlyPenalisesNovices() {
        func suitability(_ experience: ExperienceLevel, stability: Double) -> Double {
            let exercise = SelectionFixture.exercise(
                id: "a",
                metadata: SelectionFixture.metadata(stability: stability, tags: ["press"])
            )
            return ExerciseScoring.score(
                exercise,
                request: SelectionFixture.request(
                    profile: SelectionFixture.profile(experience: experience, technique: .confident)
                )
            ).experienceSuitability
        }

        #expect(suitability(.beginner, stability: 0.9) < suitability(.beginner, stability: 0.2))
        // Below the comfort threshold balance demand is irrelevant even to a novice.
        #expect(suitability(.beginner, stability: 0.45) == suitability(.beginner, stability: 0.2))
        #expect(suitability(.advanced, stability: 0.9) == suitability(.advanced, stability: 0.2))
    }

    @Test("Beginner machine work is a poor use of an advanced lifter's session")
    func advancedLiftersAreNudgedAwayFromBeginnerMachineWork() {
        let machine = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(difficulty: .beginner, tags: ["press", "machine"])
        )
        let free = SelectionFixture.exercise(
            id: "b",
            metadata: SelectionFixture.metadata(difficulty: .beginner, tags: ["press"])
        )
        let request = SelectionFixture.request(
            profile: SelectionFixture.profile(experience: .advanced, technique: .confident)
        )
        let machineValue = ExerciseScoring.score(machine, request: request).experienceSuitability
        let freeValue = ExerciseScoring.score(free, request: request).experienceSuitability

        #expect(abs((freeValue - machineValue) - 0.08) < 1e-9)
    }

    @Test("A guided path is worth a bonus for somebody with no technique to fall back on")
    func novicesAreNudgedTowardsSupportedMovements() {
        let machine = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(difficulty: .beginner, tags: ["press", "machine"])
        )
        let free = SelectionFixture.exercise(
            id: "b",
            metadata: SelectionFixture.metadata(difficulty: .beginner, tags: ["press"])
        )
        let request = SelectionFixture.request(
            profile: SelectionFixture.profile(experience: .never, technique: .learning)
        )
        #expect(
            ExerciseScoring.score(machine, request: request).experienceSuitability
                > ExerciseScoring.score(free, request: request).experienceSuitability
        )
    }

    @Test("A slot that asked for a compound demotes an isolation instead of banning it")
    func mismatchedMechanicCostsSixtyPercentOfTheGoalScore() {
        let isolation = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(mechanic: .isolation)
        )
        let open = ExerciseScoring.score(
            isolation, request: SelectionFixture.request(mechanic: nil)
        ).goalSuitability
        let mismatched = ExerciseScoring.score(
            isolation, request: SelectionFixture.request(mechanic: .compound)
        ).goalSuitability

        let expectedMismatch: Double = open * 0.6
        #expect(abs(mismatched - expectedMismatch) < 1e-9)
        #expect(mismatched > 0)
    }

    @Test("An empty goal list is treated as general fitness rather than as no opinion at all")
    func emptyGoalsFallBackToGeneralFitness() {
        let exercise = SelectionFixture.exercise(id: "a")
        let empty = ExerciseScoring.score(
            exercise,
            request: SelectionFixture.request(profile: SelectionFixture.profile(goals: []))
        ).goalSuitability
        let general = ExerciseScoring.score(
            exercise,
            request: SelectionFixture.request(profile: SelectionFixture.profile(goals: [.generalFitness]))
        ).goalSuitability

        #expect(empty == general)
        #expect(empty > 0)
    }

    @Test("Goals are blended rather than switched on, and only the first three are consulted")
    func goalsAreBlendedWithDecayingWeights() {
        // A pure strength movement: highly progressable, compound, low rep range.
        let strengthExercise = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(
                mechanic: .compound,
                stimulus: 0.4,
                progression: 1.0,
                repRange: .strength
            )
        )
        func value(_ goals: [TrainingGoal]) -> Double {
            ExerciseScoring.score(
                strengthExercise,
                request: SelectionFixture.request(profile: SelectionFixture.profile(goals: goals))
            ).goalSuitability
        }

        let pureStrength = value([.buildStrength])
        let strengthThenEndurance = value([.buildStrength, .improveEndurance])
        let pureEndurance = value([.improveEndurance])

        #expect(pureStrength > strengthThenEndurance)
        #expect(strengthThenEndurance > pureEndurance)

        // A fourth goal is beyond where the list still expresses a preference.
        #expect(
            value([.buildStrength, .buildMuscle, .loseFat])
                == value([.buildStrength, .buildMuscle, .loseFat, .improveEndurance])
        )
    }

    @Test("A movement with no rep window neither fits nor misfits a goal's rep range")
    func timedWorkGetsANeutralRepRangeAffinity() {
        // buildStrength = 0.42·progression + 0.28·compoundness + 0.30·affinity, affinity 0.55.
        let plank = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(
                mechanic: .compound,
                tracking: .duration,
                progression: 0.5
            )
        )
        let expected = 0.42 * 0.5 + 0.28 * 1.0 + 0.30 * 0.55
        let actual = ExerciseScoring.score(
            plank,
            request: SelectionFixture.request(profile: SelectionFixture.profile(goals: [.buildStrength]))
        ).goalSuitability

        #expect(abs(actual - expected) < 1e-9)
    }

    @Test("Secondary utility rewards work that also feeds the user's other priorities")
    func secondaryUtilityFollowsThePriorityList() {
        let servesBiceps = SelectionFixture.exercise(
            id: "a",
            target: .lats,
            metadata: SelectionFixture.metadata(volume: [.back: 1.0, .biceps: 1.0])
        )
        let servesNothingElse = SelectionFixture.exercise(
            id: "b",
            target: .lats,
            metadata: SelectionFixture.metadata(volume: [.back: 1.0])
        )
        let request = SelectionFixture.request(
            target: .back,
            profile: SelectionFixture.profile(priorities: [.back, .biceps])
        )

        let helpful = ExerciseScoring.score(servesBiceps, request: request).secondaryUtility
        let plain = ExerciseScoring.score(servesNothingElse, request: request).secondaryUtility

        // The slot's own group drops out of the priority list, so biceps is the head of it and
        // keeps the full rank of 1.0: 0.65 · best + 0.35 · min(1, Σ/2).
        let expected: Double = 0.65 * 1.0 + 0.35 * 0.5
        #expect(abs(helpful - expected) < 1e-9)
        #expect(plain == 0)
        #expect(helpful > plain)
    }

    @Test("Without stated priorities, secondary utility rewards honest whole-movement coverage")
    func secondaryUtilityFallsBackToIndirectCoverage() {
        let compound = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(volume: [.chest: 1.0, .triceps: 0.5, .shoulders: 0.5])
        )
        let isolation = SelectionFixture.exercise(
            id: "b",
            metadata: SelectionFixture.metadata(volume: [.chest: 1.0])
        )
        let request = SelectionFixture.request(target: .chest)

        let expectedCoverage: Double = 1.0 / 1.5
        let compoundUtility = ExerciseScoring.score(compound, request: request).secondaryUtility
        #expect(abs(compoundUtility - expectedCoverage) < 1e-9)
        #expect(ExerciseScoring.score(isolation, request: request).secondaryUtility == 0)
    }

    @Test("The priority bonus counts indirect work at half and decays down the priority list")
    func priorityBonusRewardsDirectWorkOnAPrioritisedGroup() {
        let direct = SelectionFixture.exercise(
            id: "a",
            target: .pectorals,
            metadata: SelectionFixture.metadata(volume: [.chest: 1.0])
        )
        let indirect = SelectionFixture.exercise(
            id: "b",
            target: .triceps,
            metadata: SelectionFixture.metadata(volume: [.triceps: 1.0, .chest: 0.5])
        )

        func bonus(_ exercise: Exercise, priorities: [MuscleGroup]) -> Double {
            ExerciseScoring.score(
                exercise,
                request: SelectionFixture.request(
                    target: .chest,
                    profile: SelectionFixture.profile(priorities: priorities)
                )
            ).priorityBonus
        }

        #expect(bonus(direct, priorities: []) == 0)
        #expect(bonus(direct, priorities: [.chest]) == 1)
        #expect(bonus(indirect, priorities: [.chest]) == 0.5)
        #expect(abs(bonus(direct, priorities: [.back, .chest]) - 0.9) < 1e-9)
        // The rank decay bottoms out at 0.6 rather than running to zero.
        #expect(
            abs(bonus(direct, priorities: [.back, .biceps, .triceps, .quads, .glutes, .chest]) - 0.6) < 1e-9
        )
    }

    @Test("Repeating something the user just did costs variety, less so for a favourite")
    func recentRepetitionIsPenalisedUnlessTheUserLovesIt() {
        let exercise = SelectionFixture.exercise(id: "a")

        let fresh = ExerciseScoring.score(exercise, request: SelectionFixture.request())
        #expect(fresh.recentRepetitionPenalty == 0)

        let repeated = ExerciseScoring.score(
            exercise, request: SelectionFixture.request(recentlyUsed: ["a"])
        )
        #expect(abs(repeated.recentRepetitionPenalty - 0.7) < 1e-9)
        #expect(repeated.total < fresh.total)

        let favourite = ExerciseScoring.score(
            exercise,
            request: SelectionFixture.request(
                preferences: ["a": SelectionFixture.preference("a", favorite: true)],
                recentlyUsed: ["a"]
            )
        )
        #expect(abs(favourite.recentRepetitionPenalty - 0.35) < 1e-9)

        let loved = ExerciseScoring.score(
            exercise,
            request: SelectionFixture.request(
                preferences: ["a": SelectionFixture.preference("a", feedback: .love)],
                recentlyUsed: ["a"]
            )
        )
        #expect(abs(loved.recentRepetitionPenalty - 0.35) < 1e-9)
    }

    @Test("Progression suitability and staple score are passed through unchanged")
    func metadataScoresArePassedThroughVerbatim() {
        let exercise = SelectionFixture.exercise(
            id: "a",
            metadata: SelectionFixture.metadata(progression: 0.42, staple: 0.17)
        )
        let breakdown = ExerciseScoring.score(exercise, request: SelectionFixture.request())
        #expect(breakdown.progressionSuitability == 0.42)
        #expect(breakdown.stapleBonus == 0.17)
    }

    @Test("Equipment availability is a gate, so anything that is scored at all scores full marks")
    func equipmentAvailabilityIsConstantForEverythingThatPassesTheGate() {
        let exercise = SelectionFixture.exercise(id: "a", equipment: .cable)
        let breakdown = ExerciseScoring.score(
            exercise,
            request: SelectionFixture.request(
                profile: SelectionFixture.profile(equipment: [.cable])
            )
        )
        #expect(breakdown.equipmentAvailability == 1)
    }
}

// MARK: - Weighting

@Suite("Low-fatigue re-weighting")
struct ExerciseScoringWeightTests {

    @Test("The default weights sum to exactly one so totals are comparable across releases")
    func defaultAdditiveWeightsSumToOne() {
        #expect(abs(ExerciseScoringWeights.default.additiveSum - 1.0) < 1e-12)
    }

    @Test("A normal slot leaves the weights alone")
    func normalSlotDoesNotReweight() {
        let weights = ExerciseScoringWeights.default
        let applied = ExerciseScoring.effectiveWeights(weights, for: SelectionFixture.request())
        #expect(applied == weights)
    }

    @Test("A nearly-full session moves weight into fatigue efficiency without changing the scale")
    func lowFatigueReweightingPreservesTheAdditiveSum() {
        let weights = ExerciseScoringWeights.default
        let applied = ExerciseScoring.effectiveWeights(
            weights,
            for: SelectionFixture.request(favorLowFatigue: true)
        )

        #expect(abs(applied.additiveSum - weights.additiveSum) < 1e-12)
        #expect(abs(applied.fatigueEfficiency - 0.13) < 1e-12)
        #expect(applied.targetMatch < weights.targetMatch)
        // The penalty weights are outside the additive sum and must not move.
        #expect(applied.recentRepetitionPenalty == weights.recentRepetitionPenalty)
        #expect(applied.priorityBonus == weights.priorityBonus)
    }

    @Test("Re-weighting degrades gracefully when there is nothing left to take weight from")
    func lowFatigueReweightingIsANoOpWithNoOtherWeight() {
        var weights = ExerciseScoringWeights.default
        weights.targetMatch = 0
        weights.secondaryUtility = 0
        weights.goalSuitability = 0
        weights.equipmentAvailability = 0
        weights.userPreference = 0
        weights.historicalPerformance = 0
        weights.movementDiversity = 0
        weights.progressionSuitability = 0
        weights.experienceSuitability = 0
        weights.stapleBonus = 0

        let applied = ExerciseScoring.effectiveWeights(
            weights,
            for: SelectionFixture.request(favorLowFatigue: true)
        )
        #expect(applied == weights)
    }

    @Test("Zero weights everywhere produce a zero score rather than a crash")
    func zeroWeightsProduceAZeroScore() {
        var weights = ExerciseScoringWeights.default
        weights.targetMatch = 0
        weights.secondaryUtility = 0
        weights.goalSuitability = 0
        weights.equipmentAvailability = 0
        weights.userPreference = 0
        weights.historicalPerformance = 0
        weights.movementDiversity = 0
        weights.progressionSuitability = 0
        weights.fatigueEfficiency = 0
        weights.experienceSuitability = 0
        weights.stapleBonus = 0
        weights.priorityBonus = 0
        weights.recentRepetitionPenalty = 0

        let breakdown = ExerciseScoring.score(
            SelectionFixture.exercise(id: "a"),
            request: SelectionFixture.request(),
            weights: weights
        )
        #expect(breakdown.total == 0)
        #expect(!breakdown.isDisqualified)
    }

    @Test("Scoring is a pure function: the same request twice gives an identical breakdown")
    func scoringIsPure() {
        let exercise = SelectionFixture.exercise(id: "a")
        let request = SelectionFixture.request(
            preferences: ["a": SelectionFixture.preference("a", feedback: .like)],
            histories: [
                "a": SelectionFixture.history(
                    id: "a",
                    sessions: [
                        [SelectionFixture.performedSet(weightKg: 102, reps: 5)],
                        [SelectionFixture.performedSet(weightKg: 100, reps: 5)]
                    ]
                )
            ],
            recentlyUsed: ["z"],
            patternsUsed: [.verticalPull]
        )
        #expect(ExerciseScoring.score(exercise, request: request) == ExerciseScoring.score(exercise, request: request))
    }
}
