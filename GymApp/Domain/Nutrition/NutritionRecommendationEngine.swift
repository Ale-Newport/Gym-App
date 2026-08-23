import Foundation

/// Turns a `NutritionProfileSnapshot` into a daily energy and macronutrient target.
///
/// Every number this engine produces is a **population estimate**, not a measurement. Mifflin-St
/// Jeor predicts an individual's resting energy to roughly ±10 %, activity factors are coarser
/// still, and the 7,700 kcal/kg conversion assumes a fixed body composition of the tissue gained or
/// lost. That is fine — the target is a starting point which `WeightTrendAnalyzer` and
/// `NutritionAdjustmentEngine` then correct against what the user's own scale says. What is *not*
/// fine is presenting the estimate as fact, so every target carries explanations, and the last
/// explanation always states plainly that these are estimates rather than medical advice.
///
/// The engine is pure: value types in, value types out, no persistence, no `Date()`.
enum NutritionRecommendationEngine {

    // MARK: - Constants

    /// Thresholds and coefficients, gathered so `docs/ALGORITHMS.md` and the code cannot drift.
    enum Constants {
        /// Energy per kilogram of body-mass change. The conventional 7,700 kcal/kg (Wishnofsky's
        /// 3,500 kcal/lb) figure: it assumes the tissue is mostly fat, which holds well enough for
        /// the modest rates this app recommends.
        static let energyPerKilogramBodyMass: Double = 7_700

        /// Substituted when no birth date is on file. Thirty is the middle of the adult range, so
        /// the error it introduces is at most about ±100 kcal across a 20–60 year old.
        static let defaultAgeYears: Int = 30
        static let minimumAgeYears: Double = 14
        static let maximumAgeYears: Double = 100

        /// Absolute intake floors. Widely used clinical guardrails for unsupervised dieting; the
        /// app never recommends below them and says so.
        static let femaleFloorKilocalories: Double = 1_200
        static let maleFloorKilocalories: Double = 1_500
        /// A target below resting energy plus a 10 % margin is not a diet, it is a fast.
        static let restingEnergyFloorMultiplier: Double = 1.1

        /// Hard caps on the daily energy offset, applied before the floor.
        static let maximumDailyDeficit: Double = 1_000
        static let maximumDailySurplus: Double = 700

        /// A surplus above ~0.5 % of body mass per week is mostly fat, whatever the pace setting
        /// says, so the surplus side of `NutritionGoalPace` is capped here.
        static let maximumSurplusWeeklyFraction: Double = 0.005
        /// Recomposition runs at half the chosen pace: enough of a deficit to lose fat, small
        /// enough to keep training quality and lean mass.
        static let recompositionPaceFactor: Double = 0.5

        /// Uplift applied per resistance session beyond the third, on top of the activity factor.
        /// The onboarding copy describes `ActivityLevel` in terms of *daily* movement ("desk work,
        /// little walking"), so lifting sessions are only partly captured by it. A 60-minute
        /// session costs roughly 250–350 kcal; since part of that is already inside the multiplier
        /// we credit a deliberately small 1.2 % of maintenance per extra session, capping at four.
        static let trainingUpliftPerSession: Double = 0.012
        static let trainingUpliftBaselineDays: Int = 3

        /// Mainstream sports-nutrition protein range for people who train, in g per kg of body
        /// mass per day. The band spans the usual recommendations for hypertrophy and for
        /// preserving lean mass in a deficit.
        static let proteinMinimumPerKg: Double = 1.6
        static let proteinMaximumPerKg: Double = 2.2

        /// Fat floors. 0.6 g/kg and 20 % of energy are the commonly cited minimums for hormone
        /// production and fat-soluble vitamin absorption; whichever binds harder wins.
        static let fatMinimumPerKg: Double = 0.6
        static let fatMinimumEnergyShare: Double = 0.20

        /// Above this BMI, protein is prescribed off an adjusted body mass instead of scale mass.
        static let adjustedMassBMIThreshold: Double = 30
        /// Top of the WHO healthy BMI band, used as the reference mass in that correction.
        static let healthyBMICeiling: Double = 25
        /// The clinical adjusted-body-weight correction: reference + 0.4 × (actual − reference).
        static let adjustedMassFactor: Double = 0.4

        /// A target weight this far from current mass steers an otherwise neutral goal. Two
        /// kilograms is roughly the noise floor of a bathroom scale read over a few weeks.
        static let targetWeightSteerThresholdKg: Double = 2
    }

    // MARK: - Resting and maintenance energy

    /// Mifflin-St Jeor resting metabolic rate, kcal/day.
    ///
    /// `10w + 6.25h − 5a + 5` for men and `… − 161` for women. For `.unspecified` the two sex
    /// constants are averaged (`(5 − 161) / 2 = −78`) rather than guessing a sex: the resulting
    /// figure sits between the two and the explanation tells the user it is less precise.
    ///
    /// Inputs are clamped to physiologically plausible ranges so a corrupt or half-finished profile
    /// produces a conservative number instead of nonsense.
    static func basalMetabolicRate(profile: NutritionProfileSnapshot) -> Double {
        let mass = nutritionClamp(profile.weightKg, 30, 300)
        let height = nutritionClamp(profile.heightCm, 120, 230)
        let age = nutritionClamp(
            Double(profile.ageYears ?? Constants.defaultAgeYears),
            Constants.minimumAgeYears,
            Constants.maximumAgeYears
        )
        let constant: Double
        switch profile.biologicalSex {
        case .male: constant = 5
        case .female: constant = -161
        case .unspecified: constant = (5 - 161) / 2
        }
        let value = 10 * mass + 6.25 * height - 5 * age + constant
        // Even the smallest plausible adult sits above 800 kcal; the floor only guards against
        // arithmetic on a profile that should never have reached this far.
        return max(800, value)
    }

    /// Maintenance energy, kcal/day: resting energy × activity factor × training uplift.
    static func totalDailyEnergyExpenditure(profile: NutritionProfileSnapshot) -> Double {
        let resting = basalMetabolicRate(profile: profile)
        let sessions = max(0, min(profile.trainingDaysPerWeek, 7) - Constants.trainingUpliftBaselineDays)
        let uplift = 1 + Constants.trainingUpliftPerSession * Double(sessions)
        return resting * profile.activityLevel.multiplier * uplift
    }

    // MARK: - Targets

    /// The complete daily target for this profile.
    static func targets(for profile: NutritionProfileSnapshot) -> EnergyTargets {
        let resting = basalMetabolicRate(profile: profile)
        let maintenance = totalDailyEnergyExpenditure(profile: profile)
        let direction = resolvedDirection(for: profile)

        var explanations: [Explanation] = []
        explanations.append(Explanation("nutrition.energy.bmr", [NutritionFormat.whole(resting)]))
        if profile.ageYears == nil {
            explanations.append(Explanation(
                "nutrition.energy.bmrDefaultAge",
                [NutritionFormat.whole(Double(Constants.defaultAgeYears))]
            ))
        }
        if profile.biologicalSex == .unspecified {
            explanations.append(Explanation("nutrition.energy.bmrUnspecifiedSex"))
        }
        explanations.append(Explanation("nutrition.energy.tdee", [
            NutritionFormat.whole(maintenance),
            NutritionFormat.whole(Double(max(0, min(profile.trainingDaysPerWeek, 7))))
        ]))

        // Intended rate, then the energy offset it implies.
        let intendedWeeklyChange = intendedWeeklyBodyMassChangeKg(profile: profile, direction: direction)
        let rawDailyOffset = intendedWeeklyChange * Constants.energyPerKilogramBodyMass / 7
        var dailyOffset = nutritionClamp(
            rawDailyOffset, -Constants.maximumDailyDeficit, Constants.maximumDailySurplus
        )
        if rawDailyOffset < -Constants.maximumDailyDeficit {
            explanations.append(Explanation(
                "nutrition.energy.deficitCapped", [NutritionFormat.whole(Constants.maximumDailyDeficit)]
            ))
        } else if rawDailyOffset > Constants.maximumDailySurplus {
            explanations.append(Explanation(
                "nutrition.energy.surplusCapped", [NutritionFormat.whole(Constants.maximumDailySurplus)]
            ))
        }

        // Safety floor. A target under it is raised and the user is told why.
        let floor = safeMinimumKilocalories(for: profile)
        var kilocalories = maintenance + dailyOffset
        var floorApplied = false
        if kilocalories < floor {
            kilocalories = floor
            dailyOffset = kilocalories - maintenance
            floorApplied = true
        }
        kilocalories = (kilocalories / 10).rounded() * 10

        // The rate the user will actually see, recomputed from the number they were given rather
        // than the number that was asked for.
        let achievedWeeklyChange = (kilocalories - maintenance) * 7 / Constants.energyPerKilogramBodyMass
        let achievedOffset = kilocalories - maintenance

        // A small, older, sedentary person can have an estimated maintenance *below* the absolute
        // intake floor. Their target is then above maintenance however hard they asked to cut, and
        // saying "eat 1500 kcal, roughly 538 below maintenance" would be flatly untrue — as would
        // prescribing the deficit protein bump. Both the sentence and the macro split therefore
        // follow the balance the user actually gets, not the one they asked for. `direction` on the
        // result stays the *intent*, which is what the rest of the app reasons about.
        let floorRemovedTheDeficit = floorApplied && achievedOffset > 1
        let effectiveDirection: EnergyBalanceDirection =
            floorRemovedTheDeficit && direction != .surplus ? .maintenance : direction

        if floorRemovedTheDeficit {
            explanations.append(Explanation("nutrition.energy.floorAboveMaintenance", [
                NutritionFormat.whole(kilocalories),
                NutritionFormat.whole(maintenance)
            ]))
        } else {
            switch direction {
            case .deficit:
                explanations.append(Explanation("nutrition.energy.deficit", [
                    NutritionFormat.oneDecimal(abs(achievedWeeklyChange)),
                    NutritionFormat.whole(kilocalories),
                    NutritionFormat.whole(abs(kilocalories - maintenance))
                ]))
            case .slightDeficit:
                explanations.append(Explanation("nutrition.energy.recomposition", [
                    NutritionFormat.whole(abs(kilocalories - maintenance)),
                    NutritionFormat.whole(kilocalories)
                ]))
            case .surplus:
                explanations.append(Explanation("nutrition.energy.surplus", [
                    NutritionFormat.oneDecimal(abs(achievedWeeklyChange)),
                    NutritionFormat.whole(kilocalories),
                    NutritionFormat.whole(abs(kilocalories - maintenance))
                ]))
            case .maintenance:
                explanations.append(Explanation(
                    "nutrition.energy.maintenance", [NutritionFormat.whole(kilocalories)]
                ))
            }
            if floorApplied {
                explanations.append(Explanation(
                    "nutrition.energy.floorApplied", [NutritionFormat.whole(kilocalories)]
                ))
            }
        }

        let split = macros(kilocalories: kilocalories, profile: profile, direction: effectiveDirection)
        explanations.append(contentsOf: split.explanations)
        explanations.append(Explanation("nutrition.energy.estimateDisclaimer"))

        return EnergyTargets(
            basalMetabolicRate: (resting).rounded(),
            totalDailyEnergyExpenditure: (maintenance).rounded(),
            kilocalories: kilocalories,
            proteinG: split.proteinG,
            carbsG: split.carbsG,
            fatG: split.fatG,
            direction: direction,
            weeklyBodyMassChangeKg: (achievedWeeklyChange * 100).rounded() / 100,
            explanations: explanations
        )
    }

    /// Which way the energy balance should point.
    ///
    /// The primary goal decides. When that goal is neutral about body mass but the user typed a
    /// target weight that differs by more than `targetWeightSteerThresholdKg`, the target weight
    /// steers instead — otherwise somebody who picked "general fitness" and "lose 8 kg" would be
    /// handed a maintenance target and no way to understand why.
    static func resolvedDirection(for profile: NutritionProfileSnapshot) -> EnergyBalanceDirection {
        let goalDirection = profile.primaryGoal.energyBalanceDirection
        guard goalDirection == .maintenance, let target = profile.targetWeightKg else {
            return goalDirection
        }
        let gap = target - profile.weightKg
        if gap <= -Constants.targetWeightSteerThresholdKg { return .deficit }
        if gap >= Constants.targetWeightSteerThresholdKg { return .surplus }
        return .maintenance
    }

    /// The signed weekly body-mass change the pace and direction ask for, before any clamping.
    static func intendedWeeklyBodyMassChangeKg(
        profile: NutritionProfileSnapshot,
        direction: EnergyBalanceDirection
    ) -> Double {
        let mass = nutritionClamp(profile.weightKg, 30, 300)
        let fraction = profile.pace.weeklyBodyMassFraction
        switch direction {
        case .maintenance:
            return 0
        case .deficit:
            return -fraction * mass
        case .slightDeficit:
            return -fraction * Constants.recompositionPaceFactor * mass
        case .surplus:
            return min(fraction, Constants.maximumSurplusWeeklyFraction) * mass
        }
    }

    /// The lowest daily intake the app will ever recommend for this profile.
    ///
    /// The larger of resting energy + 10 % and the absolute sex floor. For `.unspecified` the
    /// higher of the two absolute floors is used: a floor set too high only slows progress, while
    /// one set too low risks under-eating, so the asymmetry runs towards caution.
    static func safeMinimumKilocalories(for profile: NutritionProfileSnapshot) -> Double {
        let absoluteFloor: Double
        switch profile.biologicalSex {
        case .female: absoluteFloor = Constants.femaleFloorKilocalories
        case .male, .unspecified: absoluteFloor = Constants.maleFloorKilocalories
        }
        let restingFloor = basalMetabolicRate(profile: profile) * Constants.restingEnergyFloorMultiplier
        return max(restingFloor, absoluteFloor)
    }

    // MARK: - Macronutrients

    /// Splits an energy target into protein, carbohydrate and fat.
    ///
    /// Order of operations, and why:
    /// 1. **Protein first.** It is the macro with the strongest evidence behind a specific intake
    ///    and the one that protects lean mass in a deficit, so it gets first call on the budget.
    /// 2. **Fat second, with a hard floor.** Fat has a physiological minimum that carbohydrate does
    ///    not; dropping below it to make the arithmetic work would be the wrong trade.
    /// 3. **Carbohydrate takes the remainder** — it is the training fuel and the flexible macro.
    ///
    /// When the remainder would go negative (a small person on a fast cut with a high protein
    /// prescription), protein is walked back towards its 1.6 g/kg floor first, then fat towards its
    /// own floor, and the compromise is explained. No macro is ever returned negative.
    static func macros(
        kilocalories: Double,
        profile: NutritionProfileSnapshot,
        direction: EnergyBalanceDirection
    ) -> (proteinG: Double, carbsG: Double, fatG: Double, explanations: [Explanation]) {
        var explanations: [Explanation] = []
        let energy = max(0, kilocalories)
        let referenceMass = proteinReferenceMassKg(for: profile)

        // Protein, inside the 1.6–2.2 g/kg consensus band.
        let perKg = proteinPerKilogram(profile: profile, direction: direction)
        var protein = (perKg * referenceMass / 5).rounded() * 5
        let proteinFloor = max(40, (Constants.proteinMinimumPerKg * referenceMass / 5).rounded() * 5)

        // Fat: a share of energy, never below the floor.
        let fatShare = fatEnergyShare(direction: direction)
        let fatFloor = fatFloorGrams(kilocalories: energy, profile: profile)
        var fat = max((fatShare * energy / 9).rounded(), fatFloor)
        let fatFloorBound = fat <= fatFloor + 0.5

        // Carbohydrate is whatever is left.
        var carbs = (energy - protein * 4 - fat * 9) / 4
        var proteinTrimmed = false
        var fatTrimmed = false

        // A meal plan with essentially no carbohydrate is not something this app should hand out
        // silently, so the compromise triggers at a small positive floor rather than at zero.
        let carbTargetFloor: Double = 40
        if carbs < carbTargetFloor {
            let deficitEnergy = (carbTargetFloor - carbs) * 4
            let proteinHeadroomG = max(0, protein - proteinFloor)
            let proteinGiveG = min(proteinHeadroomG, deficitEnergy / 4)
            if proteinGiveG > 0 {
                protein = ((protein - proteinGiveG) / 5).rounded() * 5
                proteinTrimmed = true
            }
            carbs = (energy - protein * 4 - fat * 9) / 4
        }
        if carbs < 0 {
            let deficitEnergy = -carbs * 4
            let fatHeadroomG = max(0, fat - fatFloor)
            let fatGiveG = min(fatHeadroomG, deficitEnergy / 9)
            if fatGiveG > 0 {
                fat = (fat - fatGiveG).rounded()
                fatTrimmed = true
            }
            carbs = (energy - protein * 4 - fat * 9) / 4
        }
        if carbs < 0 {
            // Protein and fat at their floors already exceed the budget. Scale both down in
            // proportion so the split still fits, and say so — the honest answer here is that the
            // calorie target is too low for the body mass, and the explanation points that out.
            let floorEnergy = protein * 4 + fat * 9
            if floorEnergy > 0 {
                let scale = energy / floorEnergy
                protein = (protein * scale / 5).rounded() * 5
                fat = (fat * scale).rounded()
            }
            carbs = 0
            explanations.append(Explanation("nutrition.macro.lowCalorieCompromise"))
        }

        carbs = max(0, (carbs / 5).rounded() * 5)

        // Explanations, in the order the decisions were made.
        let achievedPerKg = referenceMass > 0 ? protein / referenceMass : 0
        explanations.append(Explanation("nutrition.macro.protein", [
            NutritionFormat.whole(protein), NutritionFormat.twoDecimals(achievedPerKg)
        ]))
        if usesAdjustedMass(profile) {
            explanations.append(Explanation(
                "nutrition.macro.proteinAdjustedMass", [NutritionFormat.whole(referenceMass)]
            ))
        }
        if direction == .deficit || direction == .slightDeficit {
            explanations.append(Explanation("nutrition.macro.proteinDeficit"))
        }
        if proteinTrimmed {
            explanations.append(Explanation(
                "nutrition.macro.proteinCompromise", [NutritionFormat.whole(protein)]
            ))
        }
        let achievedFatShare = energy > 0 ? fat * 9 / energy : 0
        explanations.append(Explanation("nutrition.macro.fat", [
            NutritionFormat.whole(fat), NutritionFormat.percent(achievedFatShare)
        ]))
        if fatFloorBound {
            explanations.append(Explanation("nutrition.macro.fatFloor", [NutritionFormat.whole(fat)]))
        }
        if fatTrimmed {
            explanations.append(Explanation(
                "nutrition.macro.fatCompromise", [NutritionFormat.whole(fat)]
            ))
        }
        explanations.append(Explanation("nutrition.macro.carbs", [NutritionFormat.whole(carbs)]))

        return (protein, carbs, fat, explanations)
    }

    /// Grams of protein per kilogram of reference mass for this user.
    ///
    /// Starts at the bottom of the 1.6–2.2 g/kg band and adds documented increments: a deficit
    /// raises it (protein sparing is the whole reason the range has an upper end), a
    /// muscle/strength goal raises it, and a high training load raises it a little further.
    static func proteinPerKilogram(
        profile: NutritionProfileSnapshot,
        direction: EnergyBalanceDirection
    ) -> Double {
        var perKg = Constants.proteinMinimumPerKg
        if direction == .deficit || direction == .slightDeficit { perKg += 0.3 }
        switch profile.primaryGoal {
        case .buildMuscle, .buildStrength, .recomposition, .targetMuscleGroup: perKg += 0.2
        case .loseFat: perKg += 0.1
        case .improveEndurance, .maintain, .generalFitness: break
        }
        let isHighLoad = profile.trainingDaysPerWeek >= 5
            || profile.activityLevel == .active
            || profile.activityLevel == .veryActive
        if isHighLoad { perKg += 0.1 }
        return nutritionClamp(perKg, Constants.proteinMinimumPerKg, Constants.proteinMaximumPerKg)
    }

    /// The body mass protein is prescribed against.
    ///
    /// Above a BMI of 30, g/kg prescriptions on scale mass produce numbers nobody eats — 2 g/kg of
    /// 140 kg is 280 g of protein a day. The standard clinical correction is used instead:
    /// reference mass at the top of the healthy BMI band plus 40 % of the excess. Below that
    /// threshold, and whenever the height on file is implausible, scale mass is used unchanged.
    static func proteinReferenceMassKg(for profile: NutritionProfileSnapshot) -> Double {
        let mass = nutritionClamp(profile.weightKg, 30, 300)
        guard usesAdjustedMass(profile), let bmi = profile.bodyMassIndex, bmi > 0 else { return mass }
        let metres = profile.heightCm / 100
        let healthyMass = Constants.healthyBMICeiling * metres * metres
        return healthyMass + Constants.adjustedMassFactor * (mass - healthyMass)
    }

    /// Whether the adjusted-mass correction applies to this profile.
    static func usesAdjustedMass(_ profile: NutritionProfileSnapshot) -> Bool {
        guard let bmi = profile.bodyMassIndex else { return false }
        return bmi > Constants.adjustedMassBMIThreshold
    }

    /// Share of energy fat should carry before the floor is applied.
    ///
    /// A deficit and a surplus both leave a little more room for carbohydrate — training quality is
    /// the first thing to suffer when glycogen is short, and it is the thing that protects muscle
    /// on a cut and builds it on a bulk. Maintenance sits slightly higher for palatability.
    static func fatEnergyShare(direction: EnergyBalanceDirection) -> Double {
        switch direction {
        case .deficit, .surplus: return 0.25
        case .slightDeficit, .maintenance: return 0.27
        }
    }

    /// The minimum grams of fat for this profile at this energy level.
    static func fatFloorGrams(kilocalories: Double, profile: NutritionProfileSnapshot) -> Double {
        let referenceMass = proteinReferenceMassKg(for: profile)
        let perKgFloor = Constants.fatMinimumPerKg * referenceMass
        let shareFloor = Constants.fatMinimumEnergyShare * max(0, kilocalories) / 9
        return max(perKgFloor, shareFloor).rounded()
    }

    // MARK: - Micronutrients

    /// Compares consumed micronutrients against the user's goals, falling back to the reference
    /// daily intake where no explicit goal exists.
    ///
    /// A nutrient the food data does not carry stays `isUnknown` and gets no fraction: the app must
    /// never draw an empty bar for missing data, because that reads as a deficiency the data cannot
    /// support. Results come back in `Micronutrient.allCases` order so the UI is stable.
    static func micronutrientStatus(consumed: Micronutrients, goals: Micronutrients) -> [MicronutrientStatus] {
        Micronutrient.allCases.map { nutrient in
            // A goal of zero means "not set" rather than "aim for none"; the model has no separate
            // sentinel and a real zero-intake goal is not something the app offers.
            let explicitGoal = goals[nutrient].flatMap { $0 > 0 ? $0 : nil }
            let reference = explicitGoal ?? nutrient.referenceDailyIntake
            let value = consumed[nutrient]
            var fraction: Double?
            if let value, let reference, reference > 0 {
                fraction = value / reference
            }
            return MicronutrientStatus(
                nutrient: nutrient,
                consumed: value,
                reference: reference,
                fraction: fraction,
                isUnknown: value == nil
            )
        }
    }
}
