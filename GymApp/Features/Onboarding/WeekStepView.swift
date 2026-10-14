import SwiftUI

/// When the user can train and for how long.
///
/// This is the step that decides the shape of the program. `SplitSelector` picks a structure from
/// the number of days; the time cap decides how many sets each session can actually hold. The
/// daily-activity question is a nutrition input rather than a training one, but it belongs to the
/// same question — "what does your week look like?" — so it is asked here rather than twice.
struct WeekStepView: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            daysSection
            lengthSection
            activitySection
        }
    }

    // MARK: - Days

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            SegmentedValuePicker(
                title: L("onboarding.availability.perWeek"),
                values: Array(InputValidation.daysPerWeek),
                label: { String($0) },
                selection: daysPerWeekBinding
            )

            // One row of day chips, so the "which days" refinement costs a glance rather than a
            // section of its own.
            HStack(spacing: Metrics.spacing6) {
                ForEach(Weekday.orderedMondayFirst) { day in
                    dayChip(day)
                }
            }

            if let hint = model.hint(for: "availableWeekdays") {
                OnboardingInlineHint(message: hint, tint: .appWarning)
            } else {
                OnboardingInlineHint(message: L("start.week.days.hint"), systemImage: "calendar")
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

    private func dayChip(_ day: Weekday) -> some View {
        let isSelected = model.availableWeekdays.contains(day)
        return Button {
            Haptics.selectionChanged()
            model.toggleWeekday(day)
        } label: {
            Text(L(day.shortLocalizationKey))
                .font(.footnote.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: Metrics.minimumTapTarget)
                .foregroundStyle(isSelected ? Color.appOnAccent : Color.appTextSecondary)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                        .fill(isSelected ? Color.appAccent : Color.appFill)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L(day.localizationKey)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Session length

    private var lengthSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            SegmentedValuePicker(
                title: L("onboarding.availability.length"),
                values: OnboardingSchedule.sessionMinuteOptions,
                label: { L("onboarding.unit.minutesShort", $0) },
                selection: $model.sessionMinutes
            )
            if let hint = model.hint(for: "sessionMinutes") {
                OnboardingInlineHint(message: hint, tint: .appWarning)
            } else if model.sessionMinutes < 40 {
                // Not a refusal — short sessions work — but the trade-off should be stated before
                // the program comes back leaner than the user expected.
                OnboardingInlineHint(message: L("onboarding.availability.length.short"))
            }
        }
    }

    // MARK: - Daily activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text(L("onboarding.availability.activity"))
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)

            Menu {
                Picker(L("onboarding.availability.activity"), selection: $model.activityLevel) {
                    ForEach(ActivityLevel.allCases) { level in
                        Text(L(level.localizationKey)).tag(level)
                    }
                }
            } label: {
                HStack {
                    Text(L(model.activityLevel.localizationKey))
                        .font(.body)
                        .foregroundStyle(Color.appTextPrimary)
                    Spacer(minLength: Metrics.spacing8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote)
                        .foregroundStyle(Color.appTextTertiary)
                }
                .padding(.horizontal, Metrics.spacing12)
                .frame(minHeight: Metrics.gymTapTarget)
                .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
            }
            .accessibilityLabel(Text(L("onboarding.availability.activity")))
            .accessibilityValue(Text(L(model.activityLevel.localizationKey)))

            OnboardingInlineHint(message: L(model.activityLevel.detailLocalizationKey), systemImage: "figure.walk")
        }
    }
}

#Preview("Week") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .week) { model in
            WeekStepView(model: model)
        }
    }
}
