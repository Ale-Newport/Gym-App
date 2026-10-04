import Charts
import SwiftData
import SwiftUI

/// Energy and macronutrients over time, measured against the active target.
///
/// The day is the unit of logging but the *week* is the unit of meaning: one heavy Saturday says
/// nothing, and the weekly average line exists so nobody reads a single bar as a verdict. Days with
/// no food logged are drawn as gaps rather than as zeroes — an unlogged day is missing data, not a
/// day of fasting, and filling it with a zero would drag every average down.
struct NutritionProgressView: View {
    let range: ProgressRangeStore

    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model = NutritionProgressViewModel()

    var body: some View {
        ProgressRangeScrollView(range: range) {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                content
            }
            .padding(.vertical, Metrics.spacing16)
            .screenPadding()
            .readableWidth()
        }
        .background(Color.appBackground)
        .navigationTitle(L("progress.nutrition.title"))
        .navigationBarTitleDisplayMode(.inline)
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
            if model.loggedDays.isEmpty {
                EmptyStateView(
                    systemImage: "fork.knife",
                    title: L("progress.nutrition.empty.title"),
                    message: L("progress.nutrition.empty.message")
                ) {
                    Button(L("progress.nutrition.openTab")) { router.selectedTab = .nutrition }
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
            summaryTiles
            energyChart
            averageDayCard
            macroChart
        }
    }

    // MARK: - Summary

    private var summaryTiles: some View {
        ScaledTileGrid(minimumWidth: 130) {
            StatTile(
                value: model.averageMacros.map { formatter.energy($0.kilocalories) } ?? "—",
                label: L("progress.nutrition.averageDay"),
                caption: L("progress.nutrition.loggedOnly"),
                tint: .appNutrition,
                systemImage: "flame"
            )
            StatTile(
                value: model.target.map { formatter.energy($0.kilocalories) } ?? "—",
                label: L("progress.nutrition.target"),
                systemImage: "target"
            )
            StatTile(
                value: L("progress.adherence.daysOf", model.loggedDays.count, model.days.count),
                label: L("progress.nutrition.daysLogged"),
                systemImage: "calendar"
            )
        }
    }

    // MARK: - Energy

    private var energyChart: some View {
        ChartCard(
            title: L("progress.nutrition.energyTitle"),
            subtitle: L("progress.nutrition.energySubtitle", formatter.energyUnitLabel),
            footnote: energyFootnote,
            hasData: !model.loggedDays.isEmpty,
            emptySystemImage: "flame",
            emptyMessage: L("progress.nutrition.noDays"),
            content: {
                Chart {
                    ForEach(model.loggedDays) { day in
                        BarMark(
                            x: .value(L("progress.axis.date"), day.date, unit: .day),
                            y: .value(L("progress.nutrition.energyTitle"), energyValue(day.macros.kilocalories))
                        )
                        .foregroundStyle(Color.appNutrition.opacity(0.75))
                        .cornerRadius(2)
                        .accessibilityLabel(Text(formatter.mediumDate(day.date)))
                        .accessibilityValue(Text(formatter.energy(day.macros.kilocalories)))
                    }
                    ForEach(model.weeklyAverages) { point in
                        LineMark(
                            x: .value(L("progress.axis.date"), point.date),
                            y: .value(L("progress.nutrition.weeklyAverage"), energyValue(point.value))
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .foregroundStyle(Color.appAccent)
                        .accessibilityLabel(Text(L("progress.nutrition.weeklyAverage") + ", " + formatter.shortDate(point.date)))
                        .accessibilityValue(Text(formatter.energy(point.value)))
                    }
                    if let target = model.target, target.kilocalories > 0 {
                        RuleMark(y: .value(L("progress.nutrition.target"), energyValue(target.kilocalories)))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .foregroundStyle(Color.appTextPrimary.opacity(0.7))
                            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                Text(L("progress.nutrition.target"))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.appTextSecondary)
                            }
                    }
                }
                .progressDateAxis(range.dateSpan)
                .progressValueAxis()
                .frame(height: 220)
                .chartAccessibilityContainer(L("progress.nutrition.energyTitle"))
            },
            legend: {
                ChartLegendView(keys: [
                    ChartSeriesKey(
                        id: "daily", label: L("progress.nutrition.dailyIntake"),
                        color: .appNutrition, symbolName: "square.fill"
                    ),
                    ChartSeriesKey(
                        id: "weekly", label: L("progress.nutrition.weeklyAverage"),
                        color: .appAccent, symbolName: "minus"
                    ),
                ] + (model.target == nil ? [] : [
                    ChartSeriesKey(
                        id: "target", label: L("progress.nutrition.target"),
                        color: .appTextPrimary, symbolName: "minus"
                    ),
                ]))
            }
        )
    }

    private var energyFootnote: String {
        guard let delta = model.averageEnergyDelta else { return L("progress.nutrition.noTargetFootnote") }
        if abs(delta) < 50 { return L("progress.nutrition.onTarget") }
        let amount = formatter.energy(abs(delta))
        return delta > 0
            ? L("progress.nutrition.aboveTarget", amount)
            : L("progress.nutrition.belowTarget", amount)
    }

    // MARK: - Average day

    private var averageDayCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(
                    L("progress.nutrition.averageDay"),
                    subtitle: L("progress.nutrition.averageOverDays", model.loggedDays.count)
                )
                if let average = model.averageMacros {
                    TargetProgressRow(
                        title: L("progress.nutrition.energyTitle"),
                        valueText: targetText(average.kilocalories, model.target?.kilocalories) { formatter.energy($0) },
                        value: average.kilocalories,
                        target: model.target?.kilocalories ?? average.kilocalories,
                        tint: .appNutrition
                    )
                    ForEach(MacroKind.allCases) { macro in
                        let consumed = macro.grams(in: average)
                        let target = model.target.map { macro.grams(in: $0) }
                        TargetProgressRow(
                            title: L(macro.localizationKey),
                            valueText: targetText(consumed, target) { formatter.macro($0) },
                            value: consumed,
                            target: target ?? consumed,
                            tint: macro.color
                        )
                    }
                    if model.target == nil {
                        Text(L("progress.nutrition.noTargetNote"))
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func targetText(_ value: Double, _ target: Double?, format: (Double) -> String) -> String {
        guard let target, target > 0 else { return format(value) }
        return "\(format(value)) / \(format(target))"
    }

    // MARK: - Macros

    private var macroChart: some View {
        ChartCard(
            title: L("progress.nutrition.macroTitle"),
            subtitle: L("progress.nutrition.macroSubtitle"),
            footnote: L("progress.nutrition.macroFootnote"),
            hasData: !model.loggedDays.isEmpty,
            emptySystemImage: "chart.bar.fill",
            emptyMessage: L("progress.nutrition.noDays"),
            content: {
                Chart(model.macroEnergyPoints) { point in
                    BarMark(
                        x: .value(L("progress.axis.date"), point.date, unit: .day),
                        y: .value(L("progress.nutrition.energyTitle"), energyValue(point.kilocalories))
                    )
                    .foregroundStyle(by: .value(L("progress.nutrition.macroTitle"), L(point.macro.localizationKey)))
                    .accessibilityLabel(Text("\(L(point.macro.localizationKey)), \(formatter.shortDate(point.date))"))
                    .accessibilityValue(Text(formatter.macro(point.grams)))
                }
                .chartForegroundStyleScale(macroStyleScale)
                .chartLegend(.hidden)
                .progressDateAxis(range.dateSpan)
                .progressValueAxis()
                .frame(height: 200)
                .chartAccessibilityContainer(L("progress.nutrition.macroTitle"))
            },
            legend: {
                ChartLegendView(keys: MacroKind.allCases.map {
                    ChartSeriesKey(
                        id: $0.rawValue, label: L($0.localizationKey),
                        color: $0.color, symbolName: "square.fill"
                    )
                })
            }
        )
    }

    /// Explicit colour scale so the macros keep the same colour as the legend below the chart and
    /// as the rows in the average-day card.
    private var macroStyleScale: KeyValuePairs<String, Color> {
        [
            L(MacroKind.protein.localizationKey): MacroKind.protein.color,
            L(MacroKind.carbs.localizationKey): MacroKind.carbs.color,
            L(MacroKind.fat.localizationKey): MacroKind.fat.color,
        ]
    }

    /// Kilocalories converted into whatever energy unit the user reads in.
    private func energyValue(_ kilocalories: Double) -> Double {
        kilocalories * formatter.energyUnit.perKilocalorie
    }
}

#Preview("Nutrition progress") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            NutritionProgressView(range: ProgressRangeStore())
        }
    }
}
