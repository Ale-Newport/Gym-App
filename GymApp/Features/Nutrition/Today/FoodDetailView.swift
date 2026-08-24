import SwiftUI

/// Everything one food contains: energy, macros and the full micronutrient profile.
///
/// The screen exists mainly to make one distinction visible. `Micronutrients` stores `nil` for
/// "this record does not say" and `0` for "this food genuinely contains none", and the interface
/// has to keep those apart: printing a zero for missing data would let the app imply a deficiency
/// it has no evidence for. Unknown values are therefore rendered as a dash, are never given a bar,
/// and are announced as unknown to VoiceOver.
struct FoodDetailView: View {
    let basis: PortionBasis
    let source: FoodSource
    var barcode: String?
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)?
    var defaultSlot: MealSlot = .snacks
    var initialPortion: PortionValue?
    /// Nil when the screen is opened purely to read — a logged entry whose food has been deleted
    /// can be inspected but not logged again.
    var onLog: ((PortionValue, MealSlot) -> Void)?

    @State private var showsPortion = false
    @State private var isEditingPortion = false
    @Environment(\.displayFormatter) private var formatter

    private var portion: PortionValue { initialPortion ?? basis.defaultPortion }

    /// The quantity every figure on this screen is expressed in.
    private var displayedPortion: PortionValue {
        showsPortion
            ? portion
            : PortionValue(quantity: 100, unit: basis.basisUnit == .milliliters ? .milliliters : .grams)
    }

    private var macros: MacroNutrients { basis.macros(for: displayedPortion) }
    private var micros: Micronutrients { basis.micronutrients(for: displayedPortion) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                header
                basisPicker
                macroCard
                if hasInconsistentEnergy {
                    ExplanationNote(
                        text: L("food.result.energyMismatch"),
                        systemImage: "exclamationmark.triangle",
                        tint: .appWarning
                    )
                }
                micronutrientSection(title: L("nutritionLog.micro.other"), nutrients: Micronutrient.otherNutrients)
                micronutrientSection(title: L("nutritionLog.micro.minerals"), nutrients: Micronutrient.minerals)
                micronutrientSection(title: L("nutritionLog.micro.vitamins"), nutrients: Micronutrient.vitamins)
                footnotes
                if onLog != nil { logButton }
            }
            .screenPadding()
            .padding(.vertical, Metrics.spacing20)
            .readableWidth()
        }
        .background(Color.appBackground)
        .navigationTitle(L("nutritionLog.food.details"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onToggleFavorite {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Haptics.tap()
                        onToggleFavorite()
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                    }
                    .accessibilityLabel(isFavorite ? L("nutritionLog.action.unfavorite") : L("nutritionLog.action.favorite"))
                }
            }
        }
        .sheet(isPresented: $isEditingPortion) {
            NavigationStack {
                PortionEditorView(
                    basis: basis,
                    initial: portion,
                    slot: defaultSlot,
                    actionTitle: L("nutritionLog.action.addToMeal")
                ) { value, slot in
                    isEditingPortion = false
                    onLog?(value, slot)
                }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            Text(basis.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let brand = basis.brand, !brand.isEmpty {
                Text(brand)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Metrics.spacing8) {
                Chip(title: L(source.localizationKey), systemImage: "shippingbox", tint: .appNutrition)
                if let barcode, !barcode.isEmpty {
                    Chip(title: barcode, systemImage: "barcode", tint: .appTextSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var basisPicker: some View {
        SegmentedValuePicker(
            title: nil,
            values: [false, true],
            label: { $0 ? portionLabel : basisLabel },
            selection: $showsPortion
        )
        .accessibilityLabel(L("nutritionLog.food.basis"))
    }

    private var macroCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("nutritionLog.food.energy"))
                        .font(.appOverline)
                        .foregroundStyle(Color.appTextSecondary)
                    Spacer(minLength: Metrics.spacing8)
                    Text(formatter.energy(macros.kilocalories))
                        .font(.appNumeric(24))
                        .foregroundStyle(Color.appNutrition)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Divider().overlay(Color.appSeparator)
                nutrientLine(L("nutritionLog.macro.protein"), formatter.macro(macros.proteinG))
                nutrientLine(L("nutritionLog.macro.carbs"), formatter.macro(macros.carbsG))
                nutrientLine(L("nutritionLog.macro.fat"), formatter.macro(macros.fatG))
            }
        }
    }

    private func micronutrientSection(title: String, nutrients: [Micronutrient]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            SectionHeader(title)
            Card {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    ForEach(nutrients) { nutrient in
                        micronutrientRow(nutrient)
                        if nutrient != nutrients.last {
                            Divider().overlay(Color.appSeparator)
                        }
                    }
                }
            }
        }
    }

    private func micronutrientRow(_ nutrient: Micronutrient) -> some View {
        let value = micros[nutrient]
        let reference = nutrient.referenceDailyIntake
        let fraction = (value != nil && (reference ?? 0) > 0) ? value! / reference! : nil

        return VStack(alignment: .leading, spacing: Metrics.spacing4) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                Text(L(nutrient.localizationKey))
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Metrics.spacing8)
                Text(valueText(value, unit: nutrient.unit))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(value == nil ? Color.appTextTertiary : Color.appTextPrimary)
                    .lineLimit(1)
            }
            if let fraction {
                ProgressBar(
                    value: fraction,
                    total: 1,
                    tint: nutrient.isLimitingNutrient && fraction >= 1 ? .appWarning : .appNutrition,
                    height: 5
                )
                Text(L("nutritionLog.micro.ofReference", NutritionFormat.percent(fraction)))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(micronutrientAccessibilityLabel(nutrient, value: value, fraction: fraction))
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            Text(L("nutritionLog.micro.unknownNote"))
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let attribution = basis.attribution, !attribution.isEmpty {
                Text(attribution)
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var logButton: some View {
        Button {
            isEditingPortion = true
        } label: {
            Text(L("nutritionLog.action.addToMeal"))
        }
        .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
        .accessibilityLabel(L("nutritionLog.action.addToMeal"))
    }

    // MARK: Text

    private func nutrientLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.spacing8)
            Text(value)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func valueText(_ value: Double?, unit: Micronutrient.Unit) -> String {
        guard let value else { return "—" }
        let digits = value < 10 ? 1 : 0
        return "\(Units.formatDecimal(value, digits: digits, locale: formatter.locale)) \(unit.rawValue)"
    }

    private func micronutrientAccessibilityLabel(_ nutrient: Micronutrient, value: Double?, fraction: Double?) -> String {
        let name = L(nutrient.localizationKey)
        guard let value else { return L("nutritionLog.a11y.microUnknown", name) }
        let amount = "\(Units.formatDecimal(value, digits: value < 10 ? 1 : 0, locale: formatter.locale)) \(nutrient.unit.rawValue)"
        guard let fraction else { return L("nutritionLog.a11y.microValue", name, amount) }
        return L("nutritionLog.a11y.microValueReference", name, amount, NutritionFormat.percent(fraction))
    }

    private var basisLabel: String {
        basis.basisUnit == .milliliters ? L("food.result.per100ml") : L("food.result.per100g")
    }

    private var portionLabel: String {
        let amount = Units.formatDecimal(portion.quantity, digits: portion.quantity < 10 ? 1 : 0, locale: formatter.locale)
        return L("nutritionLog.food.perPortion", "\(amount) \(L(portion.unit.localizationKey))")
    }

    private var hasInconsistentEnergy: Bool {
        let stated = basis.macrosPer100.kilocalories
        let derived = basis.macrosPer100.derivedKilocalories
        guard stated > 0, derived > 0 else { return false }
        return abs(derived - stated) / stated > 0.25
    }
}

#Preview("Food detail") {
    PreviewHost(scenario: .fullNutritionDay) {
        NavigationStack {
            FoodDetailView(
                basis: PortionBasis(
                    name: "Rolled oats",
                    brand: nil,
                    basisUnit: .grams,
                    macrosPer100: MacroNutrients(kilocalories: 379, proteinG: 13.2, carbsG: 67.7, fatG: 6.5),
                    micronutrientsPer100: Micronutrients(
                        fiberG: 10.1, sugarG: 0.99, saturatedFatG: 1.2,
                        sodiumMg: 6, potassiumMg: 362, calciumMg: 52, ironMg: 4.7,
                        magnesiumMg: 138, zincMg: 3.6, thiaminMg: 0.46
                    ),
                    servings: [FoodServing(name: "1 bowl", gramsPerServing: 80)],
                    gramsPerPiece: nil,
                    attribution: "USDA FoodData Central (public domain)"
                ),
                source: .builtIn,
                isFavorite: true,
                onToggleFavorite: {},
                defaultSlot: .breakfast,
                onLog: { _, _ in }
            )
        }
    }
}
