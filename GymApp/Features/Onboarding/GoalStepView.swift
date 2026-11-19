import SwiftUI

/// What the user is training for, and how much training is behind them.
///
/// One goal, picked with one tap. The first goal decides the rep ranges and the direction of the
/// energy balance, so asking for several at once only produces a compromise the user did not
/// choose. Muscle focus appears only for the goal that needs it, and the level sits underneath
/// because it is the second thing every program depends on.
struct GoalStepView: View {
    @Bindable var model: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            goalsSection
            if model.goals.first == .targetMuscleGroup { focusSection }
            levelSection
            nutritionSection
        }
    }

    // MARK: - Goal

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            OnboardingOptionGrid {
                ForEach(TrainingGoal.allCases) { goal in
                    OnboardingOptionTile(
                        title: L(goal.localizationKey),
                        systemImage: goal.symbolName,
                        isSelected: model.goals.first == goal
                    ) {
                        model.selectGoal(goal)
                    }
                }
            }

            // With nothing chosen the footer already says "pick a goal"; repeating it here would
            // put the same sentence on screen twice.
            if let goal = model.goals.first {
                OnboardingInlineHint(message: L(goal.detailLocalizationKey), systemImage: goal.symbolName)
            }
        }
    }

    // MARK: - Muscle focus

    private var focusSection: some View {
        OnboardingSection(
            L("onboarding.goals.muscles"),
            subtitle: L("onboarding.goals.muscles.required")
        ) {
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
                }
            }
        }
    }

    // MARK: - Level

    private var levelSection: some View {
        OnboardingSection(L("start.goal.level")) {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                OnboardingOptionGrid {
                    ForEach(ExperienceLevel.allCases) { level in
                        OnboardingOptionTile(
                            title: L(level.localizationKey),
                            isSelected: model.experience == level
                        ) {
                            model.experience = level
                        }
                    }
                }
                OnboardingInlineHint(
                    message: L(model.experience.detailLocalizationKey),
                    systemImage: "figure.strengthtraining.traditional")
            }
        }
    }

    // MARK: - Nutrition

    private var nutritionSection: some View {
        OnboardingToggleRow(
            systemImage: "fork.knife",
            title: L("start.goal.nutrition"),
            detail: L("start.goal.nutrition.detail"),
            tint: .appNutrition,
            isOn: $model.nutritionEnabled
        )
    }
}

#Preview("Goal") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .goal) { model in
            GoalStepView(model: model)
        }
    }
}
