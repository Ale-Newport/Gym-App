import Foundation

/// Smooths raw scale readings into something a decision can safely be made on.
///
/// Day-to-day body mass swings by roughly ±1 kg on water, glycogen, sodium and gut content alone —
/// comfortably more than a week's worth of real fat loss at any sane rate. Any logic that subtracts
/// Monday's reading from last Monday's is therefore reading noise most of the time. This analyser
/// exists so nothing downstream ever has to: it publishes a trailing moving average for display and
/// a regression slope for decisions, plus an honest confidence figure for both.
///
/// Pure and deterministic: the caller supplies `now`, and no randomness is involved.
enum WeightTrendAnalyzer {

    // MARK: - Constants

    enum Constants {
        /// A decision needs at least this many distinct days with a reading.
        static let minimumReadings: Int = 10
        /// …spanning at least this many calendar days. Two weeks is the shortest window in which a
        /// real trend can outgrow the daily noise at the rates this app recommends.
        static let minimumSpanDays: Int = 14

        /// The regression looks at the trailing three weeks. Longer windows lag a genuine change of
        /// direction; shorter ones are dominated by noise.
        static let regressionWindowDays: Int = 21
        /// …and needs at least a fortnight of it covered, with this many readings inside.
        static let minimumRegressionSpanDays: Int = 14
        static let minimumRegressionReadings: Int = 8

        /// Residual spread at or below this is treated as a perfectly clean signal; at or above the
        /// ceiling the readings are pure noise as far as confidence is concerned. The band brackets
        /// the ±1 kg daily fluctuation a normal person shows.
        static let noiseFloorKg: Double = 0.3
        static let noiseCeilingKg: Double = 1.2

        /// Readings outside this range are dropped as data-entry errors rather than trusted.
        static let plausibleMassRangeKg: ClosedRange<Double> = 20...400

        /// Confidence blend. Reading count carries the most weight because a sparse log is the most
        /// common reason a trend is wrong; spread matters nearly as much; span is a floor rule that
        /// `hasEnoughData` already enforces, so it contributes least.
        static let countWeight: Double = 0.40
        static let noiseWeight: Double = 0.35
        static let spanWeight: Double = 0.25
        /// Readings at which the count component saturates: three weeks of daily weigh-ins.
        static let saturatingReadingCount: Double = 21
    }

    // MARK: - Entry point

    /// Analyses a set of body-mass readings.
    ///
    /// - Parameters:
    ///   - entries: readings in any order. Several on one day are averaged; future-dated readings
    ///     and implausible masses are discarded.
    ///   - windowDays: length of the trailing moving-average window. Seven days by default so the
    ///     average always covers exactly one of every weekday — weekend eating is the single
    ///     biggest weekly cycle in most people's data, and a window that does not close over it
    ///     produces a sawtooth.
    ///   - now: reference date. Passed in rather than read, so the result is reproducible.
    ///   - calendar: calendar used to bucket readings into days.
    static func analyze(
        entries: [WeightTrendPoint],
        windowDays: Int = 7,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WeightTrendAnalysis {
        let window = max(1, windowDays)
        let daily = dailyPoints(from: entries, now: now, calendar: calendar)
        guard let first = daily.first, let last = daily.last else { return .empty }

        let movingAverage = trailingMovingAverage(daily, windowDays: window, calendar: calendar)
        let spanDays = dayCount(from: first.date, to: last.date, calendar: calendar)
        let weeksOfData = (Double(spanDays) / 7 * 100).rounded() / 100
        let hasEnoughData = daily.count >= Constants.minimumReadings
            && spanDays >= Constants.minimumSpanDays

        let regression = regressionSlope(daily, endingAt: last.date, calendar: calendar)
        let weeklyChange = regression.map { ((($0.slopePerDay * 7) * 1_000).rounded() / 1_000) }

        let confidence = confidenceScore(
            readingsInWindow: regression?.readingCount ?? daily.count,
            spanDays: regression?.spanDays ?? spanDays,
            residualStandardDeviation: regression?.residualStandardDeviation
        )

        return WeightTrendAnalysis(
            movingAverage: movingAverage,
            currentTrendKg: movingAverage.last?.weightKg,
            weeklyChangeKg: weeklyChange,
            weeksOfData: weeksOfData,
            confidence: confidence,
            hasEnoughData: hasEnoughData
        )
    }

    // MARK: - Day bucketing

    /// One point per day, oldest first, with same-day readings averaged.
    ///
    /// Averaging rather than taking the first or last reading matters: somebody who weighs
    /// themselves before and after breakfast would otherwise inject a systematic step into the
    /// series depending on which reading won.
    private static func dailyPoints(
        from entries: [WeightTrendPoint],
        now: Date,
        calendar: Calendar
    ) -> [WeightTrendPoint] {
        var totals: [Date: (sum: Double, count: Double)] = [:]
        for entry in entries {
            guard entry.weightKg.isFinite,
                  Constants.plausibleMassRangeKg.contains(entry.weightKg),
                  entry.date <= now else { continue }
            let day = calendar.startOfDay(for: entry.date)
            let existing = totals[day] ?? (0, 0)
            totals[day] = (existing.sum + entry.weightKg, existing.count + 1)
        }
        // Sorted explicitly: dictionary iteration order is not defined, and this function feeds
        // every number the engine publishes.
        return totals.keys.sorted().map { day in
            let bucket = totals[day] ?? (0, 1)
            let mean = bucket.count > 0 ? bucket.sum / bucket.count : 0
            return WeightTrendPoint(date: day, weightKg: (mean * 1_000).rounded() / 1_000)
        }
    }

    private static func dayCount(from start: Date, to end: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    // MARK: - Moving average

    /// Trailing average of every reading in the `windowDays` days up to and including each point.
    ///
    /// Trailing rather than centred: a centred average cannot produce a value for today, and today
    /// is precisely the number the user wants on their dashboard. The cost is a few days of lag
    /// after a genuine change, which the regression below is there to catch.
    private static func trailingMovingAverage(
        _ points: [WeightTrendPoint],
        windowDays: Int,
        calendar: Calendar
    ) -> [WeightTrendPoint] {
        guard !points.isEmpty else { return [] }
        var result: [WeightTrendPoint] = []
        result.reserveCapacity(points.count)
        var startIndex = 0
        var runningSum: Double = 0
        for index in points.indices {
            runningSum += points[index].weightKg
            // Stepped with the calendar rather than `(windowDays − 1) × 86 400`. A day is 23 or 25
            // hours across a daylight-saving change, so a fixed-seconds cutoff quietly shortens the
            // window to six days for the whole week after an autumn transition — and a six-day
            // window no longer closes over exactly one of every weekday, which is the entire reason
            // the window is seven days long.
            let cutoff = calendar.date(byAdding: .day, value: -(windowDays - 1), to: points[index].date)
                ?? points[index].date.addingTimeInterval(-Double(windowDays - 1) * 86_400)
            while startIndex < index && points[startIndex].date < cutoff {
                runningSum -= points[startIndex].weightKg
                startIndex += 1
            }
            let count = Double(index - startIndex + 1)
            let mean = runningSum / count
            result.append(WeightTrendPoint(
                date: points[index].date, weightKg: (mean * 1_000).rounded() / 1_000
            ))
        }
        return result
    }

    // MARK: - Regression

    private struct Regression {
        var slopePerDay: Double
        var residualStandardDeviation: Double
        var readingCount: Int
        var spanDays: Int
    }

    /// Ordinary least squares over the trailing window, in kg per day.
    ///
    /// The regression runs on the *raw* daily points, not on the moving average. Regressing a
    /// smoothed series would understate the residual spread and so overstate confidence — the
    /// smoothing has already removed exactly the variation the confidence figure is supposed to
    /// measure.
    private static func regressionSlope(
        _ points: [WeightTrendPoint],
        endingAt end: Date,
        calendar: Calendar
    ) -> Regression? {
        // Calendar arithmetic for the same reason as the moving average: a fixed-seconds window
        // drops the oldest day of the three weeks after an autumn daylight-saving change, which
        // costs a reading and a slice of confidence for no reason the user could ever see.
        let start = calendar.date(byAdding: .day, value: -(Constants.regressionWindowDays - 1), to: end)
            ?? end.addingTimeInterval(-Double(Constants.regressionWindowDays - 1) * 86_400)
        let window = points.filter { $0.date >= start }
        guard window.count >= Constants.minimumRegressionReadings,
              let firstDate = window.first?.date else { return nil }
        let spanDays = dayCount(from: firstDate, to: end, calendar: calendar)
        guard spanDays >= Constants.minimumRegressionSpanDays else { return nil }

        let xs = window.map { $0.date.timeIntervalSince(firstDate) / 86_400 }
        let ys = window.map(\.weightKg)
        let n = Double(window.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n

        var covariance: Double = 0
        var varianceX: Double = 0
        for index in xs.indices {
            let dx = xs[index] - meanX
            covariance += dx * (ys[index] - meanY)
            varianceX += dx * dx
        }
        guard varianceX > 1e-9 else { return nil }
        let slope = covariance / varianceX
        let intercept = meanY - slope * meanX

        var residualSquares: Double = 0
        for index in xs.indices {
            let predicted = intercept + slope * xs[index]
            let residual = ys[index] - predicted
            residualSquares += residual * residual
        }
        // Two degrees of freedom are consumed by the fitted slope and intercept.
        let denominator = max(1, n - 2)
        let residualSD = (residualSquares / denominator).squareRoot()

        return Regression(
            slopePerDay: slope,
            residualStandardDeviation: residualSD,
            readingCount: window.count,
            spanDays: spanDays
        )
    }

    // MARK: - Confidence

    /// How much the trend deserves to be trusted, 0…1.
    ///
    /// Three components: how many readings there are, how long they span, and how tightly they sit
    /// around the fitted line. Weighing spread explicitly matters because a user who weighs in
    /// daily but at wildly different times produces plenty of data and a poor signal, and the
    /// adjustment engine widens its tolerance band when confidence is low rather than acting on it.
    private static func confidenceScore(
        readingsInWindow: Int,
        spanDays: Int,
        residualStandardDeviation: Double?
    ) -> Double {
        let countScore = nutritionClamp01(
            Double(readingsInWindow) / Constants.saturatingReadingCount
        )
        let spanScore = nutritionClamp01(Double(spanDays) / Double(Constants.regressionWindowDays))
        let noiseScore: Double
        if let sd = residualStandardDeviation {
            let excess = max(0, sd - Constants.noiseFloorKg)
            let range = Constants.noiseCeilingKg - Constants.noiseFloorKg
            noiseScore = nutritionClamp01(1 - excess / range)
        } else {
            // No regression means no residuals to judge; assume the middle rather than either
            // extreme, since the count and span components already reflect the sparse data.
            noiseScore = 0.5
        }
        let blended = countScore * Constants.countWeight
            + noiseScore * Constants.noiseWeight
            + spanScore * Constants.spanWeight
        return (nutritionClamp01(blended) * 1_000).rounded() / 1_000
    }
}
