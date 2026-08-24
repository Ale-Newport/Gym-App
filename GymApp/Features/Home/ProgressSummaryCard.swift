import SwiftUI

/// Body mass, the week against the plan, and the streak.
///
/// The weight shown is the seven-day trend rather than the last reading. A single morning weigh-in
/// moves by up to a kilogram on water and gut content alone, so showing it raw would invite the user
/// to react to noise — the whole reason `WeightTrendAnalyzer` exists.
struct ProgressSummaryCard: View {
    let summary: HomeViewModel.ProgressSummary
    var onOpen: () -> Void
    var onLogWeight: () -> Void

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: Metrics.spacing16) {
                        header
                        if summary.trendWeightKg != nil || summary.latestWeightKg != nil {
                            weightRow
                        }
                        weekRow
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(L("home.progress.openTab")))

                // Kept outside the card-wide button: a button inside another button's label never
                // receives the tap.
                if summary.trendWeightKg == nil && summary.latestWeightKg == nil {
                    logWeightRow
                }

                Divider().overlay(Color.appSeparator)

                StreakView(
                    weekStreak: summary.weekStreak,
                    longestWeekStreak: summary.longestWeekStreak,
                    trainedDays: summary.trainedDays
                )
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: Metrics.spacing8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.caption)
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            Text(L("home.progress.title"))
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
                .textCase(.uppercase)
            Spacer(minLength: Metrics.spacing8)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.appTextTertiary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var weightRow: some View {
        if let weight = summary.trendWeightKg ?? summary.latestWeightKg {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing12) {
                VStack(alignment: .leading, spacing: Metrics.spacing2) {
                    Text(L("home.progress.weight"))
                        .font(.appOverline)
                        .foregroundStyle(Color.appTextSecondary)
                    Text(formatter.weight(weight))
                        .font(.appNumeric(24))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: Metrics.spacing8)
                trendBadge
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var logWeightRow: some View {
        HStack(spacing: Metrics.spacing12) {
            Text(L("home.progress.noWeight"))
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.spacing8)
            Button(action: onLogWeight) {
                Text(L("home.progress.logWeight"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(minHeight: Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Direction is carried by the arrow *and* by the sentence, never by colour alone — and the
    /// wording stays neutral, because whether "up" is good depends on a goal this card cannot see.
    private var trendBadge: some View {
        HStack(spacing: Metrics.spacing4) {
            Image(systemName: trendSymbol)
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
            Text(trendText)
                .font(.caption)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.appTextSecondary)
    }

    private var trendSymbol: String {
        guard let change = summary.weeklyChangeKg else { return "questionmark" }
        if change > 0.05 { return "arrow.up.right" }
        if change < -0.05 { return "arrow.down.right" }
        return "arrow.right"
    }

    private var trendText: String {
        guard let change = summary.weeklyChangeKg else { return L("home.progress.trendUnknown") }
        if change > 0.05 { return L("home.progress.trendUp", formatter.weight(change)) }
        if change < -0.05 { return L("home.progress.trendDown", formatter.weight(-change)) }
        return L("home.progress.trendSteady")
    }

    @ViewBuilder
    private var weekRow: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("home.progress.thisWeek"))
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
                Spacer(minLength: Metrics.spacing8)
                Text(summary.plannedSessionsPerWeek > 0
                     ? L("home.progress.sessionsOfPlan", summary.sessionsThisWeek, summary.plannedSessionsPerWeek)
                     : LPlural("home.progress.sessionsDone", summary.sessionsThisWeek))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.appTextPrimary)
            }
            if summary.plannedSessionsPerWeek > 0 {
                ProgressBar(
                    value: Double(summary.sessionsThisWeek),
                    total: Double(summary.plannedSessionsPerWeek),
                    tint: .appAccent,
                    height: 6
                )
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    PreviewHost(scenario: .seasonedUser) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        ScrollView {
            ProgressSummaryCard(
                summary: .init(
                    latestWeightKg: 78.4,
                    trendWeightKg: 78.1,
                    weeklyChangeKg: -0.34,
                    sessionsThisWeek: 2,
                    plannedSessionsPerWeek: 4,
                    weekStreak: 6,
                    longestWeekStreak: 11,
                    trainedDays: Set([0, -2, -4].compactMap {
                        calendar.date(byAdding: .day, value: $0, to: today)
                    })
                ),
                onOpen: {}, onLogWeight: {}
            )
            .screenPadding()
        }
        .background(Color.appBackground)
    }
}
