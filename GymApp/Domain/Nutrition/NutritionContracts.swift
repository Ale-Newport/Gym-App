import Foundation

// MARK: - Profile snapshot

/// Everything the nutrition engines need to know about the user, as a value type.
///
/// Mirrors the role `TrainingProfileSnapshot` plays for the training engines: the engines never
/// touch SwiftData, they take a snapshot in and return plain results. That is what makes every
/// number below reproducible in a unit test and free of persistence concerns.
///
/// Canonical units throughout: kilograms, centimetres, kilocalories.
struct NutritionProfileSnapshot: Hashable, Sendable {
    var biologicalSex: BiologicalSex = .unspecified
    /// `nil` when the user did not give a birth date. The engines substitute a documented default
    /// and say so in their explanations rather than silently inventing an age.
    var ageYears: Int?
    var heightCm: Double = 175
    var weightKg: Double = 75
    var targetWeightKg: Double?
    var activityLevel: ActivityLevel = .moderate
    var goals: [TrainingGoal] = [.generalFitness]
    var pace: NutritionGoalPace = .moderate
    var dietType: DietType = .omnivore
    /// Lower-cased allergen tags the user must never be shown, e.g. `"peanut"`.
    var allergenTags: Set<String> = []
    /// Lower-cased intolerance tags, e.g. `"lactose"`. Treated as hard exclusions too: the app is
    /// not in a position to judge how much of an intolerance is "a bit".
    var intoleranceTags: Set<String> = []
    /// Tags the user simply does not want to see, e.g. `"offal"`.
    var excludedFoodTags: Set<String> = []
    var mealsPerDay: Int = 4
    /// Resistance sessions per week. Feeds the small training uplift on top of the activity factor.
    var trainingDaysPerWeek: Int = 3
    /// Optional weekly food budget in the user's currency. `nil` means "do not consider cost".
    var weeklyFoodBudget: Double?

    var primaryGoal: TrainingGoal { goals.first ?? .generalFitness }

    /// Body-mass index, or `nil` when the height on file is implausible. Used only to decide
    /// whether protein should be scaled off an adjusted body mass — never shown as a verdict.
    var bodyMassIndex: Double? {
        guard heightCm >= 100, heightCm <= 250, weightKg > 20 else { return nil }
        let metres = heightCm / 100
        return weightKg / (metres * metres)
    }

    /// Every tag that disqualifies a food outright, lower-cased and merged.
    ///
    /// Diet, allergen, intolerance and personal exclusions are deliberately one set: the meal
    /// recommender must treat all four as hard filters, never as a score penalty.
    var forbiddenFoodTags: Set<String> {
        var tags = dietType.excludedTags
        tags.formUnion(allergenTags.map { $0.lowercased() })
        tags.formUnion(intoleranceTags.map { $0.lowercased() })
        tags.formUnion(excludedFoodTags.map { $0.lowercased() })
        return tags
    }

    /// Meal slots the day is actually split into. Three meals collapse the snack budget into the
    /// main meals, which is how people with `mealsPerDay <= 3` actually eat.
    var activeSlots: [MealSlot] {
        mealsPerDay >= 4 ? MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }
                         : [.breakfast, .lunch, .dinner]
    }

    /// Share of the day's energy this slot should carry, renormalised over `activeSlots` so the
    /// shares always sum to 1 regardless of how many meals the user eats.
    func energyShare(of slot: MealSlot) -> Double {
        let slots = activeSlots
        let total = slots.reduce(0) { $0 + $1.defaultEnergyShare }
        guard total > 0 else { return slot.defaultEnergyShare }
        guard slots.contains(slot) else {
            // A slot outside the user's pattern (a snack for a three-meal user) still gets its
            // nominal share rather than zero — they asked for a suggestion, so give them one.
            return slot.defaultEnergyShare
        }
        return slot.defaultEnergyShare / total
    }
}

// MARK: - Energy and macro targets

/// The daily energy and macronutrient target produced by `NutritionRecommendationEngine`.
///
/// `explanations` is not decoration: every number here is an estimate derived from population
/// equations, and the user is entitled to see which assumption produced which figure before they
/// accept it.
struct EnergyTargets: Hashable, Sendable {
    /// Estimated resting energy expenditure, kcal/day (Mifflin-St Jeor).
    var basalMetabolicRate: Double = 0
    /// Estimated maintenance energy, kcal/day.
    var totalDailyEnergyExpenditure: Double = 0
    /// The recommended daily intake, kcal.
    var kilocalories: Double = 0
    var proteinG: Double = 0
    var carbsG: Double = 0
    var fatG: Double = 0
    var direction: EnergyBalanceDirection = .maintenance
    /// The body-mass change the target actually implies, signed, kg/week. Recomputed after every
    /// safety clamp, so it always describes the number the user was given rather than the number
    /// that was asked for.
    var weeklyBodyMassChangeKg: Double = 0
    var explanations: [Explanation] = []

    var macros: MacroNutrients {
        MacroNutrients(kilocalories: kilocalories, proteinG: proteinG, carbsG: carbsG, fatG: fatG)
    }

    /// Share of energy each macro carries, using the 4/4/9 convention. Handy for the ring chart and
    /// for asserting in tests that a clamp did not distort the split.
    var energyShares: (protein: Double, carbs: Double, fat: Double) {
        let total = max(1, macros.derivedKilocalories)
        return (proteinG * 4 / total, carbsG * 4 / total, fatG * 9 / total)
    }
}

// MARK: - Weight trend

/// One body-mass reading. Several readings on the same day are averaged by the analyser.
struct WeightTrendPoint: Hashable, Sendable {
    var date: Date
    var weightKg: Double

    init(date: Date, weightKg: Double) {
        self.date = date
        self.weightKg = weightKg
    }
}

/// The output of `WeightTrendAnalyzer`.
///
/// Single scale readings are useless for decisions — daily body mass swings by roughly ±1 kg on
/// water, glycogen and gut content alone — so everything downstream consumes this smoothed and
/// regressed view instead of raw entries.
struct WeightTrendAnalysis: Hashable, Sendable {
    /// Trailing moving average, one point per day that has at least one reading, oldest first.
    var movingAverage: [WeightTrendPoint] = []
    /// The most recent moving-average value: the number to show as "your weight".
    var currentTrendKg: Double?
    /// Regression slope over the trailing window, kg/week. `nil` when the data cannot support one.
    var weeklyChangeKg: Double?
    /// Calendar span of the readings, in weeks.
    var weeksOfData: Double = 0
    /// 0…1 — how much the trend can be trusted, from reading count, span and residual spread.
    var confidence: Double = 0
    /// True when there is enough data for an automatic decision to even be considered.
    var hasEnoughData: Bool = false

    static let empty = WeightTrendAnalysis()
}

// MARK: - Calorie adjustment

enum CalorieAdjustmentAction: String, Hashable, Sendable, Codable {
    case increase
    case decrease
    case hold
    case insufficientData

    var localizationKey: String { "nutrition.adjustAction.\(rawValue)" }
}

/// A proposed change to the daily energy target.
///
/// `requiresUserApproval` is always `true`. The app proposes, the user decides — silently moving
/// somebody's calorie target is the fastest way to lose their trust in every other number too.
struct CalorieAdjustmentDecision: Hashable, Sendable {
    var action: CalorieAdjustmentAction
    /// Signed change in kcal/day. Zero for `.hold` and `.insufficientData`.
    var deltaKilocalories: Double
    /// The full target set that would replace the current one. `nil` unless something changes.
    var newTargets: EnergyTargets?
    var explanation: Explanation
    var requiresUserApproval: Bool
}

// MARK: - Meal suggestions

/// One food at one portion size inside a suggestion.
struct SuggestedFoodPortion: Hashable, Sendable {
    /// Identifier of the underlying `FoodItem`, when the suggestion came from the user's database.
    var foodID: UUID?
    /// Stable catalogue identifier for built-in foods.
    var catalogID: String?
    var name: String
    var quantity: Double
    var unit: ServingUnit
    var macros: MacroNutrients

    /// Identity used for de-duplication and for the deterministic suggestion id.
    var identityKey: String {
        catalogID ?? foodID?.uuidString ?? name.lowercased()
    }
}

/// One recommended meal.
struct MealSuggestion: Hashable, Sendable, Identifiable {
    /// Derived deterministically from the contents, so the same request always yields the same ids
    /// and SwiftUI does not re-animate an unchanged list.
    var id: UUID
    /// Localisation key describing the *shape* of the suggestion ("Protein, carbs and vegetables").
    var titleKey: String?
    /// Display title built from the food names, which are data rather than UI copy.
    var title: String
    var items: [SuggestedFoodPortion]
    var macros: MacroNutrients
    /// 0…1 overall suitability.
    var score: Double
    /// Why this was suggested, best reason first.
    var reasons: [Explanation]
    var savedMealID: UUID?
    var recipeID: UUID?
}

/// A food the recommender may build a portion from.
struct MealCandidateFood: Hashable, Sendable {
    var id: UUID
    var catalogID: String?
    var name: String
    var macrosPer100: MacroNutrients
    var micronutrientsPer100: Micronutrients = .unknown
    /// Diet tags: `meat`, `dairy`, `egg`…
    var dietaryTags: Set<String> = []
    var allergenTags: Set<String> = []
    /// Role tags: `protein_source`, `carb_source`, `vegetable`, `fat_source`, `breakfast`, `quick`…
    var roleTags: Set<String> = []
    /// Grams in one natural piece (an egg, a banana), when the food is counted rather than weighed.
    var gramsPerPiece: Double?
    /// The portion the user normally logs, in grams. Used to seed and bound the portion solver.
    var defaultServingGrams: Double?
    var timesLogged: Int = 0
    var isFavorite: Bool = false
    /// Cost per 100 g in the user's currency. `nil` means unknown, which is treated as neutral.
    var costPer100: Double?

    /// Every tag that a dietary filter may match against.
    var allTags: Set<String> {
        var tags = Set(dietaryTags.map { $0.lowercased() })
        tags.formUnion(allergenTags.map { $0.lowercased() })
        tags.formUnion(roleTags.map { $0.lowercased() })
        return tags
    }

    var identityKey: String { catalogID ?? id.uuidString }

    /// Energy per 100 g, falling back to the 4/4/9 derivation when a record carries macros but no
    /// energy — a common gap in imported data.
    var effectiveKilocaloriesPer100: Double {
        macrosPer100.kilocalories > 0 ? macrosPer100.kilocalories : macrosPer100.derivedKilocalories
    }
}

/// A meal the user already saved, offered back to them verbatim.
struct SavedMealCandidate: Hashable, Sendable {
    var id: UUID
    var name: String
    var macros: MacroNutrients
    var items: [SuggestedFoodPortion]
    var timesUsed: Int
    var slot: MealSlot
}

/// A recipe, offered at one or two servings.
struct RecipeCandidate: Hashable, Sendable {
    var id: UUID
    var name: String
    var macrosPerServing: MacroNutrients
    var preparationMinutes: Int?
    var tags: Set<String> = []
    var timesUsed: Int = 0
}

/// Everything `MealRecommendationEngine` needs.
struct MealRecommendationRequest: Sendable {
    /// Macros left in the *day* at the moment of asking.
    var remaining: MacroNutrients
    var slot: MealSlot
    var profile: NutritionProfileSnapshot
    var candidates: [MealCandidateFood] = []
    /// Foods logged in the last two days. Penalised so the suggestions do not become a rut.
    var recentlyLoggedIDs: [UUID] = []
    var savedMeals: [SavedMealCandidate] = []
    var recipes: [RecipeCandidate] = []
    var limit: Int = 5
    /// The full day's target, when known. Lets the engine size a meal as a share of the day rather
    /// than dumping every remaining calorie into one sitting.
    var dailyTarget: MacroNutrients?

    init(
        remaining: MacroNutrients,
        slot: MealSlot,
        profile: NutritionProfileSnapshot,
        candidates: [MealCandidateFood] = [],
        recentlyLoggedIDs: [UUID] = [],
        savedMeals: [SavedMealCandidate] = [],
        recipes: [RecipeCandidate] = [],
        limit: Int = 5,
        dailyTarget: MacroNutrients? = nil
    ) {
        self.remaining = remaining
        self.slot = slot
        self.profile = profile
        self.candidates = candidates
        self.recentlyLoggedIDs = recentlyLoggedIDs
        self.savedMeals = savedMeals
        self.recipes = recipes
        self.limit = limit
        self.dailyTarget = dailyTarget
    }
}

/// Tunable weights for `MealRecommendationEngine`.
///
/// Exposed as a value type for the same reason `ExerciseScoringWeights` is: the balance between,
/// say, macro fit and variety should be adjustable and unit-testable without editing the scorer.
/// The five additive weights sum to 1.0 so a raw score stays on a 0…1 scale before the bonuses.
struct MealScoringWeights: Hashable, Sendable {
    var macroFit: Double = 0.34
    var calorieFit: Double = 0.22
    var preferenceFit: Double = 0.18
    var micronutrientFit: Double = 0.12
    var varietyBonus: Double = 0.14
    /// Subtracted, not added.
    var restrictionPenalty: Double = 0.25
    /// Added for a saved meal, because re-logging something the user already built is the whole
    /// point of saving it.
    var savedMealBonus: Double = 0.08
    var recipeBonus: Double = 0.06

    static let `default` = MealScoringWeights()

    var additiveSum: Double {
        macroFit + calorieFit + preferenceFit + micronutrientFit + varietyBonus
    }
}

// MARK: - Micronutrients

/// One micronutrient compared against a reference intake.
///
/// `isUnknown` exists because `Micronutrients` distinguishes "no data" from "zero", and the UI must
/// too: showing an empty iron bar for a food whose data simply omits iron would imply a shortfall
/// the app has no evidence for.
struct MicronutrientStatus: Hashable, Sendable {
    var nutrient: Micronutrient
    var consumed: Double?
    var reference: Double?
    /// `consumed / reference`, or `nil` when either side is missing.
    var fraction: Double?
    var isUnknown: Bool
}

// MARK: - Shared helpers

/// Deterministic number formatting for explanation arguments.
///
/// `Explanation.arguments` is `[String]`, so every catalogue entry for an engine key uses `%@` and
/// the engine formats the number itself. Formatting here is deliberately locale-independent:
/// engines must return byte-identical output for identical input, and a `NumberFormatter` bound to
/// `Locale.current` would break that.
enum NutritionFormat {
    /// Beyond this magnitude a figure is corrupt data rather than a number worth printing — and
    /// `Int(_: Double)` *traps* rather than saturating when the value does not fit, so an imported
    /// food carrying an absurd `per100` value would otherwise crash the app inside a formatter.
    /// Everything this app formats (kcal, grams, kilograms, percentages) sits far below the limit.
    private static let integerSafeLimit: Double = 1e15

    /// `Int` conversion that saturates instead of trapping. Non-finite input is caught by the
    /// callers' `isFinite` guards; this handles the finite-but-enormous case.
    private static func safeInt(_ value: Double) -> Int {
        Int(nutritionClamp(value, -integerSafeLimit, integerSafeLimit).rounded())
    }

    /// Rounds to a whole number, e.g. `"1850"`.
    static func whole(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(safeInt(value))
    }

    /// One decimal place, e.g. `"0.4"`.
    static func oneDecimal(_ value: Double) -> String {
        guard value.isFinite else { return "0.0" }
        return String(format: "%.1f", value)
    }

    /// Two decimal places, for per-kilogram figures such as `"1.85"`.
    static func twoDecimals(_ value: Double) -> String {
        guard value.isFinite else { return "0.00" }
        return String(format: "%.2f", value)
    }

    /// A whole percentage with its sign, e.g. `"27%"`. The `%` lives inside the *argument*, never
    /// inside the catalogue template, so no `%%` escaping is needed anywhere.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0%" }
        return "\(safeInt(fraction * 100))%"
    }

    /// Signed value to one decimal, for "+0.4 kg a week" phrasing where the sentence itself does not
    /// carry the direction.
    ///
    /// The rounding happens *before* the sign is chosen, so a rate of −0.03 kg/week prints as
    /// `"0.0"` rather than the nonsensical `"-0.0"` a bare `%.1f` would produce.
    static func signedOneDecimal(_ value: Double) -> String {
        guard value.isFinite else { return "0.0" }
        let rounded = (value * 10).rounded() / 10
        if rounded == 0 { return "0.0" }
        return rounded > 0 ? "+\(oneDecimal(rounded))" : oneDecimal(rounded)
    }
}

/// Clamps `value` into `range`. Used everywhere below; kept here so no engine grows its own copy.
func nutritionClamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    guard value.isFinite else { return lower }
    if upper <= lower { return lower }
    return min(max(value, lower), upper)
}

/// Clamps into 0…1.
func nutritionClamp01(_ value: Double) -> Double { nutritionClamp(value, 0, 1) }

/// Builds a stable UUID from a signature string.
///
/// Suggestions must be reproducible: identical requests have to produce identical ids, otherwise
/// every call looks like a brand-new list to SwiftUI's diffing and to any test that compares two
/// runs. A 128-bit FNV-1a over the signature gives that cheaply — this is an identity, not a
/// security decision, so a cryptographic digest would be the wrong tool.
enum DeterministicID {
    static func make(from signature: String) -> UUID {
        var low: UInt64 = 0xcbf2_9ce4_8422_2325
        var high: UInt64 = 0x9e37_79b9_7f4a_7c15
        let prime: UInt64 = 0x100_0000_01b3
        for byte in signature.utf8 {
            low = (low ^ UInt64(byte)) &* prime
            high = (high &+ UInt64(byte) &+ (low >> 13)) &* prime
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: high >> UInt64(56 - index * 8))
            bytes[index + 8] = UInt8(truncatingIfNeeded: low >> UInt64(56 - index * 8))
        }
        // RFC 4122 version and variant bits, so the value is a well-formed UUID rather than 16
        // arbitrary bytes wearing a UUID's clothes.
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
