import SwiftUI

/// Who the user is, physically: the numbers every energy calculation and every load estimate is
/// built on.
///
/// The unit choice sits at the very top rather than in Settings, because every field below it is
/// meaningless until the user knows which unit they are typing in. Everything is stored canonically
/// — kilograms and centimetres — and converted here, at the edge.
struct BasicsStepView: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            unitsSection
            nameSection
            birthDateSection
            sexSection
            bodySection
            targetSection
        }
    }

    // MARK: - Units

    private var unitsSection: some View {
        OnboardingSection(L("onboarding.basics.units"), subtitle: L("onboarding.basics.units.detail")) {
            VStack(spacing: Metrics.spacing12) {
                SegmentedValuePicker(
                    title: L("onboarding.basics.weightUnit"),
                    values: WeightUnit.allCases,
                    label: { L($0.localizationKey) },
                    selection: $model.weightUnit
                )
                SegmentedValuePicker(
                    title: L("onboarding.basics.heightUnit"),
                    values: HeightUnit.allCases,
                    label: { L($0.localizationKey) },
                    selection: $model.heightUnit
                )
            }
        }
    }

    // MARK: - Name

    private var nameSection: some View {
        OnboardingSection(
            title: L("onboarding.basics.name"),
            subtitle: L("onboarding.basics.name.detail"),
            accessory: {
                if !model.name.isEmpty {
                    OnboardingSkipButton(title: L("common.skip")) { model.name = "" }
                }
            },
            content: {
                OnboardingTextField(
                    placeholder: L("onboarding.basics.name.placeholder"),
                    text: $model.name,
                    accessibilityLabel: L("onboarding.basics.name"),
                    systemImage: "person",
                    textContentType: .givenName
                )
            }
        )
    }

    // MARK: - Birth date

    private var birthDateSection: some View {
        OnboardingSection(L("onboarding.basics.birthDate"), subtitle: L("onboarding.basics.birthDate.detail")) {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Toggle(isOn: $model.wantsBirthDate) {
                    Text(L("onboarding.basics.birthDate.toggle"))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(Color.appAccent)
                .frame(minHeight: Metrics.minimumTapTarget)

                if model.wantsBirthDate {
                    DatePicker(
                        L("onboarding.basics.birthDate"),
                        selection: $model.birthDate,
                        in: earliestBirthDate...Date(),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .tint(Color.appAccent)
                    .frame(minHeight: Metrics.minimumTapTarget)

                    if let hint = model.hint(for: "birthDate") {
                        OnboardingInlineHint(message: hint, tint: .appWarning)
                    }
                } else {
                    OnboardingInlineHint(message: L("onboarding.basics.birthDate.skipped"))
                }
            }
        }
    }

    /// The oldest date the picker will offer, derived from the validation range so the two can never
    /// disagree about what counts as a plausible age.
    private var earliestBirthDate: Date {
        Calendar.current.date(
            byAdding: .year, value: -InputValidation.ageYears.upperBound, to: Date()
        ) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: - Biological sex

    private var sexSection: some View {
        OnboardingSection(L("onboarding.basics.sex"), subtitle: L("onboarding.basics.sex.detail")) {
            VStack(spacing: Metrics.spacing8) {
                ForEach(BiologicalSex.allCases) { option in
                    OnboardingChoiceRow(
                        title: L(option.localizationKey),
                        detail: option == .unspecified ? L("onboarding.basics.sex.unspecified.detail") : nil,
                        isSelected: model.biologicalSex == option
                    ) {
                        model.biologicalSex = option
                    }
                }
            }
        }
    }

    // MARK: - Height and weight

    private var bodySection: some View {
        OnboardingSection(L("onboarding.basics.body"), subtitle: L("onboarding.basics.body.detail")) {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                if model.heightUnit == .centimeters {
                    NumberEntryField(
                        title: L("onboarding.basics.height"),
                        value: $model.heightCm,
                        unit: L("onboarding.unit.cm"),
                        allowsDecimals: false,
                        range: InputValidation.heightCm,
                        step: 1
                    )
                } else {
                    HStack(alignment: .bottom, spacing: Metrics.spacing12) {
                        IntegerEntryField(
                            title: L("onboarding.basics.heightFeet"),
                            value: $model.heightFeet,
                            range: 1...8,
                            step: 1,
                            showsStepper: false
                        )
                        IntegerEntryField(
                            title: L("onboarding.basics.heightInches"),
                            value: $model.heightInches,
                            range: 0...11,
                            step: 1,
                            showsStepper: false
                        )
                    }
                }
                if let hint = model.hint(for: "heightCm") {
                    OnboardingInlineHint(message: hint, tint: .appWarning)
                }

                NumberEntryField(
                    title: L("onboarding.basics.weight"),
                    value: $model.currentWeightDisplay,
                    unit: model.weightUnit.rawValue,
                    allowsDecimals: true,
                    range: weightDisplayRange,
                    step: model.weightUnit == .kilograms ? 0.5 : 1
                )
                if let hint = model.hint(for: "currentWeightKg") {
                    OnboardingInlineHint(message: hint, tint: .appWarning)
                }
            }
        }
    }

    private var weightDisplayRange: ClosedRange<Double> {
        // Bound to locals first: a leading `...` on a continuation line parses as a prefix
        // operator, which turns this into two statements and no return.
        let lower = Units.display(kilograms: InputValidation.bodyMassKg.lowerBound, unit: model.weightUnit)
        let upper = Units.display(kilograms: InputValidation.bodyMassKg.upperBound, unit: model.weightUnit)
        return lower...upper
    }

    // MARK: - Target weight

    private var targetSection: some View {
        OnboardingSection(L("onboarding.basics.target"), subtitle: L("onboarding.basics.target.detail")) {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Toggle(isOn: $model.wantsTargetWeight) {
                    Text(L("onboarding.basics.target.toggle"))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tint(Color.appAccent)
                .frame(minHeight: Metrics.minimumTapTarget)
                .onChange(of: model.wantsTargetWeight) { _, isOn in
                    // Seeding the field with the current weight means the stepper starts somewhere
                    // sensible instead of at nothing.
                    if isOn, model.targetWeightKg == nil { model.targetWeightKg = model.currentWeightKg }
                }

                if model.wantsTargetWeight {
                    NumberEntryField(
                        title: L("onboarding.basics.target"),
                        value: $model.targetWeightDisplay,
                        unit: model.weightUnit.rawValue,
                        allowsDecimals: true,
                        range: weightDisplayRange,
                        step: model.weightUnit == .kilograms ? 0.5 : 1
                    )
                    if let hint = model.hint(for: "targetWeightKg") {
                        OnboardingInlineHint(message: hint, tint: .appWarning)
                    } else if let direction = targetDirectionMessage {
                        OnboardingInlineHint(message: direction, systemImage: "arrow.left.and.right")
                    }
                }
            }
        }
    }

    /// Restates the target as a direction and a distance, so a mis-typed number is obvious before it
    /// reaches the calorie engine.
    private var targetDirectionMessage: String? {
        guard let current = model.currentWeightKg, let target = model.targetWeightKg else { return nil }
        let delta = target - current
        guard abs(delta) >= 0.1 else { return L("onboarding.basics.target.same") }
        let amount = Units.formatWeight(kilograms: abs(delta), unit: model.weightUnit)
        return delta < 0
            ? L("onboarding.basics.target.lose", amount)
            : L("onboarding.basics.target.gain", amount)
    }
}

#Preview("Basics") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .basics) { model in
            BasicsStepView(model: model)
        }
    }
}
