import SwiftUI
import SwiftData

/// The day's micronutrients against reference intakes.
///
/// The screen is built around one distinction the rest of the app also respects: *no data* is not
/// *zero*. A food whose label never printed its iron content leaves iron unknown, and drawing an
/// empty bar for it would assert a shortfall nothing here can support. Unknown values therefore
/// render as "—" with a note about the food data, and no copy on this screen describes a shortfall
/// as a deficiency — that is a clinical judgement, and a food diary is not equipped to make it.
struct MicronutrientDetailView: View {
    private let initialDayKey: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model: MicronutrientDetailViewModel

    init(dayKey: String = DayKey.today) {
        self.initialDayKey = dayKey
        _model = State(initialValue: MicronutrientDetailViewModel(dayKey: dayKey))
    }

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L("nutritionLibrary.micros.title"))
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.load(context: modelContext) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("common.loading"))
        case .failed(let explanation):
            ErrorStateView(
                message: explanation.text,
                retryTitle: L("common.retry"),
                retry: { Task { await model.load(context: modelContext) } }
            )
        case .ready:
            ScrollView {
                VStack(spacing: Metrics.spacing16) {
                    dayHeader
                    if model.entryCount == 0 {
                        EmptyStateView(
                            systemImage: "leaf",
                            title: L("nutritionLibrary.micros.emptyTitle"),
                            message: L("nutritionLibrary.micros.emptyMessage")
                        ) {
                            if model.dayKey != DayKey.today {
                                Button(L("common.today")) {
                                    Task { await goToToday() }
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .frame(maxWidth: 240)
                            }
                        }
                    } else {
                        dataNoteCard
                        ForEach(model.groups) { group in
                            groupCard(group)
                        }
                    }
                }
                .screenPadding()
                .padding(.vertical, Metrics.spacing16)
                .readableWidth()
            }
        }
    }

    // MARK: - Header

    private var dayHeader: some View {
        HStack(spacing: Metrics.spacing12) {
            Button {
                Task { await model.step(days: -1) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .minimumTapTarget()
                    .background(Color.appFill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L("nutritionLibrary.micros.previousDay")))

            Text(formatter.relativeDay(model.date))
                .font(.appCardTitle)
                .foregroundStyle(Color.appTextPrimary)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)

            Button {
                Task { await model.step(days: 1) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(model.canStepForward ? Color.appTextPrimary : Color.appTextTertiary)
                    .minimumTapTarget()
                    .background(Color.appFill, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canStepForward)
            .accessibilityLabel(Text(L("nutritionLibrary.micros.nextDay")))
        }
    }

    /// The standing caveat. Stated once, at the top, rather than repeated on every unknown row.
    private var dataNoteCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text(L("nutritionLibrary.micros.referenceNote"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.unknownCount > 0 {
                    Text(L("nutritionLibrary.micros.unknownNote", model.unknownCount))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.hasExplicitGoals {
                    Text(L("nutritionLibrary.micros.goalNote"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Groups

    private func groupCard(_ group: MicronutrientGroup) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(L(group.titleKey))
                ForEach(group.statuses, id: \.nutrient) { status in
                    MicronutrientRow(status: status, locale: formatter.locale)
                }
            }
        }
    }

    private func goToToday() async {
        // Walking forward one day at a time would be silly; the model clamps at today anyway.
        let days = daysBetween(model.dayKey, DayKey.today)
        await model.step(days: days)
    }

    private func daysBetween(_ from: String, _ to: String) -> Int {
        guard let start = DayKey.date(from: from), let end = DayKey.date(from: to) else { return 0 }
        return Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
    }
}

// MARK: - Row

/// One nutrient against its reference intake.
///
/// Limiting nutrients — sodium, sugars, saturated fat, cholesterol — read the other way round: the
/// bar filling up is a caution rather than an achievement, so it is tinted differently *and*
/// labelled "limit", because colour alone would carry the meaning for nobody using VoiceOver and
/// for many people using their eyes.
private struct MicronutrientRow: View {
    let status: MicronutrientStatus
    let locale: Locale

    private var isLimiting: Bool { status.nutrient.isLimitingNutrient }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                Text(L(status.nutrient.localizationKey))
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if isLimiting {
                    Text(L("nutritionLibrary.micros.limit"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.appWarning)
                        .padding(.horizontal, Metrics.spacing6)
                        .padding(.vertical, 2)
                        .background(Color.appWarning.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: Metrics.spacing8)
                Text(valueText)
                    .font(.appNumeric(15, weight: .medium))
                    .foregroundStyle(status.isUnknown ? Color.appTextTertiary : Color.appTextPrimary)
            }

            if let fraction = status.fraction {
                ProgressBar(
                    value: fraction,
                    total: 1,
                    tint: isLimiting ? Color.appWarning : Color.appNutrition,
                    height: 6,
                    warnsOnOverflow: isLimiting
                )
            } else if status.isUnknown {
                Text(L("nutritionLibrary.micros.noData"))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("nutritionLibrary.micros.noReference"))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Metrics.spacing2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var valueText: String {
        guard let consumed = status.consumed else { return "—" }
        let amount = Units.formatDecimal(consumed, digits: consumed < 10 ? 1 : 0, locale: locale)
            + " " + status.nutrient.unit.rawValue
        guard let reference = status.reference else { return amount }
        let referenceText = Units.formatDecimal(reference, digits: reference < 10 ? 1 : 0, locale: locale)
            + " " + status.nutrient.unit.rawValue
        return L("nutritionLibrary.micros.ofReference", amount, referenceText)
    }

    private var accessibilityLabel: String {
        let name = L(status.nutrient.localizationKey)
        guard !status.isUnknown else {
            return L("nutritionLibrary.micros.rowUnknownAccessibility", name)
        }
        guard let fraction = status.fraction else {
            return L("nutritionLibrary.micros.rowNoReferenceAccessibility", name, valueText)
        }
        let key = isLimiting
            ? "nutritionLibrary.micros.rowLimitAccessibility"
            : "nutritionLibrary.micros.rowAccessibility"
        return L(key, name, valueText, NutritionFormat.percent(fraction))
    }
}

#Preview("Micronutrients") {
    PreviewHost(scenario: .fullNutritionDay) {
        NavigationStack {
            MicronutrientDetailView()
        }
    }
}
