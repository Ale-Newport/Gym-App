import SwiftUI

/// How the app plans and runs a session: when the user can train, how progression is decided, how
/// long rests are, and what happens on screen mid-set.
///
/// Values that are chosen from a short, conventional list (rest lengths, session caps) are menus
/// rather than free text — typing "137 seconds" is not a thing anybody wants to do between sets —
/// but a value already stored outside the list is added to it so a restored backup is never
/// silently rounded.
struct TrainingSettingsView: View {
    @State private var model = SettingsViewModel()

    init() {}

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)
                availabilitySection
                programmingSection
                restSection
                duringWorkoutSection
                limitationsSection
            }
        }
        .navigationTitle(L("settings.training.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Availability

    private var availabilitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text(L("settings.training.weekdays"))
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
                ChipSelectionRow(
                    values: Weekday.orderedMondayFirst,
                    label: { L($0.shortLocalizationKey) },
                    isSelected: { model.profile?.availableWeekdays.contains($0) ?? false },
                    toggle: toggleWeekday
                )
            }
            .padding(.vertical, Metrics.spacing4)

            if (model.profile?.availableWeekdays.isEmpty ?? true) {
                SettingsFootnote(text: L("settings.training.noDaysExplainer"))
            }

            Picker(selection: sessionMinutesBinding) {
                ForEach(sessionMinuteOptions, id: \.self) { minutes in
                    Text(Units.formatDurationCompact(seconds: minutes * 60)).tag(minutes)
                }
            } label: {
                Text(L("settings.training.sessionLength"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .pickerStyle(.menu)
            .tint(Color.appAccent)
            .frame(minHeight: Metrics.minimumTapTarget)

            EnumPickerRow(
                title: L("settings.training.preferredTime"),
                values: PreferredTrainingTime.allCases,
                label: { L($0.localizationKey) },
                selection: Binding(
                    get: { model.profile?.preferredTrainingTime ?? .evening },
                    set: { model.updateAvailability(preferredTrainingTime: $0) }
                )
            )

            EnumPickerRow(
                title: L("settings.training.cardio"),
                values: CardioPreference.allCases,
                label: { L($0.localizationKey) },
                selection: Binding(
                    get: { model.profile?.cardioPreference ?? .either },
                    set: { model.updateAvailability(cardioPreference: $0) }
                )
            )
        } header: {
            Text(L("settings.training.section.availability"))
        } footer: {
            Text(L("settings.training.availabilityFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    private func toggleWeekday(_ day: Weekday) {
        var updated = model.profile?.availableWeekdays ?? []
        if let index = updated.firstIndex(of: day) { updated.remove(at: index) } else { updated.append(day) }
        model.updateAvailability(weekdays: updated)
    }

    private var sessionMinutesBinding: Binding<Int> {
        Binding(
            get: { model.profile?.sessionMinutesCap ?? 60 },
            set: { model.updateAvailability(sessionMinutesCap: $0) }
        )
    }

    private var sessionMinuteOptions: [Int] {
        Self.merged([20, 30, 45, 60, 75, 90, 120, 150], with: model.profile?.sessionMinutesCap)
    }

    // MARK: - Programming

    private var programmingSection: some View {
        Section {
            EnumPickerRow(
                title: L("settings.training.progression"),
                values: ProgressionStrategy.allCases,
                label: { L($0.localizationKey) },
                selection: model.settingsBinding(\.progressionStrategy, default: .doubleProgression)
            )
            SettingsFootnote(text: L((model.settings?.progressionStrategy ?? .doubleProgression).detailLocalizationKey))

            Toggle(isOn: model.settingsBinding(\.autoProgressionEnabled, default: true)) {
                settingLabel(L("settings.training.autoProgression"), L("settings.training.autoProgression.detail"))
            }
            Toggle(isOn: model.settingsBinding(\.deloadSuggestionsEnabled, default: true)) {
                settingLabel(L("settings.training.deload"), L("settings.training.deload.detail"))
            }
            Toggle(isOn: model.settingsBinding(\.autoRegulationEnabled, default: true)) {
                settingLabel(L("settings.training.autoregulation"), L("settings.training.autoregulation.detail"))
            }

            Toggle(isOn: rirOverrideEnabledBinding) {
                settingLabel(L("settings.training.rirOverride"), L("settings.training.rirOverride.detail"))
            }
            if model.settings?.targetRIROverride != nil {
                SegmentedValuePicker(
                    title: L("settings.training.targetRIR"),
                    values: Array(InputValidation.repsInReserve.lowerBound...5),
                    label: { String($0) },
                    selection: Binding(
                        get: { model.settings?.targetRIROverride ?? defaultRIR },
                        set: { value in model.updateSettings { $0.targetRIROverride = value } }
                    )
                )
                .padding(.vertical, Metrics.spacing4)
            }
            SettingsFootnote(text: L("settings.training.effectiveRIR", effectiveRIR))
        } header: {
            Text(L("settings.training.section.programming"))
        }
        .listRowBackground(Color.appSurface)
        .tint(Color.appAccent)
    }

    private var defaultRIR: Int { (model.profile?.experience ?? .beginner).defaultRIR }

    private var effectiveRIR: Int { model.settings?.targetRIROverride ?? defaultRIR }

    private var rirOverrideEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.settings?.targetRIROverride != nil },
            set: { isOn in
                // Clearing the override hands the decision back to the experience level rather than
                // freezing whatever number happened to be showing.
                model.updateSettings { $0.targetRIROverride = isOn ? defaultRIR : nil }
            }
        )
    }

    // MARK: - Rest

    private var restSection: some View {
        Section {
            restPicker(L("settings.training.restDefault"), keyPath: \.defaultRestSeconds, fallback: 120)
            restPicker(L("settings.training.restCompound"), keyPath: \.defaultCompoundRestSeconds, fallback: 180)
            restPicker(L("settings.training.restIsolation"), keyPath: \.defaultIsolationRestSeconds, fallback: 75)
        } header: {
            Text(L("settings.training.section.rest"))
        } footer: {
            Text(L("settings.training.restFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    private func restPicker(
        _ title: String,
        keyPath: ReferenceWritableKeyPath<UserSettings, Int>,
        fallback: Int
    ) -> some View {
        let binding = model.settingsBinding(keyPath, default: fallback)
        return Picker(selection: binding) {
            ForEach(Self.merged(Self.restOptions, with: binding.wrappedValue), id: \.self) { seconds in
                Text(Units.formatDuration(seconds: seconds)).tag(seconds)
            }
        } label: {
            Text(title).fixedSize(horizontal: false, vertical: true)
        }
        .pickerStyle(.menu)
        .tint(Color.appAccent)
        .frame(minHeight: Metrics.minimumTapTarget)
    }

    private static let restOptions = [30, 45, 60, 75, 90, 120, 150, 180, 240, 300]

    // MARK: - During a workout

    private var duringWorkoutSection: some View {
        Section {
            Toggle(isOn: model.settingsBinding(\.restTimerAutoStart, default: true)) {
                settingLabel(L("settings.training.restAutoStart"), L("settings.training.restAutoStart.detail"))
            }
            Toggle(isOn: model.settingsBinding(\.restTimerSoundEnabled, default: true)) {
                Text(L("settings.training.restSound")).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: model.settingsBinding(\.restTimerHapticsEnabled, default: true)) {
                Text(L("settings.training.restHaptics")).fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: model.settingsBinding(\.keepScreenAwakeDuringWorkout, default: true)) {
                settingLabel(L("settings.training.keepAwake"), L("settings.training.keepAwake.detail"))
            }
            Toggle(isOn: model.settingsBinding(\.showAnimationsDuringWorkout, default: true)) {
                settingLabel(L("settings.training.showAnimations"), L("settings.training.showAnimations.detail"))
            }
        } header: {
            Text(L("settings.training.section.duringWorkout"))
        }
        .listRowBackground(Color.appSurface)
        .tint(Color.appAccent)
    }

    // MARK: - Limitations

    /// Movements the user has asked not to be given. Recorded as scheduling constraints only — the
    /// app never interprets them, and never stores anything clinical.
    private var limitationsSection: some View {
        Section {
            ChipSelectionRow(
                values: MobilityLimitation.allCases,
                label: { L($0.localizationKey) },
                tint: .appWarning,
                isSelected: { model.profile?.mobilityLimitations.contains($0) ?? false },
                toggle: toggleLimitation
            )
            if let selected = model.profile?.mobilityLimitations, !selected.isEmpty {
                ForEach(selected) { limitation in
                    SettingsFootnote(text: "\(L(limitation.localizationKey)) — \(L(limitation.detailLocalizationKey))")
                }
            } else {
                SettingsFootnote(text: L("settings.training.limitationsNone"))
            }
        } header: {
            Text(L("settings.training.section.limitations"))
        } footer: {
            Text(L("settings.training.limitationsFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    private func toggleLimitation(_ limitation: MobilityLimitation) {
        var updated = model.profile?.mobilityLimitations ?? []
        if let index = updated.firstIndex(of: limitation) {
            updated.remove(at: index)
        } else {
            updated.append(limitation)
        }
        model.updateRestrictions(mobilityLimitations: updated)
    }

    // MARK: - Helpers

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Metrics.spacing2)
    }

    /// Keeps a stored value selectable even when it is not one of the offered options, so a value
    /// restored from a backup or set by an earlier build is never silently changed by this screen.
    private static func merged(_ options: [Int], with current: Int?) -> [Int] {
        guard let current, !options.contains(current) else { return options }
        return (options + [current]).sorted()
    }
}

#Preview("Training") {
    // Fresh program: availability and progression are already populated, and no history exists yet
    // to distract from the defaults being edited.
    PreviewHost(scenario: .freshProgram) {
        NavigationStack {
            TrainingSettingsView()
        }
    }
}
