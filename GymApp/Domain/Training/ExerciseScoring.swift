import Foundation

/// Scores one exercise against one slot in a session.
///
/// The selector rests on a single idea: a slot is a *question* — "give me a chest compound I can
/// load, that I have not trained this week, that suits a beginner who owns dumbbells" — and every
/// record in the catalogue answers it well or badly. `score` turns that answer into a number on a
/// fixed 0…1 scale; `isEligible` answers the separate and stricter question of whether the exercise
/// is allowed to be offered at all.
///
/// Two rules keep the result trustworthy:
///
/// * **Hard rules are gates, never weights.** Absent equipment, a user exclusion or a movement the
///   user cannot perform must not be out-voted by a strong score elsewhere, so those live in
///   `isEligible` and short-circuit before any arithmetic happens.
/// * **Every soft factor is normalised to 0…1 before it is weighted.** The additive weights sum to
///   `ExerciseScoringWeights.additiveSum` (1.0), so `total` is comparable between users, between
///   muscle groups and between releases, and changing a weight means exactly what it looks like it
///   means.
///
/// Everything here is a pure function of its arguments: no clock, no randomness, no persistence.
/// The same request always produces the same breakdown, which is what makes generated programs
/// reproducible and the whole thing testable.
enum ExerciseScoring {

    // MARK: - Tuning constants

    /// The value every "we know nothing" factor returns. Chosen as the midpoint so that a missing
    /// signal neither helps nor hurts — an exercise the user has never performed must not lose to
    /// one they have merely because we have data on the latter.
    static let neutral = 0.5

    /// Penalty applied inside `experienceSuitability` per difficulty step above the user's ceiling:
    /// one step is a stretch goal, two steps is a movement they should be taught rather than
    /// programmed.
    private static let difficultyOvershootPenalty = 0.35

    /// Soft-exclusion subtracted from the total per difficulty step above the user's ceiling, and
    /// its ceiling.
    ///
    /// `experienceSuitability` alone carries only 7 % of the scale, which is not enough to keep a
    /// novice away from a movement that happens to score well everywhere else. This is subtracted
    /// outside the weights, so two steps above the ceiling costs roughly a quarter of the whole
    /// score — a demotion strong enough to matter without being an outright ban, since a movement
    /// one grade too hard is often exactly the right thing to work towards.
    private static let overshootExclusionPerStep = 0.12
    /// Multiplier for a user who has never trained. They have no technique to fall back on and no
    /// experience of what "too heavy" feels like, so the app stays further from the edge.
    private static let untrainedOvershootMultiplier = 1.5
    private static let overshootExclusionCeiling = 0.36

    /// Stability above this level starts to make the *stabilisers* the limiting factor rather than
    /// the target muscle. Below it, balance demand is irrelevant to a novice's results.
    private static let stabilityComfortThreshold = 0.45

    /// Share of an exercise's variety penalty that survives when the user has favourited it.
    /// A favourite repeated on purpose is a feature, not a monotony bug.
    private static let favoriteRepetitionRelief = 0.5

    /// Baseline variety penalty for an exercise seen in the recent-session window.
    private static let recentRepetitionBase = 0.7

    /// Fraction of the non-fatigue weight mass reallocated to `fatigueEfficiency` when the caller
    /// says the session is nearly full, and the absolute ceiling on that reallocation.
    private static let lowFatigueBoostFraction = 0.12
    private static let lowFatigueBoostCeiling = 0.08

    // MARK: - Eligibility

    /// Whether `exercise` may be offered for this slot at all, and why not when it may not.
    ///
    /// Callers should treat a `false` result as final. Every reason returned here is something the
    /// user themselves configured or something the movement structurally cannot do, so "score it
    /// lower and hope" would be the wrong response to all of them.
    ///
    /// An `ExerciseSelectionRequest` always describes a *working* slot — warm-ups and mobility work
    /// are chosen by `ExerciseRecommendationEngine.warmupSuggestions`, which does not score — so
    /// stretches are gated out here unconditionally.
    static func isEligible(
        _ exercise: Exercise,
        request: ExerciseSelectionRequest
    ) -> (eligible: Bool, reason: Explanation?) {
        let reason = blockingReason(
            for: exercise,
            equipment: request.profile.availableEquipment,
            excludedIDs: request.profile.excludedExerciseIDs,
            preference: request.preferences[exercise.id],
            avoidedPatterns: request.profile.avoidedPatterns,
            limitations: request.profile.mobilityLimitations,
            unavailableIDs: request.alreadySelected,
            allowsStretch: false,
            requiresLoadableMovement: request.requiresLoadableMovement
        )
        return (reason == nil, reason)
    }

    /// The gate shared by exercise selection and exercise substitution.
    ///
    /// Substitution runs mid-workout against a different equipment set and a different "already
    /// taken" list than programming does, so the rules live here as loose parameters rather than
    /// being read off one request type. Ordering is deliberate: the most specific and most
    /// actionable reason wins, because this string is what the user reads when an exercise they
    /// expected to see is missing.
    ///
    /// - Returns: `nil` when the exercise is allowed, otherwise the reason it is not.
    static func blockingReason(
        for exercise: Exercise,
        equipment: Set<Equipment>,
        excludedIDs: Set<String>,
        preference: ExercisePreferenceSnapshot?,
        avoidedPatterns: Set<MovementPattern>,
        limitations: [MobilityLimitation],
        unavailableIDs: Set<String>,
        allowsStretch: Bool,
        requiresLoadableMovement: Bool
    ) -> Explanation? {
        let metadata = exercise.metadata

        if unavailableIDs.contains(exercise.id) {
            return Explanation("selection.blocked.alreadyInSession")
        }
        if excludedIDs.contains(exercise.id) {
            return Explanation("selection.blocked.excluded")
        }
        if let preference {
            if preference.feedback == .neverRecommend {
                return Explanation("selection.blocked.neverRecommend")
            }
            if preference.isExcluded {
                return Explanation("selection.blocked.excluded")
            }
        }
        if !equipment.contains(exercise.equipment) {
            return Explanation("selection.blocked.equipment")
        }
        if avoidedPatterns.contains(metadata.movementPattern) {
            return Explanation("selection.blocked.avoidedPattern")
        }
        for limitation in limitations {
            if limitation.blockedPatterns.contains(metadata.movementPattern) {
                return Explanation("selection.blocked.limitation")
            }
            // `blockedTags` catches the cases a pattern cannot: "behind neck" is a vertical push
            // like any other, but it is the one variation a restricted shoulder must not do.
            if !limitation.blockedTags.isDisjoint(with: metadata.substitutionTags) {
                return Explanation("selection.blocked.limitation")
            }
        }
        if metadata.isStretch && !allowsStretch {
            return Explanation("selection.blocked.stretch")
        }
        if requiresLoadableMovement && !(metadata.trackingMode.usesWeight && metadata.trackingMode.usesReps) {
            return Explanation("selection.blocked.notLoadable")
        }
        return nil
    }

    // MARK: - Scoring

    /// The full per-factor breakdown for one exercise against one slot.
    ///
    /// Disqualified exercises still return a breakdown — with `isDisqualified` set, `total` at zero
    /// and the reason attached — so the exercise browser can grey a row out and say why instead of
    /// silently dropping it.
    static func score(
        _ exercise: Exercise,
        request: ExerciseSelectionRequest,
        weights: ExerciseScoringWeights = .default
    ) -> ExerciseScoreBreakdown {
        var breakdown = ExerciseScoreBreakdown()

        let gate = isEligible(exercise, request: request)
        guard gate.eligible else {
            breakdown.isDisqualified = true
            breakdown.disqualificationReason = gate.reason
            breakdown.exclusionPenalty = 1
            breakdown.total = 0
            return breakdown
        }

        let metadata = exercise.metadata
        let preference = request.preferences[exercise.id]

        breakdown.targetMatch = targetMatch(exercise, request: request)
        breakdown.secondaryUtility = secondaryUtility(exercise, request: request)
        breakdown.goalSuitability = goalSuitability(exercise, request: request)
        // Availability is a gate, not a dial: anything that reaches this line is usable in the
        // user's gym today. The weight it carries keeps `total` on the documented 0…1 scale.
        breakdown.equipmentAvailability = 1
        breakdown.userPreference = preferenceScore(preference)
        breakdown.historicalPerformance = historicalPerformance(request.histories[exercise.id])
        breakdown.movementDiversity = movementDiversity(exercise, request: request)
        breakdown.progressionSuitability = metadata.progressionSuitability
        breakdown.fatigueEfficiency = fatigueEfficiency(exercise, favorLowFatigue: request.favorLowFatigue)
        breakdown.experienceSuitability = experienceSuitability(exercise, profile: request.profile)
        breakdown.stapleBonus = metadata.stapleScore
        breakdown.priorityBonus = priorityBonus(exercise, request: request)
        breakdown.recentRepetitionPenalty = recentRepetitionPenalty(
            exercise, request: request, preference: preference
        )
        breakdown.exclusionPenalty = softExclusionPenalty(exercise, profile: request.profile)

        let applied = effectiveWeights(weights, for: request)
        var total = applied.targetMatch * breakdown.targetMatch
        total += applied.secondaryUtility * breakdown.secondaryUtility
        total += applied.goalSuitability * breakdown.goalSuitability
        total += applied.equipmentAvailability * breakdown.equipmentAvailability
        total += applied.userPreference * breakdown.userPreference
        total += applied.historicalPerformance * breakdown.historicalPerformance
        total += applied.movementDiversity * breakdown.movementDiversity
        total += applied.progressionSuitability * breakdown.progressionSuitability
        total += applied.fatigueEfficiency * breakdown.fatigueEfficiency
        total += applied.experienceSuitability * breakdown.experienceSuitability
        total += applied.stapleBonus * breakdown.stapleBonus
        // `priorityBonus` sits outside `additiveSum` on purpose: it is allowed to push a
        // prioritised group's best options against the 1.0 ceiling rather than merely reshuffling
        // them against each other.
        total += applied.priorityBonus * breakdown.priorityBonus
        total -= applied.recentRepetitionPenalty * breakdown.recentRepetitionPenalty
        // The exclusion penalty carries no weight of its own — it is the safety rail expressed as a
        // number, so it is subtracted at full scale: 1.0 for a hard gate, a fraction for a movement
        // that is merely too advanced for this user right now.
        total -= breakdown.exclusionPenalty

        breakdown.total = clamp01(total)
        return breakdown
    }

    /// The weights actually used for a request.
    ///
    /// When the caller flags a nearly-full session, weight is moved *into* `fatigueEfficiency` from
    /// the remaining additive factors in proportion, which is a genuine re-prioritisation rather
    /// than a fudge: `additiveSum` is preserved exactly, so `total` stays on the same 0…1 scale and
    /// scores from a low-fatigue slot remain comparable with scores from a normal one.
    static func effectiveWeights(
        _ weights: ExerciseScoringWeights,
        for request: ExerciseSelectionRequest
    ) -> ExerciseScoringWeights {
        guard request.favorLowFatigue else { return weights }
        let rest = weights.additiveSum - weights.fatigueEfficiency
        guard rest > 0 else { return weights }

        let boost = min(lowFatigueBoostCeiling, rest * lowFatigueBoostFraction)
        let scale = (rest - boost) / rest

        var adjusted = weights
        adjusted.targetMatch *= scale
        adjusted.secondaryUtility *= scale
        adjusted.goalSuitability *= scale
        adjusted.equipmentAvailability *= scale
        adjusted.userPreference *= scale
        adjusted.historicalPerformance *= scale
        adjusted.movementDiversity *= scale
        adjusted.progressionSuitability *= scale
        adjusted.experienceSuitability *= scale
        adjusted.stapleBonus *= scale
        adjusted.fatigueEfficiency += boost
        return adjusted
    }

    // MARK: - Factors

    /// How directly the exercise trains the group the slot exists for.
    ///
    /// A direct hit scores 1.0; anything else earns the fractional weekly-volume credit the
    /// metadata already assigns (0.5 for a compound's synergists, 0.33 for an isolation's), which
    /// keeps selection and volume accounting speaking the same language.
    private static func targetMatch(_ exercise: Exercise, request: ExerciseSelectionRequest) -> Double {
        if exercise.primaryGroup == request.targetGroup { return 1 }
        return clamp01(exercise.metadata.volumeCredit(for: request.targetGroup))
    }

    /// Useful indirect volume the exercise adds to the *other* groups the user cares about.
    ///
    /// With stated priorities this rewards a row that also feeds prioritised biceps. Without them
    /// it falls back to rewarding honest whole-movement coverage, capped so that a five-muscle
    /// compound cannot out-score a well-aimed one on this factor alone.
    private static func secondaryUtility(_ exercise: Exercise, request: ExerciseSelectionRequest) -> Double {
        let target = request.targetGroup
        let priorities = request.profile.priorityGroups.filter { $0 != target }

        guard !priorities.isEmpty else {
            let indirect = exercise.metadata.volumeContribution
                .filter { $0.key != target }
                .reduce(0.0) { $0 + $1.value }
            return min(1, indirect / 1.5)
        }

        var best = 0.0
        var accumulated = 0.0
        for (index, group) in priorities.enumerated() {
            // Priorities are stored best-first, so later entries count for a little less.
            let rank = max(0.6, 1.0 - 0.1 * Double(index))
            let value = clamp01(exercise.metadata.volumeCredit(for: group)) * rank
            best = max(best, value)
            accumulated += value
        }
        // Mostly "does it serve the top priority", partly "how many priorities does it serve".
        return clamp01(0.65 * best + 0.35 * min(1, accumulated / 2))
    }

    /// How well the movement serves the user's stated goals.
    ///
    /// Goals are blended rather than switched on: a user chasing muscle *and* strength should get
    /// exercises that serve both, so each goal contributes with a decaying weight (1, 0.5, 0.25)
    /// and the result is renormalised. Only the first three goals are consulted — beyond that the
    /// list stops expressing a preference.
    private static func goalSuitability(_ exercise: Exercise, request: ExerciseSelectionRequest) -> Double {
        let goals = request.profile.goals.isEmpty ? [TrainingGoal.generalFitness] : request.profile.goals
        var weighted = 0.0
        var weightSum = 0.0
        for (index, goal) in goals.prefix(3).enumerated() {
            let weight = 1.0 / pow(2, Double(index))
            weighted += weight * goalFit(exercise, goal: goal)
            weightSum += weight
        }
        var value = weightSum > 0 ? weighted / weightSum : neutral

        // A slot that explicitly asked for a compound (the first movement of a session) or an
        // isolation (the finisher) should not be filled with the other kind unless nothing else
        // exists, so the mismatch is a large multiplier rather than a small subtraction.
        if let preferred = request.preferredMechanic, exercise.metadata.mechanic != preferred {
            value *= 0.6
        }
        return clamp01(value)
    }

    private static func goalFit(_ exercise: Exercise, goal: TrainingGoal) -> Double {
        let metadata = exercise.metadata
        // Isolations are not worthless for goals that favour compounds, they are simply second
        // choice; 0.4 keeps them selectable when a session needs one.
        let compoundness = metadata.mechanic == .compound ? 1.0 : 0.4
        let affinity = repRangeAffinity(metadata, goalRange: goal.primaryRepRange)

        switch goal {
        case .buildStrength:
            // Strength is bought with load that can be added in small, repeatable steps, on
            // multi-joint movements, in the low rep ranges.
            return clamp01(0.42 * metadata.progressionSuitability + 0.28 * compoundness + 0.30 * affinity)
        case .buildMuscle, .recomposition, .targetMuscleGroup:
            // Hypertrophy follows stimulus per set far more closely than it follows movement
            // selection, so `stimulusScore` dominates here.
            return clamp01(0.60 * metadata.stimulusScore + 0.25 * affinity + 0.15 * compoundness)
        case .loseFat:
            // Fat loss is won in the kitchen; training's job is to hold on to muscle in the time
            // available, which favours the same stimulus-dense compounds hypertrophy wants.
            return clamp01(0.45 * metadata.stimulusScore + 0.30 * compoundness + 0.25 * affinity)
        case .improveEndurance:
            // Higher rep work that can be repeated often, which means low systemic cost.
            return clamp01(0.5 * affinity + 0.5 * (1 - metadata.fatigueCost))
        case .maintain, .generalFitness:
            return clamp01(0.45 * metadata.stimulusScore + 0.30 * compoundness + 0.25 * affinity)
        }
    }

    /// Agreement between the exercise's own recommended rep range and the range a goal calls for.
    ///
    /// Blends overlap (do the windows share reps at all?) with midpoint distance (how far apart are
    /// they?), because overlap alone produces a cliff between 5–8 and 8–12 that does not reflect
    /// how interchangeable those two prescriptions really are.
    private static func repRangeAffinity(_ metadata: ExerciseMetadata, goalRange: RepRange) -> Double {
        // Timed and distance work has no meaningful rep window, so it neither fits nor misfits.
        guard metadata.trackingMode.usesReps else { return 0.55 }
        let range = metadata.recommendedRepRange
        let overlap = max(0, min(range.upper, goalRange.upper) - max(range.lower, goalRange.lower) + 1)
        let span = max(range.upper - range.lower, goalRange.upper - goalRange.lower) + 1
        let overlapFraction = span > 0 ? min(1, Double(overlap) / Double(span)) : 0
        let distance = abs(Double(range.midpoint - goalRange.midpoint))
        let proximity = max(0, 1 - distance / 10)
        return clamp01(0.6 * overlapFraction + 0.4 * proximity)
    }

    /// The user's standing opinion, mapped from a multiplier onto the shared 0…1 scale.
    ///
    /// `scoreMultiplier` runs 0 (never recommend) to 1.62 (favourited and loved) around a neutral
    /// 1.0, so halving it puts "no opinion" at exactly 0.5 and keeps the mapping monotone.
    /// Shared with `ExerciseSubstitutionEngine`, which blends the same opinion into its own score.
    static func preferenceScore(_ preference: ExercisePreferenceSnapshot?) -> Double {
        guard let preference else { return neutral }
        return clamp01(preference.scoreMultiplier / 2)
    }

    /// Whether the user has actually been getting stronger on this exercise.
    ///
    /// Rewarding demonstrated progress is how the selector learns which movements suit a particular
    /// body without ever being told. With no history it returns `neutral`, so a new exercise is
    /// never punished for being new.
    ///
    /// Shared with `ExerciseSubstitutionEngine` so that "have they been progressing on this" means
    /// exactly the same thing in both places.
    static func historicalPerformance(_ history: ExerciseHistorySnapshot?) -> Double {
        guard let history, history.performances.count >= 2 else { return neutral }

        // Newest first. Five sessions is enough to see a trend and short enough that a training
        // block from two months ago no longer colours today's choice.
        let window = history.performances.prefix(5)
        guard let newest = window.first.flatMap(strengthProxy),
              let oldest = window.last.flatMap(strengthProxy),
              // The three proxies are measured in different units — an estimated one-rep max in
              // kilograms, a rep count, a held duration — so a ratio between two of them is
              // meaningless. A session logged without load next to one logged with it would read as
              // a collapse or a breakthrough that never happened, so the comparison is simply
              // declined and the factor stays neutral.
              newest.kind == oldest.kind,
              oldest.value > 0 else { return neutral }

        let change = (newest.value - oldest.value) / oldest.value
        // ±8 % across the window saturates the factor: past that the extra information is small and
        // mostly reflects rep-range changes rather than genuine progress.
        return clamp01(neutral + max(-0.35, min(0.4, change * 5)))
    }

    /// Which measure a session's work had to be reduced to. Only two sessions expressed in the same
    /// unit may be compared.
    private enum ProxyKind: Hashable {
        /// Estimated one-rep max in kilograms.
        case estimatedOneRepMax
        /// Total working repetitions, for movements that carry no external load.
        case totalReps
        /// Total held seconds, for movements that are neither loaded nor counted in reps.
        case totalSeconds
    }

    /// A single "how much did they do on this day" number, plus the unit it is expressed in.
    private static func strengthProxy(
        _ performance: ExercisePerformance
    ) -> (value: Double, kind: ProxyKind)? {
        let sets = performance.workingSets
        guard !sets.isEmpty else { return nil }

        var best = 0.0
        for set in sets {
            guard let weight = set.weightKg, let reps = set.reps, weight > 0, reps > 0 else { continue }
            // Epley. Reps are capped at 20 because every one-rep-max formula becomes fiction well
            // before that, and an uncapped estimate would let a light high-rep day look like a PR.
            best = max(best, weight * (1 + Double(min(reps, 20)) / 30))
        }
        if best > 0 { return (best, .estimatedOneRepMax) }

        // Unloadable movements: total working reps, then held seconds, are the honest proxies.
        let reps = sets.reduce(0) { $0 + ($1.reps ?? 0) }
        if reps > 0 { return (Double(reps), .totalReps) }
        let seconds = sets.reduce(0) { $0 + ($1.durationSeconds ?? 0) }
        return seconds > 0 ? (Double(seconds), .totalSeconds) : nil
    }

    /// Whether the movement adds something the session does not already have.
    ///
    /// Repeating a pattern inside one session is the single most common way an automatically
    /// generated workout goes wrong (three chest presses in a row), so a repeat is punished hard
    /// while covering the antagonist of something already trained earns a small bonus.
    private static func movementDiversity(_ exercise: Exercise, request: ExerciseSelectionRequest) -> Double {
        let pattern = exercise.metadata.movementPattern
        let repeated = request.patternsUsed.contains(pattern)

        var value: Double
        if let preferred = request.preferredPattern {
            if pattern == preferred {
                value = repeated ? 0.6 : 1.0
            } else {
                value = repeated ? 0.1 : 0.5
            }
        } else {
            value = repeated ? 0.2 : 0.75
        }

        if let antagonist = pattern.antagonist, request.patternsUsed.contains(antagonist) {
            // Balancing a pattern the session already trained is worth a nudge: it is how push/pull
            // ratios stay sane over a mesocycle.
            value += 0.12
        }
        return clamp01(value)
    }

    /// Stimulus bought per unit of systemic fatigue.
    ///
    /// The raw ratio is unbounded, so it is squashed with `r / (r + 1)`, which puts "as much
    /// stimulus as fatigue" at exactly 0.5 and keeps the tails from dominating. When the session is
    /// nearly full the absolute cost matters as much as the ratio, so the two are blended.
    private static func fatigueEfficiency(_ exercise: Exercise, favorLowFatigue: Bool) -> Double {
        let metadata = exercise.metadata
        let ratio = metadata.stimulusScore / max(metadata.fatigueCost, 0.05)
        var value = ratio / (ratio + 1)
        if favorLowFatigue {
            value = 0.55 * value + 0.45 * (1 - metadata.fatigueCost)
        }
        return clamp01(value)
    }

    /// Whether the movement is a sensible thing to hand *this* user.
    ///
    /// Two separate worries: the movement being graded above them (`difficultyOvershoot`), and the
    /// movement asking for balance they do not yet have, which makes the stabilisers rather than
    /// the target muscle the limiting factor and wastes the set.
    private static func experienceSuitability(
        _ exercise: Exercise,
        profile: TrainingProfileSnapshot
    ) -> Double {
        let metadata = exercise.metadata
        let overshoot = difficultyOvershoot(metadata.difficulty, profile: profile)
        var value = 0.88 - difficultyOvershootPenalty * Double(overshoot)

        let tolerance = max(0, min(3, profile.experience.rank + techniqueShift(profile)))

        // 1.0 for a complete novice, 0.0 for a coached advanced lifter.
        let noviceness = Double(3 - tolerance) / 3
        value -= noviceness * max(0, metadata.stabilityDemand - stabilityComfortThreshold) * 0.55

        let tags = metadata.substitutionTags
        if noviceness >= 0.66, tags.contains("machine") || tags.contains("supported") {
            // A guided path is where a novice should be learning to push hard.
            value += 0.10
        }
        if profile.experience == .advanced, metadata.difficulty == .beginner, tags.contains("machine") {
            // Not wrong, just a poor use of an experienced lifter's session time.
            value -= 0.08
        }
        return clamp01(value)
    }

    /// How many difficulty grades an exercise sits above what this user should normally be given.
    ///
    /// The ceiling comes from `ExperienceLevel.maximumDifficulty` and is shifted by how the user
    /// described their technique: somebody who has been coached can be handed a barbell far sooner
    /// than somebody teaching themselves from videos, and an intermediate who says they are
    /// unfamiliar should be treated as a beginner until their log says otherwise.
    private static func difficultyOvershoot(
        _ difficulty: Difficulty,
        profile: TrainingProfileSnapshot
    ) -> Int {
        // The floor is −1, not 0. Clamping at 0 made `.unfamiliar` a no-op for exactly the users it
        // exists to protect: a beginner already has a ceiling of 0, so the −1 shift vanished and
        // someone who told us they are unsure of their form was scored identically to someone
        // confident. A ceiling of −1 reads as "even beginner movements are a stretch for you",
        // which is what they said.
        let ceiling = min(2, max(-1, profile.experience.maximumDifficulty.rank + techniqueShift(profile)))
        return max(0, difficulty.rank - ceiling)
    }

    /// Difficulty grades of credit (or debt) the user's self-reported technique is worth.
    private static func techniqueShift(_ profile: TrainingProfileSnapshot) -> Int {
        switch profile.techniqueConfidence {
        case .unfamiliar: -1
        case .learning, .confident: 0
        case .coached: 1
        }
    }

    /// Penalties that are nearly gates: real enough to move an exercise out of the top of a list,
    /// short of removing it from the catalogue.
    ///
    /// Only difficulty overshoot qualifies today. Everything else the user has told us — dislikes,
    /// exclusions, avoided patterns — is either an opinion (handled by `preferenceScore`) or an
    /// instruction (handled by `blockingReason`).
    private static func softExclusionPenalty(
        _ exercise: Exercise,
        profile: TrainingProfileSnapshot
    ) -> Double {
        let overshoot = difficultyOvershoot(exercise.metadata.difficulty, profile: profile)
        guard overshoot > 0 else { return 0 }
        let multiplier = profile.experience == .never ? untrainedOvershootMultiplier : 1.0
        return min(overshootExclusionCeiling, overshootExclusionPerStep * Double(overshoot) * multiplier)
    }

    /// Variety penalty for something the user has just done. Subtracted, not added.
    ///
    /// The recent-session window is the case that actually shapes rankings. The full-scale branch
    /// for `alreadySelected` is defensive only: that set is also a hard gate, so `score` has already
    /// returned by the time this is reached. It is kept so the helper stays correct if it is ever
    /// called outside the gate.
    private static func recentRepetitionPenalty(
        _ exercise: Exercise,
        request: ExerciseSelectionRequest,
        preference: ExercisePreferenceSnapshot?
    ) -> Double {
        if request.alreadySelected.contains(exercise.id) { return 1 }
        guard request.recentlyUsedIDs.contains(exercise.id) else { return 0 }
        // Rotating away from a favourite is worse than a little monotony.
        if preference?.isFavorite == true || preference?.feedback == .love {
            return recentRepetitionBase * favoriteRepetitionRelief
        }
        return recentRepetitionBase
    }

    /// Extra credit when this slot serves a group the user asked to prioritise.
    ///
    /// Indirect work on a priority counts for half: prioritising biceps should pull in curls, not
    /// simply re-rank every row in the catalogue.
    private static func priorityBonus(_ exercise: Exercise, request: ExerciseSelectionRequest) -> Double {
        guard let index = request.profile.priorityGroups.firstIndex(of: request.targetGroup) else { return 0 }
        let rank = max(0.6, 1.0 - 0.1 * Double(index))
        return clamp01(rank * (exercise.primaryGroup == request.targetGroup ? 1.0 : 0.5))
    }

    // MARK: - Helpers

    static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
