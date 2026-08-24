import SwiftUI
import SwiftData

private struct EditingRecipe: Identifiable, Hashable {
    let id: UUID
}

private struct LoggingRecipe: Identifiable, Hashable {
    let id: UUID
    let name: String
    let servingsCount: Double
}

/// The user's recipes, priced per serving.
///
/// A recipe is logged as a number of servings rather than as its ingredients: the user ate "chilli",
/// and a diary that expands it into eleven rows of tinned tomatoes is unreadable.
struct RecipeListView: View {
    var dayKey: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model: RecipeListViewModel
    @State private var editingRecipe: EditingRecipe?
    @State private var loggingRecipe: LoggingRecipe?
    @State private var isCreatingRecipe = false

    init(dayKey: String = DayKey.today) {
        self.dayKey = dayKey
        _model = State(initialValue: RecipeListViewModel(dayKey: dayKey))
    }

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L("nutritionLibrary.recipes.title"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreatingRecipe = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text(L("nutritionLibrary.recipes.newTitle")))
                }
            }
            .task { await model.load(context: modelContext) }
            .sheet(isPresented: $isCreatingRecipe) {
                NavigationStack {
                    RecipeEditorView { Task { await model.load(context: modelContext) } }
                }
            }
            .sheet(item: $editingRecipe) { editing in
                NavigationStack {
                    RecipeEditorView(recipeID: editing.id) {
                        Task { await model.load(context: modelContext) }
                    }
                }
            }
            .sheet(item: $loggingRecipe) { recipe in
                RecipeServingSheet(recipe: recipe) { servings, slot in
                    Task { await model.log(id: recipe.id, servings: servings, to: slot) }
                }
                .presentationDetents([.medium])
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
                retry: { Task { await model.load(context: modelContext) } }
            )
        case .ready:
            ScrollView {
                VStack(spacing: Metrics.spacing16) {
                    if let failure = model.actionFailure {
                        FailureBanner(explanation: failure) { model.clearFailure() }
                    }
                    if model.recipes.isEmpty {
                        EmptyStateView(
                            systemImage: "list.bullet.rectangle.portrait",
                            title: L("nutritionLibrary.recipes.emptyTitle"),
                            message: L("nutritionLibrary.recipes.emptyMessage")
                        ) {
                            Button(L("nutritionLibrary.recipes.newTitle")) { isCreatingRecipe = true }
                                .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
                                .frame(maxWidth: 280)
                        }
                    } else {
                        LazyVStack(spacing: Metrics.spacing12) {
                            ForEach(model.recipes) { recipe in
                                recipeCard(recipe)
                            }
                        }
                    }
                }
                .screenPadding()
                .padding(.vertical, Metrics.spacing16)
                .readableWidth()
            }
        }
    }

    private func recipeCard(_ recipe: RecipeSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                HStack(alignment: .top, spacing: Metrics.spacing8) {
                    VStack(alignment: .leading, spacing: Metrics.spacing4) {
                        Text(recipe.name)
                            .font(.appCardTitle)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle(for: recipe))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Metrics.spacing8)
                    if recipe.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.appAccent)
                            .accessibilityHidden(true)
                    }
                }

                InsetGroup {
                    VStack(alignment: .leading, spacing: Metrics.spacing4) {
                        Text(L("nutritionLibrary.recipes.perServing"))
                            .font(.appOverline)
                            .foregroundStyle(Color.appTextSecondary)
                        Text(macroLine(recipe.perServing))
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if recipe.unresolvedIngredientCount > 0 {
                    Text(L("nutritionLibrary.recipes.unresolvedIngredients", recipe.unresolvedIngredientCount))
                        .font(.caption)
                        .foregroundStyle(Color.appWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.lastLoggedRecipeID == recipe.id {
                    Label(L("nutritionLibrary.recipes.logged"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.appSuccess)
                }

                actionRow(recipe)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func actionRow(_ recipe: RecipeSummary) -> some View {
        HStack(spacing: Metrics.spacing8) {
            Menu {
                ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                    Button {
                        Task { await model.log(id: recipe.id, servings: 1, to: slot) }
                    } label: {
                        Label(L(slot.localizationKey), systemImage: slot.symbolName)
                    }
                }
                Divider()
                Button {
                    loggingRecipe = LoggingRecipe(
                        id: recipe.id, name: recipe.name, servingsCount: recipe.servingsCount
                    )
                } label: {
                    Label(L("nutritionLibrary.recipes.chooseAmount"), systemImage: "slider.horizontal.3")
                }
            } label: {
                Label(L("nutritionLibrary.recipes.logOne"), systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Metrics.minimumTapTarget)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                            .fill(Color.appNutrition)
                    )
            }
            .accessibilityLabel(Text(L("nutritionLibrary.recipes.logAccessibility", recipe.name)))

            Button {
                editingRecipe = EditingRecipe(id: recipe.id)
            } label: {
                Text(L("common.edit"))
            }
            .buttonStyle(SecondaryButtonStyle())
            .frame(maxWidth: 110)

            Menu {
                Button {
                    Task { await model.toggleFavorite(id: recipe.id) }
                } label: {
                    Label(
                        L(recipe.isFavorite ? "nutritionLibrary.meals.unfavorite" : "nutritionLibrary.meals.favorite"),
                        systemImage: recipe.isFavorite ? "star.slash" : "star"
                    )
                }
                Button(role: .destructive) {
                    Task { await model.delete(id: recipe.id) }
                } label: {
                    Label(L("common.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Color.appTextSecondary)
                    .minimumTapTarget()
            }
            .accessibilityLabel(Text(L("nutritionLibrary.recipes.moreAccessibility", recipe.name)))
        }
    }

    private func subtitle(for recipe: RecipeSummary) -> String {
        var text = L(
            "nutritionLibrary.recipes.subtitle",
            Units.formatDecimal(recipe.servingsCount, digits: 1, locale: formatter.locale),
            recipe.ingredientCount
        )
        if let minutes = recipe.preparationMinutes, minutes > 0 {
            text += " · " + L("nutritionLibrary.recipes.prepMinutes", minutes)
        }
        return text
    }

    private func macroLine(_ macros: MacroNutrients) -> String {
        L(
            "nutritionLibrary.common.macroLine",
            formatter.energy(macros.kilocalories),
            formatter.macro(macros.proteinG),
            formatter.macro(macros.carbsG),
            formatter.macro(macros.fatG)
        )
    }
}

// MARK: - Serving sheet

/// Logs an arbitrary number of servings into a chosen slot.
private struct RecipeServingSheet: View {
    let recipe: LoggingRecipe
    let onLog: (Double, MealSlot) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var servings: Double? = 1
    @State private var slot: MealSlot = .dinner

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing20) {
                    Text(L("nutritionLibrary.recipes.servingSheetMessage", recipe.name))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    NumberEntryField(
                        title: L("nutritionLibrary.recipes.servingsToLog"),
                        value: $servings,
                        range: InputValidation.portionQuantity.lowerBound...InputValidation.recipeServings.upperBound,
                        step: 0.5
                    )

                    SegmentedValuePicker(
                        title: L("nutritionLibrary.suggest.slot"),
                        values: MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex },
                        label: { L($0.localizationKey) },
                        selection: $slot
                    )

                    Button(L("nutritionLibrary.recipes.logButton")) {
                        onLog(max(0.01, servings ?? 1), slot)
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
                    .disabled((servings ?? 0) <= 0)
                }
                .screenPadding()
                .padding(.vertical, Metrics.spacing20)
                .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(L("nutritionLibrary.recipes.logTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
            }
        }
    }
}

#Preview("Recipes") {
    PreviewHost(scenario: .fullNutritionDay) {
        NavigationStack {
            RecipeListView()
        }
    }
}
