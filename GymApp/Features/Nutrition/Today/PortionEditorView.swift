import SwiftData
import SwiftUI

// MARK: - Values

/// One portion, as the user describes it: a number, a unit, and — for a named serving — which
/// serving they meant.
struct PortionValue: Hashable, Sendable {
    var quantity: Double
    var unit: ServingUnit
    var servingIndex: Int?

    init(quantity: Double, unit: ServingUnit = .grams, servingIndex: Int? = nil) {
        self.quantity = quantity
        self.unit = unit
        self.servingIndex = servingIndex
    }
}

/// The nutrition basis a portion is measured against, decoupled from where it came from.
///
/// The portion editor has to work for three different things — a stored `FoodItem`, a provider
/// result that has never been written to the store, and a log entry whose food has since been
/// deleted — and the arithmetic is identical for all three. Lifting it into a value type keeps that
/// arithmetic in one place and makes the editor's live preview provably the same calculation the
/// repository will perform when it saves.
struct PortionBasis: Hashable, Sendable {
    var name: String
    var brand: String?
    /// Whether the per-100 figures are per 100 g or per 100 ml.
    var basisUnit: ServingUnit
    var macrosPer100: MacroNutrients
    var micronutrientsPer100: Micronutrients
    var servings: [FoodServing]
    var gramsPerPiece: Double?
    /// False when nothing in the store knows how many grams a "piece" of this food is any more —
    /// the food behind a log entry was deleted. The unit is then frozen, because the repository
    /// can only rescale such an entry along its existing unit.
    var allowsUnitChange: Bool = true
    var attribution: String?

    static func from(_ food: FoodItem) -> PortionBasis {
        PortionBasis(
            name: food.name,
            brand: food.brand,
            basisUnit: food.basisUnit,
            macrosPer100: food.macrosPer100,
            micronutrientsPer100: food.micronutrientsPer100,
            servings: food.servings,
            gramsPerPiece: food.gramsPerPiece,
            attribution: food.attribution
        )
    }

    static func from(_ result: FoodSearchResult) -> PortionBasis {
        PortionBasis(
            name: result.name,
            brand: result.brand,
            basisUnit: result.basisUnit,
            macrosPer100: result.macrosPer100,
            micronutrientsPer100: result.micronutrientsPer100,
            servings: result.servings,
            gramsPerPiece: result.gramsPerPiece,
            attribution: result.attribution
        )
    }

    /// Rebuilds a basis from a log entry's own snapshot, for the case where the food is gone.
    ///
    /// The snapshot is all that survives, so the basis is derived by dividing it back out by the
    /// quantity that produced it. For pieces and servings that means treating one piece (or one
    /// serving) as weighing 100 units, which keeps the arithmetic linear and correct for the only
    /// operation still permitted on such an entry: changing the number.
    @MainActor
    static func fromSnapshot(of entry: FoodLogEntry) -> PortionBasis {
        let quantity = max(entry.quantity, 0.0001)
        let perUnitFactor: Double
        var servings: [FoodServing] = []
        var gramsPerPiece: Double?

        switch entry.unit {
        case .grams, .milliliters:
            perUnitFactor = 100 / quantity
        case .piece:
            perUnitFactor = 1 / quantity
            gramsPerPiece = 100
        case .serving:
            perUnitFactor = 1 / quantity
            servings = [FoodServing(name: L("servingUnit.serving"), gramsPerServing: 100)]
        }

        return PortionBasis(
            name: entry.foodNameSnapshot,
            brand: entry.brandSnapshot,
            basisUnit: entry.unit.isMassOrVolume ? entry.unit : .grams,
            macrosPer100: entry.macrosSnapshot * perUnitFactor,
            micronutrientsPer100: entry.micronutrientsSnapshot.scaled(by: perUnitFactor),
            servings: servings,
            gramsPerPiece: gramsPerPiece,
            allowsUnitChange: false
        )
    }

    /// Grams (or millilitres) represented by a portion. Mirrors `FoodItem.basisQuantity`.
    func basisQuantity(for portion: PortionValue) -> Double {
        switch portion.unit {
        case .grams, .milliliters:
            return portion.quantity
        case .piece:
            return portion.quantity * (gramsPerPiece ?? 100)
        case .serving:
            let serving = portion.servingIndex
                .flatMap { servings.indices.contains($0) ? servings[$0] : nil } ?? servings.first
            return portion.quantity * (serving?.gramsPerServing ?? 100)
        }
    }

    func macros(for portion: PortionValue) -> MacroNutrients {
        macrosPer100 * (basisQuantity(for: portion) / 100)
    }

    func micronutrients(for portion: PortionValue) -> Micronutrients {
        micronutrientsPer100.scaled(by: basisQuantity(for: portion) / 100)
    }

    /// Units this food can actually be measured in. Never offers "piece" for a food that has no
    /// piece weight, because the answer would silently be wrong by whatever 100 g is not.
    var availableUnits: [ServingUnit] {
        guard allowsUnitChange else { return [] }
        var units: [ServingUnit] = [basisUnit == .milliliters ? .milliliters : .grams]
        if gramsPerPiece != nil { units.append(.piece) }
        if !servings.isEmpty { units.append(.serving) }
        return units
    }

    /// The portion to open the editor at for a food the user has not logged before: one named
    /// serving if the food has one, otherwise 100 g — the basis every label is printed in.
    var defaultPortion: PortionValue {
        if !servings.isEmpty { return PortionValue(quantity: 1, unit: .serving, servingIndex: 0) }
        if gramsPerPiece != nil { return PortionValue(quantity: 1, unit: .piece) }
        return PortionValue(quantity: 100, unit: basisUnit == .milliliters ? .milliliters : .grams)
    }

    @MainActor
    func servingName(at index: Int?) -> String? {
        guard let index, servings.indices.contains(index) else {
            return servings.first.map { Self.name(of: $0) }
        }
        return Self.name(of: servings[index])
    }

    /// Built-in servings ship a localisation key; user-created ones carry their own text.
    ///
    /// Main-actor bound because the lookup follows the in-app language override, which lives on
    /// the main actor; every caller is a view or a view model, so this costs nothing.
    @MainActor
    static func name(of serving: FoodServing) -> String {
        guard let key = serving.nameKey, !key.isEmpty else { return serving.name }
        return L(key)
    }
}

// MARK: - Editor

/// Quantity, unit and meal for one portion, with the macros recalculating as the number changes.
///
/// Live recalculation is the whole point of this screen: people do not think in grams, they think
/// "is this too much?", and the only way to answer that is to show the consequence of the number
/// while it is still being typed.
struct PortionEditorView: View {
    let basis: PortionBasis
    let actionTitle: String
    /// Shown when the food's own nutrition can be inspected in full.
    var onShowDetails: (() -> Void)?
    /// False when the editor is pushed onto a stack that already has a back button.
    var showsCancelButton: Bool = true
    let onCommit: (PortionValue, MealSlot) -> Void

    @State private var quantity: Double?
    @State private var unit: ServingUnit
    @State private var servingIndex: Int?
    @State private var slot: MealSlot

    @Environment(\.displayFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss

    init(
        basis: PortionBasis,
        initial: PortionValue,
        slot: MealSlot,
        actionTitle: String,
        onShowDetails: (() -> Void)? = nil,
        showsCancelButton: Bool = true,
        onCommit: @escaping (PortionValue, MealSlot) -> Void
    ) {
        self.basis = basis
        self.actionTitle = actionTitle
        self.onShowDetails = onShowDetails
        self.showsCancelButton = showsCancelButton
        self.onCommit = onCommit
        _quantity = State(initialValue: initial.quantity)
        _unit = State(initialValue: initial.unit)
        _servingIndex = State(initialValue: initial.servingIndex ?? (initial.unit == .serving ? 0 : nil))
        _slot = State(initialValue: slot)
    }

    private var portion: PortionValue {
        PortionValue(quantity: quantity ?? 0, unit: unit, servingIndex: servingIndex)
    }

    private var macros: MacroNutrients { basis.macros(for: portion) }
    private var isCommitEnabled: Bool { (quantity ?? 0) >= InputValidation.portionQuantity.lowerBound }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing20) {
                header
                amountCard
                livePreview
                mealPicker
                commitButton
            }
            .screenPadding()
            .padding(.vertical, Metrics.spacing20)
            .readableWidth()
        }
        .background(Color.appBackground)
        .navigationTitle(L("nutritionLog.portion.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCancelButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
            }
            if let onShowDetails {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onShowDetails()
                    } label: {
                        Label(L("nutritionLog.food.details"), systemImage: "info.circle")
                    }
                    .accessibilityLabel(L("nutritionLog.food.details"))
                }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
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
            Text(basisSummary)
                .font(.caption)
                .foregroundStyle(Color.appTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var amountCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                NumberEntryField(
                    title: L("nutritionLog.portion.amount"),
                    value: $quantity,
                    unit: unitLabel,
                    allowsDecimals: true,
                    range: InputValidation.portionQuantity,
                    step: quantityStep
                )

                if basis.availableUnits.count > 1 {
                    SegmentedValuePicker(
                        title: L("nutritionLog.portion.unit"),
                        values: basis.availableUnits,
                        label: { L($0.localizationKey) },
                        selection: unitBinding
                    )
                }

                if unit == .serving, basis.servings.count > 1 {
                    servingPicker
                }

                if unit == .serving, let grams = servingGrams {
                    Text(L("nutritionLog.portion.servingWeight", basis.servingName(at: servingIndex) ?? "", Units.formatMacro(grams: grams, locale: formatter.locale)))
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                quickAmounts
            }
        }
    }

    private var servingPicker: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            Text(L("nutritionLog.portion.serving"))
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
            Menu {
                ForEach(Array(basis.servings.enumerated()), id: \.element.id) { index, serving in
                    Button {
                        servingIndex = index
                        Haptics.selectionChanged()
                    } label: {
                        Text("\(PortionBasis.name(of: serving)) · \(Units.formatMacro(grams: serving.gramsPerServing, locale: formatter.locale))")
                    }
                }
            } label: {
                HStack {
                    Text(basis.servingName(at: servingIndex) ?? L("servingUnit.serving"))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Metrics.spacing8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                }
                .padding(.horizontal, Metrics.spacing12)
                .frame(minHeight: Metrics.minimumTapTarget)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
            }
            .accessibilityLabel(L("nutritionLog.portion.serving"))
        }
    }

    /// One-tap portions. Typing "150" on a number pad is four interactions; this is one, and it
    /// covers the amounts people actually log.
    private var quickAmounts: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            Text(L("nutritionLog.portion.quick"))
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
            FlowLayout {
                ForEach(quickValues, id: \.self) { value in
                    Button {
                        quantity = value
                        Haptics.tap()
                    } label: {
                        Chip(
                            title: "\(Units.formatDecimal(value, digits: value < 10 ? 1 : 0, locale: formatter.locale)) \(unitLabel)",
                            isSelected: quantity == value,
                            tint: .appNutrition
                        )
                        .frame(minHeight: Metrics.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(quantity == value ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private var livePreview: some View {
        Card(background: .appSurfaceElevated) {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("nutritionLog.portion.thisPortion"))
                        .font(.appOverline)
                        .foregroundStyle(Color.appTextSecondary)
                    Spacer(minLength: Metrics.spacing8)
                    Text(formatter.energy(macros.kilocalories))
                        .font(.appNumeric(26))
                        .foregroundStyle(Color.appNutrition)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                MacroSummaryLine(macros: macros)
            }
            .animation(.easeOut(duration: 0.2), value: macros)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L(
            "nutritionLog.a11y.portionMacros",
            formatter.energy(macros.kilocalories),
            formatter.macro(macros.proteinG),
            formatter.macro(macros.carbsG),
            formatter.macro(macros.fatG)
        ))
    }

    private var mealPicker: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            Text(L("nutritionLog.portion.meal"))
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
            // Four segments do not fit side by side at accessibility text sizes, so the picker
            // becomes a menu rather than clipping its own labels.
            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { candidate in
                        Button(L(candidate.localizationKey)) { slot = candidate }
                    }
                } label: {
                    HStack {
                        Text(L(slot.localizationKey)).foregroundStyle(Color.appTextPrimary)
                        Spacer(minLength: Metrics.spacing8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                    }
                    .padding(.horizontal, Metrics.spacing12)
                    .frame(minHeight: Metrics.minimumTapTarget)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
                }
                .accessibilityLabel(L("nutritionLog.portion.meal"))
            } else {
                SegmentedValuePicker(
                    title: nil,
                    values: MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex },
                    label: { L($0.localizationKey) },
                    selection: $slot
                )
            }
        }
    }

    private var commitButton: some View {
        Button {
            guard isCommitEnabled else { return }
            Haptics.success()
            onCommit(portion, slot)
        } label: {
            Text(actionTitle)
        }
        .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
        .disabled(!isCommitEnabled)
        .accessibilityLabel(actionTitle)
    }

    // MARK: Helpers

    private var unitBinding: Binding<ServingUnit> {
        Binding(
            get: { unit },
            set: { newUnit in
                guard newUnit != unit else { return }
                unit = newUnit
                servingIndex = newUnit == .serving ? (servingIndex ?? 0) : nil
                // Switching units keeps a sensible number rather than carrying "150" over from
                // grams into servings, which would silently log fifteen kilos of cereal.
                quantity = newUnit.isMassOrVolume ? 100 : 1
            }
        )
    }

    private var unitLabel: String { L(unit.localizationKey) }

    private var basisSummary: String {
        let basisLabel = basis.basisUnit == .milliliters ? L("food.result.per100ml") : L("food.result.per100g")
        return "\(basisLabel) · \(formatter.energy(basis.macrosPer100.kilocalories))"
    }

    private var quantityStep: Double { unit.isMassOrVolume ? 10 : 0.5 }

    private var quickValues: [Double] {
        unit.isMassOrVolume ? [30, 50, 100, 150, 200, 250] : [0.5, 1, 1.5, 2, 3]
    }

    private var servingGrams: Double? {
        guard unit == .serving else { return nil }
        let serving = servingIndex.flatMap { basis.servings.indices.contains($0) ? basis.servings[$0] : nil }
            ?? basis.servings.first
        return serving?.gramsPerServing
    }
}

// MARK: - Shared macro line

/// Protein, carbohydrate and fat on one line, each labelled. Used in the portion editor, in log
/// rows and in meal subtotals so a macro breakdown always reads the same way.
struct MacroSummaryLine: View {
    let macros: MacroNutrients
    var font: Font = .footnote

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        HStack(spacing: Metrics.spacing12) {
            component(L("nutritionLog.macro.proteinShort"), macros.proteinG, .appAccent)
            component(L("nutritionLog.macro.carbsShort"), macros.carbsG, .appRecovery)
            component(L("nutritionLog.macro.fatShort"), macros.fatG, .appWarning)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L(
            "nutritionLog.a11y.macros",
            formatter.macro(macros.proteinG),
            formatter.macro(macros.carbsG),
            formatter.macro(macros.fatG)
        ))
    }

    private func component(_ label: String, _ grams: Double, _ tint: Color) -> some View {
        HStack(spacing: Metrics.spacing4) {
            // The dot is decoration on top of a written label, never the label itself.
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label)
                .font(font)
                .foregroundStyle(Color.appTextTertiary)
            Text(formatter.macro(grams))
                .font(font.weight(.medium).monospacedDigit())
                .foregroundStyle(Color.appTextPrimary)
        }
    }
}

// MARK: - Preview

#Preview("Portion editor") {
    PreviewHost(scenario: .fullNutritionDay) {
        NavigationStack {
            PortionEditorView(
                basis: PortionBasis(
                    name: "Greek yoghurt, plain 2%",
                    brand: "Fage",
                    basisUnit: .grams,
                    macrosPer100: MacroNutrients(kilocalories: 73, proteinG: 10, carbsG: 3.9, fatG: 1.9),
                    micronutrientsPer100: .unknown,
                    servings: [FoodServing(name: "1 pot", gramsPerServing: 170)],
                    gramsPerPiece: nil
                ),
                initial: PortionValue(quantity: 1, unit: .serving, servingIndex: 0),
                slot: .breakfast,
                actionTitle: L("nutritionLog.action.addToMeal")
            ) { _, _ in }
        }
    }
}
