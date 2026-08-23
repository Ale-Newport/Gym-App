import Foundation
import SwiftData

// MARK: - Value types

/// Macro and micronutrient totals for an arbitrary collection of portions.
struct NutritionTotals: Hashable, Sendable {
    var macros: MacroNutrients = .zero
    var micronutrients: Micronutrients = .unknown

    static let zero = NutritionTotals()

    func scaled(by factor: Double) -> NutritionTotals {
        NutritionTotals(macros: macros * factor, micronutrients: micronutrients.scaled(by: factor))
    }

    static func + (lhs: NutritionTotals, rhs: NutritionTotals) -> NutritionTotals {
        NutritionTotals(
            macros: lhs.macros + rhs.macros,
            micronutrients: lhs.micronutrients + rhs.micronutrients
        )
    }
}

/// One portion of one food, as the caller describes it before it becomes a stored row.
struct NutritionPortionInput: Hashable, Sendable {
    var foodID: UUID
    var quantity: Double
    var unit: ServingUnit
    var servingIndex: Int?

    init(foodID: UUID, quantity: Double, unit: ServingUnit = .grams, servingIndex: Int? = nil) {
        self.foodID = foodID
        self.quantity = quantity
        self.unit = unit
        self.servingIndex = servingIndex
    }
}

/// Everything eaten and drunk on one day.
struct DailyNutritionTotals: Hashable, Sendable {
    var dayKey: String
    var totals: NutritionTotals = .zero
    /// Macros per meal slot, for the day's breakdown ring.
    var macrosBySlot: [MealSlot: MacroNutrients] = [:]
    var entryCount: Int = 0
    var waterMilliliters: Double = 0

    var macros: MacroNutrients { totals.macros }
    var micronutrients: Micronutrients { totals.micronutrients }
}

/// A day measured against the active target.
struct DailyNutritionProgress: Hashable, Sendable {
    var dayKey: String
    /// `nil` before a target has ever been set.
    var target: MacroNutrients?
    var consumed: MacroNutrients
    /// Target minus consumed. Negative components mean the user is over on that macro; they are not
    /// clamped, because "212 g of carbs left" and "−40 g of carbs" are both information the user
    /// asked for.
    var remaining: MacroNutrients
    /// Consumed energy as a fraction of the target. `0` when no target exists.
    var energyProgress: Double
    var waterMilliliters: Double
}

/// Total and per-serving nutrition for a recipe.
struct RecipeNutrition: Hashable, Sendable {
    var servingsCount: Double
    var total: NutritionTotals
    var perServing: NutritionTotals
}

// MARK: - Repository

/// Owns food, food logging, saved meals, recipes, energy targets and water.
///
/// The governing rule of this file is that **a log entry is history, not a pointer.** Every entry
/// stores the food's name and its complete macro and micronutrient contribution at the moment it was
/// logged. Editing a food's nutrition tomorrow, or deleting it outright, therefore cannot rewrite
/// what a user ate last month — which is exactly what a food diary is for. The cost is a little
/// duplicated data per row; the alternative is a diary whose past silently changes, which is worse
/// than useless.
///
/// Days are addressed by `DayKey` (`yyyy-MM-dd` in the user's calendar) rather than by date range,
/// so a day's log is one indexed equality fetch and a flight across time zones does not move
/// yesterday's dinner into today.
@MainActor
struct NutritionRepository: Repository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Food: reading

    func food(id: UUID) throws -> FoodItem? {
        try fetchFirst(FetchDescriptor<FoodItem>(predicate: #Predicate { $0.id == id }))
    }

    /// Foods by id, in one fetch. Used everywhere a saved meal or a recipe has to be priced out.
    func foods(ids: [UUID]) throws -> [UUID: FoodItem] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        let rows = try fetch(FetchDescriptor<FoodItem>(predicate: #Predicate { unique.contains($0.id) }))
        return Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
    }

    /// Name and brand search, most-logged first so the foods a user actually eats surface first.
    func searchFoods(_ query: String, limit: Int = 60) throws -> [FoodItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var descriptor = FetchDescriptor<FoodItem>(
            sortBy: [SortDescriptor(\.timesLogged, order: .reverse), SortDescriptor(\.name, order: .forward)]
        )
        if !trimmed.isEmpty {
            descriptor.predicate = #Predicate { food in
                food.name.localizedStandardContains(trimmed)
                    || (food.brand ?? "").localizedStandardContains(trimmed)
            }
        }
        descriptor.fetchLimit = max(0, limit)
        return try fetch(descriptor)
    }

    /// Exact barcode lookup, for the scanner.
    func food(barcode: String) throws -> FoodItem? {
        let trimmed = barcode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return try fetchFirst(FetchDescriptor<FoodItem>(predicate: #Predicate { $0.barcode == trimmed }))
    }

    /// Foods logged most recently, newest first.
    func recentFoods(limit: Int = 30) throws -> [FoodItem] {
        var descriptor = FetchDescriptor<FoodItem>(
            predicate: #Predicate { $0.lastLoggedAt != nil },
            sortBy: [SortDescriptor(\.lastLoggedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try fetch(descriptor)
    }

    func favoriteFoods() throws -> [FoodItem] {
        try fetch(FetchDescriptor<FoodItem>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.name, order: .forward)]
        ))
    }

    func setFoodFavorite(_ isFavorite: Bool, on food: FoodItem, now: Date = Date()) throws {
        food.isFavorite = isFavorite
        food.updatedAt = now
        try persist()
    }

    // MARK: - Food: writing

    /// Creates a food the user typed in themselves.
    ///
    /// Values are given per 100 g (or per 100 ml), which is the basis the whole app stores and the
    /// basis every packaged food in the EU is already labelled in. Energy is derived from the macros
    /// when the user leaves it blank — a 4/4/9 derivation is a better answer than zero.
    @discardableResult
    func createCustomFood(
        name: String,
        brand: String? = nil,
        barcode: String? = nil,
        kilocaloriesPer100: Double,
        proteinGPer100: Double,
        carbsGPer100: Double,
        fatGPer100: Double,
        micronutrientsPer100: Micronutrients = .unknown,
        basisUnit: ServingUnit = .grams,
        servings: [FoodServing] = [],
        gramsPerPiece: Double? = nil,
        dietaryTags: [String] = [],
        allergenTags: [String] = [],
        roleTags: [String] = [],
        costPer100: Double? = nil,
        now: Date = Date()
    ) throws -> FoodItem {
        let food = FoodItem()
        food.name = try InputValidation.name(name, field: "foodName")
        food.brand = InputValidation.sanitisedNote(brand)
        food.barcode = barcode?.trimmingCharacters(in: .whitespaces).nilWhenEmpty
        food.source = .custom
        food.basisUnit = basisUnit == .milliliters ? .milliliters : .grams

        let macros = try Self.validatedPer100(
            kilocalories: kilocaloriesPer100,
            proteinG: proteinGPer100,
            carbsG: carbsGPer100,
            fatG: fatGPer100
        )
        food.kilocaloriesPer100 = macros.kilocalories
        food.proteinGPer100 = macros.proteinG
        food.carbsGPer100 = macros.carbsG
        food.fatGPer100 = macros.fatG
        food.micronutrientsPer100 = micronutrientsPer100
        food.servings = try Self.validatedServings(servings)
        food.gramsPerPiece = try gramsPerPiece.map { try InputValidation.grams($0, field: "gramsPerPiece") }
        food.dietaryTags = InputValidation.normalisedTags(dietaryTags)
        food.allergenTags = InputValidation.normalisedTags(allergenTags)
        food.roleTags = InputValidation.normalisedTags(roleTags)
        food.costPer100 = costPer100.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        food.createdAt = now
        food.updatedAt = now
        context.insert(food)
        try persist()
        return food
    }

    /// Edits a food. Only user-created foods and recipe-backed foods may be changed: a built-in or
    /// imported record is reference data, and letting the user edit it in place would make a later
    /// database refresh either destroy their edit or silently keep a wrong value.
    func updateFood(
        _ food: FoodItem,
        name: String? = nil,
        brand: String?? = nil,
        kilocaloriesPer100: Double? = nil,
        proteinGPer100: Double? = nil,
        carbsGPer100: Double? = nil,
        fatGPer100: Double? = nil,
        micronutrientsPer100: Micronutrients? = nil,
        servings: [FoodServing]? = nil,
        gramsPerPiece: Double?? = nil,
        dietaryTags: [String]? = nil,
        allergenTags: [String]? = nil,
        roleTags: [String]? = nil,
        costPer100: Double?? = nil,
        now: Date = Date()
    ) throws {
        guard food.source.isUserEditable else {
            throw RepositoryError.notEditable(entity: "foodItem")
        }
        if let name { food.name = try InputValidation.name(name, field: "foodName") }
        if let brand { food.brand = InputValidation.sanitisedNote(brand) }

        if kilocaloriesPer100 != nil || proteinGPer100 != nil || carbsGPer100 != nil || fatGPer100 != nil {
            let macros = try Self.validatedPer100(
                kilocalories: kilocaloriesPer100 ?? food.kilocaloriesPer100,
                proteinG: proteinGPer100 ?? food.proteinGPer100,
                carbsG: carbsGPer100 ?? food.carbsGPer100,
                fatG: fatGPer100 ?? food.fatGPer100
            )
            food.kilocaloriesPer100 = macros.kilocalories
            food.proteinGPer100 = macros.proteinG
            food.carbsGPer100 = macros.carbsG
            food.fatGPer100 = macros.fatG
        }
        if let micronutrientsPer100 { food.micronutrientsPer100 = micronutrientsPer100 }
        if let servings { food.servings = try Self.validatedServings(servings) }
        if let gramsPerPiece {
            food.gramsPerPiece = try gramsPerPiece.map { try InputValidation.grams($0, field: "gramsPerPiece") }
        }
        if let dietaryTags { food.dietaryTags = InputValidation.normalisedTags(dietaryTags) }
        if let allergenTags { food.allergenTags = InputValidation.normalisedTags(allergenTags) }
        if let roleTags { food.roleTags = InputValidation.normalisedTags(roleTags) }
        if let costPer100 { food.costPer100 = costPer100.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        food.updatedAt = now
        try persist()
    }

    /// Deletes a food without corrupting anything that referred to it.
    ///
    /// Log entries already carry their own name and nutrition snapshot, so the only thing they lose
    /// is the ability to jump to the food's detail screen; their `foodID` is cleared so nothing
    /// dereferences a row that no longer exists. Saved meals and recipes are different: they store
    /// only a reference and a quantity, so deleting a food would leave them unable to compute their
    /// own nutrition. Those are reported to the caller instead, and only removed on an explicit
    /// second confirmation.
    func deleteFood(_ food: FoodItem, force: Bool = false) throws {
        let target: UUID? = food.id

        let mealItems = try fetch(FetchDescriptor<SavedMealItem>(predicate: #Predicate { $0.foodID == target }))
        let ingredients = try fetch(FetchDescriptor<RecipeIngredient>(predicate: #Predicate { $0.foodID == target }))
        let referenceCount = mealItems.count + ingredients.count
        guard force || referenceCount == 0 else {
            throw RepositoryError.stillReferenced(entity: "foodItem", referenceCount: referenceCount)
        }

        let entries = try fetch(FetchDescriptor<FoodLogEntry>(predicate: #Predicate { $0.foodID == target }))
        for entry in entries { entry.foodID = nil }
        for item in mealItems { item.foodID = nil }
        for ingredient in ingredients { ingredient.foodID = nil }

        context.delete(food)
        try persist()
    }

    // MARK: - Logging

    /// Logs a portion of a food, computing and storing the full nutrition snapshot.
    @discardableResult
    func addLogEntry(
        food: FoodItem,
        quantity: Double,
        unit: ServingUnit = .grams,
        servingIndex: Int? = nil,
        slot: MealSlot,
        dayKey: String = DayKey.today,
        now: Date = Date()
    ) throws -> FoodLogEntry {
        let amount = try InputValidation.portion(quantity: quantity)
        let entry = FoodLogEntry()
        entry.dayKey = dayKey
        entry.loggedAt = now
        entry.mealSlot = slot
        entry.orderIndex = try nextOrderIndex(dayKey: dayKey, slot: slot)
        entry.foodID = food.id
        entry.foodNameSnapshot = food.name
        entry.brandSnapshot = food.brand
        entry.quantity = amount
        entry.unit = unit
        entry.servingIndex = servingIndex
        entry.macrosSnapshot = food.macros(forQuantity: amount, unit: unit, servingIndex: servingIndex)
        entry.micronutrientsSnapshot = food.micronutrients(forQuantity: amount, unit: unit, servingIndex: servingIndex)
        context.insert(entry)

        food.timesLogged += 1
        food.lastLoggedAt = now
        try persist()
        return entry
    }

    /// Every entry for a day, ordered by slot and then by the user's own ordering.
    func dayLog(for dayKey: String) throws -> [FoodLogEntry] {
        let entries = try fetch(FetchDescriptor<FoodLogEntry>(predicate: #Predicate { $0.dayKey == dayKey }))
        return entries.sorted { lhs, rhs in
            if lhs.mealSlot != rhs.mealSlot { return lhs.mealSlot.sortIndex < rhs.mealSlot.sortIndex }
            if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
            return lhs.loggedAt < rhs.loggedAt
        }
    }

    /// A day's entries grouped by meal slot. Every slot is present, so the UI renders empty meals
    /// without having to know which slots exist.
    func dayLogBySlot(for dayKey: String) throws -> [MealSlot: [FoodLogEntry]] {
        var grouped: [MealSlot: [FoodLogEntry]] = [:]
        for slot in MealSlot.allCases { grouped[slot] = [] }
        for entry in try dayLog(for: dayKey) { grouped[entry.mealSlot, default: []].append(entry) }
        return grouped
    }

    /// Changes the portion size of an existing entry and recomputes its snapshot.
    ///
    /// When the underlying food still exists the snapshot is recomputed from it, which is exact.
    /// When it has been deleted the existing snapshot is rescaled by the ratio of the two amounts —
    /// correct as long as the unit is unchanged, and refused when it is not, because there is no
    /// longer anything that knows how many grams are in "one piece".
    func updatePortion(
        of entry: FoodLogEntry,
        quantity: Double,
        unit: ServingUnit? = nil,
        servingIndex: Int?? = nil
    ) throws {
        let amount = try InputValidation.portion(quantity: quantity)
        let newUnit = unit ?? entry.unit
        let newServingIndex = servingIndex ?? entry.servingIndex

        if let foodID = entry.foodID, let food = try food(id: foodID) {
            entry.macrosSnapshot = food.macros(forQuantity: amount, unit: newUnit, servingIndex: newServingIndex)
            entry.micronutrientsSnapshot = food.micronutrients(
                forQuantity: amount, unit: newUnit, servingIndex: newServingIndex
            )
        } else {
            guard newUnit == entry.unit, newServingIndex == entry.servingIndex, entry.quantity > 0 else {
                throw RepositoryError.notFound(entity: "foodItem")
            }
            let factor = amount / entry.quantity
            entry.macrosSnapshot = entry.macrosSnapshot * factor
            entry.micronutrientsSnapshot = entry.micronutrientsSnapshot.scaled(by: factor)
        }

        entry.quantity = amount
        entry.unit = newUnit
        entry.servingIndex = newServingIndex
        try persist()
    }

    /// Moves an entry to another meal slot, appending it at the end of that slot.
    func move(_ entry: FoodLogEntry, to slot: MealSlot) throws {
        guard entry.mealSlot != slot else { return }
        entry.mealSlot = slot
        entry.orderIndex = try nextOrderIndex(dayKey: entry.dayKey, slot: slot)
        try persist()
    }

    /// Moves an entry to another day, keeping its snapshot untouched.
    func move(_ entry: FoodLogEntry, toDayKey dayKey: String, slot: MealSlot? = nil) throws {
        let targetSlot = slot ?? entry.mealSlot
        entry.dayKey = dayKey
        entry.mealSlot = targetSlot
        entry.orderIndex = try nextOrderIndex(dayKey: dayKey, slot: targetSlot)
        try persist()
    }

    func delete(_ entry: FoodLogEntry) throws {
        context.delete(entry)
        try persist()
    }

    /// Reorders the entries of one slot on one day.
    func reorderEntries(dayKey: String, slot: MealSlot, orderedIDs: [UUID]) throws {
        let entries = try dayLog(for: dayKey).filter { $0.mealSlot == slot }
        let ordered = RepositoryOrdering.sorted(
            entries, matching: orderedIDs, id: \.id, currentIndex: \.orderIndex
        )
        for (index, entry) in ordered.enumerated() { entry.orderIndex = index }
        try persist()
    }

    // MARK: - Copying

    /// Copies entries from one day to another. Passing `slots` limits the copy to those meals.
    ///
    /// The stored snapshots are copied verbatim rather than recomputed. That keeps the copy honest
    /// even if the food has been edited since, and it makes the operation independent of whether the
    /// original food still exists.
    @discardableResult
    func copyDay(
        from sourceDayKey: String,
        to targetDayKey: String,
        slots: Set<MealSlot>? = nil,
        now: Date = Date()
    ) throws -> [FoodLogEntry] {
        let source = try dayLog(for: sourceDayKey).filter { slots?.contains($0.mealSlot) ?? true }
        guard !source.isEmpty else { return [] }

        var nextIndex: [MealSlot: Int] = [:]
        for slot in Set(source.map(\.mealSlot)) {
            nextIndex[slot] = try nextOrderIndex(dayKey: targetDayKey, slot: slot)
        }

        var created: [FoodLogEntry] = []
        for entry in source {
            let copy = duplicate(entry, toDayKey: targetDayKey, slot: entry.mealSlot, now: now)
            copy.orderIndex = nextIndex[entry.mealSlot, default: 0]
            nextIndex[entry.mealSlot, default: 0] += 1
            created.append(copy)
        }
        try persist()
        return created
    }

    /// Copies one meal from the day before `dayKey` — the "same as yesterday" button.
    @discardableResult
    func copyYesterdayMeal(
        _ slot: MealSlot,
        to dayKey: String = DayKey.today,
        calendar: Calendar = .current,
        now: Date = Date()
    ) throws -> [FoodLogEntry] {
        let yesterday = DayKey.offset(from: dayKey, days: -1, calendar: calendar)
        return try copyDay(from: yesterday, to: dayKey, slots: [slot], now: now)
    }

    // MARK: - Saved meals

    /// Saved meals, favourites first and then by how often they are used.
    ///
    /// The favourite flag is applied in memory because `SortDescriptor` needs a `Comparable` key and
    /// `Bool` is not one; the store still does the useful part of the ordering.
    func savedMeals() throws -> [SavedMeal] {
        let meals = try fetch(FetchDescriptor<SavedMeal>(
            sortBy: [SortDescriptor(\.timesUsed, order: .reverse),
                     SortDescriptor(\.name, order: .forward)]
        ))
        return meals.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isFavorite != rhs.element.isFavorite { return lhs.element.isFavorite }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Turns what the user already logged into a reusable meal.
    ///
    /// Built from the entries rather than from a food picker because that is how people actually
    /// discover they have a "usual breakfast" — after eating it, not before.
    @discardableResult
    func saveMeal(
        named name: String,
        fromDayKey dayKey: String,
        slot: MealSlot,
        now: Date = Date()
    ) throws -> SavedMeal {
        let entries = try dayLog(for: dayKey).filter { $0.mealSlot == slot }
        _ = try InputValidation.requireNonEmpty(entries, field: "mealEntries")

        let meal = SavedMeal()
        meal.name = try InputValidation.name(name, field: "mealName")
        meal.defaultSlot = slot
        meal.createdAt = now
        context.insert(meal)

        for (index, entry) in entries.enumerated() {
            let item = SavedMealItem()
            item.foodID = entry.foodID
            item.foodNameSnapshot = entry.foodNameSnapshot
            item.quantity = entry.quantity
            item.unit = entry.unit
            item.servingIndex = entry.servingIndex
            item.orderIndex = index
            context.insert(item)
            item.meal = meal
        }
        try persist()
        return meal
    }

    /// Creates a saved meal from an explicit list of portions.
    @discardableResult
    func createSavedMeal(
        name: String,
        defaultSlot: MealSlot,
        items: [NutritionPortionInput],
        now: Date = Date()
    ) throws -> SavedMeal {
        _ = try InputValidation.requireNonEmpty(items, field: "mealItems")
        let foods = try foods(ids: items.map(\.foodID))

        let meal = SavedMeal()
        meal.name = try InputValidation.name(name, field: "mealName")
        meal.defaultSlot = defaultSlot
        meal.createdAt = now
        context.insert(meal)

        for (index, input) in items.enumerated() {
            guard let food = foods[input.foodID] else { throw RepositoryError.notFound(entity: "foodItem") }
            let item = SavedMealItem()
            item.foodID = food.id
            item.foodNameSnapshot = food.name
            item.quantity = try InputValidation.portion(quantity: input.quantity)
            item.unit = input.unit
            item.servingIndex = input.servingIndex
            item.orderIndex = index
            context.insert(item)
            item.meal = meal
        }
        try persist()
        return meal
    }

    func updateSavedMeal(
        _ meal: SavedMeal,
        name: String? = nil,
        defaultSlot: MealSlot? = nil,
        isFavorite: Bool? = nil,
        items: [NutritionPortionInput]? = nil
    ) throws {
        if let name { meal.name = try InputValidation.name(name, field: "mealName") }
        if let defaultSlot { meal.defaultSlot = defaultSlot }
        if let isFavorite { meal.isFavorite = isFavorite }
        if let items {
            _ = try InputValidation.requireNonEmpty(items, field: "mealItems")
            let foods = try foods(ids: items.map(\.foodID))
            for existing in meal.items { context.delete(existing) }
            meal.items = []
            for (index, input) in items.enumerated() {
                guard let food = foods[input.foodID] else { throw RepositoryError.notFound(entity: "foodItem") }
                let item = SavedMealItem()
                item.foodID = food.id
                item.foodNameSnapshot = food.name
                item.quantity = try InputValidation.portion(quantity: input.quantity)
                item.unit = input.unit
                item.servingIndex = input.servingIndex
                item.orderIndex = index
                context.insert(item)
                item.meal = meal
            }
        }
        try persist()
    }

    func deleteSavedMeal(_ meal: SavedMeal) throws {
        context.delete(meal)
        try persist()
    }

    /// Logs every item of a saved meal into one slot.
    ///
    /// Items whose food has since been deleted are skipped rather than logged as zeroes: a silent
    /// zero would understate the day's intake, which is the one failure mode a food diary must not
    /// have. The count of skipped items is logged for diagnostics.
    @discardableResult
    func logSavedMeal(
        _ meal: SavedMeal,
        to slot: MealSlot? = nil,
        dayKey: String = DayKey.today,
        now: Date = Date()
    ) throws -> [FoodLogEntry] {
        let targetSlot = slot ?? meal.defaultSlot
        let items = meal.items.sorted { $0.orderIndex < $1.orderIndex }
        let foods = try foods(ids: items.compactMap(\.foodID))

        var index = try nextOrderIndex(dayKey: dayKey, slot: targetSlot)
        var created: [FoodLogEntry] = []
        var missing = 0

        for item in items {
            guard let foodID = item.foodID, let food = foods[foodID] else {
                missing += 1
                continue
            }
            let entry = FoodLogEntry()
            entry.dayKey = dayKey
            entry.loggedAt = now
            entry.mealSlot = targetSlot
            entry.orderIndex = index
            entry.foodID = food.id
            entry.foodNameSnapshot = food.name
            entry.brandSnapshot = food.brand
            entry.quantity = item.quantity
            entry.unit = item.unit
            entry.servingIndex = item.servingIndex
            entry.macrosSnapshot = food.macros(
                forQuantity: item.quantity, unit: item.unit, servingIndex: item.servingIndex
            )
            entry.micronutrientsSnapshot = food.micronutrients(
                forQuantity: item.quantity, unit: item.unit, servingIndex: item.servingIndex
            )
            entry.savedMealID = meal.id
            context.insert(entry)
            food.timesLogged += 1
            food.lastLoggedAt = now
            created.append(entry)
            index += 1
        }

        if missing > 0 {
            AppLog.nutrition.error("Saved meal '\(meal.name, privacy: .public)' skipped \(missing) deleted food(s)")
        }
        meal.timesUsed += 1
        meal.lastUsedAt = now
        try persist()
        return created
    }

    /// Macro and micronutrient totals for a saved meal, computed from its ingredients.
    func nutrition(of meal: SavedMeal) throws -> NutritionTotals {
        let items = meal.items
        let foods = try foods(ids: items.compactMap(\.foodID))
        return items.reduce(NutritionTotals.zero) { totals, item in
            guard let foodID = item.foodID, let food = foods[foodID] else { return totals }
            return totals + NutritionTotals(
                macros: food.macros(forQuantity: item.quantity, unit: item.unit, servingIndex: item.servingIndex),
                micronutrients: food.micronutrients(
                    forQuantity: item.quantity, unit: item.unit, servingIndex: item.servingIndex
                )
            )
        }
    }

    // MARK: - Recipes

    /// Recipes, favourites first and then by how often they are used.
    func recipes() throws -> [Recipe] {
        let recipes = try fetch(FetchDescriptor<Recipe>(
            sortBy: [SortDescriptor(\.timesUsed, order: .reverse),
                     SortDescriptor(\.name, order: .forward)]
        ))
        return recipes.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isFavorite != rhs.element.isFavorite { return lhs.element.isFavorite }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    @discardableResult
    func createRecipe(
        name: String,
        servingsCount: Double,
        ingredients: [NutritionPortionInput],
        instructions: String? = nil,
        preparationMinutes: Int? = nil,
        tags: [String] = [],
        now: Date = Date()
    ) throws -> Recipe {
        _ = try InputValidation.requireNonEmpty(ingredients, field: "recipeIngredients")
        let foods = try foods(ids: ingredients.map(\.foodID))

        let recipe = Recipe()
        recipe.name = try InputValidation.name(name, field: "recipeName")
        recipe.servingsCount = try InputValidation.servings(count: servingsCount)
        recipe.instructions = InputValidation.sanitisedNote(instructions)
        recipe.preparationMinutes = preparationMinutes.map { min(max(0, $0), 1440) }
        recipe.tags = InputValidation.normalisedTags(tags)
        recipe.createdAt = now
        recipe.updatedAt = now
        context.insert(recipe)

        for (index, input) in ingredients.enumerated() {
            guard let food = foods[input.foodID] else { throw RepositoryError.notFound(entity: "foodItem") }
            let ingredient = RecipeIngredient()
            ingredient.foodID = food.id
            ingredient.foodNameSnapshot = food.name
            ingredient.quantity = try InputValidation.portion(quantity: input.quantity)
            ingredient.unit = input.unit
            ingredient.servingIndex = input.servingIndex
            ingredient.orderIndex = index
            context.insert(ingredient)
            ingredient.recipe = recipe
        }
        try persist()
        return recipe
    }

    func updateRecipe(
        _ recipe: Recipe,
        name: String? = nil,
        servingsCount: Double? = nil,
        instructions: String?? = nil,
        preparationMinutes: Int?? = nil,
        tags: [String]? = nil,
        isFavorite: Bool? = nil,
        ingredients: [NutritionPortionInput]? = nil,
        now: Date = Date()
    ) throws {
        if let name { recipe.name = try InputValidation.name(name, field: "recipeName") }
        if let servingsCount { recipe.servingsCount = try InputValidation.servings(count: servingsCount) }
        if let instructions { recipe.instructions = InputValidation.sanitisedNote(instructions) }
        if let preparationMinutes { recipe.preparationMinutes = preparationMinutes.map { min(max(0, $0), 1440) } }
        if let tags { recipe.tags = InputValidation.normalisedTags(tags) }
        if let isFavorite { recipe.isFavorite = isFavorite }
        if let ingredients {
            _ = try InputValidation.requireNonEmpty(ingredients, field: "recipeIngredients")
            let foods = try foods(ids: ingredients.map(\.foodID))
            for existing in recipe.ingredients { context.delete(existing) }
            recipe.ingredients = []
            for (index, input) in ingredients.enumerated() {
                guard let food = foods[input.foodID] else { throw RepositoryError.notFound(entity: "foodItem") }
                let ingredient = RecipeIngredient()
                ingredient.foodID = food.id
                ingredient.foodNameSnapshot = food.name
                ingredient.quantity = try InputValidation.portion(quantity: input.quantity)
                ingredient.unit = input.unit
                ingredient.servingIndex = input.servingIndex
                ingredient.orderIndex = index
                context.insert(ingredient)
                ingredient.recipe = recipe
            }
        }
        recipe.updatedAt = now
        try persist()
    }

    func deleteRecipe(_ recipe: Recipe) throws {
        context.delete(recipe)
        try persist()
    }

    /// Total and per-serving nutrition for a recipe.
    ///
    /// Computed from the ingredients every time rather than stored, so correcting an ingredient
    /// quantity immediately corrects every serving figure. Recipes are small — a dozen ingredients
    /// at most — so the cost is one dictionary lookup per ingredient.
    func nutrition(of recipe: Recipe) throws -> RecipeNutrition {
        let ingredients = recipe.ingredients
        let foods = try foods(ids: ingredients.compactMap(\.foodID))
        let total = ingredients.reduce(NutritionTotals.zero) { totals, ingredient in
            guard let foodID = ingredient.foodID, let food = foods[foodID] else { return totals }
            return totals + NutritionTotals(
                macros: food.macros(
                    forQuantity: ingredient.quantity, unit: ingredient.unit, servingIndex: ingredient.servingIndex
                ),
                micronutrients: food.micronutrients(
                    forQuantity: ingredient.quantity, unit: ingredient.unit, servingIndex: ingredient.servingIndex
                )
            )
        }
        let servings = max(0.25, recipe.servingsCount)
        return RecipeNutrition(
            servingsCount: servings,
            total: total,
            perServing: total.scaled(by: 1 / servings)
        )
    }

    /// Logs one or more servings of a recipe as a single entry.
    ///
    /// A recipe is logged as one line, not as its ingredients: the user ate "chilli", and a diary
    /// that expands it into eleven rows of tinned tomatoes is unreadable. The ingredient breakdown
    /// remains available through `recipeID`.
    @discardableResult
    func logRecipeServing(
        _ recipe: Recipe,
        servings: Double = 1,
        to slot: MealSlot,
        dayKey: String = DayKey.today,
        now: Date = Date()
    ) throws -> FoodLogEntry {
        let portions = try InputValidation.portion(quantity: servings, field: "servings")
        let nutrition = try nutrition(of: recipe)

        let entry = FoodLogEntry()
        entry.dayKey = dayKey
        entry.loggedAt = now
        entry.mealSlot = slot
        entry.orderIndex = try nextOrderIndex(dayKey: dayKey, slot: slot)
        entry.foodID = nil
        entry.foodNameSnapshot = recipe.name
        entry.quantity = portions
        entry.unit = .serving
        entry.macrosSnapshot = nutrition.perServing.macros * portions
        entry.micronutrientsSnapshot = nutrition.perServing.micronutrients.scaled(by: portions)
        entry.recipeID = recipe.id
        context.insert(entry)

        recipe.timesUsed += 1
        try persist()
        return entry
    }

    // MARK: - Targets

    /// The target currently in force, or `nil` before one has been set.
    func activeTarget() throws -> DailyNutritionTarget? {
        let descriptor = FetchDescriptor<DailyNutritionTarget>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\.effectiveFrom, order: .reverse)]
        )
        let active = try fetch(descriptor)
        if active.count > 1 {
            AppLog.nutrition.error("Found \(active.count) active nutrition targets; keeping the newest")
            for stale in active.dropFirst() { stale.isActive = false }
            try persist()
        }
        return active.first
    }

    /// Replaces the active target and writes the change into the history.
    ///
    /// The history row records both the old and the new numbers together with the reason. "Why did
    /// my calories move?" is the single most common question a calorie app has to answer, and
    /// answering it from a diff of two rows that may both have been edited since is not an answer.
    /// The previous target is deactivated rather than deleted, so the timeline stays complete.
    @discardableResult
    func replaceActiveTarget(
        kilocalories: Double,
        proteinG: Double,
        carbsG: Double,
        fatG: Double,
        isManualOverride: Bool,
        rationale: Explanation? = nil,
        reason: Explanation,
        wasAutomatic: Bool,
        trendWeightKg: Double? = nil,
        micronutrientGoals: Micronutrients? = nil,
        now: Date = Date()
    ) throws -> DailyNutritionTarget {
        let energy = try InputValidation.energy(kilocalories: kilocalories)
        let protein = InputValidation.clampedMacroGrams(proteinG)
        let carbs = InputValidation.clampedMacroGrams(carbsG)
        let fat = InputValidation.clampedMacroGrams(fatG)

        let previous = try activeTarget()

        let history = NutritionTargetHistory()
        history.changedAt = now
        history.previousKilocalories = previous?.kilocalories ?? 0
        history.previousProteinG = previous?.proteinG ?? 0
        history.previousCarbsG = previous?.carbsG ?? 0
        history.previousFatG = previous?.fatG ?? 0
        history.newKilocalories = energy
        history.newProteinG = protein
        history.newCarbsG = carbs
        history.newFatG = fat
        history.reasonKey = reason.key
        history.reasonArguments = reason.arguments
        history.wasAutomatic = wasAutomatic
        history.trendWeightKg = trendWeightKg
        context.insert(history)

        previous?.isActive = false

        let target = DailyNutritionTarget()
        target.effectiveFrom = now
        target.kilocalories = energy
        target.proteinG = protein
        target.carbsG = carbs
        target.fatG = fat
        target.isManualOverride = isManualOverride
        target.rationaleKey = rationale?.key
        target.rationaleArguments = rationale?.arguments ?? []
        target.isActive = true
        // Micronutrient goals are carried forward unless replaced: they are a separate decision from
        // the energy target and should not be silently reset by a calorie adjustment.
        target.micronutrientGoals = micronutrientGoals ?? previous?.micronutrientGoals ?? .unknown
        context.insert(target)

        try persist()
        return target
    }

    /// Sets explicit micronutrient goals on the active target.
    func updateMicronutrientGoals(_ goals: Micronutrients) throws {
        guard let target = try activeTarget() else {
            throw RepositoryError.notFound(entity: "dailyNutritionTarget")
        }
        target.micronutrientGoals = goals
        try persist()
    }

    /// Every target change, newest first.
    func targetHistory(limit: Int = 50) throws -> [NutritionTargetHistory] {
        var descriptor = FetchDescriptor<NutritionTargetHistory>(
            sortBy: [SortDescriptor(\.changedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try fetch(descriptor)
    }

    // MARK: - Water

    @discardableResult
    func addWater(
        milliliters: Double,
        dayKey: String = DayKey.today,
        now: Date = Date()
    ) throws -> WaterLogEntry {
        let entry = WaterLogEntry()
        entry.dayKey = dayKey
        entry.loggedAt = now
        entry.milliliters = InputValidation.clampedWaterMilliliters(milliliters)
        context.insert(entry)
        try persist()
        return entry
    }

    func waterEntries(for dayKey: String) throws -> [WaterLogEntry] {
        try fetch(FetchDescriptor<WaterLogEntry>(
            predicate: #Predicate { $0.dayKey == dayKey },
            sortBy: [SortDescriptor(\.loggedAt, order: .forward)]
        ))
    }

    func waterTotal(for dayKey: String = DayKey.today) throws -> Double {
        try waterEntries(for: dayKey).reduce(0) { $0 + $1.milliliters }
    }

    func deleteWater(_ entry: WaterLogEntry) throws {
        context.delete(entry)
        try persist()
    }

    // MARK: - Daily totals

    /// Everything consumed on one day, macros and micronutrients, with a per-slot breakdown.
    func totals(for dayKey: String = DayKey.today) throws -> DailyNutritionTotals {
        let entries = try dayLog(for: dayKey)
        var result = DailyNutritionTotals(dayKey: dayKey)
        for entry in entries {
            result.totals = result.totals + NutritionTotals(
                macros: entry.macrosSnapshot,
                micronutrients: entry.micronutrientsSnapshot
            )
            result.macrosBySlot[entry.mealSlot, default: .zero] = (result.macrosBySlot[entry.mealSlot] ?? .zero)
                + entry.macrosSnapshot
        }
        result.entryCount = entries.count
        result.waterMilliliters = try waterTotal(for: dayKey)
        return result
    }

    /// A day measured against the active target.
    func progress(for dayKey: String = DayKey.today) throws -> DailyNutritionProgress {
        let totals = try totals(for: dayKey)
        let target = try activeTarget()?.macros
        let consumed = totals.macros
        return DailyNutritionProgress(
            dayKey: dayKey,
            target: target,
            consumed: consumed,
            remaining: target.map { $0 - consumed } ?? .zero,
            energyProgress: (target?.kilocalories ?? 0) > 0
                ? consumed.kilocalories / (target?.kilocalories ?? 1)
                : 0,
            waterMilliliters: totals.waterMilliliters
        )
    }

    // MARK: - Candidates for the meal recommender

    /// The food pool the meal recommender scores.
    ///
    /// Ordered by how often the user logs each food, because the recommender's job is to suggest
    /// meals somebody will actually eat, and the strongest available signal for that is what they
    /// already eat. The limit exists to keep the scoring pass bounded on a large food database.
    func mealCandidateFoods(limit: Int = 400) throws -> [MealCandidateFood] {
        var descriptor = FetchDescriptor<FoodItem>(
            sortBy: [SortDescriptor(\.timesLogged, order: .reverse),
                     SortDescriptor(\.name, order: .forward)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try fetch(descriptor).map(Self.candidate(from:))
    }

    /// Converts one stored food into the recommender's value type.
    static func candidate(from food: FoodItem) -> MealCandidateFood {
        MealCandidateFood(
            id: food.id,
            catalogID: food.catalogID,
            name: food.name,
            macrosPer100: food.macrosPer100,
            micronutrientsPer100: food.micronutrientsPer100,
            dietaryTags: Set(food.dietaryTags),
            allergenTags: Set(food.allergenTags),
            roleTags: Set(food.roleTags),
            gramsPerPiece: food.gramsPerPiece,
            // The portion the user normally logs: a named serving if the food has one, otherwise a
            // natural piece. `nil` leaves the portion solver free to choose.
            defaultServingGrams: food.servings.first?.gramsPerServing ?? food.gramsPerPiece,
            timesLogged: food.timesLogged,
            isFavorite: food.isFavorite,
            costPer100: food.costPer100
        )
    }

    /// Saved meals as recommender candidates, with their nutrition resolved.
    ///
    /// Foods are fetched once for every meal rather than once per meal, so this stays two queries no
    /// matter how many meals the user has saved.
    func savedMealCandidates() throws -> [SavedMealCandidate] {
        let meals = try savedMeals()
        guard !meals.isEmpty else { return [] }
        let foods = try foods(ids: meals.flatMap { $0.items.compactMap(\.foodID) })

        return meals.map { meal in
            var macros = MacroNutrients.zero
            var portions: [SuggestedFoodPortion] = []
            for item in meal.items.sorted(by: { $0.orderIndex < $1.orderIndex }) {
                guard let foodID = item.foodID, let food = foods[foodID] else { continue }
                let itemMacros = food.macros(
                    forQuantity: item.quantity, unit: item.unit, servingIndex: item.servingIndex
                )
                macros = macros + itemMacros
                portions.append(SuggestedFoodPortion(
                    foodID: food.id,
                    catalogID: food.catalogID,
                    name: food.name,
                    quantity: item.quantity,
                    unit: item.unit,
                    macros: itemMacros
                ))
            }
            return SavedMealCandidate(
                id: meal.id,
                name: meal.name,
                macros: macros,
                items: portions,
                timesUsed: meal.timesUsed,
                slot: meal.defaultSlot
            )
        }
    }

    /// Recipes as recommender candidates, priced per serving.
    func recipeCandidates() throws -> [RecipeCandidate] {
        let recipes = try recipes()
        guard !recipes.isEmpty else { return [] }
        let foods = try foods(ids: recipes.flatMap { $0.ingredients.compactMap(\.foodID) })

        return recipes.map { recipe in
            var macros = MacroNutrients.zero
            for ingredient in recipe.ingredients {
                guard let foodID = ingredient.foodID, let food = foods[foodID] else { continue }
                macros = macros + food.macros(
                    forQuantity: ingredient.quantity, unit: ingredient.unit, servingIndex: ingredient.servingIndex
                )
            }
            let servings = max(0.25, recipe.servingsCount)
            return RecipeCandidate(
                id: recipe.id,
                name: recipe.name,
                macrosPerServing: macros * (1 / servings),
                preparationMinutes: recipe.preparationMinutes,
                tags: Set(recipe.tags),
                timesUsed: recipe.timesUsed
            )
        }
    }

    /// Ids of foods logged in the trailing `days` days, newest first. Feeds the recommender's
    /// variety penalty, which exists so the suggestions do not become a rut.
    func recentlyLoggedFoodIDs(endingOn dayKey: String = DayKey.today, days: Int = 2, calendar: Calendar = .current) throws -> [UUID] {
        var keys: [String] = []
        for offset in 0..<max(1, days) {
            keys.append(DayKey.offset(from: dayKey, days: -offset, calendar: calendar))
        }
        let entries = try fetch(FetchDescriptor<FoodLogEntry>(
            predicate: #Predicate { keys.contains($0.dayKey) },
            sortBy: [SortDescriptor(\.loggedAt, order: .reverse)]
        ))
        var seen = Set<UUID>()
        return entries.compactMap(\.foodID).filter { seen.insert($0).inserted }
    }

    // MARK: - Private

    /// The next free ordering slot within one meal of one day.
    private func nextOrderIndex(dayKey: String, slot: MealSlot) throws -> Int {
        let entries = try fetch(FetchDescriptor<FoodLogEntry>(predicate: #Predicate { $0.dayKey == dayKey }))
        let inSlot = entries.filter { $0.mealSlot == slot }
        return (inSlot.map(\.orderIndex).max() ?? -1) + 1
    }

    /// Copies a log entry onto another day, snapshot and all. Not saved; the caller batches.
    private func duplicate(
        _ entry: FoodLogEntry,
        toDayKey dayKey: String,
        slot: MealSlot,
        now: Date
    ) -> FoodLogEntry {
        let copy = FoodLogEntry()
        copy.dayKey = dayKey
        copy.loggedAt = now
        copy.mealSlot = slot
        copy.foodID = entry.foodID
        copy.foodNameSnapshot = entry.foodNameSnapshot
        copy.brandSnapshot = entry.brandSnapshot
        copy.quantity = entry.quantity
        copy.unit = entry.unit
        copy.servingIndex = entry.servingIndex
        copy.macrosSnapshot = entry.macrosSnapshot
        copy.micronutrientsSnapshot = entry.micronutrientsSnapshot
        copy.savedMealID = entry.savedMealID
        copy.recipeID = entry.recipeID
        context.insert(copy)
        return copy
    }

    /// Validates a per-100 g nutrition basis.
    ///
    /// Macros are capped at 100 g per 100 g — a food cannot be more than entirely one macronutrient —
    /// and energy at 1,000 kcal per 100 g, comfortably above pure fat's 900. Energy is derived from
    /// the macros when it is left at zero, because 4/4/9 is a far better answer than "this food has
    /// no calories".
    private static func validatedPer100(
        kilocalories: Double,
        proteinG: Double,
        carbsG: Double,
        fatG: Double
    ) throws -> MacroNutrients {
        let energy = try InputValidation.energyDensity(
            kilocaloriesPer100: kilocalories, field: "kilocaloriesPer100"
        )
        try InputValidation.requireFinite(proteinG, field: "proteinGPer100")
        try InputValidation.requireFinite(carbsG, field: "carbsGPer100")
        try InputValidation.requireFinite(fatG, field: "fatGPer100")

        let macros = MacroNutrients(
            kilocalories: energy,
            proteinG: InputValidation.clampedMacroDensity(proteinG),
            carbsG: InputValidation.clampedMacroDensity(carbsG),
            fatG: InputValidation.clampedMacroDensity(fatG)
        )
        guard macros.kilocalories > 0 else {
            var derived = macros
            derived.kilocalories = min(macros.derivedKilocalories, InputValidation.energyDensityPer100.upperBound)
            return derived
        }
        return macros
    }

    /// Named servings must have a positive gram weight, or portion maths silently produces zero.
    private static func validatedServings(_ servings: [FoodServing]) throws -> [FoodServing] {
        for serving in servings {
            _ = try InputValidation.grams(serving.gramsPerServing, field: "gramsPerServing")
        }
        return servings
    }
}

// MARK: - Small helpers

private extension String {
    /// `nil` when the string is empty, so an empty text field never becomes an empty-string barcode
    /// that would then match every other empty-string barcode.
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
