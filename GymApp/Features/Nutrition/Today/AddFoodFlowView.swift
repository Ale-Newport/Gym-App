import SwiftData
import SwiftUI

// MARK: - Selection

/// Something that can be turned into a portion and logged.
///
/// A provider result is carried by value because it may never become a stored row — only a food the
/// user actually logs is written to the database. Stored foods and recipes are carried by id so the
/// value stays `Hashable` and cheap enough to sit inside a `NavigationPath`.
enum FoodSelection: Hashable {
    case stored(UUID)
    case result(FoodSearchResult)
    case recipe(UUID)
}

/// Where the add-food flow can navigate.
private enum AddFoodRoute: Hashable {
    case portion(FoodSelection)
    case detail(FoodSelection)
    /// Creating a food by hand, optionally seeded with a barcode that nothing recognised.
    case customFood(String?)
}

// MARK: - Lookups the repository does not expose

/// Two queries the add-food flow needs that `NutritionRepository` does not offer.
///
/// It conforms to `Repository` so it inherits the same fetch and save error handling as every other
/// repository rather than growing its own. Both methods belong on `NutritionRepository`; they live
/// here because this feature does not own that file.
@MainActor
struct FoodLookup: Repository {
    let context: ModelContext

    private var nutrition: NutritionRepository { NutritionRepository(context: context) }

    /// Finds or creates the stored food behind a provider result.
    ///
    /// Matching is by barcode first — the only globally unique identifier a packaged food has — and
    /// then by catalogue id, so a bundled record the importer already wrote is reused rather than
    /// duplicated. Creation goes through `createCustomFood` for its validation and then corrects the
    /// provenance fields, because a record that came from a catalogue is not a food the user typed
    /// and must not be presented as one.
    func materialise(_ result: FoodSearchResult) throws -> FoodItem {
        if let barcode = result.barcode?.trimmingCharacters(in: .whitespaces), !barcode.isEmpty,
           let existing = try nutrition.food(barcode: barcode) {
            return existing
        }
        let catalogID: String? = result.externalID
        if result.source == .builtIn,
           let existing = try fetchFirst(FetchDescriptor<FoodItem>(predicate: #Predicate { $0.catalogID == catalogID })) {
            return existing
        }

        let created = try nutrition.createCustomFood(
            name: result.name,
            brand: result.brand,
            barcode: result.barcode,
            kilocaloriesPer100: result.kilocaloriesPer100,
            proteinGPer100: result.proteinGPer100,
            carbsGPer100: result.carbsGPer100,
            fatGPer100: result.fatGPer100,
            micronutrientsPer100: result.micronutrientsPer100,
            basisUnit: result.basisUnit,
            servings: result.servings,
            gramsPerPiece: result.gramsPerPiece,
            dietaryTags: result.dietaryTags,
            allergenTags: result.allergenTags,
            roleTags: result.roleTags
        )
        created.source = result.source
        created.catalogID = result.source == .builtIn ? result.externalID : nil
        created.attribution = result.attribution
        try persist()
        return created
    }

    /// The portion this food was logged at last time, so a repeat is one tap and no typing.
    func lastPortion(of foodID: UUID) throws -> PortionValue? {
        let target: UUID? = foodID
        var descriptor = FetchDescriptor<FoodLogEntry>(
            predicate: #Predicate { $0.foodID == target },
            sortBy: [SortDescriptor(\.loggedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let entry = try fetch(descriptor).first else { return nil }
        return PortionValue(quantity: entry.quantity, unit: entry.unit, servingIndex: entry.servingIndex)
    }

    /// The user's own foods, newest first. `NutritionRepository` has no source filter, so the
    /// filtering happens here on a bounded fetch.
    func customFoods(limit: Int = 200) throws -> [FoodItem] {
        let custom = FoodSource.custom.rawValue
        var descriptor = FetchDescriptor<FoodItem>(
            predicate: #Predicate { $0.sourceRaw == custom },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return try fetch(descriptor)
    }
}

// MARK: - View model

/// Backs every tab of the add-food flow and performs the logging itself.
@MainActor
@Observable
final class AddFoodViewModel {

    enum Tab: String, CaseIterable, Identifiable {
        case search, recent, favorites, savedMeals, recipes, mine

        var id: String { rawValue }
        var localizationKey: String { "nutritionLog.tab.\(rawValue)" }
        var symbolName: String {
            switch self {
            case .search: "magnifyingglass"
            case .recent: "clock"
            case .favorites: "heart"
            case .savedMeals: "tray.full"
            case .recipes: "list.bullet.rectangle"
            case .mine: "person.crop.square"
            }
        }
    }

    enum Phase: Equatable {
        case loading
        case content
        case failed(String)
    }

    var tab: Tab = .search
    private(set) var phase: Phase = .loading
    private(set) var recentFoods: [FoodItem] = []
    private(set) var favoriteFoods: [FoodItem] = []
    private(set) var savedMeals: [SavedMeal] = []
    private(set) var recipes: [Recipe] = []
    private(set) var myFoods: [FoodItem] = []

    var actionError: String?

    let slot: MealSlot
    let dayKey: String

    private let context: ModelContext
    private let repository: NutritionRepository
    private let lookup: FoodLookup
    private let environment: AppEnvironment

    init(context: ModelContext, environment: AppEnvironment, slot: MealSlot, dayKey: String) {
        self.context = context
        self.environment = environment
        self.repository = NutritionRepository(context: context)
        self.lookup = FoodLookup(context: context)
        self.slot = slot
        self.dayKey = dayKey
    }

    // MARK: Loading

    func load() {
        do {
            recentFoods = try repository.recentFoods(limit: 40)
            favoriteFoods = try repository.favoriteFoods()
            savedMeals = try repository.savedMeals()
            recipes = try repository.recipes()
            myFoods = try lookup.customFoods()
            phase = .content
        } catch {
            phase = .failed(NutritionDayViewModel.message(for: error))
        }
    }

    // MARK: Resolving

    func food(id: UUID) -> FoodItem? { try? repository.food(id: id) }

    func recipe(id: UUID) -> Recipe? { recipes.first { $0.id == id } }

    /// The nutrition basis behind a selection, or `nil` when the row it referred to has gone.
    func basis(for selection: FoodSelection) -> PortionBasis? {
        switch selection {
        case .stored(let id):
            return food(id: id).map(PortionBasis.from)
        case .result(let result):
            return PortionBasis.from(result)
        case .recipe(let id):
            guard let recipe = recipe(id: id), let nutrition = try? repository.nutrition(of: recipe) else { return nil }
            // A recipe is priced per serving, so one serving becomes the 100-unit basis and the
            // portion maths stays the same arithmetic every other food uses.
            return PortionBasis(
                name: recipe.name,
                brand: nil,
                basisUnit: .grams,
                macrosPer100: nutrition.perServing.macros,
                micronutrientsPer100: nutrition.perServing.micronutrients,
                servings: [FoodServing(name: L("servingUnit.serving"), gramsPerServing: 100)],
                gramsPerPiece: nil
            )
        }
    }

    func source(for selection: FoodSelection) -> FoodSource {
        switch selection {
        case .stored(let id): food(id: id)?.source ?? .custom
        case .result(let result): result.source
        case .recipe: .recipe
        }
    }

    func barcode(for selection: FoodSelection) -> String? {
        switch selection {
        case .stored(let id): food(id: id)?.barcode
        case .result(let result): result.barcode
        case .recipe: nil
        }
    }

    func isFavorite(_ selection: FoodSelection) -> Bool {
        switch selection {
        case .stored(let id): food(id: id)?.isFavorite ?? false
        case .recipe(let id): recipe(id: id)?.isFavorite ?? false
        case .result: false
        }
    }

    /// Opens the editor where the user left it last time rather than at an arbitrary 100 g.
    func initialPortion(for selection: FoodSelection) -> PortionValue {
        let fallback = basis(for: selection)?.defaultPortion ?? PortionValue(quantity: 100)
        switch selection {
        case .stored(let id):
            return (try? lookup.lastPortion(of: id)).flatMap { $0 } ?? fallback
        case .recipe:
            return PortionValue(quantity: 1, unit: .serving, servingIndex: 0)
        case .result:
            return fallback
        }
    }

    // MARK: Actions

    /// Logs a portion. Returns `false` when it failed, so the caller keeps the sheet open.
    @discardableResult
    func log(_ selection: FoodSelection, portion: PortionValue, slot: MealSlot) -> Bool {
        do {
            switch selection {
            case .stored(let id):
                guard let food = food(id: id) else { throw RepositoryError.notFound(entity: "foodItem") }
                try repository.addLogEntry(
                    food: food,
                    quantity: portion.quantity,
                    unit: portion.unit,
                    servingIndex: portion.servingIndex,
                    slot: slot,
                    dayKey: dayKey
                )
            case .result(let result):
                let food = try lookup.materialise(result)
                try repository.addLogEntry(
                    food: food,
                    quantity: portion.quantity,
                    unit: portion.unit,
                    servingIndex: portion.servingIndex,
                    slot: slot,
                    dayKey: dayKey
                )
            case .recipe(let id):
                guard let recipe = recipe(id: id) else { throw RepositoryError.notFound(entity: "recipe") }
                try repository.logRecipeServing(recipe, servings: portion.quantity, to: slot, dayKey: dayKey)
            }
            finish()
            return true
        } catch {
            report(error)
            return false
        }
    }

    @discardableResult
    func logSavedMeal(_ meal: SavedMeal, into slot: MealSlot) -> Bool {
        do {
            try repository.logSavedMeal(meal, to: slot, dayKey: dayKey)
            finish()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func toggleFavorite(_ selection: FoodSelection) {
        guard case .stored(let id) = selection, let food = food(id: id) else { return }
        do {
            try repository.setFoodFavorite(!food.isFavorite, on: food)
            load()
        } catch {
            report(error)
        }
    }

    func deleteSavedMeal(_ meal: SavedMeal) {
        do {
            try repository.deleteSavedMeal(meal)
            load()
        } catch {
            report(error)
        }
    }

    func macros(of meal: SavedMeal) -> MacroNutrients {
        (try? repository.nutrition(of: meal).macros) ?? .zero
    }

    func macrosPerServing(of recipe: Recipe) -> MacroNutrients {
        (try? repository.nutrition(of: recipe).perServing.macros) ?? .zero
    }

    /// Reloads after a food was created elsewhere, so the newly created row is present in the lists
    /// this flow shows. Creation itself belongs to `CustomFoodEditorView`, which owns validation,
    /// micronutrients and named servings.
    func reloadAfterCustomFoodCreated() {
        load()
    }

    private func finish() {
        environment.snapshotWriter.refresh(context: context, catalog: environment.catalog)
        Haptics.success()
    }

    private func report(_ error: any Error) {
        actionError = NutritionDayViewModel.message(for: error)
        AppLog.nutrition.error("Add food failed: \(String(describing: error), privacy: .public)")
    }
}

// MARK: - Flow

/// The single entry point for putting food into the log.
///
/// Six ways in, because people log food in six different situations: searching for something new,
/// repeating what they ate yesterday, reaching for a favourite, replaying a saved meal, cooking a
/// recipe, or scanning the packet in their hand. The tabs are ordered by how often each is used
/// once the app has some history, and the barcode scanner sits in the toolbar where it is reachable
/// from all of them.
struct AddFoodFlowView: View {
    private let slot: MealSlot
    private let dayKey: String

    @State private var model: AddFoodViewModel?
    @State private var path = NavigationPath()
    @State private var isScanning = false

    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    init(slot: MealSlot, dayKey: String) {
        self.slot = slot
        self.dayKey = dayKey
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    content(model)
                } else {
                    LoadingStateView(message: L("common.loading"))
                }
            }
            .background(Color.appBackground)
            .navigationTitle(L("nutritionLog.add.title", L(slot.localizationKey)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isScanning = true
                    } label: {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .accessibilityLabel(L("food.scanner.title"))
                }
            }
            .navigationDestination(for: AddFoodRoute.self) { route in
                destination(route)
            }
        }
        .task {
            if model == nil {
                let created = AddFoodViewModel(context: context, environment: environment, slot: slot, dayKey: dayKey)
                created.load()
                model = created
            }
        }
        .sheet(isPresented: $isScanning) {
            BarcodeScannerView { outcome in
                isScanning = false
                handle(outcome)
            }
        }
        .alert(
            L("common.error"),
            isPresented: Binding(
                get: { model?.actionError != nil },
                set: { if !$0 { model?.actionError = nil } }
            )
        ) {
            Button(L("common.done"), role: .cancel) { model?.actionError = nil }
        } message: {
            Text(model?.actionError ?? "")
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ model: AddFoodViewModel) -> some View {
        VStack(spacing: Metrics.spacing12) {
            tabBar(model)

            switch model.phase {
            case .loading:
                LoadingStateView(message: L("common.loading"))
            case .failed(let message):
                ErrorStateView(message: message, retryTitle: L("common.retry")) { model.load() }
            case .content:
                switch model.tab {
                case .search:
                    FoodSearchView(
                        onSelect: { path.append(AddFoodRoute.portion($0)) },
                        onShowDetails: { path.append(AddFoodRoute.detail($0)) }
                    )
                case .recent:
                    foodList(model, foods: model.recentFoods, emptyTitle: L("nutritionLog.recent.emptyTitle"), emptyMessage: L("nutritionLog.recent.emptyMessage"))
                case .favorites:
                    foodList(model, foods: model.favoriteFoods, emptyTitle: L("nutritionLog.favorites.emptyTitle"), emptyMessage: L("nutritionLog.favorites.emptyMessage"))
                case .savedMeals:
                    savedMealList(model)
                case .recipes:
                    recipeList(model)
                case .mine:
                    myFoodList(model)
                }
            }
        }
    }

    private func tabBar(_ model: AddFoodViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.spacing8) {
                ForEach(AddFoodViewModel.Tab.allCases) { tab in
                    Button {
                        model.tab = tab
                        Haptics.selectionChanged()
                    } label: {
                        Chip(
                            title: L(tab.localizationKey),
                            systemImage: tab.symbolName,
                            isSelected: model.tab == tab,
                            tint: .appNutrition
                        )
                        .frame(minHeight: Metrics.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.tab == tab ? [.isButton, .isSelected] : .isButton)
                }
            }
            .screenPadding()
        }
        .scrollClipDisabled()
    }

    private func foodList(
        _ model: AddFoodViewModel,
        foods: [FoodItem],
        emptyTitle: String,
        emptyMessage: String
    ) -> some View {
        Group {
            if foods.isEmpty {
                EmptyStateView(systemImage: "tray", title: emptyTitle, message: emptyMessage) {
                    Button(L("nutritionLog.tab.search")) { model.tab = .search }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 260)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(foods, id: \.id) { food in
                            FoodPickerRow(
                                title: food.name,
                                subtitle: food.brand,
                                macrosPer100: food.macrosPer100,
                                basisUnit: food.basisUnit,
                                isFavorite: food.isFavorite,
                                onTap: { path.append(AddFoodRoute.portion(.stored(food.id))) },
                                onShowDetails: { path.append(AddFoodRoute.detail(.stored(food.id))) }
                            )
                            Divider().overlay(Color.appSeparator)
                        }
                    }
                    .screenPadding()
                    .readableWidth()
                }
            }
        }
    }

    private func savedMealList(_ model: AddFoodViewModel) -> some View {
        Group {
            if model.savedMeals.isEmpty {
                EmptyStateView(
                    systemImage: "tray.full",
                    title: L("nutritionLog.savedMeals.emptyTitle"),
                    message: L("nutritionLog.savedMeals.emptyMessage")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: Metrics.spacing8) {
                        ForEach(model.savedMeals, id: \.id) { meal in
                            SavedMealRow(
                                name: meal.name,
                                itemCount: meal.items.count,
                                macros: model.macros(of: meal),
                                isFavorite: meal.isFavorite,
                                onLog: {
                                    if model.logSavedMeal(meal, into: slot) { dismiss() }
                                },
                                onLogInto: { chosen in
                                    if model.logSavedMeal(meal, into: chosen) { dismiss() }
                                },
                                onDelete: { model.deleteSavedMeal(meal) }
                            )
                        }
                    }
                    .screenPadding()
                    .padding(.bottom, Metrics.spacing24)
                    .readableWidth()
                }
            }
        }
    }

    private func recipeList(_ model: AddFoodViewModel) -> some View {
        Group {
            if model.recipes.isEmpty {
                EmptyStateView(
                    systemImage: "list.bullet.rectangle",
                    title: L("nutritionLog.recipes.emptyTitle"),
                    message: L("nutritionLog.recipes.emptyMessage")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.recipes, id: \.id) { recipe in
                            FoodPickerRow(
                                title: recipe.name,
                                subtitle: L("nutritionLog.recipes.servings", Units.formatDecimal(recipe.servingsCount, digits: recipe.servingsCount < 10 ? 1 : 0)),
                                macrosPer100: model.macrosPerServing(of: recipe),
                                basisUnit: .grams,
                                isFavorite: recipe.isFavorite,
                                onTap: { path.append(AddFoodRoute.portion(.recipe(recipe.id))) },
                                onShowDetails: { path.append(AddFoodRoute.detail(.recipe(recipe.id))) }
                            )
                            Divider().overlay(Color.appSeparator)
                        }
                    }
                    .screenPadding()
                    .readableWidth()
                }
            }
        }
    }

    private func myFoodList(_ model: AddFoodViewModel) -> some View {
        VStack(spacing: Metrics.spacing12) {
            Button {
                path.append(AddFoodRoute.customFood(nil))
            } label: {
                Label(L("nutritionLog.custom.create"), systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
            .screenPadding()

            if model.myFoods.isEmpty {
                EmptyStateView(
                    systemImage: "person.crop.square",
                    title: L("nutritionLog.custom.emptyTitle"),
                    message: L("nutritionLog.custom.emptyMessage")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.myFoods, id: \.id) { food in
                            FoodPickerRow(
                                title: food.name,
                                subtitle: food.brand,
                                macrosPer100: food.macrosPer100,
                                basisUnit: food.basisUnit,
                                isFavorite: food.isFavorite,
                                onTap: { path.append(AddFoodRoute.portion(.stored(food.id))) },
                                onShowDetails: { path.append(AddFoodRoute.detail(.stored(food.id))) }
                            )
                            Divider().overlay(Color.appSeparator)
                        }
                    }
                    .screenPadding()
                    .readableWidth()
                }
            }
        }
    }

    // MARK: Destinations

    @ViewBuilder
    private func destination(_ route: AddFoodRoute) -> some View {
        if let model {
            switch route {
            case .portion(let selection):
                if let basis = model.basis(for: selection) {
                    PortionEditorView(
                        basis: basis,
                        initial: model.initialPortion(for: selection),
                        slot: slot,
                        actionTitle: L("nutritionLog.action.addToMeal"),
                        onShowDetails: { path.append(AddFoodRoute.detail(selection)) },
                        showsCancelButton: false
                    ) { portion, chosenSlot in
                        if model.log(selection, portion: portion, slot: chosenSlot) { dismiss() }
                    }
                } else {
                    missingFood
                }
            case .detail(let selection):
                if let basis = model.basis(for: selection) {
                    FoodDetailView(
                        basis: basis,
                        source: model.source(for: selection),
                        barcode: model.barcode(for: selection),
                        isFavorite: model.isFavorite(selection),
                        onToggleFavorite: isStored(selection) ? { model.toggleFavorite(selection) } : nil,
                        defaultSlot: slot,
                        initialPortion: model.initialPortion(for: selection),
                        onLog: { portion, chosenSlot in
                            if model.log(selection, portion: portion, slot: chosenSlot) { dismiss() }
                        }
                    )
                } else {
                    missingFood
                }
            case .customFood(let barcode):
                // The full editor in Nutrition/Library is the single custom-food screen: it also
                // handles micronutrients, named servings and editing later, so the barcode-not-found
                // path lands the user somewhere they can finish the job properly.
                CustomFoodEditorView(prefilledBarcode: barcode) { createdID in
                    model.reloadAfterCustomFoodCreated()
                    path.append(AddFoodRoute.portion(.stored(createdID)))
                }
            }
        } else {
            LoadingStateView(message: L("common.loading"))
        }
    }

    private var missingFood: some View {
        ErrorStateView(message: L("repo.error.notFound"), retryTitle: L("common.back")) {
            if !path.isEmpty { path.removeLast() }
        }
    }

    private func isStored(_ selection: FoodSelection) -> Bool {
        if case .stored = selection { return true }
        return false
    }

    // MARK: Barcode

    private func handle(_ outcome: BarcodeScanOutcome) {
        switch outcome {
        case .cancelled:
            break
        case .found(let result):
            path.append(AddFoodRoute.portion(.result(result)))
        case .foundStored(let id):
            path.append(AddFoodRoute.portion(.stored(id)))
        case .notFound(let barcode):
            path.append(AddFoodRoute.customFood(barcode))
        }
    }
}

// MARK: - Saved meal row

/// A saved meal, logged in a single tap. The whole point of saving a meal is that replaying it
/// should cost one interaction, so the row itself is the log button and the menu carries the rest.
struct SavedMealRow: View {
    let name: String
    let itemCount: Int
    let macros: MacroNutrients
    var isFavorite: Bool = false
    let onLog: () -> Void
    let onLogInto: (MealSlot) -> Void
    let onDelete: () -> Void

    @Environment(\.displayFormatter) private var formatter
    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(spacing: Metrics.spacing8) {
            Button(action: onLog) {
                HStack(alignment: .top, spacing: Metrics.spacing12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Metrics.spacing4) {
                            Text(name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.appTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            if isFavorite {
                                Image(systemName: "heart.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Color.appAccent)
                                    .accessibilityHidden(true)
                            }
                        }
                        Text(L("nutritionLog.savedMeals.itemCount", itemCount))
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                        MacroSummaryLine(macros: macros, font: .caption2)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(formatter.energy(macros.kilocalories))
                        .font(.appNumeric(17))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(Metrics.spacing12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L("nutritionLog.a11y.savedMeal", name, itemCount, formatter.energy(macros.kilocalories)))
            .accessibilityHint(L("nutritionLog.a11y.savedMealHint"))

            Menu {
                Menu {
                    ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                        Button {
                            onLogInto(slot)
                        } label: {
                            Label(L(slot.localizationKey), systemImage: slot.symbolName)
                        }
                    }
                } label: {
                    Label(L("nutritionLog.action.logToMeal"), systemImage: "fork.knife")
                }
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label(L("common.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L("nutritionLog.a11y.savedMealActions", name))
            .padding(.trailing, Metrics.spacing4)
        }
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .strokeBorder(Color.appSeparator.opacity(0.6), lineWidth: 0.5)
        )
        .confirmationDialog(
            L("nutritionLog.savedMeals.deleteConfirm", name),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(L("common.delete"), role: .destructive, action: onDelete)
            Button(L("common.cancel"), role: .cancel) {}
        }
    }
}

// MARK: - Custom food


#Preview("Add food") {
    PreviewHost(scenario: .seasonedUser) {
        AddFoodFlowView(slot: .lunch, dayKey: DayKey.today)
    }
}
