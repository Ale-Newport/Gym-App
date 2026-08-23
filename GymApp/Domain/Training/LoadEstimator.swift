import Foundation

// MARK: - Results

/// A first working load for an exercise the user has never performed, with an honest confidence.
struct LoadEstimate: Hashable, Sendable {
    /// The recommended working load, already rounded onto weights the user can actually select.
    /// For `weightedBodyweight` this is the load to *add*; for `assistedBodyweight` it is the
    /// assistance to *remove*, never the total system mass.
    var weightKg: Double
    /// 0…1. How much the app trusts this number. Low confidence is not hidden from the user — it
    /// is what turns the first set into a calibration set.
    var confidence: Double
    /// True when the user should rate the first set so the load can be corrected immediately.
    var requiresCalibration: Bool
    var explanation: Explanation
}

/// One ramp set performed before the first working set.
struct WarmupSet: Hashable, Sendable {
    var weightKg: Double
    var reps: Int
    var restSeconds: Int
}

// MARK: - Load estimation

/// Works out where to start on a movement the user has no history for, and builds the warm-up ramp
/// that leads into it.
///
/// The guiding rule is that the app never invents a number. Every estimate is traceable to
/// something the user told us or something they did, and when nothing is traceable the app says so
/// by asking for a calibration set rather than guessing confidently. Sources are tried in
/// descending order of trustworthiness:
///
/// 1. **A strength seed for this exact exercise.** The user told us what they lift. Nothing beats it.
/// 2. **A related exercise they have already trained** — same movement pattern and same target
///    muscle — converted through a documented transfer coefficient.
/// 3. **A body-weight ratio table** by experience level, calibrated on published novice strength
///    standards and deliberately trimmed towards the light end of them.
/// 4. **The lightest sensible setting on the implement**, flagged for calibration.
///
/// Everything errs light on purpose. An under-estimate costs one extra warm-up set; an over-estimate
/// costs a failed rep under a loaded bar.
enum LoadEstimator {

    // MARK: Tuning constants

    private enum Constants {
        /// Applied to the load derived from a seed or from a related lift. Real data, small haircut.
        static let measuredSafetyFactor = 0.95
        /// Applied to the load derived from the population ratio table. Population data, bigger haircut.
        static let populationSafetyFactor = 0.90
        /// Below this confidence the first set becomes a calibration set. Set so that a number
        /// carried across from a *different* implement always gets rated — the transfer coefficients
        /// are population averages and individuals scatter widely around them — while the user's own
        /// numbers on a well-trained movement, or on this movement, are trusted straight away.
        static let calibrationThreshold = 0.60
        /// No estimate may exceed this multiple of body mass on the barbell-equivalent scale. A
        /// 4 × body-weight deadlift is a world record, so anything past it is corrupt input.
        static let sanityCeilingBodyWeightMultiple = 4.0
        /// Body-weight values outside this range are typos, not people.
        static let minimumBodyWeightKg = 30.0
        static let maximumBodyWeightKg = 250.0
        /// How many recent sessions of a related lift are scanned for a usable estimate.
        static let relatedSessionsScanned = 3
        /// An isolation movement below this working load is its own warm-up.
        static let warmupSkipThresholdKg = 20.0
    }

    // MARK: - Starting load

    /// Estimates the first working load for `exercise`.
    ///
    /// Returns `nil` when the movement carries no selectable load at all — a plank, a band pull-apart
    /// or a treadmill run. Those progress in reps, time or sets, which is `ProgressionEngine`'s job,
    /// and returning a fabricated kilogram figure for them would be worse than returning nothing.
    ///
    /// - Parameters:
    ///   - relatedHistories: histories keyed by exercise id. May contain unrelated movements; the
    ///     estimator filters them itself.
    ///   - catalog: the exercise catalogue, needed to interpret the keys of `relatedHistories`.
    ///   - targetReps: the rep target the returned load should suit.
    ///   - strengthSeeds: self-reported strength markers, from `UserProfile.strengthSeeds`.
    ///     `TrainingProfileSnapshot` does not carry them, so they arrive separately.
    static func estimateStartingLoad(
        exercise: Exercise,
        profile: TrainingProfileSnapshot,
        relatedHistories: [String: ExerciseHistorySnapshot],
        catalog: [Exercise],
        increments: EquipmentIncrements,
        targetReps: Int,
        strengthSeeds: [StrengthSeed] = []
    ) -> LoadEstimate? {
        let loadability = exercise.metadata.loadability
        guard loadability.carriesExternalLoad else { return nil }
        // A medicine ball or a sledgehammer weighs what it weighs; there is no ladder to pick from.
        guard loadability != .fixedImplement else { return nil }

        let reps = max(1, min(targetReps, OneRepMaxCalculator.maximumPrescribableReps))
        let bodyWeightKg = min(
            max(profile.bodyWeightKg, Constants.minimumBodyWeightKg),
            Constants.maximumBodyWeightKg
        )

        if let seeded = estimateFromSeed(
            exercise: exercise, seeds: strengthSeeds, bodyWeightKg: bodyWeightKg,
            increments: increments, reps: reps
        ) {
            return seeded
        }

        if let related = estimateFromRelatedLift(
            exercise: exercise, relatedHistories: relatedHistories, catalog: catalog,
            bodyWeightKg: bodyWeightKg, increments: increments, reps: reps
        ) {
            return related
        }

        if let ratio = estimateFromBodyWeightRatio(
            exercise: exercise, profile: profile, bodyWeightKg: bodyWeightKg,
            increments: increments, reps: reps
        ) {
            return ratio
        }

        return minimumLoadEstimate(exercise: exercise, increments: increments)
    }

    // MARK: Tier 1 — an explicit seed

    private static func estimateFromSeed(
        exercise: Exercise,
        seeds: [StrengthSeed],
        bodyWeightKg: Double,
        increments: EquipmentIncrements,
        reps: Int
    ) -> LoadEstimate? {
        // Sorted so a duplicated id resolves the same way on every run.
        guard let seed = seeds
            .filter({ $0.exerciseID == exercise.id })
            .sorted(by: { $0.weightKg > $1.weightKg })
            .first
        else { return nil }
        guard seed.reps >= 1, seed.weightKg.isFinite else { return nil }

        // Convert to the shared scale first: for a weighted or assisted movement the number the user
        // reported is added load or assistance, and a rep-max equation applied to that alone is
        // meaningless — the body is most of the resistance.
        let seedSystemKg = barbellEquivalent(
            ofStored: seed.weightKg, exercise: exercise, bodyWeightKg: bodyWeightKg
        )
        guard let systemOneRepMax = OneRepMaxCalculator.estimate(
            weightKg: seedSystemKg, reps: seed.reps
        ) else { return nil }

        guard let stored = workingLoad(
            systemOneRepMaxKg: systemOneRepMax, exercise: exercise, bodyWeightKg: bodyWeightKg,
            reps: reps, safetyFactor: Constants.measuredSafetyFactor, increments: increments
        ) else { return nil }

        let confidence = 0.80
        return LoadEstimate(
            weightKg: stored,
            confidence: confidence,
            requiresCalibration: confidence < Constants.calibrationThreshold,
            explanation: Explanation("loadEstimate.explain.fromSeed", [
                exercise.name,
                TrainingFormat.weight(stored),
                TrainingFormat.count(reps),
                TrainingFormat.weight(seed.weightKg),
                TrainingFormat.count(seed.reps)
            ])
        )
    }

    // MARK: Tier 2 — a related lift

    private static func estimateFromRelatedLift(
        exercise: Exercise,
        relatedHistories: [String: ExerciseHistorySnapshot],
        catalog: [Exercise],
        bodyWeightKg: Double,
        increments: EquipmentIncrements,
        reps: Int
    ) -> LoadEstimate? {
        guard !relatedHistories.isEmpty, !catalog.isEmpty else { return nil }
        var catalogByID: [String: Exercise] = [:]
        catalogByID.reserveCapacity(catalog.count)
        for entry in catalog where catalogByID[entry.id] == nil { catalogByID[entry.id] = entry }

        var bestConfidence = 0.0
        var bestStored: Double?
        var bestSource: Exercise?
        var bestSourceOneRepMax = 0.0

        // Dictionary iteration order is not stable across runs, so the keys are sorted: two
        // equally good candidates must always resolve to the same one.
        for id in relatedHistories.keys.sorted() {
            guard let history = relatedHistories[id], let source = catalogByID[id] else { continue }

            let isSameExercise = (id == exercise.id)
            let samePattern = source.metadata.movementPattern == exercise.metadata.movementPattern
            let sameTarget = source.target == exercise.target
            guard isSameExercise || (samePattern && sameTarget) else { continue }

            guard let sourceSystemOneRepMax = systemOneRepMax(
                from: history, exercise: source, bodyWeightKg: bodyWeightKg
            ) else { continue }

            guard let stored = workingLoad(
                systemOneRepMaxKg: sourceSystemOneRepMax, exercise: exercise,
                bodyWeightKg: bodyWeightKg, reps: reps,
                safetyFactor: Constants.measuredSafetyFactor, increments: increments
            ) else { continue }

            var confidence: Double
            if isSameExercise {
                // Their own numbers on this exact movement. Nothing is lost in translation.
                confidence = 0.88
            } else if source.metadata.loadability == exercise.metadata.loadability {
                confidence = 0.72
            } else {
                // A transfer coefficient between implements is a population average, not a fact.
                confidence = 0.62
            }
            if source.metadata.laterality != exercise.metadata.laterality { confidence -= 0.06 }
            if source.equipment != exercise.equipment { confidence -= 0.04 }

            // One session is an anecdote; four is a trend. Scale linearly between them.
            let sessions = max(history.totalSessions, history.performances.count)
            confidence *= min(1.0, 0.50 + Double(min(sessions, 4)) * 0.125)

            if confidence > bestConfidence {
                bestConfidence = confidence
                bestStored = stored
                bestSource = source
                bestSourceOneRepMax = sourceSystemOneRepMax
            }
        }

        guard let stored = bestStored, let source = bestSource else { return nil }
        let confidence = min(max(bestConfidence, 0), 1)
        let sourceStoredOneRepMax = storedLoad(
            fromBarbellEquivalent: bestSourceOneRepMax, exercise: source, bodyWeightKg: bodyWeightKg
        )

        let explanation: Explanation
        if source.id == exercise.id {
            explanation = Explanation("loadEstimate.explain.fromOwnHistory", [
                exercise.name,
                TrainingFormat.weight(stored),
                TrainingFormat.count(reps),
                TrainingFormat.weight(sourceStoredOneRepMax)
            ])
        } else {
            explanation = Explanation("loadEstimate.explain.fromRelated", [
                exercise.name,
                TrainingFormat.weight(stored),
                TrainingFormat.count(reps),
                source.name,
                TrainingFormat.weight(sourceStoredOneRepMax)
            ])
        }

        return LoadEstimate(
            weightKg: stored,
            confidence: confidence,
            requiresCalibration: confidence < Constants.calibrationThreshold,
            explanation: explanation
        )
    }

    /// The best one-rep max a history supports, expressed on the shared barbell-equivalent scale.
    ///
    /// Recomputed from the raw sets rather than read straight off
    /// `ExerciseHistorySnapshot.bestEstimatedOneRepMaxKg` because the stored figure is in the
    /// implement's own units, which for a weighted or assisted movement means added load or
    /// assistance — a number that has to be reunited with body mass before it means anything. The
    /// stored figure is still used as a fallback when no set survives the reliability filter.
    private static func systemOneRepMax(
        from history: ExerciseHistorySnapshot,
        exercise: Exercise,
        bodyWeightKg: Double
    ) -> Double? {
        var best: Double?
        for performance in history.performances.prefix(Constants.relatedSessionsScanned) {
            for set in performance.sets where set.kind.countsAsWorkingSet && set.isCompleted {
                guard let reps = set.reps, let weightKg = set.weightKg else { continue }
                let systemKg = barbellEquivalent(
                    ofStored: weightKg, exercise: exercise, bodyWeightKg: bodyWeightKg
                )
                guard let estimate = OneRepMaxCalculator.estimate(weightKg: systemKg, reps: reps) else { continue }
                if best == nil || estimate > best! { best = estimate }
            }
        }
        if let best { return best }
        guard let stored = history.bestEstimatedOneRepMaxKg, stored > 0 else { return nil }
        return barbellEquivalent(ofStored: stored, exercise: exercise, bodyWeightKg: bodyWeightKg)
    }

    // MARK: Tier 3 — the body-weight ratio table

    private static func estimateFromBodyWeightRatio(
        exercise: Exercise,
        profile: TrainingProfileSnapshot,
        bodyWeightKg: Double,
        increments: EquipmentIncrements,
        reps: Int
    ) -> LoadEstimate? {
        let pattern = exercise.metadata.movementPattern
        let ratio = strengthRatios(for: pattern).value(for: profile.experience)
            * sexFactor(profile.biologicalSex, pattern: pattern)
        guard ratio > 0 else { return nil }

        // The table is calibrated on the implement named by `referenceLoadability`, so it is lifted
        // onto the shared barbell-equivalent scale before being converted to this exercise's own.
        let referenceCoefficient = implementCoefficient(
            loadability: referenceLoadability(for: pattern), pattern: pattern
        )
        guard referenceCoefficient > 0 else { return nil }
        let systemOneRepMaxKg = ratio * bodyWeightKg / referenceCoefficient

        guard let stored = workingLoad(
            systemOneRepMaxKg: systemOneRepMaxKg, exercise: exercise, bodyWeightKg: bodyWeightKg,
            reps: reps, safetyFactor: Constants.populationSafetyFactor, increments: increments
        ) else { return nil }

        // The table is built from novice standards, so it fits a beginner better than an advanced
        // lifter, whose numbers scatter far more widely. Either way it is population data and the
        // first set is a calibration set.
        let confidence = profile.experience <= .beginner ? 0.45 : 0.36
        return LoadEstimate(
            weightKg: stored,
            confidence: confidence,
            requiresCalibration: confidence < Constants.calibrationThreshold,
            explanation: Explanation("loadEstimate.explain.fromBodyWeight", [
                exercise.name,
                TrainingFormat.weight(stored),
                TrainingFormat.count(reps),
                TrainingFormat.weight(bodyWeightKg)
            ])
        )
    }

    // MARK: Tier 4 — the lightest sensible setting

    private static func minimumLoadEstimate(
        exercise: Exercise,
        increments: EquipmentIncrements
    ) -> LoadEstimate {
        let stored = LoadRounding.round(
            kilograms: minimumSelectableLoad(
                loadability: exercise.metadata.loadability, increments: increments
            ),
            loadability: exercise.metadata.loadability,
            profile: increments
        )
        return LoadEstimate(
            weightKg: stored,
            confidence: 0.15,
            requiresCalibration: true,
            explanation: Explanation("loadEstimate.explain.minimum", [
                exercise.name,
                TrainingFormat.weight(stored)
            ])
        )
    }

    // MARK: - Conversion between implements

    /// Turns a one-rep max on the shared scale into a rounded working load on this exercise's own.
    private static func workingLoad(
        systemOneRepMaxKg: Double,
        exercise: Exercise,
        bodyWeightKg: Double,
        reps: Int,
        safetyFactor: Double,
        increments: EquipmentIncrements
    ) -> Double? {
        guard systemOneRepMaxKg.isFinite, systemOneRepMaxKg > 0 else { return nil }
        let ceiling = bodyWeightKg * Constants.sanityCeilingBodyWeightMultiple
        let clampedOneRepMax = min(systemOneRepMaxKg, ceiling)

        guard let systemWorking = OneRepMaxCalculator.weight(
            forReps: reps, oneRepMaxKg: clampedOneRepMax
        ) else { return nil }

        let stored = storedLoad(
            fromBarbellEquivalent: systemWorking * safetyFactor,
            exercise: exercise,
            bodyWeightKg: bodyWeightKg
        )
        guard stored.isFinite, stored >= 0 else { return nil }

        let loadability = exercise.metadata.loadability
        let rounded = LoadRounding.round(
            kilograms: stored, loadability: loadability, profile: increments
        )
        // `weightedBodyweight` and `assistedBodyweight` legitimately reach zero — bodyweight only,
        // and unassisted. Every other implement has a floor you cannot go under.
        switch loadability {
        case .weightedBodyweight, .assistedBodyweight:
            return max(0, rounded)
        default:
            return max(rounded, minimumSelectableLoad(loadability: loadability, increments: increments))
        }
    }

    /// Converts a load as the app stores it for `exercise` onto a common "barbell-equivalent" scale,
    /// so loads on different implements can be compared.
    ///
    /// For a weighted or assisted movement the stored number is added load or assistance, so body
    /// mass is folded in; for everything else the implement's transfer coefficient and, where it
    /// applies, the per-side halving of unilateral work are divided out.
    static func barbellEquivalent(
        ofStored stored: Double,
        exercise: Exercise,
        bodyWeightKg: Double
    ) -> Double {
        let meta = exercise.metadata
        switch meta.loadability {
        case .weightedBodyweight:
            return bodyWeightKg * bodyweightLoadFraction(for: meta.movementPattern) + stored
        case .assistedBodyweight:
            return max(0, bodyWeightKg * bodyweightLoadFraction(for: meta.movementPattern) - stored)
        default:
            let divisor = implementCoefficient(loadability: meta.loadability, pattern: meta.movementPattern)
                * lateralityFactor(for: meta)
            guard divisor > 0 else { return stored }
            return stored / divisor
        }
    }

    /// The inverse of `barbellEquivalent(ofStored:exercise:bodyWeightKg:)`.
    static func storedLoad(
        fromBarbellEquivalent system: Double,
        exercise: Exercise,
        bodyWeightKg: Double
    ) -> Double {
        let meta = exercise.metadata
        switch meta.loadability {
        case .weightedBodyweight:
            // Below body mass there is nothing to add: the movement is simply not yet loadable.
            return max(0, system - bodyWeightKg * bodyweightLoadFraction(for: meta.movementPattern))
        case .assistedBodyweight:
            let bodyLoad = bodyWeightKg * bodyweightLoadFraction(for: meta.movementPattern)
            // Never assist away more than 90 % of body mass: past that the machine is doing the set.
            return min(max(0, bodyLoad - system), bodyLoad * 0.90)
        default:
            return system
                * implementCoefficient(loadability: meta.loadability, pattern: meta.movementPattern)
                * lateralityFactor(for: meta)
        }
    }

    /// How much of a barbell-equivalent load the same athlete can move on each implement.
    ///
    /// Anchored on the barbell at 1.00. A fixed bar path lets you move slightly more than a free bar
    /// but stack labels are notoriously optimistic, so machines sit just below it; cables lose a
    /// little more to pulley friction and the line of pull. Dumbbells are the big one: a pair moves
    /// roughly 0.85 of the barbell total because each side stabilises itself, and the app stores
    /// dumbbell loads **per bell**, so the per-hand coefficient is roughly half of that — the widely
    /// quoted 0.40–0.45 of the barbell total.
    private static func implementCoefficient(loadability: Loadability, pattern: MovementPattern) -> Double {
        switch loadability {
        case .barbell:
            return 1.00
        case .ezBar:
            return 0.92
        case .machineStack:
            // Leg presses and hack squats both derive as a machine `squat`, and their loadable
            // ranges differ by more than a factor of two (a leg press is around twice a free squat,
            // a hack squat around 0.8 of it). The app cannot tell them apart from the pattern alone,
            // so it takes a deliberately low middle and lets the calibration set correct it upwards.
            return pattern == .squat ? 1.40 : 0.90
        case .cableStack:
            return 0.85
        case .dumbbell:
            return 0.42
        case .kettlebell:
            // A bell's offset centre of mass costs a little more than a dumbbell's.
            return 0.40
        case .fixedImplement:
            return 0.25
        case .weightedBodyweight, .assistedBodyweight, .bodyweight, .band, .none:
            // Handled by the body-mass branches; the coefficient is never consulted for these.
            return 1.00
        }
    }

    /// Per-side scaling for unilateral work.
    ///
    /// A single-leg press or a one-arm cable row moves roughly half what the two-sided version does,
    /// so the stored per-side number is halved. Handheld implements are excluded: a dumbbell load is
    /// *already* stored per hand, and a one-arm dumbbell row is if anything slightly heavier per
    /// hand than the two-arm version because the free hand braces.
    private static func lateralityFactor(for meta: ExerciseMetadata) -> Double {
        guard meta.laterality != .bilateral else { return 1.0 }
        switch meta.loadability {
        case .barbell, .ezBar, .machineStack, .cableStack:
            return 0.5
        default:
            return 1.0
        }
    }

    /// The share of body mass a bodyweight version of this pattern actually moves.
    ///
    /// A pull-up lifts nearly everything; a push-up leaves a large fraction on the floor. These are
    /// the conventional figures used to compare bodyweight work with loaded work, and they are what
    /// makes "how much can I add to a dip" answerable at all.
    private static func bodyweightLoadFraction(for pattern: MovementPattern) -> Double {
        switch pattern {
        case .verticalPull: return 0.95
        case .calfRaise: return 0.90
        case .horizontalPush: return 0.90   // dips; push-ups derive as unloadable bodyweight
        case .verticalPush: return 0.85
        case .horizontalPull: return 0.65
        case .squat: return 0.65
        case .lunge: return 0.60
        case .hinge: return 0.60
        case .hipThrust: return 0.55
        case .carry: return 0.50
        case .coreFlexion: return 0.45
        case .coreAntiExtension: return 0.40
        default: return 0.55
        }
    }

    /// The lightest load the implement can actually be set to.
    private static func minimumSelectableLoad(
        loadability: Loadability,
        increments: EquipmentIncrements
    ) -> Double {
        switch loadability {
        case .barbell: return increments.barbellBarWeightKg
        case .ezBar: return increments.ezBarWeightKg
        case .dumbbell: return increments.availableDumbbellsKg.min() ?? 2
        case .kettlebell: return increments.kettlebellsKg.min() ?? 8
        case .machineStack: return increments.machineIncrementKg
        case .cableStack: return increments.cableIncrementKg
        case .weightedBodyweight, .assistedBodyweight, .bodyweight, .band, .fixedImplement, .none:
            return 0
        }
    }

    // MARK: - Population strength standards

    /// One row of the ratio table: estimated 1RM as a multiple of body mass, per experience level.
    private struct StrengthRatios {
        var never: Double
        var beginner: Double
        var intermediate: Double
        var advanced: Double

        func value(for level: ExperienceLevel) -> Double {
            switch level {
            case .never: never
            case .beginner: beginner
            case .intermediate: intermediate
            case .advanced: advanced
            }
        }
    }

    /// Estimated 1RM as a multiple of body mass, on the pattern's reference implement.
    ///
    /// Calibrated against the untrained/novice/intermediate/advanced columns of the commonly cited
    /// strength-standard tables for men, then trimmed towards their lower bound. These numbers exist
    /// to produce a *safe first guess*, not to grade anybody: being 20 % light costs one warm-up set,
    /// while being 20 % heavy costs a failed rep on a movement the user has never performed.
    private static func strengthRatios(for pattern: MovementPattern) -> StrengthRatios {
        switch pattern {
        case .squat:            return StrengthRatios(never: 0.55, beginner: 0.75, intermediate: 1.15, advanced: 1.55)
        case .hinge:            return StrengthRatios(never: 0.70, beginner: 0.95, intermediate: 1.40, advanced: 1.85)
        case .lunge:            return StrengthRatios(never: 0.35, beginner: 0.50, intermediate: 0.75, advanced: 1.00)
        case .hipThrust:        return StrengthRatios(never: 0.60, beginner: 0.85, intermediate: 1.30, advanced: 1.75)
        case .carry:            return StrengthRatios(never: 0.45, beginner: 0.60, intermediate: 0.90, advanced: 1.20)
        case .horizontalPush:   return StrengthRatios(never: 0.40, beginner: 0.55, intermediate: 0.85, advanced: 1.15)
        case .verticalPush:     return StrengthRatios(never: 0.28, beginner: 0.38, intermediate: 0.58, advanced: 0.78)
        case .horizontalPull:   return StrengthRatios(never: 0.38, beginner: 0.52, intermediate: 0.78, advanced: 1.05)
        case .verticalPull:     return StrengthRatios(never: 0.55, beginner: 0.75, intermediate: 1.20, advanced: 1.55)
        case .chestFly:         return StrengthRatios(never: 0.20, beginner: 0.30, intermediate: 0.45, advanced: 0.60)
        case .shoulderRaise:    return StrengthRatios(never: 0.10, beginner: 0.14, intermediate: 0.20, advanced: 0.26)
        case .shrug:            return StrengthRatios(never: 0.50, beginner: 0.70, intermediate: 1.00, advanced: 1.30)
        case .elbowFlexion:     return StrengthRatios(never: 0.18, beginner: 0.25, intermediate: 0.35, advanced: 0.45)
        case .elbowExtension:   return StrengthRatios(never: 0.20, beginner: 0.28, intermediate: 0.40, advanced: 0.52)
        case .kneeExtension:    return StrengthRatios(never: 0.40, beginner: 0.55, intermediate: 0.80, advanced: 1.05)
        case .kneeFlexion:      return StrengthRatios(never: 0.28, beginner: 0.40, intermediate: 0.58, advanced: 0.75)
        case .calfRaise:        return StrengthRatios(never: 0.60, beginner: 0.85, intermediate: 1.20, advanced: 1.55)
        case .hipAbduction:     return StrengthRatios(never: 0.25, beginner: 0.35, intermediate: 0.50, advanced: 0.65)
        case .hipAdduction:     return StrengthRatios(never: 0.25, beginner: 0.35, intermediate: 0.50, advanced: 0.65)
        case .wristFlexion:     return StrengthRatios(never: 0.10, beginner: 0.14, intermediate: 0.20, advanced: 0.26)
        case .wristExtension:   return StrengthRatios(never: 0.06, beginner: 0.09, intermediate: 0.13, advanced: 0.17)
        case .coreFlexion:      return StrengthRatios(never: 0.25, beginner: 0.35, intermediate: 0.50, advanced: 0.65)
        case .coreRotation:     return StrengthRatios(never: 0.12, beginner: 0.18, intermediate: 0.26, advanced: 0.34)
        case .coreLateralFlexion: return StrengthRatios(never: 0.15, beginner: 0.22, intermediate: 0.32, advanced: 0.42)
        case .coreAntiExtension: return StrengthRatios(never: 0.12, beginner: 0.18, intermediate: 0.25, advanced: 0.32)
        case .neckMovement:     return StrengthRatios(never: 0.05, beginner: 0.07, intermediate: 0.10, advanced: 0.13)
        case .cardio, .mobility, .other:
            return StrengthRatios(never: 0.15, beginner: 0.22, intermediate: 0.30, advanced: 0.40)
        }
    }

    /// The implement the ratio table for `pattern` is calibrated on.
    private static func referenceLoadability(for pattern: MovementPattern) -> Loadability {
        switch pattern {
        case .squat, .hinge, .lunge, .hipThrust, .carry, .horizontalPush, .verticalPush,
             .horizontalPull, .shrug, .elbowFlexion, .wristFlexion, .wristExtension:
            return .barbell
        case .verticalPull, .chestFly, .kneeExtension, .kneeFlexion, .calfRaise,
             .hipAbduction, .hipAdduction, .neckMovement:
            return .machineStack
        case .shoulderRaise, .elbowExtension, .coreFlexion, .coreRotation,
             .coreLateralFlexion, .coreAntiExtension, .cardio, .mobility, .other:
            return .cableStack
        }
    }

    /// Scales the male-calibrated ratio table for the user's reported sex.
    ///
    /// Population averages put female upper-body strength at roughly 0.60–0.65 of male at the same
    /// body mass, and lower-body strength at roughly 0.70–0.80, chiefly because of differences in
    /// lean-mass distribution. When the user declined to say, the app follows the same convention as
    /// its metabolic formulas and takes the midpoint of the two constants rather than guessing.
    private static func sexFactor(_ sex: BiologicalSex, pattern: MovementPattern) -> Double {
        let female = isLowerBodyPattern(pattern) ? 0.75 : 0.62
        switch sex {
        case .male: return 1.0
        case .female: return female
        case .unspecified: return (1.0 + female) / 2
        }
    }

    private static func isLowerBodyPattern(_ pattern: MovementPattern) -> Bool {
        switch pattern {
        case .squat, .hinge, .lunge, .hipThrust, .kneeExtension, .kneeFlexion,
             .calfRaise, .hipAbduction, .hipAdduction:
            return true
        default:
            return false
        }
    }

    // MARK: - Warm-up ramp

    /// Builds the ramp of preparatory sets that leads into `workingWeightKg`.
    ///
    /// The ramp climbs from roughly 40 % to roughly 85 % of the working load with descending reps,
    /// which is the standard approach: enough total exposure to rehearse the groove and raise tissue
    /// temperature, not enough volume to eat into the working sets.
    ///
    /// **Light isolation work is skipped entirely.** Below `Constants.warmupSkipThresholdKg` on an
    /// isolation movement, 40 % of the working load is a load the user could hold all day; the first
    /// working set is a better warm-up than any ramp, and a ramp costs several minutes across a
    /// session full of them. Isolation work above the threshold gets a single ramp set.
    static func warmupSets(
        workingWeightKg: Double,
        exercise: Exercise,
        increments: EquipmentIncrements
    ) -> [WarmupSet] {
        let meta = exercise.metadata
        let loadability = meta.loadability
        guard loadability.carriesExternalLoad, loadability != .fixedImplement else { return [] }
        guard workingWeightKg.isFinite, workingWeightKg > 0 else { return [] }

        let isAssisted = loadability == .assistedBodyweight
        let count = warmupSetCount(
            workingWeightKg: workingWeightKg, mechanic: meta.mechanic, isAssisted: isAssisted
        )
        guard count > 0 else { return [] }

        let fractions = warmupFractions(count: count)
        // Anchor the rep ladder on the movement's own top-of-range so a 5-rep squat does not get a
        // 12-rep warm-up and a 20-rep calf raise does not get a double.
        let anchor = min(12, max(4, meta.recommendedRepRange.upper))

        var result: [WarmupSet] = []
        var previousReps = Int.max
        var previousWeight: Double?

        for (index, fraction) in fractions.enumerated() {
            let raw: Double
            if isAssisted {
                // For an assisted movement a *lighter* set means *more* assistance, so the ramp runs
                // the other way: the fractions are mirrored about 1, which with the two rungs an
                // assisted movement gets means 1.5× the working assistance and then 1.25×.
                raw = workingWeightKg * (2 - fraction)
            } else {
                raw = workingWeightKg * fraction
            }
            let weight = LoadRounding.round(
                kilograms: raw, loadability: loadability, profile: increments
            )

            // Drop anything that rounds onto the working load (or past it) — that is not a warm-up.
            if isAssisted {
                guard weight > workingWeightKg + 0.001 else { continue }
            } else {
                guard weight < workingWeightKg - 0.001 else { continue }
            }
            // Coarse ladders collapse neighbouring ramp steps onto the same plate; keep the first.
            if let previousWeight, abs(previousWeight - weight) < 0.001 { continue }

            let scaled = max(2, Int((Double(anchor) * warmupRepRatios(count: count)[index]).rounded()))
            let reps = min(scaled, max(2, previousReps - 1))
            let isLast = index == fractions.count - 1
            // Short rests early, a fuller one before the working set so the last ramp does not
            // become part of the working set's fatigue. Quantised to quarter-minutes: a rest timer
            // that says 82 seconds looks calculated rather than coached.
            let rest = isLast
                ? min(120, max(60, (meta.defaultRestSeconds / 2 / 15) * 15))
                : 45

            result.append(WarmupSet(weightKg: weight, reps: reps, restSeconds: rest))
            previousReps = reps
            previousWeight = weight
        }

        return result
    }

    /// How many ramp sets a load deserves. Heavier loads need more rungs to reach safely.
    private static func warmupSetCount(
        workingWeightKg: Double,
        mechanic: Mechanic,
        isAssisted: Bool
    ) -> Int {
        if mechanic == .isolation {
            return workingWeightKg < Constants.warmupSkipThresholdKg ? 0 : 1
        }
        // An assisted movement is already sub-bodyweight; two rungs are plenty.
        if isAssisted { return 2 }
        switch workingWeightKg {
        case ..<30: return 2
        case ..<70: return 3
        default: return 4
        }
    }

    /// Fraction of the working load for each ramp set.
    private static func warmupFractions(count: Int) -> [Double] {
        switch count {
        case 1: return [0.60]
        case 2: return [0.50, 0.75]
        case 3: return [0.40, 0.60, 0.80]
        default: return [0.40, 0.55, 0.70, 0.85]
        }
    }

    /// Fraction of the movement's top-of-range reps for each ramp set.
    private static func warmupRepRatios(count: Int) -> [Double] {
        switch count {
        case 1: return [0.60]
        case 2: return [1.00, 0.60]
        case 3: return [1.00, 0.60, 0.35]
        default: return [1.00, 0.65, 0.40, 0.25]
        }
    }
}
