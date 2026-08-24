import SwiftData
import SwiftUI

/// Everything the user has ever trained, newest first.
///
/// Grouped by month rather than presented as one endless list, because "how much did I train in
/// March?" is the question people actually ask of a training log, and a month header answers it
/// without a chart. Search matches the exercise names captured in each session, so "when did I last
/// do Romanian deadlifts?" is one query rather than a scroll.
struct WorkoutHistoryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model = WorkoutHistoryViewModel()

    init() {}

    var body: some View {
        @Bindable var model = model

        ZStack {
            Color.appBackground.ignoresSafeArea()

            switch model.state {
            case .loading:
                LoadingStateView(message: L("workoutHub.history.loading"))
            case .failed(let message):
                ScrollView {
                    ErrorStateView(message: message, retryTitle: L("common.retry")) { reload() }
                        .readableWidth()
                }
            case .empty:
                ScrollView {
                    VStack(spacing: Metrics.spacing16) {
                        rangeFilter
                        emptyState
                    }
                    .screenPadding()
                    .readableWidth()
                }
            case .content:
                content
            }
        }
        .navigationTitle(L("workoutHub.history.title"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $model.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(L("workoutHub.history.searchPrompt"))
        )
        .task { await model.load(context: modelContext) }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing20, pinnedViews: []) {
                rangeFilter

                ForEach(model.groups) { group in
                    VStack(alignment: .leading, spacing: Metrics.spacing8) {
                        SectionHeader(
                            monthTitle(group.monthStart),
                            subtitle: L(
                                "workoutHub.history.monthSubtitle",
                                group.sessionCount,
                                formatter.volume(group.volumeKg)
                            )
                        )
                        LazyVStack(spacing: Metrics.spacing8) {
                            ForEach(group.sessions) { session in
                                NavigationLink {
                                    WorkoutSessionDetailView(sessionID: session.id)
                                } label: {
                                    HistoryRow(summary: session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .screenPadding()
            .padding(.vertical, Metrics.spacing16)
            .readableWidth()
        }
    }

    private var rangeFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.spacing8) {
                ForEach(TimeRange.allCases) { range in
                    Button {
                        model.range = range
                        Haptics.selectionChanged()
                    } label: {
                        Chip(title: L(range.localizationKey), isSelected: model.range == range)
                            .frame(minHeight: Metrics.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("workoutHub.history.rangeLabel", L(range.localizationKey))))
                    .accessibilityAddTraits(model.range == range ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isFilteredEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: L("workoutHub.history.noMatchesTitle"),
                message: L("workoutHub.history.noMatchesMessage")
            ) {
                Button(L("common.clearAll")) {
                    model.searchText = ""
                    model.range = .all
                }
                .buttonStyle(SecondaryButtonStyle())
                .frame(maxWidth: 320)
            }
        } else {
            EmptyStateView(
                systemImage: "clock.arrow.circlepath",
                title: L("workoutHub.history.emptyTitle"),
                message: L("workoutHub.history.emptyMessage")
            )
        }
    }

    private func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year().locale(formatter.locale))
    }

    private func reload() {
        Task { await model.load(context: modelContext) }
    }
}

// MARK: - Row

/// One session in the history list.
private struct HistoryRow: View {
    let summary: HubSessionSummary

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        Card(padding: Metrics.spacing12) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(formatter.mediumDate(summary.date))
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Spacer(minLength: Metrics.spacing8)
                    if summary.hasPersonalRecord {
                        HStack(spacing: 3) {
                            Image(systemName: "trophy.fill").font(.caption2)
                            Text(L("workoutHub.history.prBadge")).font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, Metrics.spacing8)
                        .padding(.vertical, 3)
                        .foregroundStyle(Color.appWarning)
                        .background(Color.appWarning.opacity(0.14), in: Capsule())
                    }
                    if summary.status == .skipped {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.appWarning)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextTertiary)
                }

                HStack(spacing: Metrics.spacing16) {
                    metric(systemImage: "clock", text: formatter.durationCompact(summary.durationSeconds))
                    metric(systemImage: "scalemass", text: formatter.volume(summary.volumeKg))
                    metric(
                        systemImage: "square.stack.3d.up",
                        text: L("workoutHub.history.setsOf", summary.completedSets, summary.plannedSets)
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(.isButton)
    }

    private func metric(systemImage: String, text: String) -> some View {
        HStack(spacing: Metrics.spacing4) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(Color.appTextTertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .lineLimit(1)
        }
    }

    private var accessibilityLabel: String {
        var parts = [
            summary.title,
            formatter.mediumDate(summary.date),
            formatter.durationCompact(summary.durationSeconds),
            formatter.volume(summary.volumeKg),
            L("workoutHub.history.setsOf", summary.completedSets, summary.plannedSets)
        ]
        if summary.hasPersonalRecord { parts.append(L("workoutHub.history.prBadgeLong")) }
        if summary.status == .skipped { parts.append(L("sessionStatus.skipped")) }
        return parts.joined(separator: ", ")
    }
}

#Preview("History") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack { WorkoutHistoryView() }
    }
}

#Preview("No history") {
    PreviewHost(scenario: .freshProgram) {
        NavigationStack { WorkoutHistoryView() }
    }
}
