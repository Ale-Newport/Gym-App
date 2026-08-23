import Foundation

// MARK: - Result

/// One record beaten by a single exercise's work in a single session.
struct DetectedRecord: Hashable, Sendable {
    var kind: PersonalRecordKind
    /// Canonical value: kilograms for load, e1RM and set volume; whole reps; seconds; metres.
    var value: Double
    /// For load-based records, the reps performed at that load. Turns "82.5 kg" into "82.5 kg × 5".
    var repsContext: Int?
    /// The value this record supersedes, so the UI can show a delta. `nil` for a first-ever record.
    var previousValue: Double?
    /// Index into `ExercisePerformance.sets` of the set that produced the record.
    var setIndex: Int?
}

// MARK: - Detection

/// Decides which personal records a session's work on one exercise actually beat.
///
/// The hard part of a PR detector is not finding maxima, it is refusing to celebrate things that are
/// not achievements. Three rules do most of that work:
///
/// - **Only completed working sets count.** A warm-up, a drop set, a calibration set or an abandoned
///   set is not evidence of capacity, so `SetKind.countsAsWorkingSet` and `isCompleted` gate
///   everything below.
/// - **A rep record requires the load.** Fifteen reps with 20 kg is not a rep record for someone who
///   has pressed 60 kg for eight; it is a lighter session. `mostReps` therefore only fires at or
///   above the previously recorded heaviest load, which is the only defensible reading of "more
///   reps" once load is free to vary.
/// - **Improvements need a margin.** Floating-point arithmetic, unit conversion round-trips and a
///   re-logged set all produce differences in the tenth decimal place. Anything below 0.1 kg, 0.5 s
///   or 1 m is treated as the same performance, not a new record.
///
/// Whole-workout aggregates — `PersonalRecordKind.sessionVolume` — are deliberately not produced
/// here: this function sees one exercise, so it cannot know a session total.
enum PersonalRecordDetector {

    /// Smallest improvement in kilograms that counts. Covers load, e1RM and set volume.
    private static let massMarginKg = 0.1
    /// Smallest improvement in seconds that counts.
    private static let durationMarginSeconds = 0.5
    /// Smallest improvement in metres that counts.
    private static let distanceMarginMeters = 1.0

    /// Returns every record `performance` beat, ordered by `PersonalRecordKind.allCases` so the
    /// result is stable for identical inputs.
    ///
    /// - Parameter existing: the user's current best per kind for this exercise. A missing entry
    ///   means "never recorded", and the first qualifying set then sets the record.
    static func detect(
        performance: ExercisePerformance,
        exercise: Exercise,
        existing: [PersonalRecordKind: Double]
    ) -> [DetectedRecord] {
        let mode = exercise.metadata.trackingMode
        // Assistance is stored as a positive magnitude, so a *bigger* number is an *easier* set.
        // Recording load, e1RM or tonnage records for an assisted movement would celebrate the wrong
        // direction, so those kinds are skipped; reducing assistance is `ProgressionEngine`'s job.
        let isAssisted = exercise.metadata.loadability == .assistedBodyweight

        let candidates = qualifyingSets(of: performance)
        guard !candidates.isEmpty else { return [] }

        var records: [PersonalRecordKind: DetectedRecord] = [:]

        if mode.usesWeight && !isAssisted {
            if let record = heaviestWeightRecord(candidates, existing: existing) {
                records[.heaviestWeight] = record
            }
        }

        if mode.usesReps {
            if let record = mostRepsRecord(
                candidates, existing: existing,
                loadGated: mode.usesWeight && !isAssisted
            ) {
                records[.mostReps] = record
            }
        }

        if mode.usesWeight && mode.usesReps && !isAssisted {
            if let record = oneRepMaxRecord(candidates, existing: existing) {
                records[.estimatedOneRepMax] = record
            }
        }

        if mode.contributesToTonnage && !isAssisted {
            if let record = setVolumeRecord(candidates, existing: existing) {
                records[.bestSetVolume] = record
            }
        }

        if mode.usesDuration {
            if let record = durationRecord(candidates, existing: existing) {
                records[.longestDuration] = record
            }
        }

        if mode.usesDistance {
            if let record = distanceRecord(candidates, existing: existing) {
                records[.longestDistance] = record
            }
        }

        return PersonalRecordKind.allCases.compactMap { records[$0] }
    }

    // MARK: - Candidate sets

    /// The sets a record may be drawn from, paired with their index in `performance.sets`.
    private static func qualifyingSets(of performance: ExercisePerformance) -> [(index: Int, set: PerformedSet)] {
        performance.sets.enumerated().compactMap { index, set in
            guard set.kind.countsAsWorkingSet, set.isCompleted else { return nil }
            return (index, set)
        }
    }

    // MARK: - Individual kinds

    private static func heaviestWeightRecord(
        _ candidates: [(index: Int, set: PerformedSet)],
        existing: [PersonalRecordKind: Double]
    ) -> DetectedRecord? {
        var best: (index: Int, set: PerformedSet)?
        for candidate in candidates {
            guard let weight = candidate.set.weightKg, weight > 0 else { continue }
            guard let current = best, let currentWeight = current.set.weightKg else {
                best = candidate
                continue
            }
            // Equal load with more reps is the better performance and reads better as context.
            if weight > currentWeight
                || (abs(weight - currentWeight) < massMarginKg
                    && (candidate.set.reps ?? 0) > (current.set.reps ?? 0)) {
                best = candidate
            }
        }

        guard let best, let weight = best.set.weightKg else { return nil }
        let previous = existing[.heaviestWeight]
        guard beats(weight, previous, margin: massMarginKg) else { return nil }
        return DetectedRecord(
            kind: .heaviestWeight,
            value: weight,
            repsContext: best.set.reps,
            previousValue: previous,
            setIndex: best.index
        )
    }

    private static func mostRepsRecord(
        _ candidates: [(index: Int, set: PerformedSet)],
        existing: [PersonalRecordKind: Double],
        loadGated: Bool
    ) -> DetectedRecord? {
        // The bar to clear: on a loaded movement, only sets at or above the heaviest load ever
        // recorded are eligible. Without that gate every deload week would fire a rep record.
        let requiredWeight = loadGated ? existing[.heaviestWeight] : nil

        var best: (index: Int, set: PerformedSet)?
        for candidate in candidates {
            guard let reps = candidate.set.reps, reps > 0 else { continue }
            if let requiredWeight {
                guard let weight = candidate.set.weightKg,
                      weight >= requiredWeight - massMarginKg else { continue }
            }
            if best == nil || reps > (best?.set.reps ?? 0) { best = candidate }
        }

        guard let best, let reps = best.set.reps else { return nil }
        let previous = existing[.mostReps]
        // Reps are whole numbers, so the margin is one whole rep rather than a tolerance.
        guard previous == nil || Double(reps) >= (previous ?? 0) + 1 else { return nil }
        return DetectedRecord(
            kind: .mostReps,
            value: Double(reps),
            repsContext: nil,
            previousValue: previous,
            setIndex: best.index
        )
    }

    private static func oneRepMaxRecord(
        _ candidates: [(index: Int, set: PerformedSet)],
        existing: [PersonalRecordKind: Double]
    ) -> DetectedRecord? {
        var bestValue: Double?
        var bestCandidate: (index: Int, set: PerformedSet)?
        for candidate in candidates {
            guard let weight = candidate.set.weightKg, let reps = candidate.set.reps else { continue }
            // `estimate` refuses anything past `maximumReliableReps`, which is exactly the
            // "only from reliable rep counts" rule — a 20-rep set says little about a single.
            guard let estimate = OneRepMaxCalculator.estimate(weightKg: weight, reps: reps) else { continue }
            if bestValue == nil || estimate > bestValue! {
                bestValue = estimate
                bestCandidate = candidate
            }
        }

        guard let bestValue, let bestCandidate else { return nil }
        let previous = existing[.estimatedOneRepMax]
        guard beats(bestValue, previous, margin: massMarginKg) else { return nil }
        return DetectedRecord(
            kind: .estimatedOneRepMax,
            value: bestValue,
            repsContext: bestCandidate.set.reps,
            previousValue: previous,
            setIndex: bestCandidate.index
        )
    }

    private static func setVolumeRecord(
        _ candidates: [(index: Int, set: PerformedSet)],
        existing: [PersonalRecordKind: Double]
    ) -> DetectedRecord? {
        var best: (index: Int, set: PerformedSet)?
        for candidate in candidates where candidate.set.volumeKg > 0 {
            if best == nil || candidate.set.volumeKg > (best?.set.volumeKg ?? 0) { best = candidate }
        }

        guard let best else { return nil }
        let value = best.set.volumeKg
        let previous = existing[.bestSetVolume]
        guard beats(value, previous, margin: massMarginKg) else { return nil }
        return DetectedRecord(
            kind: .bestSetVolume,
            value: value,
            repsContext: best.set.reps,
            previousValue: previous,
            setIndex: best.index
        )
    }

    private static func durationRecord(
        _ candidates: [(index: Int, set: PerformedSet)],
        existing: [PersonalRecordKind: Double]
    ) -> DetectedRecord? {
        var best: (index: Int, seconds: Int)?
        for candidate in candidates {
            guard let seconds = candidate.set.durationSeconds, seconds > 0 else { continue }
            if best == nil || seconds > (best?.seconds ?? 0) { best = (candidate.index, seconds) }
        }

        guard let best else { return nil }
        let previous = existing[.longestDuration]
        guard beats(Double(best.seconds), previous, margin: durationMarginSeconds) else { return nil }
        return DetectedRecord(
            kind: .longestDuration,
            value: Double(best.seconds),
            repsContext: nil,
            previousValue: previous,
            setIndex: best.index
        )
    }

    private static func distanceRecord(
        _ candidates: [(index: Int, set: PerformedSet)],
        existing: [PersonalRecordKind: Double]
    ) -> DetectedRecord? {
        var best: (index: Int, meters: Double)?
        for candidate in candidates {
            guard let meters = candidate.set.distanceMeters, meters > 0 else { continue }
            if best == nil || meters > (best?.meters ?? 0) { best = (candidate.index, meters) }
        }

        guard let best else { return nil }
        let previous = existing[.longestDistance]
        guard beats(best.meters, previous, margin: distanceMarginMeters) else { return nil }
        return DetectedRecord(
            kind: .longestDistance,
            value: best.meters,
            repsContext: nil,
            previousValue: previous,
            setIndex: best.index
        )
    }

    // MARK: - Margin

    /// True when `value` clears `previous` by at least `margin`. A first-ever value always clears.
    private static func beats(_ value: Double, _ previous: Double?, margin: Double) -> Bool {
        guard value.isFinite, value > 0 else { return false }
        guard let previous else { return true }
        return value >= previous + margin
    }
}
