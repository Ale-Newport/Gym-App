import Foundation

/// Builds concrete meal suggestions that fit what is left of the day's macros.
///
/// The design constraint that shapes everything here: a suggestion has to be something a person can
/// actually put on a plate. That rules out the two easy approaches. Picking foods at random and
/// hoping is useless, and offering fixed serving sizes ("100 g of chicken") almost never lands on
/// the macros that are actually left. So the engine builds a small number of sensible *patterns* —
/// a protein with a carbohydrate and a vegetable, a protein with a fat, a single snack — and then
/// **solves for the portion sizes** that come closest to the remaining macros, before rounding
/// those portions onto numbers a kitchen scale or a hand can produce.
///
/// Saved meals and recipes compete on the same scale and carry a bonus, because re-logging
/// something the user already built is the whole point of having saved it.
///
/// Pure and deterministic: value types in, value types out, no persistence, no randomness, and ids
/// derived from the contents rather than freshly generated.
struct MealRecommendationEngine: Sendable {

    // MARK: - Configuration

    let weights: MealScoringWeights

    init() {
        self.init(weights: .default)
    }

    init(weights: MealScoringWeights) {
        self.weights = weights
    }

    /// Thresholds and portion rules. Gathered so `docs/ALGORITHMS.md` and the code cannot drift.
    enum Constants {
        /// Below this there is nothing worth suggesting; the user should just log what they want.
        static let minimumRemainingKilocalories: Double = 80
        /// Ceilings on how much energy one sitting should be asked to carry.
        static let mainMealKilocalorieCap: Double = 900
        static let snackKilocalorieCap: Double = 350

        /// How many foods per role feed the combination generator. Small on purpose: the top few
        /// per role already carry the user's preferences, and the product grows cubically.
        static let topPerRoleForTriples: Int = 3
        static let topPerRoleForPairs: Int = 4
        static let topForSingles: Int = 6
        /// Hard ceiling on evaluated combinations, so a huge food database cannot stall the UI.
        static let maximumCombinations: Int = 400

        /// Portion solver: fixed iteration count keeps the result reproducible to the last gram.
        static let solverIterations: Int = 40
        /// Portions are rounded to this many grams — the smallest step most people can be bothered
        /// to weigh, and the step every recipe book already uses.
        static let gramRoundingStep: Double = 5
        /// A "piece" smaller than this (a single almond, a raspberry) is not a useful unit, so the
        /// food is weighed instead.
        static let minimumMeaningfulPieceGrams: Double = 15
        /// Anything solved below this is dropped from the suggestion rather than shown.
        static let minimumPortionGrams: Double = 10

        /// Total plate mass beyond which a suggestion starts to look absurd, and the span over
        /// which the penalty reaches full strength.
        static let comfortablePlateGrams: Double = 900
        static let plateGramsPenaltySpan: Double = 600
        /// A suggestion costing more than this multiple of the per-meal budget is dropped, not
        /// merely penalised — it is not a suggestion the user can act on.
        static let budgetHardMultiple: Double = 2.0

        /// Share of a daily reference intake a single meal is expected to carry. Used to turn
        /// micronutrient amounts into a 0…1 score.
        static let micronutrientMealShare: Double = 0.25
        static let limitingNutrientMealShare: Double = 0.35
        /// No reference intake exists for saturated fat, so a daily ceiling of 20 g is used: about
        /// 10 % of energy on a 2,000 kcal diet, the usual public-health guidance.
        static let saturatedFatDailyCeilingG: Double = 20
        /// Limiting-nutrient load is only penalised once it passes this share of the meal ceiling.
        static let limitingNutrientTolerance: Double = 0.6

        /// Overshooting the calorie budget is worse than undershooting: the day has a ceiling and
        /// the next meal still has to fit.
        static let calorieOvershootPenaltyFactor: Double = 1.4

        /// Reasons shown per suggestion. More than this stops being a reason and starts being an
        /// essay.
        static let maximumReasons: Int = 4

        /// Demotion applied while picking the final list, per food a suggestion shares with one
        /// already picked. Four variations on chicken and rice are four ways of saying the same
        /// thing; a slightly worse-fitting suggestion built from different food earns its place.
        static let repeatedFoodDemotion: Double = 0.05
    }

    // MARK: - Roles

    /// The job a food does inside a meal pattern.
    enum FoodRole: String, CaseIterable, Hashable, Sendable {
        case protein
        case carbohydrate
        /// Vegetables and fruit: the bulk-and-micronutrient slot.
        case vegetable
        case fat
        case other
    }

    // MARK: - Entry point

    /// Suggestions for the given slot, best first, at most `request.limit` of them.
    func suggestions(for request: MealRecommendationRequest) -> [MealSuggestion] {
        guard request.limit > 0 else { return [] }
        guard request.remaining.kilocalories >= Constants.minimumRemainingKilocalories else { return [] }

        let target = mealTarget(for: request)
        guard target.kilocalories > 0 else { return [] }

        let context = Context(request: request, target: target, weights: weights)
        var results = combinationSuggestions(context)
        results.append(contentsOf: savedMealSuggestions(context))
        results.append(contentsOf: recipeSuggestions(context))
        return finalise(results, limit: request.limit)
    }

    // MARK: - Context

    /// Everything derived once per request and shared by the builders.
    private struct Context {
        let request: MealRecommendationRequest
        let target: MacroNutrients
        let weights: MealScoringWeights
        let forbidden: Set<String>
        let recentIDs: Set<UUID>
        /// Per-meal food budget, or `nil` when the user set none.
        let mealBudget: Double?

        init(request: MealRecommendationRequest, target: MacroNutrients, weights: MealScoringWeights) {
            self.request = request
            self.target = target
            self.weights = weights
            self.forbidden = request.profile.forbiddenFoodTags
            self.recentIDs = Set(request.recentlyLoggedIDs)
            if let weekly = request.profile.weeklyFoodBudget, weekly > 0 {
                let mealsPerWeek = 7 * Double(max(1, request.profile.mealsPerDay))
                self.mealBudget = weekly / mealsPerWeek
            } else {
                self.mealBudget = nil
            }
        }
    }

    /// A candidate food with everything the scorer needs precomputed.
    private struct RankedFood {
        var food: MealCandidateFood
        var roles: Set<FoodRole>
        /// 0…1 how much the user likes and uses this food.
        var preference: Double
        /// 0…1 how well it suits this meal slot.
        var slotFit: Double
        var isRecent: Bool
        /// Ranking score used only to pick which foods enter the combination generator.
        var componentScore: Double
    }

    private struct BuiltPortion {
        var ranked: RankedFood
        /// The pattern slot this portion was solved for. Carried through so the suggestion's title
        /// key describes the plate that survived rounding rather than the pattern that was attempted.
        var role: FoodRole
        var grams: Double
        var portion: SuggestedFoodPortion
    }

    /// The per-factor breakdown behind a suggestion's score, kept separate from the weighting so
    /// both halves stay testable.
    private struct ScoreComponents {
        var macroFit: Double = 0
        var calorieFit: Double = 0
        var preferenceFit: Double = 0
        var micronutrientFit: Double = 0
        var varietyBonus: Double = 0
        var restrictionPenalty: Double = 0
        var extraBonus: Double = 0

        func total(_ weights: MealScoringWeights) -> Double {
            var score = macroFit * weights.macroFit
            score += calorieFit * weights.calorieFit
            score += preferenceFit * weights.preferenceFit
            score += micronutrientFit * weights.micronutrientFit
            score += varietyBonus * weights.varietyBonus
            score -= restrictionPenalty * weights.restrictionPenalty
            score += extraBonus
            return nutritionClamp01(score)
        }
    }

    // MARK: - Meal target

    /// How much of the day's remainder this one meal should try to cover.
    ///
    /// Handing somebody their entire remaining 1,600 kcal as a single suggestion at lunchtime is
    /// technically a perfect macro fit and completely useless. So the meal aims at its share of the
    /// day — `MealSlot.defaultEnergyShare` renormalised over the slots the user actually eats —
    /// capped at what one sitting can sensibly hold. When the remainder is already smaller than
    /// that share, it is taken whole: this is the last meal of the day.
    private func mealTarget(for request: MealRecommendationRequest) -> MacroNutrients {
        let cap = request.slot == .snacks
            ? Constants.snackKilocalorieCap
            : Constants.mainMealKilocalorieCap
        let share = request.profile.energyShare(of: request.slot)
        var slotKilocalories = cap
        if let daily = request.dailyTarget, daily.kilocalories > 0 {
            slotKilocalories = min(daily.kilocalories * share, cap)
        }
        var target = request.remaining
        if request.remaining.kilocalories > slotKilocalories {
            target = request.remaining * (slotKilocalories / request.remaining.kilocalories)
        }
        // A macro the user has already overshot has nothing left to fill, so its target is zero
        // rather than negative — otherwise the scorer would reward foods for containing none of it.
        target.proteinG = max(0, target.proteinG)
        target.carbsG = max(0, target.carbsG)
        target.fatG = max(0, target.fatG)
        return target
    }

    // MARK: - Candidate preparation

    /// Hard filter plus ranking. Exclusions are applied here and nowhere else, so there is exactly
    /// one place where "the user must never see this food" is decided.
    private func rankedCandidates(_ context: Context) -> [RankedFood] {
        context.request.candidates.compactMap { food -> RankedFood? in
            guard isEligible(food, forbidden: context.forbidden) else { return nil }
            let roles = self.roles(for: food)
            let preference = preferenceScore(for: food)
            let slotFit = self.slotFit(for: food, slot: context.request.slot)
            let isRecent = context.recentIDs.contains(food.id)
            let density = micronutrientDensity(for: food)
            var component = preference * 0.45
            component += slotFit * 0.30
            component += density * 0.15
            component += (isRecent ? 0 : 1) * 0.10
            return RankedFood(
                food: food,
                roles: roles,
                preference: preference,
                slotFit: slotFit,
                isRecent: isRecent,
                componentScore: component
            )
        }
    }

    /// A food is eligible only if it survives every hard rule.
    ///
    /// Diet, allergen, intolerance and personal exclusions are never softened into a penalty: a
    /// peanut allergy is not a scoring nuance. Foods carrying no usable nutrition are dropped too,
    /// since a portion of them can never move the macros towards the target.
    private func isEligible(_ food: MealCandidateFood, forbidden: Set<String>) -> Bool {
        guard food.effectiveKilocaloriesPer100 > 0 else { return false }
        let macros = food.macrosPer100
        guard macros.proteinG > 0 || macros.carbsG > 0 || macros.fatG > 0 else { return false }
        guard !forbidden.isEmpty else { return true }
        return food.allTags.isDisjoint(with: forbidden)
    }

    /// Which roles a food can fill.
    ///
    /// Explicit `roleTags` win where the data has them; otherwise the macro composition decides,
    /// using both a share-of-energy test and an absolute-amount test. The absolute test matters:
    /// lettuce is 25 % protein by energy and is not a protein source.
    func roles(for food: MealCandidateFood) -> Set<FoodRole> {
        let tags = Set(food.roleTags.map { $0.lowercased() })
        let macros = food.macrosPer100
        let energy = max(1, food.effectiveKilocaloriesPer100)
        var roles: Set<FoodRole> = []

        let proteinShare = macros.proteinG * 4 / energy
        let carbShare = macros.carbsG * 4 / energy
        let fatShare = macros.fatG * 9 / energy

        if !tags.isDisjoint(with: Self.proteinTags) || (proteinShare >= 0.35 && macros.proteinG >= 10) {
            roles.insert(.protein)
        }
        if !tags.isDisjoint(with: Self.carbTags) || (carbShare >= 0.45 && macros.carbsG >= 15) {
            roles.insert(.carbohydrate)
        }
        let fibre = food.micronutrientsPer100.fiberG ?? 0
        if !tags.isDisjoint(with: Self.vegetableTags)
            || (food.effectiveKilocaloriesPer100 < 80 && fibre >= 1.5) {
            roles.insert(.vegetable)
        }
        if !tags.isDisjoint(with: Self.fatTags) || (fatShare >= 0.55 && macros.fatG >= 10) {
            roles.insert(.fat)
        }
        if roles.isEmpty { roles.insert(.other) }
        return roles
    }

    private static let proteinTags: Set<String> = ["protein_source", "protein", "lean_protein"]
    private static let carbTags: Set<String> = [
        "carb_source", "carb", "carbohydrate", "grain", "starch", "cereal"
    ]
    private static let vegetableTags: Set<String> = [
        "vegetable", "veg", "vegetables", "fruit", "salad", "produce"
    ]
    private static let fatTags: Set<String> = ["fat_source", "fat", "oil", "nut", "nuts", "seed", "seeds"]

    /// 0…1 from favourite status and how often the food has been logged.
    ///
    /// The log count is compressed logarithmically and saturates at twenty entries: the difference
    /// between a food logged twice and twenty times is real, between eighty and a hundred it is not.
    private func preferenceScore(for food: MealCandidateFood) -> Double {
        let favourite: Double = food.isFavorite ? 1 : 0
        let logged = log(1 + Double(max(0, food.timesLogged))) / log(21)
        return nutritionClamp01(0.5 * favourite + 0.5 * nutritionClamp01(logged))
    }

    /// How well a food suits the slot.
    ///
    /// A food with no slot tags at all is neutral rather than penalised — most foods carry none,
    /// and treating "unknown" as "wrong" would bury the whole database beneath the handful of
    /// tagged items.
    private func slotFit(for food: MealCandidateFood, slot: MealSlot) -> Double {
        let tags = Set(food.roleTags.map { $0.lowercased() })
        let slotTags = Self.slotTags(for: slot)
        if !tags.isDisjoint(with: slotTags) { return 1.0 }
        if !tags.isDisjoint(with: Self.allSlotTags) { return 0.15 }
        return 0.5
    }

    private static func slotTags(for slot: MealSlot) -> Set<String> {
        switch slot {
        case .breakfast: return ["breakfast", "morning"]
        case .lunch: return ["lunch", "main", "meal"]
        case .dinner: return ["dinner", "main", "meal"]
        case .snacks: return ["snack", "quick", "portable"]
        }
    }

    private static let allSlotTags: Set<String> = [
        "breakfast", "morning", "lunch", "dinner", "main", "meal", "snack", "quick", "portable"
    ]

    /// Fibre per 100 g as a rough proxy for micronutrient density, used only for ranking which
    /// foods enter the generator. Unknown fibre is neutral, never zero.
    private func micronutrientDensity(for food: MealCandidateFood) -> Double {
        guard let fibre = food.micronutrientsPer100.fiberG else { return 0.5 }
        return nutritionClamp01(fibre / 3)
    }

    // MARK: - Combination suggestions

    /// Patterns tried for a main meal, in priority order. Each is a shape people actually eat.
    private static let mainMealPatterns: [[FoodRole]] = [
        [.protein, .carbohydrate, .vegetable],
        [.protein, .carbohydrate, .fat],
        [.protein, .vegetable, .fat],
        [.protein, .carbohydrate],
        [.protein, .vegetable],
        [.carbohydrate, .vegetable],
        [.carbohydrate, .fat],
        [.protein]
    ]

    /// Snacks are one or two items. Nobody plates a snack.
    private static let snackPatterns: [[FoodRole]] = [
        [.protein],
        [.protein, .carbohydrate],
        [.protein, .fat],
        [.carbohydrate],
        [.vegetable],
        [.fat]
    ]

    /// Last resort, tried only when every named pattern came back empty.
    ///
    /// `.other` is what a food gets when neither its tags nor its macro composition single out a
    /// role — a sandwich, a ready meal, a protein bar, most of a supermarket. None of the patterns
    /// above can use such a food, so a user whose whole log is composite meals would otherwise be
    /// shown nothing at all, which is a worse answer than an unglamorous one.
    private static let fallbackPatterns: [[FoodRole]] = [
        [.other, .other],
        [.other]
    ]

    private func combinationSuggestions(_ context: Context) -> [MealSuggestion] {
        let ranked = rankedCandidates(context)
        guard !ranked.isEmpty else { return [] }

        var byRole: [FoodRole: [RankedFood]] = [:]
        for role in FoodRole.allCases {
            byRole[role] = ranked
                .filter { $0.roles.contains(role) }
                .sorted(by: Self.rankOrder)
        }

        let patterns = context.request.slot == .snacks ? Self.snackPatterns : Self.mainMealPatterns
        var suggestions: [MealSuggestion] = []
        var evaluated = 0

        func evaluate(_ patterns: [[FoodRole]]) {
            for pattern in patterns {
                let perRole: Int
                switch pattern.count {
                case 1: perRole = Constants.topForSingles
                case 2: perRole = Constants.topPerRoleForPairs
                default: perRole = Constants.topPerRoleForTriples
                }
                let lists = pattern.map { Array((byRole[$0] ?? []).prefix(perRole)) }
                guard !lists.contains(where: { $0.isEmpty }) else { continue }
                for combination in Self.product(lists) {
                    guard evaluated < Constants.maximumCombinations else { break }
                    evaluated += 1
                    if let suggestion = buildSuggestion(
                        combination: combination, pattern: pattern, context: context
                    ) {
                        suggestions.append(suggestion)
                    }
                }
                if evaluated >= Constants.maximumCombinations { break }
            }
        }

        evaluate(patterns)
        if suggestions.isEmpty { evaluate(Self.fallbackPatterns) }
        return suggestions
    }

    /// Deterministic ordering for the generator: best component score first, then identity so two
    /// foods with equal scores never swap places between runs. `sort` is not stable in Swift, so the
    /// tie-break is not optional.
    private static func rankOrder(_ lhs: RankedFood, _ rhs: RankedFood) -> Bool {
        if lhs.componentScore != rhs.componentScore { return lhs.componentScore > rhs.componentScore }
        return lhs.food.identityKey < rhs.food.identityKey
    }

    /// Cartesian product, skipping combinations that would use the same food twice (a food can hold
    /// several roles — Greek yoghurt is both a protein and a dairy carbohydrate).
    private static func product(_ lists: [[RankedFood]]) -> [[RankedFood]] {
        var result: [[RankedFood]] = [[]]
        for list in lists {
            var next: [[RankedFood]] = []
            for prefix in result {
                for food in list {
                    let key = food.food.identityKey
                    guard !prefix.contains(where: { $0.food.identityKey == key }) else { continue }
                    next.append(prefix + [food])
                }
            }
            result = next
            if result.isEmpty { break }
        }
        return result
    }

    /// Solves portions for one combination and turns it into a scored suggestion.
    private func buildSuggestion(
        combination: [RankedFood],
        pattern: [FoodRole],
        context: Context
    ) -> MealSuggestion? {
        // First pass: solve, then drop anything the solver pushed towards zero — a suggestion
        // containing "3 g of rice" is noise, and removing it and re-solving gives the survivors the
        // room to cover what it was carrying.
        var foods = combination
        var roles = pattern
        var grams = solvePortions(foods: foods, roles: roles, target: context.target)
        var keptFoods: [RankedFood] = []
        var keptRoles: [FoodRole] = []
        for index in foods.indices where grams[index] >= Constants.minimumPortionGrams {
            keptFoods.append(foods[index])
            keptRoles.append(roles[index])
        }
        guard !keptFoods.isEmpty else { return nil }
        if keptFoods.count != foods.count {
            foods = keptFoods
            roles = keptRoles
            grams = solvePortions(foods: foods, roles: roles, target: context.target)
        }

        var built: [BuiltPortion] = []
        for index in foods.indices {
            let rounded = roundPortion(grams: grams[index], food: foods[index].food)
            guard rounded.grams >= Constants.minimumPortionGrams else { continue }
            let macros = foods[index].food.macrosPer100 * (rounded.grams / 100)
            let portion = SuggestedFoodPortion(
                foodID: foods[index].food.id,
                catalogID: foods[index].food.catalogID,
                name: foods[index].food.name,
                quantity: rounded.quantity,
                unit: rounded.unit,
                macros: normalisedMacros(macros, food: foods[index].food, grams: rounded.grams)
            )
            built.append(BuiltPortion(
                ranked: foods[index], role: roles[index], grams: rounded.grams, portion: portion
            ))
        }
        guard !built.isEmpty else { return nil }

        let macros = built.reduce(MacroNutrients.zero) { $0 + $1.portion.macros }
        let totalGrams = built.reduce(0) { $0 + $1.grams }
        let cost = totalCost(of: built)
        if let budget = context.mealBudget, let cost, cost > budget * Constants.budgetHardMultiple {
            return nil
        }
        let micros = built.reduce(Micronutrients.unknown) {
            $0 + $1.ranked.food.micronutrientsPer100.scaled(by: $1.grams / 100)
        }

        var components = ScoreComponents()
        components.macroFit = macroFit(macros, target: context.target)
        components.calorieFit = calorieFit(macros, target: context.target)
        let preference = built.reduce(0.0) { $0 + $1.ranked.preference } / Double(built.count)
        let slot = built.reduce(0.0) { $0 + $1.ranked.slotFit } / Double(built.count)
        components.preferenceFit = nutritionClamp01(0.6 * preference + 0.4 * slot)
        components.micronutrientFit = micronutrientFit(micros)
        let recentCount = built.filter { $0.ranked.isRecent }.count
        components.varietyBonus = 1 - Double(recentCount) / Double(built.count)
        components.restrictionPenalty = restrictionPenalty(
            cost: cost, budget: context.mealBudget, totalGrams: totalGrams
        )

        let title = built.map { $0.portion.name }.joined(separator: " + ")
        let signature = "combo:" + built
            .map { "\($0.portion.identityKey)@\(Int($0.grams))" }
            .sorted()
            .joined(separator: "|")

        return MealSuggestion(
            id: DeterministicID.make(from: signature),
            // Built from what is on the plate, not from the pattern that was attempted: rounding a
            // portion to whole pieces can drop an item, and a two-item plate must not be announced
            // as "Protein, carbs and vegetables".
            titleKey: Self.patternKey(for: built.map(\.role)),
            title: title,
            items: built.map(\.portion),
            macros: macros,
            score: components.total(context.weights),
            reasons: reasons(
                macros: macros,
                context: context,
                components: components,
                built: built,
                savedMealUses: nil,
                recipeMinutes: nil,
                isRecipe: false
            ),
            savedMealID: nil,
            recipeID: nil
        )
    }

    /// Energy is recomputed from the macros when the source record carries none, so a suggestion's
    /// calorie figure is never zero just because an imported food forgot to state it.
    private func normalisedMacros(
        _ macros: MacroNutrients,
        food: MealCandidateFood,
        grams: Double
    ) -> MacroNutrients {
        guard macros.kilocalories <= 0 else { return macros }
        var copy = macros
        copy.kilocalories = food.effectiveKilocaloriesPer100 * grams / 100
        return copy
    }

    /// The localisation key describing the shape of a plate.
    ///
    /// Every case below is written in the order `sorted()` actually produces — alphabetical by raw
    /// value, so `fat` precedes `protein` and `carbohydrate` precedes both. Writing a case in
    /// reading order instead makes it silently unreachable, which is how protein-and-fat plates came
    /// to be labelled "A single food".
    private static func patternKey(for roles: [FoodRole]) -> String {
        let sorted = Set(roles).map(\.rawValue).sorted()
        switch sorted {
        case ["carbohydrate", "protein", "vegetable"]: return "meal.pattern.proteinCarbVegetable"
        case ["carbohydrate", "fat", "protein"]: return "meal.pattern.proteinCarbFat"
        case ["fat", "protein", "vegetable"]: return "meal.pattern.proteinVegetableFat"
        case ["carbohydrate", "protein"]: return "meal.pattern.proteinCarb"
        case ["protein", "vegetable"]: return "meal.pattern.proteinVegetable"
        case ["carbohydrate", "vegetable"]: return "meal.pattern.carbVegetable"
        case ["carbohydrate", "fat"]: return "meal.pattern.carbFat"
        case ["fat", "protein"]: return "meal.pattern.proteinFat"
        case ["fat", "vegetable"]: return "meal.pattern.vegetableFat"
        default:
            // One item is genuinely a single food; anything else is a shape with no name of its own
            // (two composite foods, or a plate whose roles collapsed after pruning), and claiming
            // "a single food" for two items would be a small lie in the user's list.
            return roles.count <= 1 ? "meal.pattern.single" : "meal.pattern.mixed"
        }
    }

    // MARK: - Portion solving

    /// Grams bounds and a starting point for one food in one role.
    private struct SolverFood {
        var per100: (protein: Double, carbs: Double, fat: Double, energy: Double)
        var lowerGrams: Double
        var upperGrams: Double
        var initialGrams: Double
    }

    /// Solves for the portion sizes that come closest to `target`.
    ///
    /// This is a small bounded least-squares problem: find grams `x` minimising the weighted squared
    /// error between what the portions deliver and what the meal needs. It is solved by cyclic
    /// coordinate descent — each food's optimum given the others has a closed form, clamp it to the
    /// food's sensible range, repeat. The objective is convex and the constraints are a box, so the
    /// iteration converges; a fixed forty passes make the result bit-for-bit reproducible.
    ///
    /// Each residual is divided by the size of the thing it measures, so a 10 g protein miss and a
    /// 10 g carbohydrate miss are not treated as equally bad when the targets are 40 g and 200 g.
    /// Protein and energy carry the heaviest weights: protein because it is the hardest macro to
    /// hit and the one with a real consequence for missing, energy because it is the day's ceiling.
    private func solvePortions(
        foods: [RankedFood],
        roles: [FoodRole],
        target: MacroNutrients
    ) -> [Double] {
        let solverFoods = foods.indices.map { index -> SolverFood in
            let bounds = self.bounds(for: foods[index].food, role: roles[index])
            let macros = foods[index].food.macrosPer100
            return SolverFood(
                per100: (
                    macros.proteinG, macros.carbsG, macros.fatG,
                    foods[index].food.effectiveKilocaloriesPer100
                ),
                lowerGrams: bounds.lower,
                upperGrams: bounds.upper,
                initialGrams: bounds.initial
            )
        }
        guard !solverFoods.isEmpty else { return [] }

        // Residual scales: never smaller than a floor, so a near-zero target cannot blow up the
        // relative error and dominate the objective.
        let scales: [Double] = [
            max(target.proteinG, 20), max(target.carbsG, 30),
            max(target.fatG, 10), max(target.kilocalories, 200)
        ]
        let macroWeights: [Double] = [1.0, 0.6, 0.6, 1.2]
        let targets: [Double] = [
            target.proteinG / scales[0], target.carbsG / scales[1],
            target.fatG / scales[2], target.kilocalories / scales[3]
        ]

        // b[i][m] — food i's contribution to macro m per 100 g, in scaled units.
        var coefficients: [[Double]] = []
        coefficients.reserveCapacity(solverFoods.count)
        for food in solverFoods {
            coefficients.append([
                food.per100.protein / scales[0], food.per100.carbs / scales[1],
                food.per100.fat / scales[2], food.per100.energy / scales[3]
            ])
        }

        // x is measured in hundreds of grams so the coefficients above are used directly.
        var x = solverFoods.map { nutritionClamp($0.initialGrams, $0.lowerGrams, $0.upperGrams) / 100 }
        var totals = [Double](repeating: 0, count: 4)
        for index in solverFoods.indices {
            for macro in 0..<4 { totals[macro] += coefficients[index][macro] * x[index] }
        }

        for _ in 0..<Constants.solverIterations {
            for index in solverFoods.indices {
                var numerator: Double = 0
                var denominator: Double = 0
                for macro in 0..<4 {
                    let coefficient = coefficients[index][macro]
                    let others = totals[macro] - coefficient * x[index]
                    numerator += macroWeights[macro] * coefficient * (targets[macro] - others)
                    denominator += macroWeights[macro] * coefficient * coefficient
                }
                guard denominator > 1e-9 else { continue }
                let lower = solverFoods[index].lowerGrams / 100
                let upper = solverFoods[index].upperGrams / 100
                let updated = nutritionClamp(numerator / denominator, lower, upper)
                for macro in 0..<4 {
                    totals[macro] += coefficients[index][macro] * (updated - x[index])
                }
                x[index] = updated
            }
        }
        return x.map { $0 * 100 }
    }

    /// Sensible grams for one food in one role.
    ///
    /// The role defaults describe portions people actually eat; where the food knows its own usual
    /// serving that takes precedence, allowing up to three of them. Fats are bounded tightly
    /// because the solver would otherwise cheerfully prescribe 200 g of olive oil to close an
    /// energy gap.
    private func bounds(
        for food: MealCandidateFood,
        role: FoodRole
    ) -> (lower: Double, upper: Double, initial: Double) {
        var lower: Double
        var upper: Double
        var initial: Double
        switch role {
        case .protein: (lower, upper, initial) = (40, 300, 150)
        case .carbohydrate: (lower, upper, initial) = (30, 300, 120)
        case .vegetable: (lower, upper, initial) = (50, 400, 150)
        case .fat: (lower, upper, initial) = (5, 60, 20)
        case .other: (lower, upper, initial) = (20, 300, 100)
        }
        if let serving = food.defaultServingGrams, serving > 0 {
            initial = serving
            lower = min(lower, serving)
            upper = max(min(upper, serving * 3), lower + Constants.gramRoundingStep)
        }
        if let piece = food.gramsPerPiece, piece >= Constants.minimumMeaningfulPieceGrams {
            // At least one whole piece has to be representable, otherwise the rounding step below
            // would always round the food away.
            lower = min(lower, piece)
            upper = max(upper, piece)
            initial = nutritionClamp(initial, lower, upper)
        }
        initial = nutritionClamp(initial, lower, upper)
        return (lower, upper, initial)
    }

    /// Rounds a solved portion onto a number somebody can serve: whole pieces where the food is
    /// naturally counted, 5 g steps otherwise.
    private func roundPortion(
        grams: Double,
        food: MealCandidateFood
    ) -> (grams: Double, quantity: Double, unit: ServingUnit) {
        if let piece = food.gramsPerPiece, piece >= Constants.minimumMeaningfulPieceGrams {
            let pieces = max(0, (grams / piece).rounded())
            return (pieces * piece, pieces, .piece)
        }
        let step = Constants.gramRoundingStep
        let rounded = max(0, (grams / step).rounded() * step)
        return (rounded, rounded, .grams)
    }

    // MARK: - Saved meals and recipes

    /// Saved meals, offered back verbatim.
    ///
    /// A saved meal that contains an excluded food is dropped outright: the exclusion applies to
    /// what is on the plate, not to how the plate was assembled. Items whose food is not in the
    /// candidate list cannot be checked, so they are trusted — the user built the meal themselves.
    private func savedMealSuggestions(_ context: Context) -> [MealSuggestion] {
        guard !context.request.savedMeals.isEmpty else { return [] }
        let forbiddenIDs = excludedFoodIDs(context)
        return context.request.savedMeals.compactMap { meal -> MealSuggestion? in
            guard !meal.items.isEmpty else { return nil }
            guard !meal.items.contains(where: { item in
                item.foodID.map { forbiddenIDs.contains($0) } ?? false
            }) else { return nil }

            let macros = meal.macros.kilocalories > 0
                ? meal.macros
                : meal.items.reduce(MacroNutrients.zero) { $0 + $1.macros }
            guard macros.kilocalories > 0 else { return nil }

            var components = ScoreComponents()
            components.macroFit = macroFit(macros, target: context.target)
            components.calorieFit = calorieFit(macros, target: context.target)
            // A saved meal's preference is its use count; the slot it was saved for is a strong
            // signal of when the user wants it.
            let usage = nutritionClamp01(log(1 + Double(max(0, meal.timesUsed))) / log(11))
            let slot: Double = meal.slot == context.request.slot ? 1.0 : 0.35
            components.preferenceFit = nutritionClamp01(0.6 * usage + 0.4 * slot)
            // No micronutrient data travels with a saved meal, so it scores neutrally rather than
            // being punished for what the app failed to record.
            components.micronutrientFit = 0.5
            let recentItems = meal.items.filter { item in
                item.foodID.map { context.recentIDs.contains($0) } ?? false
            }.count
            components.varietyBonus = 1 - Double(recentItems) / Double(meal.items.count)
            let grams = meal.items.reduce(0.0) { $0 + ($1.unit.isMassOrVolume ? $1.quantity : 100) }
            components.restrictionPenalty = restrictionPenalty(
                cost: nil, budget: context.mealBudget, totalGrams: grams
            )
            components.extraBonus = context.weights.savedMealBonus

            let signature = "saved:\(meal.id.uuidString)"
            return MealSuggestion(
                id: DeterministicID.make(from: signature),
                titleKey: "meal.pattern.savedMeal",
                title: meal.name,
                items: meal.items,
                macros: macros,
                score: components.total(context.weights),
                reasons: reasons(
                    macros: macros,
                    context: context,
                    components: components,
                    built: [],
                    savedMealUses: meal.timesUsed,
                    recipeMinutes: nil,
                    isRecipe: false
                ),
                savedMealID: meal.id,
                recipeID: nil
            )
        }
    }

    /// Recipes, offered at one or two servings — whichever fits the remaining macros better.
    private func recipeSuggestions(_ context: Context) -> [MealSuggestion] {
        guard !context.request.recipes.isEmpty else { return [] }
        let forbidden = context.forbidden
        return context.request.recipes.compactMap { recipe -> MealSuggestion? in
            let tags = Set(recipe.tags.map { $0.lowercased() })
            guard forbidden.isEmpty || tags.isDisjoint(with: forbidden) else { return nil }
            guard recipe.macrosPerServing.kilocalories > 0 else { return nil }

            // Two servings only when one leaves more than 45 % of the meal's energy unfilled — the
            // point is to fit the target, not to talk somebody into seconds.
            let single = recipe.macrosPerServing
            let double = recipe.macrosPerServing * 2
            let servings: Double
            let macros: MacroNutrients
            if double.kilocalories <= context.target.kilocalories * 1.1
                && single.kilocalories < context.target.kilocalories * 0.55 {
                servings = 2
                macros = double
            } else {
                servings = 1
                macros = single
            }

            var components = ScoreComponents()
            components.macroFit = macroFit(macros, target: context.target)
            components.calorieFit = calorieFit(macros, target: context.target)
            let usage = nutritionClamp01(log(1 + Double(max(0, recipe.timesUsed))) / log(11))
            let slotMatch = tags.isDisjoint(with: Self.allSlotTags)
                ? 0.5
                : (tags.isDisjoint(with: Self.slotTags(for: context.request.slot)) ? 0.15 : 1.0)
            components.preferenceFit = nutritionClamp01(0.6 * usage + 0.4 * slotMatch)
            components.micronutrientFit = 0.5
            components.varietyBonus = 1
            components.restrictionPenalty = 0
            components.extraBonus = context.weights.recipeBonus

            let portion = SuggestedFoodPortion(
                foodID: nil,
                catalogID: nil,
                name: recipe.name,
                quantity: servings,
                unit: .serving,
                macros: macros
            )
            let signature = "recipe:\(recipe.id.uuidString)@\(Int(servings))"
            return MealSuggestion(
                id: DeterministicID.make(from: signature),
                titleKey: "meal.pattern.recipe",
                title: recipe.name,
                items: [portion],
                macros: macros,
                score: components.total(context.weights),
                reasons: reasons(
                    macros: macros,
                    context: context,
                    components: components,
                    built: [],
                    savedMealUses: nil,
                    recipeMinutes: recipe.preparationMinutes,
                    isRecipe: true
                ),
                savedMealID: nil,
                recipeID: recipe.id
            )
        }
    }

    /// Ids of candidate foods the user must not be shown, so saved meals referencing them can be
    /// filtered out too.
    private func excludedFoodIDs(_ context: Context) -> Set<UUID> {
        guard !context.forbidden.isEmpty else { return [] }
        var ids: Set<UUID> = []
        for food in context.request.candidates where !food.allTags.isDisjoint(with: context.forbidden) {
            ids.insert(food.id)
        }
        return ids
    }

    // MARK: - Scoring

    /// 0…1 — how close the macros land to the target, with each miss measured against the size of
    /// the macro it misses. Protein carries half the weight on its own.
    private func macroFit(_ macros: MacroNutrients, target: MacroNutrients) -> Double {
        let proteinError = abs(macros.proteinG - target.proteinG) / max(target.proteinG, 20)
        let carbError = abs(macros.carbsG - target.carbsG) / max(target.carbsG, 30)
        let fatError = abs(macros.fatG - target.fatG) / max(target.fatG, 10)
        let weighted = 0.5 * proteinError + 0.25 * carbError + 0.25 * fatError
        return nutritionClamp01(1 - weighted)
    }

    /// 0…1 — how close the energy lands, penalising overshoot harder than undershoot.
    private func calorieFit(_ macros: MacroNutrients, target: MacroNutrients) -> Double {
        let scale = max(target.kilocalories, 150)
        let difference = macros.kilocalories - target.kilocalories
        let penalty = difference >= 0
            ? Constants.calorieOvershootPenaltyFactor * difference / scale
            : -difference / scale
        return nutritionClamp01(1 - penalty)
    }

    /// Nutrients most often short in everyday diets, used to reward a suggestion that brings some.
    /// Deliberately a short list: this is a nudge towards vegetables and whole foods, not a claim
    /// about anybody's nutritional status.
    private static let priorityMicronutrients: [Micronutrient] = [
        .fiber, .potassium, .calcium, .iron, .vitaminC
    ]
    private static let limitingMicronutrients: [Micronutrient] = [.sodium, .saturatedFat]

    /// 0…1 — micronutrient contribution, tempered by the sodium and saturated-fat load.
    ///
    /// Nutrients the data does not know are skipped rather than scored zero. When nothing is known
    /// the whole factor is neutral at 0.5, so a suggestion built from sparse data is neither
    /// rewarded nor punished for the gap.
    private func micronutrientFit(_ micros: Micronutrients) -> Double {
        var coverageTotal: Double = 0
        var coverageCount: Double = 0
        for nutrient in Self.priorityMicronutrients {
            guard let value = micros[nutrient], let reference = nutrient.referenceDailyIntake,
                  reference > 0 else { continue }
            coverageTotal += nutritionClamp01(value / (reference * Constants.micronutrientMealShare))
            coverageCount += 1
        }
        let coverage = coverageCount > 0 ? coverageTotal / coverageCount : 0.5

        var limitingTotal: Double = 0
        var limitingCount: Double = 0
        for nutrient in Self.limitingMicronutrients {
            guard let value = micros[nutrient] else { continue }
            let daily = nutrient.referenceDailyIntake ?? Constants.saturatedFatDailyCeilingG
            guard daily > 0 else { continue }
            limitingTotal += nutritionClamp01(value / (daily * Constants.limitingNutrientMealShare))
            limitingCount += 1
        }
        let limiting = limitingCount > 0 ? limitingTotal / limitingCount : 0
        let excess = max(0, limiting - Constants.limitingNutrientTolerance)
        return nutritionClamp01(coverage - 0.4 * excess)
    }

    /// Soft penalties: cost above the per-meal budget, and a plate nobody would serve.
    private func restrictionPenalty(cost: Double?, budget: Double?, totalGrams: Double) -> Double {
        var budgetPenalty: Double = 0
        if let budget, budget > 0, let cost, cost > 0 {
            budgetPenalty = nutritionClamp01((cost - budget) / max(budget, 1))
        }
        let bulk = nutritionClamp01(
            (totalGrams - Constants.comfortablePlateGrams) / Constants.plateGramsPenaltySpan
        )
        return nutritionClamp01(0.7 * budgetPenalty + 0.3 * bulk)
    }

    /// Total cost of a suggestion, or `nil` when no item carries a price — unknown cost must not be
    /// read as free, nor as expensive.
    private func totalCost(of built: [BuiltPortion]) -> Double? {
        var total: Double = 0
        var known = false
        for item in built {
            guard let per100 = item.ranked.food.costPer100 else { continue }
            total += per100 * item.grams / 100
            known = true
        }
        return known ? total : nil
    }

    // MARK: - Reasons

    /// Why this suggestion, best reason first. Every suggestion names the macros it fills — a
    /// recommendation the user cannot interrogate is one they cannot sensibly overrule.
    private func reasons(
        macros: MacroNutrients,
        context: Context,
        components: ScoreComponents,
        built: [BuiltPortion],
        savedMealUses: Int?,
        recipeMinutes: Int?,
        isRecipe: Bool
    ) -> [Explanation] {
        var reasons: [Explanation] = []

        if let uses = savedMealUses, uses > 0 {
            reasons.append(Explanation("meal.reason.savedMeal", [NutritionFormat.whole(Double(uses))]))
        } else if isRecipe {
            if let minutes = recipeMinutes, minutes > 0 {
                reasons.append(Explanation("meal.reason.recipe", [NutritionFormat.whole(Double(minutes))]))
            } else {
                reasons.append(Explanation("meal.reason.recipeNoTime"))
            }
        }

        reasons.append(Explanation("meal.reason.macros", [
            NutritionFormat.whole(macros.proteinG),
            NutritionFormat.whole(macros.carbsG),
            NutritionFormat.whole(macros.fatG)
        ]))

        if context.target.proteinG >= 20, macros.proteinG >= context.target.proteinG * 0.7 {
            reasons.append(Explanation("meal.reason.protein", [NutritionFormat.whole(macros.proteinG)]))
        }
        reasons.append(Explanation("meal.reason.calories", [
            NutritionFormat.whole(macros.kilocalories),
            NutritionFormat.whole(context.target.kilocalories)
        ]))

        if built.contains(where: { $0.ranked.food.isFavorite }) {
            reasons.append(Explanation("meal.reason.favorite"))
        } else if built.contains(where: { $0.ranked.food.timesLogged >= 5 }) {
            reasons.append(Explanation("meal.reason.frequentlyLogged"))
        }
        if !built.isEmpty, components.varietyBonus >= 0.999 {
            reasons.append(Explanation("meal.reason.variety"))
        }
        if components.micronutrientFit >= 0.6, !built.isEmpty {
            reasons.append(Explanation("meal.reason.micronutrients"))
        }
        if context.mealBudget != nil, components.restrictionPenalty <= 0.01, !built.isEmpty {
            reasons.append(Explanation("meal.reason.budget"))
        }
        return Array(reasons.prefix(Constants.maximumReasons))
    }

    // MARK: - Finalising

    /// De-duplicates, diversifies, sorts and truncates.
    ///
    /// Two suggestions built from the same set of foods are the same suggestion as far as the user
    /// is concerned, however differently the solver portioned them, so only the best-scoring one
    /// survives. The final few are then picked greedily with a demotion for repeating a food
    /// already picked, because a list of near-identical plates is a list with one entry on it. The
    /// picked set is returned in score order, as the contract promises.
    ///
    /// Every comparison carries a full tie-break: Swift's `sort` is not stable, and the output has
    /// to be identical between runs.
    private func finalise(_ suggestions: [MealSuggestion], limit: Int) -> [MealSuggestion] {
        var best: [String: MealSuggestion] = [:]
        var order: [String] = []
        for suggestion in suggestions {
            let key = Self.duplicateKey(for: suggestion)
            if let existing = best[key] {
                // Same tie-break as the final sort, id included: two solves of the same food set can
                // land on the same score and title with different portions, and without the last
                // comparison which one survived would depend on the order the caller happened to
                // pass its candidates in.
                if Self.scoreOrder(suggestion, existing) { best[key] = suggestion }
            } else {
                best[key] = suggestion
                order.append(key)
            }
        }
        let deduplicated = order.compactMap { best[$0] }
        var pool = deduplicated.sorted(by: Self.scoreOrder)

        var picked: [MealSuggestion] = []
        var usedFoods: Set<String> = []
        while picked.count < limit && !pool.isEmpty {
            var bestIndex = 0
            var bestAdjusted = -Double.greatestFiniteMagnitude
            for (index, suggestion) in pool.enumerated() {
                let repeats = suggestion.items.filter { usedFoods.contains($0.identityKey) }.count
                let adjusted = suggestion.score - Double(repeats) * Constants.repeatedFoodDemotion
                // Strictly greater, so an exact tie keeps the earlier — and therefore
                // higher-scoring — entry, which is what makes the loop reproducible.
                if adjusted > bestAdjusted { bestAdjusted = adjusted; bestIndex = index }
            }
            let chosen = pool.remove(at: bestIndex)
            usedFoods.formUnion(chosen.items.map(\.identityKey))
            picked.append(chosen)
        }
        return picked.sorted(by: Self.scoreOrder)
    }

    private static func scoreOrder(_ lhs: MealSuggestion, _ rhs: MealSuggestion) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func duplicateKey(for suggestion: MealSuggestion) -> String {
        if let savedMealID = suggestion.savedMealID { return "saved:\(savedMealID.uuidString)" }
        if let recipeID = suggestion.recipeID { return "recipe:\(recipeID.uuidString)" }
        return suggestion.items.map(\.identityKey).sorted().joined(separator: "|")
    }
}
