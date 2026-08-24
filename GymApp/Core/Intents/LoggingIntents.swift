import AppIntents
import Foundation
import SwiftData

// MARK: - Body weight

/// Records a body-mass reading without opening the app.
///
/// This one writes directly. A weigh-in is a single number with no follow-up decision, it is
/// logged at a moment when the phone is usually face-down on a bathroom shelf, and `InputValidation`
/// already owns the question of which numbers the app accepts — so there is nothing a screen would
/// add. See `IntentModelStore` for why writing from an intent is safe here.
struct LogBodyWeightIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intents.logBodyWeight.title")

    static var description = IntentDescription(
        LocalizedStringResource("intents.logBodyWeight.description")
    )

    /// Deliberately false: the whole point is that the app stays closed.
    static var openAppWhenRun: Bool = false

    /// `defaultUnitAdjustForLocale` is what puts pounds in front of a user in the United States and
    /// kilograms in front of everyone else, without the app having to read its own settings from a
    /// process that may not have opened the store yet.
    @Parameter(
        title: LocalizedStringResource("intents.logBodyWeight.parameter"),
        defaultUnit: .kilograms,
        defaultUnitAdjustForLocale: true,
        supportsNegativeNumbers: false
    )
    var weight: Measurement<UnitMass>

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let kilograms = weight.converted(to: .kilograms).value
        guard kilograms.isFinite, kilograms > 0 else { throw IntentFailure.valueOutOfRange }

        let context = try IntentModelStore.context()
        let repository = ProgressRepository(context: context)
        do {
            try repository.addBodyWeight(kg: kilograms)
        } catch {
            AppLog.persistence.error(
                "Body weight intent refused: \(String(describing: error), privacy: .public)"
            )
            throw IntentFailure.valueOutOfRange
        }
        IntentModelStore.publishSnapshot(context: context)

        // Echoed in whatever unit the user gave, which is the unit they are thinking in.
        let spoken = IntentMeasurementFormat.asGiven(weight)
        return .result(dialog: IntentDialog(
            LocalizedStringResource(stringLiteral: L("intents.logBodyWeight.logged", spoken))
        ))
    }
}

// MARK: - Water

/// Adds a drink to today's water log.
///
/// The default is one glass, because the overwhelmingly common request is "log a glass of water"
/// with no amount attached, and an intent that demands a number for that is an intent nobody uses.
struct LogWaterIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intents.logWater.title")

    static var description = IntentDescription(
        LocalizedStringResource("intents.logWater.description")
    )

    static var openAppWhenRun: Bool = false

    /// One glass. The unit is pinned rather than adjusted for locale, because "250" is only a
    /// sensible default while it means millilitres.
    @Parameter(
        title: LocalizedStringResource("intents.logWater.parameter"),
        defaultValue: 250,
        defaultUnit: .milliliters,
        supportsNegativeNumbers: false
    )
    var amount: Measurement<UnitVolume>

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let millilitres = amount.converted(to: .milliliters).value
        guard millilitres.isFinite, millilitres > 0 else { throw IntentFailure.valueOutOfRange }

        let context = try IntentModelStore.context()
        let repository = NutritionRepository(context: context)
        // `addWater` clamps to the range the app will store, so an absurd amount becomes a large
        // one rather than a rejection — the user did mean to drink something.
        let entry = try repository.addWater(milliliters: millilitres)
        let total = (try? repository.waterTotal()) ?? entry.milliliters
        IntentModelStore.publishSnapshot(context: context)

        let logged = IntentMeasurementFormat.asGiven(
            Measurement<UnitVolume>(value: entry.milliliters, unit: .milliliters)
        )
        let today = IntentMeasurementFormat.naturalVolume(millilitres: total)
        return .result(dialog: IntentDialog(
            LocalizedStringResource(stringLiteral: L("intents.logWater.logged", logged, today))
        ))
    }
}

// MARK: - Meals

/// Opens the food picker for one meal.
///
/// Unlike a weight or a glass of water, logging food is a choice — which food, which portion — so
/// this intent takes the user to the right screen rather than guessing. The slot is the one thing
/// worth asking for up front, because it is what decides where the entry lands.
struct AddMealIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intents.addMeal.title")

    static var description = IntentDescription(
        LocalizedStringResource("intents.addMeal.description")
    )

    static var openAppWhenRun: Bool = true

    @Parameter(title: LocalizedStringResource("intents.addMeal.parameter"))
    var meal: MealSlotAppValue

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkInbox.shared.post(.addMeal(meal.slot))
        return .result()
    }
}

/// The Shortcuts-facing mirror of `MealSlot`.
///
/// A separate type rather than conforming the model enum to `AppEnum`: the display names shown in
/// Shortcuts are a presentation concern, and `MealSlot` lives in the domain layer, which does not
/// import App Intents.
enum MealSlotAppValue: String, AppEnum, CaseIterable {
    case breakfast
    case lunch
    case dinner
    case snacks

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: LocalizedStringResource("intents.mealSlot.type"))
    }

    /// Reuses the app's own meal-slot strings, so Siri and the Nutrition tab never disagree.
    static var caseDisplayRepresentations: [MealSlotAppValue: DisplayRepresentation] {
        [
            .breakfast: DisplayRepresentation(title: LocalizedStringResource("meal.breakfast")),
            .lunch: DisplayRepresentation(title: LocalizedStringResource("meal.lunch")),
            .dinner: DisplayRepresentation(title: LocalizedStringResource("meal.dinner")),
            .snacks: DisplayRepresentation(title: LocalizedStringResource("meal.snacks")),
        ]
    }

    init(_ slot: MealSlot) {
        self = MealSlotAppValue(rawValue: slot.rawValue) ?? .breakfast
    }

    var slot: MealSlot {
        MealSlot(rawValue: rawValue) ?? .breakfast
    }
}

// MARK: - Formatting

/// Measurement formatting for spoken and written intent confirmations.
///
/// Separate from `Units` because the app's formatter answers "in the unit this user picked in
/// Settings", and an intent confirmation should answer "in the unit this user just said". Repeating
/// "500 ml" back as "17.6 fl oz" would read as though the intent had misheard.
enum IntentMeasurementFormat {

    /// Echoes a measurement in exactly the unit it arrived in.
    static func asGiven<U: Unit>(_ measurement: Measurement<U>) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter.string(from: measurement)
    }

    /// A running total, allowed to scale into the unit that reads best — 1,500 ml becomes 1.5 L.
    static func naturalVolume(millilitres: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.unitOptions = .naturalScale
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter.string(from: Measurement(value: millilitres, unit: UnitVolume.milliliters))
    }
}
