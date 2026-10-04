import Foundation
import Observation
import SwiftData

/// Everything the Nutrition tab shows for one day, and every mutation it can perform.
///
/// The whole tab is addressed by `DayKey` rather than by `Date`: a day's log is then one indexed
/// equality fetch, and moving between days is a string calculation that cannot drift with time
/// zones. A day is small — a few dozen rows at most — so every mutation simply reloads the day
/// afterwards instead of trying to patch the in-memory arrays. That is a deliberate trade: the
/// reload costs a millisecond and removes an entire class of "the total disagrees with the rows"
/// bugs that a food diary absolutely must not have.
@MainActor
@Observable
final class NutritionDayViewModel {

    /// The four states every screen has to handle. `failed` carries finished copy because the
    /// failure it describes has already been translated out of `RepositoryError`.
    enum Phase: Equatable {
        case loading
        case content
        case failed(String)
    }

    // MARK: - State

    private(set) var phase: Phase = .loading
    private(set) var dayKey: String
    private(set) var entriesBySlot: [MealSlot: [FoodLogEntry]] = [:]
    private(set) var totals: DailyNutritionTotals
    private(set) var progress: DailyNutritionProgress
    private(set) var savedMeals: [SavedMeal] = []

    /// Everything the rows need to render, resolved once per load instead of once per render.
    ///
    /// The four meal sections live in a plain `VStack`, so every change to the day rebuilds all of
    /// them. Resolving each row's food and recipe from inside `body` meant three store round-trips
    /// per logged item — one of them a full fetch and re-sort of the whole `Recipe` table — on every
    /// keystroke, every water tap and every day change.
    ///
    /// Deliberately ids and values, never the `FoodItem` objects themselves. This view model is
    /// created once and lives for as long as the tab does, so a food deleted from the Library tab
    /// in the meantime would leave a deleted model sitting in the cache — and reading a property
    /// off a deleted SwiftData model is not something a food diary should be doing. Anything that
    /// needs the object itself goes back to the store for it.
    private var knownFoodIDs: Set<UUID> = []
    private var favoriteFoodIDs: Set<UUID> = []
    private var knownRecipeIDs: Set<UUID> = []
    private var savedMealMacros: [UUID: MacroNutrients] = [:]
    /// Meals that the previous day has something in, so "same as yesterday" is only offered when
    /// it would actually do something.
    private(set) var yesterdaySlotsWithFood: Set<MealSlot> = []
    private(set) var isWaterTrackingEnabled = true
    private(set) var waterTargetMl: Double = 2500

    /// A short confirmation of the last action ("3 items added"). The view shows it briefly and
    /// clears it; it is never the only feedback for a change.
    var notice: String?
    /// A failure from a *mutation*, as opposed to a failure to load. Presented as an alert so the
    /// day the user is looking at stays on screen.
    var actionError: String?

    // MARK: - Collaborators

    private let context: ModelContext
    private let repository: NutritionRepository
    private let profiles: ProfileRepository
    private let environment: AppEnvironment
    private let calendar: Calendar

    init(context: ModelContext, environment: AppEnvironment, dayKey: String = DayKey.today, calendar: Calendar = .current) {
        self.context = context
        self.environment = environment
        self.repository = NutritionRepository(context: context)
        self.profiles = ProfileRepository(context: context)
        self.dayKey = dayKey
        self.calendar = calendar
        self.totals = DailyNutritionTotals(dayKey: dayKey)
        self.progress = DailyNutritionProgress(
            dayKey: dayKey, target: nil, consumed: .zero, remaining: .zero,
            energyProgress: 0, waterMilliliters: 0
        )
    }

    // MARK: - Derived

    var date: Date { DayKey.date(from: dayKey, calendar: calendar) ?? Date() }
    var isToday: Bool { dayKey == DayKey.make(from: Date(), calendar: calendar) }
    var isEmptyDay: Bool { totals.entryCount == 0 }
    var hasTarget: Bool { progress.target != nil }

    /// Forward navigation stops at today. A food diary records what was eaten; letting the user
    /// wander into next week produces days that can never be anything but empty.
    var canGoForward: Bool { !isToday }

    func entries(in slot: MealSlot) -> [FoodLogEntry] { entriesBySlot[slot] ?? [] }
    func subtotal(of slot: MealSlot) -> MacroNutrients { totals.macrosBySlot[slot] ?? .zero }

    /// The meal a person is most likely to be logging right now. Used as the default when they tap
    /// "Add food" without having said which meal they mean.
    var slotForNow: MealSlot {
        switch calendar.component(.hour, from: Date()) {
        case ..<11: .breakfast
        case ..<16: .lunch
        case ..<21: .dinner
        default: .snacks
        }
    }

    // MARK: - Loading

    func load() {
        do {
            let settings = try profiles.settings()
            isWaterTrackingEnabled = settings.waterTrackingEnabled
            waterTargetMl = settings.dailyWaterTargetMl

            entriesBySlot = try repository.dayLogBySlot(for: dayKey)
            totals = try repository.totals(for: dayKey)
            progress = try repository.progress(for: dayKey)
            savedMeals = try repository.savedMeals()
            savedMealMacros = Dictionary(
                savedMeals.map { ($0.id, (try? repository.nutrition(of: $0).macros) ?? .zero) },
                uniquingKeysWith: { first, _ in first }
            )

            let entries = entriesBySlot.values.flatMap { $0 }
            let foods = Set(entries.compactMap(\.foodID)).compactMap { try? repository.food(id: $0) }
            knownFoodIDs = Set(foods.map(\.id))
            favoriteFoodIDs = Set(foods.filter(\.isFavorite).map(\.id))
            knownRecipeIDs = Set(try repository.recipes().map(\.id))
                .intersection(entries.compactMap(\.recipeID))

            let yesterday = DayKey.offset(from: dayKey, days: -1, calendar: calendar)
            yesterdaySlotsWithFood = Set(try repository.dayLog(for: yesterday).map(\.mealSlot))

            phase = .content
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    /// Moves to another day and reloads. Kept separate from `load()` so the view can animate the
    /// change of day without animating an ordinary refresh.
    func select(dayKey newDayKey: String) {
        guard newDayKey != dayKey else { return }
        dayKey = newDayKey
        load()
    }

    func goToPreviousDay() { select(dayKey: DayKey.offset(from: dayKey, days: -1, calendar: calendar)) }

    func goToNextDay() {
        guard canGoForward else { return }
        select(dayKey: DayKey.offset(from: dayKey, days: 1, calendar: calendar))
    }

    func goToToday() { select(dayKey: DayKey.make(from: Date(), calendar: calendar)) }

    func select(date: Date) { select(dayKey: DayKey.make(from: date, calendar: calendar)) }

    // MARK: - Entry actions

    func delete(_ entry: FoodLogEntry) {
        perform { try repository.delete(entry) }
    }

    func move(_ entry: FoodLogEntry, to slot: MealSlot) {
        perform(notice: L("nutritionLog.notice.moved", L(slot.localizationKey))) {
            try repository.move(entry, to: slot)
        }
    }

    func updatePortion(of entry: FoodLogEntry, to portion: PortionValue) {
        perform {
            try repository.updatePortion(
                of: entry,
                quantity: portion.quantity,
                unit: portion.unit,
                servingIndex: .some(portion.servingIndex)
            )
        }
    }

    /// Whether this row can be logged a second time. An entry whose food has since been deleted
    /// carries only a snapshot, and nothing left in the store knows how to build another portion
    /// of it, so the action is hidden rather than offered and then refused.
    func canDuplicate(_ entry: FoodLogEntry) -> Bool {
        if let id = entry.foodID, knownFoodIDs.contains(id) { return true }
        if let id = entry.recipeID, knownRecipeIDs.contains(id) { return true }
        return false
    }

    /// Whether this row's food still exists, so the favourite toggle is offered rather than shown
    /// and then refused. Read from `body` for every row, so it must not touch the store.
    func canFavorite(_ entry: FoodLogEntry) -> Bool {
        guard let id = entry.foodID else { return false }
        return knownFoodIDs.contains(id)
    }

    /// The confirmation is claimed inside the branch that actually wrote a row, never up front.
    ///
    /// `canDuplicate` answers from the id caches, which go stale the moment a food or recipe is
    /// deleted from the Library while this tab is alive. The affordance therefore outlives the
    /// thing it points at, and announcing "duplicated" before checking would have a food diary
    /// reporting a write it never made — the one thing it must never do. The fall-through says so
    /// plainly instead, and `perform`'s reload then retires the affordance on the same tap.
    func duplicate(_ entry: FoodLogEntry) {
        perform {
            if let food = food(for: entry) {
                try repository.addLogEntry(
                    food: food,
                    quantity: entry.quantity,
                    unit: entry.unit,
                    servingIndex: entry.servingIndex,
                    slot: entry.mealSlot,
                    dayKey: dayKey
                )
                notice = L("nutritionLog.notice.duplicated")
            } else if let recipe = recipe(for: entry) {
                try repository.logRecipeServing(
                    recipe, servings: entry.quantity, to: entry.mealSlot, dayKey: dayKey
                )
                notice = L("nutritionLog.notice.duplicated")
            } else {
                actionError = L("nutritionLog.error.noLongerAvailable")
            }
        }
    }

    func isFavorite(_ entry: FoodLogEntry) -> Bool {
        guard let id = entry.foodID else { return false }
        return favoriteFoodIDs.contains(id)
    }

    func toggleFavorite(_ entry: FoodLogEntry) {
        guard let food = food(for: entry) else { return }
        let makingFavorite = !food.isFavorite
        perform(notice: makingFavorite ? L("nutritionLog.notice.favorited") : nil) {
            try repository.setFoodFavorite(makingFavorite, on: food)
        }
    }

    /// The stored food behind an entry, when it still exists.
    ///
    /// A live fetch, on purpose. Every caller either mutates through the object or presents a sheet
    /// built from it, and both want the current row rather than whatever was true at the last
    /// load. Nothing on the scrolling path calls this — `canFavorite`, `canDuplicate` and
    /// `isFavorite` answer from the caches above instead.
    func food(for entry: FoodLogEntry) -> FoodItem? {
        guard let id = entry.foodID else { return nil }
        return try? repository.food(id: id)
    }

    private func recipe(for entry: FoodLogEntry) -> Recipe? {
        guard let id = entry.recipeID else { return nil }
        return try? repository.recipes().first { $0.id == id }
    }

    // MARK: - Fast repeats

    func copyYesterday(into slot: MealSlot) {
        perform {
            let created = try repository.copyYesterdayMeal(slot, to: dayKey, calendar: calendar)
            notice = created.isEmpty
                ? L("nutritionLog.notice.nothingToCopy")
                : L("nutritionLog.notice.itemsAdded", created.count)
        }
    }

    func copyDay(from sourceDayKey: String) {
        perform {
            let created = try repository.copyDay(from: sourceDayKey, to: dayKey)
            notice = created.isEmpty
                ? L("nutritionLog.notice.nothingToCopy")
                : L("nutritionLog.notice.itemsAdded", created.count)
        }
    }

    /// Number of entries on an arbitrary day, so the copy-a-day picker can say what it would copy
    /// before the user commits to it.
    func entryCount(on otherDayKey: String) -> Int {
        (try? repository.dayLog(for: otherDayKey).count) ?? 0
    }

    func saveAsMeal(named name: String, slot: MealSlot) {
        perform(notice: L("nutritionLog.notice.mealSaved")) {
            try repository.saveMeal(named: name, fromDayKey: dayKey, slot: slot)
        }
    }

    func logSavedMeal(_ meal: SavedMeal, into slot: MealSlot) {
        perform {
            let created = try repository.logSavedMeal(meal, to: slot, dayKey: dayKey)
            // A saved meal can lose items when a food behind it is deleted; saying how many rows
            // actually landed is the only honest way to report that.
            notice = created.count == meal.items.count
                ? L("nutritionLog.notice.itemsAdded", created.count)
                : L("nutritionLog.notice.itemsAddedPartial", created.count, meal.items.count)
        }
    }

    /// Totals for a saved meal, precomputed in `load()`. Every meal section renders this for every
    /// saved meal in its menu, so it cannot be a fetch.
    func nutrition(of meal: SavedMeal) -> MacroNutrients {
        savedMealMacros[meal.id] ?? .zero
    }

    // MARK: - Water

    func addWater(milliliters: Double) {
        perform { try repository.addWater(milliliters: milliliters, dayKey: dayKey) }
    }

    /// Removes the most recent glass. The only sane undo for a quick-add button that people will
    /// inevitably hit twice.
    func removeLastWater() {
        perform {
            guard let last = try repository.waterEntries(for: dayKey).last else { return }
            try repository.deleteWater(last)
        }
    }

    // MARK: - Plumbing

    /// Runs a mutation, refreshes the day and the widget snapshot, and turns any failure into an
    /// alert instead of a crash. Every mutating method on this type goes through here so that
    /// "did the widget update?" is never a per-call decision.
    private func perform(notice successNotice: String? = nil, _ work: () throws -> Void) {
        do {
            try work()
            if let successNotice { notice = successNotice }
            load()
            environment.snapshotWriter.refresh(context: context, catalog: environment.catalog)
        } catch {
            actionError = Self.message(for: error)
            AppLog.nutrition.error("Nutrition action failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func message(for error: any Error) -> String {
        if let repositoryError = error as? RepositoryError {
            return repositoryError.explanation.text
        }
        return L("nutritionLog.error.generic")
    }
}
