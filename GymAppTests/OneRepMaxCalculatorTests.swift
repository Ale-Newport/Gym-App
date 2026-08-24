import Foundation
import Testing
@testable import GymApp

/// Behaviour of `OneRepMaxCalculator`, checked against the published equations and against the
/// reliability bounds documented in `docs/fragments/progression.md`.
@Suite("One-rep max estimation")
struct OneRepMaxCalculatorTests {

    private let tolerance = 1e-9

    // MARK: - Published values

    @Test("Epley estimates 116.67 kg from 100 kg for five reps")
    func epleyMatchesItsPublishedEquation() throws {
        // 1RM = w × (1 + reps / 30)
        let value = try #require(
            OneRepMaxCalculator.estimate(weightKg: 100, reps: 5, formula: .epley)
        )
        #expect(abs(value - 100 * (1 + 5.0 / 30)) < tolerance)
        #expect(abs(value - 116.666_666_666_666_67) < 1e-9)
    }

    @Test("Brzycki estimates 112.5 kg from 100 kg for five reps")
    func brzyckiMatchesItsPublishedEquation() throws {
        // 1RM = w × 36 / (37 − reps)
        let value = try #require(
            OneRepMaxCalculator.estimate(weightKg: 100, reps: 5, formula: .brzycki)
        )
        #expect(abs(value - 112.5) < tolerance)
    }

    @Test("Lombardi estimates 117.46 kg from 100 kg for five reps")
    func lombardiMatchesItsPublishedEquation() throws {
        // 1RM = w × reps^0.10
        let value = try #require(
            OneRepMaxCalculator.estimate(weightKg: 100, reps: 5, formula: .lombardi)
        )
        #expect(abs(value - 100 * pow(5.0, 0.10)) < tolerance)
        #expect(abs(value - 117.461_894_308_802_2) < 1e-9)
    }

    @Test("Epley and Brzycki agree exactly at ten reps, which is where both were fitted")
    func epleyAndBrzyckiCrossAtTenReps() throws {
        let epley = try #require(OneRepMaxCalculator.estimate(weightKg: 100, reps: 10, formula: .epley))
        let brzycki = try #require(OneRepMaxCalculator.estimate(weightKg: 100, reps: 10, formula: .brzycki))
        #expect(abs(epley - brzycki) < 1e-9)
        #expect(abs(epley - 133.333_333_333_333_33) < 1e-9)
    }

    @Test("The default formula is the mean of Epley and Brzycki")
    func averageIsTheMeanOfTheTwoOpposingFormulas() throws {
        let epley = try #require(OneRepMaxCalculator.estimate(weightKg: 82.5, reps: 7, formula: .epley))
        let brzycki = try #require(OneRepMaxCalculator.estimate(weightKg: 82.5, reps: 7, formula: .brzycki))
        let average = try #require(OneRepMaxCalculator.estimate(weightKg: 82.5, reps: 7))
        #expect(abs(average - (epley + brzycki) / 2) < tolerance)
    }

    @Test("Epley drifts high and Brzycki drifts low as reps climb")
    func theTwoFormulasErrInOppositeDirections() throws {
        // The whole reason `.average` exists. At ten reps they coincide; either side of that they
        // straddle the mean.
        let epley = try #require(OneRepMaxCalculator.estimate(weightKg: 100, reps: 12, formula: .epley))
        let brzycki = try #require(OneRepMaxCalculator.estimate(weightKg: 100, reps: 12, formula: .brzycki))
        #expect(epley > brzycki)

        let lowEpley = try #require(OneRepMaxCalculator.estimate(weightKg: 100, reps: 3, formula: .epley))
        let lowBrzycki = try #require(OneRepMaxCalculator.estimate(weightKg: 100, reps: 3, formula: .brzycki))
        #expect(lowEpley < lowBrzycki)
    }

    // MARK: - Bounds

    @Test("A single rep returns the load itself rather than being inflated by a formula", arguments: OneRepMaxCalculator.Formula.allCases)
    func singleRepReturnsTheLoadUnchanged(formula: OneRepMaxCalculator.Formula) throws {
        let value = try #require(OneRepMaxCalculator.estimate(weightKg: 142.5, reps: 1, formula: formula))
        #expect(value == 142.5)
    }

    @Test("Fewer than one rep is not a set, so no estimate is produced", arguments: [0, -1, -12])
    func repsBelowOneReturnNil(reps: Int) {
        #expect(OneRepMaxCalculator.estimate(weightKg: 100, reps: reps) == nil)
    }

    @Test("Twelve reps is the last reliable rep count; thirteen is refused")
    func repsAboveTheReliabilityCeilingReturnNil() {
        #expect(OneRepMaxCalculator.maximumReliableReps == 12)
        #expect(OneRepMaxCalculator.estimate(weightKg: 60, reps: 12) != nil)
        #expect(OneRepMaxCalculator.estimate(weightKg: 60, reps: 13) == nil)
        #expect(OneRepMaxCalculator.estimate(weightKg: 60, reps: 20) == nil)
    }

    @Test("A non-positive or non-finite load produces no estimate")
    func unusableLoadsReturnNil() {
        #expect(OneRepMaxCalculator.estimate(weightKg: 0, reps: 5) == nil)
        #expect(OneRepMaxCalculator.estimate(weightKg: -60, reps: 5) == nil)
        #expect(OneRepMaxCalculator.estimate(weightKg: .nan, reps: 5) == nil)
        #expect(OneRepMaxCalculator.estimate(weightKg: .infinity, reps: 5) == nil)
    }

    @Test("Brzycki never divides by zero or flips sign, at any rep count")
    func brzyckiDenominatorCannotBlowUp() {
        // 37 reps is Brzycki's singularity and past it the raw equation returns a *negative* 1RM.
        // The rep bounds must keep every caller away from it, for every formula.
        for reps in 1...200 {
            for formula in OneRepMaxCalculator.Formula.allCases {
                guard let value = OneRepMaxCalculator.estimate(
                    weightKg: 100, reps: reps, formula: formula
                ) else { continue }
                #expect(value.isFinite, "reps \(reps) with \(formula) produced a non-finite 1RM")
                #expect(value > 0, "reps \(reps) with \(formula) produced a non-positive 1RM")
            }
        }
        #expect(OneRepMaxCalculator.estimate(weightKg: 100, reps: 36, formula: .brzycki) == nil)
        #expect(OneRepMaxCalculator.estimate(weightKg: 100, reps: 37, formula: .brzycki) == nil)
        #expect(OneRepMaxCalculator.estimate(weightKg: 100, reps: 38, formula: .brzycki) == nil)
    }

    // MARK: - The inverse

    @Test("Prescribing one rep hands back the one-rep max", arguments: OneRepMaxCalculator.Formula.allCases)
    func inverseAtOneRepIsTheOneRepMax(formula: OneRepMaxCalculator.Formula) throws {
        let value = try #require(
            OneRepMaxCalculator.weight(forReps: 1, oneRepMaxKg: 120, formula: formula)
        )
        #expect(value == 120)
    }

    @Test("The inverse runs to thirty reps and refuses thirty-one")
    func inverseRespectsThePrescribableCeiling() {
        #expect(OneRepMaxCalculator.maximumPrescribableReps == 30)
        #expect(OneRepMaxCalculator.weight(forReps: 30, oneRepMaxKg: 100) != nil)
        #expect(OneRepMaxCalculator.weight(forReps: 31, oneRepMaxKg: 100) == nil)
        #expect(OneRepMaxCalculator.weight(forReps: 0, oneRepMaxKg: 100) == nil)
        #expect(OneRepMaxCalculator.weight(forReps: 8, oneRepMaxKg: 0) == nil)
        #expect(OneRepMaxCalculator.weight(forReps: 8, oneRepMaxKg: .nan) == nil)
    }

    @Test("Past twelve reps the Epley inverse takes over: 60 % at twenty reps, 50 % at thirty")
    func inverseFallsBackToEpleyPastTheReliabilityCeiling() throws {
        // Brzycki's inverse collapses towards zero here, so it is deliberately not used.
        let twenty = try #require(OneRepMaxCalculator.weight(forReps: 20, oneRepMaxKg: 100))
        let thirty = try #require(OneRepMaxCalculator.weight(forReps: 30, oneRepMaxKg: 100))
        #expect(abs(twenty - 60) < 1e-9)
        #expect(abs(thirty - 50) < 1e-9)

        // Above the ceiling the formula argument stops mattering, by design.
        for formula in OneRepMaxCalculator.Formula.allCases {
            let value = try #require(
                OneRepMaxCalculator.weight(forReps: 25, oneRepMaxKg: 100, formula: formula)
            )
            #expect(abs(value - twenty) > 1e-9)
            #expect(abs(value - 100 / (1 + 25.0 / 30)) < 1e-9)
        }
    }

    @Test("The prescribed load falls as the rep target rises, with no discontinuity at the ceiling")
    func inverseIsMonotonicallyDecreasing() throws {
        var previous = Double.greatestFiniteMagnitude
        for reps in 1...OneRepMaxCalculator.maximumPrescribableReps {
            let value = try #require(OneRepMaxCalculator.weight(forReps: reps, oneRepMaxKg: 100))
            #expect(value < previous, "load did not fall going into \(reps) reps")
            #expect(value > 0)
            previous = value
        }
    }

    @Test("The forward and inverse agree to well under a plate across the reliable range")
    func inverseRoundTripsWithinPlateResolution() throws {
        // `.average` inverts the mean of the two inverses rather than the mean of the two forward
        // equations. The documented claim is that the difference is far below any selectable load.
        for reps in 1...OneRepMaxCalculator.maximumReliableReps {
            let oneRepMax = try #require(OneRepMaxCalculator.estimate(weightKg: 100, reps: reps))
            let back = try #require(OneRepMaxCalculator.weight(forReps: reps, oneRepMaxKg: oneRepMax))
            #expect(abs(back - 100) < 0.5, "round trip at \(reps) reps drifted to \(back) kg")
        }
    }

    // MARK: - Best estimate from a set of sets

    @Test("The best estimate ignores warm-up, drop and calibration sets")
    func bestEstimateOnlyCountsWorkingSets() throws {
        let sets = [
            Fixtures.set(kind: .warmup, weightKg: 200, reps: 5),
            Fixtures.set(kind: .calibration, weightKg: 190, reps: 5),
            Fixtures.set(kind: .dropSet, weightKg: 180, reps: 5),
            Fixtures.set(kind: .working, weightKg: 100, reps: 5)
        ]
        let best = try #require(OneRepMaxCalculator.bestEstimate(from: sets))
        // 100 kg × 5 through `.average`, not 200 kg from the warm-up.
        #expect(abs(best - 114.583_333_333_333_33) < 1e-9)
    }

    @Test("Back-off and AMRAP sets do count, because they are working sets")
    func bestEstimateCountsBackoffAndAmrapSets() throws {
        let backoff = try #require(
            OneRepMaxCalculator.bestEstimate(from: [Fixtures.set(kind: .backoff, weightKg: 100, reps: 5)])
        )
        let amrap = try #require(
            OneRepMaxCalculator.bestEstimate(from: [Fixtures.set(kind: .amrap, weightKg: 100, reps: 5)])
        )
        #expect(abs(backoff - 114.583_333_333_333_33) < 1e-9)
        #expect(abs(amrap - 114.583_333_333_333_33) < 1e-9)
    }

    @Test("An abandoned set says nothing about capacity and is skipped")
    func bestEstimateIgnoresIncompleteSets() throws {
        let sets = [
            Fixtures.set(weightKg: 140, reps: 5, isCompleted: false),
            Fixtures.set(weightKg: 100, reps: 5)
        ]
        let best = try #require(OneRepMaxCalculator.bestEstimate(from: sets))
        #expect(abs(best - 114.583_333_333_333_33) < 1e-9)
    }

    @Test("An empty list of sets produces no estimate")
    func bestEstimateOfNothingIsNil() {
        #expect(OneRepMaxCalculator.bestEstimate(from: []) == nil)
    }

    @Test("A list with nothing but warm-ups produces no estimate")
    func bestEstimateOfOnlyWarmupsIsNil() {
        let sets = [
            Fixtures.set(kind: .warmup, weightKg: 60, reps: 10),
            Fixtures.set(kind: .warmup, weightKg: 80, reps: 5)
        ]
        #expect(OneRepMaxCalculator.bestEstimate(from: sets) == nil)
    }

    @Test("Sets missing a load or a rep count are skipped, not treated as zero")
    func bestEstimateSkipsSetsWithMissingData() {
        let sets = [
            Fixtures.set(weightKg: 100, reps: nil),
            Fixtures.set(weightKg: nil, reps: 5)
        ]
        #expect(OneRepMaxCalculator.bestEstimate(from: sets) == nil)
    }

    @Test("A set past the reliability ceiling is skipped but does not suppress a usable one")
    func bestEstimateSkipsUnreliableRepCounts() throws {
        let sets = [
            Fixtures.set(weightKg: 60, reps: 25),
            Fixtures.set(weightKg: 100, reps: 5)
        ]
        let best = try #require(OneRepMaxCalculator.bestEstimate(from: sets))
        #expect(abs(best - 114.583_333_333_333_33) < 1e-9)

        #expect(OneRepMaxCalculator.bestEstimate(from: [Fixtures.set(weightKg: 60, reps: 25)]) == nil)
    }

    @Test("The best estimate is the maximum across the session, not the heaviest set")
    func bestEstimateTakesTheStrongestSetNotTheHeaviest() throws {
        // 90 kg × 8 estimates higher than 100 kg × 3, and that is the point of estimating at all.
        let heavyTriple = try #require(OneRepMaxCalculator.estimate(weightKg: 100, reps: 3))
        let lighterEight = try #require(OneRepMaxCalculator.estimate(weightKg: 90, reps: 8))
        #expect(lighterEight > heavyTriple)

        let best = try #require(OneRepMaxCalculator.bestEstimate(from: [
            Fixtures.set(weightKg: 100, reps: 3),
            Fixtures.set(weightKg: 90, reps: 8)
        ]))
        #expect(abs(best - lighterEight) < tolerance)
    }

    @Test("Identical input always produces identical output")
    func bestEstimateIsDeterministic() {
        let sets = [
            Fixtures.set(weightKg: 100, reps: 5),
            Fixtures.set(weightKg: 100, reps: 5),
            Fixtures.set(weightKg: 95, reps: 6)
        ]
        let first = OneRepMaxCalculator.bestEstimate(from: sets)
        for _ in 0..<20 {
            #expect(OneRepMaxCalculator.bestEstimate(from: sets) == first)
        }
    }
}
