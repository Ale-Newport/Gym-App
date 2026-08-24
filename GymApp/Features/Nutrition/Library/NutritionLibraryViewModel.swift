import Foundation
import Observation
import SwiftData

// MARK: - Shared phase

/// Load state shared by every screen in the nutrition library.
///
/// One enum rather than a scattering of `isLoading` / `errorMessage` pairs: the four states a screen
/// has to render are a single fact about that screen, and the bug that always ships is the error
/// that cannot be told apart from "empty".
enum NutritionLibraryPhase: Hashable {
    case loading
    case ready
    case failed(Explanation)

    var isLoading: Bool { self == .loading }
    var failure: Explanation? {
        if case .failed(let explanation) = self { return explanation }
        return nil
    }
}

/// Turns anything thrown by a repository into copy the user can act on.
///
/// Repository errors already carry an `Explanation`; anything else is a programming error the user
/// cannot do anything about, so it collapses to the generic message and goes to the log instead.
enum NutritionLibraryFailure {
    static func explanation(for error: any Error) -> Explanation {
        if let repositoryError = error as? RepositoryError {
            if let detail = repositoryError.diagnosticDetail {
                AppLog.nutrition.error("Nutrition library: \(detail, privacy: .public)")
            }
            return repositoryError.explanation
        }
        AppLog.nutrition.error("Nutrition library: \(String(describing: error), privacy: .public)")
        return Explanation("common.error")
    }
}

// MARK: - Portion drafts

/// One named portion of a food while it is being edited.
struct NutritionServingDraft: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var grams: Double
}

/// One editable portion inside a saved meal or a recipe.
///
/// The food's per-100 basis is snapshotted into the draft when it is picked, so the running total
/// updates as the user types without a fetch per keystroke. The repository recomputes everything
/// from the live `FoodItem` on save, so the snapshot is only ever a preview — it can never write a
/// stale number into the store.
struct NutritionPortionDraft: Identifiable, Hashable {
    /// Row identity. Deliberately *not* the food's id: the same food may appear twice in a recipe.
    var id = UUID()
    var foodID: UUID
    var name: String
    var brand: String?
    var quantity: Double
    var unit: ServingUnit
    var servingIndex: Int?

    var macrosPer100: MacroNutrients
    var basisUnit: ServingUnit
    var gramsPerPiece: Double?
    var servings: [NutritionServingDraft]

    /// Grams (or millilitres) this portion represents. Mirrors `FoodItem.basisQuantity(for:unit:)`
    /// exactly — if the two ever disagree the preview total would not match what gets stored.
    var basisQuantity: Double {
        switch unit {
        case .grams, .milliliters:
            return quantity
        case .piece:
            return quantity * (gramsPerPiece ?? 100)
        case .serving:
            let grams = servingIndex
                .flatMap { servings.indices.contains($0) ? servings[$0].grams : nil }
                ?? servings.first?.grams
            return quantity * (grams ?? 100)
        }
    }

    var macros: MacroNutrients { macrosPer100 * (basisQuantity / 100) }

    /// Units this particular food can actually be measured in. A food with no named servings must
    /// not offer "serving", because the portion maths would silently fall back to 100 g.
    var availableUnits: [ServingUnit] {
        var units: [ServingUnit] = [basisUnit == .milliliters ? .milliliters : .grams]
        if gramsPerPiece != nil { units.append(.piece) }
        if !servings.isEmpty { units.append(.serving) }
        return units
    }

    var input: NutritionPortionInput {
        NutritionPortionInput(foodID: foodID, quantity: quantity, unit: unit, servingIndex: servingIndex)
    }

    @MainActor
    static func make(
        from food: FoodItem,
        quantity: Double? = nil,
        unit: ServingUnit? = nil,
        servingIndex: Int? = nil
    ) -> NutritionPortionDraft {
        let servings = food.servings.map {
            NutritionServingDraft(name: $0.nameKey.map { key in L(key) } ?? $0.name, grams: $0.gramsPerServing)
        }
        let resolvedUnit = unit ?? (food.basisUnit == .milliliters ? .milliliters : .grams)
        return NutritionPortionDraft(
            foodID: food.id,
            name: food.name,
            brand: food.brand,
            // 100 g is the basis every packet is labelled in, so it is the least surprising default.
            quantity: quantity ?? (resolvedUnit.isMassOrVolume ? 100 : 1),
            unit: resolvedUnit,
            servingIndex: servingIndex,
            macrosPer100: food.macrosPer100,
            basisUnit: food.basisUnit,
            gramsPerPiece: food.gramsPerPiece,
            servings: servings
        )
    }
}

extension Array where Element == NutritionPortionDraft {
    var totalMacros: MacroNutrients {
        reduce(MacroNutrients.zero) { $0 + $1.macros }
    }
}

// MARK: - Food picker

/// One row of the library's own food picker.
struct NutritionFoodRow: Identifiable, Hashable {
    var id: UUID
    var name: String
    var brand: String?
    var kilocaloriesPer100: Double
    var proteinPer100: Double
    var basisUnit: ServingUnit
    var source: FoodSource
    var isFavorite: Bool
}

/// Backs `LibraryFoodPickerSheet`.
///
/// The library needs its own picker because a saved meal and a recipe are assembled from stored
/// `FoodItem` rows, which is a different job from the logging flow: nothing here is written to a
/// diary, and the result is a portion the caller edits rather than an entry.
@MainActor
@Observable
final class LibraryFoodPickerViewModel {
    private(set) var phase: NutritionLibraryPhase = .loading
    private(set) var rows: [NutritionFoodRow] = []
    var query: String = ""

    private var context: ModelContext?

    func attach(_ context: ModelContext) {
        self.context = context
    }

    /// Runs the current query. Empty query lists the most-logged foods, which is what a picker
    /// should open on: the foods this user actually eats.
    func search() async {
        guard let context else { return }
        if rows.isEmpty { phase = .loading }
        do {
            let repository = NutritionRepository(context: context)
            let foods = try repository.searchFoods(query, limit: 80)
            rows = foods.map {
                NutritionFoodRow(
                    id: $0.id,
                    name: $0.name,
                    brand: $0.brand,
                    kilocaloriesPer100: $0.kilocaloriesPer100,
                    proteinPer100: $0.proteinGPer100,
                    basisUnit: $0.basisUnit,
                    source: $0.source,
                    isFavorite: $0.isFavorite
                )
            }
            phase = .ready
        } catch {
            phase = .failed(NutritionLibraryFailure.explanation(for: error))
        }
    }

    /// Resolves a picked row into an editable portion.
    func draft(for id: UUID) -> NutritionPortionDraft? {
        guard let context, let food = try? NutritionRepository(context: context).food(id: id) else { return nil }
        return NutritionPortionDraft.make(from: food)
    }
}

// MARK: - Custom food editor

/// The warning shown when a food's stated energy and its macros disagree.
///
/// A warning, never a block: packets round their own numbers, fibre and polyols are counted
/// differently between jurisdictions, and refusing the user's own label would be the app claiming
/// to know their food better than the packet in their hand.
struct MacroConsistencyWarning: Hashable {
    var statedKilocalories: Double
    var impliedKilocalories: Double
}

@MainActor
@Observable
final class CustomFoodEditorViewModel {
    /// Tolerated disagreement between stated and implied energy before the warning appears.
    /// Twelve per cent is the bound the bundled food database is held to; below it the difference is
    /// label rounding rather than a typo.
    private static let energyTolerance: Double = 0.12
    /// …and never warn about a handful of kilocalories on a low-energy food, where the relative
    /// difference is large but the absolute one is meaningless.
    private static let energyToleranceFloor: Double = 15

    private(set) var phase: NutritionLibraryPhase = .loading
    private(set) var isExistingFood = false
    private(set) var saveFailure: Explanation?
    private(set) var isSaving = false

    var name: String = ""
    var brand: String = ""
    /// Set when the food came from a barcode the scanner could not find. Storing it means the next
    /// scan of the same packet resolves instantly instead of asking the user to type it all again.
    var barcode: String?
    var basisUnit: ServingUnit = .grams
    var kilocalories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var gramsPerPiece: Double?
    var micronutrients: Micronutrients = .unknown
    var servings: [NutritionServingDraft] = []
    var dietaryTags: Set<String> = []
    var allergenTags: Set<String> = []
    var roleTags: Set<String> = []

    private var context: ModelContext?
    private var foodID: UUID?

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    /// The energy the macros imply, using the 4/4/9 convention.
    var impliedKilocalories: Double {
        MacroNutrients(
            kilocalories: 0,
            proteinG: protein ?? 0,
            carbsG: carbs ?? 0,
            fatG: fat ?? 0
        ).derivedKilocalories
    }

    var consistencyWarning: MacroConsistencyWarning? {
        guard let stated = kilocalories, stated > 0 else { return nil }
        let implied = impliedKilocalories
        guard implied > 0 else { return nil }
        let difference = abs(implied - stated)
        guard difference >= Self.energyToleranceFloor,
              difference / stated > Self.energyTolerance else { return nil }
        return MacroConsistencyWarning(statedKilocalories: stated, impliedKilocalories: implied)
    }

    func load(context: ModelContext, foodID: UUID?) async {
        self.context = context
        self.foodID = foodID
        guard let foodID else {
            phase = .ready
            isExistingFood = false
            return
        }
        do {
            let repository = NutritionRepository(context: context)
            guard let food = try repository.food(id: foodID) else {
                phase = .failed(RepositoryError.notFound(entity: "foodItem").explanation)
                return
            }
            guard food.source.isUserEditable else {
                phase = .failed(RepositoryError.notEditable(entity: "foodItem").explanation)
                return
            }
            isExistingFood = true
            name = food.name
            brand = food.brand ?? ""
            barcode = food.barcode
            basisUnit = food.basisUnit
            kilocalories = food.kilocaloriesPer100
            protein = food.proteinGPer100
            carbs = food.carbsGPer100
            fat = food.fatGPer100
            gramsPerPiece = food.gramsPerPiece
            micronutrients = food.micronutrientsPer100
            servings = food.servings.map {
                NutritionServingDraft(name: $0.nameKey.map { key in L(key) } ?? $0.name, grams: $0.gramsPerServing)
            }
            dietaryTags = Set(food.dietaryTags)
            allergenTags = Set(food.allergenTags)
            roleTags = Set(food.roleTags)
            phase = .ready
        } catch {
            phase = .failed(NutritionLibraryFailure.explanation(for: error))
        }
    }

    /// Adopts the energy the macros imply. Offered next to the warning so the fix is one tap.
    func useImpliedEnergy() {
        let implied = impliedKilocalories
        guard implied > 0 else { return }
        kilocalories = implied.rounded()
    }

    func addServing() {
        servings.append(NutritionServingDraft(name: "", grams: 30))
    }

    func removeServings(at offsets: IndexSet) {
        servings.remove(atOffsets: offsets)
    }

    func toggle(_ tag: String, in keyPath: ReferenceWritableKeyPath<CustomFoodEditorViewModel, Set<String>>) {
        if self[keyPath: keyPath].contains(tag) {
            self[keyPath: keyPath].remove(tag)
        } else {
            self[keyPath: keyPath].insert(tag)
        }
    }

    /// Saves and returns the food's id, or `nil` when validation refused it.
    @discardableResult
    func save() async -> UUID? {
        guard let context else { return nil }
        isSaving = true
        saveFailure = nil
        defer { isSaving = false }

        // Named servings without a name are half-finished rows the user abandoned, not data.
        let cleanedServings = servings
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { FoodServing(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), gramsPerServing: $0.grams) }

        do {
            let repository = NutritionRepository(context: context)
            if let foodID, let food = try repository.food(id: foodID) {
                try repository.updateFood(
                    food,
                    name: name,
                    brand: .some(brand),
                    kilocaloriesPer100: kilocalories ?? 0,
                    proteinGPer100: protein ?? 0,
                    carbsGPer100: carbs ?? 0,
                    fatGPer100: fat ?? 0,
                    micronutrientsPer100: micronutrients,
                    servings: cleanedServings,
                    gramsPerPiece: .some(gramsPerPiece),
                    dietaryTags: Array(dietaryTags).sorted(),
                    allergenTags: Array(allergenTags).sorted(),
                    roleTags: Array(roleTags).sorted()
                )
                return food.id
            }
            let created = try repository.createCustomFood(
                name: name,
                brand: brand,
                barcode: barcode,
                kilocaloriesPer100: kilocalories ?? 0,
                proteinGPer100: protein ?? 0,
                carbsGPer100: carbs ?? 0,
                fatGPer100: fat ?? 0,
                micronutrientsPer100: micronutrients,
                basisUnit: basisUnit,
                servings: cleanedServings,
                gramsPerPiece: gramsPerPiece,
                dietaryTags: Array(dietaryTags).sorted(),
                allergenTags: Array(allergenTags).sorted(),
                roleTags: Array(roleTags).sorted()
            )
            foodID = created.id
            isExistingFood = true
            return created.id
        } catch {
            saveFailure = NutritionLibraryFailure.explanation(for: error)
            return nil
        }
    }

    /// What happened when the user asked to delete the food.
    ///
    /// `blocked` is not a failure: saved meals and recipes hold only a reference and a quantity, so
    /// deleting the food would leave them unable to compute their own nutrition. The repository
    /// reports that instead of doing it, and the caller asks a second question.
    enum DeleteOutcome: Hashable {
        case deleted
        case blocked(referenceCount: Int)
        case failed
    }

    /// Deletes the food. `force` is the answer to "it is still used by a meal or a recipe".
    func delete(force: Bool) async -> DeleteOutcome {
        guard let context, let foodID else { return .failed }
        do {
            let repository = NutritionRepository(context: context)
            guard let food = try repository.food(id: foodID) else { return .deleted }
            try repository.deleteFood(food, force: force)
            return .deleted
        } catch RepositoryError.stillReferenced(_, let referenceCount) {
            return .blocked(referenceCount: referenceCount)
        } catch {
            saveFailure = NutritionLibraryFailure.explanation(for: error)
            return .failed
        }
    }

    func clearFailure() { saveFailure = nil }
}

// MARK: - Saved meals

struct SavedMealSummary: Identifiable, Hashable {
    var id: UUID
    var name: String
    var slot: MealSlot
    var isFavorite: Bool
    var timesUsed: Int
    var itemNames: [String]
    var macros: MacroNutrients
    /// Items whose food has since been deleted. They cannot be logged, so the row says so.
    var unresolvedItemCount: Int
}

/// One meal on one day that is complete enough to be worth saving.
struct DayMealOption: Identifiable, Hashable {
    var id: String { slot.rawValue }
    var slot: MealSlot
    var entryCount: Int
    var macros: MacroNutrients
    var suggestedName: String
}

@MainActor
@Observable
final class SavedMealsViewModel {
    private(set) var phase: NutritionLibraryPhase = .loading
    private(set) var meals: [SavedMealSummary] = []
    private(set) var dayOptions: [DayMealOption] = []
    private(set) var actionFailure: Explanation?
    /// Set briefly after a successful log so the row can confirm what happened.
    private(set) var lastLoggedMealID: UUID?

    private var context: ModelContext?
    private let dayKey: String

    init(dayKey: String = DayKey.today) {
        self.dayKey = dayKey
    }

    func load(context: ModelContext) async {
        self.context = context
        do {
            let repository = NutritionRepository(context: context)
            let stored = try repository.savedMeals()
            meals = try stored.map { meal in
                let totals = try repository.nutrition(of: meal)
                let items = meal.items.sorted { $0.orderIndex < $1.orderIndex }
                return SavedMealSummary(
                    id: meal.id,
                    name: meal.name,
                    slot: meal.defaultSlot,
                    isFavorite: meal.isFavorite,
                    timesUsed: meal.timesUsed,
                    itemNames: items.map(\.foodNameSnapshot),
                    macros: totals.macros,
                    unresolvedItemCount: items.filter { $0.foodID == nil }.count
                )
            }
            dayOptions = try Self.mealOptions(on: dayKey, repository: repository)
            phase = .ready
        } catch {
            phase = .failed(NutritionLibraryFailure.explanation(for: error))
        }
    }

    /// The slots of `dayKey` that carry entries, offered as the seed for a new saved meal.
    @MainActor
    private static func mealOptions(on dayKey: String, repository: NutritionRepository) throws -> [DayMealOption] {
        let grouped = try repository.dayLogBySlot(for: dayKey)
        return MealSlot.allCases
            .sorted { $0.sortIndex < $1.sortIndex }
            .compactMap { slot in
                guard let entries = grouped[slot], !entries.isEmpty else { return nil }
                let macros = entries.reduce(MacroNutrients.zero) { $0 + $1.macrosSnapshot }
                return DayMealOption(
                    slot: slot,
                    entryCount: entries.count,
                    macros: macros,
                    suggestedName: L("nutritionLibrary.meals.defaultName", L(slot.localizationKey))
                )
            }
    }

    func logMeal(id: UUID, to slot: MealSlot) async {
        guard let context else { return }
        actionFailure = nil
        do {
            let repository = NutritionRepository(context: context)
            guard let meal = try savedMeal(id: id, repository: repository) else { return }
            let created = try repository.logSavedMeal(meal, to: slot, dayKey: dayKey)
            guard !created.isEmpty else {
                actionFailure = Explanation("nutritionLibrary.meals.nothingToLog")
                return
            }
            lastLoggedMealID = id
            Haptics.success()
            await load(context: context)
        } catch {
            actionFailure = NutritionLibraryFailure.explanation(for: error)
        }
    }

    func toggleFavorite(id: UUID) async {
        guard let context else { return }
        do {
            let repository = NutritionRepository(context: context)
            guard let meal = try savedMeal(id: id, repository: repository) else { return }
            try repository.updateSavedMeal(meal, isFavorite: !meal.isFavorite)
            await load(context: context)
        } catch {
            actionFailure = NutritionLibraryFailure.explanation(for: error)
        }
    }

    func delete(id: UUID) async {
        guard let context else { return }
        do {
            let repository = NutritionRepository(context: context)
            guard let meal = try savedMeal(id: id, repository: repository) else { return }
            try repository.deleteSavedMeal(meal)
            await load(context: context)
        } catch {
            actionFailure = NutritionLibraryFailure.explanation(for: error)
        }
    }

    /// Turns one of today's meals into a saved meal.
    func saveMealFromDay(_ option: DayMealOption, named name: String) async -> Bool {
        guard let context else { return false }
        actionFailure = nil
        do {
            let repository = NutritionRepository(context: context)
            _ = try repository.saveMeal(named: name, fromDayKey: dayKey, slot: option.slot)
            await load(context: context)
            return true
        } catch {
            actionFailure = NutritionLibraryFailure.explanation(for: error)
            return false
        }
    }

    func clearFailure() { actionFailure = nil }

    private func savedMeal(id: UUID, repository: NutritionRepository) throws -> SavedMeal? {
        try repository.savedMeals().first { $0.id == id }
    }
}

// MARK: - Saved meal editor

@MainActor
@Observable
final class SavedMealEditorViewModel {
    private(set) var phase: NutritionLibraryPhase = .loading
    private(set) var isExistingMeal = false
    private(set) var saveFailure: Explanation?
    /// Items whose food has since been deleted and could not be rebuilt into the draft.
    private(set) var droppedItemCount = 0

    var name: String = ""
    var slot: MealSlot = .breakfast
    var items: [NutritionPortionDraft] = []

    private var context: ModelContext?
    private var mealID: UUID?

    var totals: MacroNutrients { items.totalMacros }
    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !items.isEmpty
    }

    func load(context: ModelContext, mealID: UUID?, defaultSlot: MealSlot) async {
        self.context = context
        self.mealID = mealID
        guard let mealID else {
            slot = defaultSlot
            phase = .ready
            return
        }
        do {
            let repository = NutritionRepository(context: context)
            guard let meal = try repository.savedMeals().first(where: { $0.id == mealID }) else {
                phase = .failed(RepositoryError.notFound(entity: "savedMeal").explanation)
                return
            }
            isExistingMeal = true
            name = meal.name
            slot = meal.defaultSlot
            let foods = try repository.foods(ids: meal.items.compactMap(\.foodID))
            // An item whose food was deleted cannot be priced or logged, so it is dropped from the
            // draft rather than shown as a zero — and the editor says how many went.
            items = meal.items
                .sorted { $0.orderIndex < $1.orderIndex }
                .compactMap { item in
                    guard let foodID = item.foodID, let food = foods[foodID] else { return nil }
                    return NutritionPortionDraft.make(
                        from: food,
                        quantity: item.quantity,
                        unit: item.unit,
                        servingIndex: item.servingIndex
                    )
                }
            droppedItemCount = meal.items.count - items.count
            phase = .ready
        } catch {
            phase = .failed(NutritionLibraryFailure.explanation(for: error))
        }
    }

    func add(_ draft: NutritionPortionDraft) {
        items.append(draft)
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func save() async -> Bool {
        guard let context else { return false }
        saveFailure = nil
        do {
            let repository = NutritionRepository(context: context)
            if let mealID, let meal = try repository.savedMeals().first(where: { $0.id == mealID }) {
                try repository.updateSavedMeal(
                    meal, name: name, defaultSlot: slot, items: items.map(\.input)
                )
            } else {
                let created = try repository.createSavedMeal(
                    name: name, defaultSlot: slot, items: items.map(\.input)
                )
                mealID = created.id
                isExistingMeal = true
            }
            return true
        } catch {
            saveFailure = NutritionLibraryFailure.explanation(for: error)
            return false
        }
    }

    func clearFailure() { saveFailure = nil }
}

// MARK: - Recipes

struct RecipeSummary: Identifiable, Hashable {
    var id: UUID
    var name: String
    var servingsCount: Double
    var perServing: MacroNutrients
    var total: MacroNutrients
    var preparationMinutes: Int?
    var isFavorite: Bool
    var timesUsed: Int
    var ingredientCount: Int
    var unresolvedIngredientCount: Int
}

@MainActor
@Observable
final class RecipeListViewModel {
    private(set) var phase: NutritionLibraryPhase = .loading
    private(set) var recipes: [RecipeSummary] = []
    private(set) var actionFailure: Explanation?
    private(set) var lastLoggedRecipeID: UUID?

    private var context: ModelContext?
    private let dayKey: String

    init(dayKey: String = DayKey.today) {
        self.dayKey = dayKey
    }

    func load(context: ModelContext) async {
        self.context = context
        do {
            let repository = NutritionRepository(context: context)
            let stored = try repository.recipes()
            recipes = try stored.map { recipe in
                let nutrition = try repository.nutrition(of: recipe)
                return RecipeSummary(
                    id: recipe.id,
                    name: recipe.name,
                    servingsCount: nutrition.servingsCount,
                    perServing: nutrition.perServing.macros,
                    total: nutrition.total.macros,
                    preparationMinutes: recipe.preparationMinutes,
                    isFavorite: recipe.isFavorite,
                    timesUsed: recipe.timesUsed,
                    ingredientCount: recipe.ingredients.count,
                    unresolvedIngredientCount: recipe.ingredients.filter { $0.foodID == nil }.count
                )
            }
            phase = .ready
        } catch {
            phase = .failed(NutritionLibraryFailure.explanation(for: error))
        }
    }

    func log(id: UUID, servings: Double, to slot: MealSlot) async {
        guard let context else { return }
        actionFailure = nil
        do {
            let repository = NutritionRepository(context: context)
            guard let recipe = try repository.recipes().first(where: { $0.id == id }) else { return }
            _ = try repository.logRecipeServing(recipe, servings: servings, to: slot, dayKey: dayKey)
            lastLoggedRecipeID = id
            Haptics.success()
            await load(context: context)
        } catch {
            actionFailure = NutritionLibraryFailure.explanation(for: error)
        }
    }

    func toggleFavorite(id: UUID) async {
        guard let context else { return }
        do {
            let repository = NutritionRepository(context: context)
            guard let recipe = try repository.recipes().first(where: { $0.id == id }) else { return }
            try repository.updateRecipe(recipe, isFavorite: !recipe.isFavorite)
            await load(context: context)
        } catch {
            actionFailure = NutritionLibraryFailure.explanation(for: error)
        }
    }

    func delete(id: UUID) async {
        guard let context else { return }
        do {
            let repository = NutritionRepository(context: context)
            guard let recipe = try repository.recipes().first(where: { $0.id == id }) else { return }
            try repository.deleteRecipe(recipe)
            await load(context: context)
        } catch {
            actionFailure = NutritionLibraryFailure.explanation(for: error)
        }
    }

    func clearFailure() { actionFailure = nil }
}

@MainActor
@Observable
final class RecipeEditorViewModel {
    private(set) var phase: NutritionLibraryPhase = .loading
    private(set) var isExistingRecipe = false
    private(set) var saveFailure: Explanation?
    private(set) var droppedIngredientCount = 0

    var name: String = ""
    var servingsCount: Double? = 4
    var preparationMinutes: Int?
    var instructions: String = ""
    var ingredients: [NutritionPortionDraft] = []

    private var context: ModelContext?
    private var recipeID: UUID?

    var total: MacroNutrients { ingredients.totalMacros }

    /// Per-serving nutrition, computed rather than typed. The floor mirrors the repository's, so
    /// the number on screen is the number that will be stored.
    var perServing: MacroNutrients {
        total * (1 / max(0.25, servingsCount ?? 1))
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ingredients.isEmpty
    }

    func load(context: ModelContext, recipeID: UUID?) async {
        self.context = context
        self.recipeID = recipeID
        guard let recipeID else {
            phase = .ready
            return
        }
        do {
            let repository = NutritionRepository(context: context)
            guard let recipe = try repository.recipes().first(where: { $0.id == recipeID }) else {
                phase = .failed(RepositoryError.notFound(entity: "recipe").explanation)
                return
            }
            isExistingRecipe = true
            name = recipe.name
            servingsCount = recipe.servingsCount
            preparationMinutes = recipe.preparationMinutes
            instructions = recipe.instructions ?? ""
            let foods = try repository.foods(ids: recipe.ingredients.compactMap(\.foodID))
            ingredients = recipe.ingredients
                .sorted { $0.orderIndex < $1.orderIndex }
                .compactMap { ingredient in
                    guard let foodID = ingredient.foodID, let food = foods[foodID] else { return nil }
                    return NutritionPortionDraft.make(
                        from: food,
                        quantity: ingredient.quantity,
                        unit: ingredient.unit,
                        servingIndex: ingredient.servingIndex
                    )
                }
            droppedIngredientCount = recipe.ingredients.count - ingredients.count
            phase = .ready
        } catch {
            phase = .failed(NutritionLibraryFailure.explanation(for: error))
        }
    }

    func add(_ draft: NutritionPortionDraft) { ingredients.append(draft) }
    func remove(at offsets: IndexSet) { ingredients.remove(atOffsets: offsets) }
    func move(from source: IndexSet, to destination: Int) {
        ingredients.move(fromOffsets: source, toOffset: destination)
    }

    func save() async -> Bool {
        guard let context else { return false }
        saveFailure = nil
        do {
            let repository = NutritionRepository(context: context)
            if let recipeID, let recipe = try repository.recipes().first(where: { $0.id == recipeID }) {
                try repository.updateRecipe(
                    recipe,
                    name: name,
                    servingsCount: servingsCount ?? 1,
                    instructions: .some(instructions),
                    preparationMinutes: .some(preparationMinutes),
                    ingredients: ingredients.map(\.input)
                )
            } else {
                let created = try repository.createRecipe(
                    name: name,
                    servingsCount: servingsCount ?? 1,
                    ingredients: ingredients.map(\.input),
                    instructions: instructions,
                    preparationMinutes: preparationMinutes
                )
                recipeID = created.id
                isExistingRecipe = true
            }
            return true
        } catch {
            saveFailure = NutritionLibraryFailure.explanation(for: error)
            return false
        }
    }

    func clearFailure() { saveFailure = nil }
}

// MARK: - Meal recommendations

/// Everything the suggestions screen needs to explain *why* it is suggesting anything.
struct MealSuggestionContext: Hashable {
    var slot: MealSlot
    var remaining: MacroNutrients
    var dailyTarget: MacroNutrients?
    var consumed: MacroNutrients
    /// Share of the day's energy this slot usually carries, 0…1.
    var slotShare: Double
    /// Tags that disqualify a food outright: diet, allergens, intolerances and exclusions.
    var exclusions: [String]
    var candidateCount: Int
}

@MainActor
@Observable
final class MealRecommendationsViewModel {
    private(set) var phase: NutritionLibraryPhase = .loading
    private(set) var suggestions: [MealSuggestion] = []
    private(set) var plan: MealSuggestionContext?
    private(set) var actionFailure: Explanation?
    private(set) var lastLoggedSuggestionID: UUID?
    /// True when a target exists but the day is already full. Not an error — a real answer.
    private(set) var hasNoRoomLeft = false
    /// True when no daily target has ever been set, which is the one thing the user must fix first.
    private(set) var isMissingTarget = false

    var slot: MealSlot {
        didSet { if slot != oldValue { needsReload = true } }
    }

    private var needsReload = false
    private var modelContext: ModelContext?
    private let dayKey: String

    init(slot: MealSlot? = nil, dayKey: String = DayKey.today, now: Date = Date(), calendar: Calendar = .current) {
        self.slot = slot ?? Self.slot(at: now, calendar: calendar)
        self.dayKey = dayKey
    }

    /// The meal a person is most likely to be planning at this hour. Boundaries sit *after* the
    /// meal rather than before it: at 11:00 the useful suggestion is lunch, not another breakfast.
    static func slot(at date: Date, calendar: Calendar = .current) -> MealSlot {
        switch calendar.component(.hour, from: date) {
        case ..<11: return .breakfast
        case 11..<15: return .lunch
        case 15..<21: return .dinner
        default: return .snacks
        }
    }

    func reloadIfNeeded(context: ModelContext) async {
        guard needsReload else { return }
        needsReload = false
        await load(context: context)
    }

    func load(context: ModelContext) async {
        self.modelContext = context
        phase = .loading
        hasNoRoomLeft = false
        isMissingTarget = false
        do {
            let nutrition = NutritionRepository(context: context)
            let profileRepository = ProfileRepository(context: context)
            let profile = try profileRepository.nutritionProfileSnapshot()
            let progress = try nutrition.progress(for: dayKey)

            guard let target = progress.target else {
                isMissingTarget = true
                suggestions = []
                plan = nil
                phase = .ready
                return
            }

            let candidates = try nutrition.mealCandidateFoods()
            let request = MealRecommendationRequest(
                remaining: progress.remaining,
                slot: slot,
                profile: profile,
                candidates: candidates,
                recentlyLoggedIDs: try nutrition.recentlyLoggedFoodIDs(endingOn: dayKey),
                savedMeals: try nutrition.savedMealCandidates(),
                recipes: try nutrition.recipeCandidates(),
                limit: 6,
                dailyTarget: target
            )

            plan = MealSuggestionContext(
                slot: slot,
                remaining: progress.remaining,
                dailyTarget: target,
                consumed: progress.consumed,
                slotShare: profile.energyShare(of: slot),
                exclusions: profile.forbiddenFoodTags.sorted(),
                candidateCount: candidates.count
            )

            // Portion solving over a few hundred combinations is real work; it has no business on
            // the main actor while the user is looking at a spinner.
            let engine = MealRecommendationEngine()
            let results = await Task.detached(priority: .userInitiated) {
                engine.suggestions(for: request)
            }.value

            suggestions = results
            hasNoRoomLeft = results.isEmpty
                && progress.remaining.kilocalories < MealRecommendationEngine.Constants.minimumRemainingKilocalories
            phase = .ready
        } catch {
            phase = .failed(NutritionLibraryFailure.explanation(for: error))
        }
    }

    /// Logs a suggestion into the slot it was built for, in one tap.
    func log(_ suggestion: MealSuggestion) async {
        guard let modelContext else { return }
        actionFailure = nil
        do {
            let repository = NutritionRepository(context: modelContext)
            if let savedMealID = suggestion.savedMealID,
               let meal = try repository.savedMeals().first(where: { $0.id == savedMealID }) {
                _ = try repository.logSavedMeal(meal, to: slot, dayKey: dayKey)
            } else if let recipeID = suggestion.recipeID,
                      let recipe = try repository.recipes().first(where: { $0.id == recipeID }) {
                _ = try repository.logRecipeServing(recipe, servings: 1, to: slot, dayKey: dayKey)
            } else {
                var logged = 0
                for item in suggestion.items {
                    guard let foodID = item.foodID, let food = try repository.food(id: foodID) else { continue }
                    try repository.addLogEntry(
                        food: food,
                        quantity: item.quantity,
                        unit: item.unit,
                        slot: slot,
                        dayKey: dayKey
                    )
                    logged += 1
                }
                guard logged > 0 else {
                    actionFailure = Explanation("nutritionLibrary.suggest.nothingToLog")
                    return
                }
            }
            lastLoggedSuggestionID = suggestion.id
            Haptics.success()
            await load(context: modelContext)
        } catch {
            actionFailure = NutritionLibraryFailure.explanation(for: error)
        }
    }

    func clearFailure() { actionFailure = nil }
}

// MARK: - Targets

/// One row of the target change log.
struct TargetChangeRow: Identifiable, Hashable {
    var id: UUID
    var changedAt: Date
    var previous: MacroNutrients
    var updated: MacroNutrients
    var reason: Explanation
    var wasAutomatic: Bool
}

@MainActor
@Observable
final class NutritionTargetsViewModel {
    /// Days of diary looked at when judging whether the user actually followed the target.
    private static let adherenceWindowDays = 21
    /// A day counts as logged past this share of the target energy. A single apple is not a logged
    /// day, and counting it as one would let a fortnight of guesswork move somebody's calories.
    private static let minimumLoggedShare: Double = 0.5
    private static let dismissalDefaultsKey = "nutrition.library.dismissedAdjustment"

    private(set) var phase: NutritionLibraryPhase = .loading
    private(set) var automatic: EnergyTargets = EnergyTargets()
    private(set) var current: EnergyTargets = EnergyTargets()
    private(set) var hasStoredTarget = false
    private(set) var isManualOverride = false
    private(set) var proposal: CalorieAdjustmentDecision?
    private(set) var trend: WeightTrendAnalysis = .empty
    private(set) var history: [TargetChangeRow] = []
    private(set) var safeMinimumKilocalories: Double = 0
    private(set) var actionFailure: Explanation?

    /// Draft values for the manual override sheet.
    var draftKilocalories: Double?
    var draftProtein: Double?
    var draftCarbs: Double?
    var draftFat: Double?

    private var modelContext: ModelContext?

    /// Signed daily offset against maintenance: the deficit or surplus, in kcal.
    var energyOffset: Double {
        current.kilocalories - current.totalDailyEnergyExpenditure
    }

    /// Energy the drafted macros imply. Shown next to the drafted calorie figure so a manual
    /// override that does not add up is visible before it is saved.
    var draftImpliedKilocalories: Double {
        MacroNutrients(
            kilocalories: 0,
            proteinG: draftProtein ?? 0,
            carbsG: draftCarbs ?? 0,
            fatG: draftFat ?? 0
        ).derivedKilocalories
    }

    var isDraftBelowSafeMinimum: Bool {
        guard let kilocalories = draftKilocalories else { return false }
        return kilocalories < safeMinimumKilocalories
    }

    /// A proposal the user has already waved away is not shown again until it changes.
    var visibleProposal: CalorieAdjustmentDecision? {
        guard let proposal, proposal.newTargets != nil else { return nil }
        let dismissed = UserDefaults.standard.string(forKey: Self.dismissalDefaultsKey)
        return dismissed == Self.signature(of: proposal) ? nil : proposal
    }

    func load(context: ModelContext) async {
        self.modelContext = context
        do {
            let nutrition = NutritionRepository(context: context)
            let profileRepository = ProfileRepository(context: context)
            let progressRepository = ProgressRepository(context: context)

            let profile = try profileRepository.nutritionProfileSnapshot()
            automatic = NutritionRecommendationEngine.targets(for: profile)
            safeMinimumKilocalories = NutritionRecommendationEngine.safeMinimumKilocalories(for: profile)

            let stored = try nutrition.activeTarget()
            hasStoredTarget = stored != nil
            isManualOverride = stored?.isManualOverride ?? false
            current = Self.targets(merging: stored, into: automatic)
            seedDraft()

            trend = WeightTrendAnalyzer.analyze(entries: try progressRepository.weightTrendPoints())

            let changes = try nutrition.targetHistory(limit: 20)
            history = changes.map {
                TargetChangeRow(
                    id: $0.id,
                    changedAt: $0.changedAt,
                    previous: MacroNutrients(
                        kilocalories: $0.previousKilocalories,
                        proteinG: $0.previousProteinG,
                        carbsG: $0.previousCarbsG,
                        fatG: $0.previousFatG
                    ),
                    updated: MacroNutrients(
                        kilocalories: $0.newKilocalories,
                        proteinG: $0.newProteinG,
                        carbsG: $0.newCarbsG,
                        fatG: $0.newFatG
                    ),
                    reason: Explanation($0.reasonKey, $0.reasonArguments),
                    wasAutomatic: $0.wasAutomatic
                )
            }

            if let stored {
                let lastChange = changes.first?.changedAt ?? stored.effectiveFrom
                let days = Calendar.current.dateComponents([.day], from: lastChange, to: Date()).day ?? 0
                proposal = NutritionAdjustmentEngine.evaluate(
                    current: current,
                    trend: trend,
                    profile: profile,
                    adherence: try adherence(target: stored.kilocalories, repository: nutrition),
                    daysSinceLastAdjustment: max(0, days)
                )
            } else {
                proposal = nil
            }
            phase = .ready
        } catch {
            phase = .failed(NutritionLibraryFailure.explanation(for: error))
        }
    }

    /// Rebuilds the drafted override from whatever is currently in force.
    func seedDraft() {
        draftKilocalories = current.kilocalories
        draftProtein = current.proteinG
        draftCarbs = current.carbsG
        draftFat = current.fatG
    }

    /// Writes the drafted numbers as a manual override.
    func saveManualOverride() async -> Bool {
        await apply(
            macros: MacroNutrients(
                kilocalories: draftKilocalories ?? current.kilocalories,
                proteinG: draftProtein ?? current.proteinG,
                carbsG: draftCarbs ?? current.carbsG,
                fatG: draftFat ?? current.fatG
            ),
            isManualOverride: true,
            rationale: Explanation("nutritionLibrary.targets.reason.manual"),
            reason: Explanation("nutritionLibrary.targets.reason.manual"),
            wasAutomatic: false
        )
    }

    /// Throws away the override and goes back to the engine's own figures.
    func resetToAutomatic() async -> Bool {
        await apply(
            macros: automatic.macros,
            isManualOverride: false,
            rationale: automatic.explanations.first,
            reason: Explanation("nutritionLibrary.targets.reason.reset"),
            wasAutomatic: false
        )
    }

    /// Accepts the adjustment engine's proposal. Never called on the engine's behalf — only from a
    /// button the user pressed.
    func acceptProposal() async -> Bool {
        guard let proposal, let proposed = proposal.newTargets else { return false }
        let applied = await apply(
            macros: proposed.macros,
            isManualOverride: false,
            rationale: proposal.explanation,
            reason: proposal.explanation,
            wasAutomatic: true,
            trendWeightKg: trend.currentTrendKg
        )
        if applied { UserDefaults.standard.removeObject(forKey: Self.dismissalDefaultsKey) }
        return applied
    }

    /// "Not now". Remembered against the proposal's own shape, so the same suggestion does not
    /// reappear on every visit but a genuinely new one still does.
    func dismissProposal() {
        guard let proposal else { return }
        UserDefaults.standard.set(Self.signature(of: proposal), forKey: Self.dismissalDefaultsKey)
    }

    func clearFailure() { actionFailure = nil }

    // MARK: Private

    @discardableResult
    private func apply(
        macros: MacroNutrients,
        isManualOverride: Bool,
        rationale: Explanation?,
        reason: Explanation,
        wasAutomatic: Bool,
        trendWeightKg: Double? = nil
    ) async -> Bool {
        guard let modelContext else { return false }
        actionFailure = nil
        do {
            let repository = NutritionRepository(context: modelContext)
            _ = try repository.replaceActiveTarget(
                kilocalories: macros.kilocalories,
                proteinG: macros.proteinG,
                carbsG: macros.carbsG,
                fatG: macros.fatG,
                isManualOverride: isManualOverride,
                rationale: rationale,
                reason: reason,
                wasAutomatic: wasAutomatic,
                trendWeightKg: trendWeightKg
            )
            Haptics.success()
            await load(context: modelContext)
            return true
        } catch {
            actionFailure = NutritionLibraryFailure.explanation(for: error)
            return false
        }
    }

    /// Overlays the stored numbers onto the engine's estimate.
    ///
    /// The estimate supplies resting energy, maintenance and the intended direction — facts about
    /// the body, not about the plan — while the stored row supplies the numbers actually in force.
    /// The implied rate of change is recomputed so it always describes the target the user has,
    /// which is what `NutritionAdjustmentEngine` compares the scale against.
    private static func targets(merging stored: DailyNutritionTarget?, into automatic: EnergyTargets) -> EnergyTargets {
        guard let stored else { return automatic }
        var merged = automatic
        merged.kilocalories = stored.kilocalories
        merged.proteinG = stored.proteinG
        merged.carbsG = stored.carbsG
        merged.fatG = stored.fatG
        let offset = stored.kilocalories - automatic.totalDailyEnergyExpenditure
        merged.weeklyBodyMassChangeKg =
            (offset * 7 / NutritionRecommendationEngine.Constants.energyPerKilogramBodyMass * 100).rounded() / 100
        return merged
    }

    /// Share of the trailing window on which the user logged something like a full day of food.
    private func adherence(target: Double, repository: NutritionRepository) throws -> Double? {
        guard target > 0 else { return nil }
        var logged = 0
        for offset in 0..<Self.adherenceWindowDays {
            let key = DayKey.offset(from: DayKey.today, days: -offset)
            let energy = try repository.dayLog(for: key).reduce(0) { $0 + $1.macrosSnapshot.kilocalories }
            if energy >= target * Self.minimumLoggedShare { logged += 1 }
        }
        return Double(logged) / Double(Self.adherenceWindowDays)
    }

    /// Identity of a proposal, so a dismissal survives a reload but not a change of mind.
    private static func signature(of decision: CalorieAdjustmentDecision) -> String {
        "\(decision.action.rawValue):\(Int(decision.deltaKilocalories.rounded()))"
            + ":\(Int((decision.newTargets?.kilocalories ?? 0).rounded()))"
    }
}

// MARK: - Micronutrients

/// Vitamins, minerals and everything else, in the order the screen renders them.
struct MicronutrientGroup: Identifiable, Hashable {
    var id: String
    var titleKey: String
    var statuses: [MicronutrientStatus]
}

@MainActor
@Observable
final class MicronutrientDetailViewModel {
    private(set) var phase: NutritionLibraryPhase = .loading
    private(set) var groups: [MicronutrientGroup] = []
    private(set) var entryCount = 0
    /// Nutrients the day's foods carry no data for at all. Shown as a count, never as a shortfall.
    private(set) var unknownCount = 0
    private(set) var hasExplicitGoals = false

    var dayKey: String

    private var modelContext: ModelContext?

    init(dayKey: String = DayKey.today) {
        self.dayKey = dayKey
    }

    var canStepForward: Bool { dayKey < DayKey.today }
    var date: Date { DayKey.date(from: dayKey) ?? Date() }

    func step(days: Int) async {
        let candidate = DayKey.offset(from: dayKey, days: days)
        guard candidate <= DayKey.today else { return }
        dayKey = candidate
        guard let modelContext else { return }
        await load(context: modelContext)
    }

    func load(context: ModelContext) async {
        self.modelContext = context
        do {
            let repository = NutritionRepository(context: context)
            let totals = try repository.totals(for: dayKey)
            let goals = try repository.activeTarget()?.micronutrientGoals ?? .unknown
            hasExplicitGoals = Micronutrient.allCases.contains { (goals[$0] ?? 0) > 0 }
            entryCount = totals.entryCount

            let statuses = NutritionRecommendationEngine.micronutrientStatus(
                consumed: totals.micronutrients, goals: goals
            )
            let byNutrient = Dictionary(uniqueKeysWithValues: statuses.map { ($0.nutrient, $0) })
            groups = [
                MicronutrientGroup(
                    id: "vitamins",
                    titleKey: "nutritionLibrary.micros.vitamins",
                    statuses: Micronutrient.vitamins.compactMap { byNutrient[$0] }
                ),
                MicronutrientGroup(
                    id: "minerals",
                    titleKey: "nutritionLibrary.micros.minerals",
                    statuses: Micronutrient.minerals.compactMap { byNutrient[$0] }
                ),
                MicronutrientGroup(
                    id: "other",
                    titleKey: "nutritionLibrary.micros.other",
                    statuses: Micronutrient.otherNutrients.compactMap { byNutrient[$0] }
                ),
            ]
            unknownCount = statuses.filter(\.isUnknown).count
            phase = .ready
        } catch {
            phase = .failed(NutritionLibraryFailure.explanation(for: error))
        }
    }
}
