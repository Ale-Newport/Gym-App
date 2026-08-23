import Foundation

// MARK: - One-repetition maximum

/// Estimates a one-repetition maximum (1RM) from a submaximal set, and the inverse — the load that
/// corresponds to a given rep target.
///
/// The app never asks a user to attempt a true single: a maximal attempt is the least safe thing a
/// training app can prescribe, and it is not needed. Every strength figure the app shows is an
/// *estimate* derived from work the user already did.
///
/// Three published formulas are implemented because they disagree, and the disagreement is the
/// useful part:
///
/// - **Epley (1985)** is linear in reps, so it drifts *high* as reps climb.
/// - **Brzycki (1993)** is hyperbolic, so it drifts *low* as reps climb.
/// - **Lombardi (1989)** is a power law and is the flattest of the three.
///
/// Because Epley and Brzycki err in opposite directions, their arithmetic mean is more stable than
/// either alone, which is why `.average` is the default everywhere in the app.
enum OneRepMaxCalculator {

    /// The prediction equations the app supports.
    enum Formula: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
        /// `1RM = w × (1 + reps / 30)`.
        case epley
        /// `1RM = w × 36 / (37 − reps)`.
        case brzycki
        /// `1RM = w × reps^0.10`.
        case lombardi
        /// The mean of Epley and Brzycki. The app default.
        case average

        var id: String { rawValue }
        var localizationKey: String { "oneRepMax.formula.\(rawValue)" }
    }

    // MARK: - Reliability bounds

    /// The highest rep count the app will estimate a 1RM from.
    ///
    /// Every prediction equation is fitted on sets of roughly 1–10 reps. Past about 10–12 the
    /// residual error grows steeply and becomes dominated by the lifter's rep endurance rather than
    /// their maximal strength — two people with the same true 1RM can differ by 5 reps at 70 % of
    /// it. Refusing to answer is better than answering badly, so `estimate` returns `nil` above this
    /// bound instead of producing a number the rest of the app would then treat as fact.
    static var maximumReliableReps: Int { 12 }

    /// The highest rep target `weight(forReps:oneRepMaxKg:)` will prescribe a load for.
    ///
    /// Prescribing *downwards* is a much easier problem than estimating upwards: an error at 20 reps
    /// costs a set that is slightly too light, not a failed rep under a loaded bar. The app programs
    /// up to 25-rep endurance ranges (`RepRange.endurance`), so the inverse has to cover them; 30
    /// is a round bound comfortably past anything the programming engine produces.
    static var maximumPrescribableReps: Int { 30 }

    /// The rep count at which Brzycki's denominator reaches zero. Guarded everywhere it is used.
    private static let brzyckiSingularity = 37

    // MARK: - Estimation

    /// Estimates a one-repetition maximum from a single completed set.
    ///
    /// Returns `nil` — rather than a guess — when the set cannot support an estimate: a non-positive
    /// load, fewer than one rep, or more reps than `maximumReliableReps`.
    static func estimate(weightKg: Double, reps: Int, formula: Formula = .average) -> Double? {
        guard weightKg.isFinite, weightKg > 0 else { return nil }
        guard reps >= 1 else { return nil }
        // A single *is* the maximum; running it through a formula would inflate it by rounding noise.
        guard reps > 1 else { return weightKg }
        guard reps <= maximumReliableReps else { return nil }

        switch formula {
        case .epley:
            return epley(weightKg: weightKg, reps: reps)
        case .brzycki:
            return brzycki(weightKg: weightKg, reps: reps)
        case .lombardi:
            return lombardi(weightKg: weightKg, reps: reps)
        case .average:
            guard let low = brzycki(weightKg: weightKg, reps: reps) else {
                return epley(weightKg: weightKg, reps: reps)
            }
            let high = epley(weightKg: weightKg, reps: reps)
            return (low + high) / 2
        }
    }

    /// The load that should allow exactly `reps` repetitions, given a one-repetition maximum.
    ///
    /// This is the inverse of `estimate` and is what turns a strength estimate into a prescription.
    /// Above `maximumReliableReps` the Epley inverse is used regardless of `formula`: it degrades
    /// gracefully (60 % of 1RM at 20 reps, 50 % at 30), matching the conventional NSCA
    /// percentage-of-1RM table to within about three points, whereas the Brzycki inverse collapses
    /// towards zero as reps approach its singularity and would prescribe absurdly light loads.
    static func weight(forReps reps: Int, oneRepMaxKg: Double, formula: Formula = .average) -> Double? {
        guard oneRepMaxKg.isFinite, oneRepMaxKg > 0 else { return nil }
        guard reps >= 1, reps <= maximumPrescribableReps else { return nil }
        guard reps > 1 else { return oneRepMaxKg }

        guard reps <= maximumReliableReps else {
            return oneRepMaxKg * epleyFraction(reps: reps)
        }

        switch formula {
        case .epley:
            return oneRepMaxKg * epleyFraction(reps: reps)
        case .brzycki:
            return oneRepMaxKg * brzyckiFraction(reps: reps)
        case .lombardi:
            return oneRepMaxKg * lombardiFraction(reps: reps)
        case .average:
            // The mean of the two inverses is not the exact inverse of the mean of the two forward
            // equations, but across 1–12 reps the two differ by well under half a percent — far
            // below the resolution of any plate, dumbbell or stack the user can actually select.
            return oneRepMaxKg * (epleyFraction(reps: reps) + brzyckiFraction(reps: reps)) / 2
        }
    }

    /// The best 1RM estimate supported by a group of sets — typically one exercise in one session.
    ///
    /// Warm-up, drop and calibration sets are excluded (`SetKind.countsAsWorkingSet` owns that
    /// rule), as are sets the user did not finish: an abandoned set says nothing about capacity.
    /// Ties keep the earliest qualifying set so the result is stable across identical inputs.
    static func bestEstimate(from sets: [PerformedSet], formula: Formula = .average) -> Double? {
        var best: Double?
        for set in sets where set.kind.countsAsWorkingSet && set.isCompleted {
            guard let weightKg = set.weightKg, let reps = set.reps else { continue }
            guard let estimate = estimate(weightKg: weightKg, reps: reps, formula: formula) else { continue }
            if best == nil || estimate > best! { best = estimate }
        }
        return best
    }

    // MARK: - The equations

    private static func epley(weightKg: Double, reps: Int) -> Double {
        weightKg * (1 + Double(reps) / 30)
    }

    private static func brzycki(weightKg: Double, reps: Int) -> Double? {
        // At 37 reps the denominator is zero and beyond it the sign flips, which would silently
        // return a *negative* one-rep max. The rep bounds above already prevent it; this guard
        // exists so the helper is safe wherever it is reused.
        guard reps < brzyckiSingularity else { return nil }
        return weightKg * 36 / Double(brzyckiSingularity - reps)
    }

    private static func lombardi(weightKg: Double, reps: Int) -> Double {
        weightKg * pow(Double(reps), 0.10)
    }

    /// Fraction of 1RM that Epley predicts for `reps`.
    private static func epleyFraction(reps: Int) -> Double {
        1 / (1 + Double(reps) / 30)
    }

    /// Fraction of 1RM that Brzycki predicts for `reps`, clamped away from its singularity.
    private static func brzyckiFraction(reps: Int) -> Double {
        let safeReps = min(reps, brzyckiSingularity - 1)
        return Double(brzyckiSingularity - safeReps) / 36
    }

    /// Fraction of 1RM that Lombardi predicts for `reps`.
    private static func lombardiFraction(reps: Int) -> Double {
        1 / pow(Double(reps), 0.10)
    }
}

// MARK: - Explanation formatting

/// Formats quantities for `Explanation` arguments across the progression engines.
///
/// Two constraints shape this type. First, `Explanation` stores *already-formatted* strings, and the
/// engines run with no access to the user's unit preference, so every quantity an explanation quotes
/// is rendered in the app's canonical units — kilograms, seconds, metres. Second, engines must be
/// deterministic: `NumberFormatter` reads `Locale.current`, which is ambient process state, and an
/// engine whose output changes with the device region cannot be pinned down in a test.
/// `String(format:)` without an explicit locale always uses the POSIX decimal point, so the same
/// inputs always produce the same string.
enum TrainingFormat {

    /// A load, in canonical kilograms. Whole values lose the decimal: "60 kg", not "60.0 kg".
    static func weight(_ kilograms: Double) -> String {
        guard kilograms.isFinite else { return "0 kg" }
        // Loads are only ever selectable in steps of 0.5 kg or coarser, so one decimal is exact.
        let rounded = (kilograms * 10).rounded() / 10
        let text = abs(rounded.rounded() - rounded) < 0.05
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
        return "\(text) kg"
    }

    /// A bare count — sets, reps, sessions.
    static func count(_ value: Int) -> String { String(value) }

    /// A duration in whole seconds.
    static func seconds(_ value: Int) -> String { String(value) }

    /// A percentage, rounded to a whole number and written without the sign.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0" }
        return String(format: "%.0f", (abs(fraction) * 100).rounded())
    }
}
