import SwiftUI

/// Water for the day: a total against the target and three one-tap amounts.
///
/// Quick-add buttons are sized at the gym tap target rather than the standard one. Drinking water
/// is the single most-repeated action in the whole app, it is done one-handed while holding a
/// bottle, and a mis-tap costs an undo — which is why the undo sits right next to them.
struct WaterTrackerView: View {
    let consumedMl: Double
    let targetMl: Double
    let onAdd: (Double) -> Void
    let onUndo: () -> Void

    /// The amounts a glass, a small bottle and a large bottle actually hold.
    private static let quickAmounts: [Double] = [250, 330, 500]

    @Environment(\.displayFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var fraction: Double {
        guard targetMl > 0 else { return 0 }
        return consumedMl / targetMl
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                    Image(systemName: "drop.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.appRecovery)
                        .accessibilityHidden(true)
                    Text(L("nutritionLog.water.title"))
                        .font(.appCardTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Metrics.spacing8)
                    Text(totalText)
                        .font(.appNumeric(17))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                if targetMl > 0 {
                    ProgressBar(value: consumedMl, total: targetMl, tint: .appRecovery, height: 8)
                    Text(remainingText)
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                addButtons
            }
            .accessibilityElement(children: .contain)
        }
        .accessibilityLabel(L("nutritionLog.water.title"))
    }

    @ViewBuilder
    private var addButtons: some View {
        // Three buttons plus an undo do not fit on one line once text is enlarged, so the row
        // becomes a column rather than squeezing each label to nothing.
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: Metrics.spacing8) {
                ForEach(Self.quickAmounts, id: \.self) { amount in addButton(amount) }
                undoButton
            }
        } else {
            HStack(spacing: Metrics.spacing8) {
                ForEach(Self.quickAmounts, id: \.self) { amount in addButton(amount) }
                undoButton
            }
        }
    }

    private func addButton(_ amount: Double) -> some View {
        Button {
            Haptics.tap()
            onAdd(amount)
        } label: {
            Text(millilitreText(amount))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appRecovery)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Metrics.gymTapTarget)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                        .fill(Color.appRecoveryMuted)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("nutritionLog.a11y.addWater", millilitreText(amount)))
    }

    private var undoButton: some View {
        Button {
            Haptics.tap()
            onUndo()
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(consumedMl > 0 ? Color.appTextSecondary : Color.appTextTertiary)
                .frame(minWidth: Metrics.gymTapTarget)
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                .frame(minHeight: Metrics.gymTapTarget)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                        .fill(Color.appFill)
                )
        }
        .buttonStyle(.plain)
        .disabled(consumedMl <= 0)
        .accessibilityLabel(L("nutritionLog.a11y.undoWater"))
    }

    // MARK: Text

    /// Millilitres below a litre, litres above it — the way a bottle is labelled and the way people
    /// talk about a day's intake.
    private func millilitreText(_ value: Double) -> String {
        if value >= 1000 {
            return L("nutritionLog.water.litres", Units.formatDecimal(value / 1000, digits: 1, locale: formatter.locale))
        }
        return L("nutritionLog.water.millilitres", Units.formatDecimal(value, digits: 0, locale: formatter.locale))
    }

    private var totalText: String {
        guard targetMl > 0 else { return millilitreText(consumedMl) }
        return "\(millilitreText(consumedMl)) / \(millilitreText(targetMl))"
    }

    private var remainingText: String {
        let remaining = targetMl - consumedMl
        return remaining <= 0
            ? L("nutritionLog.water.targetReached")
            : L("nutritionLog.water.remaining", millilitreText(remaining))
    }
}

/// The same tracker presented on its own, for the "log water" deep link that arrives from the
/// widget and from Shortcuts.
struct WaterEntrySheet: View {
    let consumedMl: Double
    let targetMl: Double
    let onAdd: (Double) -> Void
    let onUndo: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                WaterTrackerView(consumedMl: consumedMl, targetMl: targetMl, onAdd: onAdd, onUndo: onUndo)
                    .screenPadding()
                    .padding(.vertical, Metrics.spacing20)
                    .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(L("nutritionLog.water.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview("Water tracker") {
    PreviewHost(scenario: .fullNutritionDay) {
        ScrollView {
            VStack(spacing: Metrics.spacing16) {
                WaterTrackerView(consumedMl: 1500, targetMl: 2500, onAdd: { _ in }, onUndo: {})
                WaterTrackerView(consumedMl: 2600, targetMl: 2500, onAdd: { _ in }, onUndo: {})
            }
            .screenPadding()
        }
        .background(Color.appBackground)
    }
}
