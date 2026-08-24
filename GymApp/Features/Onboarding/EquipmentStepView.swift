import SwiftUI

/// What the user can actually train with, and the exact loads their gym lets them select.
///
/// The equipment list is read from the catalogue rather than hard-coded, and every row states how
/// many exercises it unlocks. That number is the honest answer to "does it matter if I tick this?",
/// and it is the only way a user can tell that a cable machine is worth walking to and a tyre is
/// not. Increments matter just as much: a recommendation of 32.8 kg tells the user the app has
/// never been to a gym, so the plate and stack sizes are asked for rather than assumed.
struct EquipmentStepView: View {
    @Bindable var model: OnboardingViewModel
    @Environment(AppEnvironment.self) private var environment

    private var catalog: ExerciseCatalog { environment.catalog }

    /// Equipment present in the dataset, most useful first. Sorting by how much each unlocks puts
    /// the decisions that change the program at the top of a long list.
    private var equipmentOptions: [Equipment] {
        catalog.availableEquipment.sorted { lhs, rhs in
            let left = catalog.count(forEquipment: lhs)
            let right = catalog.count(forEquipment: rhs)
            if left != right { return left > right }
            return lhs.rawValue < rhs.rawValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            presetSection
            equipmentSection
            if model.usesBarbell || model.usesDumbbells || model.usesKettlebells
                || model.usesMachines || model.selectedEquipment.contains(.cable)
                || model.selectedEquipment.contains(.ezBarbell) {
                incrementsSection
            }
        }
    }

    // MARK: - Presets

    private var presetSection: some View {
        OnboardingSection(L("onboarding.equipment.preset"), subtitle: L("onboarding.equipment.preset.detail")) {
            VStack(spacing: Metrics.spacing8) {
                ForEach(GymSetupPreset.allCases) { preset in
                    OnboardingChoiceRow(
                        title: L(preset.localizationKey),
                        detail: presetDetail(preset),
                        isSelected: model.equipmentPreset == preset
                    ) {
                        model.applyEquipmentPreset(preset)
                    }
                }
            }
        }
    }

    private func presetDetail(_ preset: GymSetupPreset) -> String {
        guard preset != .custom else { return L(preset.detailLocalizationKey) }
        let count = model.exerciseCount(for: preset.equipment, catalog: catalog)
        return "\(L(preset.detailLocalizationKey)) · \(L("onboarding.equipment.unlocks", count))"
    }

    // MARK: - Individual equipment

    private var equipmentSection: some View {
        OnboardingSection(
            title: L("onboarding.equipment.fineTune"),
            subtitle: L("onboarding.equipment.fineTune.detail"),
            accessory: {
                Text(L("onboarding.equipment.unlocks", model.unlockedExerciseCount(catalog: catalog)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            },
            content: {
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    if equipmentOptions.isEmpty {
                        EmptyStateView(
                            systemImage: "wrench.and.screwdriver",
                            title: L("onboarding.equipment.empty.title"),
                            message: L("onboarding.equipment.empty.message")
                        )
                    } else {
                        LazyVStack(spacing: Metrics.spacing8) {
                            ForEach(equipmentOptions) { item in
                                OnboardingChoiceRow(
                                    title: L(item.localizationKey),
                                    detail: L("onboarding.equipment.unlocks", catalog.count(forEquipment: item)),
                                    systemImage: item.symbolName,
                                    isSelected: model.selectedEquipment.contains(item),
                                    allowsMultiple: true
                                ) {
                                    model.toggleEquipment(item)
                                }
                                .disabled(item == .bodyWeight)
                            }
                        }
                    }

                    if let hint = model.hint(for: "selectedEquipment") {
                        OnboardingInlineHint(message: hint, tint: .appWarning)
                    } else {
                        OnboardingInlineHint(message: L("onboarding.equipment.bodyweightLocked"))
                    }
                }
            }
        )
    }

    // MARK: - Increments

    private var incrementsSection: some View {
        OnboardingSection(L("onboarding.equipment.increments"), subtitle: L("onboarding.equipment.increments.detail")) {
            VStack(alignment: .leading, spacing: Metrics.spacing20) {
                if model.usesBarbell { barbellGroup }
                if model.selectedEquipment.contains(.ezBarbell) { ezBarGroup }
                if model.usesDumbbells { dumbbellGroup }
                if model.usesKettlebells { kettlebellGroup }
                if model.usesMachines { machineGroup }
                if model.selectedEquipment.contains(.cable) { cableGroup }
            }
        }
    }

    private var barbellGroup: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            NumberEntryField(
                title: L("onboarding.equipment.barWeight"),
                value: $model.barbellBarWeightDisplay,
                unit: model.weightUnit.rawValue,
                allowsDecimals: true,
                range: 0...Units.display(kilograms: 100, unit: model.weightUnit),
                step: model.weightUnit == .kilograms ? 2.5 : 5,
                showsStepper: false
            )
            if let hint = model.hint(for: "barbellBarWeightKg") {
                OnboardingInlineHint(message: hint, tint: .appWarning)
            }

            Text(L("onboarding.equipment.plates"))
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
            FlowLayout {
                ForEach(model.plateOptionsKg, id: \.self) { plate in
                    OnboardingChip(
                        title: Units.formatWeight(kilograms: plate, unit: model.weightUnit),
                        isSelected: model.isPlateSelected(plate)
                    ) {
                        model.togglePlate(plate)
                    }
                }
            }
            if let hint = model.hint(for: "plates") {
                OnboardingInlineHint(message: hint, tint: .appWarning)
            } else {
                OnboardingInlineHint(message: L("onboarding.equipment.plates.detail"))
            }
        }
    }

    private var ezBarGroup: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            NumberEntryField(
                title: L("onboarding.equipment.ezBarWeight"),
                value: $model.ezBarWeightDisplay,
                unit: model.weightUnit.rawValue,
                allowsDecimals: true,
                range: 0...Units.display(kilograms: 60, unit: model.weightUnit),
                step: model.weightUnit == .kilograms ? 1 : 2.5,
                showsStepper: false
            )
            if let hint = model.hint(for: "ezBarWeightKg") {
                OnboardingInlineHint(message: hint, tint: .appWarning)
            }
        }
    }

    private var dumbbellGroup: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            SegmentedValuePicker(
                title: L("onboarding.equipment.dumbbellStep"),
                values: model.dumbbellStepOptionsKg,
                label: { Units.formatWeight(kilograms: $0, unit: model.weightUnit) },
                selection: $model.dumbbellStepKg
            )
            OnboardingInlineHint(message: L("onboarding.equipment.dumbbellStep.detail", dumbbellLadderSummary))
        }
    }

    /// Shows the first few rungs of the generated ladder so the choice is concrete rather than
    /// abstract — "2, 4, 6…" is a rack the user can picture.
    private var dumbbellLadderSummary: String {
        OnboardingOptions.dumbbellLadder(step: model.dumbbellStepKg)
            .prefix(4)
            .map { Units.formatWeight(kilograms: $0, unit: model.weightUnit, includeUnit: false) }
            .joined(separator: ", ")
    }

    private var kettlebellGroup: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text(L("onboarding.equipment.kettlebells"))
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
            FlowLayout {
                ForEach(model.kettlebellOptionsKg, id: \.self) { bell in
                    OnboardingChip(
                        title: Units.formatWeight(kilograms: bell, unit: model.weightUnit),
                        isSelected: model.isKettlebellSelected(bell)
                    ) {
                        model.toggleKettlebell(bell)
                    }
                }
            }
        }
    }

    private var machineGroup: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            NumberEntryField(
                title: L("onboarding.equipment.machineIncrement"),
                value: $model.machineIncrementDisplay,
                unit: model.weightUnit.rawValue,
                allowsDecimals: true,
                range: 0...Units.display(kilograms: InputValidation.loadIncrementKg.upperBound, unit: model.weightUnit),
                step: model.weightUnit == .kilograms ? 1 : 2.5,
                showsStepper: false
            )
            if let hint = model.hint(for: "machineIncrementKg") {
                OnboardingInlineHint(message: hint, tint: .appWarning)
            }
        }
    }

    private var cableGroup: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            NumberEntryField(
                title: L("onboarding.equipment.cableIncrement"),
                value: $model.cableIncrementDisplay,
                unit: model.weightUnit.rawValue,
                allowsDecimals: true,
                range: 0...Units.display(kilograms: InputValidation.loadIncrementKg.upperBound, unit: model.weightUnit),
                step: model.weightUnit == .kilograms ? 0.5 : 1,
                showsStepper: false
            )
            if let hint = model.hint(for: "cableIncrementKg") {
                OnboardingInlineHint(message: hint, tint: .appWarning)
            }
        }
    }
}

#Preview("Equipment") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .equipment) { model in
            EquipmentStepView(model: model)
        }
    }
}
