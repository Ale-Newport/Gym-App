import Foundation

/// Decides whether the daily energy target should move, given what the scale actually did.
///
/// The estimate `NutritionRecommendationEngine` produces is a starting point; this engine is the
/// feedback loop that corrects it against reality. Three principles shape every rule below.
///
/// **Slow.** Nothing changes on less than a fortnight of data and never more often than every
/// fourteen days. A weekly nudge would chase measurement error and leave the user unable to tell
/// which change caused which result.
///
/// **Small.** Corrections are 5–10 % of current intake, capped at ±250 kcal, and only half of the
/// observed gap is corrected at a time. Over-correcting produces oscillation, and the body's own
/// adaptation closes part of any gap without help.
///
/// **Proposed, never applied.** `requiresUserApproval` is always `true`.
///
/// Pure and deterministic: `now` is supplied by the caller.
enum NutritionAdjustmentEngine {

    // MARK: - Constants

    enum Constants {
        /// Minimum days between two automatic proposals.
        static let minimumDaysBetweenAdjustments: Int = 14
        /// Below this confidence the trend is treated as unusable regardless of reading count.
        static let minimumConfidence: Double = 0.35
        /// Below this share of days logged, the observed trend cannot be attributed to the target,
        /// so the engine holds. Eighty per cent is roughly "missed one day in five".
        static let minimumAdherence: Double = 0.8
        /// A trend whose newest point is older than this is stale — the user stopped weighing in.
        static let maximumTrendAgeDays: Int = 10

        /// How close to the safety floor still counts as "at the floor". A target that was clamped
        /// upwards rarely lands exactly on it, because macro rounding moves the total by a few
        /// kilocalories either way.
        static let floorProximityKilocalories: Double = 25
        /// Tolerance band around the target rate. The floor covers the standard error of a
        /// three-week regression on noisy daily readings (roughly 0.1–0.2 kg/week); the
        /// proportional term keeps the band sensible for aggressive targets.
        static let toleranceFloorKgPerWeek: Double = 0.15
        static let toleranceFractionOfTarget: Double = 0.30

        /// Only half of the observed gap is corrected in one step.
        static let correctionDamping: Double = 0.5
        /// Correction size as a share of current intake, and the absolute cap on top.
        static let minimumCorrectionFraction: Double = 0.05
        static let maximumCorrectionFraction: Double = 0.10
        static let maximumCorrectionKilocalories: Double = 250
        /// Below this the proposal is not worth putting in front of the user.
        static let negligibleCorrectionKilocalories: Double = 25

        /// The engine will not push intake beyond maintenance plus this, however slow the gain.
        /// Past that point the limit is rarely energy, and a bigger surplus is mostly fat.
        static let maximumSurplusAboveMaintenance: Double = 750

        /// How the calorie change is split by energy. Carbohydrate carries most of it: it is the
        /// training fuel, the easiest macro to add or remove in practice, and the one with no
        /// physiological floor to respect. Protein never moves at all.
        static let carbohydrateShareOfChange: Double = 0.7
    }

    // MARK: - Entry point

    /// Evaluates the current targets against the observed weight trend.
    ///
    /// - Parameters:
    ///   - current: the targets in force.
    ///   - trend: output of `WeightTrendAnalyzer`.
    ///   - profile: the user's nutrition profile, for the safety floor and macro floors.
    ///   - adherence: 0…1 share of days in the trend window on which the user logged their food
    ///     reasonably completely. `nil` when the caller cannot tell, which is treated as "do not
    ///     block on adherence" rather than as zero.
    ///   - daysSinceLastAdjustment: whole days since the target last changed, however it changed.
    ///   - now: reference date, used only to judge whether the trend data is stale.
    static func evaluate(
        current: EnergyTargets,
        trend: WeightTrendAnalysis,
        profile: NutritionProfileSnapshot,
        adherence: Double?,
        daysSinceLastAdjustment: Int,
        now: Date = Date()
    ) -> CalorieAdjustmentDecision {

        // 1. Is there a usable signal at all?
        guard trend.hasEnoughData, let observedWeekly = trend.weeklyChangeKg else {
            return hold(.insufficientData, Explanation("nutrition.adjust.insufficientData", [
                NutritionFormat.whole(Double(WeightTrendAnalyzer.Constants.minimumReadings)),
                NutritionFormat.whole(Double(WeightTrendAnalyzer.Constants.minimumSpanDays))
            ]))
        }
        if isTrendStale(trend, now: now) {
            return hold(.insufficientData, Explanation("nutrition.adjust.staleData", [
                NutritionFormat.whole(Double(Constants.maximumTrendAgeDays))
            ]))
        }
        if trend.confidence < Constants.minimumConfidence {
            return hold(.hold, Explanation("nutrition.adjust.lowConfidence"))
        }

        // 2. Has enough time passed since the last change for its effect to be visible?
        if daysSinceLastAdjustment < Constants.minimumDaysBetweenAdjustments {
            return hold(.hold, Explanation("nutrition.adjust.tooSoon", [
                NutritionFormat.whole(Double(max(0, daysSinceLastAdjustment))),
                NutritionFormat.whole(Double(Constants.minimumDaysBetweenAdjustments))
            ]))
        }

        // 3. Can the trend be attributed to the plan?
        if let adherence, adherence < Constants.minimumAdherence {
            return hold(.hold, Explanation("nutrition.adjust.lowAdherence", [
                NutritionFormat.percent(nutritionClamp01(adherence))
            ]))
        }

        // 4a. The floor case, which has to be handled before the comparison in 4b.
        //
        // When a small or older user asks for an aggressive cut, the safety floor can land *above*
        // the intake their goal implied. `EnergyTargets.weeklyBodyMassChangeKg` faithfully reports
        // the rate those clamped calories imply, which is a small *gain* — so a woman eating at the
        // floor and steadily losing 0.2 kg a week compares as "gaining far less than intended" and
        // gets told to eat more. That is not unsafe, but it actively fights the goal she chose.
        //
        // If the intent is a deficit, intake is already at the floor, and the scale is moving the
        // right way, calories are simply not the lever any more.
        if current.direction == .deficit || current.direction == .slightDeficit {
            let safetyFloor = NutritionRecommendationEngine.safeMinimumKilocalories(for: profile)
            if current.kilocalories <= safetyFloor + Constants.floorProximityKilocalories,
               observedWeekly <= 0 {
                return hold(.hold, Explanation("nutrition.adjust.floorReached", [
                    NutritionFormat.whole(safetyFloor)
                ]))
            }
        }

        // 4b. Compare observed against intended.
        let targetWeekly = current.weeklyBodyMassChangeKg
        let gap = targetWeekly - observedWeekly
        let tolerance = toleranceKgPerWeek(targetWeekly: targetWeekly, confidence: trend.confidence)
        if abs(gap) <= tolerance {
            return hold(.hold, Explanation("nutrition.adjust.onTrack", [
                NutritionFormat.signedOneDecimal(observedWeekly),
                NutritionFormat.signedOneDecimal(targetWeekly)
            ]))
        }

        // 5. Size the correction. `gap > 0` means the user is gaining less (or losing more) than
        // intended, so energy goes up.
        let rawDelta = gap * NutritionRecommendationEngine.Constants.energyPerKilogramBodyMass / 7
        let damped = rawDelta * Constants.correctionDamping
        let lowerBound = Constants.minimumCorrectionFraction * current.kilocalories
        let upperBound = min(
            Constants.maximumCorrectionFraction * current.kilocalories,
            Constants.maximumCorrectionKilocalories
        )
        let magnitude = nutritionClamp(abs(damped), min(lowerBound, upperBound), upperBound)
        var delta = (damped < 0 ? -magnitude : magnitude)

        // 6. Respect the safety floor and the surplus ceiling.
        //
        // The floor wins outright: `max(floor, …)` is not cosmetic. A stale or partly-populated
        // `current` — a zeroed `EnergyTargets`, or one whose stored maintenance predates a large
        // weight change — can put `TDEE + 750` *below* the safety floor, and clamping to that
        // ceiling afterwards would hand the user a target under the lowest intake this app is
        // willing to recommend. Ordering the two clamps alone does not fix it; the ceiling has to
        // be incapable of reaching below the floor in the first place.
        //
        // The stored maintenance figure is likewise only trusted when it is actually there. A zero
        // means the record never carried one, not that the user burns nothing, and taking it
        // literally would both pin the ceiling at 750 kcal and report the new target as a 1.7 kg a
        // week gain. Re-estimating from the profile is what the app would have done anyway.
        let floor = NutritionRecommendationEngine.safeMinimumKilocalories(for: profile)
        let maintenance = current.totalDailyEnergyExpenditure > 0
            ? current.totalDailyEnergyExpenditure
            : NutritionRecommendationEngine.totalDailyEnergyExpenditure(profile: profile)
        let ceiling = max(
            floor,
            current.kilocalories,
            maintenance + Constants.maximumSurplusAboveMaintenance
        )
        var proposed = current.kilocalories + delta
        if proposed < floor {
            proposed = floor
            delta = proposed - current.kilocalories
            if abs(delta) < Constants.negligibleCorrectionKilocalories {
                return hold(.hold, Explanation("nutrition.adjust.floorReached", [
                    NutritionFormat.whole(floor)
                ]))
            }
        }
        if proposed > ceiling {
            proposed = ceiling
            delta = proposed - current.kilocalories
            if abs(delta) < Constants.negligibleCorrectionKilocalories {
                return hold(.hold, Explanation("nutrition.adjust.ceilingReached", [
                    NutritionFormat.whole(ceiling)
                ]))
            }
        }
        if abs(delta) < Constants.negligibleCorrectionKilocalories {
            return hold(.hold, Explanation("nutrition.adjust.onTrack", [
                NutritionFormat.signedOneDecimal(observedWeekly),
                NutritionFormat.signedOneDecimal(targetWeekly)
            ]))
        }

        proposed = (proposed / 10).rounded() * 10
        delta = proposed - current.kilocalories

        let action: CalorieAdjustmentAction = delta > 0 ? .increase : .decrease
        let headline = Explanation(
            delta > 0 ? "nutrition.adjust.increase" : "nutrition.adjust.decrease",
            [
                NutritionFormat.signedOneDecimal(observedWeekly),
                NutritionFormat.signedOneDecimal(targetWeekly),
                NutritionFormat.whole(abs(delta))
            ]
        )

        var newTargets = current
        newTargets.kilocalories = proposed
        newTargets.totalDailyEnergyExpenditure = maintenance
        let split = redistribute(delta: delta, current: current, profile: profile, newKilocalories: proposed)
        newTargets.proteinG = split.proteinG
        newTargets.carbsG = split.carbsG
        newTargets.fatG = split.fatG
        // The intent has not changed; the rate the new number implies has.
        newTargets.weeklyBodyMassChangeKg = ((proposed - maintenance)
            * 7 / NutritionRecommendationEngine.Constants.energyPerKilogramBodyMass * 100).rounded() / 100
        newTargets.explanations = [headline]
            + split.explanations
            + [Explanation("nutrition.adjust.approval"),
               Explanation("nutrition.energy.estimateDisclaimer")]

        return CalorieAdjustmentDecision(
            action: action,
            deltaKilocalories: delta,
            newTargets: newTargets,
            explanation: headline,
            requiresUserApproval: true
        )
    }

    // MARK: - Helpers

    private static func hold(
        _ action: CalorieAdjustmentAction,
        _ explanation: Explanation
    ) -> CalorieAdjustmentDecision {
        // Even a "nothing changes" outcome is returned as requiring approval: the contract is that
        // this engine only ever produces proposals, and a caller must never be able to apply one of
        // its results without asking.
        CalorieAdjustmentDecision(
            action: action,
            deltaKilocalories: 0,
            newTargets: nil,
            explanation: explanation,
            requiresUserApproval: true
        )
    }

    private static func isTrendStale(_ trend: WeightTrendAnalysis, now: Date) -> Bool {
        guard let newest = trend.movingAverage.last?.date else { return true }
        let ageDays = now.timeIntervalSince(newest) / 86_400
        return ageDays > Double(Constants.maximumTrendAgeDays)
    }

    /// The band inside which the observed rate counts as "close enough".
    ///
    /// Widened as confidence falls — noisy data should make the engine more reluctant to act, not
    /// equally willing. At full confidence the band is the base width; at the minimum usable
    /// confidence it is about 1.65× that.
    static func toleranceKgPerWeek(targetWeekly: Double, confidence: Double) -> Double {
        let base = max(
            Constants.toleranceFloorKgPerWeek,
            Constants.toleranceFractionOfTarget * abs(targetWeekly)
        )
        let widening = nutritionClamp(2 - nutritionClamp01(confidence), 1, 2)
        return base * widening
    }

    /// Applies the energy change to carbohydrate and fat, leaving protein untouched.
    ///
    /// Protein stays put for two reasons: it is the macro with a specific evidence-based target
    /// that does not depend on total intake, and it is the one whose job — protecting lean mass —
    /// matters most precisely when calories are being cut. Fat is not allowed below its floor; any
    /// remainder that cannot go on fat goes on carbohydrate, and vice versa.
    ///
    /// Adding the change onto the existing grams only produces a coherent plate when the existing
    /// grams already account for the existing calorie figure. `EnergyTargets` carries a default on
    /// every field, so a caller can hand over a set whose macros do not reconcile with its
    /// `kilocalories` — a half-populated record, or one restored from an older schema. Two things
    /// therefore happen before the 70/30 split is trusted:
    ///
    /// * Protein that alone exceeds the new energy budget (or a negative macro anywhere) means there
    ///   is no split to nudge, so one is rebuilt from scratch. Protein moving is the lesser evil
    ///   against handing the user a plan that cannot be eaten.
    /// * Otherwise carbohydrate and fat are re-anchored on the energy actually left after protein.
    ///   This is a no-op on a consistent target set, and it stops the few kcal of rounding drift
    ///   each adjustment introduces from compounding across a year of fortnightly changes.
    static func redistribute(
        delta: Double,
        current: EnergyTargets,
        profile: NutritionProfileSnapshot,
        newKilocalories: Double
    ) -> (proteinG: Double, carbsG: Double, fatG: Double, explanations: [Explanation]) {
        let energy = max(0, newKilocalories)
        let protein = current.proteinG
        // A protein figure of zero is a record that never carried one, not a plan to eat none of
        // it, so it is rebuilt rather than frozen in place.
        let usable = protein > 0 && current.carbsG >= 0 && current.fatG >= 0
            && protein * 4 <= energy
        guard usable else {
            let rebuilt = NutritionRecommendationEngine.macros(
                kilocalories: energy,
                profile: profile,
                direction: current.direction
            )
            return (rebuilt.proteinG, rebuilt.carbsG, rebuilt.fatG, rebuilt.explanations)
        }

        let fatFloor = NutritionRecommendationEngine.fatFloorGrams(
            kilocalories: energy, profile: profile
        )
        let availableEnergy = max(0, energy - protein * 4)

        var carbEnergy = current.carbsG * 4 + delta * Constants.carbohydrateShareOfChange
        var fatEnergy = current.fatG * 9 + delta * (1 - Constants.carbohydrateShareOfChange)
        // Re-anchor on the budget. Every step below only moves energy *between* the two, so this is
        // the one place the total is set, and the returned split always adds up to `newKilocalories`.
        let plannedEnergy = carbEnergy + fatEnergy
        if plannedEnergy > 0 {
            let scale = availableEnergy / plannedEnergy
            carbEnergy *= scale
            fatEnergy *= scale
        } else {
            // Nothing left to scale — the incoming split carried no carbohydrate or fat at all.
            // Fall back to the same energy share the recommendation engine would have used.
            fatEnergy = availableEnergy
                * NutritionRecommendationEngine.fatEnergyShare(direction: current.direction)
            carbEnergy = availableEnergy - fatEnergy
        }
        var explanations: [Explanation] = [Explanation("nutrition.adjust.macroSplit")]

        // Fat floor first: whatever fat cannot absorb, carbohydrate takes.
        let fatFloorEnergy = fatFloor * 9
        if fatEnergy < fatFloorEnergy {
            carbEnergy -= (fatFloorEnergy - fatEnergy)
            fatEnergy = fatFloorEnergy
            explanations.append(Explanation(
                "nutrition.macro.fatFloor", [NutritionFormat.whole(fatFloor)]
            ))
        }
        // Then the carbohydrate floor at zero: whatever carbohydrate cannot absorb comes off fat,
        // down to — and if the arithmetic demands it, below — its floor, because a negative macro
        // is never an acceptable output.
        if carbEnergy < 0 {
            fatEnergy += carbEnergy
            carbEnergy = 0
            explanations.append(Explanation(
                "nutrition.macro.fatCompromise", [NutritionFormat.whole(max(0, fatEnergy) / 9)]
            ))
        }

        let carbs = max(0, (carbEnergy / 4 / 5).rounded() * 5)
        let fat = max(0, (fatEnergy / 9).rounded())
        return (protein, carbs, fat, explanations)
    }
}
