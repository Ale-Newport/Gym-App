import Foundation

// MARK: - Tuning

/// The constants behind the recovery model, gathered in one place so the numbers can be read,
/// argued with and unit-tested without wading through the algorithm.
///
/// **What this model is, and is not.** It is bookkeeping: it adds up training stimulus that has
/// been applied recently, lets it decay with time, and reports what is left. That estimate exists
/// to inform a *recommendation* about the next session — nothing more. It does not measure muscle
/// damage, hormones, heart-rate variability or nervous-system state, it is not a health metric, and
/// the app must never present it as a medical or physiological measurement.
enum RecoveryTuning {

    /// The residual fraction of a session's fatigue that is still present once the group has had
    /// `MuscleGroup.baselineRecoveryHours` to recover. Defining "recovered" as "90 % dissipated"
    /// is what turns the baseline hours into a half-life:
    ///
    ///     halfLife = baselineRecoveryHours / log2(1 / 0.10) ≈ baselineRecoveryHours / 3.32
    ///
    /// Quads (60 h baseline) therefore get an 18 h half-life: ~40 % of a session's fatigue remains
    /// a day later, ~16 % after two days, ~10 % at the 60 h mark. Biceps (44 h) recover on a 13 h
    /// half-life, calves and abs (34 h) on ~10 h — which is why small muscles tolerate more
    /// frequency, exactly as `MuscleGroup.isSmallMuscle` implies.
    static let recoveredResidualFraction: Double = 0.10

    /// `log2(1 / recoveredResidualFraction)` ≈ 3.32. Derived, never hard-coded.
    static var halfLifeDivisor: Double { log2(1 / recoveredResidualFraction) }

    /// Saturation constant for a single group, in raw fatigue units.
    ///
    /// Raw units are unbounded (they are just sets × cost × proximity), but `RecoverySnapshot`
    /// promises 0…1, so the map is `1 − e^(−raw / K)`: monotonic, never reaches 1, and gives
    /// diminishing returns exactly where reality does. K = 2.75 is calibrated so that one hard
    /// session for a group — about four working sets of a compound at ~0.6 fatigue cost, i.e.
    /// ≈2.5 raw units — reads as ≈0.60 fatigue immediately afterwards.
    ///
    /// That figure is for the per-set catalogue path (`fatigueContribution(of:catalog:)`). Inside
    /// `snapshot`, which has no catalogue, credits are priced at `catalogueTypicalFatigueCost`
    /// instead, so the same amount of work reads a little differently: six recorded set credits at
    /// 1.5 RIR on a session rated "hard" come to 6 × 0.45 × 1.14 × 1.15 ≈ 3.54 raw units → 0.72
    /// fatigue on the day, 0.40 a day later, 0.18 after two.
    static let groupSaturationConstant: Double = 2.75

    /// Saturation constant for whole-body load, in raw fatigue units summed across groups.
    ///
    /// K = 12 is calibrated against two reference cases, both measured through `snapshot`. One hard
    /// lower-body day — six set credits on quads and three on glutes, 1.5 RIR, rated "hard" — sums
    /// to ≈5.31 weighted raw units → 0.36 systemic fatigue, i.e. **0.64 readiness** on the day,
    /// recovering to 0.84 after a day and 0.93 after two. Four of those days on four consecutive
    /// days sum to ≈8.6 → 0.51 fatigue, i.e. **0.49 readiness**. Anything that reads lower than
    /// that is a genuinely heavy block, not a normal week.
    static let systemicSaturationConstant: Double = 12.0

    /// Cost multiplier for a set taken to failure (0 reps in reserve).
    static let proximityAtFailure: Double = 1.32
    /// How much of that multiplier each rep left in reserve buys back.
    ///
    /// Linear, 0.12 per RIR: failure 1.32, 1 RIR 1.20, 2 RIR 1.08, 3 RIR 0.96, 4 RIR 0.84. A set
    /// taken to failure therefore costs ~37 % more than the same set stopped at 3 RIR, which is the
    /// direction (and roughly the magnitude) the fatigue-vs-proximity literature points at without
    /// pretending to a precision nobody has.
    static let proximitySlopePerRIR: Double = 0.12
    /// Floor and ceiling on the proximity multiplier; deep-in-reserve sets still cost something.
    static let proximityFloor: Double = 0.80
    static let proximityCeiling: Double = 1.35

    /// Reps in reserve assumed when neither the set nor the session recorded any effort rating and
    /// no profile default is available. Two is the conventional hypertrophy target and sits in the
    /// middle of the app's own defaults (`ExperienceLevel.defaultRIR` spans 2…4).
    static let assumedTargetRIR: Double = 2.0

    /// Sessions older than this contribute less than 0.1 % of their fatigue even for the slowest
    /// group, so they are dropped rather than iterated.
    static let fatigueLookbackDays: Double = 10
    static let weeklyWindowHours: Double = 168

    /// Check-ins older than three days say nothing useful about today.
    static let checkInWindowHours: Double = 72
    /// Recency weighting for check-ins: yesterday counts half as much as today.
    static let checkInHalfLifeHours: Double = 24

    /// How far a subjective check-in may move systemic readiness, in either direction.
    ///
    /// Deliberately a *modulation around neutral*, not a blend: a middling check-in (all 3s) moves
    /// readiness by zero, a great one adds up to +0.20 and a poor one subtracts up to 0.20. That is
    /// what keeps a missing check-in mathematically identical to "no information" — it contributes
    /// no term at all — instead of quietly meaning "fine" or "not fine".
    static let subjectiveSwing: Double = 0.20

    /// Extra fatigue applied to a group the user explicitly reported as sore, as a fraction.
    static let soreGroupFatigueBoost: Double = 0.35
    /// Floor applied to a reported-sore group, so a group the user says is sore never reads as
    /// completely fresh even when the app has no session record for it (untracked work, a hike, a
    /// first week of training). This is a positive report, not an absence of one.
    static let soreGroupFatigueFloor: Double = 0.30
    /// Severity assumed when a group is flagged sore but the numeric soreness question was skipped.
    static let soreFlagBaselineSeverity: Double = 0.60
    /// Severity floor for an explicitly flagged group, even if the numeric answer was "not sore".
    static let soreFlagMinimumSeverity: Double = 0.40

    /// Fractional set credit a group must receive in one session for that session to count as a
    /// stimulus for `daysSinceStimulus`. Half a set of indirect credit is the smallest amount worth
    /// calling "trained".
    static let hardStimulusSetCredit: Double = 0.5

    /// Fatigue cost assumed per working set when per-exercise metadata is not available — roughly
    /// the middle of `ExerciseMetadataDeriver.fatigueCost`'s range across the catalogue, between an
    /// isolation (~0.20) and a heavy compound (~0.90).
    static let catalogueTypicalFatigueCost: Double = 0.45

    /// Values below this are dropped from the snapshot so the dictionary carries signal, not dust.
    static let minimumStoredFatigue: Double = 0.005

    /// Systemic weighting per group: a fatigued quad taxes the whole body more than a fatigued
    /// forearm, and cardio sits in between.
    static func systemicWeight(for group: MuscleGroup) -> Double {
        if group == .cardio { return 0.8 }
        return group.isSmallMuscle ? 0.5 : 1.0
    }
}

// MARK: - Engine

/// Estimates how much recent training stimulus is still outstanding, per muscle group and for the
/// body as a whole.
///
/// The model is deliberately simple and completely explicable:
///
///     raw(group)   = Σ over sessions  [ Σ over hard sets  cost × credit × proximity ] × effort
///                                     × 0.5 ^ (hoursSince / halfLife(group))
///     fatigue      = 1 − e^(−raw / K)
///     halfLife     = baselineRecoveryHours / log2(10)
///
/// Every term is something the app actually recorded: how many hard sets, how fatiguing the
/// movement is (`ExerciseMetadata.fatigueCost`), how much of it landed on each group
/// (`ExerciseMetadata.volumeContribution`, so a bench press credits triceps and shoulders at their
/// fractional rate), how close to failure the sets were, and how long ago it happened.
///
/// There are two ways to reach `raw`, and which one runs depends on whether the caller holds the
/// catalogue. `fatigueContribution(of:catalog:)` prices every logged set individually, exactly as
/// above. `snapshot` takes no catalogue, so it works from `SessionOutcome.groupSets` — the
/// per-group set credits the logger already recorded, which have `volumeContribution` baked into
/// them — and prices each credit at `RecoveryTuning.catalogueTypicalFatigueCost` using the
/// session's mean reps in reserve:
///
///     raw(group)   = groupSets[group] × 0.45 × proximity(sessionRIR) × effort
///                    × 0.5 ^ (hoursSince / halfLife(group))
///
/// Same shape, one less degree of fidelity: a session of heavy compounds and one of machine
/// isolations cost the same per credit. The decay, saturation and subjective terms are identical.
///
/// It is an estimate that informs a recommendation. It is not a physiological measurement and must
/// never be presented as one.
enum RecoveryEngine {

    // MARK: Snapshot

    /// Builds the current recovery picture.
    ///
    /// - Parameters:
    ///   - sessions: Finished sessions in any order; entries dated after `now` are ignored.
    ///   - wellbeing: Subjective check-ins in any order. An empty array means "no information" and
    ///     leaves systemic readiness resting purely on the objective term.
    ///   - profile: Used only for the reps-in-reserve assumed when a set recorded no effort rating.
    ///   - now: Reference instant. Passed in rather than read, so the result is reproducible.
    static func snapshot(
        sessions: [SessionOutcome],
        wellbeing: [WellbeingSnapshot],
        profile: TrainingProfileSnapshot,
        now: Date = Date()
    ) -> RecoverySnapshot {
        let assumedRIR = Double(profile.defaultTargetRIR)

        // Newest first, with the session id as a tie-break so identical timestamps never reorder.
        let past = sessions
            .filter { $0.date <= now }
            .sorted { ($0.date, $0.sessionID.uuidString) > ($1.date, $1.sessionID.uuidString) }

        var decayedFatigue: [MuscleGroup: Double] = [:]
        var weeklySets: [MuscleGroup: Double] = [:]
        var hoursSinceStimulus: [MuscleGroup: Double] = [:]
        var recentSessionCount = 0

        for outcome in past {
            let hours = max(0, now.timeIntervalSince(outcome.date) / 3600)

            if hours <= RecoveryTuning.weeklyWindowHours {
                // A session with nothing completed is a session that did not happen.
                if outcome.completedSets > 0 { recentSessionCount += 1 }
                for (group, sets) in outcome.groupSets where sets > 0 {
                    weeklySets[group, default: 0] += sets
                }
            }

            for (group, sets) in outcome.groupSets where sets >= RecoveryTuning.hardStimulusSetCredit {
                if let existing = hoursSinceStimulus[group] {
                    hoursSinceStimulus[group] = min(existing, hours)
                } else {
                    hoursSinceStimulus[group] = hours
                }
            }

            guard hours <= RecoveryTuning.fatigueLookbackDays * 24 else { continue }
            // `snapshot` has no catalogue, so it works from the per-group set credits the caller
            // recorded on the outcome. `fatigueContribution(of:catalog:)` is the higher-fidelity
            // path for callers that do hold the catalogue.
            let contribution = rawFatigue(of: outcome, catalog: nil, assumedRIR: assumedRIR)
            for (group, value) in contribution where value > 0 {
                decayedFatigue[group, default: 0] += value * decayMultiplier(hoursElapsed: hours, for: group)
            }
        }

        let sore = soreGroupSeverities(wellbeing, now: now)

        var fatigue: [MuscleGroup: Double] = [:]
        var systemicRaw: Double = 0
        let touchedGroups = Set(decayedFatigue.keys).union(sore.keys)
        for group in touchedGroups.sorted(by: { $0.rawValue < $1.rawValue }) {
            // Reported soreness scales the outstanding stimulus rather than replacing it: the user
            // is telling us this group dissipated more slowly than the model assumed.
            let boost = 1 + RecoveryTuning.soreGroupFatigueBoost * (sore[group] ?? 0)
            let raw = (decayedFatigue[group] ?? 0) * boost
            systemicRaw += raw * RecoveryTuning.systemicWeight(for: group)

            var value = saturate(raw, constant: RecoveryTuning.groupSaturationConstant)
            if let severity = sore[group] {
                value = max(value, RecoveryTuning.soreGroupFatigueFloor * severity)
            }
            if value >= RecoveryTuning.minimumStoredFatigue {
                fatigue[group] = clamp(value)
            }
        }

        var readiness = 1 - saturate(systemicRaw, constant: RecoveryTuning.systemicSaturationConstant)
        if let subjective = wellbeingIndex(wellbeing, now: now) {
            // 0.5 is a neutral check-in and moves nothing; the term is symmetric about it.
            readiness += RecoveryTuning.subjectiveSwing * (2 * subjective - 1)
        }

        var daysSinceStimulus: [MuscleGroup: Int] = [:]
        for (group, hours) in hoursSinceStimulus {
            // Whole elapsed days rather than calendar days: a session 30 hours ago is "1 day ago"
            // regardless of the device's time zone, which keeps the figure reproducible.
            daysSinceStimulus[group] = max(0, Int((hours / 24).rounded(.down)))
        }

        return RecoverySnapshot(
            fatigue: fatigue,
            daysSinceStimulus: daysSinceStimulus,
            weeklySets: weeklySets,
            systemicReadiness: clamp(readiness),
            recentSessionCount: recentSessionCount
        )
    }

    // MARK: Per-session contribution

    /// The raw fatigue one finished session adds to each muscle group, in fatigue units, measured
    /// at the moment the session ended — before any time decay and before the 0…1 saturation map.
    ///
    /// Compound movements spill onto their synergists: the per-set cost is multiplied by
    /// `ExerciseMetadata.volumeContribution`, so a barbell row credits the lats in full and the
    /// biceps at half rate, exactly as weekly volume accounting does.
    static func fatigueContribution(
        of outcome: SessionOutcome,
        catalog: [String: Exercise]
    ) -> [MuscleGroup: Double] {
        rawFatigue(of: outcome, catalog: catalog, assumedRIR: RecoveryTuning.assumedTargetRIR)
    }

    // MARK: Queries

    /// Muscle groups whose outstanding fatigue is at or below `threshold`, least fatigued first.
    ///
    /// The default of 0.35 is the point at which roughly two thirds of a hard session's stimulus
    /// has dissipated — the conventional "ready for another quality session" mark. Cardio and neck
    /// are omitted because they are programmed separately from the weekly volume budget.
    static func readyGroups(_ snapshot: RecoverySnapshot, threshold: Double = 0.35) -> [MuscleGroup] {
        MuscleGroup.volumeTracked
            .filter { snapshot.fatigue(for: $0) <= threshold }
            .sorted { lhs, rhs in
                let left = snapshot.fatigue(for: lhs)
                let right = snapshot.fatigue(for: rhs)
                if left != right { return left < right }
                return lhs.rawValue < rhs.rawValue
            }
    }

    /// A one-line, non-clinical reading of the snapshot for the home screen.
    ///
    /// The wording never claims to measure the user's body: it says what the app can see and what
    /// it suggests. Bands are deliberately wide, because the underlying number is an estimate and
    /// a summary that flips between two states on a 0.01 change reads as noise.
    static func readinessSummary(_ snapshot: RecoverySnapshot) -> Explanation {
        let readiness = clamp(snapshot.systemicReadiness)
        let loadedGroups = snapshot.fatigue.values.filter { $0 >= 0.5 }.count

        switch readiness {
        case 0.85...:
            return Explanation("recovery.summary.fresh")
        case 0.65..<0.85:
            return Explanation("recovery.summary.ready")
        case 0.45..<0.65:
            return Explanation(loadedGroups > 0 ? "recovery.summary.moderate.groups" : "recovery.summary.moderate.systemic")
        default:
            return Explanation(loadedGroups > 0 ? "recovery.summary.low.groups" : "recovery.summary.low.systemic")
        }
    }

    // MARK: Shared model pieces

    /// Fraction of a stimulus still present after `hoursElapsed`, for one group.
    static func decayMultiplier(hoursElapsed: Double, for group: MuscleGroup) -> Double {
        guard hoursElapsed > 0 else { return 1 }
        let halfLife = group.baselineRecoveryHours / RecoveryTuning.halfLifeDivisor
        guard halfLife > 0 else { return 0 }
        return pow(0.5, hoursElapsed / halfLife)
    }

    /// Cost multiplier for a set stopped `repsInReserve` short of failure.
    static func proximityFactor(repsInReserve: Double) -> Double {
        let value = RecoveryTuning.proximityAtFailure
            - RecoveryTuning.proximitySlopePerRIR * max(0, repsInReserve)
        return min(RecoveryTuning.proximityCeiling, max(RecoveryTuning.proximityFloor, value))
    }

    /// A 0…1 reading of the recent subjective check-ins, where 1 is "everything feels good" and
    /// 0.5 is a neutral answer. Returns `nil` when the user answered nothing in the window — that
    /// is genuinely no information and callers must treat it as such.
    ///
    /// Components are weighted by how much they historically say about the next session's quality:
    /// energy and sleep quality lead, soreness and stress follow, motivation counts least because
    /// it moves for reasons that have nothing to do with recovery. Weights are renormalised over
    /// whatever the user actually answered, so skipping a question costs nothing.
    static func wellbeingIndex(_ entries: [WellbeingSnapshot], now: Date) -> Double? {
        let window = entries.filter {
            let hours = now.timeIntervalSince($0.date) / 3600
            return hours >= 0 && hours <= RecoveryTuning.checkInWindowHours
        }
        guard !window.isEmpty else { return nil }

        var weightedSum: Double = 0
        var weightTotal: Double = 0
        for entry in window {
            guard let index = index(of: entry) else { continue }
            let hours = max(0, now.timeIntervalSince(entry.date) / 3600)
            let recency = pow(0.5, hours / RecoveryTuning.checkInHalfLifeHours)
            weightedSum += index * recency
            weightTotal += recency
        }
        guard weightTotal > 0 else { return nil }
        return clamp(weightedSum / weightTotal)
    }

    /// The 0…1 index for a single check-in, or `nil` if every question was skipped.
    static func index(of entry: WellbeingSnapshot) -> Double? {
        var sum: Double = 0
        var weight: Double = 0

        func add(_ value: Double?, _ componentWeight: Double) {
            guard let value else { return }
            sum += value * componentWeight
            weight += componentWeight
        }

        add(entry.energy.map { scale($0) }, 0.28)
        add(entry.sleepQuality.map { scale($0) }, 0.22)
        // 5 h or less reads as 0, 8 h or more as 1 — the usual adult range, not a sleep diagnosis.
        add(entry.sleepHours.map { clamp(($0 - 5) / 3) }, 0.14)
        add(entry.soreness.map { 1 - scale($0) }, 0.16)
        add(entry.stress.map { 1 - scale($0) }, 0.12)
        add(entry.motivation.map { scale($0) }, 0.08)

        guard weight > 0 else { return nil }
        return clamp(sum / weight)
    }

    // MARK: Private

    /// Raw, undecayed fatigue for one session.
    ///
    /// Two paths, in order of fidelity: with a catalogue and logged sets we cost every set by its
    /// exercise's `fatigueCost`, its per-group `volumeContribution` and how close it was taken to
    /// failure. Without one — which is the case inside `snapshot` — we fall back to the per-group
    /// set credits already recorded on the outcome, priced at the catalogue-typical cost.
    private static func rawFatigue(
        of outcome: SessionOutcome,
        catalog: [String: Exercise]?,
        assumedRIR: Double
    ) -> [MuscleGroup: Double] {
        // The user's own verdict on the session scales everything: `fatigueDelta` spans −0.15…0.35,
        // so an "easy" session costs 85 % and an "exhausting" one 135 %.
        let effortMultiplier = 1 + (outcome.effortFeedback?.fatigueDelta ?? 0)
        var result: [MuscleGroup: Double] = [:]

        if let catalog, !outcome.performances.isEmpty {
            let fallbackRIR = outcome.averageRIR ?? assumedRIR
            for performance in outcome.performances {
                guard let exercise = catalog[performance.exerciseID] else { continue }
                let credits = exercise.metadata.volumeContribution
                guard !credits.isEmpty else { continue }
                let cost = exercise.metadata.fatigueCost
                for set in performance.workingSets {
                    let proximity = proximityFactor(repsInReserve: set.effectiveRIR ?? fallbackRIR)
                    for (group, credit) in credits where credit > 0 {
                        result[group, default: 0] += cost * credit * proximity * effortMultiplier
                    }
                }
            }
            if !result.isEmpty { return result }
        }

        let proximity = proximityFactor(repsInReserve: sessionRepsInReserve(of: outcome, assumedRIR: assumedRIR))
        for (group, sets) in outcome.groupSets where sets > 0 {
            result[group] = sets * RecoveryTuning.catalogueTypicalFatigueCost * proximity * effortMultiplier
        }
        return result
    }

    /// Mean reps in reserve across the session's working sets, falling back to the session-level
    /// rating and finally to the assumed target. Absence of a rating is never read as "to failure".
    private static func sessionRepsInReserve(of outcome: SessionOutcome, assumedRIR: Double) -> Double {
        var sum: Double = 0
        var count = 0
        for performance in outcome.performances {
            for set in performance.workingSets {
                if let rir = set.effectiveRIR {
                    sum += rir
                    count += 1
                }
            }
        }
        if count > 0 { return sum / Double(count) }
        return outcome.averageRIR ?? assumedRIR
    }

    /// Combined severity × recency, 0…1, for each group the user reported as sore in the window.
    private static func soreGroupSeverities(
        _ entries: [WellbeingSnapshot],
        now: Date
    ) -> [MuscleGroup: Double] {
        var result: [MuscleGroup: Double] = [:]
        for entry in entries where !entry.soreGroups.isEmpty {
            let hours = now.timeIntervalSince(entry.date) / 3600
            guard hours >= 0, hours <= RecoveryTuning.checkInWindowHours else { continue }
            let recency = pow(0.5, hours / RecoveryTuning.checkInHalfLifeHours)
            // Naming a group is itself the signal, so a flagged group keeps a severity floor even
            // when the numeric soreness question says "barely".
            let severity: Double
            if let soreness = entry.soreness {
                severity = max(RecoveryTuning.soreFlagMinimumSeverity, scale(soreness))
            } else {
                severity = RecoveryTuning.soreFlagBaselineSeverity
            }
            let value = clamp(severity * recency)
            for group in entry.soreGroups {
                result[group] = max(result[group] ?? 0, value)
            }
        }
        return result
    }

    /// Maps raw fatigue units onto 0…1 with diminishing returns and no hard ceiling artefacts.
    private static func saturate(_ raw: Double, constant: Double) -> Double {
        guard raw > 0, constant > 0 else { return 0 }
        return 1 - exp(-raw / constant)
    }

    /// Normalises a 1…5 check-in answer onto 0…1.
    private static func scale(_ answer: Int) -> Double {
        clamp((Double(answer) - 1) / 4)
    }

    private static func clamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
        min(upper, max(lower, value))
    }
}
