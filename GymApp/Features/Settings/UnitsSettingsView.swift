import SwiftUI

/// Units of measure.
///
/// Everything in the store is canonical — kilograms, centimetres, metres, kilocalories — and these
/// four settings only change the presentation edge. Switching them therefore never rewrites a
/// single logged set, which is why the screen can show live examples of the change instead of
/// warning about it.
struct UnitsSettingsView: View {
    @State private var model = SettingsViewModel()

    init() {}

    private var formatter: DisplayFormatter { model.formatter }

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)
                systemSection
                individualSection
                exampleSection
            }
        }
        .navigationTitle(L("settings.units.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Presets

    /// One tap for the common case. It writes all four settings, so it is never left half-applied.
    private var systemSection: some View {
        Section {
            HStack(spacing: Metrics.spacing8) {
                ForEach(UnitSystem.allCases) { system in
                    Button {
                        apply(system)
                        Haptics.selectionChanged()
                    } label: {
                        Text(L(system.localizationKey))
                            .font(.subheadline.weight(currentSystem == system ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Metrics.minimumTapTarget)
                            .foregroundStyle(currentSystem == system ? Color.white : Color.appTextSecondary)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                                    .fill(currentSystem == system ? Color.appAccent : Color.appFill)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(currentSystem == system ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, Metrics.spacing4)

            if currentSystem == nil {
                SettingsFootnote(text: L("settings.units.mixed"))
            }
        } header: {
            Text(L("settings.units.section.system"))
        }
        .listRowBackground(Color.appSurface)
    }

    /// `nil` when the four units do not all belong to one system — a perfectly reasonable state
    /// (kilograms and miles is a common combination), so it is described rather than corrected.
    private var currentSystem: UnitSystem? {
        guard let settings = model.settings else { return nil }
        let isMetric = settings.weightUnit == .kilograms && settings.heightUnit == .centimeters
            && settings.distanceUnit == .kilometers
        let isImperial = settings.weightUnit == .pounds && settings.heightUnit == .feetInches
            && settings.distanceUnit == .miles
        if isMetric { return .metric }
        if isImperial { return .imperial }
        return nil
    }

    private func apply(_ system: UnitSystem) {
        model.updateSettings { settings in
            switch system {
            case .metric:
                settings.weightUnit = .kilograms
                settings.heightUnit = .centimeters
                settings.distanceUnit = .kilometers
            case .imperial:
                settings.weightUnit = .pounds
                settings.heightUnit = .feetInches
                settings.distanceUnit = .miles
            }
        }
    }

    // MARK: - Individual units

    private var individualSection: some View {
        Section {
            EnumPickerRow(
                title: L("settings.units.weight"),
                values: WeightUnit.allCases,
                label: { L($0.localizationKey) },
                selection: model.settingsBinding(\.weightUnit, default: .kilograms)
            )
            EnumPickerRow(
                title: L("settings.units.height"),
                values: HeightUnit.allCases,
                label: { L($0.localizationKey) },
                selection: model.settingsBinding(\.heightUnit, default: .centimeters)
            )
            EnumPickerRow(
                title: L("settings.units.distance"),
                values: DistanceUnit.allCases,
                label: { L($0.localizationKey) },
                selection: model.settingsBinding(\.distanceUnit, default: .kilometers)
            )
            EnumPickerRow(
                title: L("settings.units.energy"),
                values: EnergyUnit.allCases,
                label: { L($0.localizationKey) },
                selection: model.settingsBinding(\.energyUnit, default: .kilocalories)
            )
        } header: {
            Text(L("settings.units.section.individual"))
        } footer: {
            Text(L("settings.units.footer"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Examples

    /// The same four numbers, rendered the way the rest of the app will render them. Cheaper than
    /// explaining the change in words, and it updates the instant a picker moves.
    private var exampleSection: some View {
        Section {
            exampleRow(L("settings.units.example.load"), formatter.weight(100))
            exampleRow(L("settings.units.example.height"), formatter.height(180))
            exampleRow(L("settings.units.example.distance"), formatter.distance(5000))
            exampleRow(L("settings.units.example.energy"), formatter.energy(2200))
            exampleRow(L("settings.units.example.volume"), formatter.volume(12500))
        } header: {
            Text(L("settings.units.section.examples"))
        }
        .listRowBackground(Color.appSurface)
    }

    private func exampleRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.spacing8)
            Text(value)
                .font(.appNumeric(17))
                .foregroundStyle(Color.appTextPrimary)
        }
        .frame(minHeight: Metrics.minimumTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

#Preview("Units") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            UnitsSettingsView()
        }
    }
}
