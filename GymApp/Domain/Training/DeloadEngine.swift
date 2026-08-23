import Foundation

// MARK: - Tuning

/// Weights, thresholds and gates for deload detection.
///
/// The weights sum to exactly 1.0, which is what makes the "no single signal can trigger a deload"
/// property structural rather than a comment: the largest weight (0.28) sits below the severity
/// threshold (0.40), so even a signal firing at full strength cannot recommend an easy week on its
/// own. Two corroborating signals are additionally required by count.
enum DeloadTuning {

    /// Loads coming down on several exercises is the least ambiguous sign that the current dose has
    /// stopped being productive, so it carries the most weight.
    static let weightPerformanceRegression: Double = 0.28
    /// Outstanding fatigue across several groups — the model's own view of accumulated stimulus.
    static let weightElevatedFatigue: Double = 0.20
    /// Length of the current hard block. A mesocycle of 4–6 weeks before an easy week is the
    /// standard convention across periodisation practice; this signal ramps across exactly that
    /// window rather than forcing a deload on a calendar date.
    static let weightBlockLength: Double = 0.18
    /// The same loads feeling harder — effort inflation, the classic early warning.
    static let weightEffortInflation: Double = 0.16
    /// Sustained poor check-ins. Weighted below the objective signals because it is self-reported
    /// and moves for reasons that have nothing to do with training.
    static let weightSubjective: Double = 0.12
    /// Sets going unfinished. Weighted least because it is the noisiest: life interrupts sessions.
    static let weightMissedSets: Double = 0.06

    /// A signal must reach this strength to count as "fired" and to be named as a reason.
    static let signalFireThreshold: Double = 0.30
    /// Corroboration requirement. One bad session, one bad night or one long block is never enough.
    static let minimumCorroboratingSignals = 2
    /// Weighted severity required to actually recommend. Two strong signals (≈0.85 each on the two
    /// heaviest) reach ≈0.41 and clear it; anything less stays a "worth watching" note.
    static let severityThreshold: Double = 0.40

    /// History gates. A user with almost no training history is never told to deload: they have no
    /// accumulated block to unload, and the advice would be actively wrong.
    static let minimumSessionsForOpinion = 6
    static let historyWindowDays: Double = 28
    static let minimumTrainingSpanDays: Double = 21
    /// Immediately after a deload there is nothing to unload.
    static let minimumWeeksSinceDeload = 2

    /// Regression detection.
    static let regressionWindowDays: Double = 21
    /// Session-to-session estimated-1RM noise from bar speed, rounding and rep judgement is
    /// routinely 1–2 %, so a drop only counts as real past 2.5 %.
    static let regressionNoiseFraction: Double = 0.025
    /// Epley overestimates badly at high rep counts, so sets above this are not used for e1RM.
    static let maximumRepsForOneRepMax = 15
    static let minimumRegressingExercises = 2
    static let minimumEligibleExercises = 3

    /// Effort inflation: same load (within 3 %) but at least 0.75 fewer reps in reserve.
    static let effortInflationLoadTolerance: Double = 0.03
    static let effortInflationRIRDrop: Double = 0.75

    /// Fatigue at or above this counts as "elevated" for a group.
    static let elevatedFatigueThreshold: Double = 0.60

    /// Missed-set rates. Below 8 % is ordinary; 30 % is a session falling apart.
    static let normalMissedFraction: Double = 0.08
    static let severeMissedFraction: Double = 0.30
    static let missedSetsWindow = 4

    /// Check-ins needed before the subjective signal has an opinion at all.
    static let minimumCheckInsForOpinion = 3
    static let subjectiveWindowDays: Double = 7

    /// Prescription. A deload that removes 40–50 % of the volume and ~10 % of the load keeps the
    /// movement pattern and the habit intact while cutting the dose enough to dissipate fatigue —
    /// the conventional prescription, and deliberately not a week off.
    static let baselineVolumeReduction: Double = 0.40
    static let maximumVolumeReduction: Double = 0.50
    static let baselineIntensityReduction: Double = 0.10
    static let maximumIntensityReduction: Double = 0.15
}

// MARK: - Engine

/// Decides whether the user has earned an easy week.
///
/// Six independent signals are scored 0…1, weighted and summed into a severity. A recommendation
/// requires **two or more** signals to fire and the weighted severity to clear 0.40, so a single bad
/// session, a single poor night's sleep or a long block on its own can never produce one. The
/// reasons returned name the signals that actually fired, in order of contribution, because a user
/// who cannot interrogate the recommendation cannot sensibly overrule it.
///
/// Nothing here is a health judgement. The engine reads training data and self-reported ratings and
/// suggests training less for a week; it does not diagnose anything.
enum DeloadEngine {

    /// Assesses the need for a deload.
    ///
    /// - Parameters:
    ///   - sessions: Finished sessions in any order; entries after `now` are ignored.
    ///   - histories: Per-exercise history, keyed by exercise id.
    ///   - recovery: The current `RecoveryEngine` snapshot.
    ///   - wellbeing: Subjective check-ins in any order. Fewer than three in the window means the
    ///     subjective signal simply has no opinion, never a bad one.
    ///   - weeksSinceLastDeload: Completed hard weeks since the last easy week.
    ///   - profile: Used for the experience gate on very new lifters.
    ///   - now: Reference instant, so the assessment is reproducible.
    static func assess(
        sessions: [SessionOutcome],
        histories: [String: ExerciseHistorySnapshot],
        recovery: RecoverySnapshot,
        wellbeing: [WellbeingSnapshot],
        weeksSinceLastDeload: Int,
        profile: TrainingProfileSnapshot,
        now: Date = Date()
    ) -> DeloadAssessment {
        let past = sessions
            .filter { $0.date <= now && $0.completedSets > 0 }
            .sorted { ($0.date, $0.sessionID.uuidString) > ($1.date, $1.sessionID.uuidString) }

        guard hasEnoughHistory(past, profile: profile, weeksSinceLastDeload: weeksSinceLastDeload, now: now) else {
            return .none
        }

        let signals = [
            performanceRegressionSignal(histories: histories, now: now),
            elevatedFatigueSignal(recovery: recovery),
            blockLengthSignal(weeksSinceLastDeload: weeksSinceLastDeload),
            effortInflationSignal(sessions: past, histories: histories, now: now),
            subjectiveSignal(wellbeing: wellbeing, now: now),
            missedSetsSignal(sessions: past)
        ]

        let fired = signals.enumerated().filter { $0.element.hasFired }
        let severity = min(1, signals.reduce(0) { $0 + $1.contribution })
        let shouldDeload = fired.count >= DeloadTuning.minimumCorroboratingSignals
            && severity >= DeloadTuning.severityThreshold

        // Strongest contribution first; the declaration index breaks ties so the order is stable
        // (Swift's sort is not guaranteed stable on its own).
        let ordered = fired.sorted { lhs, rhs in
            if lhs.element.contribution != rhs.element.contribution {
                return lhs.element.contribution > rhs.element.contribution
            }
            return lhs.offset < rhs.offset
        }
        let firedReasons = ordered.map(\.element.explanation)

        guard shouldDeload else {
            guard !firedReasons.isEmpty else { return .none }
            // Something is stirring but not enough to act on. The caller shows this as a note, not
            // as a recommendation, which is why the reductions stay at zero.
            return DeloadAssessment(
                shouldDeload: false,
                severity: severity,
                reasons: [Explanation("deload.summary.watch")] + firedReasons,
                volumeReduction: 0,
                intensityReduction: 0
            )
        }

        // Scale the prescription across the band between "just recommended" and "every signal
        // shouting", so a marginal call gets the gentle end of the range.
        let scaled = clamp((severity - DeloadTuning.severityThreshold) / 0.35)
        let volumeReduction = DeloadTuning.baselineVolumeReduction
            + (DeloadTuning.maximumVolumeReduction - DeloadTuning.baselineVolumeReduction) * scaled
        let intensityReduction = DeloadTuning.baselineIntensityReduction
            + (DeloadTuning.maximumIntensityReduction - DeloadTuning.baselineIntensityReduction) * scaled

        let summary = Explanation(
            "deload.summary.recommended",
            [percentString(volumeReduction), percentString(intensityReduction)]
        )

        return DeloadAssessment(
            shouldDeload: true,
            severity: severity,
            reasons: [summary] + firedReasons,
            volumeReduction: volumeReduction,
            intensityReduction: intensityReduction
        )
    }

    // MARK: - Signals

    /// One weighted piece of evidence.
    private struct Signal {
        var strength: Double
        var weight: Double
        var explanation: Explanation

        var contribution: Double { max(0, min(1, strength)) * weight }
        var hasFired: Bool { strength >= DeloadTuning.signalFireThreshold }
    }

    /// (a) Estimated 1RM trending down across two or more consecutive sessions, on more than one
    /// exercise. A single exercise going backwards is a bad day; several at once is a pattern.
    private static func performanceRegressionSignal(
        histories: [String: ExerciseHistorySnapshot],
        now: Date
    ) -> Signal {
        var eligible = 0
        var regressing = 0

        for key in histories.keys.sorted() {
            guard let history = histories[key] else { continue }
            let recent = recentPerformances(history, windowDays: DeloadTuning.regressionWindowDays, now: now)
            guard recent.count >= 3 else { continue }
            let estimates = recent.prefix(3).compactMap { estimatedOneRepMax(of: $0) }
            guard estimates.count == 3, estimates[2] > 0 else { continue }

            eligible += 1
            let (latest, previous, older) = (estimates[0], estimates[1], estimates[2])
            let stepwiseDown = latest < previous && previous <= older
            let materialDrop = (older - latest) / older >= DeloadTuning.regressionNoiseFraction
            if stepwiseDown && materialDrop { regressing += 1 }
        }

        let strength = fractionSignal(
            hits: regressing,
            eligible: eligible,
            minimumHits: DeloadTuning.minimumRegressingExercises,
            minimumEligible: DeloadTuning.minimumEligibleExercises
        )
        return Signal(
            strength: strength,
            weight: DeloadTuning.weightPerformanceRegression,
            explanation: Explanation("deload.reason.performanceRegression", [String(regressing)])
        )
    }

    /// (b) Outstanding fatigue on several groups at once, or a low whole-body readiness. Either
    /// view can carry the signal; the stronger one wins.
    private static func elevatedFatigueSignal(recovery: RecoverySnapshot) -> Signal {
        let elevated = MuscleGroup.volumeTracked
            .filter { recovery.fatigue(for: $0) >= DeloadTuning.elevatedFatigueThreshold }
            .count
        // One loaded group after a hard day is normal; five at once is a block catching up.
        let countTerm = clamp(Double(elevated - 1) / 4)
        let readinessTerm = clamp((0.55 - recovery.systemicReadiness) / 0.35)
        let strength = max(countTerm, readinessTerm)

        let explanation = elevated >= 2
            ? Explanation("deload.reason.elevatedFatigue", [String(elevated)])
            : Explanation("deload.reason.lowReadiness")
        return Signal(strength: strength, weight: DeloadTuning.weightElevatedFatigue, explanation: explanation)
    }

    /// (d) Hard weeks accumulated since the last easy one. Ramps from week 3 to week 7 so that a
    /// 4–6 week mesocycle lands in the middle of the range; it never triggers a deload on its own.
    private static func blockLengthSignal(weeksSinceLastDeload: Int) -> Signal {
        let strength = clamp(Double(weeksSinceLastDeload - 3) / 4)
        return Signal(
            strength: strength,
            weight: DeloadTuning.weightBlockLength,
            explanation: Explanation("deload.reason.blockLength", [String(max(0, weeksSinceLastDeload))])
        )
    }

    /// (c) Effort inflation: the same loads costing more effort than they did.
    ///
    /// Measured per exercise where possible — top-set load within 3 % of the recent average while
    /// reps in reserve fall by at least 0.75 — and from the session-level average as a fallback for
    /// users who rate sessions but not individual sets.
    private static func effortInflationSignal(
        sessions: [SessionOutcome],
        histories: [String: ExerciseHistorySnapshot],
        now: Date
    ) -> Signal {
        var eligible = 0
        var inflating = 0

        for key in histories.keys.sorted() {
            guard let history = histories[key] else { continue }
            let recent = recentPerformances(history, windowDays: DeloadTuning.regressionWindowDays, now: now)
            guard recent.count >= 3 else { continue }

            guard let newestLoad = topWorkingLoad(of: recent[0]),
                  let newestRIR = meanRepsInReserve(of: recent[0]) else { continue }

            var priorLoads: [Double] = []
            var priorRIRs: [Double] = []
            for performance in recent[1...2] {
                if let load = topWorkingLoad(of: performance), let rir = meanRepsInReserve(of: performance) {
                    priorLoads.append(load)
                    priorRIRs.append(rir)
                }
            }
            guard !priorLoads.isEmpty else { continue }

            let priorLoad = priorLoads.reduce(0, +) / Double(priorLoads.count)
            let priorRIR = priorRIRs.reduce(0, +) / Double(priorRIRs.count)
            guard priorLoad > 0 else { continue }

            eligible += 1
            let sameLoad = abs(newestLoad - priorLoad) / priorLoad <= DeloadTuning.effortInflationLoadTolerance
            if sameLoad && (priorRIR - newestRIR) >= DeloadTuning.effortInflationRIRDrop { inflating += 1 }
        }

        let exerciseStrength = fractionSignal(
            hits: inflating,
            eligible: eligible,
            minimumHits: 2,
            minimumEligible: 2
        )

        // Session-level fallback: mean rated reps in reserve over the last two sessions against the
        // two before them. Half a point of drift is noise; a point and a half is not.
        var sessionStrength: Double = 0
        let rated = sessions.compactMap(\.averageRIR)
        if rated.count >= 4 {
            let recentMean = (rated[0] + rated[1]) / 2
            let priorMean = (rated[2] + rated[3]) / 2
            sessionStrength = clamp((priorMean - recentMean - 0.5) / 1.0)
        }

        if exerciseStrength >= sessionStrength {
            return Signal(
                strength: exerciseStrength,
                weight: DeloadTuning.weightEffortInflation,
                explanation: Explanation("deload.reason.effortInflation", [String(inflating)])
            )
        }
        return Signal(
            strength: sessionStrength,
            weight: DeloadTuning.weightEffortInflation,
            explanation: Explanation("deload.reason.effortInflationSession")
        )
    }

    /// (e) Sustained poor check-ins. Needs three days of answers before it has any opinion, because
    /// one rough night says nothing about a training block.
    private static func subjectiveSignal(wellbeing: [WellbeingSnapshot], now: Date) -> Signal {
        let window = wellbeing.filter {
            let days = now.timeIntervalSince($0.date) / 86400
            return days >= 0 && days <= DeloadTuning.subjectiveWindowDays
        }
        let indices = window.compactMap { RecoveryEngine.index(of: $0) }
        guard indices.count >= DeloadTuning.minimumCheckInsForOpinion else {
            return Signal(strength: 0, weight: DeloadTuning.weightSubjective,
                          explanation: Explanation("deload.reason.subjective"))
        }
        let mean = indices.reduce(0, +) / Double(indices.count)
        // Neutral (0.5) contributes nothing; a sustained 0.2 average saturates the signal.
        let strength = clamp((0.5 - mean) / 0.3)
        return Signal(
            strength: strength,
            weight: DeloadTuning.weightSubjective,
            explanation: Explanation("deload.reason.subjective")
        )
    }

    /// (f) A rising rate of unfinished sets. Both the level and the trend count; the higher wins.
    private static func missedSetsSignal(sessions: [SessionOutcome]) -> Signal {
        let planned = sessions.filter { $0.plannedSets > 0 }
        guard planned.count >= 3 else {
            return Signal(strength: 0, weight: DeloadTuning.weightMissedSets,
                          explanation: Explanation("deload.reason.missedSets", ["0"]))
        }

        let recent = Array(planned.prefix(DeloadTuning.missedSetsWindow))
        let recentMissed = 1 - recent.reduce(0) { $0 + $1.completionRate } / Double(recent.count)

        var rise: Double = 0
        let prior = Array(planned.dropFirst(recent.count).prefix(DeloadTuning.missedSetsWindow))
        if prior.count >= 2 {
            let priorMissed = 1 - prior.reduce(0) { $0 + $1.completionRate } / Double(prior.count)
            // Five points of drift is ordinary variation; twenty is a trend.
            rise = clamp(((recentMissed - priorMissed) - 0.05) / 0.15)
        }
        let level = clamp(
            (recentMissed - DeloadTuning.normalMissedFraction)
                / (DeloadTuning.severeMissedFraction - DeloadTuning.normalMissedFraction)
        )

        return Signal(
            strength: max(level, rise),
            weight: DeloadTuning.weightMissedSets,
            explanation: Explanation("deload.reason.missedSets", [percentString(max(0, recentMissed))])
        )
    }

    // MARK: - Gates

    /// A deload is a way of shedding accumulated fatigue. Somebody who has not accumulated any yet
    /// has nothing to shed, so the engine keeps quiet: at least six sessions in the last four
    /// weeks, at least three weeks of training on record, and not straight after the last easy week.
    private static func hasEnoughHistory(
        _ sessions: [SessionOutcome],
        profile: TrainingProfileSnapshot,
        weeksSinceLastDeload: Int,
        now: Date
    ) -> Bool {
        guard weeksSinceLastDeload >= DeloadTuning.minimumWeeksSinceDeload else { return false }
        guard profile.experience != .never else { return false }

        let window = sessions.filter {
            now.timeIntervalSince($0.date) / 86400 <= DeloadTuning.historyWindowDays
        }
        guard window.count >= DeloadTuning.minimumSessionsForOpinion else { return false }

        guard let newest = sessions.first?.date, let oldest = sessions.last?.date else { return false }
        return newest.timeIntervalSince(oldest) / 86400 >= DeloadTuning.minimumTrainingSpanDays
    }

    // MARK: - Helpers

    /// Newest-first performances inside a window, ignoring anything dated in the future.
    private static func recentPerformances(
        _ history: ExerciseHistorySnapshot,
        windowDays: Double,
        now: Date
    ) -> [ExercisePerformance] {
        history.performances
            .filter {
                let days = now.timeIntervalSince($0.date) / 86400
                return days >= 0 && days <= windowDays
            }
            .sorted { $0.date > $1.date }
    }

    /// Best estimated one-rep max across a session's working sets, using Epley
    /// (`1RM ≈ w × (1 + reps / 30)`) — the conventional choice for the 1–10 rep range, and capped
    /// at 15 reps because every rep-max formula falls apart above that.
    private static func estimatedOneRepMax(of performance: ExercisePerformance) -> Double? {
        var best: Double?
        for set in performance.workingSets {
            guard let weight = set.weightKg, weight > 0,
                  let reps = set.reps, reps > 0, reps <= DeloadTuning.maximumRepsForOneRepMax
            else { continue }
            let estimate = weight * (1 + Double(reps) / 30)
            if estimate > (best ?? 0) { best = estimate }
        }
        return best
    }

    /// Heaviest working-set load in a session, used as the "same load" reference point.
    private static func topWorkingLoad(of performance: ExercisePerformance) -> Double? {
        let loads = performance.workingSets.compactMap { $0.weightKg }.filter { $0 > 0 }
        return loads.max()
    }

    /// Mean rated reps in reserve across a session's working sets, or `nil` if nothing was rated.
    private static func meanRepsInReserve(of performance: ExercisePerformance) -> Double? {
        let values = performance.workingSets.compactMap(\.effectiveRIR)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Turns "how many of the eligible items are misbehaving" into a 0…1 strength.
    ///
    /// Below `minimumHits` the signal is silent no matter the fraction — this is the rule that stops
    /// one exercise, or one session, from speaking for the whole block. Above it, a fifth of the
    /// eligible items misbehaving reads as 0, three fifths as full strength.
    private static func fractionSignal(
        hits: Int,
        eligible: Int,
        minimumHits: Int,
        minimumEligible: Int
    ) -> Double {
        guard eligible >= minimumEligible, hits >= minimumHits else { return 0 }
        let fraction = Double(hits) / Double(eligible)
        return clamp((fraction - 0.2) / 0.4)
    }

    /// Whole-number percentage as a string. `Explanation.arguments` is `[String]`, so every
    /// placeholder in the catalogue is `%@` and numbers are formatted here, without a decimal
    /// separator so the result is locale-independent.
    private static func percentString(_ fraction: Double) -> String {
        String(Int((clamp(fraction) * 100).rounded()))
    }

    private static func clamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
        min(upper, max(lower, value))
    }
}
