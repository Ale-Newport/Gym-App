import SwiftUI
import SwiftData

/// Formats values for display using the user's chosen units.
///
/// Views must never reach into `Units` directly with a hard-coded unit — that is how half a screen
/// ends up in kilograms and the other half in pounds. They take a `DisplayFormatter` from the
/// environment, which carries the current `UserSettings` and the active locale.
struct DisplayFormatter: Sendable {
    var weightUnit: WeightUnit = .kilograms
    var heightUnit: HeightUnit = .centimeters
    var distanceUnit: DistanceUnit = .kilometers
    var energyUnit: EnergyUnit = .kilocalories
    var locale: Locale = .current

    init() {}

    init(settings: UserSettings?, locale: Locale = .current) {
        self.weightUnit = settings?.weightUnit ?? .kilograms
        self.heightUnit = settings?.heightUnit ?? .centimeters
        self.distanceUnit = settings?.distanceUnit ?? .kilometers
        self.energyUnit = settings?.energyUnit ?? .kilocalories
        self.locale = locale
    }

    // MARK: - Load

    func weight(_ kilograms: Double, includeUnit: Bool = true) -> String {
        Units.formatWeight(kilograms: kilograms, unit: weightUnit, locale: locale, includeUnit: includeUnit)
    }

    /// The number alone, for text fields and steppers.
    func weightValue(_ kilograms: Double) -> Double {
        Units.display(kilograms: kilograms, unit: weightUnit)
    }

    func kilograms(fromDisplayed value: Double) -> Double {
        Units.kilograms(fromDisplay: value, unit: weightUnit)
    }

    var weightUnitLabel: String { weightUnit.rawValue }

    /// Tonnage reads better abbreviated once it passes a tonne.
    func volume(_ kilograms: Double) -> String {
        let displayed = Units.display(kilograms: kilograms, unit: weightUnit)
        if displayed >= 10_000 {
            return Units.joinUnit(Units.formatDecimal(displayed / 1000, digits: 1, locale: locale), "t")
        }
        return Units.joinUnit(Units.formatDecimal(displayed, digits: 0, locale: locale), weightUnitLabel)
    }

    // MARK: - Body

    func height(_ centimeters: Double) -> String {
        Units.formatHeight(centimeters: centimeters, unit: heightUnit, locale: locale)
    }

    func distance(_ meters: Double) -> String {
        Units.formatDistance(meters: meters, unit: distanceUnit, locale: locale)
    }

    // MARK: - Nutrition

    func energy(_ kilocalories: Double, includeUnit: Bool = true) -> String {
        Units.formatEnergy(kilocalories: kilocalories, unit: energyUnit, locale: locale, includeUnit: includeUnit)
    }

    var energyUnitLabel: String { energyUnit.rawValue }

    func macro(_ grams: Double) -> String {
        Units.formatMacro(grams: grams, locale: locale)
    }

    // MARK: - Time

    func duration(_ seconds: Int) -> String { Units.formatDuration(seconds: seconds) }

    @MainActor
    func durationCompact(_ seconds: Int) -> String { Units.formatDurationCompact(seconds: seconds) }

    // MARK: - Dates

    func mediumDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }

    func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
    }

    func weekdayAndDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(locale))
    }

    func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    /// "Today", "Yesterday", or a date. Used everywhere a log is listed by day.
    @MainActor
    func relativeDay(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return L("common.today") }
        if calendar.isDateInYesterday(date) { return L("common.yesterday") }
        if calendar.isDateInTomorrow(date) { return L("common.tomorrow") }
        return weekdayAndDate(date)
    }
}

private struct DisplayFormatterKey: EnvironmentKey {
    static let defaultValue = DisplayFormatter()
}

extension EnvironmentValues {
    var displayFormatter: DisplayFormatter {
        get { self[DisplayFormatterKey.self] }
        set { self[DisplayFormatterKey.self] = newValue }
    }
}

/// Reads `UserSettings` and publishes a matching `DisplayFormatter` into the environment.
/// Placed once, high in the tree, so a unit change updates every screen at once.
struct DisplayFormatterProvider<Content: View>: View {
    @Query private var settings: [UserSettings]
    @Environment(LocalizationManager.self) private var localization
    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(\.displayFormatter, DisplayFormatter(
                settings: settings.first,
                locale: localization.current.locale
            ))
    }
}
