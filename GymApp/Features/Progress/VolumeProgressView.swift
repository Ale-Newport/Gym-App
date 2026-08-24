import Charts
import SwiftData
import SwiftUI

/// Weekly training volume: hard-set credits per muscle group against the allocator's target, and
/// total tonnage per week.
///
/// Volume is counted in *credits*, matching `VolumeAllocator`: a bench press earns the chest a full
/// credit and the triceps and front delts a fraction each. Comparing performed sets against a credit
/// target would understate every group by roughly the amount of indirect work it receives, so the
/// footnote says plainly what the unit is.
struct VolumeProgressView: View {
    let range: ProgressRangeStore

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter
    @ScaledMetric(relativeTo: .caption) private var barRowHeight: CGFloat = 26

    @State private var model = VolumeProgressViewModel()

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
        .navigationTitle(L("progress.volume.title"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                TimeRangePicker(store: range)
                Divider().overlay(Color.appSeparator)
            }
            .background(.bar)
        }
        .task(id: range.range) { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        await model.load(
            context: modelContext,
            range: range,
            catalog: Dictionary(appEnvironment.catalog.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        )
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
                Task { await reload() }
            }
            .frame(minHeight: 320)
        case .content:
            if model.trainedGroups.isEmpty {
                EmptyStateView(
                    systemImage: "chart.bar.xaxis",
                    title: L("progress.volume.empty.title"),
                    message: L("progress.volume.empty.message")
                ) {
                    Button(L("progress.range.widen")) { range.range = .all }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 260)
                }
                .frame(minHeight: 320)
            } else {
                loadedContent
            }
        }
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            latestWeekCard
            groupFocusCard
            tonnageCard
        }
    }

    // MARK: - Latest week

    private var latestWeekCard: some View {
        ChartCard(
            title: L("progress.volume.thisWeek"),
            subtitle: model.latestWeekStart.map { L("progress.volume.weekOf", formatter.shortDate($0)) },
            footnote: L("progress.volume.creditsFootnote"),
            hasData: !model.latestWeek.isEmpty,
            emptySystemImage: "chart.bar.xaxis",
            emptyMessage: L("progress.volume.noWeek"),
            content: {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    Chart {
                        ForEach(model.latestWeek, id: \.group) { row in
                            BarMark(
                                x: .value(L("progress.volume.setsAxis"), row.sets),
                                y: .value(L("progress.volume.groupAxis"), L(row.group.localizationKey))
                            )
                            .foregroundStyle(Color.forGroup(row.group))
                            .cornerRadius(3)
                            .accessibilityLabel(Text(L(row.group.localizationKey)))
                            .accessibilityValue(Text(L(
                                "progress.volume.setsOfTarget",
                                Units.formatDecimal(row.sets, digits: 1),
                                Units.formatDecimal(row.target, digits: 0)
                            )))

                            if row.target > 0 {
                                PointMark(
                                    x: .value(L("progress.volume.targetAxis"), row.target),
                                    y: .value(L("progress.volume.groupAxis"), L(row.group.localizationKey))
                                )
                                .symbol(.diamond)
                                .symbolSize(52)
                                .foregroundStyle(Color.appTextPrimary)
                                .accessibilityHidden(true)
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(position: .bottom, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine().foregroundStyle(Color.appSeparator.opacity(0.55))
                            AxisValueLabel {
                                if let number = value.as(Double.self) {
                                    Text(Units.formatDecimal(number, digits: 0))
                                        .font(.caption2)
                                        .foregroundStyle(Color.appTextSecondary)
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(preset: .aligned, position: .leading) { _ in
                            AxisValueLabel()
                                .font(.caption2)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                    .frame(height: max(140, CGFloat(model.latestWeek.count) * barRowHeight + 36))
                    .chartAccessibilityContainer(L("progress.volume.thisWeek"))

                    ChartLegendView(keys: [
                        ChartSeriesKey(
                            id: "target", label: L("progress.volume.legend.target"),
                            color: .appTextPrimary, symbolName: "diamond.fill"
                        ),
                    ])
                }
            }
        )
    }

    // MARK: - One group over time

    private var groupFocusCard: some View {
        let series = model.series(for: model.selectedGroup)
        let target = model.targets.target(for: model.selectedGroup)
        return ChartCard(
            title: L("progress.volume.perGroup"),
            subtitle: L("progress.volume.perGroupSubtitle"),
            footnote: target > 0
                ? L("progress.volume.targetFootnote",
                    Units.formatDecimal(target, digits: 0),
                    model.targets.frequency(for: model.selectedGroup))
                : nil,
            hasData: !series.isEmpty,
            emptySystemImage: "chart.line.uptrend.xyaxis",
            emptyMessage: L("progress.volume.noWeek"),
            content: {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    groupPicker
                    Chart {
                        ForEach(series) { point in
                            BarMark(
                                x: .value(L("progress.axis.date"), point.date, unit: .weekOfYear),
                                y: .value(L("progress.volume.setsAxis"), point.value)
                            )
                            .foregroundStyle(Color.forGroup(model.selectedGroup))
                            .cornerRadius(3)
                            .accessibilityLabel(Text(L("progress.volume.weekOf", formatter.shortDate(point.date))))
                            .accessibilityValue(Text(L(
                                "progress.volume.setsCount", Units.formatDecimal(point.value, digits: 1)
                            )))
                        }
                        if target > 0 {
                            RuleMark(y: .value(L("progress.volume.targetAxis"), target))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                .foregroundStyle(Color.appTextPrimary.opacity(0.7))
                                .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                    Text(L("progress.volume.legend.target"))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Color.appTextSecondary)
                                }
                        }
                    }
                    .progressDateAxis(range.dateSpan)
                    .progressValueAxis()
                    .frame(height: 200)
                    .chartAccessibilityContainer(L("progress.volume.perGroup"))
                }
            }
        )
    }

    private var groupPicker: some View {
        Menu {
            // Every group is named in the menu, so the colour in the chart is reinforcement only.
            ForEach(model.trainedGroups) { group in
                Button {
                    model.selectedGroup = group
                    Haptics.selectionChanged()
                } label: {
                    if group == model.selectedGroup {
                        Label(L(group.localizationKey), systemImage: "checkmark")
                    } else {
                        Text(L(group.localizationKey))
                    }
                }
            }
        } label: {
            HStack(spacing: Metrics.spacing8) {
                Circle()
                    .fill(Color.forGroup(model.selectedGroup))
                    .frame(width: 10, height: 10)
                Text(L(model.selectedGroup.localizationKey))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(.horizontal, Metrics.spacing12)
            .frame(minHeight: Metrics.minimumTapTarget)
            .background(Color.appFill, in: Capsule())
        }
        .accessibilityLabel(Text(L("progress.volume.groupAxis")))
        .accessibilityValue(Text(L(model.selectedGroup.localizationKey)))
    }

    // MARK: - Tonnage

    private var tonnageCard: some View {
        ChartCard(
            title: L("progress.volume.tonnage"),
            subtitle: L("progress.volume.tonnageSubtitle"),
            footnote: L("progress.volume.tonnageFootnote"),
            hasData: model.weeklyTonnage.contains { $0.value > 0 },
            emptySystemImage: "scalemass",
            emptyMessage: L("progress.volume.noWeek"),
            content: {
                Chart(model.weeklyTonnage) { point in
                    BarMark(
                        x: .value(L("progress.axis.date"), point.date, unit: .weekOfYear),
                        y: .value(L("progress.volume.tonnage"), formatter.weightValue(point.value))
                    )
                    .foregroundStyle(Color.appAccent)
                    .cornerRadius(3)
                    .accessibilityLabel(Text(L("progress.volume.weekOf", formatter.shortDate(point.date))))
                    .accessibilityValue(Text(formatter.volume(point.value)))
                }
                .progressDateAxis(range.dateSpan)
                .progressValueAxis()
                .frame(height: 200)
                .chartAccessibilityContainer(L("progress.volume.tonnage"))
            }
        )
    }
}

#Preview("Volume progress") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            VolumeProgressView(range: ProgressRangeStore())
        }
    }
}
