import SwiftUI

/// When the user can train, for how long, and how much they move the rest of the time.
///
/// This is the step that decides the shape of the program. `SplitSelector` picks a structure from
/// the number of days; the time cap decides how many sets each session can actually hold; the
/// activity level is a nutrition input rather than a training one, but it belongs to the same
/// question — "what does your week look like?" — so it is asked here rather than twice.
struct AvailabilityStepView: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            daysSection
            lengthSection
            timeSection
            cardioSection
            activitySection
        }
    }

    // MARK: - Days

    private var daysSection: some View {
        OnboardingSection(L("onboarding.availability.days"), subtitle: L("onboarding.availability.days.detail")) {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SegmentedValuePicker(
                    title: L("onboarding.availability.perWeek"),
                    values: Array(InputValidation.daysPerWeek),
                    label: { String($0) },
                    selection: daysPerWeekBinding
                )

                FlowLayout {
                    ForEach(Weekday.orderedMondayFirst) { day in
                        OnboardingChip(
                            title: L(day.shortLocalizationKey),
                            isSelected: model.availableWeekdays.contains(day)
                        ) {
                            model.toggleWeekday(day)
                        }
                    }
                }

                if let hint = model.hint(for: "availableWeekdays") {
                    OnboardingInlineHint(message: hint, tint: .appWarning)
                } else {
                    OnboardingInlineHint(
                        message: L("onboarding.availability.days.summary", model.daysPerWeek),
                        systemImage: "calendar"
                    )
                }
            }
        }
    }

    /// Changing the count re-seeds well-spaced days; picking individual days then refines it. The
    /// binding reads back from the actual selection so the two controls never disagree.
    private var daysPerWeekBinding: Binding<Int> {
        Binding(
            get: { model.daysPerWeek },
            set: { model.setDaysPerWeek($0) }
        )
    }

    // MARK: - Session length

    private var lengthSection: some View {
        OnboardingSection(L("onboarding.availability.length"), subtitle: L("onboarding.availability.length.detail")) {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                FlowLayout {
                    ForEach(OnboardingSchedule.sessionMinuteOptions, id: \.self) { minutes in
                        OnboardingChip(
                            title: L("onboarding.unit.minutesShort", minutes),
                            isSelected: model.sessionMinutes == minutes
                        ) {
                            model.sessionMinutes = minutes
                        }
                    }
                }

                OnboardingStepperRow(
                    title: L("onboarding.availability.lengthFine"),
                    subtitle: L("onboarding.availability.lengthFine.detail"),
                    value: model.sessionMinutes,
                    range: InputValidation.sessionMinutes,
                    step: 5,
                    formatted: L("onboarding.unit.minutesShort", model.sessionMinutes)
                ) { model.sessionMinutes = $0 }

                if let hint = model.hint(for: "sessionMinutes") {
                    OnboardingInlineHint(message: hint, tint: .appWarning)
                } else if model.sessionMinutes < 40 {
                    // Not a refusal — short sessions work — but the trade-off should be stated
                    // before the program comes back leaner than the user expected.
                    OnboardingInlineHint(message: L("onboarding.availability.length.short"))
                }
            }
        }
    }

    // MARK: - Preferred time

    private var timeSection: some View {
        OnboardingSection(L("onboarding.availability.time"), subtitle: L("onboarding.availability.time.detail")) {
            FlowLayout {
                ForEach(PreferredTrainingTime.allCases) { option in
                    OnboardingChip(
                        title: L(option.localizationKey),
                        isSelected: model.preferredTrainingTime == option
                    ) {
                        model.preferredTrainingTime = option
                    }
                }
            }
        }
    }

    // MARK: - Cardio

    private var cardioSection: some View {
        OnboardingSection(L("onboarding.availability.cardio"), subtitle: L("onboarding.availability.cardio.detail")) {
            VStack(spacing: Metrics.spacing8) {
                ForEach(CardioPreference.allCases) { option in
                    OnboardingChoiceRow(
                        title: L(option.localizationKey),
                        isSelected: model.cardioPreference == option
                    ) {
                        model.cardioPreference = option
                    }
                }
            }
        }
    }

    // MARK: - Daily activity

    private var activitySection: some View {
        OnboardingSection(L("onboarding.availability.activity"), subtitle: L("onboarding.availability.activity.detail")) {
            VStack(spacing: Metrics.spacing8) {
                ForEach(ActivityLevel.allCases) { level in
                    OnboardingChoiceRow(
                        title: L(level.localizationKey),
                        detail: L(level.detailLocalizationKey),
                        isSelected: model.activityLevel == level
                    ) {
                        model.activityLevel = level
                    }
                }
            }
        }
    }
}

#Preview("Availability") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .availability) { model in
            AvailabilityStepView(model: model)
        }
    }
}
