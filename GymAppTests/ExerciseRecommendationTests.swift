import Foundation
import Testing
@testable import GymApp

// MARK: - Small purpose-built catalogues

/// Catalogues assembled for one behaviour at a time.
///
/// The engine indexes whatever it is handed, so a five-record catalogue exercises exactly the same
/// code paths as the shipping one while letting a test say precisely which property it is varying.
private enum RecommendationCatalogue {

    /// Three barbell horizontal presses, two dumbbell flyes and a cable vertical press, all of them
    /// direct chest work and all within a few points of each other. The presses are the *best*
    /// options, so ranking alone returns three of them.
    static var chestWithSeveralPatterns: [Exercise] {
        [
            press(id: "c1"), press(id: "c2"), press(id: "c3"),
            fly(id: "f1"), fly(id: "f2"),
            verticalPress(id: "v1")
        ]
    }

    static func press(id: String, staple: Double = 0.9) -> Exercise {
        SelectionFixture.exercise(
            id: id,
            equipment: .barbell,
            target: .pectorals,
            synergist: .triceps,
            secondary: [.delts],
            metadata: SelectionFixture.metadata(
                pattern: .horizontalPush,
                volume: [.chest: 1.0, .triceps: 0.5],
                tags: ["press"],
                staple: staple
            )
        )
    }

    static func fly(id: String, staple: Double = 0.5) -> Exercise {
        SelectionFixture.exercise(
            id: id,
            equipment: .dumbbell,
            target: .pectorals,
            synergist: .triceps,
            secondary: [.delts],
            metadata: SelectionFixture.metadata(
                pattern: .chestFly,
                volume: [.chest: 1.0, .triceps: 0.5],
                tags: ["fly"],
                staple: staple
            )
        )
    }

    static func verticalPress(id: String, staple: Double = 0.5) -> Exercise {
        SelectionFixture.exercise(
            id: id,
            equipment: .cable,
            target: .pectorals,
            synergist: .triceps,
            secondary: [.delts],
            metadata: SelectionFixture.metadata(
                pattern: .verticalPush,
                volume: [.chest: 1.0, .triceps: 0.5],
                tags: ["press"],
                staple: staple
            )
        )
    }

    /// A strong press, for tests that need a clear leader.
    static func strongPress(id: String, pattern: MovementPattern = .horizontalPush) -> Exercise {
        SelectionFixture.exercise(
            id: id,
            equipment: .barbell,
            target: .pectorals,
            metadata: SelectionFixture.metadata(
                pattern: pattern,
                stimulus: 0.9,
                progression: 0.9,
                volume: [.chest: 1.0, .triceps: 0.5],
                tags: ["press"],
                staple: 0.9
            )
        )
    }

    /// A genuinely poor option that happens to bring a fresh movement pattern with it.
    static func weakButDifferent(id: String) -> Exercise {
        SelectionFixture.exercise(
            id: id,
            equipment: .band,
            target: .pectorals,
            metadata: SelectionFixture.metadata(
                pattern: .chestFly,
                difficulty: .advanced,
                stability: 0.9,
                fatigue: 1.0,
                stimulus: 0.05,
                progression: 0,
                repRange: .endurance,
                volume: [.chest: 1.0],
                tags: ["fly"],
                staple: 0
            )
        )
    }

    /// A strong triceps movement that only earns indirect chest credit.
    static func indirectTricepsWork(id: String) -> Exercise {
        SelectionFixture.exercise(
            id: id,
            equipment: .cable,
            target: .triceps,
            synergist: .pectorals,
            secondary: [.delts],
            metadata: SelectionFixture.metadata(
                pattern: .elbowExtension,
                mechanic: .isolation,
                fatigue: 0.2,
                stimulus: 1.0,
                progression: 1.0,
                volume: [.triceps: 1.0, .chest: 0.5],
                tags: ["pushdown"],
                staple: 1.0
            )
        )
    }

    static func warmup(
        id: String,
        target: Muscle,
        equipment: Equipment = .bodyWeight,
        pattern: MovementPattern = .mobility,
        isWarmupCandidate: Bool = true,
        isStretch: Bool = false,
        isPlyometric: Bool = false,
        fatigue: Double = 0.1,
        stability: Double = 0.2,
        staple: Double = 0.5
    ) -> Exercise {
        SelectionFixture.exercise(
            id: id,
            equipment: equipment,
            target: target,
            synergist: nil,
            secondary: [],
            metadata: SelectionFixture.metadata(
                pattern: pattern,
                tracking: .repsOnly,
                stability: stability,
                fatigue: fatigue,
                isStretch: isStretch,
                isPlyometric: isPlyometric,
                isWarmupCandidate: isWarmupCandidate,
                volume: [target.group: 1.0],
                tags: ["mobility"],
                staple: staple
            )
        )
    }
}

// MARK: - Ranking

@Suite("Exercise ranking")
struct ExerciseRankingTests {

    @Test("The same request twice returns exactly the same order")
    func rankingIsDeterministic() {
        let engine = ExerciseRecommendationEngine(catalog: RecommendationCatalogue.chestWithSeveralPatterns)
        let request = SelectionFixture.request(
            preferences: ["c2": SelectionFixture.preference("c2", feedback: .like)],
            histories: [
                "f1": SelectionFixture.history(
                    id: "f1",
                    sessions: [
                        [SelectionFixture.performedSet(weightKg: 30, reps: 10)],
                        [SelectionFixture.performedSet(weightKg: 28, reps: 10)]
                    ]
                )
            ],
            recentlyUsed: ["c3"]
        )

        let first = engine.rank(request)
        let second = engine.rank(request)

        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.score) == second.map(\.score))
    }

    @Test("The shipping catalogue also ranks identically twice over")
    func rankingTheShippingCatalogueIsDeterministic() throws {
        try #require(!SelectionCatalogue.exercises.isEmpty, "The shipping catalogue failed to load")
        let engine = SelectionCatalogue.recommendation
        let request = SelectionFixture.request(
            target: .back,
            pattern: .verticalPull,
            profile: SelectionFixture.profile(priorities: [.back, .biceps])
        )

        let first = engine.rank(request)
        let second = engine.rank(request)
        #expect(!first.isEmpty)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.score) == second.map(\.score))

        // A second engine built from the same records must agree with the first.
        let rebuilt = ExerciseRecommendationEngine(catalog: SelectionCatalogue.exercises)
        #expect(rebuilt.rank(request).map(\.id) == first.map(\.id))
    }

    @Test("Ranking is ordered by score, then by how central the movement is, then by id")
    func rankingBreaksTiesDeterministically() {
        // Identical in every respect except the staple score, then except the id.
        let central = RecommendationCatalogue.press(id: "z", staple: 0.9)
        let niche = RecommendationCatalogue.press(id: "a", staple: 0.1)
        let engine = ExerciseRecommendationEngine(catalog: [niche, central])
        #expect(engine.rank(SelectionFixture.request()).map(\.id) == ["z", "a"])

        let twinB = RecommendationCatalogue.press(id: "b", staple: 0.5)
        let twinA = RecommendationCatalogue.press(id: "a", staple: 0.5)
        let twins = ExerciseRecommendationEngine(catalog: [twinB, twinA])
        #expect(twins.rank(SelectionFixture.request()).map(\.id) == ["a", "b"])
    }

    @Test("A limit of zero or less returns nothing at all")
    func rankingRespectsANonPositiveLimit() {
        let engine = ExerciseRecommendationEngine(catalog: RecommendationCatalogue.chestWithSeveralPatterns)
        #expect(engine.rank(SelectionFixture.request(), limit: 0).isEmpty)
        #expect(engine.rank(SelectionFixture.request(), limit: -3).isEmpty)
    }

    @Test("Ranking never returns more rows than the caller asked for")
    func rankingRespectsTheLimit() {
        let engine = ExerciseRecommendationEngine(catalog: RecommendationCatalogue.chestWithSeveralPatterns)
        #expect(engine.rank(SelectionFixture.request(), limit: 2).count == 2)
        #expect(engine.rank(SelectionFixture.request(), limit: 99).count == 6)
    }

    @Test("An empty catalogue ranks nothing rather than trapping")
    func rankingAnEmptyCatalogueReturnsNothing() {
        let engine = ExerciseRecommendationEngine(catalog: [])
        #expect(engine.catalogCount == 0)
        #expect(engine.rank(SelectionFixture.request()).isEmpty)
        #expect(engine.best(SelectionFixture.request(), count: 3).isEmpty)
        #expect(engine.warmupSuggestions(for: [.chest], equipment: [.bodyWeight], limit: 3).isEmpty)
    }

    @Test("A group the catalogue does not cover ranks nothing")
    func rankingAnUncoveredGroupReturnsNothing() {
        let engine = ExerciseRecommendationEngine(catalog: RecommendationCatalogue.chestWithSeveralPatterns)
        #expect(engine.rank(SelectionFixture.request(target: .calves)).isEmpty)
    }

    @Test("Disqualified exercises are dropped from the ranking rather than ranked last")
    func rankingDropsDisqualifiedExercises() {
        let engine = ExerciseRecommendationEngine(catalog: RecommendationCatalogue.chestWithSeveralPatterns)
        let request = SelectionFixture.request(
            profile: SelectionFixture.profile(
                equipment: [.dumbbell],
                excludedIDs: ["f1"]
            )
        )
        let ids = engine.rank(request).map(\.id)
        // Only the dumbbell flyes are reachable, and one of those is excluded by id.
        #expect(ids == ["f2"])
    }

    @Test("Indirect contributors are reachable through the group they only partly train")
    func rankingIncludesIndirectContributors() {
        let engine = ExerciseRecommendationEngine(
            catalog: [
                RecommendationCatalogue.strongPress(id: "c1"),
                RecommendationCatalogue.indirectTricepsWork(id: "t1")
            ]
        )
        let ranked = engine.rank(SelectionFixture.request(target: .chest))
        #expect(Set(ranked.map(\.id)) == ["c1", "t1"])
        #expect(ranked.first { $0.id == "c1" }?.breakdown.targetMatch == 1)
        #expect(ranked.first { $0.id == "t1" }?.breakdown.targetMatch == 0.5)
    }

    @Test("Work that carries no volume credit at all is still reachable through its own group")
    func cardioIsReachableDespiteCarryingNoVolumeCredit() {
        let row = SelectionFixture.exercise(
            id: "cardio1",
            bodyPart: .cardio,
            equipment: .stationaryBike,
            target: .cardiovascularSystem,
            synergist: nil,
            secondary: [],
            metadata: SelectionFixture.metadata(
                pattern: .cardio,
                pushPull: .cardio,
                tracking: .distanceAndDuration,
                volume: [:],
                tags: ["cardio"]
            )
        )
        let engine = ExerciseRecommendationEngine(catalog: [row])
        #expect(engine.rank(SelectionFixture.request(target: .cardio)).map(\.id) == ["cardio1"])
    }

    @Test("Prioritising a group lifts the exercise that trains it directly above a stronger neighbour")
    func priorityGroupsRaiseAnExerciseUpTheRanking() {
        // A modest chest press against an excellent triceps movement that only earns the chest
        // half credit. On merit alone the triceps movement edges ahead; once the user says chest
        // is a priority, the movement that actually trains chest takes the slot.
        let directChest = SelectionFixture.exercise(
            id: "chest-press",
            equipment: .barbell,
            target: .pectorals,
            synergist: nil,
            secondary: [],
            metadata: SelectionFixture.metadata(
                pattern: .horizontalPush,
                fatigue: 0.6,
                stimulus: 0.5,
                progression: 0.4,
                volume: [.chest: 1.0],
                tags: ["press"],
                staple: 0.2
            )
        )
        let mostlyTriceps = SelectionFixture.exercise(
            id: "triceps-pushdown",
            equipment: .cable,
            target: .triceps,
            synergist: nil,
            secondary: [],
            metadata: SelectionFixture.metadata(
                pattern: .elbowExtension,
                mechanic: .isolation,
                fatigue: 0.2,
                stimulus: 1.0,
                progression: 0.8,
                volume: [.triceps: 1.0, .chest: 0.5],
                tags: ["pushdown"],
                staple: 0.6
            )
        )
        let engine = ExerciseRecommendationEngine(catalog: [directChest, mostlyTriceps])

        let neutral = engine.rank(SelectionFixture.request(target: .chest))
        #expect(
            neutral.map(\.id) == ["triceps-pushdown", "chest-press"],
            "unprioritised order was \(neutral.map { "\($0.id) \($0.score)" })"
        )

        let prioritised = engine.rank(
            SelectionFixture.request(
                target: .chest,
                profile: SelectionFixture.profile(priorities: [.chest])
            )
        )
        #expect(
            prioritised.map(\.id) == ["chest-press", "triceps-pushdown"],
            "prioritised order was \(prioritised.map { "\($0.id) \($0.score)" })"
        )
    }

    @Test("Prioritising the slot's own group lifts direct work more than indirect work")
    func prioritisingTheSlotsGroupFavoursDirectWork() {
        let engine = ExerciseRecommendationEngine(
            catalog: [
                RecommendationCatalogue.strongPress(id: "c1"),
                RecommendationCatalogue.indirectTricepsWork(id: "t1")
            ]
        )
        func score(_ id: String, priorities: [MuscleGroup]) -> Double {
            engine.rank(
                SelectionFixture.request(
                    target: .chest,
                    profile: SelectionFixture.profile(priorities: priorities)
                )
            ).first { $0.id == id }?.score ?? 0
        }

        let directGain = score("c1", priorities: [.chest]) - score("c1", priorities: [])
        let indirectGain = score("t1", priorities: [.chest]) - score("t1", priorities: [])

        #expect(directGain > 0)
        #expect(indirectGain > 0)
        #expect(directGain > indirectGain)
    }

    @Test("Ranking reports the introspection count it was built with")
    func engineReportsItsCatalogueSize() {
        let engine = ExerciseRecommendationEngine(catalog: RecommendationCatalogue.chestWithSeveralPatterns)
        #expect(engine.catalogCount == 6)
    }
}

// MARK: - Diverse selection

@Suite("Diverse exercise selection")
struct ExerciseBestSelectionTests {

    @Test("A count of zero or less selects nothing")
    func bestRefusesANonPositiveCount() {
        let engine = ExerciseRecommendationEngine(catalog: RecommendationCatalogue.chestWithSeveralPatterns)
        #expect(engine.best(SelectionFixture.request(), count: 0).isEmpty)
        #expect(engine.best(SelectionFixture.request(), count: -2).isEmpty)
    }

    @Test("A session never contains the same exercise twice")
    func bestNeverRepeatsAnExercise() {
        let engine = ExerciseRecommendationEngine(catalog: RecommendationCatalogue.chestWithSeveralPatterns)
        let chosen = engine.best(SelectionFixture.request(), count: 6)
        #expect(chosen.count == Set(chosen.map(\.id)).count)
    }

    @Test("Selection stops when the pool runs out instead of padding or looping")
    func bestStopsWhenThePoolIsExhausted() {
        let engine = ExerciseRecommendationEngine(
            catalog: [RecommendationCatalogue.press(id: "c1"), RecommendationCatalogue.fly(id: "f1")]
        )
        let chosen = engine.best(SelectionFixture.request(), count: 10)
        #expect(chosen.count == 2)
        #expect(Set(chosen.map(\.id)) == ["c1", "f1"])
    }

    @Test("Ranking alone repeats one pattern; diverse selection does not")
    func bestSpreadsPicksAcrossMovementPatterns() {
        let engine = ExerciseRecommendationEngine(catalog: RecommendationCatalogue.chestWithSeveralPatterns)
        let request = SelectionFixture.request()

        // The three presses are the best options, so the plain ranking takes all three.
        let ranked = engine.rank(request, limit: 3)
        #expect(Set(ranked.map(\.exercise.metadata.movementPattern)).count == 1)

        let chosen = engine.best(request, count: 3)
        #expect(chosen.count == 3)
        let patterns = chosen.map(\.metadata.movementPattern)
        #expect(Set(patterns).count == 3, "expected three distinct patterns, got \(patterns)")
        // The equipment penalty pushes the same way: three implements, not three barbell lifts.
        #expect(Set(chosen.map(\.equipment)).count == 3)
    }

    @Test("Diverse selection is deterministic")
    func bestIsDeterministic() {
        let engine = ExerciseRecommendationEngine(catalog: RecommendationCatalogue.chestWithSeveralPatterns)
        let request = SelectionFixture.request(recentlyUsed: ["c1"])
        #expect(engine.best(request, count: 4).map(\.id) == engine.best(request, count: 4).map(\.id))
    }

    @Test("Variety is never bought with a genuinely unsuitable exercise")
    func bestKeepsQualityAheadOfVariety() {
        let engine = ExerciseRecommendationEngine(
            catalog: [
                RecommendationCatalogue.strongPress(id: "c1"),
                RecommendationCatalogue.strongPress(id: "c2"),
                RecommendationCatalogue.weakButDifferent(id: "w1")
            ]
        )
        let chosen = engine.best(SelectionFixture.request(), count: 2)

        #expect(chosen.map(\.id) == ["c1", "c2"])
        // The weak option is eligible and ranked — it is simply too far below the leader to buy
        // its way in on novelty.
        #expect(engine.rank(SelectionFixture.request()).map(\.id).contains("w1"))
    }

    @Test("A slot for one group is not filled with indirect work while direct work remains")
    func bestPrefersDirectWorkOverIndirectVariety() {
        let engine = ExerciseRecommendationEngine(
            catalog: [
                RecommendationCatalogue.strongPress(id: "c1"),
                RecommendationCatalogue.strongPress(id: "c2"),
                RecommendationCatalogue.indirectTricepsWork(id: "t1")
            ]
        )
        let request = SelectionFixture.request(target: .chest)

        // The triceps movement is a real contender on score and brings a fresh pattern with it.
        #expect(engine.rank(request).map(\.id).contains("t1"))

        let chosen = engine.best(request, count: 2)
        #expect(chosen.map(\.id) == ["c1", "c2"])
        #expect(chosen.allSatisfy { $0.primaryGroup == .chest })
    }

    @Test("Indirect work is still selected once nothing direct is left")
    func bestFallsBackToIndirectWorkWhenDirectWorkRunsOut() {
        let engine = ExerciseRecommendationEngine(
            catalog: [
                RecommendationCatalogue.strongPress(id: "c1"),
                RecommendationCatalogue.indirectTricepsWork(id: "t1")
            ]
        )
        let chosen = engine.best(SelectionFixture.request(target: .chest), count: 2)
        #expect(chosen.map(\.id) == ["c1", "t1"])
    }

    @Test("Hard gates still apply to every pick a session makes")
    func bestHonoursTheEligibilityGates() {
        let engine = ExerciseRecommendationEngine(catalog: RecommendationCatalogue.chestWithSeveralPatterns)
        let request = SelectionFixture.request(
            profile: SelectionFixture.profile(
                equipment: [.barbell, .dumbbell],
                excludedIDs: ["c1"],
                avoidedPatterns: [.chestFly]
            )
        )
        let chosen = engine.best(request, count: 6)
        #expect(!chosen.map(\.id).contains("c1"))
        #expect(chosen.allSatisfy { $0.metadata.movementPattern != .chestFly })
        #expect(chosen.allSatisfy { $0.equipment != .cable })
    }

    @Test("A real chest day gets more than one movement pattern")
    func bestGivesARealChestDayGenuineVariety() throws {
        try #require(!SelectionCatalogue.exercises.isEmpty, "The shipping catalogue failed to load")
        let chosen = SelectionCatalogue.recommendation.best(
            SelectionFixture.request(target: .chest),
            count: 4
        )
        #expect(chosen.count == 4)
        let patterns = Set(chosen.map(\.metadata.movementPattern))
        #expect(
            patterns.count >= 2,
            "expected several patterns, got \(chosen.map { "\($0.name) [\($0.metadata.movementPattern)]" })"
        )
        #expect(chosen.count == Set(chosen.map(\.id)).count)
    }
}

// MARK: - Warm-ups

@Suite("Warm-up suggestions")
struct WarmupSuggestionTests {

    private var catalogue: [Exercise] {
        [
            RecommendationCatalogue.warmup(id: "chest-1", target: .pectorals, staple: 0.9),
            RecommendationCatalogue.warmup(id: "chest-2", target: .pectorals, staple: 0.5),
            RecommendationCatalogue.warmup(id: "chest-3", target: .pectorals, staple: 0.1),
            RecommendationCatalogue.warmup(id: "back-1", target: .lats, staple: 0.9),
            RecommendationCatalogue.warmup(id: "back-2", target: .lats, staple: 0.5),
            RecommendationCatalogue.warmup(id: "back-3", target: .lats, staple: 0.1)
        ]
    }

    @Test("No groups or a non-positive limit produces no suggestions")
    func warmupsRefuseDegenerateRequests() {
        let engine = ExerciseRecommendationEngine(catalog: catalogue)
        #expect(engine.warmupSuggestions(for: [], equipment: [.bodyWeight], limit: 3).isEmpty)
        #expect(engine.warmupSuggestions(for: [.chest], equipment: [.bodyWeight], limit: 0).isEmpty)
        #expect(engine.warmupSuggestions(for: [.chest], equipment: [], limit: 3).isEmpty)
    }

    @Test("Suggestions are handed out round-robin so every group gets warmed up")
    func warmupsAlternateBetweenTheGroupsTheSessionTrains() {
        let engine = ExerciseRecommendationEngine(catalog: catalogue)
        let suggestions = engine.warmupSuggestions(
            for: [.chest, .back],
            equipment: [.bodyWeight],
            limit: 4
        )
        #expect(suggestions.map(\.id) == ["chest-1", "back-1", "chest-2", "back-2"])
    }

    @Test("A repeated group is only warmed up once")
    func warmupsDeduplicateTheRequestedGroups() {
        let engine = ExerciseRecommendationEngine(catalog: catalogue)
        let suggestions = engine.warmupSuggestions(
            for: [.chest, .chest, .back],
            equipment: [.bodyWeight],
            limit: 4
        )
        #expect(suggestions.map(\.id) == ["chest-1", "back-1", "chest-2", "back-2"])
        #expect(Set(suggestions.map(\.id)).count == suggestions.count)
    }

    @Test("Warm-ups are limited to the kit actually within reach")
    func warmupsHonourTheEquipmentInReach() {
        let engine = ExerciseRecommendationEngine(
            catalog: [
                RecommendationCatalogue.warmup(id: "band-1", target: .pectorals, equipment: .band),
                RecommendationCatalogue.warmup(id: "body-1", target: .pectorals, equipment: .bodyWeight)
            ]
        )
        #expect(
            engine.warmupSuggestions(for: [.chest], equipment: [.bodyWeight], limit: 5).map(\.id)
                == ["body-1"]
        )
    }

    @Test("Explosive movements are never offered as a warm-up")
    func warmupsExcludePlyometrics() {
        let engine = ExerciseRecommendationEngine(
            catalog: [
                RecommendationCatalogue.warmup(id: "jump", target: .pectorals, isPlyometric: true),
                RecommendationCatalogue.warmup(id: "swing", target: .pectorals)
            ]
        )
        #expect(
            engine.warmupSuggestions(for: [.chest], equipment: [.bodyWeight], limit: 5).map(\.id)
                == ["swing"]
        )
    }

    @Test("A held stretch belongs in a warm-up list, but below the dynamic work")
    func warmupsRankDynamicWorkAboveStaticStretches() {
        let engine = ExerciseRecommendationEngine(
            catalog: [
                RecommendationCatalogue.warmup(id: "stretch", target: .pectorals, isStretch: true),
                RecommendationCatalogue.warmup(id: "dynamic", target: .pectorals)
            ]
        )
        let suggestions = engine.warmupSuggestions(for: [.chest], equipment: [.bodyWeight], limit: 5)
        #expect(suggestions.map(\.id) == ["dynamic", "stretch"])
    }

    @Test("A cheap movement warms up better than an expensive one")
    func warmupsPreferMovementsThatCostNothing() {
        let engine = ExerciseRecommendationEngine(
            catalog: [
                RecommendationCatalogue.warmup(
                    id: "costly", target: .pectorals, isWarmupCandidate: false, fatigue: 0.25
                ),
                RecommendationCatalogue.warmup(
                    id: "cheap", target: .pectorals, isWarmupCandidate: false, fatigue: 0.0
                )
            ]
        )
        let suggestions = engine.warmupSuggestions(for: [.chest], equipment: [.bodyWeight], limit: 5)
        #expect(suggestions.map(\.id) == ["cheap", "costly"])
    }

    @Test("A supplied profile gates warm-ups exactly as it gates working sets")
    func warmupsHonourTheUsersOwnRules() {
        let engine = ExerciseRecommendationEngine(
            catalog: [
                RecommendationCatalogue.warmup(
                    id: "overhead", target: .delts, pattern: .verticalPush
                ),
                RecommendationCatalogue.warmup(
                    id: "excluded", target: .delts, pattern: .shoulderRaise
                ),
                RecommendationCatalogue.warmup(
                    id: "allowed", target: .delts, pattern: .mobility
                )
            ]
        )
        let profile = SelectionFixture.profile(
            excludedIDs: ["excluded"],
            limitations: [.overheadPressing]
        )
        let gated = engine.warmupSuggestions(
            for: [.shoulders],
            equipment: [.bodyWeight],
            limit: 5,
            profile: profile
        )
        #expect(gated.map(\.id) == ["allowed"])

        // Without a profile the only gate is the equipment in reach.
        let ungated = engine.warmupSuggestions(for: [.shoulders], equipment: [.bodyWeight], limit: 5)
        #expect(Set(ungated.map(\.id)) == ["overhead", "excluded", "allowed"])
    }

    @Test("A stretch survives the gate that would reject it from a working slot")
    func warmupsAllowStretchesThroughTheGate() {
        let engine = ExerciseRecommendationEngine(
            catalog: [RecommendationCatalogue.warmup(id: "stretch", target: .pectorals, isStretch: true)]
        )
        let suggestions = engine.warmupSuggestions(
            for: [.chest],
            equipment: [.bodyWeight],
            limit: 3,
            profile: SelectionFixture.profile()
        )
        #expect(suggestions.map(\.id) == ["stretch"])
    }

    @Test("Warm-up suggestions are deterministic")
    func warmupsAreDeterministic() {
        let engine = ExerciseRecommendationEngine(catalog: catalogue)
        let first = engine.warmupSuggestions(for: [.chest, .back], equipment: [.bodyWeight], limit: 5)
        let second = engine.warmupSuggestions(for: [.chest, .back], equipment: [.bodyWeight], limit: 5)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("The shipping catalogue offers real warm-ups for a full-body session")
    func warmupsExistForEveryGroupAFullBodySessionTrains() throws {
        try #require(!SelectionCatalogue.exercises.isEmpty, "The shipping catalogue failed to load")
        let suggestions = SelectionCatalogue.recommendation.warmupSuggestions(
            for: [.chest, .back, .quads],
            equipment: Equipment.fullGym,
            limit: 6,
            profile: SelectionFixture.profile()
        )
        #expect(suggestions.count == 6)
        #expect(Set(suggestions.map(\.id)).count == 6)
        #expect(suggestions.allSatisfy { !$0.metadata.isPlyometric })
    }
}

// MARK: - Performance

@Suite("Recommendation performance", .serialized)
struct ExerciseRecommendationPerformanceTests {

    @Test("Building the engine from the whole shipping catalogue is not slow")
    func buildingTheIndexIsFast() throws {
        let catalogue = SelectionCatalogue.exercises
        try #require(!catalogue.isEmpty, "The shipping catalogue failed to load")

        let elapsed = ContinuousClock().measure {
            let engine = ExerciseRecommendationEngine(catalog: catalogue)
            #expect(engine.catalogCount == catalogue.count)
        }
        // Generous: the shipped figure is 3–4 ms in a release build.
        #expect(elapsed < .seconds(3), "index build took \(elapsed)")
    }

    @Test("Ranking every muscle group over the whole catalogue stays well inside budget")
    func rankingTheWholeCatalogueIsFast() throws {
        let catalogue = SelectionCatalogue.exercises
        try #require(!catalogue.isEmpty, "The shipping catalogue failed to load")
        let engine = SelectionCatalogue.recommendation

        // The expensive shape: a full preference and history dictionary, so every candidate costs
        // two dictionary lookups and a trend computation.
        var preferences: [String: ExercisePreferenceSnapshot] = [:]
        var histories: [String: ExerciseHistorySnapshot] = [:]
        for exercise in catalogue {
            preferences[exercise.id] = SelectionFixture.preference(exercise.id, feedback: .like)
            histories[exercise.id] = SelectionFixture.history(
                id: exercise.id,
                sessions: [
                    [SelectionFixture.performedSet(weightKg: 60, reps: 8)],
                    [SelectionFixture.performedSet(weightKg: 57.5, reps: 8)]
                ]
            )
        }

        var ranked = 0
        let elapsed = ContinuousClock().measure {
            for group in MuscleGroup.allCases {
                let request = SelectionFixture.request(
                    target: group,
                    profile: SelectionFixture.profile(priorities: [group]),
                    preferences: preferences,
                    histories: histories
                )
                ranked += engine.rank(request).count
            }
        }

        #expect(ranked > 0)
        // Eighteen full rankings. The release figure is around 1 ms each; this ceiling is
        // deliberately far above a debug build's cost so the test cannot flake.
        #expect(elapsed < .seconds(10), "ranking all groups took \(elapsed)")
    }

    @Test("Building a six-exercise session out of the whole catalogue stays well inside budget")
    func buildingASessionIsFast() throws {
        try #require(!SelectionCatalogue.exercises.isEmpty, "The shipping catalogue failed to load")
        let engine = SelectionCatalogue.recommendation

        var chosen = 0
        let elapsed = ContinuousClock().measure {
            for group in [MuscleGroup.chest, .back, .quads] {
                chosen += engine.best(SelectionFixture.request(target: group), count: 6).count
            }
        }

        #expect(chosen == 18)
        #expect(elapsed < .seconds(10), "three sessions took \(elapsed)")
    }
}
