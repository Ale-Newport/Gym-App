import Charts
import SwiftUI

// MARK: - Shared range

/// The time range every chart on the Progress tab reads.
///
/// One object, owned by `ProgressHubView` and handed to each pushed screen, rather than a
/// `@State` per screen. The tab promises that changing the range changes *everything*, and a
/// per-screen copy would quietly break that the moment the user drilled in and came back.
@MainActor
@Observable
final class ProgressRangeStore {
    var range: TimeRange = .threeMonths

    /// Oldest datum anywhere on the tab, used to bound the "All" range.
    ///
    /// Without it, "All" would have to start at `.distantPast` and Swift Charts would render a
    /// couple of centuries of empty axis with the user's three months squeezed into the last pixel.
    var earliestDataDate: Date?

    private let calendar = ProgressRepository.trainingCalendar()

    /// `[start, end)` covering the selected range. `end` is the start of tomorrow so today's data
    /// is always inside the interval regardless of the hour.
    func interval(now: Date = Date()) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)

        let start: Date
        if let days = range.days {
            start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        } else if let earliest = earliestDataDate {
            start = calendar.startOfDay(for: earliest)
        } else {
            // No history yet: a year of empty axis is a more honest "all time" than one day.
            start = calendar.date(byAdding: .year, value: -1, to: today) ?? today
        }
        return DateInterval(start: min(start, today), end: end)
    }

    /// The same range widened to whole training weeks, for anything bucketed by week.
    ///
    /// A range that starts on a Thursday would otherwise produce a first bar built from four days
    /// of training and invite the user to read it as a collapse in volume.
    func weekAlignedInterval(now: Date = Date()) -> DateInterval {
        let base = interval(now: now)
        let start = ProgressRepository.weekStart(of: base.start, calendar: calendar) ?? base.start
        return DateInterval(start: start, end: base.end)
    }

    /// How dense the x-axis labels may be for the current range.
    var dateSpan: ChartDateSpan {
        switch range {
        case .week: .days
        case .month: .weeks
        case .threeMonths, .sixMonths: .months
        case .year: .quarters
        case .all: earliestDataDate.map { Date().timeIntervalSince($0) > 400 * 86_400 } == true ? .quarters : .months
        }
    }
}

// MARK: - Axis

/// Label density for a date axis. Picked from the range rather than left to Swift Charts, whose
/// automatic stride happily writes eleven overlapping labels onto a 350-point-wide iPhone chart.
enum ChartDateSpan {
    case days
    case weeks
    case months
    case quarters

    var component: Calendar.Component {
        switch self {
        case .days: .day
        case .weeks: .weekOfYear
        case .months, .quarters: .month
        }
    }

    var count: Int {
        switch self {
        case .days: 1
        case .weeks: 1
        case .months: 1
        case .quarters: 3
        }
    }

    var format: Date.FormatStyle {
        switch self {
        case .days: .dateTime.weekday(.narrow)
        case .weeks: .dateTime.day().month(.narrow)
        case .months, .quarters: .dateTime.month(.abbreviated)
        }
    }
}

extension View {
    /// The tab's standard date axis: themed grid lines and a label density that fits an iPhone.
    func progressDateAxis(_ span: ChartDateSpan) -> some View {
        chartXAxis {
            AxisMarks(values: .stride(by: span.component, count: span.count)) { value in
                AxisGridLine().foregroundStyle(Color.appSeparator.opacity(0.55))
                AxisTick(length: 3).foregroundStyle(Color.appSeparator)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: span.format)
                            .font(.caption2)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            }
        }
    }

    /// The tab's standard value axis. Leading position so the numbers sit against the reading edge.
    func progressValueAxis(desiredCount: Int = 4) -> some View {
        chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: desiredCount)) { value in
                AxisGridLine().foregroundStyle(Color.appSeparator.opacity(0.55))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(Units.formatDecimal(number, digits: number < 10 ? 1 : 0))
                            .font(.caption2)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
            }
        }
    }

    /// Marks the chart as one accessibility container so VoiceOver reads its points in order
    /// instead of announcing the whole plot as a single unlabelled image.
    func chartAccessibilityContainer(_ label: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityLabel(Text(label))
    }
}

// MARK: - Containers

/// A titled chart panel. Every chart on the tab sits in one of these so headings, legends and
/// empty states are laid out identically wherever the user meets them.
struct ChartCard<Content: View, Legend: View>: View {
    let title: String
    var subtitle: String?
    /// Shown under the chart — the caveat, the unit note, the "this is an estimate" line.
    var footnote: String?
    /// When false the card shows `emptyMessage` instead of the chart.
    var hasData: Bool = true
    var emptySystemImage: String = "chart.line.uptrend.xyaxis"
    var emptyMessage: String?
    @ViewBuilder var content: Content
    @ViewBuilder var legend: Legend

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.appCardTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                if hasData {
                    content
                    legend
                } else {
                    EmptyStateView(
                        systemImage: emptySystemImage,
                        title: emptyMessage ?? L("progress.chart.empty.title"),
                        message: L("progress.chart.empty.message")
                    )
                    .padding(.vertical, Metrics.spacing8)
                }

                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension ChartCard where Legend == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        footnote: String? = nil,
        hasData: Bool = true,
        emptySystemImage: String = "chart.line.uptrend.xyaxis",
        emptyMessage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            footnote: footnote,
            hasData: hasData,
            emptySystemImage: emptySystemImage,
            emptyMessage: emptyMessage,
            content: content,
            legend: { EmptyView() }
        )
    }
}

// MARK: - Legend

/// One series in a legend. Carries a symbol as well as a colour, because colour alone is not an
/// accessible way to tell two lines apart.
struct ChartSeriesKey: Identifiable, Hashable {
    let id: String
    let label: String
    let color: Color
    var symbolName: String?

    init(id: String, label: String, color: Color, symbolName: String? = nil) {
        self.id = id
        self.label = label
        self.color = color
        self.symbolName = symbolName
    }
}

/// Wrapping legend. Flows onto as many lines as Dynamic Type needs.
struct ChartLegendView: View {
    let keys: [ChartSeriesKey]

    var body: some View {
        FlowLayout(spacing: Metrics.spacing12, lineSpacing: Metrics.spacing6) {
            ForEach(keys) { key in
                HStack(spacing: Metrics.spacing6) {
                    Image(systemName: key.symbolName ?? "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(key.color)
                    Text(key.label)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(key.label)
            }
        }
    }
}

// MARK: - Value types

/// One point on a dated series. Kept `Sendable` so series can be built off the main actor.
struct DatedValue: Identifiable, Hashable, Sendable {
    var date: Date
    var value: Double
    /// Optional per-point description used verbatim as the VoiceOver label.
    var accessibilityText: String?

    var id: Date { date }

    init(date: Date, value: Double, accessibilityText: String? = nil) {
        self.date = date
        self.value = value
        self.accessibilityText = accessibilityText
    }
}

/// One point that also names its series, for charts drawn with `foregroundStyle(by:)`.
struct SeriesValue: Identifiable, Hashable, Sendable {
    var seriesID: String
    var date: Date
    var value: Double

    var id: String { "\(seriesID)-\(date.timeIntervalSince1970)" }
}

// MARK: - Compact chart

/// The small trend line used on hub summary cards.
///
/// Deliberately axis-free: at this size an axis is unreadable, and the card always states the
/// current value in text next to it, so nothing is conveyed by the shape alone.
struct SparklineChart: View {
    let points: [DatedValue]
    var tint: Color = .appAccent
    var accessibilityDescription: String

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value(L("progress.axis.date"), point.date), y: .value(L("progress.axis.value"), point.value))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(tint)
            AreaMark(x: .value(L("progress.axis.date"), point.date), y: .value(L("progress.axis.value"), point.value))
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityDescription))
    }
}

// MARK: - Range picker

/// The tab-wide range selector: 7D · 1M · 3M · 6M · 1Y · All.
struct TimeRangePicker: View {
    @Bindable var store: ProgressRangeStore

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Metrics.spacing8) {
                ForEach(TimeRange.allCases) { range in
                    Button {
                        guard store.range != range else { return }
                        store.range = range
                        Haptics.selectionChanged()
                    } label: {
                        Chip(title: L(range.localizationKey), isSelected: store.range == range)
                            .frame(minHeight: Metrics.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("progress.range.accessibility", L(range.localizationKey))))
                    .accessibilityAddTraits(store.range == range ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, Metrics.spacing4)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

// MARK: - Small building blocks

/// A labelled row of "value against target", used by volume, adherence and nutrition.
///
/// The number is always spelled out next to the bar: a bar alone tells a user with low vision
/// nothing, and a bar plus a percentage tells them everything.
struct TargetProgressRow: View {
    let title: String
    let valueText: String
    let value: Double
    let target: Double
    var tint: Color = .appAccent
    /// Extra context read after the value by VoiceOver, e.g. "target 15 sets".
    var accessibilityDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Metrics.spacing8)
                Text(valueText)
                    .font(.appNumeric(15))
                    .foregroundStyle(Color.appTextSecondary)
            }
            ProgressBar(value: value, total: target, tint: tint, height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text([valueText, accessibilityDetail].compactMap { $0 }.joined(separator: ", ")))
    }
}

/// A signed change with an arrow *and* a word, so the direction never depends on colour.
struct DeltaLabel: View {
    let text: String
    let direction: Direction
    var font: Font = .caption

    enum Direction {
        case up
        case down
        case flat

        var symbolName: String {
            switch self {
            case .up: "arrow.up.right"
            case .down: "arrow.down.right"
            case .flat: "arrow.right"
            }
        }
    }

    /// Colour follows the direction only as reinforcement; the arrow and the sign carry the meaning.
    var tint: Color {
        switch direction {
        case .up: .appAccent
        case .down: .appRecovery
        case .flat: .appTextSecondary
        }
    }

    var body: some View {
        HStack(spacing: Metrics.spacing4) {
            Image(systemName: direction.symbolName)
                .font(font.weight(.semibold))
            Text(text)
                .font(font.weight(.semibold))
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Chart components") {
    PreviewHost(scenario: .seasonedUser) {
        ScrollView {
            VStack(spacing: Metrics.spacing16) {
                TimeRangePicker(store: ProgressRangeStore())
                ChartCard(title: "Body weight", subtitle: "Last 90 days", footnote: "Trend, not readings.") {
                    SparklineChart(
                        points: (0..<30).map {
                            DatedValue(
                                date: Date().addingTimeInterval(Double(-$0) * 86_400),
                                value: 78 - Double($0) * 0.05
                            )
                        },
                        accessibilityDescription: "Body weight trending down"
                    )
                }
                TargetProgressRow(title: "Chest", valueText: "12 / 15", value: 12, target: 15, tint: .forGroup(.chest))
                DeltaLabel(text: "+2.5 kg", direction: .up)
            }
            .screenPadding()
        }
        .background(Color.appBackground)
    }
}
