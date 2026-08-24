import SwiftData
import SwiftUI

/// Formats a stored record in the unit its kind is actually measured in.
///
/// A record's `value` is canonical but its *meaning* varies by kind — kilograms for a load, whole
/// reps for a rep record, seconds for a hold — so one shared formatter here keeps the hub, the
/// strength screen and this list from each inventing their own.
enum PersonalRecordFormatting {

    @MainActor
    static func value(_ record: PersonalRecordRow, formatter: DisplayFormatter) -> String {
        switch record.kind {
        case .heaviestWeight, .estimatedOneRepMax, .lightestAssistance:
            formatter.weight(record.value)
        case .bestSetVolume, .sessionVolume:
            formatter.volume(record.value)
        case .mostReps:
            L("progress.records.reps", Int(record.value.rounded()))
        case .longestDuration:
            formatter.duration(Int(record.value.rounded()))
        case .longestDistance:
            formatter.distance(record.value)
        }
    }

    /// The improvement over the record this one replaced, already unit-formatted and signed.
    @MainActor
    static func delta(_ record: PersonalRecordRow, formatter: DisplayFormatter) -> String? {
        guard let delta = record.delta, abs(delta) > 0.0001 else { return nil }
        switch record.kind {
        case .heaviestWeight, .estimatedOneRepMax, .lightestAssistance, .bestSetVolume, .sessionVolume:
            let displayed = formatter.weightValue(delta)
            return Units.formatSignedDecimal(displayed, digits: 1, locale: formatter.locale)
                + " " + formatter.weightUnitLabel
        case .mostReps:
            return Units.formatSignedDecimal(delta, digits: 0, locale: formatter.locale)
        case .longestDuration:
            return Units.formatSignedDecimal(delta, digits: 0, locale: formatter.locale) + " " + L("common.sec")
        case .longestDistance:
            return Units.formatSignedDecimal(delta, digits: 0, locale: formatter.locale) + " m"
        }
    }

    /// Context for a load record: the reps it was set at. A 100 kg single and a 100 kg set of eight
    /// are wildly different achievements, and the number alone cannot tell them apart.
    @MainActor
    static func context(_ record: PersonalRecordRow) -> String? {
        guard let reps = record.repsContext, reps > 0 else { return nil }
        switch record.kind {
        case .heaviestWeight, .estimatedOneRepMax, .lightestAssistance, .bestSetVolume:
            return L("progress.records.atReps", reps)
        default:
            return nil
        }
    }
}

/// One record, as it appears everywhere on the tab.
struct PersonalRecordRowView: View {
    let record: PersonalRecordRow
    var showsExerciseName: Bool = true

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacing12) {
            Image(systemName: record.kind.symbolName)
                .font(.footnote)
                .foregroundStyle(Color.appAccent)
                .frame(width: 22)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if showsExerciseName {
                    Text(record.exerciseName.localizedCapitalized)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L(record.kind.localizationKey))
                    .font(showsExerciseName ? .caption : .subheadline.weight(.medium))
                    .foregroundStyle(showsExerciseName ? Color.appTextSecondary : Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(formatter.mediumDate(record.achievedAt))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
            }

            Spacer(minLength: Metrics.spacing8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(PersonalRecordFormatting.value(record, formatter: formatter))
                    .font(.appNumeric(16))
                    .foregroundStyle(Color.appTextPrimary)
                if let context = PersonalRecordFormatting.context(record) {
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(Color.appTextSecondary)
                }
                if let delta = PersonalRecordFormatting.delta(record, formatter: formatter) {
                    DeltaLabel(text: delta, direction: .up, font: .caption2)
                } else if record.previousValue == nil {
                    Text(L("progress.records.first"))
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
        }
        .padding(.vertical, Metrics.spacing4)
        .frame(minHeight: Metrics.minimumTapTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var accessibilityLabel: String {
        [
            showsExerciseName ? record.exerciseName : nil,
            L(record.kind.localizationKey),
            PersonalRecordFormatting.value(record, formatter: formatter),
            PersonalRecordFormatting.context(record),
            PersonalRecordFormatting.delta(record, formatter: formatter).map {
                L("progress.records.improvedBy", $0)
            },
            formatter.mediumDate(record.achievedAt),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

/// Every personal record, grouped by exercise, newest first.
struct PersonalRecordsView: View {
    let range: ProgressRangeStore

    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model = PersonalRecordsViewModel()

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
        .navigationTitle(L("progress.records.title"))
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
            if model.groups.isEmpty && model.kindFilter == nil {
                EmptyStateView(
                    systemImage: "trophy",
                    title: L("progress.records.empty.title"),
                    message: L("progress.records.empty.message")
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
            if model.availableKinds.count > 1 {
                filterBar
            }
            if model.groups.isEmpty {
                EmptyStateView(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: L("progress.records.noneForFilter"),
                    message: L("progress.records.noneForFilterMessage")
                ) {
                    Button(L("common.clear")) {
                        Task { await model.setFilter(nil, context: modelContext, range: range) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 260)
                }
                .frame(minHeight: 240)
            } else {
                Text(L("progress.records.countInRange", model.totalRecords))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVStack(spacing: Metrics.spacing12) {
                    ForEach(model.groups) { group in
                        Card {
                            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                                Text(group.exerciseName.localizedCapitalized)
                                    .font(.appCardTitle)
                                    .foregroundStyle(Color.appTextPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(group.records) { record in
                                    PersonalRecordRowView(record: record, showsExerciseName: false)
                                    if record.id != group.records.last?.id {
                                        Divider().overlay(Color.appSeparator)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Metrics.spacing8) {
                Button {
                    Task { await model.setFilter(nil, context: modelContext, range: range) }
                } label: {
                    Chip(title: L("common.all"), isSelected: model.kindFilter == nil)
                        .frame(minHeight: Metrics.minimumTapTarget)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.kindFilter == nil ? [.isButton, .isSelected] : .isButton)

                ForEach(model.availableKinds) { kind in
                    Button {
                        Task { await model.setFilter(kind, context: modelContext, range: range) }
                    } label: {
                        Chip(
                            title: L(kind.localizationKey),
                            systemImage: kind.symbolName,
                            isSelected: model.kindFilter == kind
                        )
                        .frame(minHeight: Metrics.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.kindFilter == kind ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

#Preview("Personal records") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            PersonalRecordsView(range: ProgressRangeStore())
        }
    }
}
