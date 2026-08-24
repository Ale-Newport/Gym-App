import Charts
import SwiftData
import SwiftUI

/// Body mass over time.
///
/// The screen exists to make one point impossible to miss: a single morning's reading is noise, and
/// only the trend line means anything. The raw readings are therefore drawn small and muted while
/// the seven-day average is the emphasised line, and the caveat is written out in words rather than
/// left for the user to infer from the styling.
struct BodyWeightView: View {
    let range: ProgressRangeStore

    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model = BodyWeightViewModel()

    var body: some View {
        @Bindable var router = router

        Group {
            switch model.phase {
            case .loading:
                LoadingStateView(message: L("progress.loading"))
            case .failed(let message):
                ErrorStateView(message: message, retryTitle: L("common.retry")) {
                    Task { await model.load(context: modelContext, range: range) }
                }
            case .content:
                if model.rows.isEmpty && model.movingAverage.isEmpty {
                    emptyState
                } else {
                    loadedList
                }
            }
        }
        .background(Color.appBackground)
        .navigationTitle(L("progress.weight.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.isPresentingWeightEntry = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel(Text(L("progress.weight.add")))
                // The empty state offers the same action with the same words, so the label alone
                // matches two controls. Both keep the label a VoiceOver user expects; the
                // identifiers are what tell them apart.
                .accessibilityIdentifier("progress.weight.add.toolbar")
            }
        }
        .sheet(isPresented: $router.isPresentingWeightEntry) {
            BodyWeightEntrySheet()
        }
        .task(id: range.range) {
            await model.load(context: modelContext, range: range)
        }
        .onChange(of: router.isPresentingWeightEntry) { _, isPresenting in
            // Reload when the sheet closes: it is the only way a new reading arrives here.
            guard !isPresenting else { return }
            Task { await model.load(context: modelContext, range: range) }
        }
    }

    // MARK: - States

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "scalemass",
            title: L("progress.weight.empty.title"),
            message: L("progress.weight.empty.message")
        ) {
            VStack(spacing: Metrics.spacing12) {
                Button(L("progress.weight.add")) {
                    router.isPresentingWeightEntry = true
                }
                .accessibilityIdentifier("progress.weight.add.empty")
                .buttonStyle(PrimaryButtonStyle())
                if model.isHealthEnabled {
                    healthImportButton
                }
            }
            .frame(maxWidth: 320)
        }
        .screenPadding()
    }

    private var loadedList: some View {
        List {
            Section {
                chart
                    .listRowInsets(EdgeInsets(
                        top: Metrics.spacing16, leading: Metrics.spacing12,
                        bottom: Metrics.spacing16, trailing: Metrics.spacing16
                    ))
                    .listRowBackground(Color.appSurface)
            }

            Section {
                statsRow
                    .listRowBackground(Color.appSurface)
                Text(L("progress.weight.noiseNote"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.appSurface)
                if let goal = model.goalWeightKg {
                    goalRow(goal)
                        .listRowBackground(Color.appSurface)
                }
            } header: {
                sectionHeader(L("progress.weight.trendSection"))
            }

            if model.isHealthEnabled {
                Section {
                    healthImportButton
                        .listRowBackground(Color.appSurface)
                    if let summary = model.importSummary {
                        Text(summary)
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .listRowBackground(Color.appSurface)
                    }
                } header: {
                    sectionHeader(L("progress.weight.health.section"))
                }
            }

            Section {
                if model.rows.isEmpty {
                    Text(L("progress.weight.noneInRange"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.appSurface)
                } else {
                    ForEach(model.rows.reversed()) { row in
                        entryRow(row)
                            .listRowBackground(Color.appSurface)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await model.delete(row, context: modelContext, range: range) }
                                } label: {
                                    Label(L("common.delete"), systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                sectionHeader(L("progress.weight.readings", model.rows.count))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(context: modelContext, range: range) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.appOverline)
            .foregroundStyle(Color.appTextSecondary)
    }

    // MARK: - Chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            Chart {
                ForEach(model.readings) { point in
                    PointMark(
                        x: .value(L("progress.axis.date"), point.date),
                        y: .value(L("progress.axis.weight"), formatter.weightValue(point.value))
                    )
                    .symbolSize(16)
                    .foregroundStyle(Color.appTextTertiary.opacity(0.7))
                    // Hidden from VoiceOver on purpose: every reading is listed as a real row
                    // below, and announcing ninety points here would bury the trend line.
                    .accessibilityHidden(true)
                }

                ForEach(model.movingAverage) { point in
                    LineMark(
                        x: .value(L("progress.axis.date"), point.date),
                        y: .value(L("progress.axis.weight"), formatter.weightValue(point.value))
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .foregroundStyle(Color.appRecovery)
                    .accessibilityLabel(Text(formatter.mediumDate(point.date)))
                    .accessibilityValue(Text(formatter.weight(point.value)))
                }

                if let goal = model.goalWeightKg {
                    RuleMark(y: .value(L("progress.weight.goal"), formatter.weightValue(goal)))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(Color.appSuccess)
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text(L("progress.weight.goalMark", formatter.weight(goal)))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.appSuccess)
                        }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .progressDateAxis(range.dateSpan)
            .progressValueAxis()
            .frame(height: 220)
            .chartAccessibilityContainer(L("progress.weight.chartAccessibility"))

            ChartLegendView(keys: [
                ChartSeriesKey(
                    id: "average", label: L("progress.weight.legend.average"),
                    color: .appRecovery, symbolName: "minus"
                ),
                ChartSeriesKey(
                    id: "readings", label: L("progress.weight.legend.readings"),
                    color: .appTextTertiary, symbolName: "circle.fill"
                ),
            ] + (model.goalWeightKg == nil ? [] : [
                ChartSeriesKey(
                    id: "goal", label: L("progress.weight.legend.goal"),
                    color: .appSuccess, symbolName: "minus"
                ),
            ]))
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: Metrics.spacing12)],
            alignment: .leading,
            spacing: Metrics.spacing12
        ) {
            StatTile(
                value: model.analysis.currentTrendKg.map { formatter.weight($0) } ?? "—",
                label: L("progress.weight.trendLabel"),
                caption: L("progress.weight.trendCaption"),
                tint: .appRecovery,
                systemImage: "chart.line.flattrend.xyaxis"
            )
            StatTile(
                value: model.analysis.weeklyChangeKg.map { signedWeight($0) } ?? "—",
                label: L("progress.weight.rateLabel"),
                caption: L("progress.weight.rateCaption"),
                systemImage: "arrow.up.arrow.down"
            )
            StatTile(
                value: L("progress.percent", Int((model.analysis.confidence * 100).rounded())),
                label: L("progress.weight.confidence"),
                caption: confidenceCaption,
                tint: model.analysis.hasEnoughData ? .appTextPrimary : .appTextSecondary,
                systemImage: "checkmark.seal"
            )
        }
    }

    private var confidenceCaption: String {
        model.analysis.hasEnoughData
            ? L("progress.weight.confidence.enough")
            : L("progress.weight.confidence.notEnough")
    }

    private func goalRow(_ goalKg: Double) -> some View {
        let current = model.analysis.currentTrendKg ?? model.latest?.weightKg ?? goalKg
        let remaining = goalKg - current
        return VStack(alignment: .leading, spacing: Metrics.spacing6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("progress.weight.goal"))
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                Spacer(minLength: Metrics.spacing8)
                Text(formatter.weight(goalKg))
                    .font(.appNumeric(15))
                    .foregroundStyle(Color.appTextSecondary)
            }
            Text(abs(remaining) < 0.1
                 ? L("progress.weight.goalReached")
                 : L("progress.weight.goalRemaining", formatter.weight(abs(remaining))))
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Rows

    private func entryRow(_ row: BodyWeightRow) -> some View {
        HStack(spacing: Metrics.spacing12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatter.weight(row.weightKg))
                    .font(.appNumeric(17))
                    .foregroundStyle(Color.appTextPrimary)
                Text(formatter.weekdayAndDate(row.date))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = row.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Metrics.spacing8)
            if row.isFromHealthKit {
                // Labelled with words as well as an icon: the badge tells the user why this row
                // cannot be edited here, so an icon alone would not do the job.
                HStack(spacing: Metrics.spacing4) {
                    Image(systemName: "heart.fill").font(.caption2)
                    Text(L("progress.weight.source.health")).font(.caption2.weight(.medium))
                }
                .padding(.horizontal, Metrics.spacing8)
                .padding(.vertical, 3)
                .foregroundStyle(Color.appDanger)
                .background(Color.appDanger.opacity(0.12), in: Capsule())
            }
        }
        .frame(minHeight: Metrics.minimumTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text([
            formatter.weight(row.weightKg),
            formatter.weekdayAndDate(row.date),
            row.isFromHealthKit ? L("progress.weight.source.health") : nil,
            row.note,
        ].compactMap { $0 }.joined(separator: ", ")))
    }

    private var healthImportButton: some View {
        Button {
            Task {
                await model.importFromHealth(
                    service: appEnvironment.healthService,
                    context: modelContext,
                    range: range
                )
            }
        } label: {
            HStack(spacing: Metrics.spacing8) {
                if model.isImporting {
                    ProgressView()
                } else {
                    Image(systemName: "square.and.arrow.down")
                }
                Text(L("progress.weight.health.import"))
            }
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(model.isImporting)
        .accessibilityLabel(Text(L("progress.weight.health.import")))
    }

    private func signedWeight(_ kilograms: Double) -> String {
        let displayed = formatter.weightValue(kilograms)
        return Units.formatSignedDecimal(displayed, digits: 2, locale: formatter.locale)
            + " " + formatter.weightUnitLabel
    }
}

#Preview("Body weight") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            BodyWeightView(range: ProgressRangeStore())
        }
    }
}
