import Foundation
import Testing
@testable import GymApp

// MARK: - Fixtures

private enum SubstitutionFixture {

    static func request(
        original: Exercise,
        reason: SubstitutionReason? = nil,
        equipment: Set<Equipment> = Equipment.fullGym,
        profile: TrainingProfileSnapshot = SelectionFixture.profile(),
        preferences: [String: ExercisePreferenceSnapshot] = [:],
        histories: [String: ExerciseHistorySnapshot] = [:],
        inSession: Set<String> = [],
        limit: Int = 20
    ) -> SubstitutionRequest {
        var request = SubstitutionRequest(
            original: original,
            availableEquipment: equipment,
            profile: profile
        )
        request.reason = reason
        request.preferences = preferences
        request.histories = histories
        request.exercisesInSession = inSession
        request.limit = limit
        return request
    }

    static func chestPress(
        id: String,
        equipment: Equipment,
        difficulty: Difficulty = .intermediate,
        pattern: MovementPattern = .horizontalPush,
        mechanic: Mechanic = .compound,
        laterality: Laterality = .bilateral,
        stability: Double = 0.5,
        tags: Set<String> = ["press", "flat"],
        target: Muscle = .pectorals,
        volume: [MuscleGroup: Double] = [.chest: 1.0, .triceps: 0.5],
        staple: Double = 0.5
    ) -> Exercise {
        SelectionFixture.exercise(
            id: id,
            equipment: equipment,
            target: target,
            synergist: .triceps,
            secondary: [.delts],
            metadata: SelectionFixture.metadata(
                pattern: pattern,
                mechanic: mechanic,
                difficulty: difficulty,
                laterality: laterality,
                stability: stability,
                volume: volume,
                tags: tags,
                staple: staple
            )
        )
    }

    /// The exercise being replaced in every reason test: a bilateral intermediate barbell press.
    static let original = chestPress(
        id: "orig",
        equipment: .barbell,
        difficulty: .intermediate,
        stability: 0.6,
        tags: ["press", "wide_grip"],
        staple: 0.9
    )

    /// One plausible alternative per implement class and per difficulty, so each reason has both
    /// something to keep and something to reject.
    static let chestCatalogue: [Exercise] = [
        original,
        chestPress(id: "db-press", equipment: .dumbbell, difficulty: .intermediate, tags: ["press", "neutral_grip"]),
        chestPress(
            id: "machine-press",
            equipment: .leverageMachine,
            difficulty: .beginner,
            stability: 0.2,
            tags: ["press", "machine", "seated"]
        ),
        chestPress(
            id: "cable-fly",
            equipment: .cable,
            difficulty: .beginner,
            pattern: .chestFly,
            mechanic: .isolation,
            stability: 0.3,
            tags: ["fly"],
            volume: [.chest: 1.0]
        ),
        chestPress(id: "push-up", equipment: .bodyWeight, difficulty: .beginner, stability: 0.4, tags: ["press", "floor"]),
        chestPress(
            id: "deficit-push-up",
            equipment: .bodyWeight,
            difficulty: .advanced,
            stability: 0.8,
            tags: ["press", "deficit"]
        ),
        chestPress(id: "weighted-dip", equipment: .weighted, difficulty: .advanced, stability: 0.7, tags: ["dip"]),
        chestPress(id: "assisted-dip", equipment: .assisted, difficulty: .beginner, stability: 0.3, tags: ["dip", "machine"]),
        chestPress(id: "band-press", equipment: .band, difficulty: .beginner, stability: 0.4, tags: ["press", "floor"]),
        chestPress(id: "ez-press", equipment: .ezBarbell, difficulty: .intermediate, tags: ["press", "flat"]),
        chestPress(
            id: "wide-machine",
            equipment: .smithMachine,
            difficulty: .beginner,
            tags: ["press", "wide_grip", "machine"]
        ),
        chestPress(
            id: "single-arm-cable",
            equipment: .cable,
            difficulty: .intermediate,
            laterality: .unilateral,
            stability: 0.6,
            tags: ["press", "unilateral"]
        ),
        // Two movements from an unrelated group, to prove the pool is not the whole catalogue.
        SelectionFixture.exercise(
            id: "leg-curl",
            equipment: .leverageMachine,
            target: .hamstrings,
            synergist: .glutes,
            secondary: [],
            metadata: SelectionFixture.metadata(
                pattern: .kneeFlexion,
                pushPull: .legs,
                mechanic: .isolation,
                volume: [.hamstrings: 1.0],
                tags: ["curl", "machine"]
            )
        ),
        SelectionFixture.exercise(
            id: "back-squat",
            equipment: .barbell,
            target: .quads,
            synergist: .glutes,
            secondary: [],
            metadata: SelectionFixture.metadata(
                pattern: .squat,
                pushPull: .legs,
                volume: [.quads: 1.0, .glutes: 0.5],
                tags: ["squat", "axial_load"]
            )
        )
    ]

    static let engine = ExerciseSubstitutionEngine(catalog: chestCatalogue)

    static func exercise(_ id: String) -> Exercise {
        chestCatalogue.first { $0.id == id } ?? original
    }
}

// MARK: - Similarity

@Suite("Substitution similarity")
struct SubstitutionSimilarityTests {

    @Test("Similarity is symmetric")
    func similarityIsSymmetric() {
        let engine = SubstitutionFixture.engine
        for left in SubstitutionFixture.chestCatalogue {
            for right in SubstitutionFixture.chestCatalogue {
                let forward = engine.similarity(left, right)
                let backward = engine.similarity(right, left)
                #expect(
                    abs(forward - backward) < 1e-12,
                    "\(left.id) → \(right.id) was \(forward) but \(backward) the other way round"
                )
            }
        }
    }

    @Test("Similarity is symmetric across the shipping catalogue too")
    func similarityIsSymmetricOnTheRealCatalogue() throws {
        let catalogue = SelectionCatalogue.exercises
        try #require(!catalogue.isEmpty, "The shipping catalogue failed to load")
        let engine = SelectionCatalogue.substitution

        // A fixed, spread-out sample: deterministic, and wide enough to hit every equipment family.
        let sample = stride(from: 0, to: catalogue.count, by: 53).map { catalogue[$0] }
        #expect(sample.count > 10)
        for left in sample {
            for right in sample {
                #expect(abs(engine.similarity(left, right) - engine.similarity(right, left)) < 1e-12)
            }
        }
    }

    @Test("Every exercise is essentially perfectly similar to itself")
    func anExerciseIsMaximallySimilarToItself() throws {
        let catalogue = SelectionCatalogue.exercises
        try #require(!catalogue.isEmpty, "The shipping catalogue failed to load")
        let engine = SelectionCatalogue.substitution

        for exercise in catalogue {
            let selfSimilarity = engine.similarity(exercise, exercise)
            #expect(selfSimilarity <= 1.0)
            #expect(
                selfSimilarity >= 0.9,
                "\(exercise.id) \(exercise.name) scored \(selfSimilarity) against itself"
            )
        }

        // A record with both tags and secondary muscles has no missing evidence at all.
        let bench = try #require(SelectionCatalogue.exercise(SelectionCatalogue.barbellBenchPressID))
        #expect(abs(engine.similarity(bench, bench) - 1.0) < 1e-12)
    }

    @Test("A known trio is ordered the way a coach would order it")
    func similarityOrdersAKnownTrioSensibly() throws {
        try #require(!SelectionCatalogue.exercises.isEmpty, "The shipping catalogue failed to load")
        let engine = SelectionCatalogue.substitution
        let bench = try #require(SelectionCatalogue.exercise(SelectionCatalogue.barbellBenchPressID))
        let dumbbell = try #require(SelectionCatalogue.exercise(SelectionCatalogue.dumbbellBenchPressID))
        let machine = try #require(SelectionCatalogue.exercise(SelectionCatalogue.leverChestPressID))
        let squat = try #require(SelectionCatalogue.exercise(SelectionCatalogue.barbellFullSquatID))
        let legCurl = try #require(SelectionCatalogue.exercise(SelectionCatalogue.leverLyingLegCurlID))

        let toDumbbell = engine.similarity(bench, dumbbell)
        let toMachine = engine.similarity(bench, machine)
        let toSquat = engine.similarity(bench, squat)
        let toLegCurl = engine.similarity(bench, legCurl)

        #expect(toDumbbell > toMachine, "dumbbell \(toDumbbell) should beat machine \(toMachine)")
        #expect(toMachine > toSquat, "machine \(toMachine) should beat squat \(toSquat)")
        #expect(toSquat > toLegCurl, "squat \(toSquat) should beat leg curl \(toLegCurl)")

        // The values documented in docs/fragments/selection.md for the shipping dataset.
        #expect(abs(toDumbbell - 0.94) < 0.05, "documented 0.94, measured \(toDumbbell)")
        #expect(abs(toMachine - 0.86) < 0.05, "documented 0.86, measured \(toMachine)")
        #expect(abs(toSquat - 0.22) < 0.05, "documented 0.22, measured \(toSquat)")
    }

    @Test("Similarity always lands in 0…1, whatever the pair")
    func similarityStaysInsideTheUnitInterval() throws {
        let catalogue = SelectionCatalogue.exercises
        try #require(!catalogue.isEmpty, "The shipping catalogue failed to load")
        let engine = SelectionCatalogue.substitution
        let sample = stride(from: 0, to: catalogue.count, by: 29).map { catalogue[$0] }

        for left in sample {
            for right in sample {
                let value = engine.similarity(left, right)
                #expect(value >= 0 && value <= 1, "\(left.id) → \(right.id) scored \(value)")
            }
        }
    }

    @Test("Unnormalised weights still produce a 0…1 result")
    func similarityRenormalisesItsOwnWeights() {
        let engine = SubstitutionFixture.engine
        let left = SubstitutionFixture.original
        let right = SubstitutionFixture.exercise("db-press")

        var doubled = SubstitutionWeights.default
        doubled.sameTarget *= 2
        doubled.samePattern *= 2
        doubled.secondaryOverlap *= 2
        doubled.samePushPull *= 2
        doubled.sameMechanic *= 2
        doubled.tagOverlap *= 2
        doubled.difficultyProximity *= 2
        doubled.equipmentFit *= 2

        #expect(
            abs(engine.similarity(left, right, weights: doubled)
                - engine.similarity(left, right, weights: .default)) < 1e-12
        )
    }

    @Test("Zero weights produce zero rather than a division by zero")
    func similarityWithNoWeightsIsZero() {
        var empty = SubstitutionWeights.default
        empty.sameTarget = 0
        empty.samePattern = 0
        empty.secondaryOverlap = 0
        empty.samePushPull = 0
        empty.sameMechanic = 0
        empty.tagOverlap = 0
        empty.difficultyProximity = 0
        empty.equipmentFit = 0

        let value = SubstitutionFixture.engine.similarity(
            SubstitutionFixture.original,
            SubstitutionFixture.exercise("db-press"),
            weights: empty
        )
        #expect(value == 0)
        #expect(value.isFinite)
    }

    @Test("An empty catalogue still answers a similarity question")
    func similarityWorksWithoutACatalogueToLearnTagRarityFrom() {
        let engine = ExerciseSubstitutionEngine(catalog: [])
        #expect(engine.catalogCount == 0)
        let value = engine.similarity(SubstitutionFixture.original, SubstitutionFixture.exercise("db-press"))
        #expect(value > 0 && value <= 1)
        #expect(engine.alternatives(for: SubstitutionFixture.request(original: SubstitutionFixture.original)).isEmpty)
    }
}

// MARK: - Candidates

@Suite("Substitution candidates")
struct SubstitutionCandidateTests {

    @Test("The exercise being replaced is never offered as its own replacement")
    func theOriginalNeverAppearsInItsOwnAlternatives() {
        let engine = SubstitutionFixture.engine
        for reason in [SubstitutionReason?.none] + SubstitutionReason.allCases.map({ Optional($0) }) {
            let candidates = engine.alternatives(
                for: SubstitutionFixture.request(original: SubstitutionFixture.original, reason: reason)
            )
            #expect(
                !candidates.contains { $0.id == SubstitutionFixture.original.id },
                "the original came back for reason \(String(describing: reason))"
            )
        }
    }

    @Test("Alternatives for a real exercise never include the exercise itself")
    func theOriginalNeverAppearsOnTheRealCatalogueEither() throws {
        try #require(!SelectionCatalogue.exercises.isEmpty, "The shipping catalogue failed to load")
        let bench = try #require(SelectionCatalogue.exercise(SelectionCatalogue.barbellBenchPressID))
        let candidates = SelectionCatalogue.substitution.alternatives(
            for: SubstitutionFixture.request(original: bench)
        )
        #expect(!candidates.isEmpty)
        #expect(!candidates.contains { $0.id == bench.id })
    }

    @Test("The same target muscle is what the top of the list is made of")
    func theSameTargetMuscleIsPreferred() throws {
        try #require(!SelectionCatalogue.exercises.isEmpty, "The shipping catalogue failed to load")
        let bench = try #require(SelectionCatalogue.exercise(SelectionCatalogue.barbellBenchPressID))
        let candidates = SelectionCatalogue.substitution.alternatives(
            for: SubstitutionFixture.request(original: bench, limit: 10)
        )
        try #require(candidates.count >= 5)

        #expect(candidates[0].matchesTarget)
        #expect(candidates.prefix(5).allSatisfy { $0.matchesTarget })
        #expect(candidates.allSatisfy { $0.exercise.primaryGroup == bench.primaryGroup })
        // Scores are ordered, and every candidate carries something to say for itself.
        #expect(candidates.map(\.score) == candidates.map(\.score).sorted(by: >))
        #expect(candidates.allSatisfy { !$0.reasons.isEmpty && $0.reasons.count <= 3 })
        #expect(candidates.allSatisfy { Set($0.reasons.map(\.key)).count == $0.reasons.count })
    }

    @Test("Equipment the user cannot reach is excluded outright, not merely demoted")
    func unavailableEquipmentIsExcludedOutright() {
        let candidates = SubstitutionFixture.engine.alternatives(
            for: SubstitutionFixture.request(
                original: SubstitutionFixture.original,
                equipment: [.dumbbell, .bodyWeight]
            )
        )
        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { [.dumbbell, .bodyWeight].contains($0.exercise.equipment) })
        #expect(Set(candidates.map(\.id)) == ["db-press", "push-up", "deficit-push-up"])
    }

    @Test("A blacklisted exercise never appears, however it was blacklisted")
    func blacklistedExercisesNeverAppear() {
        let candidates = SubstitutionFixture.engine.alternatives(
            for: SubstitutionFixture.request(
                original: SubstitutionFixture.original,
                profile: SelectionFixture.profile(excludedIDs: ["db-press"]),
                preferences: [
                    "machine-press": SelectionFixture.preference("machine-press", feedback: .neverRecommend),
                    "cable-fly": SelectionFixture.preference("cable-fly", excluded: true)
                ]
            )
        )
        let ids = Set(candidates.map(\.id))
        #expect(!ids.contains("db-press"))
        #expect(!ids.contains("machine-press"))
        #expect(!ids.contains("cable-fly"))
        #expect(!ids.isEmpty)
    }

    @Test("An exercise already in today's session is not offered as a swap for another")
    func exercisesAlreadyInTheSessionAreNotOffered() {
        let candidates = SubstitutionFixture.engine.alternatives(
            for: SubstitutionFixture.request(
                original: SubstitutionFixture.original,
                inSession: ["db-press", "push-up"]
            )
        )
        let ids = Set(candidates.map(\.id))
        #expect(!ids.contains("db-press"))
        #expect(!ids.contains("push-up"))
        #expect(!ids.isEmpty)
    }

    @Test("A movement the user cannot perform is not offered as a replacement")
    func mobilityLimitationsGateTheAlternatives() {
        let candidates = SubstitutionFixture.engine.alternatives(
            for: SubstitutionFixture.request(
                original: SubstitutionFixture.original,
                profile: SelectionFixture.profile(avoidedPatterns: [.chestFly])
            )
        )
        #expect(!candidates.contains { $0.exercise.metadata.movementPattern == .chestFly })
    }

    @Test("A limit of zero returns nothing, and the limit is never exceeded")
    func theLimitIsRespected() {
        let engine = SubstitutionFixture.engine
        #expect(
            engine.alternatives(
                for: SubstitutionFixture.request(original: SubstitutionFixture.original, limit: 0)
            ).isEmpty
        )
        #expect(
            engine.alternatives(
                for: SubstitutionFixture.request(original: SubstitutionFixture.original, limit: -1)
            ).isEmpty
        )
        #expect(
            engine.alternatives(
                for: SubstitutionFixture.request(original: SubstitutionFixture.original, limit: 3)
            ).count == 3
        )
    }

    @Test("The same substitution request twice returns the same list in the same order")
    func alternativesAreDeterministic() throws {
        try #require(!SelectionCatalogue.exercises.isEmpty, "The shipping catalogue failed to load")
        let bench = try #require(SelectionCatalogue.exercise(SelectionCatalogue.barbellBenchPressID))
        let request = SubstitutionFixture.request(
            original: bench,
            reason: .easier,
            preferences: ["0289": SelectionFixture.preference("0289", favorite: true, feedback: .love)],
            histories: [
                "0289": SelectionFixture.history(
                    id: "0289",
                    sessions: [
                        [SelectionFixture.performedSet(weightKg: 40, reps: 8)],
                        [SelectionFixture.performedSet(weightKg: 38, reps: 8)]
                    ],
                    totalSessions: 6
                )
            ]
        )

        let first = SelectionCatalogue.substitution.alternatives(for: request)
        let second = SelectionCatalogue.substitution.alternatives(for: request)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.score) == second.map(\.score))

        let rebuilt = ExerciseSubstitutionEngine(catalog: SelectionCatalogue.exercises)
        #expect(rebuilt.alternatives(for: request).map(\.id) == first.map(\.id))
    }

    @Test("Every candidate's score and similarity land inside 0…1")
    func candidateScoresStayInRange() throws {
        try #require(!SelectionCatalogue.exercises.isEmpty, "The shipping catalogue failed to load")
        let bench = try #require(SelectionCatalogue.exercise(SelectionCatalogue.barbellBenchPressID))

        for reason in SubstitutionReason.allCases {
            let candidates = SelectionCatalogue.substitution.alternatives(
                for: SubstitutionFixture.request(original: bench, reason: reason)
            )
            for candidate in candidates {
                #expect(candidate.score >= 0 && candidate.score <= 1, "\(candidate.id) scored \(candidate.score)")
                #expect(candidate.similarity >= 0 && candidate.similarity <= 1)
            }
        }
    }

    @Test("A thin primary pool is topped up from the wider index rather than left short")
    func aThinPoolIsToppedUpFromTheWiderIndex() {
        var catalogue: [Exercise] = [
            SubstitutionFixture.original,
            SubstitutionFixture.chestPress(id: "db-press", equipment: .dumbbell)
        ]
        for index in 0..<3 {
            catalogue.append(
                SelectionFixture.exercise(
                    id: "triceps-\(index)",
                    equipment: .cable,
                    target: .triceps,
                    synergist: .pectorals,
                    secondary: [],
                    metadata: SelectionFixture.metadata(
                        pattern: .elbowExtension,
                        mechanic: .isolation,
                        volume: [.triceps: 1.0, .chest: 0.5],
                        tags: ["pushdown"]
                    )
                )
            )
        }
        let engine = ExerciseSubstitutionEngine(catalog: catalogue)
        let ids = Set(
            engine.alternatives(for: SubstitutionFixture.request(original: SubstitutionFixture.original))
                .map(\.id)
        )
        #expect(ids.contains("db-press"))
        #expect(ids.count == 4, "expected the thin chest pool to be topped up, got \(ids)")
    }

    @Test("A favourite the user is progressing on is described as such")
    func candidatesExplainThemselvesInAFixedOrder() {
        let candidates = SubstitutionFixture.engine.alternatives(
            for: SubstitutionFixture.request(
                original: SubstitutionFixture.original,
                preferences: ["db-press": SelectionFixture.preference("db-press", favorite: true)]
            )
        )
        let dumbbell = candidates.first { $0.id == "db-press" }
        #expect(dumbbell != nil)
        // Same target muscle and same pattern, so the relationship line comes first.
        #expect(dumbbell?.reasons.first?.key == "substitution.reason.sameTargetAndPattern.push")
        #expect(dumbbell?.reasons.contains { $0.key == "substitution.reason.favorite" } == true)
        #expect(dumbbell?.matchesTarget == true)
        #expect(dumbbell?.matchesPattern == true)
    }
}

// MARK: - Reasons

@Suite("Substitution reasons")
struct SubstitutionReasonTests {

    private func ids(_ reason: SubstitutionReason?) -> [String] {
        SubstitutionFixture.engine.alternatives(
            for: SubstitutionFixture.request(original: SubstitutionFixture.original, reason: reason)
        ).map(\.id)
    }

    private func candidates(_ reason: SubstitutionReason?) -> [SubstitutionCandidate] {
        SubstitutionFixture.engine.alternatives(
            for: SubstitutionFixture.request(original: SubstitutionFixture.original, reason: reason)
        )
    }

    @Test("Bodyweight only returns bodyweight movements and nothing else")
    func bodyweightOnlyReturnsOnlyBodyweightOptions() {
        let result = candidates(.bodyweightOnly)
        #expect(!result.isEmpty)
        #expect(
            result.allSatisfy { [.bodyWeight, .assisted, .weighted].contains($0.exercise.equipment) },
            "got \(result.map { "\($0.id) \($0.exercise.equipment)" })"
        )
        // Plain bodyweight outranks its assisted and loaded cousins.
        #expect(result.first?.exercise.equipment == .bodyWeight)
    }

    @Test("Preferring dumbbells puts dumbbell work on top and drops everything else")
    func preferDumbbellPromotesDumbbellWork() {
        let result = candidates(.preferDumbbell)
        #expect(result.map(\.id) == ["db-press"])
        #expect(result.first?.exercise.equipment == .dumbbell)
    }

    @Test("Preferring a barbell keeps the barbell family only")
    func preferBarbellKeepsTheBarbellFamily() {
        let result = candidates(.preferBarbell)
        #expect(result.map(\.id) == ["ez-press"])
    }

    @Test("Preferring a cable keeps cable work only")
    func preferCableKeepsCableWork() {
        #expect(Set(ids(.preferCable)) == ["cable-fly", "single-arm-cable"])
    }

    @Test("A missing or occupied machine never returns the same implement")
    func machineUnavailableExcludesTheOriginalImplement() {
        for reason in [SubstitutionReason.machineUnavailable, .machineOccupied] {
            let result = candidates(reason)
            #expect(!result.isEmpty)
            #expect(
                result.allSatisfy { $0.exercise.equipment != SubstitutionFixture.original.equipment },
                "\(reason) returned the original's own implement"
            )
            // Free weights answer "the machine is taken" best of all.
            #expect(
                ExerciseSubstitutionEngine.family(of: result[0].exercise.equipment) == .freeWeight
            )
        }
    }

    @Test("Easier returns a lower average difficulty than harder does")
    func easierIsEasierThanHarder() {
        let easier = candidates(.easier)
        let harder = candidates(.harder)
        #expect(!easier.isEmpty)
        #expect(!harder.isEmpty)

        let originalRank = SubstitutionFixture.original.metadata.difficulty.rank
        #expect(easier.allSatisfy { $0.exercise.metadata.difficulty.rank <= originalRank })
        #expect(harder.allSatisfy { $0.exercise.metadata.difficulty.rank >= originalRank })

        func averageDifficulty(_ candidates: [SubstitutionCandidate]) -> Double {
            Double(candidates.reduce(0) { $0 + $1.exercise.metadata.difficulty.rank }) / Double(candidates.count)
        }
        let easierAverage = averageDifficulty(easier)
        let harderAverage = averageDifficulty(harder)
        #expect(easierAverage < harderAverage, "easier averaged \(easierAverage), harder \(harderAverage)")
    }

    @Test("Easier promotes the supported, low-balance option to the top of the list")
    func easierPromotesSupportedWork() {
        let result = candidates(.easier)
        let leader = result.first
        #expect(leader != nil)
        #expect(
            leader.map { $0.exercise.metadata.stabilityDemand < SubstitutionFixture.original.metadata.stabilityDemand }
                == true,
            "leader was \(String(describing: leader?.id))"
        )
        #expect(
            leader.map { $0.exercise.metadata.difficulty.rank <= SubstitutionFixture.original.metadata.difficulty.rank }
                == true
        )
    }

    @Test("Harder promotes the more demanding option to the top of the list")
    func harderPromotesMoreDemandingWork() throws {
        let result = candidates(.harder)
        let leader = try #require(result.first)
        let raisesDifficulty = leader.exercise.metadata.difficulty.rank
            > SubstitutionFixture.original.metadata.difficulty.rank
        let unilateral = leader.exercise.metadata.laterality != .bilateral
        #expect(raisesDifficulty || unilateral, "leader was \(leader.id)")
    }

    @Test("Sore joints get a different movement path, never the same pattern again")
    func jointDiscomfortChangesTheMovementPattern() {
        let result = candidates(.jointDiscomfort)
        #expect(!result.isEmpty)
        #expect(
            result.allSatisfy {
                $0.exercise.metadata.movementPattern != SubstitutionFixture.original.metadata.movementPattern
            }
        )
        #expect(result.allSatisfy { !$0.matchesPattern })
    }

    @Test("Wanting a different exercise for the same muscle changes how it is performed")
    func sameMuscleDifferentExerciseActuallyDiffers() {
        let result = candidates(.sameMuscleDifferentExercise)
        #expect(!result.isEmpty)
        #expect(
            result.allSatisfy {
                $0.exercise.metadata.movementPattern != SubstitutionFixture.original.metadata.movementPattern
                    || $0.exercise.equipment != SubstitutionFixture.original.equipment
            }
        )
        // Same target muscle is what the fit rewards most, so it leads.
        #expect(result.first?.matchesTarget == true)
    }

    @Test("Disliking an exercise excludes the variation, not the whole movement family")
    func dislikeExcludesTheDistinctiveTags() {
        let result = candidates(.dislike)
        #expect(!result.isEmpty)
        // "wide_grip" is the original's rarest tag; nothing carrying it may come back.
        #expect(!result.contains { $0.exercise.metadata.substitutionTags.contains("wide_grip") })
        // Other chest work is still on the table.
        #expect(result.contains { $0.exercise.primaryGroup == .chest })
    }

    @Test("No reason ever produces an empty sheet")
    func everyReasonReturnsSomethingUsable() {
        #expect(!ids(nil).isEmpty)
        for reason in SubstitutionReason.allCases {
            #expect(!ids(reason).isEmpty, "\(reason) returned nothing at all")
        }
    }

    @Test("An implement preference genuinely reorders the sheet")
    func animplementPreferenceReordersTheSheet() {
        let unreasoned = ids(nil)
        for reason in [SubstitutionReason.preferCable, .bodyweightOnly, .machineUnavailable, .easier] {
            #expect(ids(reason) != unreasoned, "\(reason) made no difference to the answer")
        }
    }

    @Test("An impossible reason is dropped rather than returning an empty sheet")
    func animpossibleReasonFallsBackToARankingPreference() {
        // A gym with no bodyweight chest option at all.
        let catalogue = [
            SubstitutionFixture.original,
            SubstitutionFixture.chestPress(id: "db-press", equipment: .dumbbell),
            SubstitutionFixture.chestPress(id: "machine-press", equipment: .leverageMachine)
        ]
        let engine = ExerciseSubstitutionEngine(catalog: catalogue)
        let result = engine.alternatives(
            for: SubstitutionFixture.request(
                original: SubstitutionFixture.original,
                reason: .bodyweightOnly
            )
        )
        #expect(Set(result.map(\.id)) == ["db-press", "machine-press"])
    }

    @Test("Dropping the reason filter never drops the hard gates with it")
    func theFallbackStillHonoursTheHardGates() {
        let catalogue = [
            SubstitutionFixture.original,
            SubstitutionFixture.chestPress(id: "db-press", equipment: .dumbbell),
            SubstitutionFixture.chestPress(id: "machine-press", equipment: .leverageMachine)
        ]
        let engine = ExerciseSubstitutionEngine(catalog: catalogue)
        let result = engine.alternatives(
            for: SubstitutionFixture.request(
                original: SubstitutionFixture.original,
                reason: .bodyweightOnly,
                equipment: [.dumbbell],
                profile: SelectionFixture.profile(excludedIDs: ["machine-press"])
            )
        )
        #expect(result.map(\.id) == ["db-press"])
    }

    @Test("Every reason on the shipping catalogue honours its own filter")
    func realCatalogueReasonsHonourTheirFilters() throws {
        try #require(!SelectionCatalogue.exercises.isEmpty, "The shipping catalogue failed to load")
        let bench = try #require(SelectionCatalogue.exercise(SelectionCatalogue.barbellBenchPressID))
        let engine = SelectionCatalogue.substitution

        func result(_ reason: SubstitutionReason) -> [SubstitutionCandidate] {
            engine.alternatives(for: SubstitutionFixture.request(original: bench, reason: reason, limit: 12))
        }

        #expect(result(.bodyweightOnly).allSatisfy {
            [.bodyWeight, .assisted, .weighted].contains($0.exercise.equipment)
        })
        #expect(result(.preferDumbbell).allSatisfy { $0.exercise.equipment == .dumbbell })
        #expect(result(.preferCable).allSatisfy { $0.exercise.equipment == .cable })
        #expect(result(.preferBarbell).allSatisfy {
            [.barbell, .olympicBarbell, .ezBarbell, .trapBar].contains($0.exercise.equipment)
        })
        #expect(result(.machineUnavailable).allSatisfy { $0.exercise.equipment != bench.equipment })
        #expect(result(.jointDiscomfort).allSatisfy {
            $0.exercise.metadata.movementPattern != bench.metadata.movementPattern
        })
        #expect(result(.easier).allSatisfy {
            $0.exercise.metadata.difficulty.rank <= bench.metadata.difficulty.rank
        })
        #expect(result(.harder).allSatisfy {
            $0.exercise.metadata.difficulty.rank >= bench.metadata.difficulty.rank
        })
    }
}

// MARK: - Performance

@Suite("Substitution performance", .serialized)
struct SubstitutionPerformanceTests {

    @Test("Indexing the whole shipping catalogue is not slow")
    func buildingTheIndexIsFast() throws {
        let catalogue = SelectionCatalogue.exercises
        try #require(!catalogue.isEmpty, "The shipping catalogue failed to load")

        let elapsed = ContinuousClock().measure {
            let engine = ExerciseSubstitutionEngine(catalog: catalogue)
            #expect(engine.catalogCount == catalogue.count)
        }
        #expect(elapsed < .seconds(3), "index build took \(elapsed)")
    }

    @Test("Answering a mid-set substitution over the whole catalogue stays well inside budget")
    func alternativesAreFastEnoughToOpenASheetInstantly() throws {
        let catalogue = SelectionCatalogue.exercises
        try #require(!catalogue.isEmpty, "The shipping catalogue failed to load")
        let engine = SelectionCatalogue.substitution
        let bench = try #require(SelectionCatalogue.exercise(SelectionCatalogue.barbellBenchPressID))

        // The expensive case: a preference and a history for every record in the catalogue.
        var preferences: [String: ExercisePreferenceSnapshot] = [:]
        var histories: [String: ExerciseHistorySnapshot] = [:]
        for exercise in catalogue {
            preferences[exercise.id] = SelectionFixture.preference(exercise.id, feedback: .like, timesPerformed: 4)
            histories[exercise.id] = SelectionFixture.history(
                id: exercise.id,
                sessions: [
                    [SelectionFixture.performedSet(weightKg: 60, reps: 8)],
                    [SelectionFixture.performedSet(weightKg: 57.5, reps: 8)]
                ],
                totalSessions: 5
            )
        }

        var produced = 0
        let elapsed = ContinuousClock().measure {
            for reason in SubstitutionReason.allCases {
                produced += engine.alternatives(
                    for: SubstitutionFixture.request(
                        original: bench,
                        reason: reason,
                        preferences: preferences,
                        histories: histories
                    )
                ).count
            }
        }

        #expect(produced > 0)
        // Eleven full substitution passes. The shipped figure is about 1 ms each in release; the
        // ceiling here is deliberately far above a debug build's cost.
        #expect(elapsed < .seconds(10), "eleven substitution passes took \(elapsed)")
    }
}
