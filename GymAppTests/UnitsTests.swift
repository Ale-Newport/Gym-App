import Foundation
import Testing

@testable import GymApp

// MARK: - Mass, length, energy, time

@Suite("Unit conversion")
struct UnitConversionTests {

    @Test("Kilograms convert to pounds and back without losing the original value")
    func kilogramsToPoundsRoundTrip() {
        for kilograms in [0.0, 0.25, 1.25, 2.5, 20, 60.5, 102.058, 227.5, 1000] {
            let pounds = Units.display(kilograms: kilograms, unit: .pounds)
            let back = Units.kilograms(fromDisplay: pounds, unit: .pounds)
            #expect(
                abs(back - kilograms) < 1e-9,
                "\(kilograms) kg round-tripped through pounds as \(back)"
            )
        }
    }

    @Test("Kilograms and pounds use the international avoirdupois pound")
    func poundConversionUsesTheStandardFactor() {
        #expect(abs(Units.display(kilograms: 100, unit: .pounds) - 220.46226218487757) < 1e-9)
        #expect(abs(Units.kilograms(fromDisplay: 225, unit: .pounds) - 102.05828325) < 1e-9)
    }

    @Test("Kilograms are the identity conversion")
    func kilogramsAreTheCanonicalUnit() {
        #expect(Units.display(kilograms: 82.5, unit: .kilograms) == 82.5)
        #expect(Units.kilograms(fromDisplay: 82.5, unit: .kilograms) == 82.5)
        #expect(Units.display(kilograms: 0, unit: .pounds) == 0)
    }

    @Test("Negative loads convert without changing sign")
    func negativeLoadsKeepTheirSign() {
        let pounds = Units.display(kilograms: -10, unit: .pounds)
        #expect(pounds < 0)
        #expect(abs(Units.kilograms(fromDisplay: pounds, unit: .pounds) + 10) < 1e-9)
    }

    @Test("Feet and inches convert to centimetres and back")
    func feetAndInchesRoundTrip() {
        #expect(abs(Units.centimeters(fromFeet: 5, inches: 10) - 177.8) < 1e-9)
        #expect(abs(Units.centimeters(fromFeet: 0, inches: 0)) < 1e-12)
        #expect(abs(Units.centimeters(fromFeet: 6, inches: 0) - 182.88) < 1e-9)

        for centimeters in stride(from: 120.0, through: 220.0, by: 0.5) {
            let parts = Units.feetAndInches(fromCentimeters: centimeters)
            #expect(parts.inches >= 0, "\(centimeters) cm produced negative inches")
            #expect(parts.inches < 12, "\(centimeters) cm produced \(parts.inches) inches")
            let back = Units.centimeters(fromFeet: parts.feet, inches: parts.inches)
            #expect(abs(back - centimeters) < 1e-9, "\(centimeters) cm round-tripped as \(back)")
        }
    }

    @Test("A known height decomposes into the expected feet and inches")
    func knownHeightDecomposition() {
        let parts = Units.feetAndInches(fromCentimeters: 175)
        #expect(parts.feet == 5)
        #expect(abs(parts.inches - 8.897637795275591) < 1e-9)

        let shorter = Units.feetAndInches(fromCentimeters: 160)
        #expect(shorter.feet == 5)
        #expect(abs(shorter.inches - 2.99212598425197) < 1e-9)
    }

    @Test("Zero centimetres is zero feet and zero inches")
    func zeroHeightDecomposes() {
        let parts = Units.feetAndInches(fromCentimeters: 0)
        #expect(parts.feet == 0)
        #expect(parts.inches == 0)
    }

    @Test("Distance converts through the configured unit")
    func distanceConversion() {
        #expect(Units.meters(fromDisplay: 5, unit: .kilometers) == 5000)
        #expect(abs(Units.meters(fromDisplay: 3, unit: .miles) - 4828.032) < 1e-9)
        #expect(Units.meters(fromDisplay: 0, unit: .miles) == 0)
    }
}

// MARK: - Formatting

@Suite("Unit formatting")
struct UnitFormattingTests {

    private let posix = Locale(identifier: "en_US_POSIX")

    @Test("A whole load formats without a decimal, a fractional one keeps a single digit")
    func weightFormatting() {
        #expect(Units.formatWeight(kilograms: 100, unit: .kilograms, locale: posix) == "100 kg")
        #expect(Units.formatWeight(kilograms: 62.5, unit: .kilograms, locale: posix) == "62.5 kg")
        #expect(
            Units.formatWeight(kilograms: 62.5, unit: .kilograms, locale: posix, includeUnit: false) == "62.5"
        )
        #expect(Units.formatWeight(kilograms: 0, unit: .kilograms, locale: posix) == "0 kg")
    }

    @Test("A load shown in pounds is converted before it is formatted")
    func weightFormattingInPounds() {
        #expect(Units.formatWeight(kilograms: 100, unit: .pounds, locale: posix) == "220.5 lb")
    }

    @Test("Height formats as whole centimetres or as feet and inches")
    func heightFormatting() {
        #expect(Units.formatHeight(centimeters: 175, unit: .centimeters, locale: posix) == "175 cm")
        #expect(Units.formatHeight(centimeters: 175.4, unit: .centimeters, locale: posix) == "175 cm")
        #expect(Units.formatHeight(centimeters: 175, unit: .feetInches, locale: posix) == "5′ 9″")
        #expect(Units.formatHeight(centimeters: 160, unit: .feetInches, locale: posix) == "5′ 3″")
        #expect(Units.formatHeight(centimeters: 180, unit: .feetInches, locale: posix) == "5′ 11″")
    }

    /// DOCUMENTED PRODUCTION DEFECT — `Units.formatHeight(unit: .feetInches)` can print twelve
    /// inches. It rounds the inch remainder independently of the foot count, so a height whose
    /// remainder rounds up to 12 is shown as `5′ 12″` instead of carrying into `6′ 0″`.
    /// 182.5 cm is 71.850 in = 5 ft 11.850 in; the inch part rounds to 12.
    @Test("A height whose inches round up carries into the next foot")
    func heightNeverShowsTwelveInches() {
        #expect(Units.formatHeight(centimeters: 182.5, unit: .feetInches, locale: posix) == "6′ 0″")

        let offenders = stride(from: 120.0, through: 220.0, by: 0.1)
            .filter { Units.formatHeight(centimeters: $0, unit: .feetInches, locale: posix).contains("12″") }
        #expect(
            offenders.count == 0,
            "heights between 120 cm and 220 cm printing twelve inches, first five: \(Array(offenders.prefix(5)))"
        )
    }

    @Test("Energy converts to kilojoules before formatting")
    func energyFormatting() {
        #expect(Units.formatEnergy(kilocalories: 500, unit: .kilocalories, locale: posix) == "500 kcal")
        #expect(Units.formatEnergy(kilocalories: 100, unit: .kilojoules, locale: posix) == "418 kJ")
        #expect(
            Units.formatEnergy(kilocalories: 500, unit: .kilocalories, locale: posix, includeUnit: false) == "500"
        )
    }

    @Test("Durations format as mm:ss and grow an hour field past an hour")
    func durationFormatting() {
        #expect(Units.formatDuration(seconds: 0) == "0:00")
        #expect(Units.formatDuration(seconds: 5) == "0:05")
        #expect(Units.formatDuration(seconds: 59) == "0:59")
        #expect(Units.formatDuration(seconds: 60) == "1:00")
        #expect(Units.formatDuration(seconds: 3599) == "59:59")
        #expect(Units.formatDuration(seconds: 3600) == "1:00:00")
        #expect(Units.formatDuration(seconds: 3661) == "1:01:01")
    }

    @Test("A negative duration is clamped to zero rather than printed with a minus sign")
    func negativeDurationIsClamped() {
        #expect(Units.formatDuration(seconds: -1) == "0:00")
        #expect(Units.formatDuration(seconds: -3600) == "0:00")
    }

    @Test("A signed decimal carries its sign and zero carries none")
    func signedDecimalFormatting() {
        #expect(Units.formatSignedDecimal(2.5, locale: posix) == "+2.5")
        #expect(Units.formatSignedDecimal(-2.5, locale: posix) == "−2.5")
        #expect(Units.formatSignedDecimal(0, locale: posix) == "0")
    }

    @Test("Macro grams keep a decimal below ten and drop it above")
    func macroFormatting() {
        #expect(Units.formatMacro(grams: 5.5, locale: posix) == "5.5 g")
        #expect(Units.formatMacro(grams: 12.4, locale: posix) == "12 g")
        #expect(Units.formatMacro(grams: 0, locale: posix) == "0 g")
    }
}

// MARK: - Load rounding

@Suite("Load rounding onto selectable weights")
struct LoadRoundingTests {

    private let profile = EquipmentIncrements.default

    /// The barbell weights the default profile can actually produce.
    private func isSelectableBarbell(_ value: Double, barWeight: Double, smallestPlate: Double) -> Bool {
        guard value >= barWeight else { return false }
        let perSidePairs = (value - barWeight) / (2 * smallestPlate)
        return abs(perSidePairs - perSidePairs.rounded()) < 1e-9
    }

    @Test("Every barbell recommendation lands on a load the plates can build")
    func barbellRoundingIsAlwaysSelectable() {
        for step in stride(from: 0.0, through: 300.0, by: 0.1) {
            let rounded = LoadRounding.round(kilograms: step, loadability: .barbell, profile: profile)
            #expect(
                isSelectableBarbell(rounded, barWeight: 20, smallestPlate: 1.25),
                "\(step) kg rounded to \(rounded) kg, which no plate combination produces"
            )
        }
    }

    @Test("A barbell load below the bar is the bare bar, never less")
    func barbellNeverGoesBelowTheBar() {
        #expect(LoadRounding.round(kilograms: 0, loadability: .barbell, profile: profile) == 20)
        #expect(LoadRounding.round(kilograms: 19.9, loadability: .barbell, profile: profile) == 20)
        #expect(LoadRounding.round(kilograms: 20, loadability: .barbell, profile: profile) == 20)
        #expect(LoadRounding.round(kilograms: -50, loadability: .barbell, profile: profile) == 20)
    }

    @Test("A barbell load just past the bar rounds to the first loadable step")
    func barbellRoundsJustPastTheBar() {
        // Half of the smallest pair rounds up to a full pair of 1.25 kg plates.
        #expect(LoadRounding.round(kilograms: 21.5, loadability: .barbell, profile: profile) == 22.5)
        #expect(LoadRounding.round(kilograms: 72.3, loadability: .barbell, profile: profile) == 72.5)
        #expect(LoadRounding.round(kilograms: 100, loadability: .barbell, profile: profile) == 100)
    }

    @Test("An EZ bar rounds onto its own lighter bar weight")
    func ezBarUsesItsOwnBarWeight() {
        #expect(LoadRounding.round(kilograms: 5, loadability: .ezBar, profile: profile) == 10)
        #expect(LoadRounding.round(kilograms: 32.4, loadability: .ezBar, profile: profile) == 32.5)
    }

    @Test("Every dumbbell recommendation is a dumbbell the gym stocks")
    func dumbbellRoundingIsAlwaysOnTheRack() {
        for step in stride(from: 0.0, through: 80.0, by: 0.1) {
            let rounded = LoadRounding.round(kilograms: step, loadability: .dumbbell, profile: profile)
            #expect(
                profile.availableDumbbellsKg.contains(rounded),
                "\(step) kg rounded to \(rounded) kg, which is not on the rack"
            )
        }
    }

    @Test("A dumbbell rounds to the nearest one on the rack, including past the heaviest")
    func dumbbellRoundsToNearest() {
        #expect(LoadRounding.round(kilograms: 23.4, loadability: .dumbbell, profile: profile) == 22.5)
        #expect(LoadRounding.round(kilograms: 24, loadability: .dumbbell, profile: profile) == 25)
        #expect(LoadRounding.round(kilograms: 0, loadability: .dumbbell, profile: profile) == 2)
        #expect(LoadRounding.round(kilograms: 500, loadability: .dumbbell, profile: profile) == 50)
    }

    @Test("An empty dumbbell rack falls back to a 2.5 kg ladder rather than returning nothing")
    func emptyDumbbellRackFallsBack() {
        var bare = EquipmentIncrements.default
        bare.availableDumbbellsKg = []
        #expect(LoadRounding.round(kilograms: 23.4, loadability: .dumbbell, profile: bare) == 22.5)
        #expect(LoadRounding.round(kilograms: 24, loadability: .dumbbell, profile: bare) == 25)
    }

    @Test("Every machine and cable recommendation is a whole number of stack plates")
    func stackRoundingIsAlwaysSelectable() {
        for step in stride(from: 0.0, through: 200.0, by: 0.1) {
            let machine = LoadRounding.round(kilograms: step, loadability: .machineStack, profile: profile)
            let quotient = machine / profile.machineIncrementKg
            #expect(
                abs(quotient - quotient.rounded()) < 1e-9 && machine >= 0,
                "\(step) kg rounded to \(machine) kg, which is not a whole machine stack step"
            )

            let cable = LoadRounding.round(kilograms: step, loadability: .cableStack, profile: profile)
            let cableQuotient = cable / profile.cableIncrementKg
            #expect(
                abs(cableQuotient - cableQuotient.rounded()) < 1e-9 && cable >= 0,
                "\(step) kg rounded to \(cable) kg, which is not a whole cable stack step"
            )
        }
    }

    @Test("Known machine and cable roundings")
    func knownStackRoundings() {
        #expect(LoadRounding.round(kilograms: 37.4, loadability: .machineStack, profile: profile) == 35)
        #expect(LoadRounding.round(kilograms: 37.6, loadability: .machineStack, profile: profile) == 40)
        #expect(LoadRounding.round(kilograms: 37.4, loadability: .cableStack, profile: profile) == 37.5)
        #expect(LoadRounding.round(kilograms: 0, loadability: .machineStack, profile: profile) == 0)
    }

    @Test("Kettlebells round onto the bells the gym owns")
    func kettlebellRounding() {
        #expect(LoadRounding.round(kilograms: 17, loadability: .kettlebell, profile: profile) == 16)
        #expect(LoadRounding.round(kilograms: 30, loadability: .kettlebell, profile: profile) == 28)
        #expect(profile.kettlebellsKg.contains(
            LoadRounding.round(kilograms: 21.3, loadability: .kettlebell, profile: profile)
        ))
    }

    @Test("Unloadable movements round onto a half-kilogram grid rather than to nothing")
    func unloadableMovementsRoundToAHalfKilo() {
        for loadability in [Loadability.band, .bodyweight, .fixedImplement, Loadability.none] {
            let rounded = LoadRounding.round(kilograms: 7.3, loadability: loadability, profile: profile)
            #expect(rounded == 7.5, "\(loadability) rounded 7.3 to \(rounded)")
        }
        #expect(LoadRounding.round(kilograms: 7.3, loadability: .weightedBodyweight, profile: profile) == 7.5)
        #expect(LoadRounding.round(kilograms: 7.3, loadability: .assistedBodyweight, profile: profile) == 7.5)
    }

    @Test("A non-finite or negative load never escapes as a non-finite or negative recommendation")
    func nonFiniteAndNegativeInputsAreContained() {
        for loadability in Loadability.allCases {
            #expect(LoadRounding.round(kilograms: .nan, loadability: loadability, profile: profile) == 0)
            #expect(LoadRounding.round(kilograms: .infinity, loadability: loadability, profile: profile) == 0)

            let negative = LoadRounding.round(kilograms: -25, loadability: loadability, profile: profile)
            #expect(negative >= 0, "\(loadability) turned -25 kg into \(negative)")
            #expect(negative.isFinite)
        }
    }

    @Test("The smallest barbell increment is a pair of the lightest plates")
    func barbellIncrementIsAPairOfLightestPlates() {
        #expect(LoadRounding.increment(for: .barbell, profile: profile) == 2.5)
        #expect(LoadRounding.increment(for: .ezBar, profile: profile) == 2.5)

        var micro = EquipmentIncrements.default
        micro.availablePlatesKg = [20, 10, 5, 2.5, 1.25, 0.5]
        #expect(LoadRounding.increment(for: .barbell, profile: micro) == 1.0)

        var noPlates = EquipmentIncrements.default
        noPlates.availablePlatesKg = []
        #expect(LoadRounding.increment(for: .barbell, profile: noPlates) == 2.5)
    }

    @Test("The smallest dumbbell increment is the tightest gap on the rack")
    func dumbbellIncrementIsTheTightestGap() {
        #expect(LoadRounding.increment(for: .dumbbell, profile: profile) == 2)

        var sparse = EquipmentIncrements.default
        sparse.availableDumbbellsKg = [10, 20, 30]
        #expect(LoadRounding.increment(for: .dumbbell, profile: sparse) == 10)

        var single = EquipmentIncrements.default
        single.availableDumbbellsKg = [10]
        #expect(LoadRounding.increment(for: .dumbbell, profile: single) == 2.5)

        var empty = EquipmentIncrements.default
        empty.availableDumbbellsKg = []
        #expect(LoadRounding.increment(for: .dumbbell, profile: empty) == 2.5)
    }

    @Test("Stack increments come straight from the gym's configuration")
    func stackIncrementsComeFromTheProfile() {
        #expect(LoadRounding.increment(for: .machineStack, profile: profile) == 5)
        #expect(LoadRounding.increment(for: .cableStack, profile: profile) == 2.5)
        #expect(LoadRounding.increment(for: .kettlebell, profile: profile) == 4)
        #expect(LoadRounding.increment(for: .weightedBodyweight, profile: profile) == 2.5)
        #expect(LoadRounding.increment(for: .assistedBodyweight, profile: profile) == 2.5)
    }

    @Test("Movements that carry no external load report no increment")
    func unloadableMovementsHaveNoIncrement() {
        #expect(LoadRounding.increment(for: .band, profile: profile) == 0)
        #expect(LoadRounding.increment(for: .bodyweight, profile: profile) == 0)
        #expect(LoadRounding.increment(for: .fixedImplement, profile: profile) == 0)
        #expect(LoadRounding.increment(for: Loadability.none, profile: profile) == 0)
    }

    @Test("Adding one increment to a rounded load lands on another selectable load")
    func addingAnIncrementStaysSelectable() {
        let start = LoadRounding.round(kilograms: 60, loadability: .barbell, profile: profile)
        let stepped = start + LoadRounding.increment(for: .barbell, profile: profile)
        #expect(LoadRounding.round(kilograms: stepped, loadability: .barbell, profile: profile) == stepped)

        let machineStart = LoadRounding.round(kilograms: 40, loadability: .machineStack, profile: profile)
        let machineStepped = machineStart + LoadRounding.increment(for: .machineStack, profile: profile)
        #expect(
            LoadRounding.round(kilograms: machineStepped, loadability: .machineStack, profile: profile)
                == machineStepped
        )
    }

    @Test("An equipment profile row maps onto the increments value type field by field")
    func equipmentProfileMapsOntoIncrements() throws {
        let equipment = EquipmentProfile()
        equipment.barbellBarWeightKg = 15
        equipment.ezBarWeightKg = 7.5
        equipment.availablePlatesKg = [20, 10, 5, 2.5, 1.25]
        equipment.availableDumbbellsKg = [5, 10, 15]
        equipment.kettlebellsKg = [12, 16]
        equipment.machineIncrementKg = 4
        equipment.cableIncrementKg = 1.25

        let increments = equipment.increments
        #expect(increments.barbellBarWeightKg == 15)
        #expect(increments.ezBarWeightKg == 7.5)
        #expect(increments.availablePlatesKg == [20, 10, 5, 2.5, 1.25])
        #expect(increments.availableDumbbellsKg == [5, 10, 15])
        #expect(increments.kettlebellsKg == [12, 16])
        #expect(increments.machineIncrementKg == 4)
        #expect(increments.cableIncrementKg == 1.25)
        #expect(LoadRounding.round(kilograms: 60, loadability: .barbell, profile: increments) == 60)
    }
}

// MARK: - Day keys

@Suite("Day keys")
struct DayKeyTests {

    private func calendar(_ timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private let instant = Date(timeIntervalSince1970: 1_717_405_200) // 2024-06-03 09:00 UTC

    @Test("A day key is the local calendar day, whatever the device language")
    func keyIsTheLocalCalendarDay() {
        #expect(DayKey.make(from: instant, calendar: calendar("UTC")) == "2024-06-03")
        #expect(DayKey.make(from: instant, calendar: calendar("America/New_York")) == "2024-06-03")
        #expect(DayKey.make(from: instant, calendar: calendar("Asia/Kathmandu")) == "2024-06-03")
        // Far enough west that 09:00 UTC is still the previous local day.
        #expect(DayKey.make(from: instant, calendar: calendar("Pacific/Pago_Pago")) == "2024-06-02")
    }

    @Test("The same instant and calendar always produce the same key")
    func keyIsStableForRepeatedReads() {
        let zones = ["UTC", "America/New_York", "Europe/Madrid", "Asia/Kathmandu", "Pacific/Auckland"]
        for zone in zones {
            let first = DayKey.make(from: instant, calendar: calendar(zone))
            for _ in 0..<5 {
                #expect(DayKey.make(from: instant, calendar: calendar(zone)) == first)
            }
        }
    }

    @Test("A key parses back to a date that produces the same key")
    func keyRoundTripsThroughADate() throws {
        let keys = ["2024-01-01", "2024-02-29", "2024-03-10", "2024-11-03", "2024-12-31", "2025-06-15"]
        for zone in ["UTC", "America/New_York", "Europe/Madrid", "Asia/Kathmandu", "Pacific/Auckland"] {
            let cal = calendar(zone)
            for key in keys {
                let date = try #require(DayKey.date(from: key, calendar: cal), "\(key) in \(zone)")
                #expect(DayKey.make(from: date, calendar: cal) == key, "\(key) in \(zone)")
            }
        }
    }

    @Test("Offset arithmetic advances exactly one calendar day, in every time zone")
    func offsetAdvancesOneCalendarDay() {
        for zone in ["UTC", "America/New_York", "Europe/Madrid", "Asia/Kathmandu", "Pacific/Auckland"] {
            let cal = calendar(zone)
            #expect(DayKey.offset(from: "2024-06-03", days: 1, calendar: cal) == "2024-06-04")
            #expect(DayKey.offset(from: "2024-06-03", days: -1, calendar: cal) == "2024-06-02")
            #expect(DayKey.offset(from: "2024-06-03", days: 0, calendar: cal) == "2024-06-03")
            #expect(DayKey.offset(from: "2024-06-03", days: 7, calendar: cal) == "2024-06-10")
        }
    }

    @Test("Offset arithmetic survives a daylight-saving transition")
    func offsetSurvivesDaylightSaving() {
        let newYork = calendar("America/New_York")
        // Spring forward: 2024-03-10 is a 23-hour day.
        #expect(DayKey.offset(from: "2024-03-09", days: 1, calendar: newYork) == "2024-03-10")
        #expect(DayKey.offset(from: "2024-03-10", days: 1, calendar: newYork) == "2024-03-11")
        // Fall back: 2024-11-03 is a 25-hour day.
        #expect(DayKey.offset(from: "2024-11-02", days: 1, calendar: newYork) == "2024-11-03")
        #expect(DayKey.offset(from: "2024-11-03", days: 1, calendar: newYork) == "2024-11-04")

        let madrid = calendar("Europe/Madrid")
        #expect(DayKey.offset(from: "2024-03-30", days: 1, calendar: madrid) == "2024-03-31")
        #expect(DayKey.offset(from: "2024-03-31", days: 1, calendar: madrid) == "2024-04-01")
    }

    @Test("Offset arithmetic crosses month, leap-day and year boundaries")
    func offsetCrossesBoundaries() {
        let utc = calendar("UTC")
        #expect(DayKey.offset(from: "2024-02-28", days: 1, calendar: utc) == "2024-02-29")
        #expect(DayKey.offset(from: "2024-02-28", days: 2, calendar: utc) == "2024-03-01")
        #expect(DayKey.offset(from: "2023-02-28", days: 1, calendar: utc) == "2023-03-01")
        #expect(DayKey.offset(from: "2024-12-31", days: 1, calendar: utc) == "2025-01-01")
        #expect(DayKey.offset(from: "2025-01-01", days: -1, calendar: utc) == "2024-12-31")
        #expect(DayKey.offset(from: "2024-06-03", days: -365, calendar: utc) == "2023-06-04")
    }

    @Test("Offsetting forwards and back returns the original key")
    func offsetIsReversible() {
        let utc = calendar("UTC")
        for days in [1, 3, 7, 30, 365] {
            let forward = DayKey.offset(from: "2024-03-09", days: days, calendar: utc)
            #expect(DayKey.offset(from: forward, days: -days, calendar: utc) == "2024-03-09")
        }
    }

    @Test("An unparseable key is returned unchanged rather than becoming today")
    func unparseableKeysArePassedThrough() {
        let utc = calendar("UTC")
        #expect(DayKey.date(from: "not-a-day", calendar: utc) == nil)
        #expect(DayKey.date(from: "", calendar: utc) == nil)
        #expect(DayKey.offset(from: "not-a-day", days: 1, calendar: utc) == "not-a-day")
        #expect(DayKey.offset(from: "", days: -3, calendar: utc) == "")
    }

    @Test("Keys sort lexicographically in chronological order")
    func keysSortChronologically() {
        let utc = calendar("UTC")
        var keys: [String] = []
        var key = "2024-12-28"
        for _ in 0..<10 {
            keys.append(key)
            key = DayKey.offset(from: key, days: 1, calendar: utc)
        }
        #expect(keys == keys.sorted())
        #expect(keys.first == "2024-12-28")
        #expect(keys.last == "2025-01-06")
    }
}
