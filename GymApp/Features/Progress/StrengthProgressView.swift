import Charts
import SwiftData
import SwiftUI

/// Strength on one movement over time.
///
/// Two series, deliberately: the top set is what the user actually did, and the estimated one-rep
/// max is what it implies about their capacity. They disagree whenever reps change — a heavier
/// triple can sit below a lighter set of ten on the estimate — and seeing both is what stops a user
/// concluding they got weaker the week they moved into a higher rep range.
struct StrengthProgressView: View {
    let range: ProgressRangeStore

    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model = StrengthProgressViewModel()
    @State private var isPickingExercise = false

    private var selectedExercise: TrainedExercise? {
        model.trainedExercises.first { $0.id == model.selectedExerciseID }
    }

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
        .navigationTitle(L("progress.strength.title"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPickingExercise) {
            TrainedExercisePickerSheet(exercises: model.trainedExercises, selectedID: model.selectedExerciseID) { id in
                Task { await model.select(id, context: modelContext, range: range) }
            }
        }
        .task(id: range.range) {
            await model.load(context: modelContext, range: range)
        }
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
            if model.trainedExercises.isEmpty {
                EmptyStateView(
                    systemImage: "figure.strengthtraining.traditional",
                    title: L("progress.strength.empty.title"),
                    message: L("progress.strength.empty.message")
                ) {
                    Button(L("progress.range.widen")) {
                        range.range = .all
                    }
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
            exerciseSelector
            summaryTiles
            strengthChart
            recordsSection
        }
    }

    // MARK: - Selector

    private var exerciseSelector: some View {
        Button {
            isPickingExercise = true
        } label: {
            Card {
                HStack(spacing: Metrics.spacing12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("progress.strength.exercise"))
                            .font(.appOverline)
                            .foregroundStyle(Color.appTextSecondary)
                        Text(selectedExercise?.name.localizedCapitalized ?? L("common.select"))
                            .font(.appCardTitle)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let selectedExercise {
                            Text(L("progress.strength.sessionsInRange", selectedExercise.sessionCount))
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: Metrics.spacing8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.appTextTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Metrics.minimumTapTarget)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(L("progress.strength.pickHint")))
    }

    // MARK: - Summary

    private var summaryTiles: some View {
        ScaledTileGrid(minimumWidth: 130) {
            StatTile(
                value: model.bestOneRepMaxKg.map { formatter.weight($0) } ?? "—",
                label: L("progress.strength.bestEstimate"),
                caption: L("progress.strength.estimateCaption"),
                tint: .appAccent,
                systemImage: "trophy"
            )
            StatTile(
                value: model.latestTopSetKg.map { formatter.weight($0) } ?? "—",
                label: L("progress.strength.latestTopSet"),
                systemImage: "scalemass"
            )
            StatTile(
                value: formatter.volume(model.totalVolumeKg),
                label: L("progress.strength.totalVolume"),
                caption: L("progress.stat.tonnage.caption"),
                systemImage: "sum"
            )
            StatTile(
                value: String(model.sessionCount),
                label: L("progress.stat.sessions"),
                systemImage: "calendar"
            )
        }
    }

    // MARK: - Chart

    /// Both plotted series in display units. They share one axis, so the domain has to span both:
    /// scaling to the estimate alone would push a heavy low-rep top set off the top of the chart.
    private var strengthDomainValues: [Double] {
        (model.topSetPoints + model.oneRepMaxPoints).map { formatter.weightValue($0.value) }
    }

    private var strengthChart: some View {
        ChartCard(
            title: L("progress.strength.chartTitle"),
            subtitle: selectedExercise?.name.localizedCapitalized,
            footnote: model.isUnestimable
                ? L("progress.strength.unestimable")
                : L("progress.strength.chartFootnote"),
            hasData: !model.oneRepMaxPoints.isEmpty || !model.topSetPoints.isEmpty,
            emptySystemImage: "chart.line.uptrend.xyaxis",
            emptyMessage: L("progress.strength.noSeries"),
            content: {
                Chart {
                    ForEach(model.topSetPoints) { point in
                        LineMark(
                            x: .value(L("progress.axis.date"), point.date),
                            y: .value(L("progress.axis.weight"), formatter.weightValue(point.value)),
                            series: .value(L("progress.axis.series"), "topSet")
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .foregroundStyle(Color.appRecovery)
                        .symbol(.square)
                        .accessibilityLabel(Text(L("progress.strength.legend.topSet") + ", " + formatter.mediumDate(point.date)))
                        .accessibilityValue(Text(formatter.weight(point.value)))
                    }
                    ForEach(model.oneRepMaxPoints) { point in
                        LineMark(
                            x: .value(L("progress.axis.date"), point.date),
                            y: .value(L("progress.axis.weight"), formatter.weightValue(point.value)),
                            series: .value(L("progress.axis.series"), "oneRepMax")
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .foregroundStyle(Color.appAccent)
                        .symbol(.circle)
                        .accessibilityLabel(Text(L("progress.strength.legend.estimate") + ", " + formatter.mediumDate(point.date)))
                        .accessibilityValue(Text(formatter.weight(point.value)))
                    }
                }
                .chartYScale(domain: ChartDomain.padded(strengthDomainValues, minimumSpan: 5))
                .progressDateAxis(range.dateSpan)
                .progressValueAxis()
                .frame(height: 220)
                .chartAccessibilityContainer(L("progress.strength.chartTitle"))
            },
            legend: {
                ChartLegendView(keys: [
                    ChartSeriesKey(
                        id: "estimate", label: L("progress.strength.legend.estimate"),
                        color: .appAccent, symbolName: "circle.fill"
                    ),
                    ChartSeriesKey(
                        id: "topSet", label: L("progress.strength.legend.topSet"),
                        color: .appRecovery, symbolName: "square.fill"
                    ),
                ])
            }
        )
    }

    // MARK: - Records

    private var recordsSection: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(L("progress.records.forExercise"))
                if model.records.isEmpty {
                    Text(L("progress.records.noneForExercise"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVStack(spacing: Metrics.spacing8) {
                        ForEach(model.records) { record in
                            PersonalRecordRowView(record: record, showsExerciseName: false)
                        }
                    }
                }
            }
        }
    }
}

/// Picks from the movements the user actually trained in the selected range.
///
/// Deliberately not the full catalogue: a strength chart for an exercise with no history is an
/// empty chart, and offering three thousand of them would make the useful dozen hard to find.
private struct TrainedExercisePickerSheet: View {
    let exercises: [TrainedExercise]
    let selectedID: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayFormatter) private var formatter
    @State private var query = ""

    private var filtered: [TrainedExercise] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return exercises }
        return exercises.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    EmptyStateView(
                        systemImage: "magnifyingglass",
                        title: L("progress.strength.noMatches"),
                        message: L("progress.strength.noMatchesMessage")
                    )
                    .listRowBackground(Color.appSurface)
                } else {
                    ForEach(filtered) { exercise in
                        Button {
                            onSelect(exercise.id)
                            dismiss()
                        } label: {
                            HStack(spacing: Metrics.spacing12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(exercise.name.localizedCapitalized)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Color.appTextPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(L("progress.strength.sessionsAndLast",
                                           exercise.sessionCount,
                                           formatter.shortDate(exercise.lastPerformed)))
                                        .font(.caption)
                                        .foregroundStyle(Color.appTextSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: Metrics.spacing8)
                                if exercise.id == selectedID {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Color.appAccent)
                                }
                            }
                            .frame(minHeight: Metrics.minimumTapTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.appSurface)
                        .accessibilityAddTraits(exercise.id == selectedID ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .searchable(text: $query, prompt: Text(L("common.search")))
            .navigationTitle(L("progress.strength.exercise"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
            }
        }
    }
}

#Preview("Strength progress") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            StrengthProgressView(range: ProgressRangeStore())
        }
    }
}
