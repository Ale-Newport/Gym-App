import SwiftUI
import SwiftData

/// Creates or edits a food the user typed in themselves.
///
/// The whole screen is organised around the packet in the user's hand: everything is entered per
/// 100 g (or 100 ml), which is how food is labelled across the EU and how this app stores it, and
/// named servings are a *second* step rather than a competing basis. Entering "one slice, 28 g"
/// once here is what makes every later log a single tap.
struct CustomFoodEditorView: View {
    let foodID: UUID?
    var onSaved: ((UUID) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.dismiss) private var dismiss

    @State private var model = CustomFoodEditorViewModel()
    @State private var expandedGroup: String?
    @State private var isConfirmingDelete = false
    @State private var blockedReferenceCount: Int?

    init(foodID: UUID? = nil, onSaved: ((UUID) -> Void)? = nil) {
        self.foodID = foodID
        self.onSaved = onSaved
    }

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L(model.isExistingFood ? "nutritionLibrary.food.editTitle" : "nutritionLibrary.food.newTitle"))
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
            .task { await model.load(context: modelContext, foodID: foodID) }
            .alert(
                L("nutritionLibrary.food.deleteTitle"),
                isPresented: $isConfirmingDelete,
                actions: {
                    Button(L("common.cancel"), role: .cancel) {}
                    Button(L("common.delete"), role: .destructive) { delete(force: false) }
                },
                message: { Text(L("nutritionLibrary.food.deleteMessage")) }
            )
            .alert(
                L("nutritionLibrary.food.deleteBlockedTitle"),
                isPresented: Binding(
                    get: { blockedReferenceCount != nil },
                    set: { if !$0 { blockedReferenceCount = nil } }
                ),
                actions: {
                    Button(L("common.cancel"), role: .cancel) { blockedReferenceCount = nil }
                    Button(L("nutritionLibrary.food.deleteAnyway"), role: .destructive) {
                        blockedReferenceCount = nil
                        delete(force: true)
                    }
                },
                message: { Text(L("nutritionLibrary.food.deleteBlockedMessage", blockedReferenceCount ?? 0)) }
            )
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("common.loading"))
        case .failed(let explanation):
            // A food that cannot be loaded or is not editable is still a screen the user has to be
            // able to leave, so the way forward is "go back" rather than a retry that will fail again.
            ErrorStateView(
                message: explanation.text,
                retryTitle: L("common.back"),
                retry: { dismiss() }
            )
        case .ready:
            editor
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(spacing: Metrics.spacing16) {
                if let failure = model.saveFailure {
                    saveFailureCard(failure)
                }
                identityCard
                energyCard
                servingsCard
                micronutrientsCard
                tagsCard
                if model.isExistingFood {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Text(L("nutritionLibrary.food.delete"))
                            .foregroundStyle(Color.appDanger)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .screenPadding()
            .padding(.vertical, Metrics.spacing16)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Cards

    private func saveFailureCard(_ explanation: Explanation) -> some View {
        Card(background: .appSurface) {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Label(explanation.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("common.done")) { model.clearFailure() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var identityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                SectionHeader(L("nutritionLibrary.food.basics"))
                labelledField(L("nutritionLibrary.food.name")) {
                    TextField(L("nutritionLibrary.food.namePlaceholder"), text: $model.name)
                        .textInputAutocapitalization(.words)
                }
                labelledField(L("nutritionLibrary.food.brand")) {
                    TextField(L("common.optional"), text: $model.brand)
                        .textInputAutocapitalization(.words)
                }
                basisControl
            }
        }
    }

    /// The basis is fixed once a food exists: every stored serving, every log entry and every
    /// recipe quantity was computed against it, and reinterpreting grams as millilitres after the
    /// fact would silently rewrite history.
    @ViewBuilder
    private var basisControl: some View {
        if model.isExistingFood {
            HStack {
                Text(L("nutritionLibrary.food.basis"))
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
                Spacer(minLength: Metrics.spacing8)
                Text(L(model.basisUnit.localizationKey))
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
            }
            .accessibilityElement(children: .combine)
        } else {
            SegmentedValuePicker(
                title: L("nutritionLibrary.food.basis"),
                values: [ServingUnit.grams, ServingUnit.milliliters],
                label: { L($0.localizationKey) },
                selection: $model.basisUnit
            )
        }
    }

    private var energyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                SectionHeader(
                    title: L("nutritionLibrary.food.per100"),
                    subtitle: L(
                        model.basisUnit == .milliliters
                            ? "nutritionLibrary.food.per100ml"
                            : "nutritionLibrary.food.per100g"
                    )
                ) { EmptyView() }

                NumberEntryField(
                    title: L("nutritionLibrary.food.energy"),
                    value: $model.kilocalories,
                    unit: formatter.energyUnitLabel,
                    range: 0...InputValidation.energyDensityPer100.upperBound,
                    step: 10
                )
                NumberEntryField(
                    title: L("nutritionLibrary.food.protein"),
                    value: $model.protein,
                    unit: "g",
                    range: 0...InputValidation.macroDensityPer100.upperBound,
                    step: 1
                )
                NumberEntryField(
                    title: L("nutritionLibrary.food.carbs"),
                    value: $model.carbs,
                    unit: "g",
                    range: 0...InputValidation.macroDensityPer100.upperBound,
                    step: 1
                )
                NumberEntryField(
                    title: L("nutritionLibrary.food.fat"),
                    value: $model.fat,
                    unit: "g",
                    range: 0...InputValidation.macroDensityPer100.upperBound,
                    step: 1
                )

                if let warning = model.consistencyWarning {
                    consistencyWarningView(warning)
                }
            }
        }
    }

    /// Shown, never enforced: packets round their own numbers and fibre is counted differently
    /// between jurisdictions, so the app states the disagreement and offers the arithmetic rather
    /// than refusing the label in the user's hand.
    private func consistencyWarningView(_ warning: MacroConsistencyWarning) -> some View {
        InsetGroup {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Label {
                    Text(L(
                        "nutritionLibrary.food.energyMismatch",
                        formatter.energy(warning.statedKilocalories),
                        formatter.energy(warning.impliedKilocalories)
                    ))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(Color.appWarning)
                }
                Button(L("nutritionLibrary.food.useImplied", formatter.energy(warning.impliedKilocalories))) {
                    model.useImpliedEnergy()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var servingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                SectionHeader(
                    title: L("nutritionLibrary.food.servings"),
                    subtitle: L("nutritionLibrary.food.servingsHint")
                ) {
                    Button {
                        model.addServing()
                    } label: {
                        Image(systemName: "plus")
                            .minimumTapTarget()
                    }
                    .accessibilityLabel(Text(L("nutritionLibrary.food.addServing")))
                }

                if model.servings.isEmpty {
                    Text(L("nutritionLibrary.food.noServings"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach($model.servings) { $serving in
                        servingRow($serving)
                    }
                }

                NumberEntryField(
                    title: L("nutritionLibrary.food.gramsPerPiece"),
                    value: $model.gramsPerPiece,
                    unit: "g",
                    range: 0...InputValidation.servingGrams.upperBound,
                    step: 5
                )
                Text(L("nutritionLibrary.food.gramsPerPieceHint"))
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func servingRow(_ serving: Binding<NutritionServingDraft>) -> some View {
        InsetGroup {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                HStack(spacing: Metrics.spacing8) {
                    TextField(L("nutritionLibrary.food.servingName"), text: serving.name)
                        .font(.subheadline)
                        .frame(minHeight: Metrics.minimumTapTarget)
                        .accessibilityLabel(Text(L("nutritionLibrary.food.servingName")))
                    Button {
                        model.servings.removeAll { $0.id == serving.wrappedValue.id }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(Color.appDanger)
                            .minimumTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("nutritionLibrary.food.removeServing", serving.wrappedValue.name)))
                }
                NumberEntryField(
                    title: L("nutritionLibrary.food.servingGrams"),
                    value: Binding(
                        get: { serving.wrappedValue.grams },
                        set: { serving.wrappedValue.grams = $0 ?? 0 }
                    ),
                    unit: "g",
                    range: 0...InputValidation.servingGrams.upperBound,
                    step: 5
                )
            }
        }
    }

    private var micronutrientsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(
                    title: L("nutritionLibrary.food.micronutrients"),
                    subtitle: L("nutritionLibrary.food.micronutrientsHint")
                ) { EmptyView() }

                micronutrientGroup(id: "other", titleKey: "nutritionLibrary.micros.other", nutrients: Micronutrient.otherNutrients)
                micronutrientGroup(id: "minerals", titleKey: "nutritionLibrary.micros.minerals", nutrients: Micronutrient.minerals)
                micronutrientGroup(id: "vitamins", titleKey: "nutritionLibrary.micros.vitamins", nutrients: Micronutrient.vitamins)
            }
        }
    }

    /// One collapsible block of nutrient fields. Twenty-three number fields open at once would be a
    /// wall, and almost nobody fills more than the handful printed on the packet.
    private func micronutrientGroup(id: String, titleKey: String, nutrients: [Micronutrient]) -> some View {
        let isExpanded = expandedGroup == id
        let filledCount = nutrients.filter { model.micronutrients[$0] != nil }.count
        return VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Button {
                expandedGroup = isExpanded ? nil : id
            } label: {
                HStack {
                    Text(L(titleKey))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    if filledCount > 0 {
                        Text(L("nutritionLibrary.food.filledCount", filledCount))
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Spacer(minLength: Metrics.spacing8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextSecondary)
                }
                .frame(minHeight: Metrics.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isExpanded ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(Text(L(isExpanded ? "common.showLess" : "common.showMore")))

            if isExpanded {
                ForEach(nutrients) { nutrient in
                    MicronutrientValueField(
                        nutrient: nutrient,
                        value: Binding(
                            get: { model.micronutrients[nutrient] },
                            set: { model.micronutrients[nutrient] = $0 }
                        )
                    )
                }
            }
        }
    }

    private var tagsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                SectionHeader(
                    title: L("nutritionLibrary.food.tags"),
                    subtitle: L("nutritionLibrary.food.tagsHint")
                ) { EmptyView() }

                tagGroup(
                    title: L("nutritionLibrary.food.dietaryTags"),
                    tags: FoodTagVocabulary.dietary.sorted(),
                    selection: \.dietaryTags,
                    tint: .appNutrition
                )
                tagGroup(
                    title: L("nutritionLibrary.food.allergenTags"),
                    tags: FoodTagVocabulary.allergen.sorted(),
                    selection: \.allergenTags,
                    tint: .appWarning
                )
                tagGroup(
                    title: L("nutritionLibrary.food.roleTags"),
                    tags: FoodTagVocabulary.role.sorted(),
                    selection: \.roleTags,
                    tint: .appRecovery
                )
            }
        }
    }

    private func tagGroup(
        title: String,
        tags: [String],
        selection: ReferenceWritableKeyPath<CustomFoodEditorViewModel, Set<String>>,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text(title)
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
            FlowLayout {
                ForEach(tags, id: \.self) { tag in
                    let isOn = model[keyPath: selection].contains(tag)
                    Button {
                        model.toggle(tag, in: selection)
                        Haptics.selectionChanged()
                    } label: {
                        // The checkmark carries the state as well as the tint, so selection is not
                        // conveyed by colour alone.
                        Chip(
                            title: L("nutritionLibrary.tag.\(tag)"),
                            systemImage: isOn ? "checkmark" : nil,
                            isSelected: isOn,
                            tint: tint
                        )
                        .frame(minHeight: Metrics.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("nutritionLibrary.tag.\(tag)")))
                    .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private func labelledField<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            Text(title)
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
            field()
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)
                .frame(minHeight: Metrics.minimumTapTarget)
                .padding(.horizontal, Metrics.spacing12)
                .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
                .accessibilityLabel(Text(title))
        }
    }

    // MARK: - Actions

    private func save() {
        Task {
            if let id = await model.save() {
                onSaved?(id)
                Haptics.success()
                dismiss()
            } else {
                Haptics.error()
            }
        }
    }

    private func delete(force: Bool) {
        Task {
            switch await model.delete(force: force) {
            case .deleted:
                Haptics.success()
                dismiss()
            case .blocked(let referenceCount):
                blockedReferenceCount = referenceCount
            case .failed:
                Haptics.error()
            }
        }
    }
}

// MARK: - Micronutrient field

/// One optional micronutrient value, per 100 g of the food.
///
/// Left blank the nutrient stays *unknown* rather than becoming zero — the distinction is the whole
/// reason `Micronutrients` uses optionals, and it is what stops the app drawing an empty bar for a
/// food whose label simply does not print the number.
private struct MicronutrientValueField: View {
    let nutrient: Micronutrient
    @Binding var value: Double?

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.spacing12) {
            Text(L(nutrient.localizationKey))
                .font(.subheadline)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Metrics.spacing4) {
                TextField("—", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.appNumeric(17))
                    .focused($isFocused)
                    .frame(minWidth: 60)
                    .onChange(of: text) { _, newValue in commit(newValue) }
                Text(nutrient.unit.rawValue)
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(.horizontal, Metrics.spacing12)
            .frame(minHeight: Metrics.minimumTapTarget)
            .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous))
        }
        .padding(.vertical, Metrics.spacing2)
        .onAppear { text = value.map { Self.format($0) } ?? "" }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L("nutritionLibrary.food.microFieldLabel", L(nutrient.localizationKey), nutrient.unit.rawValue)))
        .accessibilityValue(Text(text.isEmpty ? L("common.notSet") : text))
    }

    private func commit(_ raw: String) {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let filtered = normalized.filter { $0.isNumber || $0 == "." }
        if filtered != raw {
            text = filtered
            return
        }
        guard !filtered.isEmpty else { value = nil; return }
        guard let parsed = Double(filtered), parsed.isFinite else { return }
        value = max(0, parsed)
    }

    private static func format(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.001 ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }
}

#Preview("New food") {
    PreviewHost(scenario: .emptyNutritionDay) {
        NavigationStack {
            CustomFoodEditorView()
        }
    }
}
