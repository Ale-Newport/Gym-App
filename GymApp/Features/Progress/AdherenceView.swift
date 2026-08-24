import Charts
import SwiftData
import SwiftUI

/// How closely the plan was followed — sessions, sets and food logging.
///
/// The whole screen is written to be readable on a bad month. Nothing here is styled as a failure:
/// no red, no crosses, no "missed" counters. Adherence data is at its least flattering exactly when
/// somebody is struggling, and a screen that scolds them at that moment is the reason they stop
/// opening the app. It reports what happened and points at the next session.
struct AdherenceView: View {
    let range: ProgressRangeStore

    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model = AdherenceViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                content
            }
            .padding(.vertical, Metrics.spacing16)
            .screenPadding()
            .readableWidth()
        }
        .background(Color.appBackground)
        .navigationTitle(L("progress.adherence.title"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                TimeRangePicker(store: range)
                Divider().overlay(Color.appSeparator)
            }
            .background(.bar)
        }
        .task(id: range.range) { await model.load(context: modelContext, range: range) }
        .refreshable { await model.load(context: modelContext, range: range) }
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
            if model.summary.completedSessions == 0 && model.nutritionDaysLogged == 0 {
                EmptyStateView(
                    systemImage: "calendar",
                    title: L("progress.adherence.empty.title"),
                    message: L("progress.adherence.empty.message")
                ) {
                    Button(L("progress.empty.startWorkout")) { router.selectedTab = .workout }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: 280)
                }
                .frame(minHeight: 320)
            } else {
                loadedContent
            }
        }
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            headline
            ringsCard
            sessionsChart
            consistencyCard
        }
    }

    // MARK: - Headline

    private var headline: some View {
        ExplanationNote(
            text: L(model.encouragementKey),
            systemImage: "hand.thumbsup",
            tint: .appSuccess
        )
    }

    private var ringsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                SectionHeader(
                    L("progress.adherence.overview"),
                    subtitle: L("progress.range.subtitle", L(range.range.localizationKey))
                )
                // Two rings side by side on a phone, four across on an iPad, without a fixed count.
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: Metrics.spacing16)],
                    spacing: Metrics.spacing16
                ) {
                    ringTile(
                        fraction: model.summary.sessionRate,
                        title: L("progress.adherence.sessions"),
                        detail: L(
                            "progress.adherence.sessionsDone",
                            model.summary.completedSessions,
                            model.summary.plannedSessions
                        ),
                        tint: .appSuccess
                    )
                    ringTile(
                        fraction: model.summary.setRate,
                        title: L("progress.adherence.sets"),
                        detail: L(
                            "progress.adherence.setsOf",
                            model.summary.completedSets,
                            model.summary.plannedSets
                        ),
                        tint: .appAccent
                    )
                }
                if model.expectedSessionsPerWeek == nil {
                    Text(L("progress.adherence.noProgramNote"))
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func ringTile(fraction: Double, title: String, detail: String, tint: Color) -> some View {
        VStack(spacing: Metrics.spacing8) {
            ProgressRing(fraction: fraction, lineWidth: 10, tint: tint) {
                Text(L("progress.percent", Int((fraction * 100).rounded())))
                    .font(.appNumeric(18))
                    .foregroundStyle(Color.appTextPrimary)
            }
            .frame(width: 84, height: 84)
            .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text("\(L("progress.percent", Int((fraction * 100).rounded()))), \(detail)"))
    }

    // MARK: - Sessions chart

    private var sessionsChart: some View {
        let planned = model.expectedSessionsPerWeek
        return ChartCard(
            title: L("progress.adherence.weekly"),
            subtitle: L("progress.adherence.weeklySubtitle"),
            footnote: planned == nil ? L("progress.adherence.noPlanFootnote") : nil,
            hasData: model.weeks.contains { $0.completedSessions > 0 },
            emptySystemImage: "calendar",
            emptyMessage: L("progress.adherence.noWeeks"),
            content: {
                Chart {
                    ForEach(model.weeks) { week in
                        BarMark(
                            x: .value(L("progress.axis.date"), week.weekStart, unit: .weekOfYear),
                            y: .value(L("progress.adherence.sessions"), week.completedSessions)
                        )
                        .foregroundStyle(Color.appSuccess)
                        .cornerRadius(3)
                        .accessibilityLabel(Text(L("progress.volume.weekOf", formatter.shortDate(week.weekStart))))
                        .accessibilityValue(Text(L("progress.adherence.sessionsCount", week.completedSessions)))
                    }
                    if let planned, planned > 0 {
                        RuleMark(y: .value(L("progress.adherence.plan"), planned))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .foregroundStyle(Color.appRecovery)
                            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                Text(L("progress.adherence.planPerWeek", planned))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.appRecovery)
                            }
                    }
                }
                .progressDateAxis(range.dateSpan)
                .progressValueAxis(desiredCount: 3)
                .frame(height: 200)
                .chartAccessibilityContainer(L("progress.adherence.weekly"))
            },
            legend: {
                ChartLegendView(keys: [
                    ChartSeriesKey(
                        id: "done", label: L("progress.adherence.completed"),
                        color: .appSuccess, symbolName: "square.fill"
                    ),
                ] + (planned == nil ? [] : [
                    ChartSeriesKey(
                        id: "plan", label: L("progress.adherence.plan"),
                        color: .appRecovery, symbolName: "minus"
                    ),
                ]))
            }
        )
    }

    // MARK: - Consistency

    private var consistencyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                SectionHeader(
                    L("progress.adherence.consistency"),
                    subtitle: L("progress.adherence.consistencySubtitle")
                )
                TargetProgressRow(
                    title: L("progress.adherence.nutritionLogging"),
                    valueText: L("progress.adherence.daysOf", model.nutritionDaysLogged, model.daysInRange),
                    value: Double(model.nutritionDaysLogged),
                    target: Double(max(1, model.daysInRange)),
                    tint: .appNutrition,
                    accessibilityDetail: L("progress.percent", Int((model.nutritionRate * 100).rounded()))
                )
                TargetProgressRow(
                    title: L("progress.adherence.weighIns"),
                    valueText: L("progress.adherence.daysOf", model.weighInDays, model.daysInRange),
                    value: Double(model.weighInDays),
                    target: Double(max(1, model.daysInRange)),
                    tint: .appRecovery
                )
                Text(L("progress.adherence.consistencyNote"))
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview("Adherence") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            AdherenceView(range: ProgressRangeStore())
        }
    }
}
