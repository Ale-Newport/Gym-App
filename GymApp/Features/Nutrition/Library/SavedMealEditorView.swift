import SwiftUI
import SwiftData

/// Builds or edits a saved meal: a named set of portions that can be logged into any slot in one
/// tap.
///
/// Quantities are edited here rather than at log time on purpose. A saved meal only earns its place
/// if logging it takes one tap, and that is only true when the portions were already right.
struct SavedMealEditorView: View {
    let mealID: UUID?
    var defaultSlot: MealSlot
    var onSaved: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.dismiss) private var dismiss

    @State private var model = SavedMealEditorViewModel()
    @State private var isPickingFood = false

    init(mealID: UUID? = nil, defaultSlot: MealSlot = .breakfast, onSaved: (() -> Void)? = nil) {
        self.mealID = mealID
        self.defaultSlot = defaultSlot
        self.onSaved = onSaved
    }

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L(model.isExistingMeal ? "nutritionLibrary.meals.editTitle" : "nutritionLibrary.meals.newTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) { save() }
                        .disabled(!model.canSave)
                }
            }
            .task { await model.load(context: modelContext, mealID: mealID, defaultSlot: defaultSlot) }
            .sheet(isPresented: $isPickingFood) {
                LibraryFoodPickerSheet(title: L("nutritionLibrary.picker.addFood")) { draft in
                    model.add(draft)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("common.loading"))
        case .failed(let explanation):
            ErrorStateView(
                message: explanation.text,
                retryTitle: L("common.retry"),
                retry: { Task { await model.load(context: modelContext, mealID: mealID, defaultSlot: defaultSlot) } }
            )
        case .ready:
            editor
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(spacing: Metrics.spacing16) {
                if let failure = model.saveFailure {
                    FailureBanner(explanation: failure) { model.clearFailure() }
                }

                Card {
                    VStack(alignment: .leading, spacing: Metrics.spacing16) {
                        VStack(alignment: .leading, spacing: Metrics.spacing6) {
                            Text(L("nutritionLibrary.meals.name"))
                                .font(.appOverline)
                                .foregroundStyle(Color.appTextSecondary)
                            TextField(L("nutritionLibrary.meals.namePlaceholder"), text: $model.name)
                                .font(.body)
                                .textInputAutocapitalization(.sentences)
                                .frame(minHeight: Metrics.minimumTapTarget)
                                .padding(.horizontal, Metrics.spacing12)
                                .background(
                                    Color.appFill,
                                    in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                                )
                                .accessibilityLabel(Text(L("nutritionLibrary.meals.name")))
                        }
                        SegmentedValuePicker(
                            title: L("nutritionLibrary.meals.defaultSlot"),
                            values: MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex },
                            label: { L($0.localizationKey) },
                            selection: $model.slot
                        )
                    }
                }

                itemsCard

                if !model.items.isEmpty {
                    MacroTotalsCard(
                        title: L("nutritionLibrary.meals.total"),
                        macros: model.totals,
                        formatter: formatter
                    )
                }
            }
            .screenPadding()
            .padding(.vertical, Metrics.spacing16)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var itemsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(
                    title: L("nutritionLibrary.meals.foods"),
                    subtitle: model.items.isEmpty ? nil : L("nutritionLibrary.meals.foodCount", model.items.count)
                ) {
                    Button {
                        isPickingFood = true
                    } label: {
                        Image(systemName: "plus").minimumTapTarget()
                    }
                    .accessibilityLabel(Text(L("nutritionLibrary.picker.addFood")))
                }

                if model.droppedItemCount > 0 {
                    Text(L("nutritionLibrary.meals.droppedItems", model.droppedItemCount))
                        .font(.footnote)
                        .foregroundStyle(Color.appWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.items.isEmpty {
                    EmptyStateView(
                        systemImage: "fork.knife",
                        title: L("nutritionLibrary.meals.emptyEditorTitle"),
                        message: L("nutritionLibrary.meals.emptyEditorMessage")
                    ) {
                        Button(L("nutritionLibrary.picker.addFood")) { isPickingFood = true }
                            .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
                            .frame(maxWidth: 280)
                    }
                } else {
                    // A saved meal is a handful of foods, so a LazyVStack of value-typed rows is both
                    // cheaper and easier to lay out than a nested List.
                    LazyVStack(spacing: Metrics.spacing12) {
                        ForEach($model.items) { $item in
                            PortionDraftRow(draft: $item, formatter: formatter) {
                                model.items.removeAll { $0.id == item.id }
                            }
                        }
                    }
                }
            }
        }
    }

    private func save() {
        Task {
            if await model.save() {
                onSaved?()
                Haptics.success()
                dismiss()
            } else {
                Haptics.error()
            }
        }
    }
}

// MARK: - Shared library components

/// One editable portion. Shared by the saved-meal and recipe editors, which need exactly the same
/// control: a food, an amount, and a unit the food actually supports.
struct PortionDraftRow: View {
    @Binding var draft: NutritionPortionDraft
    let formatter: DisplayFormatter
    let onRemove: () -> Void

    var body: some View {
        InsetGroup {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                HStack(alignment: .top, spacing: Metrics.spacing8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let brand = draft.brand, !brand.isEmpty {
                            Text(brand)
                                .font(.caption)
                                .foregroundStyle(Color.appTextTertiary)
                        }
                    }
                    Spacer(minLength: Metrics.spacing8)
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(Color.appDanger)
                            .minimumTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("nutritionLibrary.picker.removeFood", draft.name)))
                }

                HStack(alignment: .bottom, spacing: Metrics.spacing12) {
                    NumberEntryField(
                        title: L("nutritionLibrary.picker.amount"),
                        value: Binding(
                            get: { draft.quantity },
                            set: { draft.quantity = $0 ?? 0 }
                        ),
                        range: 0...InputValidation.portionQuantity.upperBound,
                        step: draft.unit.isMassOrVolume ? 10 : 1,
                        showsStepper: false
                    )
                    unitPicker
                }

                Text(macroSummary)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(macroSummary))
            }
        }
    }

    @ViewBuilder
    private var unitPicker: some View {
        let units = draft.availableUnits
        if units.count > 1 {
            Menu {
                ForEach(units) { unit in
                    Button {
                        draft.unit = unit
                        if unit == .serving, draft.servingIndex == nil { draft.servingIndex = 0 }
                    } label: {
                        if draft.unit == unit {
                            Label(L(unit.localizationKey), systemImage: "checkmark")
                        } else {
                            Text(L(unit.localizationKey))
                        }
                    }
                }
                if draft.unit == .serving, draft.servings.count > 1 {
                    Divider()
                    ForEach(Array(draft.servings.enumerated()), id: \.element.id) { index, serving in
                        Button(serving.name) { draft.servingIndex = index }
                    }
                }
            } label: {
                HStack(spacing: Metrics.spacing4) {
                    Text(unitLabel)
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .foregroundStyle(Color.appTextPrimary)
                .padding(.horizontal, Metrics.spacing12)
                .frame(minHeight: Metrics.gymTapTarget)
                .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
            }
            .accessibilityLabel(Text(L("nutritionLibrary.picker.unit")))
            .accessibilityValue(Text(unitLabel))
        } else {
            Text(unitLabel)
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .frame(minHeight: Metrics.gymTapTarget)
                .accessibilityLabel(Text(L("nutritionLibrary.picker.unit")))
                .accessibilityValue(Text(unitLabel))
        }
    }

    private var unitLabel: String {
        if draft.unit == .serving,
           let index = draft.servingIndex,
           draft.servings.indices.contains(index) {
            return draft.servings[index].name
        }
        return L(draft.unit.localizationKey)
    }

    private var macroSummary: String {
        let macros = draft.macros
        return L(
            "nutritionLibrary.picker.macroSummary",
            formatter.energy(macros.kilocalories),
            formatter.macro(macros.proteinG),
            formatter.macro(macros.carbsG),
            formatter.macro(macros.fatG)
        )
    }
}

/// The running total of a meal or a recipe.
struct MacroTotalsCard: View {
    let title: String
    var subtitle: String?
    let macros: MacroNutrients
    let formatter: DisplayFormatter

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(title: title, subtitle: subtitle) { EmptyView() }
                // Four tiles across stop fitting long before the largest accessibility sizes, so the
                // row folds into a 2×2 grid rather than squeezing the numbers into illegibility.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Metrics.spacing12) { tiles }
                    Grid(alignment: .leading, horizontalSpacing: Metrics.spacing12, verticalSpacing: Metrics.spacing12) {
                        GridRow { energyTile; proteinTile }
                        GridRow { carbsTile; fatTile }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tiles: some View {
        energyTile
        proteinTile
        carbsTile
        fatTile
    }

    private var energyTile: some View {
        StatTile(
            value: formatter.energy(macros.kilocalories, includeUnit: false),
            label: formatter.energyUnitLabel,
            tint: .appNutrition
        )
    }

    private var proteinTile: some View {
        StatTile(value: formatter.macro(macros.proteinG), label: L("nutritionLibrary.food.protein"))
    }

    private var carbsTile: some View {
        StatTile(value: formatter.macro(macros.carbsG), label: L("nutritionLibrary.food.carbs"))
    }

    private var fatTile: some View {
        StatTile(value: formatter.macro(macros.fatG), label: L("nutritionLibrary.food.fat"))
    }
}

/// A dismissible failure banner. Errors in an editor must never take the screen away from the user:
/// they have unsaved work on it.
struct FailureBanner: View {
    let explanation: Explanation
    let onDismiss: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Label {
                    Text(explanation.text)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.appWarning)
                }
                Button(L("common.done"), action: onDismiss)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Food picker

/// Picks a stored food and hands back an editable portion.
///
/// Distinct from the logging flow: nothing here is written to a diary. When the search comes up
/// empty the way forward is to create the food, which is the only honest answer for a food the
/// database has never heard of.
struct LibraryFoodPickerSheet: View {
    let title: String
    let onSelect: (NutritionPortionDraft) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.dismiss) private var dismiss

    @State private var model = LibraryFoodPickerViewModel()
    @State private var isCreatingFood = false
    @State private var createdFoodID: UUID?

    var body: some View {
        NavigationStack {
            content
                .background(Color.appBackground)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $model.query, prompt: Text(L("nutritionLibrary.picker.searchPrompt")))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("common.cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isCreatingFood = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(Text(L("nutritionLibrary.food.newTitle")))
                    }
                }
                .task(id: model.query) {
                    model.attach(modelContext)
                    // Debounced so a fetch does not run on every keystroke of a search.
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    await model.search()
                }
                // The newly created food is selected once the editor has finished closing: two
                // dismissals fired in the same run loop leave the sheet stack in a mess.
                .sheet(isPresented: $isCreatingFood, onDismiss: selectCreatedFood) {
                    NavigationStack {
                        CustomFoodEditorView { createdID in
                            createdFoodID = createdID
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("common.loading"))
        case .failed(let explanation):
            ErrorStateView(
                message: explanation.text,
                retryTitle: L("common.retry"),
                retry: { Task { await model.search() } }
            )
        case .ready:
            if model.rows.isEmpty {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: L("nutritionLibrary.picker.emptyTitle"),
                    message: L("nutritionLibrary.picker.emptyMessage")
                ) {
                    Button(L("nutritionLibrary.food.newTitle")) { isCreatingFood = true }
                        .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
                        .frame(maxWidth: 280)
                }
            } else {
                List(model.rows) { row in
                    Button {
                        select(id: row.id)
                    } label: {
                        foodRow(row)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.appSurface)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func foodRow(_ row: NutritionFoodRow) -> some View {
        HStack(spacing: Metrics.spacing12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle(for: row))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Metrics.spacing8)
            if row.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: Metrics.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.name). \(subtitle(for: row))"))
        .accessibilityAddTraits(.isButton)
    }

    private func subtitle(for row: NutritionFoodRow) -> String {
        let nutrition = L(
            "nutritionLibrary.picker.rowSummary",
            formatter.energy(row.kilocaloriesPer100),
            formatter.macro(row.proteinPer100),
            L(row.basisUnit == .milliliters ? "nutritionLibrary.food.per100ml" : "nutritionLibrary.food.per100g")
        )
        guard let brand = row.brand, !brand.isEmpty else { return nutrition }
        return "\(brand) · \(nutrition)"
    }

    private func select(id: UUID) {
        guard let draft = model.draft(for: id) else { return }
        onSelect(draft)
        Haptics.tap()
        dismiss()
    }

    private func selectCreatedFood() {
        guard let createdFoodID else { return }
        self.createdFoodID = nil
        select(id: createdFoodID)
    }
}

#Preview("Saved meal editor") {
    PreviewHost(scenario: .fullNutritionDay) {
        NavigationStack {
            SavedMealEditorView(defaultSlot: .breakfast)
        }
    }
}
