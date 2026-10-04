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

// MARK: - Chart domains

/// A y-domain that stays readable when a series barely moves.
///
/// `.automatic(includesZero: false)` collapses to a zero-height domain when every value is the
/// same. Charts then draws the line jammed against an edge with the area fill covering the whole
/// frame, so "your weight did not change" reads as a solid block of colour. Padding the range —
/// with a floor under how narrow it may get — draws a flat series as a flat line through the
/// middle, and still gives a moving one room to breathe.
enum ChartDomain {

    /// - Parameters:
    ///   - values: every y value that will be plotted, already in display units.
    ///   - minimumSpan: the narrowest window the caller will accept, in those same units.
    static func padded(_ values: [Double], minimumSpan: Double = 0) -> ClosedRange<Double> {
        let finite = values.filter { $0.isFinite }
        guard let low = finite.min(), let high = finite.max() else { return 0...1 }

        // Scale the floor with the magnitude of the data: 0.5 kg of headroom is right for a body
        // weight and far too tight for a 200 kg deadlift.
        let floor = max(minimumSpan, max(abs(high), abs(low)) * 0.04, 0.5)
        let span = high - low

        if span < floor {
            let midpoint = (low + high) / 2
            return (midpoint - floor / 2)...(midpoint + floor / 2)
        }
        let padding = span * 0.12
        return (low - padding)...(high + padding)
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
        // Computed once so the area's baseline and the y-scale cannot disagree.
        let domain = ChartDomain.padded(points.map(\.value))

        return Chart(points) { point in
            LineMark(x: .value(L("progress.axis.date"), point.date), y: .value(L("progress.axis.value"), point.value))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(tint)
            // `yStart` is pinned to the bottom of the domain rather than left to default to zero.
            // A body weight never comes near zero, so the default baseline sits far below the plot
            // area and Charts draws the fill straight out of the frame and over the next card.
            AreaMark(
                x: .value(L("progress.axis.date"), point.date),
                yStart: .value(L("progress.axis.value"), domain.lowerBound),
                yEnd: .value(L("progress.axis.value"), point.value)
            )
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
        .chartYScale(domain: domain)
        .frame(height: 44)
        // Belt and braces: nothing this chart draws may ever spill onto a neighbouring card.
        .clipped()
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
        // A horizontal `ScrollView` has no intrinsic height: it takes whatever it is offered, and
        // inside `safeAreaInset(edge: .top)` that is most of the screen — which is how the chips
        // ended up drawn a couple of hundred points below the bar they belong to, on top of the
        // page. `fixedSize` makes it adopt its content's height instead.
        //
        // Deliberately not a stated height. A number would have to be scaled against Dynamic Type
        // to survive accessibility sizes, and scaling it against `.body` while the chip's own tap
        // target stays a flat 44pt makes the two disagree: the row is shorter than its chips below
        // the default text size and clips them. The floor is a floor, never a ceiling.
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: Metrics.minimumTapTarget + Metrics.spacing8)
        .scrollIndicators(.hidden)
    }
}

// MARK: - Range-bar shell

/// The Progress tab's scrolling shell: content that scrolls under a range bar that stays put.
///
/// `safeAreaInset(edge: .top)` is deliberately not used here, though it is the obvious tool for the
/// job. Two things go wrong with it on iOS 26. The bar's background is laid out at the top of the
/// screen but the picker inside it is not drawn there — a horizontal `ScrollView` has no intrinsic
/// height, so it takes the full height the inset offers and the chips end up either centred far
/// down the page, on top of the content, or not rendered at all. And on a screen that also asks for
/// a large navigation title, the inset and the title compete for the same strip: the inset wins and
/// the tab opens on a blank band where its own name should be.
///
/// A pinned section header gives the same behaviour — the bar scrolls up, then sticks under the
/// navigation bar — renders reliably, and leaves the title alone.
struct ProgressRangeScrollView<Content: View>: View {
    let range: ProgressRangeStore
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    content
                } header: {
                    VStack(spacing: 0) {
                        // The chips share the content's column so they line up with the cards
                        // below them; the material and the divider stay full-bleed, because a bar
                        // that stops short of the screen edges reads as a floating box.
                        TimeRangePicker(store: range)
                            .readableWidth()
                        Divider().overlay(Color.appSeparator)
                    }
                    .background(.bar)
                }
            }
        }
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
