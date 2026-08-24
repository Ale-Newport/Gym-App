import Foundation
import Testing
@testable import GymApp

/// Behavioural tests for `NutritionAdjustmentEngine`.
///
/// Specification: `docs/fragments/nutrition.md` §4. The engine is slow, small and never applies
/// anything by itself, and every test below is written against one of those three promises.
/// `now` is always supplied, so nothing here depends on the wall clock.
@Suite("Nutrition adjustment engine")
struct NutritionAdjustmentTests {

    // MARK: - Fixtures

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// An 80 kg male bulking on 3,230 kcal — the target set `NutritionRecommendationEngine`
    /// produces for this profile, written out so the test reads without running the other engine.
    private static var bulkingProfile: NutritionProfileSnapshot {
        var profile = NutritionProfileSnapshot()
        profile.biologicalSex = .male
        profile.ageYears = 30
        profile.heightCm = 180
        profile.weightKg = 80
        profile.activityLevel = .moderate
        profile.goals = [.buildMuscle]
        profile.trainingDaysPerWeek = 4
        return profile
    }

    private static func bulkingTargets(
        kilocalories: Double = 3_230,
        weeklyChange: Double = 0.4
    ) -> EnergyTargets {
        EnergyTargets(
            basalMetabolicRate: 1_780,
            totalDailyEnergyExpenditure: 2_792,
            kilocalories: kilocalories,
            proteinG: 145,
            carbsG: 460,
            fatG: 90,
            direction: .surplus,
            weeklyBodyMassChangeKg: weeklyChange,
            explanations: []
        )
    }

    /// A 60 kg woman cutting on 1,600 kcal.
    private static var cuttingProfile: NutritionProfileSnapshot {
        var profile = NutritionProfileSnapshot()
        profile.biologicalSex = .female
        profile.ageYears = 30
        profile.heightCm = 165
        profile.weightKg = 60
        profile.activityLevel = .sedentary
        profile.goals = [.loseFat]
        profile.trainingDaysPerWeek = 3
        return profile
    }

    private static func cuttingTargets(
        kilocalories: Double = 1_600,
        weeklyChange: Double = -0.3
    ) -> EnergyTargets {
        EnergyTargets(
            basalMetabolicRate: 1_320,
            totalDailyEnergyExpenditure: 1_584,
            kilocalories: kilocalories,
            proteinG: 120,
            carbsG: 155,
            fatG: 45,
            direction: .deficit,
            weeklyBodyMassChangeKg: weeklyChange,
            explanations: []
        )
    }

    /// A usable trend: ten-plus readings, a fresh newest point, and good confidence unless told
    /// otherwise.
    private static func trend(
        observedWeekly: Double?,
        confidence: Double = 0.9,
        hasEnoughData: Bool = true,
        newestDaysAgo: Double = 1
    ) -> WeightTrendAnalysis {
        WeightTrendAnalysis(
            movingAverage: [
                WeightTrendPoint(
                    date: now.addingTimeInterval(-newestDaysAgo * 86_400), weightKg: 80
                )
            ],
            currentTrendKg: 80,
            weeklyChangeKg: observedWeekly,
            weeksOfData: 3,
            confidence: confidence,
            hasEnoughData: hasEnoughData
        )
    }

    private static func evaluate(
        current: EnergyTargets,
        profile: NutritionProfileSnapshot,
        observedWeekly: Double?,
        confidence: Double = 0.9,
        hasEnoughData: Bool = true,
        newestDaysAgo: Double = 1,
        adherence: Double? = 0.95,
        daysSinceLastAdjustment: Int = 21
    ) -> CalorieAdjustmentDecision {
        NutritionAdjustmentEngine.evaluate(
            current: current,
            trend: trend(
                observedWeekly: observedWeekly,
                confidence: confidence,
                hasEnoughData: hasEnoughData,
                newestDaysAgo: newestDaysAgo
            ),
            profile: profile,
            adherence: adherence,
            daysSinceLastAdjustment: daysSinceLastAdjustment,
            now: now
        )
    }

    // MARK: - Gates

    @Test("Too little weight data reports insufficientData rather than guessing")
    func insufficientDataIsReportedNotGuessed() {
        let noSlope = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile, observedWeekly: nil
        )
        #expect(noSlope.action == .insufficientData)
        #expect(noSlope.explanation.key == "nutrition.adjust.insufficientData")

        let notEnough = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile,
            observedWeekly: 0, hasEnoughData: false
        )
        #expect(notEnough.action == .insufficientData)
    }

    @Test("A trend whose newest point is over ten days old is treated as stale")
    func staleTrendIsRejected() {
        let stale = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile,
            observedWeekly: 0, newestDaysAgo: 11
        )
        #expect(stale.action == .insufficientData)
        #expect(stale.explanation.key == "nutrition.adjust.staleData")

        let fresh = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile,
            observedWeekly: 0, newestDaysAgo: 9
        )
        #expect(fresh.action != .insufficientData)
    }

    @Test("Low confidence holds instead of acting on noise")
    func lowConfidenceHolds() {
        let decision = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile,
            observedWeekly: 0, confidence: 0.2
        )
        #expect(decision.action == .hold)
        #expect(decision.explanation.key == "nutrition.adjust.lowConfidence")
        #expect(decision.deltaKilocalories == 0)
        #expect(decision.newTargets == nil)
    }

    @Test("No change is proposed before fourteen days have passed since the last one")
    func nothingChangesInsideTheWaitingPeriod() {
        for days in [0, 5, 13] {
            let decision = Self.evaluate(
                current: Self.bulkingTargets(), profile: Self.bulkingProfile,
                observedWeekly: 0, daysSinceLastAdjustment: days
            )
            #expect(decision.action == .hold, "day \(days) should still be inside the waiting period")
            #expect(decision.explanation.key == "nutrition.adjust.tooSoon")
            #expect(decision.deltaKilocalories == 0)
            #expect(decision.newTargets == nil)
        }

        // Fourteen days is the first day a change may be proposed.
        let onTheBoundary = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile,
            observedWeekly: 0, daysSinceLastAdjustment: 14
        )
        #expect(onTheBoundary.action == .increase)
    }

    @Test("Low adherence yields a hold, because the trend cannot be blamed on the target")
    func lowAdherenceHolds() {
        let decision = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile,
            observedWeekly: 0, adherence: 0.5
        )
        #expect(decision.action == .hold)
        #expect(decision.explanation.key == "nutrition.adjust.lowAdherence")
        #expect(decision.newTargets == nil)
    }

    @Test("Unknown adherence does not block a change")
    func unknownAdherenceDoesNotBlock() {
        let decision = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile,
            observedWeekly: 0, adherence: nil
        )
        #expect(decision.action == .increase, "nil adherence means 'cannot tell', not 'zero'")
    }

    @Test("Adherence at the 80% bar is good enough to act on")
    func adherenceAtTheBoundaryIsAccepted() {
        let decision = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile,
            observedWeekly: 0, adherence: 0.8
        )
        #expect(decision.action == .increase)
    }

    // MARK: - Tolerance band

    @Test("Nothing changes while the observed rate sits inside the tolerance band")
    func insideToleranceHolds() {
        // Target +0.4 kg/week, tolerance = max(0.15, 0.12) × (2 − 0.9) = 0.165 kg/week.
        for observed in [0.4, 0.35, 0.45, 0.25, 0.55] {
            let decision = Self.evaluate(
                current: Self.bulkingTargets(), profile: Self.bulkingProfile,
                observedWeekly: observed
            )
            #expect(decision.action == .hold, "observed \(observed) should read as on track")
            #expect(decision.explanation.key == "nutrition.adjust.onTrack")
            #expect(decision.deltaKilocalories == 0)
            #expect(decision.newTargets == nil)
        }
    }

    @Test("The tolerance band widens as confidence falls, so noisy data makes the engine more reluctant")
    func toleranceWidensWithPoorConfidence() {
        let confident = NutritionAdjustmentEngine.toleranceKgPerWeek(targetWeekly: 0.4, confidence: 1.0)
        let unsure = NutritionAdjustmentEngine.toleranceKgPerWeek(targetWeekly: 0.4, confidence: 0.35)
        #expect(unsure > confident)
        #expect(abs(confident - 0.15) < 0.0001)
        #expect(abs(unsure - 0.15 * 1.65) < 0.0001)

        // The proportional term takes over for aggressive targets.
        let aggressive = NutritionAdjustmentEngine.toleranceKgPerWeek(targetWeekly: -1.0, confidence: 1.0)
        #expect(abs(aggressive - 0.30) < 0.0001)

        // A zero target still gets the 0.15 kg/week floor rather than a zero-width band.
        #expect(
            abs(NutritionAdjustmentEngine.toleranceKgPerWeek(targetWeekly: 0, confidence: 1.0) - 0.15)
            < 0.0001
        )
    }

    // MARK: - Increases and decreases

    @Test("A bulk that has stalled for weeks earns an increase")
    func stalledBulkEarnsAnIncrease() {
        let decision = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile, observedWeekly: 0
        )
        #expect(decision.action == .increase)
        #expect(decision.deltaKilocalories > 0)
        #expect(decision.explanation.key == "nutrition.adjust.increase")

        let newTargets = decision.newTargets
        #expect(newTargets != nil)
        #expect((newTargets?.kilocalories ?? 0) > 3_230)
        // Half of a 0.4 kg/week gap is 220 kcal, inside the 5–10% band and under the ±250 cap.
        #expect(abs(decision.deltaKilocalories - 220) < 0.0001)
        #expect(abs((newTargets?.kilocalories ?? 0) - 3_450) < 0.0001)
    }

    @Test("Gaining far faster than intended earns a decrease")
    func runawayGainEarnsADecrease() {
        let decision = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile, observedWeekly: 1.2
        )
        #expect(decision.action == .decrease)
        #expect(decision.deltaKilocalories < 0)
        #expect(decision.explanation.key == "nutrition.adjust.decrease")
        #expect((decision.newTargets?.kilocalories ?? 0) < 3_230)
    }

    @Test("Losing far faster than intended on a cut earns an increase")
    func runawayLossOnACutEarnsAnIncrease() {
        let decision = Self.evaluate(
            current: Self.cuttingTargets(), profile: Self.cuttingProfile, observedWeekly: -1.2
        )
        #expect(decision.action == .increase)
        #expect(decision.deltaKilocalories > 0)
    }

    @Test("Every proposed change is capped at 10% of intake and at 250 kcal")
    func changesAreAlwaysCapped() {
        let scenarios: [(EnergyTargets, NutritionProfileSnapshot, Double)] = [
            (Self.bulkingTargets(), Self.bulkingProfile, 4.0),
            (Self.bulkingTargets(), Self.bulkingProfile, -4.0),
            (Self.cuttingTargets(), Self.cuttingProfile, 3.0),
            (Self.cuttingTargets(), Self.cuttingProfile, -3.0)
        ]
        for (current, profile, observed) in scenarios {
            let decision = Self.evaluate(
                current: current, profile: profile, observedWeekly: observed
            )
            let cap = min(0.10 * current.kilocalories, 250)
            // Plus five, because the proposal is rounded onto the 10 kcal grid at the very end.
            #expect(
                abs(decision.deltaKilocalories) <= cap + 5,
                "a \(observed) kg/week gap produced a \(decision.deltaKilocalories) kcal change against a \(cap) kcal cap"
            )
        }
    }

    @Test("A tiny correction is dropped rather than put in front of the user")
    func negligibleCorrectionsAreDropped() {
        // A target that sits one kcal under the ceiling has nowhere useful to go.
        let ceiling = 2_792.0 + 750
        var current = Self.bulkingTargets(kilocalories: ceiling - 1)
        current.weeklyBodyMassChangeKg = 0.4
        let decision = Self.evaluate(
            current: current, profile: Self.bulkingProfile, observedWeekly: 0
        )
        #expect(decision.action == .hold)
        #expect(decision.deltaKilocalories == 0)
        #expect(decision.newTargets == nil)
    }

    @Test("The engine will not push intake past maintenance plus 750 kcal")
    func surplusCeilingIsRespected() {
        let current = Self.bulkingTargets(kilocalories: 3_300)
        let decision = Self.evaluate(
            current: current, profile: Self.bulkingProfile, observedWeekly: -0.5
        )
        if let proposed = decision.newTargets?.kilocalories {
            #expect(proposed <= max(current.kilocalories, 2_792 + 750) + 5)
        }
    }

    @Test("A zeroed maintenance figure is re-estimated instead of taken literally")
    func zeroMaintenanceIsReEstimated() {
        var current = Self.bulkingTargets()
        current.totalDailyEnergyExpenditure = 0
        let decision = Self.evaluate(
            current: current, profile: Self.bulkingProfile, observedWeekly: 0
        )
        let newTargets = decision.newTargets
        #expect(newTargets != nil)
        #expect(
            (newTargets?.totalDailyEnergyExpenditure ?? 0) > 2_000,
            "a zero maintenance means 'never recorded', not 'this person burns nothing'"
        )
        #expect(
            abs(newTargets?.weeklyBodyMassChangeKg ?? 0) < 1,
            "a literal zero maintenance would report a 1.7 kg a week gain"
        )
    }

    @Test("Somebody already eating at the floor and still losing is told calories are not the lever")
    func atTheFloorAndLosingHoldsRatherThanAskingThemToEatMore() {
        // The safety floor for this profile is 1,452 kcal; her target has been clamped to it.
        let current = Self.cuttingTargets(kilocalories: 1_460, weeklyChange: -0.08)
        let decision = Self.evaluate(
            current: current, profile: Self.cuttingProfile, observedWeekly: -0.4
        )
        #expect(decision.action == .hold)
        #expect(decision.explanation.key == "nutrition.adjust.floorReached")
        #expect(decision.newTargets == nil)
    }

    @Test("A proposed decrease never lands under the safety floor")
    func decreasesNeverBreakTheSafetyFloor() {
        let floor = NutritionRecommendationEngine.safeMinimumKilocalories(for: Self.cuttingProfile)
        for intake in [1_600.0, 1_700, 1_900, 2_400] {
            let current = Self.cuttingTargets(kilocalories: intake, weeklyChange: -0.3)
            let decision = Self.evaluate(
                current: current, profile: Self.cuttingProfile, observedWeekly: 0.6
            )
            if let proposed = decision.newTargets?.kilocalories {
                #expect(
                    proposed >= floor - 5,
                    "an intake of \(intake) was cut to \(proposed), under the \(floor) kcal floor"
                )
            }
        }
    }

    /// KNOWN PRODUCTION DEFECT — see the summary that accompanies these tests.
    ///
    /// `NutritionRecommendationEngine.targets` deliberately re-rounds *up* when the 10 kcal grid
    /// would carry a target back under the safety floor ("Energy rounds to 10 kcal away from the
    /// floor, never through it", `docs/fragments/nutrition.md` §1). The adjustment engine clamps to
    /// the same floor and then rounds with a plain `.rounded()`, so a floor that is not a multiple
    /// of ten is quietly breached by up to 5 kcal.
    ///
    /// Expected: the proposal is at least `safeMinimumKilocalories` (1,452.275 kcal here).
    /// Actual: 1,450 kcal.
    @Test("A floor-clamped proposal is rounded away from the floor, never through it")
    func flooredProposalIsNotRoundedBackThroughTheFloor() {
        let floor = NutritionRecommendationEngine.safeMinimumKilocalories(for: Self.cuttingProfile)
        #expect(abs(floor - 1_452.275) < 0.001, "the fixture depends on a non-round floor")

        let current = Self.cuttingTargets(kilocalories: 1_600, weeklyChange: -0.3)
        let decision = Self.evaluate(
            current: current, profile: Self.cuttingProfile, observedWeekly: 0.0
        )
        #expect(decision.action == .decrease)

        withKnownIssue("The adjustment engine rounds to 10 kcal after clamping to the floor") {
            let proposed = decision.newTargets?.kilocalories ?? 0
            #expect(
                proposed >= floor,
                "proposed \(proposed) kcal against a floor of \(floor) kcal"
            )
        }
    }

    // MARK: - Approval

    @Test("Every decision, including the ones that change nothing, requires user approval")
    func everyDecisionRequiresApproval() {
        let decisions: [CalorieAdjustmentDecision] = [
            Self.evaluate(current: Self.bulkingTargets(), profile: Self.bulkingProfile, observedWeekly: nil),
            Self.evaluate(
                current: Self.bulkingTargets(), profile: Self.bulkingProfile,
                observedWeekly: 0, hasEnoughData: false
            ),
            Self.evaluate(
                current: Self.bulkingTargets(), profile: Self.bulkingProfile,
                observedWeekly: 0, newestDaysAgo: 30
            ),
            Self.evaluate(
                current: Self.bulkingTargets(), profile: Self.bulkingProfile,
                observedWeekly: 0, confidence: 0.1
            ),
            Self.evaluate(
                current: Self.bulkingTargets(), profile: Self.bulkingProfile,
                observedWeekly: 0, daysSinceLastAdjustment: 3
            ),
            Self.evaluate(
                current: Self.bulkingTargets(), profile: Self.bulkingProfile,
                observedWeekly: 0, adherence: 0.2
            ),
            Self.evaluate(current: Self.bulkingTargets(), profile: Self.bulkingProfile, observedWeekly: 0.4),
            Self.evaluate(current: Self.bulkingTargets(), profile: Self.bulkingProfile, observedWeekly: 0),
            Self.evaluate(current: Self.bulkingTargets(), profile: Self.bulkingProfile, observedWeekly: 1.5),
            Self.evaluate(current: Self.cuttingTargets(), profile: Self.cuttingProfile, observedWeekly: 0.5)
        ]
        for decision in decisions {
            #expect(decision.requiresUserApproval, "\(decision.action) came back applied, not proposed")
        }
    }

    @Test("A hold never carries replacement targets or a non-zero delta")
    func holdsCarryNoChange() {
        let holds = [
            Self.evaluate(
                current: Self.bulkingTargets(), profile: Self.bulkingProfile,
                observedWeekly: 0, daysSinceLastAdjustment: 2
            ),
            Self.evaluate(current: Self.bulkingTargets(), profile: Self.bulkingProfile, observedWeekly: 0.4),
            Self.evaluate(
                current: Self.bulkingTargets(), profile: Self.bulkingProfile,
                observedWeekly: 0, adherence: 0.1
            )
        ]
        for decision in holds {
            #expect(decision.action == .hold)
            #expect(decision.deltaKilocalories == 0)
            #expect(decision.newTargets == nil)
        }
    }

    @Test("A changed proposal explains itself and asks for approval in its explanations")
    func changedProposalCarriesItsRationale() {
        let decision = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile, observedWeekly: 0
        )
        let keys = decision.newTargets?.explanations.map(\.key) ?? []
        #expect(keys.first == "nutrition.adjust.increase")
        #expect(keys.contains("nutrition.adjust.approval"))
        #expect(keys.last == "nutrition.energy.estimateDisclaimer")
    }

    // MARK: - Macro redistribution

    @Test("Protein does not move when calories do")
    func proteinIsNeverRedistributed() {
        for observed in [0.0, 1.2, -1.0] {
            let current = Self.bulkingTargets()
            let decision = Self.evaluate(
                current: current, profile: Self.bulkingProfile, observedWeekly: observed
            )
            guard let newTargets = decision.newTargets else { continue }
            #expect(
                newTargets.proteinG == current.proteinG,
                "protein moved from \(current.proteinG) to \(newTargets.proteinG)"
            )
        }
    }

    @Test("The redistributed macros add up to the new calorie target")
    func redistributedMacrosReconcileWithTheNewTarget() {
        let scenarios: [(EnergyTargets, NutritionProfileSnapshot, Double)] = [
            (Self.bulkingTargets(), Self.bulkingProfile, 0.0),
            (Self.bulkingTargets(), Self.bulkingProfile, 1.5),
            (Self.cuttingTargets(), Self.cuttingProfile, 0.4),
            (Self.cuttingTargets(), Self.cuttingProfile, -1.1)
        ]
        for (current, profile, observed) in scenarios {
            let decision = Self.evaluate(current: current, profile: profile, observedWeekly: observed)
            guard let newTargets = decision.newTargets else { continue }
            let derived = newTargets.macros.derivedKilocalories
            #expect(
                abs(derived - newTargets.kilocalories) <= 20,
                "macros derive \(derived) kcal against a \(newTargets.kilocalories) kcal target"
            )
            #expect(newTargets.proteinG >= 0)
            #expect(newTargets.carbsG >= 0)
            #expect(newTargets.fatG >= 0)
        }
    }

    @Test("The change is split roughly 70% carbohydrate, 30% fat by energy")
    func changeSplitsSeventyThirty() {
        let current = Self.bulkingTargets()
        let split = NutritionAdjustmentEngine.redistribute(
            delta: 220, current: current, profile: Self.bulkingProfile, newKilocalories: 3_450
        )
        let carbChange = (split.carbsG - current.carbsG) * 4
        let fatChange = (split.fatG - current.fatG) * 9
        #expect(abs(carbChange - 154) <= 12, "carbohydrate took \(carbChange) kcal of the 220")
        #expect(abs(fatChange - 66) <= 12, "fat took \(fatChange) kcal of the 220")
        #expect(split.proteinG == current.proteinG)
    }

    @Test("Fat is never pushed under its floor by a decrease; the overflow comes off carbohydrate")
    func fatFloorSurvivesADecrease() {
        var current = Self.cuttingTargets(kilocalories: 1_700)
        current.fatG = 25
        current.carbsG = 210
        current.proteinG = 120
        let newEnergy = 1_530.0
        let split = NutritionAdjustmentEngine.redistribute(
            delta: -170, current: current, profile: Self.cuttingProfile, newKilocalories: newEnergy
        )
        let floor = NutritionRecommendationEngine.fatFloorGrams(
            kilocalories: newEnergy, profile: Self.cuttingProfile
        )
        #expect(split.fatG >= floor - 0.5, "fat \(split.fatG) g fell under its \(floor) g floor")
        #expect(split.carbsG >= 0)
    }

    @Test("A macro set that does not reconcile with its calories is rebuilt rather than nudged")
    func inconsistentTargetSetIsRebuilt() {
        // A half-populated record: calories but no macros at all.
        var broken = EnergyTargets()
        broken.kilocalories = 2_000
        broken.direction = .maintenance
        let split = NutritionAdjustmentEngine.redistribute(
            delta: 100, current: broken, profile: Self.bulkingProfile, newKilocalories: 2_100
        )
        #expect(split.proteinG > 0, "a zero protein figure means 'never recorded', so it is rebuilt")
        #expect(split.carbsG >= 0)
        #expect(split.fatG >= 0)
        #expect(abs(split.proteinG * 4 + split.carbsG * 4 + split.fatG * 9 - 2_100) <= 25)
    }

    @Test("A protein figure that alone overspends the new budget is rebuilt, not frozen")
    func overspendingProteinIsRebuilt() {
        var broken = Self.cuttingTargets(kilocalories: 1_600)
        broken.proteinG = 600   // 2,400 kcal of protein against a 1,450 kcal budget
        let split = NutritionAdjustmentEngine.redistribute(
            delta: -150, current: broken, profile: Self.cuttingProfile, newKilocalories: 1_450
        )
        #expect(split.proteinG < 600)
        #expect(split.proteinG * 4 <= 1_450)
        #expect(split.carbsG >= 0)
        #expect(split.fatG >= 0)
    }

    @Test("A negative macro anywhere in the incoming set forces a rebuild")
    func negativeIncomingMacroForcesARebuild() {
        var broken = Self.cuttingTargets()
        broken.carbsG = -20
        let split = NutritionAdjustmentEngine.redistribute(
            delta: 100, current: broken, profile: Self.cuttingProfile, newKilocalories: 1_700
        )
        #expect(split.carbsG >= 0)
        #expect(split.fatG >= 0)
        #expect(split.proteinG >= 0)
    }

    // MARK: - Determinism

    @Test("Identical input produces an identical decision")
    func decisionsAreReproducible() {
        let first = Self.evaluate(
            current: Self.bulkingTargets(), profile: Self.bulkingProfile, observedWeekly: 0
        )
        for _ in 0..<5 {
            let repeated = Self.evaluate(
                current: Self.bulkingTargets(), profile: Self.bulkingProfile, observedWeekly: 0
            )
            #expect(repeated == first)
        }
    }
}
