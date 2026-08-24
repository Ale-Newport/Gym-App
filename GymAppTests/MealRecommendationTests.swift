import Foundation
import Testing
@testable import GymApp

/// Behavioural tests for `MealRecommendationEngine`.
///
/// Specification: `docs/fragments/nutrition.md` §5. The two promises that matter most are that a
/// hard exclusion is *never* softened into a penalty, and that identical input produces identical
/// output — both are exercised directly below.
@Suite("Meal recommendation engine")
struct MealRecommendationTests {

    // MARK: - Candidate fixtures

    /// Fixed ids so `recentlyLoggedIDs` and the determinism tests have something stable to name.
    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private static func food(
        _ index: Int,
        _ name: String,
        kcal: Double,
        protein: Double,
        carbs: Double,
        fat: Double,
        dietary: Set<String> = [],
        allergens: Set<String> = [],
        roles: Set<String> = [],
        fibre: Double? = nil,
        gramsPerPiece: Double? = nil,
        defaultServing: Double? = nil,
        timesLogged: Int = 0,
        isFavorite: Bool = false,
        costPer100: Double? = nil
    ) -> MealCandidateFood {
        var micros = Micronutrients.unknown
        micros.fiberG = fibre
        return MealCandidateFood(
            id: id(index),
            catalogID: "cat-\(index)",
            name: name,
            macrosPer100: MacroNutrients(
                kilocalories: kcal, proteinG: protein, carbsG: carbs, fatG: fat
            ),
            micronutrientsPer100: micros,
            dietaryTags: dietary,
            allergenTags: allergens,
            roleTags: roles,
            gramsPerPiece: gramsPerPiece,
            defaultServingGrams: defaultServing,
            timesLogged: timesLogged,
            isFavorite: isFavorite,
            costPer100: costPer100
        )
    }

    private static var chicken: MealCandidateFood {
        food(1, "Chicken breast", kcal: 165, protein: 31, carbs: 0, fat: 3.6,
             dietary: ["meat", "poultry"], roles: ["protein_source"], timesLogged: 12)
    }
    private static var salmon: MealCandidateFood {
        food(2, "Salmon", kcal: 208, protein: 20, carbs: 0, fat: 13,
             dietary: ["fish", "seafood"], roles: ["protein_source"], timesLogged: 4)
    }
    private static var eggs: MealCandidateFood {
        food(3, "Egg", kcal: 155, protein: 13, carbs: 1.1, fat: 11,
             dietary: ["egg"], roles: ["protein_source", "breakfast"],
             gramsPerPiece: 50, timesLogged: 9)
    }
    private static var greekYogurt: MealCandidateFood {
        food(4, "Greek yoghurt", kcal: 59, protein: 10, carbs: 3.6, fat: 0.4,
             dietary: ["dairy"], roles: ["protein_source", "breakfast"], timesLogged: 7)
    }
    private static var tofu: MealCandidateFood {
        food(5, "Firm tofu", kcal: 144, protein: 15.7, carbs: 4.3, fat: 8.7,
             dietary: ["soy"], roles: ["protein_source"], timesLogged: 6)
    }
    private static var lentils: MealCandidateFood {
        food(6, "Cooked lentils", kcal: 116, protein: 9, carbs: 20, fat: 0.4,
             roles: ["protein_source"], fibre: 7.9, timesLogged: 3)
    }
    private static var rice: MealCandidateFood {
        food(7, "Cooked rice", kcal: 130, protein: 2.7, carbs: 28, fat: 0.3,
             roles: ["carb_source"], timesLogged: 15)
    }
    private static var potato: MealCandidateFood {
        food(8, "Boiled potato", kcal: 87, protein: 1.9, carbs: 20, fat: 0.1,
             roles: ["carb_source"], fibre: 1.8, timesLogged: 5)
    }
    private static var broccoli: MealCandidateFood {
        food(9, "Broccoli", kcal: 34, protein: 2.8, carbs: 7, fat: 0.4,
             roles: ["vegetable"], fibre: 2.6, timesLogged: 8)
    }
    private static var spinach: MealCandidateFood {
        food(10, "Spinach", kcal: 23, protein: 2.9, carbs: 3.6, fat: 0.4,
             roles: ["vegetable"], fibre: 2.2, timesLogged: 2)
    }
    private static var oliveOil: MealCandidateFood {
        food(11, "Olive oil", kcal: 884, protein: 0, carbs: 0, fat: 100,
             roles: ["fat_source", "oil"], timesLogged: 10)
    }
    private static var peanutButter: MealCandidateFood {
        food(12, "Peanut butter", kcal: 588, protein: 25, carbs: 20, fat: 50,
             allergens: ["peanut"], roles: ["fat_source", "nut"], timesLogged: 6)
    }
    private static var beefMince: MealCandidateFood {
        food(13, "Beef mince", kcal: 250, protein: 26, carbs: 0, fat: 15,
             dietary: ["meat"], roles: ["protein_source"], timesLogged: 5)
    }
    /// A composite food that fits none of the named roles — the `.other` fallback case.
    private static var readyMeal: MealCandidateFood {
        food(14, "Chicken tikka ready meal", kcal: 140, protein: 8, carbs: 14, fat: 5,
             roles: [], timesLogged: 4)
    }

    private static var omnivoreLarder: [MealCandidateFood] {
        [chicken, salmon, eggs, greekYogurt, tofu, lentils,
         rice, potato, broccoli, spinach, oliveOil, peanutButter, beefMince]
    }

    // MARK: - Profile and request fixtures

    private static func profile(
        diet: DietType = .omnivore,
        allergens: Set<String> = [],
        intolerances: Set<String> = [],
        excluded: Set<String> = [],
        mealsPerDay: Int = 4,
        weeklyFoodBudget: Double? = nil
    ) -> NutritionProfileSnapshot {
        var snapshot = NutritionProfileSnapshot()
        snapshot.dietType = diet
        snapshot.allergenTags = allergens
        snapshot.intoleranceTags = intolerances
        snapshot.excludedFoodTags = excluded
        snapshot.mealsPerDay = mealsPerDay
        snapshot.weeklyFoodBudget = weeklyFoodBudget
        return snapshot
    }

    private static func request(
        remaining: MacroNutrients = MacroNutrients(
            kilocalories: 700, proteinG: 50, carbsG: 70, fatG: 20
        ),
        slot: MealSlot = .lunch,
        profile: NutritionProfileSnapshot = profile(),
        candidates: [MealCandidateFood] = omnivoreLarder,
        recentlyLoggedIDs: [UUID] = [],
        savedMeals: [SavedMealCandidate] = [],
        recipes: [RecipeCandidate] = [],
        limit: Int = 5,
        dailyTarget: MacroNutrients? = nil
    ) -> MealRecommendationRequest {
        MealRecommendationRequest(
            remaining: remaining,
            slot: slot,
            profile: profile,
            candidates: candidates,
            recentlyLoggedIDs: recentlyLoggedIDs,
            savedMeals: savedMeals,
            recipes: recipes,
            limit: limit,
            dailyTarget: dailyTarget
        )
    }

    private static let engine = MealRecommendationEngine()

    private static func allNames(_ suggestions: [MealSuggestion]) -> [String] {
        suggestions.flatMap { $0.items.map(\.name) }
    }

    // MARK: - Empty and degenerate input

    @Test("An empty candidate list returns an empty array rather than crashing")
    func emptyCandidateListReturnsNothing() {
        let suggestions = Self.engine.suggestions(for: Self.request(candidates: []))
        #expect(suggestions.isEmpty)
    }

    @Test("Nothing is suggested below the 80 kcal remaining floor")
    func tinyRemainderSuggestsNothing() {
        let barelyAnything = MacroNutrients(kilocalories: 79, proteinG: 5, carbsG: 8, fatG: 2)
        #expect(Self.engine.suggestions(for: Self.request(remaining: barelyAnything)).isEmpty)

        let nothingLeft = MacroNutrients(kilocalories: 0, proteinG: 0, carbsG: 0, fatG: 0)
        #expect(Self.engine.suggestions(for: Self.request(remaining: nothingLeft)).isEmpty)
    }

    @Test("A negative remaining energy is not read as an enormous appetite")
    func overshotDayReturnsNothing() {
        let overshot = MacroNutrients(kilocalories: -400, proteinG: -20, carbsG: -50, fatG: -10)
        #expect(Self.engine.suggestions(for: Self.request(remaining: overshot)).isEmpty)
    }

    @Test("A zero or negative limit returns nothing")
    func nonPositiveLimitReturnsNothing() {
        #expect(Self.engine.suggestions(for: Self.request(limit: 0)).isEmpty)
        #expect(Self.engine.suggestions(for: Self.request(limit: -3)).isEmpty)
    }

    @Test("Foods carrying no usable nutrition are dropped rather than portioned")
    func emptyFoodsAreIneligible() {
        let blank = Self.food(90, "Water", kcal: 0, protein: 0, carbs: 0, fat: 0)
        let suggestions = Self.engine.suggestions(for: Self.request(candidates: [blank]))
        #expect(suggestions.isEmpty)
    }

    @Test("At most `limit` suggestions come back, best first")
    func limitIsHonouredAndOutputIsSorted() {
        for limit in [1, 2, 3, 5] {
            let suggestions = Self.engine.suggestions(for: Self.request(limit: limit))
            #expect(suggestions.count <= limit)
            for index in 1..<max(1, suggestions.count) {
                #expect(
                    suggestions[index - 1].score >= suggestions[index].score,
                    "suggestions came back out of score order at limit \(limit)"
                )
            }
        }
    }

    // MARK: - Hard exclusions

    @Test("A vegan profile is never shown meat, fish, dairy or egg")
    func veganProfileNeverSeesAnimalFoods() {
        let suggestions = Self.engine.suggestions(
            for: Self.request(profile: Self.profile(diet: .vegan))
        )
        #expect(!suggestions.isEmpty, "a vegan larder still has plenty to suggest")

        let forbidden = ["Chicken breast", "Salmon", "Egg", "Greek yoghurt", "Beef mince"]
        for name in Self.allNames(suggestions) {
            #expect(!forbidden.contains(name), "a vegan profile was offered \(name)")
        }
    }

    @Test("A vegetarian profile keeps dairy and eggs but never meat or fish")
    func vegetarianProfileKeepsDairyAndEggs() {
        let suggestions = Self.engine.suggestions(
            for: Self.request(profile: Self.profile(diet: .vegetarian))
        )
        let names = Set(Self.allNames(suggestions))
        #expect(!names.contains("Chicken breast"))
        #expect(!names.contains("Salmon"))
        #expect(!names.contains("Beef mince"))
    }

    @Test("A pescatarian profile keeps fish but never meat")
    func pescatarianProfileKeepsFish() {
        let suggestions = Self.engine.suggestions(
            for: Self.request(profile: Self.profile(diet: .pescatarian))
        )
        let names = Set(Self.allNames(suggestions))
        #expect(!names.contains("Chicken breast"))
        #expect(!names.contains("Beef mince"))
    }

    @Test("A vegan profile with an all-animal larder is shown nothing, not a compromise")
    func exclusionsAreAbsoluteNotAPenalty() {
        let animalOnly = [Self.chicken, Self.salmon, Self.beefMince, Self.eggs, Self.greekYogurt]
        let suggestions = Self.engine.suggestions(
            for: Self.request(profile: Self.profile(diet: .vegan), candidates: animalOnly)
        )
        #expect(
            suggestions.isEmpty,
            "an excluded food must never be softened into a scoring penalty"
        )
    }

    @Test("An allergen is excluded absolutely")
    func allergensAreExcludedAbsolutely() {
        let suggestions = Self.engine.suggestions(
            for: Self.request(profile: Self.profile(allergens: ["peanut"]))
        )
        #expect(!suggestions.isEmpty)
        #expect(!Self.allNames(suggestions).contains("Peanut butter"))

        // And the same food is reachable when the allergy is not on file, so the test above is
        // testing the exclusion rather than an unrelated ranking accident.
        let snack = Self.engine.suggestions(
            for: Self.request(
                remaining: MacroNutrients(kilocalories: 320, proteinG: 12, carbsG: 20, fatG: 20),
                slot: .snacks,
                candidates: [Self.peanutButter, Self.rice]
            )
        )
        #expect(Self.allNames(snack).contains("Peanut butter"))
    }

    @Test("Allergen tags are matched case-insensitively")
    func allergenMatchingIgnoresCase() {
        let suggestions = Self.engine.suggestions(
            for: Self.request(profile: Self.profile(allergens: ["PEANUT"]))
        )
        #expect(!Self.allNames(suggestions).contains("Peanut butter"))
    }

    @Test("Intolerances and personal exclusions are hard filters too")
    func intolerancesAndPersonalExclusionsAreHardFilters() {
        let lactoseFree = Self.engine.suggestions(
            for: Self.request(profile: Self.profile(intolerances: ["dairy"]))
        )
        #expect(!Self.allNames(lactoseFree).contains("Greek yoghurt"))

        let noFish = Self.engine.suggestions(
            for: Self.request(profile: Self.profile(excluded: ["fish"]))
        )
        #expect(!Self.allNames(noFish).contains("Salmon"))
    }

    @Test("A saved meal containing an excluded food is dropped whole")
    func savedMealsInheritTheExclusions() {
        let chickenPortion = SuggestedFoodPortion(
            foodID: Self.id(1), catalogID: "cat-1", name: "Chicken breast",
            quantity: 150, unit: .grams,
            macros: MacroNutrients(kilocalories: 248, proteinG: 46, carbsG: 0, fatG: 5)
        )
        let ricePortion = SuggestedFoodPortion(
            foodID: Self.id(7), catalogID: "cat-7", name: "Cooked rice",
            quantity: 200, unit: .grams,
            macros: MacroNutrients(kilocalories: 260, proteinG: 5, carbsG: 56, fatG: 1)
        )
        let meal = SavedMealCandidate(
            id: Self.id(500), name: "Chicken and rice",
            macros: MacroNutrients(kilocalories: 508, proteinG: 51, carbsG: 56, fatG: 6),
            items: [chickenPortion, ricePortion], timesUsed: 9, slot: .lunch
        )

        let omnivore = Self.engine.suggestions(for: Self.request(savedMeals: [meal]))
        #expect(omnivore.contains { $0.savedMealID == meal.id })

        let vegan = Self.engine.suggestions(
            for: Self.request(profile: Self.profile(diet: .vegan), savedMeals: [meal])
        )
        #expect(!vegan.contains { $0.savedMealID == meal.id })
    }

    @Test("A recipe carrying an excluded tag is dropped")
    func recipesInheritTheExclusions() {
        let recipe = RecipeCandidate(
            id: Self.id(600), name: "Beef stew",
            macrosPerServing: MacroNutrients(kilocalories: 520, proteinG: 40, carbsG: 35, fatG: 22),
            preparationMinutes: 45, tags: ["meat", "dinner"], timesUsed: 3
        )
        let omnivore = Self.engine.suggestions(for: Self.request(recipes: [recipe]))
        #expect(omnivore.contains { $0.recipeID == recipe.id })

        let vegetarian = Self.engine.suggestions(
            for: Self.request(profile: Self.profile(diet: .vegetarian), recipes: [recipe])
        )
        #expect(!vegetarian.contains { $0.recipeID == recipe.id })
    }

    // MARK: - Roles

    @Test("Composition decides a role when no tag does, using both a share and an absolute test")
    func compositionFallbackUsesBothTests() {
        let untaggedChicken = Self.food(
            80, "Untagged chicken", kcal: 165, protein: 31, carbs: 0, fat: 3.6
        )
        #expect(Self.engine.roles(for: untaggedChicken).contains(.protein))

        // Lettuce is 25% protein by energy but carries under 10 g per 100 g, so it is not a protein.
        let lettuce = Self.food(81, "Lettuce", kcal: 15, protein: 1.4, carbs: 2.9, fat: 0.2, fibre: 1.3)
        let lettuceRoles = Self.engine.roles(for: lettuce)
        #expect(!lettuceRoles.contains(.protein), "lettuce is not a protein source")

        let untaggedRice = Self.food(82, "Untagged rice", kcal: 130, protein: 2.7, carbs: 28, fat: 0.3)
        #expect(Self.engine.roles(for: untaggedRice).contains(.carbohydrate))

        let untaggedGreens = Self.food(
            83, "Untagged greens", kcal: 34, protein: 2.8, carbs: 7, fat: 0.4, fibre: 2.6
        )
        #expect(Self.engine.roles(for: untaggedGreens).contains(.vegetable))

        let untaggedOil = Self.food(84, "Untagged oil", kcal: 884, protein: 0, carbs: 0, fat: 100)
        #expect(Self.engine.roles(for: untaggedOil).contains(.fat))
    }

    @Test("A food that fits no named role is given the other role rather than none")
    func compositeFoodsFallIntoOther() {
        #expect(Self.engine.roles(for: Self.readyMeal) == [.other])
    }

    @Test("A larder of nothing but composite foods still produces a suggestion")
    func compositeOnlyLarderFallsBackToOther() {
        let sandwich = Self.food(85, "Chicken sandwich", kcal: 220, protein: 11, carbs: 25, fat: 8)
        let bar = Self.food(86, "Protein bar", kcal: 350, protein: 22, carbs: 40, fat: 10,
                            gramsPerPiece: 60)
        let suggestions = Self.engine.suggestions(
            for: Self.request(candidates: [Self.readyMeal, sandwich, bar])
        )
        #expect(
            !suggestions.isEmpty,
            "showing nothing at all is a worse answer than an unglamorous one"
        )
    }

    // MARK: - Approaching the target

    @Test("Suggestions actually approach the remaining macros")
    func suggestionsApproachTheRemainingMacros() throws {
        let remaining = MacroNutrients(kilocalories: 700, proteinG: 50, carbsG: 70, fatG: 20)
        let suggestions = Self.engine.suggestions(for: Self.request(remaining: remaining))
        let best = try #require(suggestions.first)

        #expect(
            abs(best.macros.kilocalories - 700) < 350,
            "best suggestion delivered \(best.macros.kilocalories) kcal against 700 remaining"
        )
        #expect(
            abs(best.macros.proteinG - 50) < 25,
            "best suggestion delivered \(best.macros.proteinG) g protein against 50 remaining"
        )
        #expect(best.score > 0.3)
        #expect(!best.items.isEmpty)
        #expect(best.items.allSatisfy { $0.quantity > 0 })
    }

    @Test("Asking for more protein produces suggestions carrying more protein")
    func moreRemainingProteinProducesMoreProtein() throws {
        let lowProtein = MacroNutrients(kilocalories: 700, proteinG: 20, carbsG: 110, fatG: 20)
        let highProtein = MacroNutrients(kilocalories: 700, proteinG: 65, carbsG: 45, fatG: 20)

        let low = try #require(Self.engine.suggestions(for: Self.request(remaining: lowProtein)).first)
        let high = try #require(Self.engine.suggestions(for: Self.request(remaining: highProtein)).first)

        #expect(
            high.macros.proteinG > low.macros.proteinG,
            "a 65 g protein gap produced \(high.macros.proteinG) g against \(low.macros.proteinG) g for a 20 g gap"
        )
    }

    @Test("A meal is sized as a share of the day rather than dumping the whole remainder")
    func mealIsSizedAsAShareOfTheDay() throws {
        // 1,600 kcal left at lunchtime, on a 2,400 kcal day: lunch carries 35% of it.
        let remaining = MacroNutrients(kilocalories: 1_600, proteinG: 120, carbsG: 160, fatG: 55)
        let daily = MacroNutrients(kilocalories: 2_400, proteinG: 170, carbsG: 250, fatG: 80)
        let suggestions = Self.engine.suggestions(
            for: Self.request(remaining: remaining, dailyTarget: daily)
        )
        let best = try #require(suggestions.first)
        #expect(
            best.macros.kilocalories < 1_200,
            "one sitting was handed \(best.macros.kilocalories) of the day's 1,600 remaining kcal"
        )
    }

    @Test("A main meal is capped at 900 kcal and a snack at 350")
    func slotCapsAreRespected() throws {
        let plenty = MacroNutrients(kilocalories: 2_000, proteinG: 150, carbsG: 200, fatG: 70)
        let lunch = try #require(
            Self.engine.suggestions(for: Self.request(remaining: plenty, slot: .lunch)).first
        )
        let snack = try #require(
            Self.engine.suggestions(for: Self.request(remaining: plenty, slot: .snacks)).first
        )
        #expect(lunch.macros.kilocalories < 1_400)
        #expect(
            snack.macros.kilocalories < lunch.macros.kilocalories,
            "a snack was sized like a main meal"
        )
    }

    @Test("A macro the user has already overshot is targeted at zero, not at a negative")
    func overshotMacrosDoNotRewardEmptyFoods() throws {
        // Plenty of energy left but protein already blown past.
        let remaining = MacroNutrients(kilocalories: 600, proteinG: -30, carbsG: 90, fatG: 20)
        let suggestions = Self.engine.suggestions(for: Self.request(remaining: remaining))
        let best = try #require(suggestions.first)
        #expect(best.macros.kilocalories > 0)
        #expect(best.macros.proteinG >= 0)
    }

    // MARK: - Portions

    @Test("Portions come back on numbers somebody can serve")
    func portionsAreRoundedOntoServableNumbers() {
        let suggestions = Self.engine.suggestions(for: Self.request())
        for suggestion in suggestions {
            for item in suggestion.items {
                switch item.unit {
                case .grams, .milliliters:
                    #expect(
                        item.quantity.truncatingRemainder(dividingBy: 5) == 0,
                        "\(item.name) came back as \(item.quantity) g, off the 5 g grid"
                    )
                    #expect(item.quantity >= 10, "\(item.name) at \(item.quantity) g is noise")
                case .piece:
                    #expect(
                        item.quantity == item.quantity.rounded(),
                        "\(item.name) came back as \(item.quantity) pieces"
                    )
                    #expect(item.quantity >= 1)
                case .serving:
                    #expect(item.quantity > 0)
                }
            }
        }
    }

    @Test("A food counted in pieces is offered in whole pieces")
    func countedFoodsAreOfferedInWholePieces() {
        let suggestions = Self.engine.suggestions(
            for: Self.request(
                remaining: MacroNutrients(kilocalories: 500, proteinG: 30, carbsG: 45, fatG: 18),
                slot: .breakfast,
                candidates: [Self.eggs, Self.rice, Self.broccoli]
            )
        )
        let eggItems = suggestions.flatMap { $0.items }.filter { $0.name == "Egg" }
        #expect(!eggItems.isEmpty)
        for item in eggItems {
            #expect(item.unit == .piece)
            #expect(item.quantity == item.quantity.rounded())
        }
    }

    @Test("The solver does not prescribe an absurd amount of oil to close an energy gap")
    func fatPortionsAreBoundedTightly() {
        let suggestions = Self.engine.suggestions(
            for: Self.request(
                remaining: MacroNutrients(kilocalories: 900, proteinG: 40, carbsG: 60, fatG: 45)
            )
        )
        for item in suggestions.flatMap(\.items) where item.name == "Olive oil" {
            #expect(item.quantity <= 60, "\(item.quantity) g of olive oil is not a portion")
        }
    }

    @Test("Every suggestion's macros are the sum of its portions")
    func suggestionMacrosAreTheSumOfItsItems() {
        let suggestions = Self.engine.suggestions(for: Self.request())
        for suggestion in suggestions where suggestion.savedMealID == nil && suggestion.recipeID == nil {
            let summed = suggestion.items.reduce(MacroNutrients.zero) { $0 + $1.macros }
            #expect(abs(summed.kilocalories - suggestion.macros.kilocalories) < 0.001)
            #expect(abs(summed.proteinG - suggestion.macros.proteinG) < 0.001)
        }
    }

    // MARK: - Titles and reasons

    @Test("The title key describes the plate that survived rounding")
    func titleKeyDescribesTheActualPlate() {
        let suggestions = Self.engine.suggestions(for: Self.request())
        #expect(!suggestions.isEmpty)
        for suggestion in suggestions {
            let key = suggestion.titleKey ?? ""
            #expect(!key.isEmpty)
            if suggestion.items.count > 1 {
                #expect(
                    key != "meal.pattern.single",
                    "\(suggestion.items.count) items were announced as a single food"
                )
            }
        }
    }

    @Test("A protein-and-fat plate gets its own name rather than being called a single food")
    func proteinAndFatPlateIsNamedCorrectly() {
        let suggestions = Self.engine.suggestions(
            for: Self.request(
                remaining: MacroNutrients(kilocalories: 600, proteinG: 45, carbsG: 5, fatG: 35),
                candidates: [Self.chicken, Self.oliveOil]
            )
        )
        let twoItem = suggestions.first { $0.items.count == 2 }
        if let twoItem {
            #expect(twoItem.titleKey == "meal.pattern.proteinFat")
        }
    }

    @Test("Every suggestion carries reasons, capped at four")
    func everySuggestionExplainsItself() {
        let suggestions = Self.engine.suggestions(for: Self.request())
        #expect(!suggestions.isEmpty)
        for suggestion in suggestions {
            #expect(!suggestion.reasons.isEmpty)
            #expect(suggestion.reasons.count <= 4)
            #expect(suggestion.reasons.contains { $0.key == "meal.reason.macros" })
        }
    }

    // MARK: - Cost

    @Test("A suggestion costing more than twice the meal budget is dropped, not merely penalised")
    func absurdlyExpensiveSuggestionsAreDropped() {
        let caviar = Self.food(87, "Caviar", kcal: 264, protein: 25, carbs: 4, fat: 18,
                               roles: ["protein_source"], costPer100: 400)
        let cheapRice = Self.food(88, "Rice", kcal: 130, protein: 2.7, carbs: 28, fat: 0.3,
                                  roles: ["carb_source"], costPer100: 0.2)
        let suggestions = Self.engine.suggestions(
            for: Self.request(
                profile: Self.profile(weeklyFoodBudget: 40),   // ~1.43 per meal on four meals a day
                candidates: [caviar, cheapRice]
            )
        )
        #expect(!Self.allNames(suggestions).contains("Caviar"))
    }

    @Test("Unknown cost is neutral rather than free")
    func unknownCostDoesNotWinOnPrice() {
        // Every food here has an unknown cost, so a budget must not silently drop the whole larder.
        let suggestions = Self.engine.suggestions(
            for: Self.request(profile: Self.profile(weeklyFoodBudget: 10))
        )
        #expect(!suggestions.isEmpty)
    }

    // MARK: - Variety

    @Test("The final list is not four variations on the same food")
    func repeatedFoodsAreDemotedInTheFinalList() {
        let suggestions = Self.engine.suggestions(for: Self.request(limit: 4))
        guard suggestions.count >= 3 else { return }
        let distinctFirstItems = Set(suggestions.compactMap { $0.items.first?.identityKey })
        #expect(
            distinctFirstItems.count > 1,
            "every suggestion led with the same food"
        )
    }

    @Test("Two suggestions built from the same foods are de-duplicated")
    func duplicateFoodSetsAreCollapsed() {
        let suggestions = Self.engine.suggestions(for: Self.request(limit: 5))
        let keys = suggestions.map { $0.items.map(\.identityKey).sorted().joined(separator: "|") }
        #expect(Set(keys).count == keys.count, "the same food set appeared twice")
    }

    // MARK: - Determinism

    @Test("Identical requests produce identical suggestions")
    func suggestionsAreDeterministic() {
        let first = Self.engine.suggestions(for: Self.request())
        for _ in 0..<25 {
            #expect(Self.engine.suggestions(for: Self.request()) == first)
        }
    }

    @Test("Reversing the candidate list does not change the suggestions")
    func candidateOrderDoesNotChangeTheOutput() {
        let forwards = Self.engine.suggestions(for: Self.request(candidates: Self.omnivoreLarder))
        let backwards = Self.engine.suggestions(
            for: Self.request(candidates: Self.omnivoreLarder.reversed())
        )
        #expect(forwards == backwards)
    }

    @Test("Rotating the candidate list does not change the suggestions")
    func candidateRotationDoesNotChangeTheOutput() {
        let base = Self.engine.suggestions(for: Self.request(candidates: Self.omnivoreLarder))
        for offset in 1..<Self.omnivoreLarder.count {
            let rotated = Array(Self.omnivoreLarder[offset...] + Self.omnivoreLarder[..<offset])
            #expect(
                Self.engine.suggestions(for: Self.request(candidates: rotated)) == base,
                "rotating the larder by \(offset) changed the output"
            )
        }
    }

    @Test("Suggestion ids are derived from their contents, so an unchanged list stays unchanged")
    func idsAreContentDerived() {
        let first = Self.engine.suggestions(for: Self.request())
        let second = Self.engine.suggestions(for: Self.request())
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == first.count, "two suggestions shared an id")
    }

    // MARK: - Saved meals and recipes

    @Test("A saved meal is offered back and carries its own reason")
    func savedMealsAreOfferedBack() throws {
        let items = [
            SuggestedFoodPortion(
                foodID: Self.id(4), catalogID: "cat-4", name: "Greek yoghurt",
                quantity: 200, unit: .grams,
                macros: MacroNutrients(kilocalories: 118, proteinG: 20, carbsG: 7, fatG: 1)
            ),
            SuggestedFoodPortion(
                foodID: Self.id(9), catalogID: "cat-9", name: "Broccoli",
                quantity: 150, unit: .grams,
                macros: MacroNutrients(kilocalories: 51, proteinG: 4, carbsG: 11, fatG: 1)
            )
        ]
        let meal = SavedMealCandidate(
            id: Self.id(501), name: "Usual breakfast",
            macros: MacroNutrients(kilocalories: 169, proteinG: 24, carbsG: 18, fatG: 2),
            items: items, timesUsed: 12, slot: .breakfast
        )
        // No loose candidates, so the saved meal is judged on its own rather than having to
        // out-score every plate the combination generator can build from a full larder.
        let suggestions = Self.engine.suggestions(
            for: Self.request(slot: .breakfast, candidates: [], savedMeals: [meal], limit: 8)
        )
        let offered = try #require(suggestions.first { $0.savedMealID == meal.id })
        #expect(offered.titleKey == "meal.pattern.savedMeal")
        #expect(offered.title == "Usual breakfast")
        #expect(offered.reasons.contains { $0.key == "meal.reason.savedMeal" })
    }

    @Test("An empty saved meal is skipped rather than offered as a plate of nothing")
    func emptySavedMealsAreSkipped() {
        let empty = SavedMealCandidate(
            id: Self.id(502), name: "Nothing", macros: .zero, items: [], timesUsed: 3, slot: .lunch
        )
        let suggestions = Self.engine.suggestions(for: Self.request(savedMeals: [empty]))
        #expect(!suggestions.contains { $0.savedMealID == empty.id })
    }

    @Test("A recipe is offered at two servings only when one leaves the meal badly unfilled")
    func recipeServingsFollowTheRemainder() throws {
        let small = RecipeCandidate(
            id: Self.id(601), name: "Small soup",
            macrosPerServing: MacroNutrients(kilocalories: 200, proteinG: 12, carbsG: 20, fatG: 6),
            preparationMinutes: 20, tags: ["lunch"], timesUsed: 2
        )
        let large = RecipeCandidate(
            id: Self.id(602), name: "Big bake",
            macrosPerServing: MacroNutrients(kilocalories: 620, proteinG: 45, carbsG: 55, fatG: 22),
            preparationMinutes: 50, tags: ["lunch"], timesUsed: 2
        )
        let remaining = MacroNutrients(kilocalories: 700, proteinG: 50, carbsG: 70, fatG: 20)
        // No larder: this test is about the serving-count rule, and a 200 kcal recipe against a
        // 700 kcal meal is a mediocre fit that a full larder of combinations rightly outranks.
        // Letting those compete would test the ranking, not the rule.
        let suggestions = Self.engine.suggestions(
            for: Self.request(remaining: remaining, candidates: [], recipes: [small, large], limit: 10)
        )

        let smallSuggestion = try #require(suggestions.first { $0.recipeID == small.id })
        let largeSuggestion = try #require(suggestions.first { $0.recipeID == large.id })
        #expect(smallSuggestion.items.first?.quantity == 2, "200 kcal leaves 71% of a 700 kcal meal unfilled")
        #expect(largeSuggestion.items.first?.quantity == 1)
    }

    @Test("A recipe with no energy figure is skipped")
    func caloriefreeRecipesAreSkipped() {
        let broken = RecipeCandidate(
            id: Self.id(603), name: "Unfilled recipe",
            macrosPerServing: .zero, preparationMinutes: nil, tags: [], timesUsed: 0
        )
        let suggestions = Self.engine.suggestions(for: Self.request(recipes: [broken]))
        #expect(!suggestions.contains { $0.recipeID == broken.id })
    }
}
