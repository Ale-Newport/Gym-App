import Foundation

// MARK: - Tuning

/// Thresholds for post-session autoregulation.
///
/// Every number here is chosen to keep changes *small*. Autoregulation that swings a program around
/// after one session is indistinguishable from noise, and it destroys the user's ability to tell
/// whether anything is working. The ceilings below are the enforcement, not the aspiration: at most
/// one load adjustment per exercise, at most one added set per muscle group per round and never one
/// that would push the week past `min(target, maximum)`, and never more than a handful of proposals
/// from a single session.
enum AutoregulationTuning {

    /// A set counts as badly missed when it lands two or more reps short of target, or below three
    /// quarters of it. One rep short is a normal day.
    static let badMissAbsoluteReps = 2
    static let badMissRepFraction: Double = 0.75

    /// Share of an exercise's rated sets that must be badly missed before the load comes down.
    static let moderateMissShare: Double = 0.50
    static let severeMissShare: Double = 0.75
    /// Load cuts. Five per cent is a plate change on most bars; ten is the largest cut this engine
    /// will ever propose from a single session.
    static let moderateLoadCut: Double = 0.05
    static let severeLoadCut: Double = 0.10
    /// Fewer rated sets than this and there is nothing to draw a conclusion from.
    static let minimumRatedSetsForLoadCut = 2
    /// Replacing an exercise is a bigger change than lightening it, so it needs more evidence:
    /// every rated set short of target, across at least this many of them.
    static let minimumRatedSetsForSwap = 3

    /// "Easy" means the user said so, or finished essentially everything with well over the
    /// intended reps in reserve.
    static let easyRIRMargin: Double = 1.5
    static let addSetCompletionFloor: Double = 0.95
    /// Volume only goes up on a group that is genuinely recovered.
    static let addSetFatigueCeiling: Double = 0.45
    /// Volume comes off a group carrying serious outstanding fatigue.
    static let removeSetFatigueThreshold: Double = 0.75

    /// A session has to overrun by 15 % before it is worth trimming; anything less is timing noise.
    static let sessionOverrunTolerance: Double = 1.15
    static let maximumTrimMinutes: Double = 15
    /// The same ceiling in seconds, and the bound `apply` puts on any trim magnitude it is handed.
    static var maximumTrimSeconds: Int { Int(maximumTrimMinutes * 60) }

    /// Within-exercise drop-off: last working set below 65 % of the first set's reps, or four reps
    /// down, across at least three sets at a load that did not fall.
    static let dropOffRepFraction: Double = 0.65
    static let dropOffAbsoluteReps = 4
    static let dropOffMinimumSets = 3
    static let extraRestSeconds: Double = 30
    static let maximumRestSeconds = 240

    /// Caps that keep a single session from rewriting the program.
    static let maximumSetsPerExercise = 6
    static let maximumAddSetGroups = 2
    static let maximumSwapSuggestions = 2
    static let maximumRestSuggestions = 2
    static let maximumAdjustments = 6
    /// No planned exercise may lose more than one set in a single application, however many
    /// adjustments ask for it, and no session may shed more than three sets in total. Without this
    /// a fatigue-driven removal and a length-driven trim can compound and gut the main lift.
    static let maximumSetsRemovedPerExercise = 1
    static let maximumSetsRemovedPerSession = 3

    /// Fallback set duration when an exercise is missing from the catalogue.
    static let fallbackSetSeconds = 45
}

// MARK: - Engine

/// Turns one finished session into a short list of concrete, conservative changes for the next one.
///
/// The contract for `AutoregulationAdjustment.magnitude`, which the type itself does not spell out:
///
/// | kind             | magnitude                                        |
/// |------------------|--------------------------------------------------|
/// | `reduceLoad`     | fraction of load to remove (0.05 = 5 %)          |
/// | `increaseLoad`   | fraction of load to add                          |
/// | `addSet`         | number of sets to add (always 1)                 |
/// | `removeSet`      | number of sets to remove (always 1)              |
/// | `restLonger`     | extra rest, in seconds                           |
/// | `shortenSession` | minutes to trim from the session                 |
/// | `swapExercise`   | 0 — the substitution engine picks the replacement |
/// | `noChange`       | 0                                                |
///
/// Load changes are produced here but *applied* by the progression layer, because a
/// `GeneratedSession` carries no loads. `apply(_:to:catalog:)` therefore only performs the changes a
/// session plan can actually express: sets, rest and session length.
enum AutoregulationEngine {

    // MARK: Proposals

    /// Proposes adjustments for the next session, most safety-relevant first.
    ///
    /// - Parameters:
    ///   - outcome: The session that just finished.
    ///   - recovery: The recovery snapshot *after* that session, so fatigue is current.
    ///   - targets: Weekly volume targets, which bound how far volume may move.
    ///   - profile: Supplies the intended reps in reserve, the session length cap and the
    ///     difficulty ceiling used when judging whether an exercise simply does not suit the user.
    ///   - catalog: Exercise catalogue, keyed by id.
    /// - Returns: A non-empty array. When nothing warrants changing it contains a single
    ///   `noChange` adjustment, which the caller shows as "on track".
    static func adjustments(
        after outcome: SessionOutcome,
        recovery: RecoverySnapshot,
        targets: VolumeTargets,
        profile: TrainingProfileSnapshot,
        catalog: [String: Exercise]
    ) -> [AutoregulationAdjustment] {
        var proposals: [AutoregulationAdjustment] = []

        let missShares = badMissShares(in: outcome)
        let dropOffs = intraSetDropOffs(in: outcome)
        let reductions = loadReductions(
            outcome: outcome, missShares: missShares, dropOffs: dropOffs, catalog: catalog
        )
        let alreadyLightened = Set(reductions.compactMap(\.exerciseID))
        proposals.append(contentsOf: reductions)
        proposals.append(contentsOf: swapSuggestions(
            outcome: outcome,
            missShares: missShares,
            alreadyLightened: alreadyLightened,
            profile: profile,
            catalog: catalog
        ))
        proposals.append(contentsOf: setRemovals(outcome: outcome, recovery: recovery, targets: targets))
        proposals.append(contentsOf: sessionTrim(outcome: outcome, profile: profile))
        proposals.append(contentsOf: restExtensions(
            dropOffs: dropOffs, alreadyLightened: alreadyLightened, catalog: catalog
        ))
        proposals.append(contentsOf: setAdditions(
            outcome: outcome, recovery: recovery, targets: targets, profile: profile
        ))

        guard !proposals.isEmpty else {
            return [make(.noChange, magnitude: 0, explanation: Explanation("autoreg.noChange"))]
        }

        // Safety-relevant changes first, then structural ones, then additions.
        let order: [AutoregulationAdjustment.Kind] = [
            .reduceLoad, .increaseLoad, .removeSet, .shortenSession, .restLonger, .swapExercise, .addSet, .noChange
        ]
        let sorted = proposals.enumerated().sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.element.kind) ?? order.count
            let right = order.firstIndex(of: rhs.element.kind) ?? order.count
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)

        return Array(sorted.prefix(AutoregulationTuning.maximumAdjustments))
    }

    // MARK: Application

    /// Applies the structural adjustments to a planned session.
    ///
    /// Guarantees, in order of importance:
    /// * a `GeneratedExercise` with `isLocked` set is never touched, for any reason;
    /// * no exercise is ever reduced below one working set;
    /// * at most one set is removed per exercise and three across the session, however many
    ///   adjustments ask for it, so a fatigue-driven removal and a length-driven trim cannot
    ///   compound into gutting the main lift;
    /// * `estimatedMinutes` is moved by exactly the time the changes added or removed, so it stays
    ///   consistent with however the programming engine originally computed it.
    ///
    /// `reduceLoad` and `increaseLoad` are intentionally no-ops here: a session plan holds sets,
    /// reps, rest and target reps in reserve, not loads, so those adjustments belong to
    /// `ProgressionEngine`. `swapExercise` is likewise a no-op because choosing the replacement is
    /// the substitution engine's job, not this one's.
    static func apply(
        _ adjustments: [AutoregulationAdjustment],
        to session: GeneratedSession,
        catalog: [String: Exercise]
    ) -> GeneratedSession {
        guard !session.isRestDay, !session.exercises.isEmpty else { return session }

        var result = session
        var secondsDelta = 0
        var budget = RemovalBudget()

        // Rest first (it changes what a set costs in time), then volume, then the overall trim, so
        // the trim sees the session as it will actually be performed.
        let order: [AutoregulationAdjustment.Kind] = [.restLonger, .addSet, .removeSet, .shortenSession]
        for kind in order {
            for adjustment in adjustments where adjustment.kind == kind {
                switch kind {
                case .restLonger:
                    secondsDelta += applyRestExtension(adjustment, to: &result)
                case .addSet:
                    secondsDelta += applySetAddition(adjustment, to: &result, catalog: catalog)
                case .removeSet:
                    secondsDelta += applySetRemoval(adjustment, to: &result, catalog: catalog, budget: &budget)
                case .shortenSession:
                    secondsDelta += applySessionTrim(adjustment, to: &result, catalog: catalog, budget: &budget)
                default:
                    break
                }
            }
        }

        let adjustedSeconds = Double(result.estimatedMinutes * 60 + secondsDelta)
        result.estimatedMinutes = max(10, Int((adjustedSeconds / 60).rounded()))
        return result
    }

    // MARK: - Proposal builders

    /// Share of rated working sets that fell badly short of target, per exercise id.
    private static func badMissShares(in outcome: SessionOutcome) -> [String: (share: Double, rated: Int)] {
        var result: [String: (share: Double, rated: Int)] = [:]
        for performance in outcome.performances {
            var rated = 0
            var missed = 0
            for set in performance.sets where set.kind.countsAsWorkingSet {
                guard let target = set.targetReps, target > 0 else { continue }
                rated += 1
                if !set.isCompleted {
                    missed += 1
                    continue
                }
                guard let reps = set.reps else { continue }
                if (target - reps) >= AutoregulationTuning.badMissAbsoluteReps
                    || Double(reps) < AutoregulationTuning.badMissRepFraction * Double(target) {
                    missed += 1
                }
            }
            guard rated > 0 else { continue }
            let existing = result[performance.exerciseID]
            let totalRated = (existing?.rated ?? 0) + rated
            let totalMissed = (existing.map { $0.share * Double($0.rated) } ?? 0) + Double(missed)
            result[performance.exerciseID] = (totalMissed / Double(totalRated), totalRated)
        }
        return result
    }

    /// Reduce load where the reps were badly missed. At most one per exercise, by construction:
    /// the miss share is aggregated per exercise id before anything is proposed.
    private static func loadReductions(
        outcome: SessionOutcome,
        missShares: [String: (share: Double, rated: Int)],
        dropOffs: [String: Bool],
        catalog: [String: Exercise]
    ) -> [AutoregulationAdjustment] {
        var result: [AutoregulationAdjustment] = []
        for exerciseID in missShares.keys.sorted() {
            guard let entry = missShares[exerciseID],
                  entry.rated >= AutoregulationTuning.minimumRatedSetsForLoadCut,
                  entry.share >= AutoregulationTuning.moderateMissShare,
                  // The first set hit its target and only the later ones fell away: the load is
                  // demonstrably right, so rest gets changed instead.
                  dropOffs[exerciseID] != true,
                  let exercise = catalog[exerciseID],
                  // Taking load off a movement that carries none is not a change, it is a fiction.
                  exercise.metadata.loadability.carriesExternalLoad
            else { continue }

            let severe = entry.share >= AutoregulationTuning.severeMissShare
            result.append(make(
                .reduceLoad,
                exerciseID: exerciseID,
                muscleGroup: exercise.primaryGroup,
                magnitude: severe ? AutoregulationTuning.severeLoadCut : AutoregulationTuning.moderateLoadCut,
                explanation: Explanation(
                    severe ? "autoreg.reduceLoad.severe" : "autoreg.reduceLoad",
                    [exercise.name]
                )
            ))
        }
        return result
    }

    /// Suggest a swap where a load cut is not the answer.
    ///
    /// A single outcome cannot see "repeatedly" on its own, so two things stand in for it: an
    /// exercise the user actively replaced mid-session (they have already swapped it once), and an
    /// exercise that fell short on every set where reducing the load cannot help — either because
    /// it carries no external load, or because it is simply harder than this user should be
    /// programmed.
    ///
    /// Anything that already earned a load cut is skipped: taking weight off is the gentler fix and
    /// deserves a session to work, and telling the user to lighten an exercise *and* replace it in
    /// the same breath is advice they cannot act on.
    private static func swapSuggestions(
        outcome: SessionOutcome,
        missShares: [String: (share: Double, rated: Int)],
        alreadyLightened: Set<String>,
        profile: TrainingProfileSnapshot,
        catalog: [String: Exercise]
    ) -> [AutoregulationAdjustment] {
        var result: [AutoregulationAdjustment] = []

        // `substitutedExerciseIDs` is keyed by the exercise the user swapped *away from*, which is
        // exactly the "they already replaced this once" signal. It is deliberately not intersected
        // with `skippedExerciseIDs`: that array records the id of the slot as it was finally
        // performed — the *replacement* — so the two never name the same exercise and requiring
        // both would make this branch unreachable.
        for exerciseID in outcome.substitutedExerciseIDs.keys.sorted() {
            // An exercise missing from the catalogue cannot be named, and the sentence would read
            // "You swapped 0025 out during the session". Silence beats a raw dataset id.
            guard let exercise = catalog[exerciseID] else { continue }
            result.append(make(
                .swapExercise,
                exerciseID: exerciseID,
                muscleGroup: exercise.primaryGroup,
                magnitude: 0,
                explanation: Explanation("autoreg.swap.substituted", [exercise.name])
            ))
        }

        for exerciseID in missShares.keys.sorted() {
            guard let entry = missShares[exerciseID],
                  entry.rated >= AutoregulationTuning.minimumRatedSetsForSwap,
                  entry.share >= 1.0,
                  !alreadyLightened.contains(exerciseID),
                  let exercise = catalog[exerciseID],
                  !result.contains(where: { $0.exerciseID == exerciseID })
            else { continue }

            let cannotLighten = !exercise.metadata.loadability.carriesExternalLoad
            let tooAdvanced = exercise.metadata.difficulty.rank > profile.experience.maximumDifficulty.rank
            guard cannotLighten || tooAdvanced else { continue }

            result.append(make(
                .swapExercise,
                exerciseID: exerciseID,
                muscleGroup: exercise.primaryGroup,
                magnitude: 0,
                explanation: Explanation("autoreg.swap.failed", [exercise.name])
            ))
        }

        return Array(result.prefix(AutoregulationTuning.maximumSwapSuggestions))
    }

    /// Remove a set from the single most fatigued group, and only while that leaves the group at or
    /// above its weekly minimum — the dose below which the work stops being worth doing at all.
    private static func setRemovals(
        outcome: SessionOutcome,
        recovery: RecoverySnapshot,
        targets: VolumeTargets
    ) -> [AutoregulationAdjustment] {
        let candidates = outcome.groupSets.keys
            .filter { group in
                guard recovery.fatigue(for: group) >= AutoregulationTuning.removeSetFatigueThreshold else {
                    return false
                }
                let weekly = recovery.weeklySets[group] ?? 0
                let minimum = targets.minimum[group] ?? 0
                return weekly - 1 >= minimum
            }
            .sorted { lhs, rhs in
                let left = recovery.fatigue(for: lhs)
                let right = recovery.fatigue(for: rhs)
                if left != right { return left > right }
                return lhs.rawValue < rhs.rawValue
            }

        guard let group = candidates.first else { return [] }
        return [make(
            .removeSet,
            muscleGroup: group,
            magnitude: 1,
            explanation: Explanation("autoreg.removeSet.fatigue")
        )]
    }

    /// Add a set where the session was easy, the group is below its weekly target and recovery
    /// allows it.
    ///
    /// One set per group per round, and the week's total additions are bounded by the volume budget
    /// rather than by a counter: the proposal requires `weeklySets + 1` to stay within both the
    /// target and the ceiling, and `weeklySets` climbs as the added sets are performed, so once the
    /// group reaches `min(target, maximum)` a later call in the same week finds the room already
    /// taken. A group sitting well under target can therefore gain a set on more than one day of
    /// the week — which is the intent, since the target is the thing being converged on.
    private static func setAdditions(
        outcome: SessionOutcome,
        recovery: RecoverySnapshot,
        targets: VolumeTargets,
        profile: TrainingProfileSnapshot
    ) -> [AutoregulationAdjustment] {
        let ratedEasy = outcome.averageRIR.map { $0 >= Double(profile.defaultTargetRIR) + AutoregulationTuning.easyRIRMargin } ?? false
        let feltEasy = outcome.effortFeedback == .easy
        // The user's own verdict outranks the inferred one. A session they called hard or
        // exhausting is never a session to add volume after, however generous the logged reps in
        // reserve happen to look — the two together mean the rating is what to trust.
        let saidDemanding = outcome.effortFeedback == .hard || outcome.effortFeedback == .exhausting
        guard !saidDemanding,
              feltEasy || ratedEasy,
              outcome.completionRate >= AutoregulationTuning.addSetCompletionFloor
        else { return [] }

        let candidates = outcome.groupSets.keys
            .filter { group in
                let target = targets.target(for: group)
                guard target > 0 else { return false }
                let ceiling = targets.maximum[group] ?? target
                let weekly = recovery.weeklySets[group] ?? 0
                guard weekly + 1 <= min(target, ceiling) else { return false }
                return recovery.fatigue(for: group) <= AutoregulationTuning.addSetFatigueCeiling
            }
            .sorted { lhs, rhs in
                // Biggest shortfall first; the raw value keeps ties deterministic.
                let left = targets.target(for: lhs) - (recovery.weeklySets[lhs] ?? 0)
                let right = targets.target(for: rhs) - (recovery.weeklySets[rhs] ?? 0)
                if left != right { return left > right }
                return lhs.rawValue < rhs.rawValue
            }

        return candidates.prefix(AutoregulationTuning.maximumAddSetGroups).map { group in
            make(.addSet, muscleGroup: group, magnitude: 1, explanation: Explanation("autoreg.addSet"))
        }
    }

    /// Trim the session when it ran materially past the user's own cap.
    private static func sessionTrim(
        outcome: SessionOutcome,
        profile: TrainingProfileSnapshot
    ) -> [AutoregulationAdjustment] {
        let capSeconds = Double(max(1, profile.sessionMinutesCap) * 60)
        guard Double(outcome.durationSeconds) > capSeconds * AutoregulationTuning.sessionOverrunTolerance
        else { return [] }

        let overrunMinutes = (Double(outcome.durationSeconds) - capSeconds) / 60
        let trim = min(AutoregulationTuning.maximumTrimMinutes, overrunMinutes.rounded())
        guard trim >= 1 else { return [] }

        // The sentence reports how far the session ran past the cap, which is *not* the trim: the
        // trim is capped at `maximumTrimMinutes`, so quoting it would tell a user who ran 45 minutes
        // over that they ran 15 minutes over. `durationSeconds` is an `Int`, so the conversion back
        // to `Int` here cannot overflow.
        return [make(
            .shortenSession,
            magnitude: trim,
            explanation: Explanation("autoreg.shortenSession", [String(Int(overrunMinutes.rounded()))])
        )]
    }

    /// Exercises where reps fell away sharply between sets at a load that did not drop, mapped to
    /// whether the *first* working set still hit its rep target.
    ///
    /// That distinction decides the fix. If the opening set made its target, the load is evidently
    /// right and what failed was recovery between sets, so rest changes and load does not. If even
    /// the first set fell short, the load is the problem and the load cut above handles it.
    private static func intraSetDropOffs(in outcome: SessionOutcome) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for performance in outcome.performances {
            let sets = performance.workingSets
            guard sets.count >= AutoregulationTuning.dropOffMinimumSets,
                  let first = sets.first, let last = sets.last,
                  let firstReps = first.reps, firstReps > 0,
                  let lastReps = last.reps
            else { continue }
            // A load that fell between sets explains the reps on its own.
            guard (last.weightKg ?? 0) >= (first.weightKg ?? 0) else { continue }

            let sharpDrop = Double(lastReps) < AutoregulationTuning.dropOffRepFraction * Double(firstReps)
                || (firstReps - lastReps) >= AutoregulationTuning.dropOffAbsoluteReps
            guard sharpDrop else { continue }

            let metTarget = first.targetReps.map { firstReps >= $0 } ?? true
            result[performance.exerciseID] = (result[performance.exerciseID] ?? true) && metTarget
        }
        return result
    }

    /// Lengthen rest where performance fell away sharply between sets of the same exercise — the
    /// textbook sign of incomplete recovery between sets rather than of too much load.
    ///
    /// Anything that already earned a load cut is skipped, for the same reason the swap is: the
    /// engine has already decided the load was the problem there, and "lift less *and* rest longer"
    /// is two changes to one variable in a single session. Longer rest is the fix only where the
    /// load was not the one being blamed.
    private static func restExtensions(
        dropOffs: [String: Bool],
        alreadyLightened: Set<String>,
        catalog: [String: Exercise]
    ) -> [AutoregulationAdjustment] {
        dropOffs.keys.sorted()
            .filter { !alreadyLightened.contains($0) }
            // The explanation names the exercise, so an id the catalogue does not know cannot be
            // rendered as anything a user would recognise. Drop it rather than print the raw id.
            .compactMap { exerciseID in catalog[exerciseID] }
            .prefix(AutoregulationTuning.maximumRestSuggestions)
            .map { exercise in
                make(
                    .restLonger,
                    exerciseID: exercise.id,
                    muscleGroup: exercise.primaryGroup,
                    magnitude: AutoregulationTuning.extraRestSeconds,
                    explanation: Explanation("autoreg.restLonger", [exercise.name])
                )
            }
    }

    // MARK: - Application helpers

    private static func applyRestExtension(
        _ adjustment: AutoregulationAdjustment,
        to session: inout GeneratedSession
    ) -> Int {
        guard let exerciseID = adjustment.exerciseID,
              let index = session.exercises.firstIndex(where: { $0.exerciseID == exerciseID && !$0.isLocked })
        else { return 0 }

        let current = session.exercises[index].restSeconds
        let extra = wholeSeconds(adjustment.magnitude, limit: AutoregulationTuning.maximumRestSeconds)
        let proposed = min(AutoregulationTuning.maximumRestSeconds, current + extra)
        guard proposed > current else { return 0 }
        session.exercises[index].restSeconds = proposed
        // Every set after the first one pays the extra rest.
        return (proposed - current) * max(0, session.exercises[index].sets - 1)
    }

    private static func applySetAddition(
        _ adjustment: AutoregulationAdjustment,
        to session: inout GeneratedSession,
        catalog: [String: Exercise]
    ) -> Int {
        let candidates = matchingIndices(adjustment, in: session, catalog: catalog)
            .filter { session.exercises[$0].sets < AutoregulationTuning.maximumSetsPerExercise }
        // Volume goes on the cheapest movement for the group: the same extra set, less systemic cost.
        guard let index = candidates.min(by: { lhs, rhs in
            let left = catalog[session.exercises[lhs].exerciseID]?.metadata.fatigueCost ?? 0.5
            let right = catalog[session.exercises[rhs].exerciseID]?.metadata.fatigueCost ?? 0.5
            if left != right { return left < right }
            return session.exercises[lhs].orderIndex < session.exercises[rhs].orderIndex
        }) else { return 0 }

        session.exercises[index].sets += 1
        return setSeconds(of: session.exercises[index], catalog: catalog)
    }

    private static func applySetRemoval(
        _ adjustment: AutoregulationAdjustment,
        to session: inout GeneratedSession,
        catalog: [String: Exercise],
        budget: inout RemovalBudget
    ) -> Int {
        let candidates = matchingIndices(adjustment, in: session, catalog: catalog)
            .filter { budget.allows($0, in: session) }
        // Take it off the most fatiguing movement, and off the back of the session on a tie.
        guard let index = candidates.max(by: { lhs, rhs in
            let left = catalog[session.exercises[lhs].exerciseID]?.metadata.fatigueCost ?? 0.5
            let right = catalog[session.exercises[rhs].exerciseID]?.metadata.fatigueCost ?? 0.5
            if left != right { return left < right }
            return session.exercises[lhs].orderIndex < session.exercises[rhs].orderIndex
        }) else { return 0 }

        let cost = setSeconds(of: session.exercises[index], catalog: catalog)
        session.exercises[index].sets -= 1
        budget.record(index)
        return -cost
    }

    private static func applySessionTrim(
        _ adjustment: AutoregulationAdjustment,
        to session: inout GeneratedSession,
        catalog: [String: Exercise],
        budget: inout RemovalBudget
    ) -> Int {
        var toRemove = wholeSeconds(adjustment.magnitude * 60, limit: AutoregulationTuning.maximumTrimSeconds)
        guard toRemove > 0 else { return 0 }
        var removed = 0

        // Bounded by the number of removable sets, so the loop always terminates.
        let maximumIterations = session.exercises.reduce(0) { $0 + max(0, $1.sets - 1) }
        var iterations = 0
        while toRemove > 0 && iterations < maximumIterations {
            iterations += 1
            let candidates = session.exercises.indices.filter { budget.allows($0, in: session) }
            // Trim the most expensive slot first: fewest sets lost for the time reclaimed.
            guard let index = candidates.max(by: { lhs, rhs in
                let left = setSeconds(of: session.exercises[lhs], catalog: catalog)
                let right = setSeconds(of: session.exercises[rhs], catalog: catalog)
                if left != right { return left < right }
                return session.exercises[lhs].orderIndex < session.exercises[rhs].orderIndex
            }) else { break }

            let cost = setSeconds(of: session.exercises[index], catalog: catalog)
            session.exercises[index].sets -= 1
            budget.record(index)
            removed += cost
            toRemove -= cost
        }
        return -removed
    }

    /// Enforces the two hard limits on how much volume a single `apply` may strip: one set per
    /// planned exercise, three sets across the session, and never the last working set of anything.
    /// Locked exercises are refused outright.
    private struct RemovalBudget {
        private var perExercise: [Int: Int] = [:]
        private var total = 0

        func allows(_ index: Int, in session: GeneratedSession) -> Bool {
            guard session.exercises.indices.contains(index) else { return false }
            let exercise = session.exercises[index]
            guard !exercise.isLocked, exercise.sets > 1 else { return false }
            guard total < AutoregulationTuning.maximumSetsRemovedPerSession else { return false }
            return (perExercise[index] ?? 0) < AutoregulationTuning.maximumSetsRemovedPerExercise
        }

        mutating func record(_ index: Int) {
            perExercise[index, default: 0] += 1
            total += 1
        }
    }

    /// Indices of the exercises an adjustment may touch: the named exercise if it gave one,
    /// otherwise every unlocked exercise that credits the named group at least half a set.
    private static func matchingIndices(
        _ adjustment: AutoregulationAdjustment,
        in session: GeneratedSession,
        catalog: [String: Exercise]
    ) -> [Int] {
        session.exercises.indices.filter { index in
            let exercise = session.exercises[index]
            guard !exercise.isLocked else { return false }
            if let exerciseID = adjustment.exerciseID { return exercise.exerciseID == exerciseID }
            guard let group = adjustment.muscleGroup,
                  let record = catalog[exercise.exerciseID] else { return false }
            return record.metadata.volumeCredit(for: group) >= 0.5
        }
    }

    /// Converts a caller-supplied `magnitude` into a bounded whole number of seconds.
    ///
    /// `apply(_:to:catalog:)` accepts any `[AutoregulationAdjustment]`, not only the ones this
    /// engine produced, and `magnitude` is an unconstrained `Double`. `Int(Double.nan)` and
    /// `Int(1e30)` both trap, so the conversion is guarded rather than trusted: a non-finite
    /// magnitude means "no change" and an absurd one is clamped to the relevant ceiling.
    private static func wholeSeconds(_ value: Double, limit: Int) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(Double(limit), max(-Double(limit), value.rounded())))
    }

    /// Clock cost of one set of a planned exercise: the work itself plus the rest that follows it.
    private static func setSeconds(of exercise: GeneratedExercise, catalog: [String: Exercise]) -> Int {
        let work = catalog[exercise.exerciseID]?.metadata.estimatedSetSeconds
            ?? AutoregulationTuning.fallbackSetSeconds
        return work + exercise.restSeconds
    }

    // MARK: - Construction

    private static func make(
        _ kind: AutoregulationAdjustment.Kind,
        exerciseID: String? = nil,
        muscleGroup: MuscleGroup? = nil,
        magnitude: Double,
        explanation: Explanation
    ) -> AutoregulationAdjustment {
        AutoregulationAdjustment(
            id: stableID("\(kind.rawValue)|\(exerciseID ?? "-")|\(muscleGroup?.rawValue ?? "-")|\(explanation.key)"),
            kind: kind,
            exerciseID: exerciseID,
            muscleGroup: muscleGroup,
            magnitude: magnitude,
            explanation: explanation
        )
    }

    /// A UUID derived from the adjustment's own content.
    ///
    /// `AutoregulationAdjustment.id` defaults to a fresh `UUID()`, which would make the engine's
    /// output differ on every call and break both equality and SwiftUI's diffing across a refresh.
    /// Hashing the content instead keeps identical proposals identical. `Hasher` is deliberately
    /// not used: its seed is randomised per process, so it is not reproducible.
    private static func stableID(_ descriptor: String) -> UUID {
        // FNV-1a, run twice from different offset bases to fill all sixteen bytes.
        var bytes: [UInt8] = []
        for basis in [0xcbf2_9ce4_8422_2325 as UInt64, 0x9e37_79b9_7f4a_7c15 as UInt64] {
            var hash = basis
            for byte in descriptor.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: (hash >> UInt64(shift)) & 0xFF))
            }
        }
        // Stamp the RFC 4122 version and variant bits so the value is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
