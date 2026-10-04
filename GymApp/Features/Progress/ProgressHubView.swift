import SwiftData
import SwiftUI

/// Destinations inside the Progress tab.
enum ProgressRoute: Hashable {
    case bodyWeight
    case strength
    case volume
    case records
    case adherence
    case nutrition
    case achievements
}

/// The Progress landing screen.
///
/// A dashboard, not a report: one headline per area, each of which opens the screen that owns the
/// detail. The range picker lives here and is handed down to every destination, so the tab always
/// answers the same question — "how have I done over *this* period?" — from top to bottom.
struct ProgressHubView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var range = ProgressRangeStore()
    @State private var model = ProgressHubViewModel()

    var body: some View {
        @Bindable var router = router

        ProgressRangeScrollView(range: range) {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                content
            }
            .padding(.vertical, Metrics.spacing16)
            .readableWidth()
        }
        .background(Color.appBackground)
        .navigationTitle(L("progress.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.isPresentingWeightEntry = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel(Text(L("progress.weight.add")))
            }
        }
        .navigationDestination(for: ProgressRoute.self) { route in
            destination(for: route)
        }
        .sheet(isPresented: $router.isPresentingWeightEntry) {
            BodyWeightEntrySheet()
        }
        .task(id: range.range) {
            await model.load(context: modelContext, range: range)
        }
        .refreshable {
            await model.load(context: modelContext, range: range)
        }
    }

    // MARK: - Routing

    @ViewBuilder
    private func destination(for route: ProgressRoute) -> some View {
        switch route {
        case .bodyWeight: BodyWeightView(range: range)
        case .strength: StrengthProgressView(range: range)
        case .volume: VolumeProgressView(range: range)
        case .records: PersonalRecordsView(range: range)
        case .adherence: AdherenceView(range: range)
        case .nutrition: NutritionProgressView(range: range)
        case .achievements: AchievementsView()
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("progress.loading"))
                .frame(minHeight: 320)
        case .failed(let message):
            ErrorStateView(message: message, retryTitle: L("common.retry")) {
                Task { await model.load(context: modelContext, range: range) }
            }
            .frame(minHeight: 320)
        case .content:
            if model.hasAnyData {
                loadedContent
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "chart.xyaxis.line",
            title: L("progress.empty.title"),
            message: L("progress.empty.message")
        ) {
            VStack(spacing: Metrics.spacing12) {
                Button(L("progress.empty.startWorkout")) {
                    router.selectedTab = .workout
                }
                .buttonStyle(PrimaryButtonStyle())
                Button(L("progress.weight.add")) {
                    router.isPresentingWeightEntry = true
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: 320)
        }
        .frame(minHeight: 320)
        .screenPadding()
    }

    // MARK: - Content

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            trainingSummary
            bodyWeightCard
            adherenceCard
            recordsCard
            moreRows
        }
        .screenPadding()
    }

    private var trainingSummary: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(L("progress.training.title"), subtitle: rangeSubtitle)
                ScaledTileGrid(minimumWidth: 120) {
                    StatTile(
                        value: String(model.sessionCount),
                        label: L("progress.stat.sessions"),
                        systemImage: "checkmark.circle"
                    )
                    StatTile(
                        value: formatter.volume(model.tonnageKg),
                        label: L("progress.stat.tonnage"),
                        caption: L("progress.stat.tonnage.caption"),
                        systemImage: "scalemass"
                    )
                    StatTile(
                        value: String(model.completedSets),
                        label: L("progress.stat.sets"),
                        systemImage: "list.number"
                    )
                    StatTile(
                        value: formatter.durationCompact(model.activeSeconds),
                        label: L("progress.stat.time"),
                        systemImage: "clock"
                    )
                }
                if model.streaks.currentWeekStreak > 0 {
                    ExplanationNote(
                        text: L("progress.streak.weeks", model.streaks.currentWeekStreak),
                        systemImage: "flame",
                        tint: .appAccent
                    )
                }
            }
        }
    }

    private var bodyWeightCard: some View {
        NavigationLink(value: ProgressRoute.bodyWeight) {
            Card {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    hubCardHeader(
                        title: L("progress.weight.title"),
                        subtitle: L("progress.weight.subtitle")
                    )
                    if model.weightTrendPoints.isEmpty {
                        Text(L("progress.weight.noneYet"))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(alignment: .bottom, spacing: Metrics.spacing16) {
                            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                                Text(formatter.weight(model.weightAnalysis.currentTrendKg ?? model.latestWeightKg ?? 0))
                                    .font(.appNumeric(26))
                                    .foregroundStyle(Color.appTextPrimary)
                                Text(L("progress.weight.trendLabel"))
                                    .font(.caption)
                                    .foregroundStyle(Color.appTextSecondary)
                                if let weekly = model.weightAnalysis.weeklyChangeKg {
                                    DeltaLabel(
                                        text: L("progress.weight.perWeek", signedWeight(weekly)),
                                        direction: weekly > 0.05 ? .up : (weekly < -0.05 ? .down : .flat)
                                    )
                                }
                            }
                            SparklineChart(
                                points: model.weightTrendPoints,
                                tint: .appRecovery,
                                accessibilityDescription: weightChartDescription
                            )
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(L("progress.hub.openHint")))
    }

    private var adherenceCard: some View {
        NavigationLink(value: ProgressRoute.adherence) {
            Card {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    hubCardHeader(
                        title: L("progress.adherence.title"),
                        subtitle: L("progress.adherence.subtitle")
                    )
                    HStack(spacing: Metrics.spacing16) {
                        ProgressRing(fraction: model.adherence.sessionRate, lineWidth: 9, tint: .appSuccess) {
                            Text(percentText(model.adherence.sessionRate))
                                .font(.appNumeric(15))
                                .foregroundStyle(Color.appTextPrimary)
                        }
                        .frame(width: 62, height: 62)
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: Metrics.spacing4) {
                            Text(L(
                                "progress.adherence.sessionsDone",
                                model.adherence.completedSessions,
                                model.adherence.plannedSessions
                            ))
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            Text(L("progress.adherence.setsDone", percentText(model.adherence.setRate)))
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if model.daysInRange > 0 {
                                Text(L("progress.adherence.nutritionDays", model.nutritionDaysLogged, model.daysInRange))
                                    .font(.caption)
                                    .foregroundStyle(Color.appTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(L("progress.hub.openHint")))
    }

    private var recordsCard: some View {
        NavigationLink(value: ProgressRoute.records) {
            Card {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    hubCardHeader(
                        title: L("progress.records.title"),
                        subtitle: L("progress.records.countInRange", model.recordCountInRange)
                    )
                    if model.recentRecords.isEmpty {
                        Text(L("progress.records.noneInRange"))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: Metrics.spacing8) {
                            ForEach(model.recentRecords) { record in
                                PersonalRecordRowView(record: record, showsExerciseName: true)
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(L("progress.hub.openHint")))
    }

    private var moreRows: some View {
        Card(padding: Metrics.spacing8) {
            VStack(spacing: 0) {
                ProgressNavigationRow(
                    route: .strength,
                    systemImage: "figure.strengthtraining.traditional",
                    title: L("progress.strength.title"),
                    subtitle: L("progress.strength.subtitle")
                )
                Divider().overlay(Color.appSeparator).padding(.leading, 52)
                ProgressNavigationRow(
                    route: .volume,
                    systemImage: "chart.bar.xaxis",
                    title: L("progress.volume.title"),
                    subtitle: L("progress.volume.subtitle")
                )
                Divider().overlay(Color.appSeparator).padding(.leading, 52)
                ProgressNavigationRow(
                    route: .nutrition,
                    systemImage: "fork.knife",
                    title: L("progress.nutrition.title"),
                    subtitle: L("progress.nutrition.subtitle")
                )
                Divider().overlay(Color.appSeparator).padding(.leading, 52)
                ProgressNavigationRow(
                    route: .achievements,
                    systemImage: "rosette",
                    title: L("progress.achievements.title"),
                    subtitle: L("progress.achievements.unlockedOf", model.unlockedAchievements, model.totalAchievements)
                )
            }
        }
    }

    // MARK: - Helpers

    private func hubCardHeader(title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appCardTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Metrics.spacing8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.appTextTertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    private var rangeSubtitle: String {
        L("progress.range.subtitle", L(range.range.localizationKey))
    }

    private func percentText(_ fraction: Double) -> String {
        L("progress.percent", Int((fraction * 100).rounded()))
    }

    private func signedWeight(_ kilograms: Double) -> String {
        let displayed = formatter.weightValue(kilograms)
        return Units.formatSignedDecimal(displayed, digits: 2, locale: formatter.locale)
            + "\u{00A0}" + formatter.weightUnitLabel
    }

    private var weightChartDescription: String {
        guard let first = model.weightTrendPoints.first, let last = model.weightTrendPoints.last else {
            return L("progress.weight.title")
        }
        return L(
            "progress.weight.chartSummary",
            formatter.weight(first.value),
            formatter.weight(last.value)
        )
    }
}

/// One row in the hub's "more" card.
private struct ProgressNavigationRow: View {
    let route: ProgressRoute
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: Metrics.spacing12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Metrics.spacing8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Metrics.spacing8)
            .frame(minHeight: Metrics.minimumTapTarget)
            .padding(.vertical, Metrics.spacing6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Progress hub") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            ProgressHubView()
        }
    }
}

#Preview("Progress hub — no data") {
    PreviewHost(scenario: .newUser) {
        NavigationStack {
            ProgressHubView()
        }
    }
}
