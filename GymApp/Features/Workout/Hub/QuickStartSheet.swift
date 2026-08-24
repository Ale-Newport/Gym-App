import SwiftUI

/// Start training without following today's plan.
///
/// Three routes, in the order people actually use them: do the last session again (the commonest
/// request by a wide margin), pick any session out of the program, or start with nothing at all and
/// add exercises as you go. Every one of them creates a real session through the repository — there
/// is no "coming soon" branch here.
struct QuickStartSheet: View {
    let model: WorkoutHubViewModel

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing20) {
                    if let last = model.lastSession {
                        section(
                            title: L("workoutHub.quickStart.repeatTitle"),
                            subtitle: L("workoutHub.quickStart.repeatSubtitle")
                        ) {
                            optionCard(
                                systemImage: "arrow.counterclockwise",
                                title: last.title,
                                detail: L(
                                    "workoutHub.quickStart.repeatDetail",
                                    formatter.mediumDate(last.date),
                                    formatter.volume(last.volumeKg)
                                ),
                                badges: last.focusGroups
                            ) {
                                model.repeatLastSession(router: router)
                                dismiss()
                            }
                        }
                    }

                    if model.quickStartOptions.isEmpty {
                        EmptyStateView(
                            systemImage: "square.grid.3x3",
                            title: L("workoutHub.quickStart.noTemplatesTitle"),
                            message: L("workoutHub.quickStart.noTemplatesMessage")
                        )
                    } else {
                        section(
                            title: L("workoutHub.quickStart.fromProgram"),
                            subtitle: L("workoutHub.quickStart.fromProgramSubtitle")
                        ) {
                            LazyVStack(spacing: Metrics.spacing8) {
                                ForEach(model.quickStartOptions) { option in
                                    optionCard(
                                        systemImage: "list.bullet.rectangle",
                                        title: option.title,
                                        detail: detail(for: option),
                                        badges: option.focusGroups
                                    ) {
                                        model.startTemplate(id: option.id, router: router)
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }

                    section(
                        title: L("workoutHub.quickStart.freestyleTitle"),
                        subtitle: L("workoutHub.quickStart.freestyleSubtitle")
                    ) {
                        optionCard(
                            systemImage: "plus.circle",
                            title: L("workoutHub.quickStart.emptyTitle"),
                            detail: L("workoutHub.quickStart.emptyDetail"),
                            badges: []
                        ) {
                            model.startEmptySession(router: router)
                            dismiss()
                        }
                    }
                }
                .screenPadding()
                .padding(.vertical, Metrics.spacing16)
                .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(L("workoutHub.quickStart.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
            }
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            SectionHeader(title, subtitle: subtitle)
            content()
        }
    }

    private func optionCard(
        systemImage: String,
        title: String,
        detail: String,
        badges: [MuscleGroup],
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Card(padding: Metrics.spacing12) {
                HStack(alignment: .top, spacing: Metrics.spacing12) {
                    Image(systemName: systemImage)
                        .font(.headline)
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 28)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: Metrics.spacing6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if !badges.isEmpty {
                            FlowLayout {
                                ForEach(badges, id: \.self) { group in
                                    MuscleGroupBadge(group: group)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .padding(.top, 4)
                }
                .frame(minHeight: Metrics.gymTapTarget)
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isStarting)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), \(detail)"))
        .accessibilityAddTraits(.isButton)
    }

    private func detail(for option: HubTemplateOption) -> String {
        var parts = [
            L("workoutHub.quickStart.templateDetail", option.exerciseCount, option.totalSets),
            formatter.durationCompact(option.estimatedMinutes * 60)
        ]
        if let weekday = option.weekday {
            parts.append(L(weekday.localizationKey))
        }
        return parts.joined(separator: " · ")
    }
}

#Preview("Quick start") {
    PreviewHost(scenario: .seasonedUser) {
        QuickStartPreviewHarness()
    }
}

/// Loads the hub model so the sheet previews with the sample program's real templates.
private struct QuickStartPreviewHarness: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @State private var model = WorkoutHubViewModel()

    var body: some View {
        QuickStartSheet(model: model)
            .task { await model.load(context: modelContext, catalog: environment.catalog) }
    }
}
