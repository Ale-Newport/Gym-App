import SwiftUI

/// Who the user is, physically: the handful of numbers every energy calculation and every load
/// estimate is built on.
///
/// Everything is optional to *read* and quick to *answer*: defaults are filled in, so a user who is
/// happy with them taps Next, and a user who is not changes only the fields that are wrong. The unit
/// system sits at the top because every number below it is meaningless until the user knows which
/// unit they are typing in. Everything is stored canonically — kilograms and centimetres — and
/// converted here, at the edge.
struct AboutStepView: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing20) {
            nameField

            SegmentedValuePicker(
                title: L("start.about.units"),
                values: UnitSystem.allCases,
                label: { L($0.localizationKey) },
                selection: $model.unitSystem
            )

            SegmentedValuePicker(
                title: L("onboarding.basics.sex"),
                values: BiologicalSex.allCases,
                label: { L($0.localizationKey) },
                selection: $model.biologicalSex
            )

            measurements
        }
    }

    // MARK: - Name

    private var nameField: some View {
        OnboardingTextField(
            placeholder: L("start.about.name.placeholder"),
            text: $model.name,
            accessibilityLabel: L("onboarding.basics.name"),
            systemImage: "person",
            textContentType: .givenName
        )
    }

    // MARK: - Age, height and weight

    private var measurements: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            HStack(alignment: .top, spacing: Metrics.spacing12) {
                IntegerEntryField(
                    title: L("start.about.age"),
                    value: $model.ageYears,
                    range: InputValidation.ageYears,
                    step: 1,
                    showsStepper: false,
                    unit: L("start.about.years")
                )
                NumberEntryField(
                    title: L("onboarding.basics.weight"),
                    value: $model.currentWeightDisplay,
                    unit: model.weightUnit.rawValue,
                    allowsDecimals: true,
                    range: weightDisplayRange,
                    step: model.weightUnit == .kilograms ? 0.5 : 1,
                    showsStepper: false
                )
            }
            if let hint = model.hint(for: "birthDate") {
                OnboardingInlineHint(message: hint, tint: .appWarning)
            }
            if let hint = model.hint(for: "currentWeightKg") {
                OnboardingInlineHint(message: hint, tint: .appWarning)
            }

            if model.heightUnit == .centimeters {
                NumberEntryField(
                    title: L("onboarding.basics.height"),
                    value: $model.heightCm,
                    unit: L("onboarding.unit.cm"),
                    allowsDecimals: false,
                    range: InputValidation.heightCm,
                    step: 1,
                    showsStepper: false
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

            OnboardingInlineHint(message: L("start.about.why"), systemImage: "lock")
        }
    }

    private var weightDisplayRange: ClosedRange<Double> {
        // Bound to locals first: a leading `...` on a continuation line parses as a prefix
        // operator, which turns this into two statements and no return.
        let lower = Units.display(kilograms: InputValidation.bodyMassKg.lowerBound, unit: model.weightUnit)
        let upper = Units.display(kilograms: InputValidation.bodyMassKg.upperBound, unit: model.weightUnit)
        return lower...upper
    }
}

#Preview("About") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .about) { model in
            AboutStepView(model: model)
        }
    }
}
