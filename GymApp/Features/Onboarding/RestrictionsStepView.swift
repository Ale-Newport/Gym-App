import SwiftUI

/// Anything the user would rather the app never programmed.
///
/// The framing is deliberately non-clinical: the app records preferences and scheduling
/// constraints, it does not record diagnoses and it does not give advice. A limitation blocks a set
/// of movement patterns and tags in `ExerciseScoring`; nothing here is interpreted any further than
/// that.
///
/// The whole step is skippable, which is why it sits after the questions that shape the program
/// rather than in the middle of them.
struct RestrictionsStepView: View {
    @Bindable var model: OnboardingViewModel
    @Environment(AppEnvironment.self) private var environment

    @State private var query = ""
    @State private var results: [Exercise] = []
    @State private var isSearching = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            limitationsSection
            patternsSection
            exclusionsSection
        }
    }

    // MARK: - Mobility limitations

    private var limitationsSection: some View {
        OnboardingSection(
            title: L("onboarding.restrictions.limitations"),
            subtitle: L("onboarding.restrictions.limitations.detail"),
            accessory: {
                if !model.mobilityLimitations.isEmpty {
                    OnboardingSkipButton(title: L("common.clear")) {
                        model.mobilityLimitations = []
                        model.avoidedPatterns = []
                    }
                }
            },
            content: {
                VStack(spacing: Metrics.spacing8) {
                    ForEach(MobilityLimitation.allCases) { limitation in
                        OnboardingChoiceRow(
                            title: L(limitation.localizationKey),
                            detail: L(limitation.detailLocalizationKey),
                            isSelected: model.mobilityLimitations.contains(limitation),
                            allowsMultiple: true,
                            tint: .appRecovery
                        ) {
                            model.toggleLimitation(limitation)
                        }
                    }
                }
            }
        )
    }

    // MARK: - Movement patterns

    private var patternsSection: some View {
        OnboardingSection(L("onboarding.restrictions.patterns"), subtitle: L("onboarding.restrictions.patterns.detail")) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                FlowLayout {
                    ForEach(OnboardingOptions.avoidablePatterns, id: \.self) { pattern in
                        let isImplied = model.patternsImpliedByLimitations.contains(pattern)
                        OnboardingChip(
                            title: L(pattern.localizationKey),
                            isSelected: isImplied || model.avoidedPatterns.contains(pattern),
                            tint: .appRecovery,
                            isLocked: isImplied
                        ) {
                            model.togglePattern(pattern)
                        }
                    }
                }

                if !model.patternsImpliedByLimitations.isEmpty {
                    OnboardingInlineHint(
                        message: L("onboarding.restrictions.patterns.implied", model.patternsImpliedByLimitations.count),
                        systemImage: "lock.fill"
                    )
                }
            }
        }
    }

    // MARK: - Excluded exercises

    private var exclusionsSection: some View {
        OnboardingSection(
            title: L("onboarding.restrictions.exclusions"),
            subtitle: L("onboarding.restrictions.exclusions.detail"),
            accessory: {
                if !model.excludedExerciseIDs.isEmpty {
                    OnboardingSkipButton(title: L("common.clear")) { model.excludedExerciseIDs = [] }
                }
            },
            content: {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    if !excludedExercises.isEmpty {
                        FlowLayout {
                            ForEach(excludedExercises) { exercise in
                                OnboardingChip(
                                    title: exercise.name.localizedCapitalized,
                                    systemImage: "xmark",
                                    isSelected: true,
                                    tint: .appDanger
                                ) {
                                    model.toggleExcludedExercise(exercise.id)
                                }
                            }
                        }
                    }

                    OnboardingTextField(
                        placeholder: L("onboarding.restrictions.search.placeholder"),
                        text: $query,
                        accessibilityLabel: L("onboarding.restrictions.search"),
                        systemImage: "magnifyingglass",
                        submitLabel: .search
                    )

                    searchResults
                }
            }
        )
        .task(id: query) { await runSearch() }
    }

    /// Excluded ids resolved back to exercises. Ids the catalogue no longer knows are dropped from
    /// the display rather than shown as blanks; they stay on the profile until the user clears them.
    private var excludedExercises: [Exercise] {
        environment.catalog.exercises(ids: model.excludedExerciseIDs)
    }

    @ViewBuilder
    private var searchResults: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            OnboardingInlineHint(message: L("onboarding.restrictions.search.hint"))
        } else if isSearching {
            LoadingStateView().frame(height: 60)
        } else if results.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: L("onboarding.restrictions.search.empty.title"),
                message: L("onboarding.restrictions.search.empty.message", trimmed)
            ) {
                Button(L("common.clear")) { query = "" }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 200)
            }
        } else {
            LazyVStack(spacing: Metrics.spacing8) {
                ForEach(results) { exercise in
                    Button {
                        Haptics.selectionChanged()
                        model.toggleExcludedExercise(exercise.id)
                    } label: {
                        ExerciseRowView(
                            exercise: exercise,
                            thumbnailURL: environment.mediaProvider.thumbnailURL(for: exercise),
                            isExcluded: model.excludedExerciseIDs.contains(exercise.id),
                            trailingSystemImage: model.excludedExerciseIDs.contains(exercise.id)
                                ? "checkmark.circle.fill" : "plus.circle"
                        )
                        .padding(Metrics.spacing8)
                        .frame(minHeight: Metrics.gymTapTarget)
                        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(
                        model.excludedExerciseIDs.contains(exercise.id)
                            ? L("onboarding.restrictions.exclusions.remove")
                            : L("onboarding.restrictions.exclusions.add")
                    ))
                }
            }
        }
    }

    /// Debounced so a fast typist does not run one ranked search per keystroke over 1,300 rows.
    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        results = environment.catalog.search(trimmed, limit: 20)
        isSearching = false
    }
}

#Preview("Restrictions") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .restrictions) { model in
            RestrictionsStepView(model: model)
        }
    }
}
