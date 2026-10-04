import Foundation

/// Finds sensible replacements for an exercise the user cannot or does not want to do.
///
/// This runs while somebody is standing in a gym between sets, so two things matter equally:
///
/// * **Speed.** The catalogue holds 500 records and the sheet must open instantly. The engine
///   indexes the catalogue once in `init`, then each call touches only the few hundred exercises
///   that train the same muscle group, gates them with set lookups before any scoring happens, and
///   computes the expensive similarity only for what survives. There is no string parsing, no
///   sorting of the full catalogue and no allocation per rejected candidate, which keeps a call at
///   well under a millisecond on device — comfortably inside the ~10 ms budget.
/// * **Judgement.** A list of technically-similar movements is not useful; the swap has to answer
///   the *reason* the user tapped the button. The reason therefore both filters (a "bodyweight
///   only" request never shows a cable machine) and re-ranks (a "make it easier" request promotes
///   supported, low-stability variations), and every candidate carries one to three concrete
///   reasons so the choice is legible in the two seconds the user will spend on it.
struct ExerciseSubstitutionEngine: Sendable {

    // MARK: - Tuning constants

    /// Blend of the three things that make a swap good. Similarity dominates: mid-session the user
    /// wants the same training effect, not the app's favourite exercise.
    private static let similarityShare = 0.72
    private static let preferenceShare = 0.18
    private static let familiarityShare = 0.10

    /// The reason modifier maps onto `[reasonFloor, 1]` rather than onto a multiplier above 1.
    /// Scores therefore stay on the 0…1 scale and never saturate at the ceiling, which is what
    /// keeps the ordering meaningful when a dozen candidates all satisfy the reason perfectly.
    private static let reasonFloor = 0.55

    /// Below this many survivors the primary-group pool is topped up from the wider index. Five is
    /// roughly what fills the substitution sheet without scrolling.
    private static let minimumUsefulCandidates = 5

    /// How many of the original's rarest tags a `dislike` request treats as "the thing they
    /// disliked". Two is enough to exclude the variation without excluding the movement.
    private static let dislikeTagDepth = 2

    // MARK: - Stored state

    private let catalog: [Exercise]
    /// Group → exercises whose *primary* group it is. The tight pool, used first.
    private let byPrimaryGroup: [MuscleGroup: [Exercise]]
    /// Group → exercises that give the group any volume credit. The fallback pool for small groups.
    private let byInvolvedGroup: [MuscleGroup: [Exercise]]
    /// Tag → rarity weight in 0…1, computed from the catalogue itself.
    ///
    /// This is inverse document frequency: `compound` appears on half the catalogue and says almost
    /// nothing about a match, whereas `preacher` or `behind_neck` appears on a handful and says
    /// almost everything. Weighting the tag overlap by rarity is what makes "like-for-like" mean
    /// like-for-like rather than "both are exercises".
    private let tagWeights: [String: Double]

    // MARK: - Construction

    init(catalog: [Exercise]) {
        let ordered = catalog.sorted { $0.id < $1.id }
        self.catalog = ordered

        var primary: [MuscleGroup: [Exercise]] = [:]
        var involved: [MuscleGroup: [Exercise]] = [:]
        var documentFrequency: [String: Int] = [:]
        for exercise in ordered {
            primary[exercise.primaryGroup, default: []].append(exercise)
            var touched: Set<MuscleGroup> = [exercise.primaryGroup]
            for (group, credit) in exercise.metadata.volumeContribution where credit > 0 {
                touched.insert(group)
            }
            for group in touched {
                involved[group, default: []].append(exercise)
            }
            for tag in exercise.metadata.substitutionTags {
                documentFrequency[tag, default: 0] += 1
            }
        }

        self.byPrimaryGroup = primary
        self.byInvolvedGroup = involved

        let total = Double(ordered.count)
        if total > 0 {
            let scale = log(total + 1)
            self.tagWeights = documentFrequency.mapValues { frequency in
                // Standard smoothed IDF, normalised by its own maximum so weights land in 0…1.
                // The 0.05 floor keeps a universal tag worth a little rather than nothing.
                let raw = log((total + 1) / Double(frequency + 1)) / scale
                return min(1, max(0.05, raw))
            }
        } else {
            self.tagWeights = [:]
        }
    }

    // MARK: - Alternatives

    /// Replacements for `request.original`, best first, capped at `request.limit`.
    ///
    /// The pipeline is deliberately ordered cheapest-first: index lookup, then O(1) set gates, then
    /// the reason filter, and only then the similarity computation. Candidates rejected by a gate
    /// cost three hash lookups and nothing else.
    ///
    /// When a reason filters everything out — "bodyweight only" in a catalogue subset with no
    /// bodyweight option for that muscle — the filter is dropped and the reason survives as a
    /// ranking preference, because an empty sheet mid-workout is the worst possible answer.
    func alternatives(
        for request: SubstitutionRequest,
        weights: SubstitutionWeights = .default
    ) -> [SubstitutionCandidate] {
        guard request.limit > 0 else { return [] }
        let original = request.original

        // Only computed for `dislike`, and only over the original's own tags, so this is a handful
        // of dictionary lookups rather than a scan.
        let avoidedTags = request.reason == .dislike
            ? distinctiveTags(of: original, limit: Self.dislikeTagDepth)
            : []

        var seen: Set<String> = [original.id]
        var candidates = evaluate(
            pool: byPrimaryGroup[original.primaryGroup] ?? [],
            request: request,
            weights: weights,
            avoidedTags: avoidedTags,
            applyReasonFilter: true,
            seen: &seen
        )

        if candidates.count < Self.minimumUsefulCandidates {
            candidates += evaluate(
                pool: byInvolvedGroup[original.primaryGroup] ?? [],
                request: request,
                weights: weights,
                avoidedTags: avoidedTags,
                applyReasonFilter: true,
                seen: &seen
            )
        }

        if candidates.isEmpty, request.reason != nil {
            var relaxed: Set<String> = [original.id]
            candidates = evaluate(
                pool: byInvolvedGroup[original.primaryGroup] ?? [],
                request: request,
                weights: weights,
                avoidedTags: [],
                applyReasonFilter: false,
                seen: &relaxed
            )
        }

        candidates.sort(by: Self.isBetter)
        return Array(candidates.prefix(request.limit))
    }

    /// Gates and scores one pool, appending to `seen` so a later pass never re-tests a record.
    private func evaluate(
        pool: [Exercise],
        request: SubstitutionRequest,
        weights: SubstitutionWeights,
        avoidedTags: Set<String>,
        applyReasonFilter: Bool,
        seen: inout Set<String>
    ) -> [SubstitutionCandidate] {
        let original = request.original
        var result: [SubstitutionCandidate] = []
        result.reserveCapacity(min(pool.count, 64))

        for exercise in pool {
            guard seen.insert(exercise.id).inserted else { continue }
            let preference = request.preferences[exercise.id]
            guard ExerciseScoring.blockingReason(
                for: exercise,
                equipment: request.availableEquipment,
                excludedIDs: request.profile.excludedExerciseIDs,
                preference: preference,
                avoidedPatterns: request.profile.avoidedPatterns,
                limitations: request.profile.mobilityLimitations,
                unavailableIDs: request.exercisesInSession,
                allowsStretch: false,
                requiresLoadableMovement: false
            ) == nil else { continue }

            if applyReasonFilter,
               !passesReasonFilter(exercise, request: request, avoidedTags: avoidedTags) { continue }

            let history = request.histories[exercise.id]
            let resemblance = similarity(original, exercise, weights: weights)
            let base = Self.similarityShare * resemblance
                + Self.preferenceShare * ExerciseScoring.preferenceScore(preference)
                + Self.familiarityShare * Self.familiarityScore(history, preference: preference)

            let fit = Self.reasonFit(exercise, original: original, reason: request.reason)
            let modifier = Self.reasonFloor + (1 - Self.reasonFloor) * fit
            let matchesTarget = exercise.target == original.target
            let matchesPattern = exercise.metadata.movementPattern == original.metadata.movementPattern

            result.append(
                SubstitutionCandidate(
                    exercise: exercise,
                    score: ExerciseScoring.clamp01(base * modifier),
                    similarity: resemblance,
                    reasons: explanations(
                        for: exercise,
                        request: request,
                        matchesTarget: matchesTarget,
                        matchesPattern: matchesPattern,
                        preference: preference,
                        history: history
                    ),
                    matchesTarget: matchesTarget,
                    matchesPattern: matchesPattern
                )
            )
        }
        return result
    }

    // MARK: - Similarity

    /// How interchangeable two exercises are, 0…1.
    ///
    /// The component order is the product's, not the algorithm's convenience: the same target
    /// muscle matters most, then the same movement pattern, then shared secondary muscles, then
    /// push/pull class and mechanic, then the descriptive tags, then how close the two sit in
    /// difficulty. Weights are renormalised by their own sum, so a caller may pass an unnormalised
    /// `SubstitutionWeights` and still get a 0…1 result.
    ///
    /// Tag rarity comes from the catalogue this engine was built with, so the measure is
    /// deterministic for a given catalogue — the same pair always scores the same.
    func similarity(_ a: Exercise, _ b: Exercise, weights: SubstitutionWeights = .default) -> Double {
        let total = weights.sameTarget + weights.samePattern + weights.secondaryOverlap
            + weights.samePushPull + weights.sameMechanic + weights.tagOverlap
            + weights.difficultyProximity + weights.equipmentFit
        guard total > 0 else { return 0 }

        var sum = weights.sameTarget * targetComponent(a, b)
        sum += weights.samePattern * Self.patternAffinity(a.metadata.movementPattern, b.metadata.movementPattern)
        sum += weights.secondaryOverlap * Self.secondaryOverlap(a, b)
        sum += weights.samePushPull * (a.metadata.pushPull == b.metadata.pushPull ? 1 : 0)
        // A compound and an isolation for the same muscle are still partly interchangeable — a
        // dumbbell fly does replace a bench press when the rack is taken, just imperfectly.
        sum += weights.sameMechanic * (a.metadata.mechanic == b.metadata.mechanic ? 1 : 0.3)
        sum += weights.tagOverlap * tagOverlap(a, b)
        sum += weights.difficultyProximity
            * (1 - Double(abs(a.metadata.difficulty.rank - b.metadata.difficulty.rank)) / 2)
        sum += weights.equipmentFit * Self.equipmentAffinity(a.equipment, b.equipment)

        return ExerciseScoring.clamp01(sum / total)
    }

    /// Agreement on what the movement is *for*.
    private func targetComponent(_ a: Exercise, _ b: Exercise) -> Double {
        if a.target == b.target { return 1 }
        if a.primaryGroup == b.primaryGroup { return 0.75 }
        // Different groups entirely: credit whichever direction of indirect work is stronger, so a
        // close-grip press still reads as a partial triceps substitute.
        let cross = max(
            b.metadata.volumeCredit(for: a.primaryGroup),
            a.metadata.volumeCredit(for: b.primaryGroup)
        )
        return ExerciseScoring.clamp01(cross * 0.6)
    }

    /// Jaccard index over the supporting musculature.
    ///
    /// Both sets empty means neither exercise reports synergists, which is an absence of evidence
    /// rather than evidence of difference, so it returns the neutral 0.5 instead of 0.
    private static func secondaryOverlap(_ a: Exercise, _ b: Exercise) -> Double {
        var left = Set(a.secondaryMuscles)
        if let synergist = a.synergist { left.insert(synergist) }
        var right = Set(b.secondaryMuscles)
        if let synergist = b.synergist { right.insert(synergist) }

        if left.isEmpty && right.isEmpty { return ExerciseScoring.neutral }
        let union = left.union(right)
        guard !union.isEmpty else { return ExerciseScoring.neutral }
        return Double(left.intersection(right).count) / Double(union.count)
    }

    /// Rarity-weighted Jaccard index over the descriptive tags.
    private func tagOverlap(_ a: Exercise, _ b: Exercise) -> Double {
        let left = a.metadata.substitutionTags
        let right = b.metadata.substitutionTags
        if left.isEmpty && right.isEmpty { return 0 }

        var shared = 0.0
        var union = 0.0
        for tag in left {
            let weight = tagWeights[tag] ?? 0.5
            union += weight
            if right.contains(tag) { shared += weight }
        }
        for tag in right where !left.contains(tag) {
            union += tagWeights[tag] ?? 0.5
        }
        return union > 0 ? min(1, shared / union) : 0
    }

    /// How closely two movement patterns train the same thing.
    ///
    /// Identical patterns score 1. Everything else comes from a hand-written table of the pairs a
    /// coach would actually accept as substitutes — a squat for a lunge, a hip thrust for a hinge,
    /// a fly for a bench press — because no property in the dataset encodes that relationship.
    private static func patternAffinity(_ a: MovementPattern, _ b: MovementPattern) -> Double {
        if a == b { return 1 }
        if let value = directedAffinity(a, b) { return value }
        if let value = directedAffinity(b, a) { return value }
        return 0
    }

    private static func directedAffinity(_ a: MovementPattern, _ b: MovementPattern) -> Double? {
        switch (a, b) {
        case (.horizontalPush, .chestFly): return 0.60
        case (.horizontalPush, .verticalPush): return 0.55
        case (.horizontalPush, .elbowExtension): return 0.35
        case (.verticalPush, .shoulderRaise): return 0.45
        case (.verticalPush, .chestFly): return 0.30
        case (.horizontalPull, .verticalPull): return 0.55
        case (.horizontalPull, .shrug): return 0.40
        case (.horizontalPull, .elbowFlexion): return 0.35
        case (.verticalPull, .elbowFlexion): return 0.40
        case (.verticalPull, .shrug): return 0.30
        case (.squat, .lunge): return 0.65
        case (.squat, .kneeExtension): return 0.50
        case (.squat, .hinge): return 0.45
        case (.lunge, .kneeExtension): return 0.40
        case (.lunge, .hipThrust): return 0.35
        case (.hinge, .hipThrust): return 0.60
        case (.hinge, .kneeFlexion): return 0.50
        case (.hinge, .carry): return 0.30
        case (.hipThrust, .hipAbduction): return 0.30
        case (.kneeExtension, .kneeFlexion): return 0.25
        case (.hipAbduction, .hipAdduction): return 0.30
        case (.shoulderRaise, .chestFly): return 0.30
        case (.shrug, .carry): return 0.25
        case (.coreFlexion, .coreAntiExtension): return 0.55
        case (.coreFlexion, .coreRotation): return 0.50
        case (.coreFlexion, .coreLateralFlexion): return 0.45
        case (.coreAntiExtension, .coreRotation): return 0.45
        case (.coreAntiExtension, .coreLateralFlexion): return 0.40
        case (.coreRotation, .coreLateralFlexion): return 0.55
        case (.wristFlexion, .wristExtension): return 0.45
        case (.elbowFlexion, .elbowExtension): return 0.10
        default: return nil
        }
    }

    /// How similar two implements feel to use.
    private static func equipmentAffinity(_ a: Equipment, _ b: Equipment) -> Double {
        if a == b { return 1 }
        let left = family(of: a)
        let right = family(of: b)
        if left == right { return 0.7 }
        // A cable stack and a selectorised machine are the closest cross-family pair there is.
        if (left == .cable && right == .machine) || (left == .machine && right == .cable) { return 0.5 }
        if (left == .bodyweight && right == .band) || (left == .band && right == .bodyweight) { return 0.4 }
        return 0.25
    }

    // MARK: - Reason handling

    /// Hard filter derived from the reason the user gave.
    ///
    /// These are exclusions the reason logically implies. Anything softer belongs in `reasonFit`,
    /// where it re-ranks instead of removing.
    private func passesReasonFilter(
        _ candidate: Exercise,
        request: SubstitutionRequest,
        avoidedTags: Set<String>
    ) -> Bool {
        guard let reason = request.reason else { return true }
        let original = request.original

        switch reason {
        case .machineUnavailable, .machineOccupied:
            // The exact implement is the thing that is missing or in use.
            return candidate.equipment != original.equipment
        case .preferDumbbell:
            return candidate.equipment == .dumbbell
        case .preferBarbell:
            return Self.barbellFamily.contains(candidate.equipment)
        case .preferCable:
            return candidate.equipment == .cable
        case .bodyweightOnly:
            // `weighted` and `assisted` are the dataset's loaded and assisted bodyweight variants —
            // a weighted dip is still a bodyweight movement.
            return Self.bodyweightFamily.contains(candidate.equipment)
        case .dislike:
            return avoidedTags.isDisjoint(with: candidate.metadata.substitutionTags)
        case .easier:
            return candidate.metadata.difficulty.rank <= original.metadata.difficulty.rank
        case .harder:
            return candidate.metadata.difficulty.rank >= original.metadata.difficulty.rank
        case .sameMuscleDifferentExercise:
            // "Different exercise" means it must actually differ in how it is performed, not just
            // in its name.
            return candidate.metadata.movementPattern != original.metadata.movementPattern
                || candidate.equipment != original.equipment
        case .jointDiscomfort:
            // Move the joint through a different path. No claim is made about why it hurts.
            return candidate.metadata.movementPattern != original.metadata.movementPattern
        }
    }

    /// How well a candidate answers the reason, 0…1. Mapped onto `[reasonFloor, 1]` by the caller.
    private static func reasonFit(
        _ candidate: Exercise,
        original: Exercise,
        reason: SubstitutionReason?
    ) -> Double {
        guard let reason else { return 1 }
        let metadata = candidate.metadata
        let source = original.metadata
        let tags = metadata.substitutionTags

        switch reason {
        case .machineUnavailable, .machineOccupied:
            switch family(of: candidate.equipment) {
            case .freeWeight: return 1.0
            case .bodyweight: return 0.9
            case .band: return 0.6
            case .ball, .implement: return 0.5
            case .cable: return 0.45
            case .cardioMachine: return 0.2
            case .machine: return 0.1
            case .other: return 0.4
            }
        case .preferDumbbell:
            switch candidate.equipment {
            case .dumbbell: return 1.0
            case .kettlebell: return 0.55
            case .weighted: return 0.4
            default: return 0.1
            }
        case .preferBarbell:
            switch candidate.equipment {
            case .barbell, .olympicBarbell: return 1.0
            case .ezBarbell: return 0.85
            case .trapBar: return 0.8
            case .smithMachine: return 0.6
            default: return 0.1
            }
        case .preferCable:
            switch candidate.equipment {
            case .cable: return 1.0
            case .band, .resistanceBand: return 0.55
            case .leverageMachine: return 0.45
            default: return 0.1
            }
        case .bodyweightOnly:
            switch candidate.equipment {
            case .bodyWeight: return 1.0
            case .assisted: return 0.8
            case .weighted: return 0.75
            default: return 0.05
            }
        case .dislike:
            // The further the swap is from the movement they disliked, the more likely it lands.
            var fit = 0.5
            if candidate.equipment != original.equipment { fit += 0.25 }
            if metadata.movementPattern != source.movementPattern { fit += 0.25 }
            return fit
        case .easier:
            var fit = 0.35
            fit += 0.25 * min(1, Double(max(0, source.difficulty.rank - metadata.difficulty.rank)) / 2)
            fit += 0.25 * ExerciseScoring.clamp01((source.stabilityDemand - metadata.stabilityDemand) / 0.4)
            if tags.contains("machine") || tags.contains("supported") || tags.contains("seated") {
                fit += 0.15
            }
            return min(1, fit)
        case .harder:
            var fit = 0.35
            fit += 0.25 * min(1, Double(max(0, metadata.difficulty.rank - source.difficulty.rank)) / 2)
            if family(of: candidate.equipment) == .freeWeight || candidate.equipment == .bodyWeight {
                fit += 0.20
            }
            if metadata.laterality != .bilateral { fit += 0.20 }
            return min(1, fit)
        case .sameMuscleDifferentExercise:
            var fit = 0.30
            if candidate.target == original.target { fit += 0.35 }
            if metadata.movementPattern != source.movementPattern { fit += 0.20 }
            if candidate.equipment != original.equipment { fit += 0.15 }
            return min(1, fit)
        case .jointDiscomfort:
            var fit = 0.30
            if tags.contains("machine") || tags.contains("supported") || tags.contains("seated") {
                fit += 0.30
            }
            // Less balancing to do means the load stays on the muscle and off the small stuff.
            fit += 0.40 * ExerciseScoring.clamp01((source.stabilityDemand - metadata.stabilityDemand) / 0.5)
            return min(1, fit)
        }
    }

    /// The rarest tags on an exercise — the ones that make it *that* exercise rather than a member
    /// of its family. Structural tags (pattern, mechanic, implement class) are excluded: disliking
    /// the preacher curl is not a statement about elbow flexion.
    private func distinctiveTags(of exercise: Exercise, limit: Int) -> Set<String> {
        let candidates = exercise.metadata.substitutionTags
            .filter { !Self.structuralTags.contains($0) }
            .sorted { lhs, rhs in
                let left = tagWeights[lhs] ?? 0.5
                let right = tagWeights[rhs] ?? 0.5
                if left != right { return left > right }
                return lhs < rhs
            }
        return Set(candidates.prefix(limit))
    }

    // MARK: - Explanations

    /// One to three concrete reasons this swap makes sense, most informative first.
    ///
    /// The first is always the relationship to the movement being replaced, because that is the
    /// question the user is actually asking. The second answers the reason they gave. The third, if
    /// there is room, is something specific about the exercise itself.
    ///
    /// De-duplication happens as the list is built rather than after it, which matters more than it
    /// looks: for "I'd rather use dumbbells" the answer to the reason *is* the equipment line, so
    /// filtering afterwards would let that repeat swallow the third slot and every candidate would
    /// come back with two lines instead of three. Skipping the repeat lets the next distinct extra —
    /// a favourite, a movement they are progressing on, a staple — take the place it was meant for.
    private func explanations(
        for candidate: Exercise,
        request: SubstitutionRequest,
        matchesTarget: Bool,
        matchesPattern: Bool,
        preference: ExercisePreferenceSnapshot?,
        history: ExerciseHistorySnapshot?
    ) -> [Explanation] {
        let original = request.original
        var keys: [String] = []
        var seen = Set<String>()

        func add(_ key: String) {
            guard keys.count < 3, seen.insert(key).inserted else { return }
            keys.append(key)
        }

        if matchesTarget && matchesPattern {
            add(Self.sameTargetAndPatternKey(for: candidate.metadata.pushPull))
        } else if matchesTarget {
            add("substitution.reason.sameTarget")
        } else if matchesPattern {
            add("substitution.reason.samePattern")
        } else if candidate.primaryGroup == original.primaryGroup {
            add("substitution.reason.sameMuscleGroup")
        } else {
            add("substitution.reason.similarMovement")
        }

        if let reason = request.reason,
           let specific = Self.reasonKey(reason, candidate: candidate, original: original) {
            add(specific)
        }

        // Fill the last slot with whichever extra is most worth saying.
        for extra in Self.extraKeys(
            candidate: candidate,
            preference: preference,
            history: history
        ) where keys.count < 3 {
            add(extra)
        }

        return keys.map { Explanation($0) }
    }

    private static func sameTargetAndPatternKey(for pushPull: PushPullClass) -> String {
        switch pushPull {
        case .push: "substitution.reason.sameTargetAndPattern.push"
        case .pull: "substitution.reason.sameTargetAndPattern.pull"
        case .legs: "substitution.reason.sameTargetAndPattern.legs"
        case .core: "substitution.reason.sameTargetAndPattern.core"
        case .cardio, .neutral: "substitution.reason.sameTargetAndPattern"
        }
    }

    private static func reasonKey(
        _ reason: SubstitutionReason,
        candidate: Exercise,
        original: Exercise
    ) -> String? {
        let metadata = candidate.metadata
        let tags = metadata.substitutionTags
        let supported = tags.contains("machine") || tags.contains("supported") || tags.contains("seated")

        switch reason {
        case .machineUnavailable, .machineOccupied:
            if candidate.equipment == .bodyWeight { return "substitution.reason.equipment.bodyweight" }
            return family(of: candidate.equipment) == .freeWeight
                ? "substitution.reason.noMachineNeeded"
                : equipmentKey(candidate.equipment)
        case .preferDumbbell, .preferBarbell, .preferCable, .bodyweightOnly:
            return equipmentKey(candidate.equipment)
        case .dislike:
            return "substitution.reason.differentFeel"
        case .easier:
            if metadata.difficulty.rank < original.metadata.difficulty.rank {
                return "substitution.reason.lowerDifficulty"
            }
            if metadata.stabilityDemand < original.metadata.stabilityDemand - 0.05 {
                return "substitution.reason.moreStable"
            }
            return supported ? "substitution.reason.supported" : nil
        case .harder:
            if metadata.difficulty.rank > original.metadata.difficulty.rank {
                return "substitution.reason.higherDifficulty"
            }
            if metadata.laterality != .bilateral { return "substitution.reason.unilateral" }
            return family(of: candidate.equipment) == .freeWeight
                ? "substitution.reason.freeWeight"
                : nil
        case .sameMuscleDifferentExercise:
            if metadata.movementPattern != original.metadata.movementPattern {
                return "substitution.reason.differentPattern"
            }
            return candidate.equipment != original.equipment
                ? "substitution.reason.differentEquipment"
                : nil
        case .jointDiscomfort:
            if supported { return "substitution.reason.supported" }
            if metadata.stabilityDemand < original.metadata.stabilityDemand - 0.05 {
                return "substitution.reason.moreStable"
            }
            return "substitution.reason.differentPattern"
        }
    }

    private static func extraKeys(
        candidate: Exercise,
        preference: ExercisePreferenceSnapshot?,
        history: ExerciseHistorySnapshot?
    ) -> [String] {
        var keys: [String] = []
        if preference?.isFavorite == true || preference?.feedback == .love {
            keys.append("substitution.reason.favorite")
        }
        if let key = equipmentKey(candidate.equipment) {
            keys.append(key)
        }
        if let history, history.totalSessions >= 3 {
            keys.append(
                ExerciseScoring.historicalPerformance(history) > 0.6
                    ? "substitution.reason.progressing"
                    : "substitution.reason.familiar"
            )
        }
        if candidate.metadata.stapleScore >= 0.6 {
            keys.append("substitution.reason.staple")
        }
        return keys
    }

    private static func equipmentKey(_ equipment: Equipment) -> String? {
        switch equipment {
        case .dumbbell: "substitution.reason.equipment.dumbbell"
        case .barbell, .olympicBarbell, .ezBarbell, .trapBar: "substitution.reason.equipment.barbell"
        case .cable: "substitution.reason.equipment.cable"
        case .leverageMachine, .smithMachine, .sledMachine, .assisted: "substitution.reason.equipment.machine"
        case .bodyWeight: "substitution.reason.equipment.bodyweight"
        case .band, .resistanceBand: "substitution.reason.equipment.band"
        case .kettlebell: "substitution.reason.equipment.kettlebell"
        case .weighted: "substitution.reason.equipment.weighted"
        default: nil
        }
    }

    // MARK: - Support

    /// How much a candidate is "one the user knows".
    ///
    /// Mid-workout, familiarity has real value: the setup is known and the working load is already
    /// in the log. It is blended with the progress trend so that a familiar movement the user has
    /// stalled on does not outrank a fresh one purely on habit.
    private static func familiarityScore(
        _ history: ExerciseHistorySnapshot?,
        preference: ExercisePreferenceSnapshot?
    ) -> Double {
        let sessions = max(history?.totalSessions ?? 0, preference?.timesPerformed ?? 0)
        // Six sessions is roughly where a lifter stops thinking about how to set the movement up.
        let familiarity = min(1, Double(sessions) / 6)
        return ExerciseScoring.clamp01(
            0.35 * familiarity + 0.65 * ExerciseScoring.historicalPerformance(history)
        )
    }

    /// Score, then similarity, then how central the movement is, then id. Total and therefore
    /// stable: the sheet never reorders itself between two identical requests.
    private static func isBetter(_ lhs: SubstitutionCandidate, _ rhs: SubstitutionCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.similarity != rhs.similarity { return lhs.similarity > rhs.similarity }
        if lhs.exercise.metadata.stapleScore != rhs.exercise.metadata.stapleScore {
            return lhs.exercise.metadata.stapleScore > rhs.exercise.metadata.stapleScore
        }
        return lhs.exercise.id < rhs.exercise.id
    }

    /// Coarse implement classes, used wherever "does this feel like the same kind of thing" matters
    /// more than the exact piece of kit.
    enum EquipmentFamily: Hashable, Sendable {
        case freeWeight
        case machine
        case cable
        case band
        case bodyweight
        case ball
        case cardioMachine
        case implement
        case other
    }

    static func family(of equipment: Equipment) -> EquipmentFamily {
        switch equipment {
        case .barbell, .olympicBarbell, .trapBar, .ezBarbell, .dumbbell, .kettlebell, .weighted:
            .freeWeight
        case .leverageMachine, .smithMachine, .sledMachine, .assisted:
            .machine
        case .cable:
            .cable
        case .band, .resistanceBand:
            .band
        case .bodyWeight:
            .bodyweight
        case .stabilityBall, .bosuBall, .medicineBall:
            .ball
        case .stationaryBike, .ellipticalMachine, .stepmillMachine, .skiergMachine, .upperBodyErgometer:
            .cardioMachine
        case .rope, .roller, .wheelRoller, .hammer, .tire:
            .implement
        case .other:
            .other
        }
    }

    /// Everything the user would call "a barbell movement".
    private static let barbellFamily: Set<Equipment> = [.barbell, .olympicBarbell, .ezBarbell, .trapBar]

    /// Bodyweight plus its assisted and loaded variants.
    private static let bodyweightFamily: Set<Equipment> = [.bodyWeight, .assisted, .weighted]

    /// Tags that describe the *class* of movement rather than the specific variation. Excluded when
    /// working out what makes one exercise distinctive.
    private static let structuralTags: Set<String> = {
        var tags = Set(MovementPattern.allCases.map(\.rawValue))
        tags.formUnion(Mechanic.allCases.map(\.rawValue))
        tags.formUnion([
            "bilateral", "unilateral", "free_weight", "handheld", "machine", "bar", "cable",
            "bodyweight", "band", "portable", "constant_tension"
        ])
        return tags
    }()

    /// Number of records the engine was built from. Useful in tests and in the dataset audit.
    var catalogCount: Int { catalog.count }
}
