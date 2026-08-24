import SwiftUI

/// Who the user is: the numbers every energy calculation and load estimate is built on.
///
/// Each field writes straight through to `UserProfile`, so a corrected body mass changes the
/// calorie target and the next session's load estimate immediately. Numeric fields commit on a
/// short debounce and are range-checked first, so a half-typed number never bounces an error.
struct ProfileSettingsView: View {
    @State private var model = SettingsViewModel()

    @State private var nameDraft: String = ""
    @State private var heightDraft: Double?
    @State private var heightFeetDraft: Int?
    @State private var heightInchesDraft: Int?
    @State private var weightDraft: Double?
    @State private var targetWeightDraft: Double?
    @State private var didSyncDrafts = false

    init() {}

    private var formatter: DisplayFormatter { model.formatter }

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)
                identitySection
                bodySection
                activitySection
            }
        }
        // Attached out here rather than inside the list: the rows only exist once the model is
        // ready, so a change fired during loading would land on a view that is not in the tree yet.
        .onChange(of: model.profile?.id, initial: true) { _, _ in syncDrafts() }
        .onChange(of: model.settings?.weightUnit) { _, _ in syncDrafts(force: true) }
        .onChange(of: model.settings?.heightUnit) { _, _ in syncDrafts(force: true) }
        .navigationTitle(L("settings.profile.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Metrics.spacing6) {
                Text(L("settings.profile.name"))
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
                TextField(L("settings.profile.namePlaceholder"), text: $nameDraft)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .font(.appBody)
                    .frame(minHeight: Metrics.minimumTapTarget)
                    .accessibilityLabel(Text(L("settings.profile.name")))
                    .onChange(of: nameDraft) { _, newValue in
                        model.commit("name") { model.updateIdentity(name: .some(newValue)) }
                    }
            }
            .padding(.vertical, Metrics.spacing4)

            birthDateRow

            EnumPickerRow(
                title: L("settings.profile.sex"),
                values: BiologicalSex.allCases,
                label: { L($0.localizationKey) },
                selection: Binding(
                    get: { model.profile?.biologicalSex ?? .unspecified },
                    set: { model.updateIdentity(biologicalSex: $0) }
                )
            )
            SettingsFootnote(text: L("settings.profile.sexExplainer"))
        } header: {
            Text(L("settings.profile.section.identity"))
        }
        .listRowBackground(Color.appSurface)
    }

    /// A date of birth is optional. When it is absent the engines say so rather than assuming an
    /// age, so the control offers adding and removing it rather than defaulting to a date the user
    /// never picked.
    @ViewBuilder
    private var birthDateRow: some View {
        if model.profile?.birthDate != nil {
            DatePicker(
                selection: birthDateBinding,
                in: Self.earliestBirthDate...Self.latestBirthDate,
                displayedComponents: .date
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("settings.profile.birthDate"))
                        .fixedSize(horizontal: false, vertical: true)
                    if let age = model.profile?.ageYears {
                        Text(L("settings.profile.age", age))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            }
            .frame(minHeight: Metrics.minimumTapTarget)

            Button(role: .destructive) {
                model.updateIdentity(birthDate: .some(nil))
            } label: {
                Text(L("settings.profile.removeBirthDate"))
                    .frame(minHeight: Metrics.minimumTapTarget)
            }
            .foregroundStyle(Color.appDanger)
        } else {
            Button {
                model.updateIdentity(birthDate: .some(Self.defaultBirthDate))
            } label: {
                HStack {
                    Text(L("settings.profile.addBirthDate"))
                    Spacer()
                    Image(systemName: "plus.circle")
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Metrics.minimumTapTarget)
            }
            .foregroundStyle(Color.appAccent)
            SettingsFootnote(text: L("settings.profile.birthDateExplainer"))
        }
    }

    private var birthDateBinding: Binding<Date> {
        Binding(
            get: { model.profile?.birthDate ?? Self.defaultBirthDate },
            set: { model.updateIdentity(birthDate: .some($0)) }
        )
    }

    // MARK: - Body

    private var bodySection: some View {
        Section {
            heightControls

            NumberEntryField(
                title: L("settings.profile.currentWeight"),
                value: $weightDraft,
                unit: formatter.weightUnitLabel,
                range: displayWeightRange,
                step: weightStep
            )
            .onChange(of: weightDraft) { _, newValue in
                guard let kilograms = kilograms(from: newValue),
                      InputValidation.bodyMassKg.contains(kilograms) else { return }
                model.commit("weight") { model.updateBodyMetrics(currentWeightKg: kilograms) }
            }

            if let profile = model.profile, profile.targetWeightKg != nil {
                NumberEntryField(
                    title: L("settings.profile.targetWeight"),
                    value: $targetWeightDraft,
                    unit: formatter.weightUnitLabel,
                    range: displayWeightRange,
                    step: weightStep
                )
                .onChange(of: targetWeightDraft) { _, newValue in
                    guard let kilograms = kilograms(from: newValue),
                          InputValidation.bodyMassKg.contains(kilograms) else { return }
                    model.commit("targetWeight") { model.updateBodyMetrics(targetWeightKg: .some(kilograms)) }
                }
                Button(role: .destructive) {
                    targetWeightDraft = nil
                    model.updateBodyMetrics(targetWeightKg: .some(nil))
                } label: {
                    Text(L("settings.profile.removeTargetWeight"))
                        .frame(minHeight: Metrics.minimumTapTarget)
                }
                .foregroundStyle(Color.appDanger)
            } else {
                Button {
                    // Seeded from current body mass so the picker opens somewhere sensible rather
                    // than at zero; the user adjusts from there.
                    let seed = model.profile?.currentWeightKg ?? 75
                    targetWeightDraft = formatter.weightValue(seed)
                    model.updateBodyMetrics(targetWeightKg: .some(seed))
                } label: {
                    HStack {
                        Text(L("settings.profile.addTargetWeight"))
                        Spacer()
                        Image(systemName: "plus.circle").accessibilityHidden(true)
                    }
                    .frame(minHeight: Metrics.minimumTapTarget)
                }
                .foregroundStyle(Color.appAccent)
            }

            SettingsFootnote(text: L("settings.profile.bodyExplainer", weightRangeText, heightRangeText))
        } header: {
            Text(L("settings.profile.section.body"))
        }
        .listRowBackground(Color.appSurface)
    }

    /// Height is entered in whichever shape the unit implies: one field in centimetres, two in feet
    /// and inches. Converting a single decimal field into feet would leave the user typing "5.9" and
    /// meaning something the app cannot guess.
    @ViewBuilder
    private var heightControls: some View {
        if model.settings?.heightUnit == .feetInches {
            HStack(alignment: .bottom, spacing: Metrics.spacing12) {
                IntegerEntryField(
                    title: L("settings.profile.heightFeet"),
                    value: $heightFeetDraft,
                    range: 1...8,
                    showsStepper: false
                )
                IntegerEntryField(
                    title: L("settings.profile.heightInches"),
                    value: $heightInchesDraft,
                    range: 0...11,
                    showsStepper: false
                )
            }
            .onChange(of: heightFeetDraft) { _, _ in commitImperialHeight() }
            .onChange(of: heightInchesDraft) { _, _ in commitImperialHeight() }
        } else {
            NumberEntryField(
                title: L("settings.profile.height"),
                value: $heightDraft,
                unit: "cm",
                allowsDecimals: false,
                range: InputValidation.heightCm,
                step: 1
            )
            .onChange(of: heightDraft) { _, newValue in
                guard let centimetres = newValue, InputValidation.heightCm.contains(centimetres) else { return }
                model.commit("height") { model.updateBodyMetrics(heightCm: centimetres) }
            }
        }
    }

    private func commitImperialHeight() {
        let centimetres = Units.centimeters(
            fromFeet: heightFeetDraft ?? 0,
            inches: Double(heightInchesDraft ?? 0)
        )
        guard InputValidation.heightCm.contains(centimetres) else { return }
        model.commit("height") { model.updateBodyMetrics(heightCm: centimetres) }
    }

    // MARK: - Activity

    private var activitySection: some View {
        Section {
            EnumPickerRow(
                title: L("settings.profile.activity"),
                values: ActivityLevel.allCases,
                label: { L($0.localizationKey) },
                selection: Binding(
                    get: { model.profile?.activityLevel ?? .moderate },
                    set: { model.updateGoals(activityLevel: $0) }
                )
            )
            SettingsFootnote(text: L((model.profile?.activityLevel ?? .moderate).detailLocalizationKey))
            SettingsFootnote(text: L("settings.profile.activityExplainer"))
        } header: {
            Text(L("settings.profile.section.activity"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Drafts

    /// Copies stored values into the editable drafts. Runs once when the rows arrive, and again
    /// whenever a unit changes, because the number on screen then means something different.
    private func syncDrafts(force: Bool = false) {
        guard model.phase == .ready, let profile = model.profile else { return }
        guard force || !didSyncDrafts else { return }
        didSyncDrafts = true
        nameDraft = profile.name ?? ""
        weightDraft = formatter.weightValue(profile.currentWeightKg)
        targetWeightDraft = profile.targetWeightKg.map { formatter.weightValue($0) }
        heightDraft = profile.heightCm.rounded()
        let imperial = Units.feetAndInches(fromCentimeters: profile.heightCm)
        heightFeetDraft = imperial.feet
        heightInchesDraft = Int(imperial.inches.rounded())
    }

    private func kilograms(from displayed: Double?) -> Double? {
        displayed.map { formatter.kilograms(fromDisplayed: $0) }
    }

    private var displayWeightRange: ClosedRange<Double> {
        // Bound to locals first: a leading `...` on a continuation line parses as a prefix
        // operator, which turns this into two statements and no return.
        let lower = formatter.weightValue(InputValidation.bodyMassKg.lowerBound)
        let upper = formatter.weightValue(InputValidation.bodyMassKg.upperBound)
        return lower...upper
    }

    private var weightStep: Double { model.settings?.weightUnit == .pounds ? 1 : 0.5 }

    private var weightRangeText: String {
        "\(formatter.weight(InputValidation.bodyMassKg.lowerBound))–\(formatter.weight(InputValidation.bodyMassKg.upperBound))"
    }

    private var heightRangeText: String {
        "\(formatter.height(InputValidation.heightCm.lowerBound))–\(formatter.height(InputValidation.heightCm.upperBound))"
    }

    private static var defaultBirthDate: Date {
        Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    }

    private static var earliestBirthDate: Date {
        Calendar.current.date(byAdding: .year, value: -InputValidation.ageYears.upperBound, to: Date()) ?? Date()
    }

    private static var latestBirthDate: Date {
        Calendar.current.date(byAdding: .year, value: -InputValidation.ageYears.lowerBound, to: Date()) ?? Date()
    }
}

#Preview("Profile") {
    // A seasoned user has a name, a birth date and a target weight, so every optional control is
    // shown in its populated state.
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            ProfileSettingsView()
        }
    }
}
