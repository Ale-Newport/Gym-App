import Foundation

/// Turns the catalogue into an ordered answer to "what should fill this slot?".
///
/// The engine is a value type built once from the immutable catalogue and then queried many times —
/// the programming engine asks it for every slot of every session in a mesocycle, and the exercise
/// browser asks it whenever a filter changes. That access pattern is why the indexes below are
/// built in `init`: a full scan of 1,324 records per slot would be wasted work, since only the few
/// hundred exercises that touch the target group can possibly score above zero.
///
/// Ordering is fully deterministic. Ties are broken by staple score and then by id, so the same
/// request always produces the same list in the same order — no flicker in the UI, and generated
/// programs are reproducible from their inputs alone.
struct ExerciseRecommendationEngine: Sendable {

    // MARK: - Tuning constants

    /// How many top-ranked exercises the greedy diversity pass looks at per pick. Wide enough that
    /// a different pattern or a different implement is always inside the window, narrow enough that
    /// the pass never drifts into genuinely unsuitable choices to buy variety.
    private static let greedyWindow = 24

    /// Variety is only ever traded against quality inside this band: a candidate must score at
    /// least 88 % of the best remaining option before its diversity is allowed to promote it.
    /// Without the band, a group with few available patterns (back is essentially two) starts
    /// paying for its third row with an unrelated triceps movement, which is a worse session.
    private static let qualityBand = 0.88

    /// Diversity penalties applied per previous pick that shares a property with the candidate.
    /// A repeated pattern is the most visible failure (three presses in a row), a repeated
    /// implement the next most (an all-cable session), a repeated exact target muscle the least.
    private static let repeatPatternPenalty = 0.22
    private static let repeatEquipmentPenalty = 0.14
    private static let repeatTargetPenalty = 0.10
    /// Floor on the diversity multiplier: variety must never fully override suitability.
    private static let diversityFloor = 0.25

    // MARK: - Stored state

    /// The catalogue, sorted by id once so every derived ordering starts from a stable base.
    private let catalog: [Exercise]
    /// Group → every exercise that gives that group any volume credit, plus everything whose
    /// primary group it is. Pre-sorted by id.
    private let byGroup: [MuscleGroup: [Exercise]]
    /// Group → plausible warm-up movements for it, pre-sorted best first.
    private let warmupsByGroup: [MuscleGroup: [Exercise]]

    // MARK: - Construction

    init(catalog: [Exercise]) {
        let ordered = catalog.sorted { $0.id < $1.id }
        self.catalog = ordered

        var groups: [MuscleGroup: [Exercise]] = [:]
        var warmups: [MuscleGroup: [Exercise]] = [:]
        for exercise in ordered {
            // The primary group is included explicitly: cardio work carries no volume credit at
            // all, and would otherwise be unreachable through the index.
            var touched: Set<MuscleGroup> = [exercise.primaryGroup]
            for (group, credit) in exercise.metadata.volumeContribution where credit > 0 {
                touched.insert(group)
            }
            for group in touched {
                groups[group, default: []].append(exercise)
            }
            if Self.isWarmupOption(exercise) {
                for group in Set(exercise.involvedGroups) {
                    warmups[group, default: []].append(exercise)
                }
            }
        }

        // Warm-up suitability depends only on the exercise, so the ordering is settled here rather
        // than on every call.
        self.byGroup = groups
        self.warmupsByGroup = warmups.mapValues { candidates in
            candidates.sorted { lhs, rhs in
                let left = Self.warmupScore(lhs)
                let right = Self.warmupScore(rhs)
                if left != right { return left > right }
                if lhs.metadata.stapleScore != rhs.metadata.stapleScore {
                    return lhs.metadata.stapleScore > rhs.metadata.stapleScore
                }
                return lhs.id < rhs.id
            }
        }
    }

    // MARK: - Ranking

    /// Every eligible exercise for the slot, best first.
    ///
    /// - Parameter limit: how many rows to return. The default of 40 is what the exercise picker
    ///   shows before the user scrolls; the programming engine asks for far fewer.
    func rank(
        _ request: ExerciseSelectionRequest,
        weights: ExerciseScoringWeights = .default,
        limit: Int = 40
    ) -> [ScoredExercise] {
        guard limit > 0 else { return [] }
        let pool = byGroup[request.targetGroup] ?? []
        guard !pool.isEmpty else { return [] }

        var scored: [ScoredExercise] = []
        scored.reserveCapacity(min(pool.count, 256))
        for exercise in pool {
            let breakdown = ExerciseScoring.score(exercise, request: request, weights: weights)
            guard !breakdown.isDisqualified, breakdown.total > 0 else { continue }
            scored.append(ScoredExercise(exercise: exercise, breakdown: breakdown))
        }

        scored.sort(by: Self.isBetter)
        return Array(scored.prefix(limit))
    }

    /// A deliberately varied set of exercises for one target group.
    ///
    /// Ranking alone would happily return five cable variations of the same press, because they all
    /// answer the same question equally well. So picks are made greedily: after each choice the
    /// request is updated (the id becomes unavailable, the pattern becomes "already used") and the
    /// remaining candidates are re-scored, then a further multiplier discounts repeats of the same
    /// implement and the same exact target muscle. The result is a session that looks like
    /// something a coach wrote rather than a database query.
    func best(
        _ request: ExerciseSelectionRequest,
        count: Int,
        weights: ExerciseScoringWeights = .default
    ) -> [Exercise] {
        guard count > 0 else { return [] }

        var working = request
        var chosen: [Exercise] = []
        var patternCounts: [MovementPattern: Int] = [:]
        var equipmentCounts: [Equipment: Int] = [:]
        var targetCounts: [Muscle: Int] = [:]
        chosen.reserveCapacity(count)

        while chosen.count < count {
            let ranked = rank(working, weights: weights, limit: Self.greedyWindow)
            guard let leader = ranked.first else { break }

            // Diversity may reorder the contenders; it may not replace them with weaker exercises.
            let floor = leader.score * Self.qualityBand
            var pick: Exercise?
            var pickValue = -1.0
            var pickIsDirect = false
            for candidate in ranked where candidate.score >= floor {
                // Directness outranks variety outright. A back day whose available patterns are
                // exhausted should take a third row, not a triceps push-down that happens to give
                // the lats a little indirect credit — the slot exists to train the target group.
                let direct = candidate.exercise.primaryGroup == request.targetGroup
                if pickIsDirect && !direct { continue }
                let adjusted = candidate.score * Self.diversityMultiplier(
                    candidate.exercise,
                    patternCounts: patternCounts,
                    equipmentCounts: equipmentCounts,
                    targetCounts: targetCounts
                )
                // Strict `>` keeps the pre-sorted, deterministic order as the tie-breaker.
                if (direct && !pickIsDirect) || adjusted > pickValue {
                    pickValue = adjusted
                    pickIsDirect = direct
                    pick = candidate.exercise
                }
            }
            guard let selected = pick else { break }

            chosen.append(selected)
            working.alreadySelected.insert(selected.id)
            working.patternsUsed.insert(selected.metadata.movementPattern)
            patternCounts[selected.metadata.movementPattern, default: 0] += 1
            equipmentCounts[selected.equipment, default: 0] += 1
            targetCounts[selected.target, default: 0] += 1
        }

        return chosen
    }

    /// Warm-up movements for the groups a session is about to train.
    ///
    /// Warm-ups are not scored like working sets: nobody cares whether a leg swing is progressable,
    /// and a stretch that would be disqualified from a working slot is exactly what belongs here.
    /// Suggestions are handed out round-robin across `groups` so that a full-body session warms up
    /// everything it is about to use rather than five variations for whichever group came first.
    ///
    /// Not being scored is not the same as being ungated. A user who said they cannot press
    /// overhead means it for the warm-up too, so when a profile is supplied the same
    /// `ExerciseScoring.blockingReason` that guards working slots runs here — with stretches
    /// allowed, because a stretch is the point of this list rather than a disqualification from it.
    ///
    /// - Parameters:
    ///   - groups: the muscle groups the session trains, most important first.
    ///   - equipment: what the user can actually reach right now. Passed separately from `profile`
    ///     because mid-session the kit within reach is often not the kit the profile describes.
    ///   - limit: maximum number of suggestions.
    ///   - profile: the user's movement limitations, avoided patterns and exclusions. Omitting it
    ///     applies no gate beyond `equipment`.
    func warmupSuggestions(
        for groups: [MuscleGroup],
        equipment: Set<Equipment>,
        limit: Int,
        profile: TrainingProfileSnapshot? = nil
    ) -> [Exercise] {
        guard limit > 0, !groups.isEmpty else { return [] }

        // De-duplicate while preserving the caller's priority order.
        var seenGroups = Set<MuscleGroup>()
        let orderedGroups = groups.filter { seenGroups.insert($0).inserted }

        var cursors = [Int](repeating: 0, count: orderedGroups.count)
        var chosenIDs = Set<String>()
        var result: [Exercise] = []
        result.reserveCapacity(limit)

        var exhausted = false
        while result.count < limit && !exhausted {
            exhausted = true
            for (index, group) in orderedGroups.enumerated() {
                guard result.count < limit else { break }
                let pool = warmupsByGroup[group] ?? []
                var cursor = cursors[index]
                while cursor < pool.count {
                    let candidate = pool[cursor]
                    cursor += 1
                    guard equipment.contains(candidate.equipment) else { continue }
                    guard Self.isPermitted(candidate, profile: profile) else { continue }
                    guard chosenIDs.insert(candidate.id).inserted else { continue }
                    result.append(candidate)
                    exhausted = false
                    break
                }
                cursors[index] = cursor
            }
        }
        return result
    }

    // MARK: - Ordering

    /// The single ordering rule used everywhere: score, then how central the movement is, then id.
    /// The final id comparison is what makes the ordering total, and therefore stable.
    private static func isBetter(_ lhs: ScoredExercise, _ rhs: ScoredExercise) -> Bool {
        if lhs.breakdown.total != rhs.breakdown.total { return lhs.breakdown.total > rhs.breakdown.total }
        if lhs.exercise.metadata.stapleScore != rhs.exercise.metadata.stapleScore {
            return lhs.exercise.metadata.stapleScore > rhs.exercise.metadata.stapleScore
        }
        return lhs.exercise.id < rhs.exercise.id
    }

    /// Discount applied to a candidate for looking like something already picked.
    ///
    /// The pattern component overlaps deliberately with the scoring engine's `movementDiversity`:
    /// that factor only knows whether a pattern has been used at all, this one knows how many
    /// times, which is what stops the third and fourth repeat.
    private static func diversityMultiplier(
        _ exercise: Exercise,
        patternCounts: [MovementPattern: Int],
        equipmentCounts: [Equipment: Int],
        targetCounts: [Muscle: Int]
    ) -> Double {
        let patterns = Double(patternCounts[exercise.metadata.movementPattern] ?? 0)
        let equipment = Double(equipmentCounts[exercise.equipment] ?? 0)
        let targets = Double(targetCounts[exercise.target] ?? 0)
        let penalty = repeatPatternPenalty * patterns
            + repeatEquipmentPenalty * equipment
            + repeatTargetPenalty * targets
        return max(diversityFloor, 1 - penalty)
    }

    // MARK: - Warm-up pool

    /// Whether a warm-up candidate clears the user's own rules.
    ///
    /// Equipment is checked by the caller against the set it was handed, so this covers what is left:
    /// mobility limitations, avoided patterns and exclusions. Stretches are explicitly allowed and
    /// loadability is irrelevant, which is the whole difference between a warm-up and a working set.
    private static func isPermitted(_ exercise: Exercise, profile: TrainingProfileSnapshot?) -> Bool {
        guard let profile else { return true }
        return ExerciseScoring.blockingReason(
            for: exercise,
            equipment: [exercise.equipment],
            excludedIDs: profile.excludedExerciseIDs,
            preference: nil,
            avoidedPatterns: profile.avoidedPatterns,
            limitations: profile.mobilityLimitations,
            unavailableIDs: [],
            allowsStretch: true,
            requiresLoadableMovement: false
        ) == nil
    }

    /// Whether an exercise could reasonably open a session.
    ///
    /// Either the metadata already flagged it (stretches, band work, named mobility drills) or it
    /// is simply cheap and controlled enough to raise temperature without spending anything: low
    /// systemic cost, no balance circus, and nothing explosive on cold tissue.
    private static func isWarmupOption(_ exercise: Exercise) -> Bool {
        let metadata = exercise.metadata
        if metadata.isPlyometric { return false }
        if metadata.isWarmupCandidate { return true }
        return metadata.fatigueCost <= 0.25 && metadata.stabilityDemand <= 0.7
    }

    /// How good a warm-up an exercise is, 0…1. Pure function of the exercise, so it is evaluated
    /// once per catalogue in `init` rather than per call.
    private static func warmupScore(_ exercise: Exercise) -> Double {
        let metadata = exercise.metadata
        var score = 0.30
        if metadata.isWarmupCandidate { score += 0.30 }
        // The cheaper the movement, the more of it fits before the real work starts.
        score += (1 - metadata.fatigueCost) * 0.25
        // Recognisable drills beat obscure ones when both would do.
        score += metadata.stapleScore * 0.10
        if metadata.difficulty == .beginner { score += 0.05 }
        // Held stretches rank below light dynamic work rather than above it. Static stretching
        // immediately before lifting transiently reduces force output, so band pull-aparts and
        // bodyweight drills go first; the stretches stay in the list, just further down it.
        if metadata.isStretch { score -= 0.08 }
        return ExerciseScoring.clamp01(score)
    }

    // MARK: - Introspection

    /// Number of records the engine was built from. Useful in tests and in the dataset audit.
    var catalogCount: Int { catalog.count }
}
