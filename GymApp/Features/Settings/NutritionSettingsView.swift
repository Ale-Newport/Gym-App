import SwiftUI

/// Everything that shapes what the app suggests you eat.
///
/// Diet, allergens, intolerances and personal exclusions all end up in one set of forbidden tags
/// that the meal recommender treats as hard filters — never as a score penalty — so a food carrying
/// any of them is not shown at all. That is stated on screen, because a filter the user believes is
/// a preference is a filter they will not trust.
struct NutritionSettingsView: View {
    @State private var model = SettingsViewModel()

    init() {}

    private var isEnabled: Bool { model.settings?.nutritionEnabled ?? true }

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)
                enableSection
                dietSection
                restrictionSection
                mealsSection
                waterSection
            }
        }
        .navigationTitle(L("settings.nutrition.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Master switch

    private var enableSection: some View {
        Section {
            Toggle(isOn: model.settingsBinding(\.nutritionEnabled, default: true)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("settings.nutrition.enabled"))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("settings.nutrition.enabled.detail"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.appNutrition)
            .frame(minHeight: Metrics.minimumTapTarget)

            if !isEnabled {
                SettingsFootnote(text: L("settings.nutrition.disabledExplainer"))
            }
        } header: {
            Text(L("settings.nutrition.section.enabled"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Diet

    private var dietSection: some View {
        Section {
            EnumPickerRow(
                title: L("settings.nutrition.diet"),
                values: DietType.allCases,
                label: { L($0.localizationKey) },
                selection: Binding(
                    get: { model.profile?.dietType ?? .omnivore },
                    set: { model.updateNutritionPreferences(dietType: $0) }
                )
            )
            let excluded = (model.profile?.dietType ?? .omnivore).excludedTags
            if excluded.isEmpty {
                SettingsFootnote(text: L("settings.nutrition.dietNoExclusions"))
            } else {
                SettingsFootnote(
                    text: L(
                        "settings.nutrition.dietExcludes",
                        excluded.sorted().map { L("settings.foodTag.\($0)") }.joined(separator: ", ")
                    )
                )
            }
        } header: {
            Text(L("settings.nutrition.section.diet"))
        }
        .listRowBackground(Color.appSurface)
        .disabled(!isEnabled)
    }

    // MARK: - Restrictions

    private var restrictionSection: some View {
        Section {
            tagPicker(
                title: L("settings.nutrition.allergens"),
                options: Self.allergenOptions,
                tint: .appDanger,
                selected: model.profile?.allergenTags ?? []
            ) { model.updateNutritionPreferences(allergenTags: $0) }

            tagPicker(
                title: L("settings.nutrition.intolerances"),
                options: Self.intoleranceOptions,
                tint: .appWarning,
                selected: model.profile?.intoleranceTags ?? []
            ) { model.updateNutritionPreferences(intoleranceTags: $0) }

            tagPicker(
                title: L("settings.nutrition.excludedFoods"),
                options: Self.excludableOptions,
                tint: .appNutrition,
                selected: model.profile?.excludedFoodTags ?? []
            ) { model.updateNutritionPreferences(excludedFoodTags: $0) }
        } header: {
            Text(L("settings.nutrition.section.restrictions"))
        } footer: {
            Text(L("settings.nutrition.restrictionsFooter"))
        }
        .listRowBackground(Color.appSurface)
        .disabled(!isEnabled)
    }

    private func tagPicker(
        title: String,
        options: [FoodTagOption],
        tint: Color,
        selected: [String],
        commit: @escaping ([String]) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text(title)
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
            ChipSelectionRow(
                values: options,
                label: { L("settings.foodTag.\($0.id)") },
                tint: tint,
                isSelected: { selected.contains($0.id) },
                toggle: { option in
                    var updated = selected
                    if let index = updated.firstIndex(of: option.id) {
                        updated.remove(at: index)
                    } else {
                        updated.append(option.id)
                    }
                    commit(updated)
                }
            )
            if selected.isEmpty {
                Text(L("common.none"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextTertiary)
            }
        }
        .padding(.vertical, Metrics.spacing4)
    }

    /// The three tag vocabularies the food layer agrees on. Offering anything outside them would
    /// produce a filter that silently matches nothing.
    private static let allergenOptions = FoodTagVocabulary.allergen.sorted().map(FoodTagOption.init)
    private static let excludableOptions = FoodTagVocabulary.dietary.sorted().map(FoodTagOption.init)
    /// Intolerances are a subset of the same vocabularies — the ones people actually report as an
    /// intolerance rather than an allergy.
    private static let intoleranceOptions = ["dairy", "egg", "gluten", "soy"].map(FoodTagOption.init)

    // MARK: - Meals

    private var mealsSection: some View {
        Section {
            Picker(selection: mealsPerDayBinding) {
                ForEach(mealOptions, id: \.self) { count in
                    Text(L("settings.nutrition.mealsValue", count)).tag(count)
                }
            } label: {
                Text(L("settings.nutrition.mealsPerDay")).fixedSize(horizontal: false, vertical: true)
            }
            .pickerStyle(.menu)
            .tint(Color.appNutrition)
            .frame(minHeight: Metrics.minimumTapTarget)
            SettingsFootnote(text: L("settings.nutrition.mealsExplainer"))

            EnumPickerRow(
                title: L("settings.nutrition.pace"),
                values: NutritionGoalPace.allCases,
                label: { L($0.localizationKey) },
                selection: Binding(
                    get: { model.profile?.nutritionPace ?? .moderate },
                    set: { model.updateNutritionPreferences(pace: $0) }
                )
            )
            SettingsFootnote(text: paceExplanation)

            Toggle(isOn: model.settingsBinding(\.dynamicCalorieAdjustmentEnabled, default: true)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("settings.nutrition.dynamicAdjustment"))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("settings.nutrition.dynamicAdjustment.detail"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.appNutrition)
            .frame(minHeight: Metrics.minimumTapTarget)
        } header: {
            Text(L("settings.nutrition.section.plan"))
        }
        .listRowBackground(Color.appSurface)
        .disabled(!isEnabled)
    }

    private var mealsPerDayBinding: Binding<Int> {
        Binding(
            get: { model.profile?.mealsPerDay ?? 4 },
            set: { model.updateNutritionPreferences(mealsPerDay: $0) }
        )
    }

    private var mealOptions: [Int] {
        let base = Array(InputValidation.mealsPerDay.lowerBound...6)
        guard let current = model.profile?.mealsPerDay, !base.contains(current) else { return base }
        return (base + [current]).sorted()
    }

    /// Turns the pace fraction into the weekly change it implies for this body mass, because
    /// "moderate" on its own tells the user nothing about what they signed up for.
    private var paceExplanation: String {
        let pace = model.profile?.nutritionPace ?? .moderate
        let bodyMass = model.profile?.currentWeightKg ?? 75
        let weeklyKg = pace.weeklyBodyMassFraction * bodyMass
        let direction = (model.profile?.goals.first ?? .generalFitness).energyBalanceDirection
        switch direction {
        case .maintenance:
            return L("settings.nutrition.paceMaintenance")
        case .surplus:
            return L("settings.nutrition.paceGain", model.formatter.weight(weeklyKg))
        case .deficit, .slightDeficit:
            return L("settings.nutrition.paceLose", model.formatter.weight(weeklyKg))
        }
    }

    // MARK: - Water

    private var waterSection: some View {
        Section {
            Toggle(isOn: model.settingsBinding(\.waterTrackingEnabled, default: true)) {
                Text(L("settings.nutrition.waterTracking")).fixedSize(horizontal: false, vertical: true)
            }
            .tint(Color.appRecovery)
            .frame(minHeight: Metrics.minimumTapTarget)

            if model.settings?.waterTrackingEnabled ?? true {
                Picker(selection: waterTargetBinding) {
                    ForEach(waterOptions, id: \.self) { millilitres in
                        Text(Self.waterLabel(millilitres)).tag(millilitres)
                    }
                } label: {
                    Text(L("settings.nutrition.waterTarget")).fixedSize(horizontal: false, vertical: true)
                }
                .pickerStyle(.menu)
                .tint(Color.appRecovery)
                .frame(minHeight: Metrics.minimumTapTarget)
                SettingsFootnote(text: L("settings.nutrition.waterFooter"))
            }
        } header: {
            Text(L("settings.nutrition.section.water"))
        }
        .listRowBackground(Color.appSurface)
        .disabled(!isEnabled)
    }

    private var waterTargetBinding: Binding<Double> {
        Binding(
            get: { model.settings?.dailyWaterTargetMl ?? 2500 },
            set: { value in model.updateSettings { $0.dailyWaterTargetMl = value } }
        )
    }

    private var waterOptions: [Double] {
        let base: [Double] = [1000, 1500, 2000, 2500, 3000, 3500, 4000, 5000]
        guard let current = model.settings?.dailyWaterTargetMl, !base.contains(current) else { return base }
        return (base + [current]).sorted()
    }

    /// Litres above a litre, millilitres below it — the way a bottle is labelled.
    private static func waterLabel(_ millilitres: Double) -> String {
        millilitres >= 1000
            ? Units.formatDecimal(millilitres / 1000, digits: 1) + " l"
            : Units.formatDecimal(millilitres, digits: 0) + " ml"
    }
}

/// A food tag rendered as a selectable chip. `String` is not `Identifiable`, and giving the tag a
/// type also keeps the three vocabularies from being mixed up with each other.
struct FoodTagOption: Identifiable, Hashable {
    let id: String

    init(_ id: String) { self.id = id }
}

#Preview("Nutrition") {
    // A full nutrition day has the diet, restrictions and targets all populated.
    PreviewHost(scenario: .fullNutritionDay) {
        NavigationStack {
            NutritionSettingsView()
        }
    }
}
