import SwiftUI
import SwiftData

/// Creates or edits a recipe: ingredients, how many servings it makes, and the per-serving
/// nutrition that falls out of those two.
///
/// Per-serving figures are computed, never typed. A recipe whose stated nutrition can drift away
/// from its ingredients is worse than no recipe at all, because it looks authoritative while being
/// wrong — so correcting an ingredient here immediately corrects every serving figure and every
/// future log.
struct RecipeEditorView: View {
    let recipeID: UUID?
    var onSaved: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.dismiss) private var dismiss

    @State private var model = RecipeEditorViewModel()
    @State private var isPickingFood = false

    init(recipeID: UUID? = nil, onSaved: (() -> Void)? = nil) {
        self.recipeID = recipeID
        self.onSaved = onSaved
    }

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L(model.isExistingRecipe ? "nutritionLibrary.recipes.editTitle" : "nutritionLibrary.recipes.newTitle"))
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
            .task { await model.load(context: modelContext, recipeID: recipeID) }
            .sheet(isPresented: $isPickingFood) {
                LibraryFoodPickerSheet(title: L("nutritionLibrary.recipes.addIngredient")) { draft in
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
                retry: { Task { await model.load(context: modelContext, recipeID: recipeID) } }
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
                detailsCard
                ingredientsCard
                if !model.ingredients.isEmpty {
                    nutritionCard
                }
                instructionsCard
            }
            .screenPadding()
            .padding(.vertical, Metrics.spacing16)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var detailsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                VStack(alignment: .leading, spacing: Metrics.spacing6) {
                    Text(L("nutritionLibrary.recipes.name"))
                        .font(.appOverline)
                        .foregroundStyle(Color.appTextSecondary)
                    TextField(L("nutritionLibrary.recipes.namePlaceholder"), text: $model.name)
                        .font(.body)
                        .textInputAutocapitalization(.sentences)
                        .frame(minHeight: Metrics.minimumTapTarget)
                        .padding(.horizontal, Metrics.spacing12)
                        .background(
                            Color.appFill,
                            in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                        )
                        .accessibilityLabel(Text(L("nutritionLibrary.recipes.name")))
                }
                NumberEntryField(
                    title: L("nutritionLibrary.recipes.servingsCount"),
                    value: $model.servingsCount,
                    range: InputValidation.recipeServings.lowerBound...InputValidation.recipeServings.upperBound,
                    step: 1
                )
                IntegerEntryField(
                    title: L("nutritionLibrary.recipes.preparationMinutes"),
                    value: $model.preparationMinutes,
                    range: 0...1440,
                    step: 5,
                    unit: L("common.min")
                )
            }
        }
    }

    private var ingredientsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(
                    title: L("nutritionLibrary.recipes.ingredients"),
                    subtitle: model.ingredients.isEmpty
                        ? nil
                        : L("nutritionLibrary.recipes.ingredientCount", model.ingredients.count)
                ) {
                    Button {
                        isPickingFood = true
                    } label: {
                        Image(systemName: "plus").minimumTapTarget()
                    }
                    .accessibilityLabel(Text(L("nutritionLibrary.recipes.addIngredient")))
                }

                if model.droppedIngredientCount > 0 {
                    Text(L("nutritionLibrary.recipes.droppedIngredients", model.droppedIngredientCount))
                        .font(.footnote)
                        .foregroundStyle(Color.appWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.ingredients.isEmpty {
                    EmptyStateView(
                        systemImage: "carrot",
                        title: L("nutritionLibrary.recipes.emptyEditorTitle"),
                        message: L("nutritionLibrary.recipes.emptyEditorMessage")
                    ) {
                        Button(L("nutritionLibrary.recipes.addIngredient")) { isPickingFood = true }
                            .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
                            .frame(maxWidth: 280)
                    }
                } else {
                    LazyVStack(spacing: Metrics.spacing12) {
                        ForEach($model.ingredients) { $ingredient in
                            PortionDraftRow(draft: $ingredient, formatter: formatter) {
                                model.ingredients.removeAll { $0.id == ingredient.id }
                            }
                        }
                    }
                }
            }
        }
    }

    private var nutritionCard: some View {
        VStack(spacing: Metrics.spacing12) {
            MacroTotalsCard(
                title: L("nutritionLibrary.recipes.perServing"),
                subtitle: L(
                    "nutritionLibrary.recipes.perServingHint",
                    Units.formatDecimal(max(0.25, model.servingsCount ?? 1), digits: 1, locale: formatter.locale)
                ),
                macros: model.perServing,
                formatter: formatter
            )
            MacroTotalsCard(
                title: L("nutritionLibrary.recipes.wholeRecipe"),
                macros: model.total,
                formatter: formatter
            )
        }
    }

    private var instructionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                SectionHeader(
                    title: L("nutritionLibrary.recipes.instructions"),
                    subtitle: L("common.optional")
                ) { EmptyView() }
                TextEditor(text: $model.instructions)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(Metrics.spacing8)
                    .background(
                        Color.appFill,
                        in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    )
                    .accessibilityLabel(Text(L("nutritionLibrary.recipes.instructions")))
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

#Preview("Recipe editor") {
    PreviewHost(scenario: .fullNutritionDay) {
        NavigationStack {
            RecipeEditorView()
        }
    }
}
