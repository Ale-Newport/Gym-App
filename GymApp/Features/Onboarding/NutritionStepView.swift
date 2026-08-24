import SwiftUI

/// Whether the app should track food at all, and if so, what it may suggest.
///
/// The first question is the real one. Calorie tracking suits some people and actively harms
/// others, so it is offered as a decision rather than assumed: turning it off skips the energy
/// target entirely — no number is written, and the nutrition tab stays out of the way.
///
/// Everything below the toggle is a hard filter, not a preference score. Allergens, intolerances
/// and diet all end up in the same `forbiddenFoodTags` set, because the meal recommender must never
/// treat "I am allergic to peanuts" as something to weigh against convenience.
struct NutritionStepView: View {
    @Bindable var model: OnboardingViewModel

    @State private var customTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            enableSection

            if model.nutritionEnabled {
                dietSection
                allergenSection
                intoleranceSection
                exclusionSection
                mealsSection
                paceSection
                budgetSection
            }
        }
    }

    // MARK: - Enable

    private var enableSection: some View {
        OnboardingSection(L("onboarding.nutrition.enable"), subtitle: L("onboarding.nutrition.enable.detail")) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Toggle(isOn: $model.nutritionEnabled) {
                    Text(L("onboarding.nutrition.enable.toggle"))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(Color.appNutrition)
                .frame(minHeight: Metrics.minimumTapTarget)

                if !model.nutritionEnabled {
                    OnboardingInlineHint(message: L("onboarding.nutrition.enable.off"))
                }
            }
        }
    }

    // MARK: - Diet

    private var dietSection: some View {
        OnboardingSection(L("onboarding.nutrition.diet"), subtitle: L("onboarding.nutrition.diet.detail")) {
            VStack(spacing: Metrics.spacing8) {
                ForEach(DietType.allCases) { diet in
                    OnboardingChoiceRow(
                        title: L(diet.localizationKey),
                        detail: diet.excludedTags.isEmpty ? nil : excludedTagSummary(diet.excludedTags),
                        isSelected: model.dietType == diet,
                        tint: .appNutrition
                    ) {
                        model.dietType = diet
                    }
                }
            }
        }
    }

    private func excludedTagSummary(_ tags: Set<String>) -> String {
        let names = tags.sorted().map { L("onboarding.foodTag.\($0)") }.joined(separator: ", ")
        return L("onboarding.nutrition.diet.excludes", names)
    }

    // MARK: - Allergens

    private var allergenSection: some View {
        OnboardingSection(
            title: L("onboarding.nutrition.allergens"),
            subtitle: L("onboarding.nutrition.allergens.detail"),
            accessory: {
                if !model.allergenTags.isEmpty {
                    OnboardingSkipButton(title: L("common.clear")) { model.allergenTags = [] }
                }
            },
            content: {
                FlowLayout {
                    ForEach(OnboardingOptions.allergenTags, id: \.self) { tag in
                        OnboardingChip(
                            title: L("onboarding.foodTag.\(tag)"),
                            isSelected: model.allergenTags.contains(tag),
                            tint: .appDanger
                        ) {
                            model.toggleTag(tag, in: \.allergenTags)
                        }
                    }
                }
            }
        )
    }

    // MARK: - Intolerances

    private var intoleranceSection: some View {
        OnboardingSection(
            title: L("onboarding.nutrition.intolerances"),
            subtitle: L("onboarding.nutrition.intolerances.detail"),
            accessory: {
                if !model.intoleranceTags.isEmpty {
                    OnboardingSkipButton(title: L("common.clear")) { model.intoleranceTags = [] }
                }
            },
            content: {
                FlowLayout {
                    ForEach(OnboardingOptions.intoleranceTags, id: \.self) { tag in
                        OnboardingChip(
                            title: L("onboarding.foodTag.\(tag)"),
                            isSelected: model.intoleranceTags.contains(tag),
                            tint: .appWarning
                        ) {
                            model.toggleTag(tag, in: \.intoleranceTags)
                        }
                    }
                }
            }
        )
    }

    // MARK: - Excluded foods

    private var exclusionSection: some View {
        OnboardingSection(L("onboarding.nutrition.excluded"), subtitle: L("onboarding.nutrition.excluded.detail")) {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                FlowLayout {
                    ForEach(OnboardingOptions.excludableFoodTags, id: \.self) { tag in
                        OnboardingChip(
                            title: L("onboarding.foodTag.\(tag)"),
                            isSelected: model.excludedFoodTags.contains(tag),
                            tint: .appNutrition
                        ) {
                            model.toggleTag(tag, in: \.excludedFoodTags)
                        }
                    }
                    ForEach(model.customFoodTags, id: \.self) { tag in
                        OnboardingChip(
                            title: tag.localizedCapitalized,
                            systemImage: "xmark",
                            isSelected: true,
                            tint: .appNutrition
                        ) {
                            model.removeCustomFoodTag(tag)
                        }
                    }
                }

                HStack(spacing: Metrics.spacing8) {
                    OnboardingTextField(
                        placeholder: L("onboarding.nutrition.excluded.placeholder"),
                        text: $customTag,
                        accessibilityLabel: L("onboarding.nutrition.excluded.add"),
                        systemImage: "tag",
                        submitLabel: .done,
                        onSubmit: addCustomTag
                    )
                    Button(action: addCustomTag) {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(customTag.isEmpty ? Color.appTextTertiary : Color.appNutrition)
                            .frame(width: Metrics.gymTapTarget, height: Metrics.gymTapTarget)
                            .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(customTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(Text(L("onboarding.nutrition.excluded.add")))
                }

                OnboardingInlineHint(message: L("onboarding.nutrition.excluded.hint"))
            }
        }
    }

    private func addCustomTag() {
        model.addCustomFoodTag(customTag)
        customTag = ""
    }

    // MARK: - Meals

    private var mealsSection: some View {
        OnboardingSection(L("onboarding.nutrition.meals"), subtitle: L("onboarding.nutrition.meals.detail")) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                SegmentedValuePicker(
                    title: nil,
                    values: OnboardingSchedule.mealsPerDayOptions,
                    label: { String($0) },
                    selection: $model.mealsPerDay
                )
                if let hint = model.hint(for: "mealsPerDay") {
                    OnboardingInlineHint(message: hint, tint: .appWarning)
                } else {
                    OnboardingInlineHint(
                        message: model.mealsPerDay >= 4
                            ? L("onboarding.nutrition.meals.fourPlus")
                            : L("onboarding.nutrition.meals.three")
                    )
                }
            }
        }
    }

    // MARK: - Pace

    private var paceSection: some View {
        OnboardingSection(L("onboarding.nutrition.pace"), subtitle: L("onboarding.nutrition.pace.detail")) {
            VStack(spacing: Metrics.spacing8) {
                ForEach(NutritionGoalPace.allCases) { pace in
                    OnboardingChoiceRow(
                        title: L(pace.localizationKey),
                        detail: paceDetail(pace),
                        isSelected: model.nutritionPace == pace,
                        tint: .appNutrition
                    ) {
                        model.nutritionPace = pace
                    }
                }
            }
        }
    }

    /// Restates the pace as the weekly change it implies for this particular body mass, because
    /// "moderate" means nothing until it is a number on the user's own scale.
    private func paceDetail(_ pace: NutritionGoalPace) -> String {
        guard let weight = model.currentWeightKg, weight > 0 else { return L("onboarding.nutrition.pace.generic") }
        let weekly = weight * pace.weeklyBodyMassFraction
        return L("onboarding.nutrition.pace.weekly", Units.formatWeight(kilograms: weekly, unit: model.weightUnit, fractionDigits: 2))
    }

    // MARK: - Budget

    private var budgetSection: some View {
        OnboardingSection(
            title: L("onboarding.nutrition.budget"),
            subtitle: L("onboarding.nutrition.budget.detail"),
            accessory: {
                if model.wantsBudget {
                    OnboardingSkipButton(title: L("common.skip")) {
                        model.wantsBudget = false
                        model.weeklyFoodBudget = nil
                    }
                }
            },
            content: {
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    Toggle(isOn: $model.wantsBudget) {
                        Text(L("onboarding.nutrition.budget.toggle"))
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tint(Color.appNutrition)
                    .frame(minHeight: Metrics.minimumTapTarget)

                    if model.wantsBudget {
                        NumberEntryField(
                            title: L("onboarding.nutrition.budget.amount"),
                            value: $model.weeklyFoodBudget,
                            allowsDecimals: true,
                            range: 0...100000,
                            step: 5,
                            showsStepper: false
                        )
                        if let hint = model.hint(for: "weeklyFoodBudget") {
                            OnboardingInlineHint(message: hint, tint: .appWarning)
                        } else {
                            OnboardingInlineHint(message: L("onboarding.nutrition.budget.currency"))
                        }
                    }
                }
            }
        )
    }
}

#Preview("Nutrition") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .nutrition) { model in
            NutritionStepView(model: model)
        }
    }
}
