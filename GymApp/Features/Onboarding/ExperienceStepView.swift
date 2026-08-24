import SwiftUI

/// How much training the user has behind them, how sure they are of their technique, and — if they
/// want to say — what they can currently lift.
///
/// Experience is not a badge here. It sets the hardest exercise difficulty the selector may pick,
/// the default reps-in-reserve, and the length of the mesocycle. Technique confidence is asked
/// separately because the two genuinely come apart: plenty of people have trained for years without
/// ever being coached, and a few months of good coaching beats a year of guessing.
struct ExperienceStepView: View {
    @Bindable var model: OnboardingViewModel
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            levelSection
            if model.experience != .never { monthsSection }
            techniqueSection
            strengthSeedSection
        }
    }

    // MARK: - Level

    private var levelSection: some View {
        OnboardingSection(L("onboarding.experience.level"), subtitle: L("onboarding.experience.level.detail")) {
            VStack(spacing: Metrics.spacing8) {
                ForEach(ExperienceLevel.allCases) { level in
                    OnboardingChoiceRow(
                        title: L(level.localizationKey),
                        detail: L(level.detailLocalizationKey),
                        isSelected: model.experience == level
                    ) {
                        model.experience = level
                    }
                }
            }
        }
    }

    // MARK: - Months

    private var monthsSection: some View {
        OnboardingSection(L("onboarding.experience.months"), subtitle: L("onboarding.experience.months.detail")) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                IntegerEntryField(
                    title: L("onboarding.experience.months"),
                    value: $model.trainingMonths,
                    range: 0...900,
                    step: 3,
                    unit: L("onboarding.unit.months")
                )
                if let months = model.trainingMonths, months >= 12 {
                    OnboardingInlineHint(
                        message: L("onboarding.experience.months.years", Units.formatDecimal(Double(months) / 12, digits: 1)),
                        systemImage: "calendar"
                    )
                }
            }
        }
    }

    // MARK: - Technique

    private var techniqueSection: some View {
        OnboardingSection(L("onboarding.experience.technique"), subtitle: L("onboarding.experience.technique.detail")) {
            VStack(spacing: Metrics.spacing8) {
                ForEach(TechniqueConfidence.allCases) { confidence in
                    OnboardingChoiceRow(
                        title: L(confidence.localizationKey),
                        isSelected: model.techniqueConfidence == confidence
                    ) {
                        model.techniqueConfidence = confidence
                    }
                }
            }
        }
    }

    // MARK: - Strength seeds

    private var strengthSeedSection: some View {
        OnboardingSection(
            title: L("onboarding.experience.seeds"),
            subtitle: L("onboarding.experience.seeds.detail"),
            accessory: {
                if model.wantsStrengthSeeds {
                    OnboardingSkipButton(title: L("common.skip")) { model.clearStrengthSeeds() }
                }
            },
            content: {
                if model.strengthSeedOptions.isEmpty {
                    // The benchmark lifts are matched against the catalogue by name. If it has not
                    // finished loading there is nothing to show yet, and the section says so rather
                    // than pretending the question does not exist.
                    LoadingStateView(message: L("onboarding.experience.seeds.loading"))
                        .frame(height: 90)
                } else if model.wantsStrengthSeeds {
                    VStack(spacing: Metrics.spacing12) {
                        ForEach(model.strengthSeedOptions) { option in
                            seedRow(option)
                        }
                        OnboardingInlineHint(message: L("onboarding.experience.seeds.partial"))
                    }
                } else {
                    Button {
                        Haptics.tap()
                        model.wantsStrengthSeeds = true
                    } label: {
                        Label(L("onboarding.experience.seeds.add"), systemImage: "plus.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityHint(Text(L("onboarding.experience.seeds.detail")))
                }
            }
        )
    }

    private func seedRow(_ option: StrengthSeedOption) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                HStack(spacing: Metrics.spacing12) {
                    ExerciseThumbnail(url: environment.mediaProvider.thumbnailURL(for: option.exercise))
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L(option.labelKey))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(option.exercise.name.localizedCapitalized)
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)

                HStack(alignment: .bottom, spacing: Metrics.spacing12) {
                    NumberEntryField(
                        title: L("onboarding.experience.seeds.weight"),
                        value: seedWeightBinding(option),
                        unit: model.weightUnit.rawValue,
                        allowsDecimals: true,
                        range: 0...Units.display(kilograms: InputValidation.loadKg.upperBound, unit: model.weightUnit),
                        step: model.weightUnit == .kilograms ? 2.5 : 5,
                        showsStepper: false
                    )
                    IntegerEntryField(
                        title: L("onboarding.experience.seeds.reps"),
                        value: seedRepsBinding(option),
                        range: 1...30,
                        step: 1,
                        showsStepper: false
                    )
                }
            }
        }
    }

    private func seedWeightBinding(_ option: StrengthSeedOption) -> Binding<Double?> {
        Binding(
            get: { model.seedWeightDisplay(for: option.exercise.id) },
            set: { model.setSeedWeightDisplay($0, for: option.exercise.id) }
        )
    }

    private func seedRepsBinding(_ option: StrengthSeedOption) -> Binding<Int?> {
        Binding(
            get: { model.strengthSeeds[option.exercise.id]?.reps },
            set: { model.setSeedReps($0, for: option.exercise.id) }
        )
    }
}

#Preview("Experience") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .experience) { model in
            ExperienceStepView(model: model)
        }
    }
}
