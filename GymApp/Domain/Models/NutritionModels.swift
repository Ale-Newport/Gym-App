import Foundation
import SwiftData

// MARK: - Nutrient value types

/// Energy and macronutrients for a given quantity of food. Canonical units: kcal and grams.
struct MacroNutrients: Codable, Hashable, Sendable {
    var kilocalories: Double = 0
    var proteinG: Double = 0
    var carbsG: Double = 0
    var fatG: Double = 0

    static let zero = MacroNutrients()

    static func + (lhs: MacroNutrients, rhs: MacroNutrients) -> MacroNutrients {
        MacroNutrients(
            kilocalories: lhs.kilocalories + rhs.kilocalories,
            proteinG: lhs.proteinG + rhs.proteinG,
            carbsG: lhs.carbsG + rhs.carbsG,
            fatG: lhs.fatG + rhs.fatG
        )
    }

    static func - (lhs: MacroNutrients, rhs: MacroNutrients) -> MacroNutrients {
        MacroNutrients(
            kilocalories: lhs.kilocalories - rhs.kilocalories,
            proteinG: lhs.proteinG - rhs.proteinG,
            carbsG: lhs.carbsG - rhs.carbsG,
            fatG: lhs.fatG - rhs.fatG
        )
    }

    static func * (lhs: MacroNutrients, factor: Double) -> MacroNutrients {
        MacroNutrients(
            kilocalories: lhs.kilocalories * factor,
            proteinG: lhs.proteinG * factor,
            carbsG: lhs.carbsG * factor,
            fatG: lhs.fatG * factor
        )
    }

    /// Energy implied by the macros, using 4/4/9 kcal per gram. Used to sanity-check custom foods.
    var derivedKilocalories: Double {
        proteinG * 4 + carbsG * 4 + fatG * 9
    }
}

/// Micronutrients for a given quantity of food.
///
/// Every field is optional on purpose. `nil` means "this food's data does not include the value";
/// `0` means "the food genuinely contains none". Conflating the two would let the app claim a
/// deficiency that the data cannot support.
struct Micronutrients: Codable, Hashable, Sendable {
    var fiberG: Double?
    var sugarG: Double?
    var saturatedFatG: Double?
    var cholesterolMg: Double?
    var sodiumMg: Double?
    var potassiumMg: Double?
    var calciumMg: Double?
    var ironMg: Double?
    var magnesiumMg: Double?
    var zincMg: Double?
    var phosphorusMg: Double?
    var seleniumUg: Double?
    var vitaminAUg: Double?
    var vitaminCMg: Double?
    var vitaminDUg: Double?
    var vitaminEMg: Double?
    var vitaminKUg: Double?
    var thiaminMg: Double?
    var riboflavinMg: Double?
    var niacinMg: Double?
    var vitaminB6Mg: Double?
    var folateUg: Double?
    var vitaminB12Ug: Double?

    static let unknown = Micronutrients()

    // MARK: - Persistence

    /// JSON encoding used by the SwiftData models that store a profile.
    ///
    /// Storing this type as a SwiftData *composite attribute* does not work: every field is
    /// optional — which is the entire point, since a missing value is not zero — and a value whose
    /// fields are all nil round-trips as `nil`, which then crashes on read with
    /// "Could not cast value of type 'Swift.Optional<Any>' to 'Micronutrients'". Encoding to `Data`
    /// keeps the unknown-versus-zero distinction intact and cannot degenerate.
    var encodedForStorage: Data? {
        guard self != .unknown else { return nil }
        return try? JSONEncoder().encode(self)
    }

    /// Inverse of `encodedForStorage`. Absent or unreadable storage means "nothing is known",
    /// which is the correct reading — never a profile full of zeroes.
    static func decodeFromStorage(_ data: Data?) -> Micronutrients {
        guard let data else { return .unknown }
        return (try? JSONDecoder().decode(Micronutrients.self, from: data)) ?? .unknown
    }

    /// Scales every *known* value; unknown values stay unknown.
    func scaled(by factor: Double) -> Micronutrients {
        var copy = self
        for nutrient in Micronutrient.allCases {
            if let value = copy[nutrient] { copy[nutrient] = value * factor }
        }
        return copy
    }

    /// Adds two profiles. A nutrient known in either operand stays known; unknown is treated as a
    /// contribution of zero but the result is only marked known if at least one side knew it.
    static func + (lhs: Micronutrients, rhs: Micronutrients) -> Micronutrients {
        var result = Micronutrients()
        for nutrient in Micronutrient.allCases {
            let a = lhs[nutrient], b = rhs[nutrient]
            if a == nil && b == nil { continue }
            result[nutrient] = (a ?? 0) + (b ?? 0)
        }
        return result
    }

    subscript(nutrient: Micronutrient) -> Double? {
        get {
            switch nutrient {
            case .fiber: fiberG
            case .sugar: sugarG
            case .saturatedFat: saturatedFatG
            case .cholesterol: cholesterolMg
            case .sodium: sodiumMg
            case .potassium: potassiumMg
            case .calcium: calciumMg
            case .iron: ironMg
            case .magnesium: magnesiumMg
            case .zinc: zincMg
            case .phosphorus: phosphorusMg
            case .selenium: seleniumUg
            case .vitaminA: vitaminAUg
            case .vitaminC: vitaminCMg
            case .vitaminD: vitaminDUg
            case .vitaminE: vitaminEMg
            case .vitaminK: vitaminKUg
            case .thiamin: thiaminMg
            case .riboflavin: riboflavinMg
            case .niacin: niacinMg
            case .vitaminB6: vitaminB6Mg
            case .folate: folateUg
            case .vitaminB12: vitaminB12Ug
            }
        }
        set {
            switch nutrient {
            case .fiber: fiberG = newValue
            case .sugar: sugarG = newValue
            case .saturatedFat: saturatedFatG = newValue
            case .cholesterol: cholesterolMg = newValue
            case .sodium: sodiumMg = newValue
            case .potassium: potassiumMg = newValue
            case .calcium: calciumMg = newValue
            case .iron: ironMg = newValue
            case .magnesium: magnesiumMg = newValue
            case .zinc: zincMg = newValue
            case .phosphorus: phosphorusMg = newValue
            case .selenium: seleniumUg = newValue
            case .vitaminA: vitaminAUg = newValue
            case .vitaminC: vitaminCMg = newValue
            case .vitaminD: vitaminDUg = newValue
            case .vitaminE: vitaminEMg = newValue
            case .vitaminK: vitaminKUg = newValue
            case .thiamin: thiaminMg = newValue
            case .riboflavin: riboflavinMg = newValue
            case .niacin: niacinMg = newValue
            case .vitaminB6: vitaminB6Mg = newValue
            case .folate: folateUg = newValue
            case .vitaminB12: vitaminB12Ug = newValue
            }
        }
    }
}

/// The micronutrients the app tracks, with their units and reference intakes.
enum Micronutrient: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case fiber, sugar, saturatedFat, cholesterol
    case sodium, potassium, calcium, iron, magnesium, zinc, phosphorus, selenium
    case vitaminA, vitaminC, vitaminD, vitaminE, vitaminK
    case thiamin, riboflavin, niacin, vitaminB6, folate, vitaminB12

    var id: String { rawValue }
    var localizationKey: String { "micro.\(rawValue)" }

    enum Unit: String, Codable, Sendable { case gram = "g", milligram = "mg", microgram = "µg" }

    var unit: Unit {
        switch self {
        case .fiber, .sugar, .saturatedFat: .gram
        case .cholesterol, .sodium, .potassium, .calcium, .iron, .magnesium, .zinc,
             .phosphorus, .vitaminC, .vitaminE, .thiamin, .riboflavin, .niacin, .vitaminB6: .milligram
        case .selenium, .vitaminA, .vitaminD, .vitaminK, .folate, .vitaminB12: .microgram
        }
    }

    /// Adult daily reference intake used only to draw a progress bar. Not medical advice, and
    /// deliberately a single non-sex-specific figure so the app never implies clinical precision.
    /// Values follow the EU Nutrition Reference Values (Regulation 1169/2011, Annex XIII) where
    /// one exists, and common dietary guidance otherwise.
    var referenceDailyIntake: Double? {
        switch self {
        case .fiber: 30
        case .sugar: nil
        case .saturatedFat: nil
        case .cholesterol: nil
        case .sodium: 2000
        case .potassium: 2000
        case .calcium: 800
        case .iron: 14
        case .magnesium: 375
        case .zinc: 10
        case .phosphorus: 700
        case .selenium: 55
        case .vitaminA: 800
        case .vitaminC: 80
        case .vitaminD: 5
        case .vitaminE: 12
        case .vitaminK: 75
        case .thiamin: 1.1
        case .riboflavin: 1.4
        case .niacin: 16
        case .vitaminB6: 1.4
        case .folate: 200
        case .vitaminB12: 2.5
        }
    }

    /// Nutrients where a *lower* number is the healthier direction, shown with an inverted bar.
    var isLimitingNutrient: Bool {
        switch self {
        case .sodium, .sugar, .saturatedFat, .cholesterol: true
        default: false
        }
    }

    static var vitamins: [Micronutrient] {
        [.vitaminA, .vitaminC, .vitaminD, .vitaminE, .vitaminK,
         .thiamin, .riboflavin, .niacin, .vitaminB6, .folate, .vitaminB12]
    }

    static var minerals: [Micronutrient] {
        [.sodium, .potassium, .calcium, .iron, .magnesium, .zinc, .phosphorus, .selenium]
    }

    static var otherNutrients: [Micronutrient] {
        [.fiber, .sugar, .saturatedFat, .cholesterol]
    }
}

// MARK: - Food

/// Where a food came from. Determines whether the user may edit it and how it is de-duplicated.
enum FoodSource: String, CaseIterable, Codable, Hashable, Sendable {
    case builtIn
    case custom
    case openFoodFacts
    case usda
    case recipe

    var localizationKey: String { "foodSource.\(rawValue)" }
    var isUserEditable: Bool { self == .custom || self == .recipe }
}

/// One food, stored with nutrition per 100 g (or 100 ml for liquids) as the canonical basis.
/// Portion maths always goes through `nutrients(forQuantity:unit:)`, never through ad-hoc scaling.
@Model
final class FoodItem {
    // `\.id` is indexed because look-up by id is the hottest read in the app: every logged row,
    // every saved-meal total and every recipe ingredient resolves its food that way.
    #Index<FoodItem>([\.id], [\.name], [\.barcode], [\.sourceRaw])

    var id: UUID = UUID()
    /// Stable identifier for built-in foods so a database refresh updates rather than duplicates.
    var catalogID: String?
    var name: String = ""
    var brand: String?
    var barcode: String?
    var sourceRaw: String = FoodSource.custom.rawValue

    /// Canonical basis: values per 100 g or 100 ml.
    var kilocaloriesPer100: Double = 0
    var proteinGPer100: Double = 0
    var carbsGPer100: Double = 0
    var fatGPer100: Double = 0
    /// Backing storage. See `Micronutrients.encodedForStorage` for why this is `Data` and not a
    /// composite attribute.
    var micronutrientsPer100Storage: Data?

    /// Whether the basis is mass (g) or volume (ml).
    var basisUnit: ServingUnit = ServingUnit.grams
    /// Named portions, e.g. "1 medium (118 g)".
    var servings: [FoodServing] = []
    /// Grams in one `.piece`, when the food is naturally counted.
    var gramsPerPiece: Double?

    /// Tags used by dietary filters and the meal recommender:
    /// diet tags (`meat`, `dairy`, `egg`…), allergen tags (`gluten`, `nuts`…) and
    /// role tags (`protein_source`, `breakfast`, `quick`…).
    var dietaryTags: [String] = []
    var allergenTags: [String] = []
    var roleTags: [String] = []

    var isFavorite: Bool = false
    var timesLogged: Int = 0
    var lastLoggedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Provenance string shown in the food detail screen.
    var attribution: String?
    /// Rough cost per 100 g in the user's currency, used only when a food budget is set.
    var costPer100: Double?

    init() {}

    var source: FoodSource {
        get { FoodSource(rawValue: sourceRaw) ?? .custom }
        set { sourceRaw = newValue.rawValue }
    }

    /// Micronutrients per 100 g or 100 ml. Unknown nutrients stay unknown.
    var micronutrientsPer100: Micronutrients {
        get { Micronutrients.decodeFromStorage(micronutrientsPer100Storage) }
        set { micronutrientsPer100Storage = newValue.encodedForStorage }
    }

    var macrosPer100: MacroNutrients {
        MacroNutrients(
            kilocalories: kilocaloriesPer100,
            proteinG: proteinGPer100,
            carbsG: carbsGPer100,
            fatG: fatGPer100
        )
    }

    /// Grams (or millilitres) represented by `quantity` of `unit`.
    func basisQuantity(for quantity: Double, unit: ServingUnit, servingIndex: Int? = nil) -> Double {
        switch unit {
        case .grams, .milliliters:
            return quantity
        case .piece:
            return quantity * (gramsPerPiece ?? 100)
        case .serving:
            let serving = servingIndex.flatMap { servings.indices.contains($0) ? servings[$0] : nil }
                ?? servings.first
            return quantity * (serving?.gramsPerServing ?? 100)
        }
    }

    func macros(forQuantity quantity: Double, unit: ServingUnit, servingIndex: Int? = nil) -> MacroNutrients {
        macrosPer100 * (basisQuantity(for: quantity, unit: unit, servingIndex: servingIndex) / 100)
    }

    func micronutrients(forQuantity quantity: Double, unit: ServingUnit, servingIndex: Int? = nil) -> Micronutrients {
        micronutrientsPer100.scaled(by: basisQuantity(for: quantity, unit: unit, servingIndex: servingIndex) / 100)
    }
}

/// A named portion of a food, e.g. "1 slice — 28 g".
struct FoodServing: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    /// Displayed as written; localisation of built-in servings happens through `nameKey`.
    var name: String
    var nameKey: String?
    var gramsPerServing: Double

    init(name: String, nameKey: String? = nil, gramsPerServing: Double) {
        self.name = name
        self.nameKey = nameKey
        self.gramsPerServing = gramsPerServing
    }
}

// MARK: - Logging

/// One food eaten on one day, in one meal slot.
@Model
final class FoodLogEntry {
    #Index<FoodLogEntry>([\.dayKey], [\.loggedAt])

    var id: UUID = UUID()
    /// `yyyy-MM-dd` in the user's calendar. Indexed so a day's log is a single cheap fetch.
    var dayKey: String = ""
    var loggedAt: Date = Date()
    var mealSlot: MealSlot = MealSlot.breakfast
    var orderIndex: Int = 0

    var foodID: UUID?
    /// Name captured at log time, so editing or deleting the food never corrupts history.
    var foodNameSnapshot: String = ""
    var brandSnapshot: String?
    var quantity: Double = 100
    var unit: ServingUnit = ServingUnit.grams
    var servingIndex: Int?
    /// Nutrition captured at log time. History is immutable by design.
    var macrosSnapshot: MacroNutrients = MacroNutrients.zero
    var micronutrientsSnapshotStorage: Data?
    /// Set when the entry came from a saved meal or recipe, for grouping in the UI.
    var savedMealID: UUID?
    var recipeID: UUID?

    init() {}

    /// Micronutrients captured at log time. Unknown nutrients stay unknown.
    var micronutrientsSnapshot: Micronutrients {
        get { Micronutrients.decodeFromStorage(micronutrientsSnapshotStorage) }
        set { micronutrientsSnapshotStorage = newValue.encodedForStorage }
    }
}

/// A remembered combination of foods, e.g. "usual breakfast".
@Model
final class SavedMeal {
    var id: UUID = UUID()
    var name: String = ""
    var defaultSlot: MealSlot = MealSlot.breakfast
    var createdAt: Date = Date()
    var timesUsed: Int = 0
    var lastUsedAt: Date?
    var isFavorite: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \SavedMealItem.meal)
    var items: [SavedMealItem] = []

    init() {}
}

@Model
final class SavedMealItem {
    var id: UUID = UUID()
    var foodID: UUID?
    var foodNameSnapshot: String = ""
    var quantity: Double = 100
    var unit: ServingUnit = ServingUnit.grams
    var servingIndex: Int?
    var orderIndex: Int = 0
    var meal: SavedMeal?

    init() {}
}

/// A recipe: ingredients plus a portion count, so per-serving nutrition is computed, not typed.
@Model
final class Recipe {
    var id: UUID = UUID()
    var name: String = ""
    var servingsCount: Double = 4
    var instructions: String?
    var preparationMinutes: Int?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isFavorite: Bool = false
    var timesUsed: Int = 0
    var tags: [String] = []

    @Relationship(deleteRule: .cascade, inverse: \RecipeIngredient.recipe)
    var ingredients: [RecipeIngredient] = []

    init() {}
}

@Model
final class RecipeIngredient {
    var id: UUID = UUID()
    var foodID: UUID?
    var foodNameSnapshot: String = ""
    var quantity: Double = 100
    var unit: ServingUnit = ServingUnit.grams
    var servingIndex: Int?
    var orderIndex: Int = 0
    var recipe: Recipe?

    init() {}
}

// MARK: - Targets

/// The active daily energy and macro targets.
@Model
final class DailyNutritionTarget {
    var id: UUID = UUID()
    var effectiveFrom: Date = Date()
    var kilocalories: Double = 2000
    var proteinG: Double = 150
    var carbsG: Double = 200
    var fatG: Double = 65
    /// True when the user typed the numbers instead of accepting the engine's.
    var isManualOverride: Bool = false
    /// Localisation key explaining how these numbers were reached.
    var rationaleKey: String?
    var rationaleArguments: [String] = []
    var isActive: Bool = true
    /// Optional per-micronutrient goals the user has set explicitly.
    var micronutrientGoalsStorage: Data?

    init() {}

    /// Per-micronutrient goals the user set explicitly. Absent means "no goal set".
    var micronutrientGoals: Micronutrients {
        get { Micronutrients.decodeFromStorage(micronutrientGoalsStorage) }
        set { micronutrientGoalsStorage = newValue.encodedForStorage }
    }

    var macros: MacroNutrients {
        MacroNutrients(kilocalories: kilocalories, proteinG: proteinG, carbsG: carbsG, fatG: fatG)
    }
}

/// An immutable log of every target change, so the "why did my calories move?" question is always
/// answerable.
@Model
final class NutritionTargetHistory {
    var id: UUID = UUID()
    var changedAt: Date = Date()
    var previousKilocalories: Double = 0
    var newKilocalories: Double = 0
    var previousProteinG: Double = 0
    var newProteinG: Double = 0
    var previousCarbsG: Double = 0
    var newCarbsG: Double = 0
    var previousFatG: Double = 0
    var newFatG: Double = 0
    var reasonKey: String = ""
    var reasonArguments: [String] = []
    var wasAutomatic: Bool = false
    /// Seven-day average body mass at the moment of the change, for context.
    var trendWeightKg: Double?

    init() {}
}

@Model
final class WaterLogEntry {
    #Index<WaterLogEntry>([\.dayKey])

    var id: UUID = UUID()
    var dayKey: String = ""
    var loggedAt: Date = Date()
    var milliliters: Double = 250

    init() {}
}

// MARK: - Achievements

@Model
final class Achievement {
    #Unique<Achievement>([\.code])

    var code: String = ""
    var unlockedAt: Date = Date()
    /// Numeric context, e.g. the streak length or the weight lifted.
    var value: Double?
    var exerciseID: String?

    init(code: String) { self.code = code }
}
