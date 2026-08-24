import Foundation
import Testing
@testable import GymApp

/// Behavioural tests for `NutritionRecommendationEngine`.
///
/// Specification: `docs/fragments/nutrition.md` §1 (energy targets) and §2 (macronutrients).
/// Every assertion below is written against the documented behaviour, not against the current
/// implementation, so a regression in either direction reads as a sentence about what broke.
@Suite("Nutrition recommendation engine")
struct NutritionRecommendationTests {

    // MARK: - Fixtures

    /// A profile with every field named, so a test that changes one thing changes exactly one thing.
    private static func profile(
        sex: BiologicalSex = .male,
        age: Int? = 30,
        heightCm: Double = 180,
        weightKg: Double = 80,
        targetWeightKg: Double? = nil,
        activity: ActivityLevel = .moderate,
        goals: [TrainingGoal] = [.generalFitness],
        pace: NutritionGoalPace = .moderate,
        trainingDays: Int = 3
    ) -> NutritionProfileSnapshot {
        var snapshot = NutritionProfileSnapshot()
        snapshot.biologicalSex = sex
        snapshot.ageYears = age
        snapshot.heightCm = heightCm
        snapshot.weightKg = weightKg
        snapshot.targetWeightKg = targetWeightKg
        snapshot.activityLevel = activity
        snapshot.goals = goals
        snapshot.pace = pace
        snapshot.trainingDaysPerWeek = trainingDays
        return snapshot
    }

    private static func keys(_ targets: EnergyTargets) -> [String] {
        targets.explanations.map(\.key)
    }

    // MARK: - Mifflin-St Jeor

    @Test("Mifflin-St Jeor reproduces the published resting energy for a known male profile")
    func maleRestingEnergyMatchesPublishedValue() {
        // 10·80 + 6.25·180 − 5·30 + 5 = 1780
        let value = NutritionRecommendationEngine.basalMetabolicRate(
            profile: Self.profile(sex: .male, age: 30, heightCm: 180, weightKg: 80)
        )
        #expect(abs(value - 1780) < 0.0001)
    }

    @Test("Mifflin-St Jeor reproduces the published resting energy for a known female profile")
    func femaleRestingEnergyMatchesPublishedValue() {
        // 10·60 + 6.25·165 − 5·30 − 161 = 1320.25
        let value = NutritionRecommendationEngine.basalMetabolicRate(
            profile: Self.profile(sex: .female, age: 30, heightCm: 165, weightKg: 60)
        )
        #expect(abs(value - 1320.25) < 0.0001)
    }

    @Test("An unspecified sex lands strictly between the male and female resting energies")
    func unspecifiedSexSitsBetweenTheTwoConstants() {
        let male = NutritionRecommendationEngine.basalMetabolicRate(profile: Self.profile(sex: .male))
        let female = NutritionRecommendationEngine.basalMetabolicRate(profile: Self.profile(sex: .female))
        let unspecified = NutritionRecommendationEngine.basalMetabolicRate(
            profile: Self.profile(sex: .unspecified)
        )
        #expect(female < unspecified)
        #expect(unspecified < male)
        // Documented as the average of the two sex constants: (5 + −161) / 2 = −78.
        #expect(abs(unspecified - (male + female) / 2) < 0.0001)
        #expect(abs(unspecified - 1697) < 0.0001)
    }

    @Test("A missing age still produces a usable resting energy, using the documented default of 30")
    func missingAgeFallsBackToThirty() {
        let withoutAge = Self.profile(age: nil)
        let withThirty = Self.profile(age: 30)
        let fallback = NutritionRecommendationEngine.basalMetabolicRate(profile: withoutAge)

        #expect(fallback > 0)
        #expect(fallback.isFinite)
        #expect(abs(fallback - NutritionRecommendationEngine.basalMetabolicRate(profile: withThirty)) < 0.0001)
    }

    @Test("A missing age is named in the explanations rather than silently assumed")
    func missingAgeIsExplained() {
        let targets = NutritionRecommendationEngine.targets(for: Self.profile(age: nil))
        #expect(Self.keys(targets).contains("nutrition.energy.bmrDefaultAge"))
        #expect(!Self.keys(NutritionRecommendationEngine.targets(for: Self.profile(age: 30)))
            .contains("nutrition.energy.bmrDefaultAge"))
    }

    @Test("An unspecified sex is named in the explanations")
    func unspecifiedSexIsExplained() {
        let targets = NutritionRecommendationEngine.targets(for: Self.profile(sex: .unspecified))
        #expect(Self.keys(targets).contains("nutrition.energy.bmrUnspecifiedSex"))
    }

    @Test("Implausible ages, masses and heights are clamped instead of producing nonsense")
    func inputsAreClampedToPlausibleRanges() {
        // Age below 14 and above 100 clamp to the documented bounds.
        #expect(
            NutritionRecommendationEngine.basalMetabolicRate(profile: Self.profile(age: 2))
            == NutritionRecommendationEngine.basalMetabolicRate(profile: Self.profile(age: 14))
        )
        #expect(
            NutritionRecommendationEngine.basalMetabolicRate(profile: Self.profile(age: 250))
            == NutritionRecommendationEngine.basalMetabolicRate(profile: Self.profile(age: 100))
        )
        // Mass clamps at 30–300 kg, height at 120–230 cm.
        #expect(
            NutritionRecommendationEngine.basalMetabolicRate(profile: Self.profile(weightKg: 900))
            == NutritionRecommendationEngine.basalMetabolicRate(profile: Self.profile(weightKg: 300))
        )
        #expect(
            NutritionRecommendationEngine.basalMetabolicRate(profile: Self.profile(heightCm: 5))
            == NutritionRecommendationEngine.basalMetabolicRate(profile: Self.profile(heightCm: 120))
        )
        // And never dips under the documented 800 kcal guard.
        let tiny = NutritionRecommendationEngine.basalMetabolicRate(
            profile: Self.profile(sex: .female, age: 100, heightCm: 120, weightKg: 30)
        )
        #expect(tiny >= 800)
    }

    // MARK: - Maintenance

    @Test("Maintenance energy rises monotonically with activity level")
    func maintenanceRisesWithActivityLevel() {
        let ordered: [ActivityLevel] = [.sedentary, .light, .moderate, .active, .veryActive]
        let values = ordered.map {
            NutritionRecommendationEngine.totalDailyEnergyExpenditure(profile: Self.profile(activity: $0))
        }
        for index in 1..<values.count {
            #expect(
                values[index] > values[index - 1],
                "\(ordered[index]) must burn more than \(ordered[index - 1])"
            )
        }
    }

    @Test("Training sessions beyond the third add 1.2% of maintenance each, capping at four")
    func trainingUpliftIsSmallAndCapped() {
        let baseline = NutritionRecommendationEngine.totalDailyEnergyExpenditure(
            profile: Self.profile(trainingDays: 3)
        )
        let three = NutritionRecommendationEngine.totalDailyEnergyExpenditure(
            profile: Self.profile(trainingDays: 0)
        )
        #expect(abs(baseline - three) < 0.0001, "fewer than three sessions earns no uplift")

        let five = NutritionRecommendationEngine.totalDailyEnergyExpenditure(
            profile: Self.profile(trainingDays: 5)
        )
        #expect(abs(five / baseline - 1.024) < 0.0001)

        let seven = NutritionRecommendationEngine.totalDailyEnergyExpenditure(
            profile: Self.profile(trainingDays: 7)
        )
        let absurd = NutritionRecommendationEngine.totalDailyEnergyExpenditure(
            profile: Self.profile(trainingDays: 40)
        )
        #expect(abs(seven / baseline - 1.048) < 0.0001, "the uplift caps at +4.8%")
        #expect(abs(seven - absurd) < 0.0001, "a nonsense training week cannot inflate maintenance")
    }

    // MARK: - Direction

    @Test("A neutral goal is steered by a target weight more than 2 kg away")
    func targetWeightSteersANeutralGoal() {
        let neutral = Self.profile(goals: [.generalFitness], targetWeightKg: nil)
        #expect(NutritionRecommendationEngine.resolvedDirection(for: neutral) == .maintenance)

        var wantsToLose = Self.profile(goals: [.generalFitness])
        wantsToLose.targetWeightKg = 72   // 8 kg below 80
        #expect(NutritionRecommendationEngine.resolvedDirection(for: wantsToLose) == .deficit)

        var wantsToGain = Self.profile(goals: [.generalFitness])
        wantsToGain.targetWeightKg = 88
        #expect(NutritionRecommendationEngine.resolvedDirection(for: wantsToGain) == .surplus)

        var insideNoiseFloor = Self.profile(goals: [.generalFitness])
        insideNoiseFloor.targetWeightKg = 78.5   // 1.5 kg — inside the scale's noise floor
        #expect(NutritionRecommendationEngine.resolvedDirection(for: insideNoiseFloor) == .maintenance)
    }

    @Test("An explicit goal outranks the target weight")
    func explicitGoalWinsOverTargetWeight() {
        var profile = Self.profile(goals: [.loseFat])
        profile.targetWeightKg = 95
        #expect(NutritionRecommendationEngine.resolvedDirection(for: profile) == .deficit)
    }

    @Test("A surplus is capped at 0.5% of body mass a week however fast the pace")
    func surplusPaceIsCapped() {
        let fast = Self.profile(goals: [.buildMuscle], pace: .fast)
        let moderate = Self.profile(goals: [.buildMuscle], pace: .moderate)
        let fastRate = NutritionRecommendationEngine.intendedWeeklyBodyMassChangeKg(
            profile: fast, direction: .surplus
        )
        let moderateRate = NutritionRecommendationEngine.intendedWeeklyBodyMassChangeKg(
            profile: moderate, direction: .surplus
        )
        #expect(abs(fastRate - moderateRate) < 0.0001)
        #expect(abs(fastRate - 0.4) < 0.0001)   // 0.5% of 80 kg
    }

    @Test("Recomposition runs at half the chosen pace")
    func recompositionHalvesThePace() {
        let profile = Self.profile(pace: .moderate)
        let deficit = NutritionRecommendationEngine.intendedWeeklyBodyMassChangeKg(
            profile: profile, direction: .deficit
        )
        let recomp = NutritionRecommendationEngine.intendedWeeklyBodyMassChangeKg(
            profile: profile, direction: .slightDeficit
        )
        #expect(abs(recomp - deficit / 2) < 0.0001)
    }

    // MARK: - Safety floors

    @Test("The absolute floor is 1200 kcal for a woman, 1500 for a man, and the higher of the two when unstated")
    func absoluteFloorsFollowTheDocumentedAsymmetry() {
        // A profile whose resting-energy floor cannot bind, so the absolute floor is what shows.
        let small = Self.profile(age: 80, heightCm: 150, weightKg: 45, activity: .sedentary)
        var female = small; female.biologicalSex = .female
        var male = small; male.biologicalSex = .male
        var unspecified = small; unspecified.biologicalSex = .unspecified

        #expect(NutritionRecommendationEngine.safeMinimumKilocalories(for: female) == 1200)
        #expect(NutritionRecommendationEngine.safeMinimumKilocalories(for: male) == 1500)
        #expect(
            NutritionRecommendationEngine.safeMinimumKilocalories(for: unspecified) == 1500,
            "an unstated sex must take the higher floor, because too low risks under-eating"
        )
    }

    @Test("An aggressive deficit for a small person never returns an unsafe calorie target")
    func aggressiveDeficitNeverGoesBelowTheFloor() {
        let sexes: [BiologicalSex] = [.male, .female, .unspecified]
        let paces: [NutritionGoalPace] = [.slow, .moderate, .fast]
        let masses: [Double] = [42, 48, 55]
        let heights: [Double] = [148, 158, 168]

        for sex in sexes {
            for pace in paces {
                for mass in masses {
                    for height in heights {
                        let profile = Self.profile(
                            sex: sex, age: 62, heightCm: height, weightKg: mass,
                            activity: .sedentary, goals: [.loseFat], pace: pace, trainingDays: 2
                        )
                        let targets = NutritionRecommendationEngine.targets(for: profile)
                        let floor = NutritionRecommendationEngine.safeMinimumKilocalories(for: profile)
                        let absolute: Double = sex == .female ? 1200 : 1500

                        #expect(
                            targets.kilocalories >= floor,
                            "\(sex)/\(pace)/\(mass)kg/\(height)cm was given \(targets.kilocalories) kcal, under its \(floor) kcal floor"
                        )
                        #expect(targets.kilocalories >= absolute)
                        #expect(
                            targets.kilocalories >= NutritionRecommendationEngine
                                .basalMetabolicRate(profile: profile) * 1.1
                        )
                    }
                }
            }
        }
    }

    @Test("Rounding onto the 10 kcal grid never carries the target back under the floor")
    func roundingNeverBreaksTheFloor() {
        // 1320.25 × 1.1 = 1452.275, which a plain `.rounded()` would send to 1450.
        let profile = Self.profile(
            sex: .female, age: 30, heightCm: 165, weightKg: 60,
            activity: .sedentary, goals: [.loseFat], pace: .fast
        )
        let targets = NutritionRecommendationEngine.targets(for: profile)
        let floor = NutritionRecommendationEngine.safeMinimumKilocalories(for: profile)

        #expect(abs(floor - 1452.275) < 0.0001)
        #expect(targets.kilocalories >= floor)
        #expect(targets.kilocalories == 1460)
        #expect(Self.keys(targets).contains("nutrition.energy.floorApplied"))
    }

    @Test("The daily offset is capped at −1000 / +700 kcal before anything else")
    func dailyOffsetIsCapped() {
        // 0.75% of 300 kg is 2.25 kg/week, which asks for ~2475 kcal/day of deficit.
        let heavy = Self.profile(
            sex: .male, age: 30, heightCm: 190, weightKg: 300,
            activity: .veryActive, goals: [.loseFat], pace: .fast, trainingDays: 6
        )
        let targets = NutritionRecommendationEngine.targets(for: heavy)
        let maintenance = NutritionRecommendationEngine.totalDailyEnergyExpenditure(profile: heavy)
        #expect(maintenance - targets.kilocalories <= 1000 + 5)
        #expect(Self.keys(targets).contains("nutrition.energy.deficitCapped"))
    }

    @Test("When the floor lands above maintenance the app says so instead of claiming a deficit")
    func floorAboveMaintenanceIsStatedHonestly() {
        // Small, old and sedentary: maintenance ≈ 960 kcal, below the 1200 kcal absolute floor.
        let profile = Self.profile(
            sex: .female, age: 70, heightCm: 145, weightKg: 40,
            activity: .sedentary, goals: [.loseFat], pace: .moderate, trainingDays: 0
        )
        let targets = NutritionRecommendationEngine.targets(for: profile)
        let maintenance = NutritionRecommendationEngine.totalDailyEnergyExpenditure(profile: profile)

        #expect(targets.kilocalories > maintenance)
        #expect(Self.keys(targets).contains("nutrition.energy.floorAboveMaintenance"))
        #expect(!Self.keys(targets).contains("nutrition.energy.deficit"))
        #expect(
            !Self.keys(targets).contains("nutrition.macro.proteinDeficit"),
            "a deficit that does not exist must not earn the deficit protein bump"
        )
        #expect(targets.direction == .deficit, "the recorded intent is still what the user asked for")
    }

    @Test("A surplus raised by the floor keeps its surplus sentence rather than the fat-loss advice")
    func floorOnASurplusKeepsTheSurplusExplanation() {
        let profile = Self.profile(
            sex: .female, age: 70, heightCm: 145, weightKg: 40,
            activity: .sedentary, goals: [.buildMuscle], pace: .moderate, trainingDays: 0
        )
        let targets = NutritionRecommendationEngine.targets(for: profile)
        let keys = Self.keys(targets)
        #expect(keys.contains("nutrition.energy.surplus"))
        #expect(keys.contains("nutrition.energy.floorApplied"))
        #expect(!keys.contains("nutrition.energy.floorAboveMaintenance"))
    }

    @Test("The weekly rate describes the calories actually given, not the ones asked for")
    func weeklyRateIsRecomputedAfterClamping() {
        let profile = Self.profile(
            sex: .female, age: 30, heightCm: 165, weightKg: 60,
            activity: .sedentary, goals: [.loseFat], pace: .fast
        )
        let targets = NutritionRecommendationEngine.targets(for: profile)
        let maintenance = NutritionRecommendationEngine.totalDailyEnergyExpenditure(profile: profile)
        let implied = (targets.kilocalories - maintenance) * 7 / 7_700

        #expect(abs(targets.weeklyBodyMassChangeKg - implied) < 0.01)
        // The pace asked for −0.45 kg/week; the floor made that impossible.
        #expect(targets.weeklyBodyMassChangeKg > -0.45)
    }

    @Test("Every target set ends with the estimate disclaimer")
    func everyTargetCarriesTheDisclaimer() {
        let goals: [TrainingGoal] = TrainingGoal.allCases
        for goal in goals {
            let targets = NutritionRecommendationEngine.targets(for: Self.profile(goals: [goal]))
            #expect(
                targets.explanations.last?.key == "nutrition.energy.estimateDisclaimer",
                "goal \(goal) did not end with the disclaimer"
            )
        }
    }

    // MARK: - Macronutrients

    @Test("Protein lands inside the documented 1.6–2.2 g/kg band")
    func proteinStaysInsideItsBand() {
        let goals: [TrainingGoal] = [.buildMuscle, .loseFat, .recomposition, .buildStrength, .maintain]
        let activities: [ActivityLevel] = [.sedentary, .moderate, .veryActive]
        for goal in goals {
            for activity in activities {
                for days in [2, 5] {
                    let profile = Self.profile(
                        sex: .male, heightCm: 180, weightKg: 80,
                        activity: activity, goals: [goal], trainingDays: days
                    )
                    let targets = NutritionRecommendationEngine.targets(for: profile)
                    let reference = NutritionRecommendationEngine.proteinReferenceMassKg(for: profile)
                    let perKg = targets.proteinG / reference
                    // Protein rounds to 5 g, which is 0.0625 g/kg at 80 kg.
                    let slack = 5.0 / reference
                    #expect(
                        perKg >= 1.6 - slack && perKg <= 2.2 + slack,
                        "\(goal)/\(activity)/\(days)d prescribed \(perKg) g/kg, outside the 1.6–2.2 band"
                    )
                }
            }
        }
    }

    @Test("A deficit and a muscle goal each raise protein inside the band")
    func proteinIncrementsFollowTheDocumentedRules() {
        let base = Self.profile(goals: [.generalFitness], trainingDays: 2)
        #expect(NutritionRecommendationEngine.proteinPerKilogram(profile: base, direction: .maintenance) == 1.6)

        let deficit = NutritionRecommendationEngine.proteinPerKilogram(profile: base, direction: .deficit)
        #expect(abs(deficit - 1.9) < 0.0001)

        let muscle = Self.profile(goals: [.buildMuscle], trainingDays: 2)
        #expect(abs(
            NutritionRecommendationEngine.proteinPerKilogram(profile: muscle, direction: .maintenance) - 1.8
        ) < 0.0001)

        let heavyLoad = Self.profile(goals: [.buildMuscle], trainingDays: 5)
        #expect(abs(
            NutritionRecommendationEngine.proteinPerKilogram(profile: heavyLoad, direction: .maintenance) - 1.9
        ) < 0.0001)

        // Everything at once still clamps back into the band.
        let everything = Self.profile(activity: .veryActive, goals: [.buildMuscle], trainingDays: 6)
        #expect(
            NutritionRecommendationEngine.proteinPerKilogram(profile: everything, direction: .deficit) == 2.2
        )
    }

    @Test("Above BMI 30 protein is prescribed off an adjusted body mass, not scale mass")
    func adjustedBodyMassAppliesAboveBMI30() {
        let obese = Self.profile(sex: .male, heightCm: 170, weightKg: 120, goals: [.loseFat])
        #expect(NutritionRecommendationEngine.usesAdjustedMass(obese))

        // reference at BMI 25 = 25 × 1.7² = 72.25 kg; adjusted = 72.25 + 0.4 × (120 − 72.25) = 91.35
        let reference = NutritionRecommendationEngine.proteinReferenceMassKg(for: obese)
        #expect(abs(reference - 91.35) < 0.0001)
        #expect(reference < 120)

        let targets = NutritionRecommendationEngine.targets(for: obese)
        #expect(Self.keys(targets).contains("nutrition.macro.proteinAdjustedMass"))
        #expect(targets.proteinG < 2.2 * 120, "scale mass would prescribe a number nobody eats")

        // Below the threshold, scale mass is used unchanged.
        let lean = Self.profile(sex: .male, heightCm: 180, weightKg: 80)
        #expect(!NutritionRecommendationEngine.usesAdjustedMass(lean))
        #expect(NutritionRecommendationEngine.proteinReferenceMassKg(for: lean) == 80)
    }

    @Test("An implausible height skips the adjusted-mass correction rather than guessing")
    func implausibleHeightSkipsAdjustedMass() {
        var profile = Self.profile(weightKg: 120)
        profile.heightCm = 0
        #expect(profile.bodyMassIndex == nil)
        #expect(!NutritionRecommendationEngine.usesAdjustedMass(profile))
        #expect(NutritionRecommendationEngine.proteinReferenceMassKg(for: profile) == 120)
    }

    @Test("Fat respects both of its floors: 0.6 g/kg and 20% of energy")
    func fatRespectsItsFloor() {
        let profiles = [
            Self.profile(sex: .male, weightKg: 80, goals: [.loseFat], pace: .fast),
            Self.profile(sex: .female, heightCm: 165, weightKg: 60, goals: [.loseFat], pace: .fast),
            Self.profile(sex: .male, weightKg: 95, goals: [.buildMuscle]),
            Self.profile(sex: .male, weightKg: 80, goals: [.recomposition])
        ]
        for profile in profiles {
            let targets = NutritionRecommendationEngine.targets(for: profile)
            let floor = NutritionRecommendationEngine.fatFloorGrams(
                kilocalories: targets.kilocalories, profile: profile
            )
            #expect(
                targets.fatG >= floor - 0.5,
                "fat \(targets.fatG) g fell under its \(floor) g floor"
            )
            #expect(targets.fatG * 9 >= 0.20 * targets.kilocalories - 5)
        }
    }

    @Test("Fat carries a larger share at maintenance than in a deficit or a surplus")
    func fatShareFollowsDirection() {
        #expect(NutritionRecommendationEngine.fatEnergyShare(direction: .deficit) == 0.25)
        #expect(NutritionRecommendationEngine.fatEnergyShare(direction: .surplus) == 0.25)
        #expect(NutritionRecommendationEngine.fatEnergyShare(direction: .maintenance) == 0.27)
        #expect(NutritionRecommendationEngine.fatEnergyShare(direction: .slightDeficit) == 0.27)
    }

    @Test("Carbohydrate is never negative and the three macros reconstruct the calorie target")
    func macrosAreNonNegativeAndReconstructTheTarget() {
        let sexes: [BiologicalSex] = [.male, .female, .unspecified]
        let goals: [TrainingGoal] = TrainingGoal.allCases
        let paces: [NutritionGoalPace] = [.slow, .moderate, .fast]
        let bodies: [(Double, Double)] = [(150, 42), (165, 60), (180, 80), (170, 120), (195, 140)]

        for sex in sexes {
            for goal in goals {
                for pace in paces {
                    for (height, mass) in bodies {
                        let profile = Self.profile(
                            sex: sex, heightCm: height, weightKg: mass,
                            goals: [goal], pace: pace, trainingDays: 4
                        )
                        let targets = NutritionRecommendationEngine.targets(for: profile)
                        let label = "\(sex)/\(goal)/\(pace)/\(mass)kg"

                        #expect(targets.proteinG >= 0, "negative protein for \(label)")
                        #expect(targets.carbsG >= 0, "negative carbohydrate for \(label)")
                        #expect(targets.fatG >= 0, "negative fat for \(label)")

                        let derived = targets.macros.derivedKilocalories
                        #expect(
                            abs(derived - targets.kilocalories) <= 25,
                            "\(label): macros derive \(derived) kcal against a \(targets.kilocalories) kcal headline"
                        )
                    }
                }
            }
        }
    }

    @Test("A very low calorie budget walks protein back to its floor instead of emitting negative carbs")
    func lowCalorieBudgetTrimsProteinRatherThanGoingNegative() {
        // 120 kg at 170 cm on a 1200 kcal budget: 2.0 g/kg of the adjusted 91.35 kg mass is 185 g,
        // which together with the fat floor alone overspends the budget.
        let profile = Self.profile(sex: .male, heightCm: 170, weightKg: 120, goals: [.loseFat])
        let split = NutritionRecommendationEngine.macros(
            kilocalories: 1200, profile: profile, direction: .deficit
        )
        let keys = split.explanations.map(\.key)
        let reference = NutritionRecommendationEngine.proteinReferenceMassKg(for: profile)

        #expect(split.carbsG >= 0)
        #expect(split.proteinG >= 0)
        #expect(split.fatG >= 0)
        #expect(keys.contains("nutrition.macro.proteinCompromise"), "the trim must be explained")
        #expect(
            split.proteinG / reference < 2.0,
            "protein must be walked back towards its 1.6 g/kg floor"
        )
        #expect(split.proteinG / reference >= 1.6 - 5.0 / reference)
    }

    @Test("When both floors together exceed the budget, macros scale down instead of going negative")
    func impossibleBudgetScalesBothFloorsProportionally() {
        let profile = Self.profile(sex: .male, heightCm: 170, weightKg: 120, goals: [.loseFat])
        let split = NutritionRecommendationEngine.macros(
            kilocalories: 800, profile: profile, direction: .deficit
        )
        let keys = split.explanations.map(\.key)

        #expect(split.carbsG == 0)
        #expect(split.proteinG >= 0)
        #expect(split.fatG >= 0)
        #expect(keys.contains("nutrition.macro.lowCalorieCompromise"), "the compromise must be explained")
        #expect(abs(split.proteinG * 4 + split.fatG * 9 - 800) <= 25)
    }

    @Test("A zero calorie budget produces zeroes, not negatives")
    func zeroBudgetProducesNoNegativeMacros() {
        let profile = Self.profile()
        let split = NutritionRecommendationEngine.macros(
            kilocalories: 0, profile: profile, direction: .maintenance
        )
        #expect(split.proteinG >= 0)
        #expect(split.carbsG >= 0)
        #expect(split.fatG >= 0)
    }

    @Test("A negative calorie budget is floored at zero rather than inverted")
    func negativeBudgetIsFlooredAtZero() {
        let profile = Self.profile()
        let split = NutritionRecommendationEngine.macros(
            kilocalories: -500, profile: profile, direction: .maintenance
        )
        #expect(split.proteinG >= 0)
        #expect(split.carbsG >= 0)
        #expect(split.fatG >= 0)
    }

    // MARK: - Energy shares

    @Test("Energy shares sum to one and survive a clamped target")
    func energySharesReconstructTheSplit() {
        let profile = Self.profile(goals: [.buildMuscle], trainingDays: 4)
        let targets = NutritionRecommendationEngine.targets(for: profile)
        let shares = targets.energyShares
        #expect(abs(shares.protein + shares.carbs + shares.fat - 1) < 0.0001)
        #expect(shares.protein > 0 && shares.carbs > 0 && shares.fat > 0)
    }

    @Test("Energy shares of an empty target set do not divide by zero")
    func energySharesOfEmptyTargetsAreSafe() {
        let shares = EnergyTargets().energyShares
        #expect(shares.protein == 0)
        #expect(shares.carbs == 0)
        #expect(shares.fat == 0)
    }

    // MARK: - Micronutrient status

    @Test("A micronutrient with no data stays unknown rather than reading as a shortfall")
    func unknownMicronutrientsAreNotDrawnAsZero() {
        var consumed = Micronutrients.unknown
        consumed.ironMg = 7
        let statuses = NutritionRecommendationEngine.micronutrientStatus(
            consumed: consumed, goals: .unknown
        )
        let iron = statuses.first { $0.nutrient == .iron }
        let calcium = statuses.first { $0.nutrient == .calcium }

        #expect(iron?.isUnknown == false)
        #expect(abs((iron?.fraction ?? 0) - 0.5) < 0.0001)   // 7 of the 14 mg reference
        #expect(calcium?.isUnknown == true)
        #expect(calcium?.fraction == nil, "an unknown nutrient must not be drawn as an empty bar")
    }

    @Test("An explicit micronutrient goal outranks the reference intake, but a zero goal does not")
    func explicitMicronutrientGoalsWin() {
        var consumed = Micronutrients.unknown
        consumed.ironMg = 7
        var goals = Micronutrients.unknown
        goals.ironMg = 28
        let withGoal = NutritionRecommendationEngine.micronutrientStatus(consumed: consumed, goals: goals)
            .first { $0.nutrient == .iron }
        #expect(abs((withGoal?.fraction ?? 0) - 0.25) < 0.0001)

        var zeroGoal = Micronutrients.unknown
        zeroGoal.ironMg = 0
        let withZero = NutritionRecommendationEngine.micronutrientStatus(consumed: consumed, goals: zeroGoal)
            .first { $0.nutrient == .iron }
        #expect(
            abs((withZero?.fraction ?? 0) - 0.5) < 0.0001,
            "a zero goal means 'not set', not 'aim for none'"
        )
    }

    @Test("Micronutrient status comes back in a stable order")
    func micronutrientStatusOrderIsStable() {
        let statuses = NutritionRecommendationEngine.micronutrientStatus(
            consumed: .unknown, goals: .unknown
        )
        #expect(statuses.map(\.nutrient) == Micronutrient.allCases)
    }
}
