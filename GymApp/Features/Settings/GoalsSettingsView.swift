import SwiftUI

/// What the user is training for, and how experienced they are.
///
/// These are the highest-leverage settings in the app: goals decide rep ranges and energy balance,
/// priorities decide where weekly volume goes, and experience decides both the hardest exercise the
/// programmer will pick and how far from failure sets are prescribed. Every control therefore says
/// what it changes rather than only what it is called.
struct GoalsSettingsView: View {
    @State private var model = SettingsViewModel()
    @State private var monthsDraft: Int?
    @State private var didSyncDrafts = false

    init() {}

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)
                goalsSection
                prioritiesSection
                experienceSection
            }
        }
        .onChange(of: model.profile?.id, initial: true) { _, _ in syncDrafts() }
        .navigationTitle(L("settings.goals.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Goals

    private var goals: [TrainingGoal] { model.profile?.goals ?? [] }

    private var goalsSection: some View {
        Section {
            ChipSelectionRow(
                values: TrainingGoal.allCases,
                label: { L($0.localizationKey) },
                symbol: { $0.symbolName },
                isSelected: { goals.contains($0) },
                toggle: toggleGoal
            )

            if let primary = goals.first {
                // Order carries meaning: the first goal is the one the programmer optimises for,
                // so it is named rather than left for the user to infer from the chip order.
                ExplanationNote(
                    text: L("settings.goals.primary", L(primary.localizationKey), L(primary.detailLocalizationKey)),
                    systemImage: primary.symbolName,
                    tint: .appAccent
                )
                .listRowInsets(EdgeInsets(top: Metrics.spacing8, leading: Metrics.spacing16,
                                          bottom: Metrics.spacing8, trailing: Metrics.spacing16))
            } else {
                SettingsFootnote(text: L("settings.goals.emptyExplainer"))
            }
        } header: {
            Text(L("settings.goals.section.goals"))
        } footer: {
            Text(L("settings.goals.footer"))
        }
        .listRowBackground(Color.appSurface)
    }

    /// Selecting a goal appends it, so the first one the user picked stays primary until they
    /// deselect it. Re-selecting an existing goal removes it.
    private func toggleGoal(_ goal: TrainingGoal) {
        var updated = goals
        if let index = updated.firstIndex(of: goal) {
            updated.remove(at: index)
        } else {
            updated.append(goal)
        }
        model.updateGoals(goals: updated)
    }

    // MARK: - Priorities

    private var prioritiesSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text(L("settings.goals.priorityRegions"))
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
                ChipSelectionRow(
                    values: TrainingFocusRegion.allCases,
                    label: { L($0.localizationKey) },
                    tint: .appRecovery,
                    isSelected: { model.profile?.priorityRegions.contains($0) ?? false },
                    toggle: toggleRegion
                )
            }
            .padding(.vertical, Metrics.spacing4)

            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text(L("settings.goals.priorityMuscles"))
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
                ChipSelectionRow(
                    values: MuscleGroup.selectablePriorities,
                    label: { L($0.localizationKey) },
                    isSelected: { model.profile?.priorityGroups.contains($0) ?? false },
                    toggle: toggleGroup
                )
            }
            .padding(.vertical, Metrics.spacing4)

            if let profile = model.profile, !profile.resolvedPriorityGroups.isEmpty {
                SettingsFootnote(
                    text: L(
                        "settings.goals.priorityResolved",
                        profile.resolvedPriorityGroups.map { L($0.localizationKey) }.joined(separator: ", ")
                    )
                )
            } else {
                SettingsFootnote(text: L("settings.goals.priorityNone"))
            }
        } header: {
            Text(L("settings.goals.section.priorities"))
        } footer: {
            Text(L("settings.goals.prioritiesFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    private func toggleRegion(_ region: TrainingFocusRegion) {
        var updated = model.profile?.priorityRegions ?? []
        if let index = updated.firstIndex(of: region) { updated.remove(at: index) } else { updated.append(region) }
        model.updateGoals(priorityRegions: updated)
    }

    private func toggleGroup(_ group: MuscleGroup) {
        var updated = model.profile?.priorityGroups ?? []
        if let index = updated.firstIndex(of: group) { updated.remove(at: index) } else { updated.append(group) }
        model.updateGoals(priorityGroups: updated)
    }

    // MARK: - Experience

    private var experienceSection: some View {
        Section {
            EnumPickerRow(
                title: L("settings.goals.experience"),
                values: ExperienceLevel.allCases,
                label: { L($0.localizationKey) },
                selection: Binding(
                    get: { model.profile?.experience ?? .beginner },
                    set: { model.updateExperience(level: $0) }
                )
            )
            SettingsFootnote(text: L((model.profile?.experience ?? .beginner).detailLocalizationKey))

            IntegerEntryField(
                title: L("settings.goals.months"),
                value: $monthsDraft,
                range: 0...900,
                step: 1
            )
            .onChange(of: monthsDraft) { _, newValue in
                guard let months = newValue else { return }
                model.commit("experienceMonths") { model.updateExperience(months: months) }
            }

            EnumPickerRow(
                title: L("settings.goals.technique"),
                values: TechniqueConfidence.allCases,
                label: { L($0.localizationKey) },
                selection: Binding(
                    get: { model.profile?.techniqueConfidence ?? .learning },
                    set: { model.updateExperience(techniqueConfidence: $0) }
                )
            )

            SettingsFootnote(
                text: L(
                    "settings.goals.experienceEffect",
                    L((model.profile?.experience ?? .beginner).maximumDifficulty.localizationKey),
                    (model.profile?.experience ?? .beginner).defaultRIR
                )
            )
        } header: {
            Text(L("settings.goals.section.experience"))
        }
        .listRowBackground(Color.appSurface)
    }

    private func syncDrafts() {
        guard !didSyncDrafts, let profile = model.profile else { return }
        didSyncDrafts = true
        monthsDraft = profile.trainingExperienceMonths
    }
}

#Preview("Goals") {
    // The seasoned scenario already has goals and priorities set, which is the state where the
    // ordering rule and the resolved-priority summary are both visible.
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            GoalsSettingsView()
        }
    }
}
