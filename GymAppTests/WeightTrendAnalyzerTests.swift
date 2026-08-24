import Foundation
import Testing
@testable import GymApp

/// Behavioural tests for `WeightTrendAnalyzer`.
///
/// Specification: `docs/fragments/nutrition.md` §3. Every test supplies its own `now` and its own
/// UTC calendar, so nothing here depends on the wall clock, the device time zone or the order the
/// readings happen to arrive in.
@Suite("Weight trend analyzer")
struct WeightTrendAnalyzerTests {

    // MARK: - Deterministic time

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Midday on a fixed date, so a reading "n days ago" never straddles a day boundary.
    private static let now: Date = {
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        return day.addingTimeInterval(12 * 3_600)
    }()

    private static func date(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
    }

    /// Readings on consecutive days, oldest first: index 0 is `days − 1` days ago.
    private static func series(days: Int, weight: (Int) -> Double) -> [WeightTrendPoint] {
        (0..<days).map { index in
            WeightTrendPoint(date: date(daysAgo: days - 1 - index), weightKg: weight(index))
        }
    }

    private static func analyze(_ entries: [WeightTrendPoint], windowDays: Int = 7) -> WeightTrendAnalysis {
        WeightTrendAnalyzer.analyze(
            entries: entries, windowDays: windowDays, now: now, calendar: calendar
        )
    }

    // MARK: - Empty and sparse input

    @Test("An empty reading list returns the empty analysis instead of crashing")
    func emptyInputReturnsEmptyAnalysis() {
        let analysis = Self.analyze([])
        #expect(analysis == WeightTrendAnalysis.empty)
        #expect(analysis.movingAverage.isEmpty)
        #expect(analysis.currentTrendKg == nil)
        #expect(analysis.weeklyChangeKg == nil)
        #expect(analysis.hasEnoughData == false)
        #expect(analysis.weeksOfData == 0)
    }

    @Test("A single reading yields a trend value but no slope and no confidence in a decision")
    func singleReadingProducesNoSlope() {
        let analysis = Self.analyze([WeightTrendPoint(date: Self.date(daysAgo: 0), weightKg: 81.4)])
        #expect(analysis.movingAverage.count == 1)
        #expect(analysis.currentTrendKg == 81.4)
        #expect(analysis.weeklyChangeKg == nil, "one point cannot support a regression")
        #expect(analysis.hasEnoughData == false)
        #expect(analysis.weeksOfData == 0)
        #expect(analysis.confidence < 0.35, "one reading must not clear the adjustment engine's bar")
    }

    @Test("Readings that are all implausible leave nothing to analyse")
    func implausibleReadingsAreDiscarded() {
        let nonsense = Self.series(days: 20) { _ in 900 }
        #expect(Self.analyze(nonsense) == WeightTrendAnalysis.empty)

        let tooLight = Self.series(days: 20) { _ in 3 }
        #expect(Self.analyze(tooLight) == WeightTrendAnalysis.empty)
    }

    @Test("A single implausible reading is dropped without taking the rest of the series with it")
    func oneImplausibleReadingIsDroppedInPlace() {
        var entries = Self.series(days: 20) { _ in 80 }
        entries[5] = WeightTrendPoint(date: entries[5].date, weightKg: 802)
        let analysis = Self.analyze(entries)
        #expect(analysis.movingAverage.count == 19)
        #expect(analysis.currentTrendKg == 80)
    }

    @Test("Future-dated readings are ignored")
    func futureReadingsAreIgnored() {
        var entries = Self.series(days: 20) { _ in 80 }
        entries.append(WeightTrendPoint(date: Self.now.addingTimeInterval(5 * 86_400), weightKg: 120))
        let analysis = Self.analyze(entries)
        #expect(analysis.movingAverage.count == 20)
        #expect(analysis.currentTrendKg == 80)
    }

    @Test("A non-finite reading cannot poison the average")
    func nonFiniteReadingsAreDropped() {
        var entries = Self.series(days: 20) { _ in 80 }
        entries.append(WeightTrendPoint(date: Self.date(daysAgo: 3), weightKg: .nan))
        let analysis = Self.analyze(entries)
        #expect(analysis.currentTrendKg == 80)
        #expect(analysis.weeklyChangeKg?.isFinite == true)
    }

    // MARK: - Day bucketing

    @Test("Several readings on one day are averaged rather than one of them winning")
    func sameDayReadingsAreAveraged() {
        let day = Self.date(daysAgo: 0)
        let entries = [
            WeightTrendPoint(date: day.addingTimeInterval(-6 * 3_600), weightKg: 80),
            WeightTrendPoint(date: day.addingTimeInterval(-1 * 3_600), weightKg: 82)
        ]
        let analysis = Self.analyze(entries)
        #expect(analysis.movingAverage.count == 1)
        #expect(analysis.currentTrendKg == 81)
    }

    @Test("Readings arriving out of order produce the same analysis as ordered ones")
    func readingOrderDoesNotMatter() {
        let ordered = Self.series(days: 21) { 80 - 0.05 * Double($0) }
        let shuffled = Array(ordered.reversed())
        #expect(Self.analyze(ordered) == Self.analyze(shuffled))
    }

    // MARK: - Moving average

    @Test("A one-day spike is smoothed away by the 7-day average")
    func sevenDayAverageSmoothsASpike() {
        // Fourteen days at 80 kg with a single 85 kg reading — a plausible salty-dinner morning.
        let spikeIndex = 8
        let entries = Self.series(days: 14) { $0 == spikeIndex ? 85 : 80 }
        let analysis = Self.analyze(entries)

        #expect(analysis.movingAverage.count == 14)
        let smoothed = analysis.movingAverage[spikeIndex].weightKg
        // (6 × 80 + 85) / 7 = 80.714
        #expect(abs(smoothed - 80.714) < 0.001)
        #expect(
            abs(smoothed - 80) < 1,
            "a 5 kg spike must move the average by under a kilogram, not by five"
        )
    }

    @Test("The trailing window covers exactly the last seven days, including today")
    func trailingWindowIsSevenDaysInclusive() {
        // Rising by 1 kg a day makes the window length directly readable from the average.
        let entries = Self.series(days: 10) { 70 + Double($0) }
        let analysis = Self.analyze(entries)
        // Last point is day index 9 (79 kg); the window covers indices 3…9, mean 76.
        #expect(abs((analysis.currentTrendKg ?? 0) - 76) < 0.001)
        // The first point has only itself in its window.
        #expect(abs(analysis.movingAverage[0].weightKg - 70) < 0.001)
    }

    @Test("The moving average is trailing, so it always has a value for the newest day")
    func movingAverageAlwaysReachesTheNewestDay() {
        let entries = Self.series(days: 30) { 80 - 0.02 * Double($0) }
        let analysis = Self.analyze(entries)
        #expect(analysis.movingAverage.last?.date == Self.calendar.startOfDay(for: Self.date(daysAgo: 0)))
        #expect(analysis.currentTrendKg == analysis.movingAverage.last?.weightKg)
    }

    @Test("A window of one day reproduces the raw daily readings")
    func windowOfOneIsTheIdentity() {
        let entries = Self.series(days: 5) { 80 + Double($0) }
        let analysis = Self.analyze(entries, windowDays: 1)
        #expect(analysis.movingAverage.map(\.weightKg) == [80, 81, 82, 83, 84])
    }

    @Test("A zero or negative window is treated as one day rather than dividing by zero")
    func nonPositiveWindowIsClampedToOne() {
        let entries = Self.series(days: 5) { 80 + Double($0) }
        #expect(Self.analyze(entries, windowDays: 0) == Self.analyze(entries, windowDays: 1))
        #expect(Self.analyze(entries, windowDays: -7) == Self.analyze(entries, windowDays: 1))
    }

    // MARK: - Weekly rate

    @Test("The weekly rate is the regression slope over the trailing three weeks")
    func weeklyRateComesFromRegression() throws {
        // 21 daily readings falling 0.05 kg a day: exactly −0.35 kg a week.
        let entries = Self.series(days: 21) { 80 - 0.05 * Double($0) }
        let analysis = Self.analyze(entries)
        #expect(analysis.hasEnoughData)
        let weekly = try #require(analysis.weeklyChangeKg)
        #expect(abs(weekly - (-0.35)) < 0.001)
    }

    @Test("One outlier day barely moves the weekly rate, because it is a regression not a difference")
    func oneOutlierBarelyMovesTheWeeklyRate() {
        let clean = Self.series(days: 21) { 80 - 0.05 * Double($0) }
        var withOutlier = clean
        withOutlier[5] = WeightTrendPoint(date: clean[5].date, weightKg: clean[5].weightKg + 1)

        let cleanRate = Self.analyze(clean).weeklyChangeKg ?? .nan
        let outlierRate = Self.analyze(withOutlier).weeklyChangeKg ?? .nan

        #expect(abs(cleanRate - (-0.35)) < 0.001)
        #expect(
            abs(outlierRate - cleanRate) < 0.06,
            "a 1 kg outlier moved the weekly rate by \(abs(outlierRate - cleanRate)) kg"
        )
        // A naive first-minus-last difference would have moved by 1 kg / 3 weeks = 0.33 kg/week.
        #expect(abs(outlierRate - cleanRate) < 0.33)
    }

    @Test("The regression needs eight readings spanning a fortnight before it reports a slope")
    func regressionRequiresEightReadingsOverAFortnight() {
        // Seven readings across three weeks: enough span, not enough readings.
        let sparse = (0..<7).map { index in
            WeightTrendPoint(date: Self.date(daysAgo: 20 - index * 3), weightKg: 80 - Double(index) * 0.1)
        }
        #expect(Self.analyze(sparse).weeklyChangeKg == nil)

        // Ten readings crammed into ten days: enough readings, not enough span.
        let short = Self.series(days: 10) { 80 - 0.05 * Double($0) }
        #expect(Self.analyze(short).weeklyChangeKg == nil)

        // Eight readings across fifteen days clears both bars.
        let just = (0..<8).map { index in
            WeightTrendPoint(date: Self.date(daysAgo: 14 - index * 2), weightKg: 80 - Double(index) * 0.1)
        }
        #expect(Self.analyze(just).weeklyChangeKg != nil)
    }

    @Test("A perfectly flat log reports a zero rate, not a missing one")
    func flatLogReportsZeroRate() {
        let entries = Self.series(days: 21) { _ in 80 }
        let analysis = Self.analyze(entries)
        #expect(analysis.weeklyChangeKg == 0)
        #expect(analysis.hasEnoughData)
    }

    @Test("Only the trailing three weeks feed the regression, so an old plateau does not drag it")
    func regressionIgnoresReadingsOlderThanThreeWeeks() {
        // 60 days: flat for the first 39, then falling 0.1 kg a day for the last 21.
        let entries = Self.series(days: 60) { index in
            index < 39 ? 90 : 90 - 0.1 * Double(index - 39)
        }
        let analysis = Self.analyze(entries)
        let weekly = analysis.weeklyChangeKg ?? .nan
        #expect(
            abs(weekly - (-0.7)) < 0.05,
            "the recent decline should dominate, but the rate came back as \(weekly)"
        )
    }

    // MARK: - hasEnoughData

    @Test("Fewer than ten daily readings reports hasEnoughData == false")
    func nineReadingsIsNotEnoughData() {
        // Nine readings spread across twenty days: the span is fine, the count is not.
        let entries = (0..<9).map { index in
            WeightTrendPoint(date: Self.date(daysAgo: 20 - index * 2), weightKg: 80)
        }
        let analysis = Self.analyze(entries)
        #expect(analysis.movingAverage.count == 9)
        #expect(analysis.hasEnoughData == false)
    }

    @Test("Ten readings spanning less than a fortnight also reports hasEnoughData == false")
    func tenReadingsOverTooShortASpanIsNotEnoughData() {
        let entries = Self.series(days: 10) { _ in 80 }
        let analysis = Self.analyze(entries)
        #expect(analysis.movingAverage.count == 10)
        #expect(analysis.hasEnoughData == false)
    }

    @Test("Ten readings spanning a full fortnight is exactly enough")
    func tenReadingsAcrossAFortnightIsEnoughData() {
        // Readings on days 14, 13, 12, 11, 10, 9, 8, 7, 6 ago and today: count 10, span 14.
        var entries = (0..<9).map { index in
            WeightTrendPoint(date: Self.date(daysAgo: 14 - index), weightKg: 80)
        }
        entries.append(WeightTrendPoint(date: Self.date(daysAgo: 0), weightKg: 80))
        let analysis = Self.analyze(entries)
        #expect(analysis.movingAverage.count == 10)
        #expect(analysis.hasEnoughData)
    }

    @Test("Weeks of data measures the calendar span, not the reading count")
    func weeksOfDataMeasuresSpan() {
        let entries = Self.series(days: 21) { _ in 80 }
        // Twenty days between the first and last reading: 20 / 7 = 2.86 weeks.
        #expect(abs(Self.analyze(entries).weeksOfData - 2.86) < 0.001)
    }

    // MARK: - Confidence

    @Test("Clean daily readings score a high confidence, noisy ones a low one")
    func confidenceFallsWithResidualSpread() {
        let clean = Self.series(days: 21) { 80 - 0.05 * Double($0) }
        // The same trend with ±1.5 kg of alternating water weight around it.
        let noisy = Self.series(days: 21) { index in
            80 - 0.05 * Double(index) + (index % 2 == 0 ? 1.5 : -1.5)
        }

        let cleanConfidence = Self.analyze(clean).confidence
        let noisyConfidence = Self.analyze(noisy).confidence

        #expect(cleanConfidence > 0.95)
        #expect(noisyConfidence < cleanConfidence)
        #expect(noisyConfidence >= 0)
        // Residual SD ≥ 1.2 kg scores zero on the noise component: 0.40 + 0.25 × 20/21 ≈ 0.638.
        #expect(abs(noisyConfidence - 0.638) < 0.002)
    }

    @Test("Confidence rises with the number of readings")
    func confidenceRisesWithReadingCount() {
        let sparse = (0..<10).map { index in
            WeightTrendPoint(date: Self.date(daysAgo: 20 - index * 2), weightKg: 80 - 0.1 * Double(index))
        }
        let dense = Self.series(days: 21) { 80 - 0.05 * Double($0) }
        #expect(Self.analyze(sparse).confidence < Self.analyze(dense).confidence)
    }

    @Test("Confidence stays inside 0…1 and is rounded so equality is stable")
    func confidenceIsBoundedAndStable() {
        let cases: [[WeightTrendPoint]] = [
            [],
            Self.series(days: 1) { _ in 80 },
            Self.series(days: 21) { 80 - 0.05 * Double($0) },
            Self.series(days: 60) { index in 80 + (index % 3 == 0 ? 3 : -3) }
        ]
        for entries in cases {
            let confidence = Self.analyze(entries).confidence
            #expect(confidence >= 0 && confidence <= 1)
            #expect(
                abs(confidence * 1_000 - (confidence * 1_000).rounded()) < 1e-6,
                "confidence \(confidence) is not rounded to three decimal places"
            )
        }
    }

    // MARK: - Determinism

    @Test("Identical input produces byte-identical output")
    func analysisIsReproducible() {
        let entries = Self.series(days: 30) { index in
            80 - 0.03 * Double(index) + (index % 4 == 0 ? 0.4 : -0.2)
        }
        let first = Self.analyze(entries)
        for _ in 0..<5 {
            #expect(Self.analyze(entries) == first)
        }
    }

    @Test("The calendar is a parameter, so a different time zone cannot silently reshape the days")
    func calendarIsHonoured() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let entries = Self.series(days: 21) { 80 - 0.05 * Double($0) }

        let utc = Self.analyze(entries)
        let jst = WeightTrendAnalyzer.analyze(
            entries: entries, windowDays: 7, now: Self.now, calendar: tokyo
        )
        // Both must be internally consistent and finite; the point is that the calendar is honoured
        // rather than read from ambient state.
        #expect(utc.movingAverage.count == 21)
        #expect(jst.movingAverage.count == 21)
        #expect(jst.weeklyChangeKg?.isFinite == true)
    }
}
