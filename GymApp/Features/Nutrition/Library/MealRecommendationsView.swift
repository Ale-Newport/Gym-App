import SwiftUI
import SwiftData

/// Suggests meals that fit what is left of the day.
///
/// The screen leads with what it is trying to fill rather than with the suggestions, because a
/// recommendation nobody can audit is a recommendation nobody should trust: the user sees the
/// calories and protein still open, the share of the day this meal usually carries, and the
/// exclusions being applied, before a single suggestion appears.
struct MealRecommendationsView: View {
    private let dayKey: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model: MealRecommendationsViewModel

    init(slot: MealSlot? = nil, dayKey: String = DayKey.today) {
        self.dayKey = dayKey
        _model = State(initialValue: MealRecommendationsViewModel(slot: slot, dayKey: dayKey))
    }

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L("nutritionLibrary.suggest.title"))
            .task { await model.load(context: modelContext) }
            // The slot is a filter, not a navigation event: changing it re-runs the recommender
            // against the same day rather than pushing anything.
            .task(id: model.slot) { await model.reloadIfNeeded(context: modelContext) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("nutritionLibrary.suggest.loading"))
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
                    slotPicker
                    if model.isMissingTarget {
                        missingTargetState
                    } else {
                        if let plan = model.plan {
                            briefCard(plan)
                            if !plan.exclusions.isEmpty {
                                exclusionsCard(plan.exclusions)
                            }
                        }
                        if model.suggestions.isEmpty {
                            emptySuggestionsState
                        } else {
                            LazyVStack(spacing: Metrics.spacing12) {
                                ForEach(model.suggestions) { suggestion in
                                    suggestionCard(suggestion)
                                }
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

    private var slotPicker: some View {
        SegmentedValuePicker(
            title: L("nutritionLibrary.suggest.slot"),
            values: MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex },
            label: { L($0.localizationKey) },
            selection: Binding(get: { model.slot }, set: { model.slot = $0 })
        )
    }

    // MARK: - The brief

    /// What the recommender is aiming at. Deliberately the first thing on the screen.
    private func briefCard(_ plan: MealSuggestionContext) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(
                    title: L("nutritionLibrary.suggest.briefTitle"),
                    subtitle: L("nutritionLibrary.suggest.briefSubtitle", L(plan.slot.localizationKey))
                ) { EmptyView() }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Metrics.spacing12) { remainingTiles(plan) }
                    Grid(alignment: .leading, horizontalSpacing: Metrics.spacing12, verticalSpacing: Metrics.spacing12) {
                        GridRow {
                            remainingEnergyTile(plan)
                            remainingProteinTile(plan)
                        }
                        GridRow {
                            remainingCarbsTile(plan)
                            remainingFatTile(plan)
                        }
                    }
                }

                ExplanationNote(
                    text: L(
                        "nutritionLibrary.suggest.brief",
                        formatter.energy(max(0, plan.remaining.kilocalories)),
                        formatter.macro(max(0, plan.remaining.proteinG)),
                        NutritionFormat.percent(plan.slotShare),
                        L(plan.slot.localizationKey)
                    ),
                    systemImage: "target",
                    tint: .appNutrition
                )
            }
        }
    }

    @ViewBuilder
    private func remainingTiles(_ plan: MealSuggestionContext) -> some View {
        remainingEnergyTile(plan)
        remainingProteinTile(plan)
        remainingCarbsTile(plan)
        remainingFatTile(plan)
    }

    private func remainingEnergyTile(_ plan: MealSuggestionContext) -> some View {
        StatTile(
            value: formatter.energy(plan.remaining.kilocalories, includeUnit: false),
            label: L("nutritionLibrary.suggest.remainingEnergy"),
            caption: formatter.energyUnitLabel,
            tint: plan.remaining.kilocalories < 0 ? .appWarning : .appNutrition
        )
    }

    private func remainingProteinTile(_ plan: MealSuggestionContext) -> some View {
        StatTile(
            value: formatter.macro(plan.remaining.proteinG),
            label: L("nutritionLibrary.food.protein")
        )
    }

    private func remainingCarbsTile(_ plan: MealSuggestionContext) -> some View {
        StatTile(
            value: formatter.macro(plan.remaining.carbsG),
            label: L("nutritionLibrary.food.carbs")
        )
    }

    private func remainingFatTile(_ plan: MealSuggestionContext) -> some View {
        StatTile(
            value: formatter.macro(plan.remaining.fatG),
            label: L("nutritionLibrary.food.fat")
        )
    }

    /// Diet, allergens, intolerances and personal exclusions, shown as the hard filters they are.
    private func exclusionsCard(_ exclusions: [String]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                SectionHeader(
                    title: L("nutritionLibrary.suggest.exclusionsTitle"),
                    subtitle: L("nutritionLibrary.suggest.exclusionsMessage")
                ) { EmptyView() }
                FlowLayout {
                    ForEach(exclusions, id: \.self) { tag in
                        Chip(title: tagLabel(tag), systemImage: "nosign", tint: .appWarning)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Vocabulary tags have translations; anything the user typed themselves is shown as typed.
    private func tagLabel(_ tag: String) -> String {
        let known = FoodTagVocabulary.dietary
            .union(FoodTagVocabulary.allergen)
            .union(FoodTagVocabulary.role)
        return known.contains(tag) ? L("nutritionLibrary.tag.\(tag)") : tag
    }

    // MARK: - Suggestions

    private func suggestionCard(_ suggestion: MealSuggestion) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                VStack(alignment: .leading, spacing: Metrics.spacing4) {
                    if let titleKey = suggestion.titleKey {
                        Text(L(titleKey))
                            .font(.appOverline)
                            .foregroundStyle(Color.appNutrition)
                    }
                    Text(suggestion.title)
                        .font(.appCardTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: Metrics.spacing6) {
                    ForEach(Array(suggestion.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                            Text(item.name)
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Metrics.spacing8)
                            Text(portionLabel(item))
                                .font(.appNumeric(15, weight: .medium))
                                .foregroundStyle(Color.appTextSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Text(macroLine(suggestion.macros))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(suggestion.reasons.enumerated()), id: \.offset) { _, reason in
                    ExplanationNote(text: reason.text)
                }

                if model.lastLoggedSuggestionID == suggestion.id {
                    Label(L("nutritionLibrary.suggest.logged", L(model.slot.localizationKey)), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.appSuccess)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await model.log(suggestion) }
                } label: {
                    Text(L("nutritionLibrary.suggest.log", L(model.slot.localizationKey)))
                }
                .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
                .accessibilityLabel(Text(L(
                    "nutritionLibrary.suggest.logAccessibility",
                    suggestion.title,
                    L(model.slot.localizationKey)
                )))
            }
        }
        .transition(reduceMotion ? .identity : .opacity)
        .accessibilityElement(children: .contain)
    }

    private func portionLabel(_ item: SuggestedFoodPortion) -> String {
        switch item.unit {
        case .grams:
            return Units.formatDecimal(item.quantity, digits: 0, locale: formatter.locale) + " g"
        case .milliliters:
            return Units.formatDecimal(item.quantity, digits: 0, locale: formatter.locale) + " ml"
        case .piece:
            return L("nutritionLibrary.suggest.pieces", Int(item.quantity.rounded()))
        case .serving:
            return L("nutritionLibrary.suggest.servings", Int(item.quantity.rounded()))
        }
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

    // MARK: - The states that are not a list

    private var missingTargetState: some View {
        EmptyStateView(
            systemImage: "target",
            title: L("nutritionLibrary.suggest.noTargetTitle"),
            message: L("nutritionLibrary.suggest.noTargetMessage")
        ) {
            NavigationLink {
                NutritionTargetsView()
            } label: {
                Text(L("nutritionLibrary.targets.title"))
                    .font(.headline)
                    .foregroundStyle(Color.appOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Metrics.gymTapTarget)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                            .fill(Color.appNutrition)
                    )
            }
            .frame(maxWidth: 280)
        }
    }

    /// Nothing to suggest is a real answer, not a failure — but it always says *why*, and always
    /// leaves somewhere to go.
    private var emptySuggestionsState: some View {
        EmptyStateView(
            systemImage: model.hasNoRoomLeft ? "checkmark.circle" : "fork.knife",
            title: L(model.hasNoRoomLeft
                ? "nutritionLibrary.suggest.dayFullTitle"
                : "nutritionLibrary.suggest.noneTitle"),
            message: L(model.hasNoRoomLeft
                ? "nutritionLibrary.suggest.dayFullMessage"
                : "nutritionLibrary.suggest.noneMessage")
        ) {
            VStack(spacing: Metrics.spacing8) {
                NavigationLink {
                    SavedMealsView(dayKey: dayKey)
                } label: {
                    Text(L("nutritionLibrary.meals.title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Metrics.minimumTapTarget)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                                .fill(Color.appFill)
                        )
                }
                NavigationLink {
                    RecipeListView(dayKey: dayKey)
                } label: {
                    Text(L("nutritionLibrary.recipes.title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Metrics.minimumTapTarget)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                                .fill(Color.appFill)
                        )
                }
            }
            .frame(maxWidth: 280)
        }
    }
}

#Preview("Meal suggestions") {
    PreviewHost(scenario: .emptyNutritionDay) {
        NavigationStack {
            MealRecommendationsView(slot: .lunch)
        }
    }
}
