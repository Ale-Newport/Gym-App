import SwiftUI

/// What the user can train with, and the exact weights their gym stocks.
///
/// The increments matter more than they look: `LoadRounding` snaps every prescribed load onto them,
/// so a gym with 1.25 kg micro-plates and a gym with 5 kg jumps get genuinely different programmes.
/// Getting them right here is what stops the app asking for 47.3 kg on a barbell.
struct EquipmentSettingsView: View {
    @State private var model = SettingsViewModel()
    @State private var barDraft: Double?
    @State private var ezBarDraft: Double?
    @State private var machineDraft: Double?
    @State private var cableDraft: Double?
    @State private var didSyncDrafts = false
    @State private var showsAdditionalEquipment = false

    init() {}

    private var formatter: DisplayFormatter { model.formatter }

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)
                presetSection
                equipmentSection
                outOfServiceSection
                incrementsSection
                ladderSections
            }
        }
        .onChange(of: model.equipment?.id, initial: true) { _, _ in syncDrafts() }
        .onChange(of: model.settings?.weightUnit) { _, _ in syncDrafts(force: true) }
        .navigationTitle(L("settings.equipment.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Preset

    private var presetSection: some View {
        Section {
            EnumPickerRow(
                title: L("settings.equipment.preset"),
                values: GymSetupPreset.allCases,
                label: { L($0.localizationKey) },
                selection: Binding(
                    get: { model.equipment?.preset ?? .fullGym },
                    set: { model.updateEquipment(preset: $0) }
                )
            )
            SettingsFootnote(text: L((model.equipment?.preset ?? .fullGym).detailLocalizationKey))
        } header: {
            Text(L("settings.equipment.section.preset"))
        } footer: {
            Text(L("settings.equipment.presetFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Equipment

    private var owned: Set<Equipment> { Set(model.equipment?.availableEquipment ?? []) }

    private var equipmentSection: some View {
        Section {
            ChipSelectionRow(
                values: Equipment.primarySelectable,
                label: { L($0.localizationKey) },
                symbol: { $0.symbolName },
                isSelected: { owned.contains($0) },
                toggle: toggleEquipment
            )

            DisclosureGroup(isExpanded: $showsAdditionalEquipment) {
                ChipSelectionRow(
                    values: Equipment.additionalSelectable,
                    label: { L($0.localizationKey) },
                    symbol: { $0.symbolName },
                    isSelected: { owned.contains($0) },
                    toggle: toggleEquipment
                )
            } label: {
                Text(L("settings.equipment.more"))
                    .frame(minHeight: Metrics.minimumTapTarget)
            }

            if owned.isEmpty {
                // An empty list is treated as "bodyweight only" by the selector rather than as an
                // empty gym, and saying so is better than letting the user wonder.
                SettingsFootnote(text: L("settings.equipment.emptyExplainer"))
            } else {
                SettingsFootnote(text: L("settings.equipment.itemsCount", owned.count))
            }
        } header: {
            Text(L("settings.equipment.section.available"))
        }
        .listRowBackground(Color.appSurface)
    }

    private func toggleEquipment(_ item: Equipment) {
        var updated = owned
        if updated.contains(item) { updated.remove(item) } else { updated.insert(item) }
        model.updateEquipment(availableEquipment: updated)
    }

    // MARK: - Out of service

    /// A broken machine is a temporary fact, not a change of gym. Keeping it separate from the
    /// owned list means putting it back is one tap and the user's real setup is never lost.
    @ViewBuilder
    private var outOfServiceSection: some View {
        if let equipment = model.equipment, !equipment.availableEquipment.isEmpty {
            Section {
                ForEach(equipment.availableEquipment) { item in
                    Toggle(isOn: Binding(
                        get: { equipment.temporarilyUnavailable.contains(item) },
                        set: { model.setTemporarilyUnavailable(item, unavailable: $0) }
                    )) {
                        Label {
                            Text(L(item.localizationKey)).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: item.symbolName).foregroundStyle(Color.appTextSecondary)
                        }
                    }
                    .frame(minHeight: Metrics.minimumTapTarget)
                }

                if !equipment.temporarilyUnavailable.isEmpty {
                    Button {
                        model.clearTemporarilyUnavailable()
                    } label: {
                        Text(L("settings.equipment.clearOutOfService"))
                            .frame(minHeight: Metrics.minimumTapTarget)
                    }
                    .foregroundStyle(Color.appAccent)
                }
            } header: {
                Text(L("settings.equipment.section.outOfService"))
            } footer: {
                Text(L("settings.equipment.outOfServiceFooter"))
            }
            .listRowBackground(Color.appSurface)
            .tint(Color.appWarning)
        }
    }

    // MARK: - Increments

    private var incrementsSection: some View {
        Section {
            NumberEntryField(
                title: L("settings.equipment.barWeight"),
                value: $barDraft,
                unit: formatter.weightUnitLabel,
                range: 0...displayMaxLoad,
                step: incrementStep
            )
            .onChange(of: barDraft) { _, newValue in
                guard let kilograms = kilograms(from: newValue), InputValidation.loadKg.contains(kilograms) else { return }
                model.commit("barWeight") { model.updateIncrements(barbellBarWeightKg: kilograms) }
            }

            NumberEntryField(
                title: L("settings.equipment.ezBarWeight"),
                value: $ezBarDraft,
                unit: formatter.weightUnitLabel,
                range: 0...displayMaxLoad,
                step: incrementStep
            )
            .onChange(of: ezBarDraft) { _, newValue in
                guard let kilograms = kilograms(from: newValue), InputValidation.loadKg.contains(kilograms) else { return }
                model.commit("ezBarWeight") { model.updateIncrements(ezBarWeightKg: kilograms) }
            }

            NumberEntryField(
                title: L("settings.equipment.machineStep"),
                value: $machineDraft,
                unit: formatter.weightUnitLabel,
                range: displayIncrementRange,
                step: incrementStep
            )
            .onChange(of: machineDraft) { _, newValue in
                guard let kilograms = kilograms(from: newValue),
                      InputValidation.loadIncrementKg.contains(kilograms) else { return }
                model.commit("machineStep") { model.updateIncrements(machineIncrementKg: kilograms) }
            }

            NumberEntryField(
                title: L("settings.equipment.cableStep"),
                value: $cableDraft,
                unit: formatter.weightUnitLabel,
                range: displayIncrementRange,
                step: incrementStep
            )
            .onChange(of: cableDraft) { _, newValue in
                guard let kilograms = kilograms(from: newValue),
                      InputValidation.loadIncrementKg.contains(kilograms) else { return }
                model.commit("cableStep") { model.updateIncrements(cableIncrementKg: kilograms) }
            }

            SettingsFootnote(text: L("settings.equipment.incrementsFooter"))
        } header: {
            Text(L("settings.equipment.section.increments"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Ladders

    @ViewBuilder
    private var ladderSections: some View {
        if let equipment = model.equipment {
            Section {
                LoadLadderEditor(
                    valuesKg: equipment.availablePlatesKg,
                    formatter: formatter,
                    defaults: Self.defaultPlatesKg,
                    addLabel: L("settings.equipment.addPlate")
                ) { model.updateIncrements(availablePlatesKg: $0) }
            } header: {
                Text(L("settings.equipment.section.plates"))
            } footer: {
                Text(L("settings.equipment.platesFooter"))
            }
            .listRowBackground(Color.appSurface)

            Section {
                LoadLadderEditor(
                    valuesKg: equipment.availableDumbbellsKg,
                    formatter: formatter,
                    defaults: Self.defaultDumbbellsKg,
                    addLabel: L("settings.equipment.addDumbbell")
                ) { model.updateIncrements(availableDumbbellsKg: $0) }
            } header: {
                Text(L("settings.equipment.section.dumbbells"))
            } footer: {
                Text(L("settings.equipment.dumbbellsFooter"))
            }
            .listRowBackground(Color.appSurface)

            Section {
                LoadLadderEditor(
                    valuesKg: equipment.kettlebellsKg,
                    formatter: formatter,
                    defaults: Self.defaultKettlebellsKg,
                    addLabel: L("settings.equipment.addKettlebell")
                ) { model.updateIncrements(kettlebellsKg: $0) }
            } header: {
                Text(L("settings.equipment.section.kettlebells"))
            }
            .listRowBackground(Color.appSurface)
        }
    }

    private static let defaultPlatesKg: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25]
    private static let defaultDumbbellsKg: [Double] = [
        2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22.5, 25, 27.5, 30, 32.5, 35, 37.5, 40, 45, 50,
    ]
    private static let defaultKettlebellsKg: [Double] = [8, 12, 16, 20, 24, 28, 32]

    // MARK: - Helpers

    private func syncDrafts(force: Bool = false) {
        guard let equipment = model.equipment else { return }
        guard force || !didSyncDrafts else { return }
        didSyncDrafts = true
        barDraft = formatter.weightValue(equipment.barbellBarWeightKg)
        ezBarDraft = formatter.weightValue(equipment.ezBarWeightKg)
        machineDraft = formatter.weightValue(equipment.machineIncrementKg)
        cableDraft = formatter.weightValue(equipment.cableIncrementKg)
    }

    private func kilograms(from displayed: Double?) -> Double? {
        displayed.map { formatter.kilograms(fromDisplayed: $0) }
    }

    private var displayMaxLoad: Double { formatter.weightValue(InputValidation.loadKg.upperBound) }

    private var displayIncrementRange: ClosedRange<Double> {
        formatter.weightValue(InputValidation.loadIncrementKg.lowerBound)
            ...formatter.weightValue(InputValidation.loadIncrementKg.upperBound)
    }

    private var incrementStep: Double { model.settings?.weightUnit == .pounds ? 1 : 0.5 }
}

// MARK: - Ladder editor

/// Edits one ladder of selectable loads — plates, dumbbells or kettlebells.
///
/// The list is displayed and entered in the user's unit but stored in kilograms, and it can never
/// be emptied: `LoadRounding` needs something to round onto, so the last entry is not removable and
/// a "restore defaults" action exists for a list that somehow arrived empty.
private struct LoadLadderEditor: View {
    let valuesKg: [Double]
    let formatter: DisplayFormatter
    let defaults: [Double]
    let addLabel: String
    let commit: ([Double]) -> Void

    @State private var draft: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            if valuesKg.isEmpty {
                EmptyStateView(
                    systemImage: "scalemass",
                    title: L("settings.equipment.ladderEmpty.title"),
                    message: L("settings.equipment.ladderEmpty.message")
                ) {
                    Button(L("settings.equipment.restoreDefaults")) { commit(defaults) }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 260)
                }
            } else {
                FlowLayout(spacing: Metrics.spacing8, lineSpacing: Metrics.spacing8) {
                    ForEach(valuesKg.sorted(), id: \.self) { value in
                        Button {
                            remove(value)
                        } label: {
                            HStack(spacing: Metrics.spacing6) {
                                Text(formatter.weight(value, includeUnit: false))
                                    .font(.subheadline.weight(.semibold))
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                            }
                            .padding(.horizontal, Metrics.spacing12)
                            .padding(.vertical, Metrics.spacing8)
                            .foregroundStyle(Color.appTextPrimary)
                            .background(Capsule().fill(Color.appFill))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: Metrics.minimumTapTarget)
                        .disabled(valuesKg.count == 1)
                        .accessibilityLabel(Text(L("settings.equipment.removeWeight", formatter.weight(value))))
                    }
                }

                HStack(alignment: .bottom, spacing: Metrics.spacing12) {
                    NumberEntryField(
                        title: addLabel,
                        value: $draft,
                        unit: formatter.weightUnitLabel,
                        range: 0...formatter.weightValue(InputValidation.loadKg.upperBound),
                        step: 1.25,
                        showsStepper: false
                    )
                    Button {
                        add()
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .frame(width: Metrics.gymTapTarget, height: Metrics.gymTapTarget)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                                    .fill(Color.appAccent.opacity(0.16))
                            )
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAdd)
                    .opacity(canAdd ? 1 : 0.4)
                    .accessibilityLabel(Text(L("common.add")))
                }

                if valuesKg.count == 1 {
                    SettingsFootnote(text: L("settings.equipment.lastWeight"))
                }
            }
        }
        .padding(.vertical, Metrics.spacing4)
    }

    private var canAdd: Bool {
        guard let draft else { return false }
        let kilograms = formatter.kilograms(fromDisplayed: draft)
        return kilograms > 0 && !valuesKg.contains(kilograms)
    }

    private func add() {
        guard let draft else { return }
        let kilograms = formatter.kilograms(fromDisplayed: draft)
        guard kilograms > 0 else { return }
        commit((valuesKg + [kilograms]).sorted())
        self.draft = nil
        Haptics.tap()
    }

    private func remove(_ value: Double) {
        guard valuesKg.count > 1 else { return }
        commit(valuesKg.filter { $0 != value })
        Haptics.tap()
    }
}

#Preview("Equipment") {
    // Fresh program: a full-gym preset with every ladder populated, which is the busiest this
    // screen ever gets.
    PreviewHost(scenario: .freshProgram) {
        NavigationStack {
            EquipmentSettingsView()
        }
    }
}
