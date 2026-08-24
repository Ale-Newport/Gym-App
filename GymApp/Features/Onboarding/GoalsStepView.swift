import SwiftUI

/// What the user is training for, and which muscles they want the extra work to land on.
///
/// Goals are an ordered list, not a set. The first one is the primary goal and it decides the rep
/// ranges and the direction of the energy balance; the rest shade the selection. Making the order
/// visible — "Primary" on the first card — is the difference between a user who understands why
/// their program looks the way it does and one who ticked four boxes and got a compromise.
struct GoalsStepView: View {
    @Bindable var model: OnboardingViewModel

    /// Priority muscles only make a difference once there is somewhere to put the extra sets, which
    /// is why the section is framed as optional for everybody except the "focus on a muscle" goal.
    private var prioritiesAreRequired: Bool { model.goals.contains(.targetMuscleGroup) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            goalsSection
            regionsSection
            musclesSection
        }
    }

    // MARK: - Goals

    private var goalsSection: some View {
        OnboardingSection(
            L("onboarding.goals.title"),
            subtitle: L("onboarding.goals.detail")
        ) {
            VStack(spacing: Metrics.spacing8) {
                ForEach(TrainingGoal.allCases) { goal in
                    OnboardingChoiceRow(
                        title: L(goal.localizationKey),
                        detail: L(goal.detailLocalizationKey),
                        systemImage: goal.symbolName,
                        badge: badge(for: goal),
                        isSelected: model.goals.contains(goal),
                        allowsMultiple: true
                    ) {
                        model.toggleGoal(goal)
                    }
                    .disabled(isUnselectable(goal))
                    .opacity(isUnselectable(goal) ? 0.5 : 1)
                }

                if model.goals.count >= 4 {
                    OnboardingInlineHint(message: L("onboarding.goals.limit"))
                }
            }
        }
    }

    /// The first goal is labelled; the rest are numbered so their influence is visibly ranked.
    private func badge(for goal: TrainingGoal) -> String? {
        guard let index = model.goals.firstIndex(of: goal) else { return nil }
        return index == 0 ? L("onboarding.goals.primary") : L("onboarding.goals.rank", index + 1)
    }

    private func isUnselectable(_ goal: TrainingGoal) -> Bool {
        model.goals.count >= 4 && !model.goals.contains(goal)
    }

    // MARK: - Regions

    private var regionsSection: some View {
        OnboardingSection(
            title: L("onboarding.goals.regions"),
            subtitle: L("onboarding.goals.regions.detail"),
            accessory: {
                if !model.priorityRegions.isEmpty {
                    OnboardingSkipButton(title: L("common.clear")) { model.priorityRegions = [] }
                }
            },
            content: {
                FlowLayout {
                    ForEach(TrainingFocusRegion.allCases) { region in
                        OnboardingChip(
                            title: L(region.localizationKey),
                            isSelected: model.priorityRegions.contains(region)
                        ) {
                            model.togglePriorityRegion(region)
                        }
                    }
                }
            }
        )
    }

    // MARK: - Muscle groups

    private var musclesSection: some View {
        OnboardingSection(
            title: L("onboarding.goals.muscles"),
            subtitle: prioritiesAreRequired
                ? L("onboarding.goals.muscles.required")
                : L("onboarding.goals.muscles.detail"),
            accessory: {
                if !model.priorityGroups.isEmpty {
                    OnboardingSkipButton(title: L("common.clear")) { model.priorityGroups = [] }
                }
            },
            content: {
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    FlowLayout {
                        ForEach(MuscleGroup.selectablePriorities) { group in
                            OnboardingChip(
                                title: L(group.localizationKey),
                                isSelected: model.priorityGroups.contains(group),
                                tint: .forGroup(group)
                            ) {
                                model.togglePriorityGroup(group)
                            }
                        }
                    }

                    if let hint = model.hint(for: "priorityGroups") {
                        OnboardingInlineHint(message: hint, tint: .appWarning)
                    } else if model.priorityGroups.count >= 4 {
                        OnboardingInlineHint(message: L("onboarding.goals.muscles.limit"))
                    } else if !model.resolvedPriorityGroups.isEmpty {
                        OnboardingInlineHint(
                            message: L("onboarding.goals.muscles.summary", model.resolvedPriorityGroups.count),
                            systemImage: "sparkles"
                        )
                    }
                }
            }
        )
    }
}

#Preview("Goals") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .goals) { model in
            GoalsStepView(model: model)
        }
    }
}
