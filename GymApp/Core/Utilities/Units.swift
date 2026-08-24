import Foundation

/// Conversion and formatting between the canonical internal units and whatever the user prefers.
///
/// **The rule the whole app follows:** every stored value is canonical — kilograms, centimetres,
/// metres, kilocalories, seconds. Conversion happens only at the presentation edge, in this file.
/// Mixing units inside the model layer is the single most reliable way to introduce silent
/// arithmetic bugs in a fitness app, so the model layer simply never sees a pound.
enum Units {

    // MARK: - Mass

    static func kilograms(fromDisplay value: Double, unit: WeightUnit) -> Double {
        value * unit.kilogramsPerUnit
    }

    static func display(kilograms: Double, unit: WeightUnit) -> Double {
        kilograms / unit.kilogramsPerUnit
    }

    /// Formats a load for display, hiding the decimal when the value is whole.
    static func formatWeight(
        kilograms: Double,
        unit: WeightUnit,
        locale: Locale = .current,
        includeUnit: Bool = true,
        fractionDigits: Int? = nil
    ) -> String {
        let value = display(kilograms: kilograms, unit: unit)
        let digits = fractionDigits ?? (abs(value.rounded() - value) < 0.001 ? 0 : (unit == .kilograms ? 1 : 1))
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        let text = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
        return includeUnit ? "\(text) \(unit.rawValue)" : text
    }

    // MARK: - Length

    static func centimeters(fromFeet feet: Int, inches: Double) -> Double {
        (Double(feet) * 12 + inches) * 2.54
    }

    static func feetAndInches(fromCentimeters centimeters: Double) -> (feet: Int, inches: Double) {
        let totalInches = centimeters / 2.54
        let feet = Int(totalInches / 12)
        return (feet, totalInches - Double(feet) * 12)
    }

    static func formatHeight(
        centimeters: Double,
        unit: HeightUnit,
        locale: Locale = .current
    ) -> String {
        switch unit {
        case .centimeters:
            return "\(Int(centimeters.rounded())) cm"
        case .feetInches:
            var (feet, inches) = feetAndInches(fromCentimeters: centimeters)
            var wholeInches = Int(inches.rounded())
            // Rounding 11.6″ gives 12″, which is a foot. Without the carry, 182.5 cm displays as
            // 5′ 12″ — a number no one has ever used to describe their height.
            if wholeInches >= 12 {
                feet += wholeInches / 12
                wholeInches %= 12
            }
            inches = Double(wholeInches)
            return "\(feet)′ \(wholeInches)″"
        }
    }

    // MARK: - Distance

    static func meters(fromDisplay value: Double, unit: DistanceUnit) -> Double {
        value * unit.metersPerUnit
    }

    static func formatDistance(
        meters: Double,
        unit: DistanceUnit,
        locale: Locale = .current
    ) -> String {
        let value = meters / unit.metersPerUnit
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value < 10 ? 2 : 1
        let text = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(text) \(unit.rawValue)"
    }

    // MARK: - Energy

    static func formatEnergy(
        kilocalories: Double,
        unit: EnergyUnit,
        locale: Locale = .current,
        includeUnit: Bool = true
    ) -> String {
        let value = kilocalories * unit.perKilocalorie
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let text = formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        return includeUnit ? "\(text) \(unit.rawValue)" : text
    }

    // MARK: - Time

    /// `mm:ss`, or `h:mm:ss` past an hour. Used for timers and session durations.
    static func formatDuration(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Compact human duration, e.g. "1 h 12 min" or "48 min".
    @MainActor
    static func formatDurationCompact(seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            return remainder == 0 ? L("duration.hours", hours) : L("duration.hoursMinutes", hours, remainder)
        }
        return L("duration.minutes", minutes)
    }

    // MARK: - Numbers

    static func formatMacro(grams: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = grams < 10 ? 1 : 0
        return (formatter.string(from: NSNumber(value: grams)) ?? "\(Int(grams))") + " g"
    }

    static func formatDecimal(_ value: Double, digits: Int = 1, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = digits
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    static func formatSignedDecimal(_ value: Double, digits: Int = 1, locale: Locale = .current) -> String {
        let text = formatDecimal(abs(value), digits: digits, locale: locale)
        if value > 0 { return "+\(text)" }
        if value < 0 { return "−\(text)" }
        return text
    }
}

// MARK: - Day keys

/// Canonical day identifiers used to index food and water logs.
///
/// A `yyyy-MM-dd` string in the user's own calendar beats storing a `Date` and comparing ranges:
/// it survives time-zone changes without a day's meals silently jumping, and it makes a day's log a
/// single indexed equality fetch.
enum DayKey {
    /// `DateFormatter` is not thread-safe and creating one per call is measurably slow, so a
    /// formatter is cached per time zone behind a lock. Day keys are computed on every food-log
    /// read, so this path stays hot.
    private static let lock = NSLock()
    private nonisolated(unsafe) static var formatters: [String: DateFormatter] = [:]

    private static func formatter(for timeZone: TimeZone) -> DateFormatter {
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[timeZone.identifier] { return cached }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        formatters[timeZone.identifier] = formatter
        return formatter
    }

    static func make(from date: Date, calendar: Calendar = .current) -> String {
        formatter(for: calendar.timeZone).string(from: date)
    }

    static func date(from key: String, calendar: Calendar = .current) -> Date? {
        formatter(for: calendar.timeZone).date(from: key)
    }

    static var today: String { make(from: Date()) }

    static func offset(from key: String, days: Int, calendar: Calendar = .current) -> String {
        guard let date = date(from: key, calendar: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return key }
        return make(from: shifted, calendar: calendar)
    }
}

// MARK: - Load rounding

/// Rounds a recommended load onto weights the user can actually select.
///
/// A recommendation of "32.817 kg" is worse than useless — it tells the user the app does not
/// understand a gym. Every load the app shows passes through here first, using the increments the
/// user configured for their own gym.
enum LoadRounding {

    /// Rounds `kilograms` onto the nearest selectable load for `loadability`.
    static func round(
        kilograms: Double,
        loadability: Loadability,
        profile: EquipmentIncrements
    ) -> Double {
        guard kilograms.isFinite else { return 0 }
        let value = max(0, kilograms)

        switch loadability {
        case .barbell:
            return roundToBarbell(value, barWeight: profile.barbellBarWeightKg, plates: profile.availablePlatesKg)
        case .ezBar:
            return roundToBarbell(value, barWeight: profile.ezBarWeightKg, plates: profile.availablePlatesKg)
        case .dumbbell:
            return nearest(value, in: profile.availableDumbbellsKg) ?? roundToStep(value, step: 2.5)
        case .kettlebell:
            return nearest(value, in: profile.kettlebellsKg) ?? roundToStep(value, step: 4)
        case .machineStack:
            return roundToStep(value, step: profile.machineIncrementKg)
        case .cableStack:
            return roundToStep(value, step: profile.cableIncrementKg)
        case .weightedBodyweight, .assistedBodyweight:
            return roundToStep(value, step: 2.5)
        case .band, .bodyweight, .fixedImplement, .none:
            return roundToStep(value, step: 0.5)
        }
    }

    /// The smallest load step available for this movement — the unit a progression may add.
    static func increment(for loadability: Loadability, profile: EquipmentIncrements) -> Double {
        switch loadability {
        case .barbell, .ezBar:
            // A pair of the lightest plates.
            return (profile.availablePlatesKg.min() ?? 1.25) * 2
        case .dumbbell:
            return smallestGap(in: profile.availableDumbbellsKg) ?? 2.5
        case .kettlebell:
            return smallestGap(in: profile.kettlebellsKg) ?? 4
        case .machineStack:
            return profile.machineIncrementKg
        case .cableStack:
            return profile.cableIncrementKg
        case .weightedBodyweight, .assistedBodyweight:
            return 2.5
        case .band, .bodyweight, .fixedImplement, .none:
            return 0
        }
    }

    private static func roundToBarbell(_ value: Double, barWeight: Double, plates: [Double]) -> Double {
        guard value > barWeight else { return barWeight }
        let perSide = (value - barWeight) / 2
        let smallestPlate = plates.min() ?? 1.25
        let rounded = (perSide / smallestPlate).rounded() * smallestPlate
        return barWeight + rounded * 2
    }

    private static func roundToStep(_ value: Double, step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private static func nearest(_ value: Double, in options: [Double]) -> Double? {
        guard !options.isEmpty else { return nil }
        return options.min { abs($0 - value) < abs($1 - value) }
    }

    private static func smallestGap(in options: [Double]) -> Double? {
        guard options.count >= 2 else { return nil }
        let sorted = options.sorted()
        var smallest = Double.greatestFiniteMagnitude
        for index in 1..<sorted.count {
            smallest = min(smallest, sorted[index] - sorted[index - 1])
        }
        return smallest.isFinite && smallest > 0 ? smallest : nil
    }
}

/// The increment configuration `LoadRounding` needs, as a plain value type so engines and tests do
/// not have to touch SwiftData.
struct EquipmentIncrements: Hashable, Sendable {
    var barbellBarWeightKg: Double = 20
    var ezBarWeightKg: Double = 10
    var availablePlatesKg: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]
    var availableDumbbellsKg: [Double] = [
        2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22.5, 25, 27.5, 30, 32.5, 35, 37.5, 40, 45, 50
    ]
    var kettlebellsKg: [Double] = [8, 12, 16, 20, 24, 28, 32]
    var machineIncrementKg: Double = 5
    var cableIncrementKg: Double = 2.5

    static let `default` = EquipmentIncrements()
}

extension EquipmentProfile {
    var increments: EquipmentIncrements {
        EquipmentIncrements(
            barbellBarWeightKg: barbellBarWeightKg,
            ezBarWeightKg: ezBarWeightKg,
            availablePlatesKg: availablePlatesKg,
            availableDumbbellsKg: availableDumbbellsKg,
            kettlebellsKg: kettlebellsKg,
            machineIncrementKg: machineIncrementKg,
            cableIncrementKg: cableIncrementKg
        )
    }
}
