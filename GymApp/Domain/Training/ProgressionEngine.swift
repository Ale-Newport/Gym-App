import Foundation

// MARK: - Progression

/// Decides what the user should do next on one exercise, given what they did last time.
///
/// This is the algorithm the whole app is built around, so it is written to a few explicit rules:
///
/// - **Evidence before load.** A single good session is not a trend. Except on the deliberately
///   linear strategies, the load only moves after the documented success condition has been met on
///   consecutive sessions, and it only moves down after consecutive shortfalls.
/// - **Small steps.** A jump is capped at 10 % of the current load, and at 5 % above 100 kg. Absolute
///   plate sizes stay constant as loads grow, so an unchecked "one more pair of plates" rule gets
///   *relatively* smaller over time — which is fine — while the reverse case, a 2.5 kg jump on a
///   10 kg dumbbell curl, is a 25 % increase and a good way to fail a set. The caps exist for the
///   light end of the range, not the heavy one.
/// - **Never a fake load.** A press-up has no kilograms. Movements with no selectable load progress
///   in reps, seconds or sets, and `recommendedWeightKg` stays `nil` for them.
/// - **The stored load is what the user selects.** For a weighted dip that is the load *added* to
///   the body; for an assisted pull-up it is the assistance *removed*. The engine progresses that
///   number, and for assisted movements every comparison runs backwards, because a smaller
///   assistance is a harder set.
/// - **Every decision explains itself with real numbers.** A recommendation the user cannot
///   interrogate is a recommendation they cannot sensibly overrule.
///
/// The engine is pure: value types in, value types out, no clock, no randomness, no persistence.
enum ProgressionEngine {

    // MARK: - Tuning constants

    private enum Constants {
        /// How much load comes off after two sessions short of the bottom of the rep range.
        /// Ten percent is the conventional reset: enough to restore a clean, controlled set, small
        /// enough that the load is usually reclaimed within two or three sessions.
        static let reduceLoadFraction = 0.10
        /// The immediate shave used by `.rirBased` when the user finished far closer to failure than
        /// they intended. Smaller than a full reset because one hard session is not a plateau.
        static let rirOvershootReduction = 0.05

        /// Largest single load increase, as a fraction of the current load.
        static let standardIncreaseCap = 0.10
        /// The cap tightens above this load. The absolute jump is already meaningful there, and a
        /// 10 % step on a 140 kg squat is 14 kg, which is a different set, not a progression.
        static let heavyLoadThresholdKg = 100.0
        static let heavyIncreaseCap = 0.05

        /// The customary smallest jump on a big barbell lift: a pair of 1.25 kg plates.
        static let barbellCompoundStepKg = 2.5

        /// Consecutive qualifying sessions required before double progression adds load.
        static let doubleProgressionSessions = 2
        /// Linear strategies act on a single qualifying session — that is what makes them linear.
        static let linearProgressionSessions = 1
        /// Sessions short of the bottom of the range before the load is cut.
        static let regressionSessionsBeforeCut = 2
        /// Sessions inside the range with no improvement before the load is reset downwards.
        static let stallSessionsBeforeReset = 4

        /// The app will not program more than this many working sets of one movement. Past it the
        /// right answer is a second exercise or more load, not more sets.
        static let compoundSetCeiling = 5
        static let isolationSetCeiling = 6
        /// Where `.volumeProgression` restarts its set count after a load increase.
        static let volumeProgressionBaseSets = 3

        /// The app will not chase rep counts past this. Beyond roughly thirty reps a set is
        /// measuring local endurance, not the quality the user came for.
        static let repCeiling = 30
        /// Past three minutes an isometric hold trains endurance rather than strength, so the app
        /// adds difficulty instead of time.
        static let holdCeilingSeconds = 180
        /// Timed cardio and loaded carries have far more room before the same argument applies.
        static let timedCeilingSeconds = 1800
        /// A stored "rep range" whose top is below this cannot be seconds — it is the default 8–12
        /// rep window a fresh progression state carries.
        static let minimumRecognisableSeconds = 15
        static let minimumHoldSeconds = 15

        /// Conventional deload magnitudes, used when the caller supplies only the week flag.
        static let defaultDeloadIntensityReduction = 0.10
        static let defaultDeloadVolumeReduction = 0.40
        /// Hard ceilings. A deload is a lighter week, not a different sport.
        static let deloadIntensityCeiling = 0.35
        static let deloadVolumeCeiling = 0.60
        /// Extra reps in reserve during a deload week — the point is to stay far from failure.
        static let deloadExtraRIR = 2

        /// How many increments the search for the next selectable load will try before giving up.
        /// Generous enough to cross the gaps in a sparse dumbbell rack, bounded so it cannot spin.
        static let maxLoadProbes = 16

        /// Tolerance for comparing loads that have both been through plate rounding.
        static let loadEpsilon = 0.001
    }

    // MARK: - Entry point

    /// The next prescription for one exercise.
    ///
    /// `input.strategy` is the authority, not `input.state.strategy`: the caller may be running a
    /// program-level override for this block, and the returned `updatedState` carries the strategy
    /// that was actually applied.
    static func decide(_ input: ProgressionInput) -> ProgressionDecision {
        let meta = input.exercise.metadata
        let targetRIR = safeTargetRIR(input)
        let increment = LoadRounding.increment(for: meta.loadability, profile: input.increments)
        // A medicine ball "carries external load" but offers no ladder to climb, which the zero
        // increment expresses. Treat anything with no selectable step as unloadable.
        let isLoadable = meta.loadability.carriesExternalLoad && increment > 0

        var currentWeight: Double?
        if isLoadable {
            guard let weight = usableWorkingWeight(input),
                  !input.state.needsCalibration,
                  !input.history.performances.isEmpty else {
                // A load we do not trust is worse than no load at all, so calibration comes first.
                return calibrationDecision(input, targetRIR: targetRIR)
            }
            currentWeight = weight
        }

        if input.isDeloadWeek {
            return deloadDecision(input, currentWeight: currentWeight, targetRIR: targetRIR)
        }

        if meta.trackingMode.usesReps {
            if let currentWeight {
                return repBasedDecision(input, currentWeight: currentWeight, targetRIR: targetRIR)
            }
            return unloadedRepDecision(input, targetRIR: targetRIR)
        }
        return durationDecision(input, targetRIR: targetRIR, currentWeight: currentWeight)
    }

    // MARK: - Calibration

    /// Turns the user's verdict on a calibration set into the next load to try.
    ///
    /// The multipliers live on `CalibrationFeedback` so the same numbers drive the UI's preview.
    /// Two details matter here. On an assisted movement the scale runs backwards — "too easy" means
    /// take assistance away — so the multiplier is inverted. And on a coarse ladder a 5–15 % nudge
    /// can round straight back onto the load the user just rejected, so the result is forced at
    /// least one selectable step in the intended direction.
    static func applyCalibration(
        _ feedback: CalibrationFeedback,
        attemptedWeightKg: Double,
        loadability: Loadability,
        increments: EquipmentIncrements
    ) -> Double {
        guard attemptedWeightKg.isFinite, attemptedWeightKg >= 0 else { return 0 }
        let base = LoadRounding.increment(for: loadability, profile: increments)
        // Nothing to adjust on a movement with no selectable load; hand the input straight back.
        guard loadability.carriesExternalLoad, base > 0 else { return attemptedWeightKg }

        let inverted = loadability == .assistedBodyweight
        let multiplier = inverted ? 1 / feedback.loadMultiplier : feedback.loadMultiplier
        var result = LoadRounding.round(
            kilograms: max(0, attemptedWeightKg * multiplier),
            loadability: loadability,
            profile: increments
        )

        guard feedback != .correct else { return result }
        guard abs(result - attemptedWeightKg) < Constants.loadEpsilon else { return result }

        let goesUp = multiplier > 1
        var probe = 1
        while probe <= Constants.maxLoadProbes {
            let raw = goesUp
                ? attemptedWeightKg + Double(probe) * base
                : attemptedWeightKg - Double(probe) * base
            if raw < 0 { break }
            let candidate = LoadRounding.round(
                kilograms: raw, loadability: loadability, profile: increments
            )
            if goesUp ? candidate > attemptedWeightKg + Constants.loadEpsilon
                      : candidate < attemptedWeightKg - Constants.loadEpsilon {
                result = candidate
                break
            }
            probe += 1
        }
        return result
    }

    // MARK: - Deload

    /// The lighter prescription for a deload week.
    ///
    /// `intensityReduction` and `volumeReduction` come from `DeloadEngine`'s assessment; zeros are
    /// read as "unspecified" and replaced with the conventional −10 % load / −40 % sets, and both are
    /// clamped so no assessment can prescribe a week that is not really training. The set count
    /// never falls below one: a deload keeps the movement pattern alive, it does not delete it.
    ///
    /// `currentSets` is optional because `ProgressionStateSnapshot` does not record a set count —
    /// callers that know the planned sets pass them, and callers that do not get `nil` back rather
    /// than an invented baseline.
    static func deloadPrescription(
        from state: ProgressionStateSnapshot,
        assessment: DeloadAssessment,
        loadability: Loadability,
        increments: EquipmentIncrements,
        currentSets: Int? = nil
    ) -> (weightKg: Double?, sets: Int?) {
        let intensity = min(
            max(assessment.intensityReduction > 0
                ? assessment.intensityReduction
                : Constants.defaultDeloadIntensityReduction, 0),
            Constants.deloadIntensityCeiling
        )
        let volume = min(
            max(assessment.volumeReduction > 0
                ? assessment.volumeReduction
                : Constants.defaultDeloadVolumeReduction, 0),
            Constants.deloadVolumeCeiling
        )

        var weight: Double?
        if loadability.carriesExternalLoad,
           let current = state.workingWeightKg,
           current > 0 {
            let inverted = loadability == .assistedBodyweight
            let target = inverted ? current * (1 + intensity) : current * (1 - intensity)
            var rounded = LoadRounding.round(
                kilograms: max(0, target), loadability: loadability, profile: increments
            )
            let base = LoadRounding.increment(for: loadability, profile: increments)
            // A deload that rounds back onto the working load is not a deload.
            if intensity > 0, base > 0, abs(rounded - current) < Constants.loadEpsilon {
                let stepped = inverted ? current + base : current - base
                if stepped >= 0 {
                    let candidate = LoadRounding.round(
                        kilograms: stepped, loadability: loadability, profile: increments
                    )
                    if inverted ? candidate > current : candidate < current { rounded = candidate }
                }
            }
            weight = rounded
        }

        let sets = currentSets.map { max(1, Int((Double($0) * (1 - volume)).rounded())) }
        return (weight, sets)
    }

    private static func deloadDecision(
        _ input: ProgressionInput,
        currentWeight: Double?,
        targetRIR: Int
    ) -> ProgressionDecision {
        let meta = input.exercise.metadata
        let range = meta.trackingMode.usesReps ? workingRepRange(input) : durationWindow(input)
        let baselineSets = usablePerformances(input.history).first?.workingSets.count

        // `ProgressionInput` carries only the week flag, so the engine applies the conventional
        // deload. A caller holding a richer `DeloadAssessment` should call `deloadPrescription`
        // directly and pass the result through.
        let assessment = DeloadAssessment(
            shouldDeload: true,
            severity: 0.5,
            reasons: [],
            volumeReduction: Constants.defaultDeloadVolumeReduction,
            intensityReduction: Constants.defaultDeloadIntensityReduction
        )
        var state = input.state
        state.workingWeightKg = currentWeight
        let prescription = deloadPrescription(
            from: state,
            assessment: assessment,
            loadability: meta.loadability,
            increments: input.increments,
            currentSets: baselineSets
        )

        let explanation: Explanation
        switch (currentWeight, prescription.weightKg, baselineSets, prescription.sets) {
        case let (.some(old), .some(new), .some(oldSets), .some(newSets)):
            explanation = Explanation("progression.explain.deload", [
                input.exercise.name,
                TrainingFormat.weight(old),
                TrainingFormat.weight(new),
                TrainingFormat.count(oldSets),
                TrainingFormat.count(newSets)
            ])
        case let (.some(old), .some(new), _, _):
            explanation = Explanation("progression.explain.deloadLoadOnly", [
                input.exercise.name,
                TrainingFormat.weight(old),
                TrainingFormat.weight(new)
            ])
        case let (_, _, .some(oldSets), .some(newSets)):
            explanation = Explanation("progression.explain.deloadUnloaded", [
                input.exercise.name,
                TrainingFormat.count(oldSets),
                TrainingFormat.count(newSets)
            ])
        default:
            explanation = Explanation("progression.explain.deloadEasy", [input.exercise.name])
        }

        // The counters and the remembered working load are deliberately untouched: a deload is a
        // planned lighter week, not evidence about the user, and next week must resume where the
        // progression left off.
        return ProgressionDecision(
            action: .deload,
            recommendedWeightKg: prescription.weightKg,
            recommendedRepRange: range,
            recommendedSets: prescription.sets,
            targetRIR: min(5, targetRIR + Constants.deloadExtraRIR),
            explanation: explanation,
            updatedState: input.state,
            requiresCalibration: false
        )
    }

    private static func calibrationDecision(
        _ input: ProgressionInput,
        targetRIR: Int
    ) -> ProgressionDecision {
        let meta = input.exercise.metadata
        let range = meta.trackingMode.usesReps ? workingRepRange(input) : durationWindow(input)
        var state = input.state
        state.repRange = range
        state.needsCalibration = true
        state.consecutiveSuccesses = 0
        state.consecutiveStalls = 0
        state.consecutiveRegressions = 0
        state.strategy = input.strategy

        // The weight is deliberately `nil`: `LoadEstimator` owns the first number, and returning a
        // half-guess here would let it be mistaken for a decision the engine stands behind.
        return ProgressionDecision(
            action: .calibrate,
            recommendedWeightKg: nil,
            recommendedRepRange: range,
            recommendedSets: nil,
            targetRIR: targetRIR,
            explanation: Explanation("progression.explain.calibrate", [input.exercise.name]),
            updatedState: state,
            requiresCalibration: true
        )
    }

    // MARK: - Loaded, rep-based movements

    private static func repBasedDecision(
        _ input: ProgressionInput,
        currentWeight: Double,
        targetRIR: Int
    ) -> ProgressionDecision {
        let range = workingRepRange(input)
        let sessions = usablePerformances(input.history)
        guard let recent = sessions.first else {
            return decision(
                input, action: .maintain, weight: currentWeight, range: range, sets: nil,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.noData", [input.exercise.name]),
                successes: input.state.consecutiveSuccesses,
                stalls: input.state.consecutiveStalls,
                regressions: input.state.consecutiveRegressions,
                lastPerformedAt: input.state.lastPerformedAt
            )
        }

        let evaluation = evaluate(
            recent,
            previous: sessions.dropFirst().first,
            range: range,
            targetRIR: targetRIR,
            plannedWeightKg: currentWeight,
            loadability: input.exercise.metadata.loadability
        )
        let setCount = recent.workingSets.count

        // 1. A session in which no set reached the planned load says nothing about the planned load.
        if !evaluation.trainedAtPlannedLoad {
            return decision(
                input, action: .maintain, weight: currentWeight, range: range, sets: setCount,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.lighterThanPlanned", [
                    input.exercise.name,
                    TrainingFormat.weight(currentWeight),
                    TrainingFormat.weight(evaluation.easiestLoggedWeightKg)
                ]),
                successes: input.state.consecutiveSuccesses,
                stalls: input.state.consecutiveStalls,
                regressions: input.state.consecutiveRegressions,
                lastPerformedAt: recent.date
            )
        }

        // 2. Falling short of the bottom of the range. One bad session is noise; two is a signal.
        if !evaluation.allMetBottom {
            return shortfallDecision(
                input, currentWeight: currentWeight, range: range, setCount: setCount,
                targetRIR: targetRIR, evaluation: evaluation, recent: recent
            )
        }

        // 3. Strategy-specific progression.
        switch input.strategy {
        case .doubleProgression:
            guard evaluation.allHitTop, evaluation.meetsRIRTarget else { break }
            return loadIncreaseDecision(
                input, currentWeight: currentWeight, range: range, resetRange: range,
                setCount: setCount, recommendedSets: setCount, targetRIR: targetRIR,
                evaluation: evaluation, requiredSessions: Constants.doubleProgressionSessions,
                recent: recent
            )

        case .loadProgression:
            // Linear progression works to a fixed target — the bottom of the range — and adds load
            // the moment it is met, which step 2 has already established.
            guard evaluation.meetsRIRTarget else { break }
            return loadIncreaseDecision(
                input, currentWeight: currentWeight, range: range, resetRange: range,
                setCount: setCount, recommendedSets: setCount, targetRIR: targetRIR,
                evaluation: evaluation, requiredSessions: Constants.linearProgressionSessions,
                recent: recent
            )

        case .repProgression:
            guard evaluation.allHitTop, evaluation.meetsRIRTarget else { break }
            if let expanded = expandedRepWindow(range) {
                return decision(
                    input, action: .addReps, weight: currentWeight, range: expanded, sets: setCount,
                    targetRIR: targetRIR,
                    explanation: Explanation("progression.explain.extendReps", [
                        input.exercise.name,
                        TrainingFormat.count(expanded.lower),
                        TrainingFormat.count(expanded.upper),
                        TrainingFormat.count(evaluation.minReps)
                    ]),
                    successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
                )
            }
            // The rep window has run out of room, so the plan converts to a load increase and the
            // window resets to where the movement started.
            return loadIncreaseDecision(
                input, currentWeight: currentWeight, range: range,
                resetRange: input.exercise.metadata.recommendedRepRange,
                setCount: setCount, recommendedSets: setCount, targetRIR: targetRIR,
                evaluation: evaluation, requiredSessions: Constants.linearProgressionSessions,
                recent: recent
            )

        case .rirBased:
            if let minRIR = evaluation.minRecordedRIR {
                if minRIR >= Double(targetRIR) + 1 {
                    return loadIncreaseDecision(
                        input, currentWeight: currentWeight, range: range, resetRange: range,
                        setCount: setCount, recommendedSets: setCount, targetRIR: targetRIR,
                        evaluation: evaluation,
                        requiredSessions: Constants.linearProgressionSessions, recent: recent
                    )
                }
                if minRIR <= Double(targetRIR) - 2 {
                    // Two or more reps closer to failure than intended. Shave a little now rather
                    // than wait for a missed set — keeping distance from failure is the whole point
                    // of this strategy.
                    if let reduced = easierLoad(
                        from: currentWeight, fraction: Constants.rirOvershootReduction, input: input
                    ) {
                        return decision(
                            input, action: .reduceLoad, weight: reduced, range: range,
                            sets: setCount, targetRIR: targetRIR,
                            explanation: Explanation("progression.explain.reducedLoadRIR", [
                                input.exercise.name,
                                TrainingFormat.weight(currentWeight),
                                TrainingFormat.weight(reduced),
                                TrainingFormat.count(Int(minRIR.rounded())),
                                TrainingFormat.count(targetRIR)
                            ]),
                            successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
                        )
                    }
                }
                break
            }
            // No reps in reserve were recorded, so this strategy has nothing to read. Fall back to
            // the evidence double progression uses.
            guard evaluation.allHitTop else { break }
            return loadIncreaseDecision(
                input, currentWeight: currentWeight, range: range, resetRange: range,
                setCount: setCount, recommendedSets: setCount, targetRIR: targetRIR,
                evaluation: evaluation, requiredSessions: Constants.doubleProgressionSessions,
                recent: recent
            )

        case .volumeProgression:
            guard evaluation.allHitTop, evaluation.meetsRIRTarget else { break }
            let ceiling = setCeiling(for: input.exercise.metadata.mechanic)
            if setCount < ceiling {
                let nextSets = setCount + 1
                return decision(
                    input, action: .addReps, weight: currentWeight, range: range, sets: nextSets,
                    targetRIR: targetRIR,
                    explanation: Explanation("progression.explain.addSet", [
                        input.exercise.name,
                        TrainingFormat.weight(currentWeight),
                        TrainingFormat.count(nextSets)
                    ]),
                    successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
                )
            }
            // At the set ceiling volume stops being the lever, so load takes over and the set count
            // drops back to the base so the next block has somewhere to grow.
            return loadIncreaseDecision(
                input, currentWeight: currentWeight, range: range, resetRange: range,
                setCount: setCount,
                recommendedSets: min(setCount, Constants.volumeProgressionBaseSets),
                targetRIR: targetRIR, evaluation: evaluation,
                requiredSessions: Constants.linearProgressionSessions, recent: recent
            )
        }

        return withinRangeDecision(
            input, currentWeight: currentWeight, range: range, setCount: setCount,
            targetRIR: targetRIR, evaluation: evaluation, recent: recent
        )
    }

    /// Two sessions short of the bottom of the range means the load is wrong, not the day.
    private static func shortfallDecision(
        _ input: ProgressionInput,
        currentWeight: Double,
        range: RepRange,
        setCount: Int,
        targetRIR: Int,
        evaluation: SessionEvaluation,
        recent: ExercisePerformance
    ) -> ProgressionDecision {
        let regressions = input.state.consecutiveRegressions + 1
        if regressions >= Constants.regressionSessionsBeforeCut,
           let reduced = easierLoad(
               from: currentWeight, fraction: Constants.reduceLoadFraction, input: input
           ) {
            return decision(
                input, action: .reduceLoad, weight: reduced, range: range, sets: setCount,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.reducedLoad", [
                    input.exercise.name,
                    TrainingFormat.weight(currentWeight),
                    TrainingFormat.weight(reduced),
                    TrainingFormat.count(range.lower)
                ]),
                successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
            )
        }

        if regressions >= Constants.regressionSessionsBeforeCut {
            // Already at the lightest the implement goes — an empty bar, or no assistance left to
            // add. The honest answer is to build reps here or pick an easier variation.
            return decision(
                input, action: .maintain, weight: currentWeight, range: range, sets: setCount,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.atMinimumLoad", [
                    input.exercise.name,
                    TrainingFormat.weight(currentWeight)
                ]),
                successes: 0, stalls: 0, regressions: regressions, lastPerformedAt: recent.date
            )
        }

        return decision(
            input, action: .maintain, weight: currentWeight, range: range, sets: setCount,
            targetRIR: targetRIR,
            explanation: Explanation("progression.explain.maintain", [
                input.exercise.name,
                TrainingFormat.weight(currentWeight),
                TrainingFormat.count(range.lower),
                TrainingFormat.count(range.upper)
            ]),
            successes: 0, stalls: 0, regressions: regressions, lastPerformedAt: recent.date
        )
    }

    /// Reps landed inside the range: keep the load and aim higher, unless the movement has stopped
    /// moving altogether.
    private static func withinRangeDecision(
        _ input: ProgressionInput,
        currentWeight: Double,
        range: RepRange,
        setCount: Int,
        targetRIR: Int,
        evaluation: SessionEvaluation,
        recent: ExercisePerformance
    ) -> ProgressionDecision {
        let stalls = evaluation.improvedOnPrevious ? 0 : input.state.consecutiveStalls + 1

        if stalls >= Constants.stallSessionsBeforeReset,
           let reduced = easierLoad(
               from: currentWeight, fraction: Constants.reduceLoadFraction, input: input
           ) {
            // Four sessions inside the range with no added reps and no added load is a plateau. A
            // small step back and a second run at the same load is the standard way through one.
            return decision(
                input, action: .reduceLoad, weight: reduced, range: range, sets: setCount,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.reducedLoadStall", [
                    input.exercise.name,
                    TrainingFormat.weight(currentWeight),
                    TrainingFormat.weight(reduced),
                    TrainingFormat.count(stalls)
                ]),
                successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
            )
        }

        return decision(
            input, action: .addReps, weight: currentWeight, range: range, sets: setCount,
            targetRIR: targetRIR,
            explanation: Explanation("progression.explain.addReps", [
                input.exercise.name,
                TrainingFormat.weight(currentWeight),
                TrainingFormat.count(range.upper),
                TrainingFormat.count(evaluation.minReps)
            ]),
            successes: 0, stalls: stalls, regressions: 0, lastPerformedAt: recent.date
        )
    }

    /// Adds load — or banks the session and waits, when the only available jump is too big a step.
    private static func loadIncreaseDecision(
        _ input: ProgressionInput,
        currentWeight: Double,
        range: RepRange,
        resetRange: RepRange,
        setCount: Int,
        recommendedSets: Int?,
        targetRIR: Int,
        evaluation: SessionEvaluation,
        requiredSessions: Int,
        recent: ExercisePerformance
    ) -> ProgressionDecision {
        let successes = input.state.consecutiveSuccesses + 1

        guard let next = harderLoad(from: currentWeight, input: input) else {
            return outgrownDecision(
                input, currentWeight: currentWeight, range: range, setCount: setCount,
                targetRIR: targetRIR, evaluation: evaluation, recent: recent
            )
        }

        let jump = abs(next - currentWeight)
        let cap = currentWeight > Constants.heavyLoadThresholdKg
            ? Constants.heavyIncreaseCap
            : Constants.standardIncreaseCap
        // Going from bodyweight to the first added plate has no meaningful percentage.
        let jumpFraction = currentWeight > Constants.loadEpsilon ? jump / currentWeight : 0
        let oversizedJump = jumpFraction > cap + 1e-9
        // A coarse ladder cannot offer a smaller step, so the app banks one extra good session
        // before taking a jump that exceeds the cap. The user keeps training; the load simply waits
        // until the evidence is stronger.
        let required = oversizedJump ? requiredSessions + 1 : requiredSessions

        guard successes >= required else {
            let explanation = oversizedJump
                ? Explanation("progression.explain.bankBeforeBigJump", [
                    input.exercise.name,
                    TrainingFormat.weight(currentWeight),
                    TrainingFormat.weight(jump),
                    TrainingFormat.percent(jumpFraction)
                ])
                : Explanation("progression.explain.bankSession", [
                    input.exercise.name,
                    TrainingFormat.weight(currentWeight),
                    TrainingFormat.count(successes),
                    TrainingFormat.count(required)
                ])
            return decision(
                input, action: .addReps, weight: currentWeight, range: range, sets: setCount,
                targetRIR: targetRIR, explanation: explanation,
                successes: successes, stalls: 0, regressions: 0, lastPerformedAt: recent.date
            )
        }

        let explanation: Explanation
        if required <= 1 {
            explanation = Explanation("progression.explain.increasedLoadSingle", [
                input.exercise.name,
                TrainingFormat.weight(currentWeight),
                TrainingFormat.weight(next),
                TrainingFormat.count(evaluation.setCount),
                TrainingFormat.count(evaluation.minReps),
                TrainingFormat.count(targetRIR)
            ])
        } else {
            explanation = Explanation("progression.explain.increasedLoad", [
                input.exercise.name,
                TrainingFormat.weight(currentWeight),
                TrainingFormat.weight(next),
                TrainingFormat.count(successes),
                TrainingFormat.count(evaluation.setCount),
                TrainingFormat.count(evaluation.minReps),
                TrainingFormat.count(targetRIR)
            ])
        }

        // The rep target resets to the bottom of the range: the new load is meant to be hard at the
        // bottom, and climbing back to the top is what earns the next increase.
        return decision(
            input, action: .increaseLoad, weight: next, range: resetRange, sets: recommendedSets,
            targetRIR: targetRIR, explanation: explanation,
            successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
        )
    }

    /// Nothing heavier can be selected: grow reps, then sets, then say so plainly.
    private static func outgrownDecision(
        _ input: ProgressionInput,
        currentWeight: Double?,
        range: RepRange,
        setCount: Int,
        targetRIR: Int,
        evaluation: SessionEvaluation,
        recent: ExercisePerformance
    ) -> ProgressionDecision {
        if let expanded = expandedRepWindow(range) {
            return decision(
                input, action: .addReps, weight: currentWeight, range: expanded, sets: setCount,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.extendReps", [
                    input.exercise.name,
                    TrainingFormat.count(expanded.lower),
                    TrainingFormat.count(expanded.upper),
                    TrainingFormat.count(evaluation.minReps)
                ]),
                successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
            )
        }

        let ceiling = setCeiling(for: input.exercise.metadata.mechanic)
        if setCount < ceiling {
            // The rep window deliberately stays where it is. Someone managing thirty press-ups a set
            // does not need to be sent back to ten; another set at the same target is the honest
            // next step, and it is the only one left once load and reps are both capped.
            let nextSets = setCount + 1
            return decision(
                input, action: .addReps, weight: currentWeight, range: range, sets: nextSets,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.addSetUnloaded", [
                    input.exercise.name,
                    TrainingFormat.count(nextSets),
                    TrainingFormat.count(range.lower),
                    TrainingFormat.count(range.upper)
                ]),
                successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
            )
        }

        return decision(
            input, action: .maintain, weight: currentWeight, range: range, sets: setCount,
            targetRIR: targetRIR,
            explanation: Explanation("progression.explain.outgrown", [
                input.exercise.name,
                TrainingFormat.count(setCount),
                TrainingFormat.count(range.upper)
            ]),
            successes: 0, stalls: input.state.consecutiveStalls + 1, regressions: 0,
            lastPerformedAt: recent.date
        )
    }

    // MARK: - Unloaded, rep-based movements

    private static func unloadedRepDecision(
        _ input: ProgressionInput,
        targetRIR: Int
    ) -> ProgressionDecision {
        let range = workingRepRange(input)
        let sessions = usablePerformances(input.history)

        guard let recent = sessions.first else {
            // There is no load to calibrate, so the first session simply runs the recommended
            // prescription and the next decision has something to read.
            return decision(
                input, action: .maintain, weight: nil, range: range, sets: nil, targetRIR: targetRIR,
                explanation: Explanation("progression.explain.startReps", [
                    input.exercise.name,
                    TrainingFormat.count(range.lower),
                    TrainingFormat.count(range.upper)
                ]),
                successes: 0, stalls: 0, regressions: 0, lastPerformedAt: input.state.lastPerformedAt
            )
        }

        let evaluation = evaluate(
            recent, previous: sessions.dropFirst().first, range: range, targetRIR: targetRIR,
            plannedWeightKg: nil, loadability: input.exercise.metadata.loadability
        )
        let setCount = recent.workingSets.count

        if evaluation.allHitTop && evaluation.meetsRIRTarget {
            // No load to add, so the rep window moves up; when it runs out, a set is added instead.
            return outgrownDecision(
                input, currentWeight: nil, range: range, setCount: setCount, targetRIR: targetRIR,
                evaluation: evaluation, recent: recent
            )
        }

        if !evaluation.allMetBottom {
            let regressions = input.state.consecutiveRegressions + 1
            if regressions >= Constants.regressionSessionsBeforeCut,
               let reduced = reducedRepWindow(range) {
                return decision(
                    input, action: .reduceLoad, weight: nil, range: reduced, sets: setCount,
                    targetRIR: targetRIR,
                    explanation: Explanation("progression.explain.reducedReps", [
                        input.exercise.name,
                        TrainingFormat.count(reduced.lower),
                        TrainingFormat.count(reduced.upper),
                        TrainingFormat.count(evaluation.minReps)
                    ]),
                    successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
                )
            }
            return decision(
                input, action: .maintain, weight: nil, range: range, sets: setCount,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.maintainUnloaded", [
                    input.exercise.name,
                    TrainingFormat.count(range.lower),
                    TrainingFormat.count(range.upper)
                ]),
                successes: 0, stalls: 0, regressions: regressions, lastPerformedAt: recent.date
            )
        }

        let stalls = evaluation.improvedOnPrevious ? 0 : input.state.consecutiveStalls + 1
        return decision(
            input, action: .addReps, weight: nil, range: range, sets: setCount,
            targetRIR: targetRIR,
            explanation: Explanation("progression.explain.addRepsUnloaded", [
                input.exercise.name,
                TrainingFormat.count(range.upper),
                TrainingFormat.count(evaluation.minReps)
            ]),
            successes: 0, stalls: stalls, regressions: 0, lastPerformedAt: recent.date
        )
    }

    // MARK: - Timed movements

    /// Progression for anything measured in seconds — holds, timed cardio and loaded carries.
    ///
    /// `ProgressionDecision` has no duration field, so for these movements `recommendedRepRange`
    /// carries **seconds**, not repetitions. Callers must read it through the exercise's tracking
    /// mode; `prescribedSeconds(from:for:)` does that check for them.
    private static func durationDecision(
        _ input: ProgressionInput,
        targetRIR: Int,
        currentWeight: Double?
    ) -> ProgressionDecision {
        let meta = input.exercise.metadata
        let window = durationWindow(input)
        let sessions = usablePerformances(input.history)

        guard let recent = sessions.first else {
            return decision(
                input, action: .maintain, weight: currentWeight, range: window, sets: nil,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.startDuration", [
                    input.exercise.name,
                    TrainingFormat.seconds(window.lower),
                    TrainingFormat.seconds(window.upper)
                ]),
                successes: 0, stalls: 0, regressions: 0, lastPerformedAt: input.state.lastPerformedAt
            )
        }

        let durations = recent.workingSets.compactMap(\.durationSeconds).filter { $0 > 0 }
        let setCount = recent.workingSets.count
        guard let shortest = durations.min() else {
            return decision(
                input, action: .maintain, weight: currentWeight, range: window, sets: setCount,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.noData", [input.exercise.name]),
                successes: input.state.consecutiveSuccesses,
                stalls: input.state.consecutiveStalls,
                regressions: input.state.consecutiveRegressions,
                lastPerformedAt: recent.date
            )
        }

        let ceiling = durationCeiling(for: meta.trackingMode)

        if shortest >= window.upper {
            if let expanded = expandedDurationWindow(window, ceiling: ceiling) {
                return decision(
                    input, action: .addReps, weight: currentWeight, range: expanded, sets: setCount,
                    targetRIR: targetRIR,
                    explanation: Explanation("progression.explain.extendDuration", [
                        input.exercise.name,
                        TrainingFormat.seconds(expanded.lower),
                        TrainingFormat.seconds(expanded.upper),
                        TrainingFormat.seconds(shortest)
                    ]),
                    successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
                )
            }

            let reset = startingDurationWindow(input)
            if let currentWeight, let next = harderLoad(from: currentWeight, input: input) {
                // A loaded carry that has run out of time to add gets heavier instead, and the clock
                // starts again from the bottom of the window.
                return decision(
                    input, action: .increaseLoad, weight: next, range: reset, sets: setCount,
                    targetRIR: targetRIR,
                    explanation: Explanation("progression.explain.increasedLoadDuration", [
                        input.exercise.name,
                        TrainingFormat.weight(currentWeight),
                        TrainingFormat.weight(next),
                        TrainingFormat.seconds(window.upper)
                    ]),
                    successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
                )
            }

            // Timed cardio and loaded carries add another interval; an isometric hold does not.
            // A fourth three-minute plank is not a harder plank, it is a longer session, and the
            // honest advice at that point is a harder variation.
            let setLimit = setCeiling(for: meta.mechanic)
            if meta.trackingMode != .duration, setCount < setLimit {
                let nextSets = setCount + 1
                return decision(
                    input, action: .addReps, weight: currentWeight, range: window, sets: nextSets,
                    targetRIR: targetRIR,
                    explanation: Explanation("progression.explain.addSetDuration", [
                        input.exercise.name,
                        TrainingFormat.count(nextSets),
                        TrainingFormat.seconds(window.lower),
                        TrainingFormat.seconds(window.upper)
                    ]),
                    successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
                )
            }

            return decision(
                input, action: .maintain, weight: currentWeight, range: window, sets: setCount,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.outgrownDuration", [
                    input.exercise.name,
                    TrainingFormat.count(setCount),
                    TrainingFormat.seconds(window.upper)
                ]),
                successes: 0, stalls: input.state.consecutiveStalls + 1, regressions: 0,
                lastPerformedAt: recent.date
            )
        }

        if shortest < window.lower {
            let regressions = input.state.consecutiveRegressions + 1
            if regressions >= Constants.regressionSessionsBeforeCut {
                if let currentWeight, let reduced = easierLoad(
                    from: currentWeight, fraction: Constants.reduceLoadFraction, input: input
                ) {
                    return decision(
                        input, action: .reduceLoad, weight: reduced, range: window, sets: setCount,
                        targetRIR: targetRIR,
                        explanation: Explanation("progression.explain.reducedLoadDuration", [
                            input.exercise.name,
                            TrainingFormat.weight(currentWeight),
                            TrainingFormat.weight(reduced),
                            TrainingFormat.seconds(window.lower)
                        ]),
                        successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
                    )
                }
                if let shortened = reducedDurationWindow(window) {
                    return decision(
                        input, action: .reduceLoad, weight: currentWeight, range: shortened,
                        sets: setCount, targetRIR: targetRIR,
                        explanation: Explanation("progression.explain.reducedDuration", [
                            input.exercise.name,
                            TrainingFormat.seconds(shortened.lower),
                            TrainingFormat.seconds(shortened.upper),
                            TrainingFormat.seconds(shortest)
                        ]),
                        successes: 0, stalls: 0, regressions: 0, lastPerformedAt: recent.date
                    )
                }
            }
            return decision(
                input, action: .maintain, weight: currentWeight, range: window, sets: setCount,
                targetRIR: targetRIR,
                explanation: Explanation("progression.explain.maintainDuration", [
                    input.exercise.name,
                    TrainingFormat.seconds(window.lower),
                    TrainingFormat.seconds(window.upper)
                ]),
                successes: 0, stalls: 0, regressions: regressions, lastPerformedAt: recent.date
            )
        }

        return decision(
            input, action: .addReps, weight: currentWeight, range: window, sets: setCount,
            targetRIR: targetRIR,
            explanation: Explanation("progression.explain.holdDuration", [
                input.exercise.name,
                TrainingFormat.seconds(window.lower),
                TrainingFormat.seconds(window.upper),
                TrainingFormat.seconds(shortest)
            ]),
            successes: 0, stalls: input.state.consecutiveStalls + 1, regressions: 0,
            lastPerformedAt: recent.date
        )
    }

    /// The prescribed hold or work time, in seconds, or `nil` when the decision is about reps.
    ///
    /// `ProgressionDecision.recommendedRepRange` doubles as the seconds window for timed movements
    /// because the contract has no duration field. This is the supported way to read it.
    static func prescribedSeconds(
        from decision: ProgressionDecision,
        for exercise: Exercise
    ) -> RepRange? {
        exercise.metadata.trackingMode.usesDuration ? decision.recommendedRepRange : nil
    }

    // MARK: - Session evaluation

    /// What one session says about the prescription that produced it.
    private struct SessionEvaluation {
        /// Number of sets the judgement was made on, which is not always the number performed —
        /// see `trainedAtPlannedLoad`.
        var setCount: Int
        var minReps: Int
        var maxReps: Int
        var totalReps: Int
        var allHitTop: Bool
        var allMetBottom: Bool
        /// True when no recorded reps-in-reserve fell below the target. Sets with no recorded RIR
        /// are not counted against the user: an unrecorded value is missing evidence, not failure.
        var meetsRIRTarget: Bool
        var minRecordedRIR: Double?
        /// False when *no* set reached the planned load, which makes the session silent about it.
        var trainedAtPlannedLoad: Bool
        /// The lightest load actually logged, for explaining a lighter-than-planned session.
        var easiestLoggedWeightKg: Double
        var improvedOnPrevious: Bool
    }

    /// Judges a session against the prescription that produced it.
    ///
    /// Only sets performed **at or above the planned load** are judged. Back-off sets count as
    /// working sets for volume purposes but are deliberately lighter, and holding a whole session
    /// hostage to them would stall every program that uses them. If no set reached the planned load
    /// the session simply says nothing about it, which `trainedAtPlannedLoad` reports.
    private static func evaluate(
        _ performance: ExercisePerformance,
        previous: ExercisePerformance?,
        range: RepRange,
        targetRIR: Int,
        plannedWeightKg: Double?,
        loadability: Loadability
    ) -> SessionEvaluation {
        let assisted = loadability == .assistedBodyweight
        let allSets = performance.workingSets
        let judged: [PerformedSet]
        if let plannedWeightKg {
            judged = allSets.filter {
                isAtLeastAsHard(logged: $0.weightKg ?? 0, planned: plannedWeightKg, assisted: assisted)
            }
        } else {
            judged = allSets
        }

        let reps = judged.map { $0.reps ?? 0 }
        let totalReps = allSets.reduce(0) { $0 + ($1.reps ?? 0) }

        var meetsRIR = true
        var minRecordedRIR: Double?
        for set in judged {
            guard let rir = set.effectiveRIR else { continue }
            if minRecordedRIR == nil || rir < minRecordedRIR! { minRecordedRIR = rir }
            if rir < Double(targetRIR) { meetsRIR = false }
        }

        let loggedLoads = allSets.map { $0.weightKg ?? 0 }
        let easiestLogged = (assisted ? loggedLoads.max() : loggedLoads.min()) ?? 0

        var improved = true
        if let previous {
            let previousSets = previous.workingSets
            let previousReps = previousSets.reduce(0) { $0 + ($1.reps ?? 0) }
            let previousLoads = previousSets.compactMap(\.weightKg)
            let currentLoads = allSets.compactMap(\.weightKg)
            let loadImproved: Bool
            if assisted {
                // Less assistance is a harder set, so "better" is the smaller number.
                let previousBest = previousLoads.min() ?? Double.greatestFiniteMagnitude
                let currentBest = currentLoads.min() ?? Double.greatestFiniteMagnitude
                loadImproved = currentBest < previousBest - Constants.loadEpsilon
            } else {
                let previousBest = previousLoads.max() ?? 0
                let currentBest = currentLoads.max() ?? 0
                loadImproved = currentBest > previousBest + Constants.loadEpsilon
            }
            improved = totalReps > previousReps || loadImproved
        }

        return SessionEvaluation(
            setCount: judged.count,
            minReps: reps.min() ?? 0,
            maxReps: reps.max() ?? 0,
            totalReps: totalReps,
            allHitTop: !judged.isEmpty && (reps.min() ?? 0) >= range.upper,
            allMetBottom: !judged.isEmpty && (reps.min() ?? 0) >= range.lower,
            meetsRIRTarget: meetsRIR,
            minRecordedRIR: minRecordedRIR,
            trainedAtPlannedLoad: !judged.isEmpty,
            easiestLoggedWeightKg: easiestLogged,
            improvedOnPrevious: improved
        )
    }

    /// Whether a logged load was at least as demanding as the planned one. Assisted movements
    /// compare the other way round, because less assistance is a harder set.
    private static func isAtLeastAsHard(logged: Double, planned: Double, assisted: Bool) -> Bool {
        assisted
            ? logged <= planned + Constants.loadEpsilon
            : logged >= planned - Constants.loadEpsilon
    }

    // MARK: - Load arithmetic

    /// The next selectable load that is genuinely harder than `current`.
    ///
    /// Rounding can snap a nominal increase straight back onto the load the user is already using —
    /// a sparse dumbbell rack does it routinely — so the search steps outwards by whole increments
    /// until the rounded result actually moves, and gives up rather than looping.
    private static func harderLoad(from current: Double, input: ProgressionInput) -> Double? {
        let loadability = input.exercise.metadata.loadability
        let base = LoadRounding.increment(for: loadability, profile: input.increments)
        guard base > 0 else { return nil }
        let step = preferredStep(input, base: base)
        let descending = loadability == .assistedBodyweight

        var probe = 0
        while probe < Constants.maxLoadProbes {
            let delta = step + Double(probe) * base
            let raw = descending ? current - delta : current + delta
            if descending && raw <= 0 {
                // Assistance has run out: unassisted is as hard as this movement gets.
                return current > Constants.loadEpsilon ? 0 : nil
            }
            let candidate = LoadRounding.round(
                kilograms: max(0, raw), loadability: loadability, profile: input.increments
            )
            if descending {
                if candidate < current - Constants.loadEpsilon { return candidate }
            } else {
                if candidate > current + Constants.loadEpsilon { return candidate }
            }
            probe += 1
        }
        return nil
    }

    /// The next selectable load that is easier than `current` by roughly `fraction`.
    private static func easierLoad(
        from current: Double,
        fraction: Double,
        input: ProgressionInput
    ) -> Double? {
        let loadability = input.exercise.metadata.loadability
        let base = LoadRounding.increment(for: loadability, profile: input.increments)
        guard base > 0 else { return nil }
        let ascending = loadability == .assistedBodyweight

        var probe = 0
        var raw = ascending ? current * (1 + fraction) : current * (1 - fraction)
        while probe <= Constants.maxLoadProbes {
            if !ascending && raw <= 0 { return nil }
            let candidate = LoadRounding.round(
                kilograms: max(0, raw), loadability: loadability, profile: input.increments
            )
            if ascending {
                if candidate > current + Constants.loadEpsilon { return candidate }
            } else {
                if candidate < current - Constants.loadEpsilon { return candidate }
            }
            probe += 1
            let delta = Double(probe) * base
            raw = ascending ? current + delta : current - delta
        }
        return nil
    }

    /// The jump the app would like to make, before the percentage caps are applied.
    ///
    /// On a big barbell lift that is 2.5 kg — a pair of 1.25 kg plates, the smallest jump most gyms
    /// can actually make and the customary one. Where a gym stocks micro-plates the raw increment is
    /// smaller, but adding half a kilogram to a squat is noise rather than progress. Isolation work
    /// gets the smallest increment available, because relative to a 10 kg curl a 2.5 kg jump is 25 %.
    private static func preferredStep(_ input: ProgressionInput, base: Double) -> Double {
        let meta = input.exercise.metadata
        if meta.mechanic == .compound,
           meta.loadability == .barbell || meta.loadability == .ezBar {
            return max(base, Constants.barbellCompoundStepKg)
        }
        return base
    }

    // MARK: - Rep and duration windows

    private static func workingRepRange(_ input: ProgressionInput) -> RepRange {
        let stored = input.state.repRange
        guard stored.lower >= 1, stored.upper >= stored.lower else {
            return input.exercise.metadata.recommendedRepRange
        }
        return stored
    }

    /// Moves the rep window up when there is no load to add. Returns `nil` at the ceiling.
    private static func expandedRepWindow(_ range: RepRange) -> RepRange? {
        guard range.upper < Constants.repCeiling else { return nil }
        // The step grows with the window: adding two reps to a set of eight is a real jump, while
        // adding two to a set of twenty-five barely registers.
        let step: Int
        switch range.upper {
        case ..<16: step = 2
        case ..<25: step = 3
        default: step = 5
        }
        let upper = min(Constants.repCeiling, range.upper + step)
        return RepRange(min(range.lower + step, upper), upper)
    }

    /// Moves the rep window down after repeated shortfalls on a movement with no load to shed.
    private static func reducedRepWindow(_ range: RepRange) -> RepRange? {
        let floor = 3
        guard range.lower > floor else { return nil }
        let step = 2
        let lower = max(floor, range.lower - step)
        return RepRange(lower, max(lower + 1, range.upper - step))
    }

    /// The seconds window for a timed movement.
    private static func durationWindow(_ input: ProgressionInput) -> RepRange {
        let stored = input.state.repRange
        // A stored window whose top is under fifteen cannot be seconds; it is the default 8–12 rep
        // range a fresh progression state carries, so the exercise's own set length is used instead.
        if stored.upper >= Constants.minimumRecognisableSeconds { return stored }
        return startingDurationWindow(input)
    }

    private static func startingDurationWindow(_ input: ProgressionInput) -> RepRange {
        let target = max(20, input.exercise.metadata.estimatedSetSeconds)
        let lower = max(
            Constants.minimumHoldSeconds,
            Int((Double(target) * 0.6 / 5).rounded()) * 5
        )
        return RepRange(lower, max(lower + 10, target))
    }

    private static func durationCeiling(for mode: TrackingMode) -> Int {
        mode == .duration ? Constants.holdCeilingSeconds : Constants.timedCeilingSeconds
    }

    private static func expandedDurationWindow(_ window: RepRange, ceiling: Int) -> RepRange? {
        guard window.upper < ceiling else { return nil }
        // Fifteen percent, rounded to whole five-second steps so the target is something a person
        // can actually watch a clock for.
        let step = max(5, Int((Double(window.upper) * 0.15 / 5).rounded()) * 5)
        let upper = min(ceiling, window.upper + step)
        return RepRange(min(window.lower + step, upper), upper)
    }

    private static func reducedDurationWindow(_ window: RepRange) -> RepRange? {
        guard window.lower > Constants.minimumHoldSeconds else { return nil }
        let step = max(5, Int((Double(window.upper) * 0.15 / 5).rounded()) * 5)
        let lower = max(Constants.minimumHoldSeconds, window.lower - step)
        return RepRange(lower, max(lower + 5, window.upper - step))
    }

    private static func setCeiling(for mechanic: Mechanic) -> Int {
        mechanic == .compound ? Constants.compoundSetCeiling : Constants.isolationSetCeiling
    }

    // MARK: - Inputs and state

    /// The working load, when there is one the engine can act on.
    private static func usableWorkingWeight(_ input: ProgressionInput) -> Double? {
        guard let weight = input.state.workingWeightKg, weight.isFinite, weight >= 0 else {
            return nil
        }
        switch input.exercise.metadata.loadability {
        case .weightedBodyweight, .assistedBodyweight:
            // Zero is a real prescription here: bodyweight only, and fully unassisted.
            return weight
        default:
            return weight > 0 ? weight : nil
        }
    }

    /// The reps-in-reserve target, clamped so no prescription puts the user at failure.
    ///
    /// Novices keep at least two reps in hand: their technique degrades before their muscles do, and
    /// their sense of how close to failure they are is the least reliable of any group.
    private static func safeTargetRIR(_ input: ProgressionInput) -> Int {
        let floor = input.experience <= .beginner ? 2 : 1
        return max(floor, min(5, input.targetRIR))
    }

    private static func usablePerformances(
        _ history: ExerciseHistorySnapshot
    ) -> [ExercisePerformance] {
        history.performances.filter { !$0.workingSets.isEmpty }
    }

    /// The best one-rep max the history supports, for loaded rep work only.
    private static func bestOneRepMax(_ input: ProgressionInput) -> Double? {
        guard input.exercise.metadata.trackingMode.usesWeight,
              input.exercise.metadata.trackingMode.usesReps,
              input.exercise.metadata.loadability != .assistedBodyweight else { return nil }
        var best = max(
            input.state.bestEstimatedOneRepMaxKg ?? 0,
            input.history.bestEstimatedOneRepMaxKg ?? 0
        )
        for performance in input.history.performances.prefix(3) {
            if let estimate = OneRepMaxCalculator.bestEstimate(from: performance.sets),
               estimate > best {
                best = estimate
            }
        }
        return best > 0 ? best : nil
    }

    /// Assembles a decision and the state it leaves behind.
    private static func decision(
        _ input: ProgressionInput,
        action: ProgressionAction,
        weight: Double?,
        range: RepRange,
        sets: Int?,
        targetRIR: Int,
        explanation: Explanation,
        successes: Int,
        stalls: Int,
        regressions: Int,
        lastPerformedAt: Date?
    ) -> ProgressionDecision {
        var state = input.state
        state.workingWeightKg = weight
        state.repRange = range
        state.consecutiveSuccesses = max(0, successes)
        state.consecutiveStalls = max(0, stalls)
        state.consecutiveRegressions = max(0, regressions)
        state.needsCalibration = false
        state.strategy = input.strategy
        state.lastPerformedAt = lastPerformedAt ?? input.state.lastPerformedAt
        if let best = bestOneRepMax(input) { state.bestEstimatedOneRepMaxKg = best }

        return ProgressionDecision(
            action: action,
            recommendedWeightKg: weight,
            recommendedRepRange: range,
            recommendedSets: sets,
            targetRIR: targetRIR,
            explanation: explanation,
            updatedState: state,
            requiresCalibration: false
        )
    }
}
