import SwiftUI

/// Today's food, at a glance: what is left in the day and how the three macros are tracking.
///
/// The headline is *remaining* rather than *eaten*, because at any point in the day the useful
/// question is "what can I still have?". Every bar is paired with its own numbers, so the card
/// still reads correctly with colour vision deficiency or in a screenshot printed in grey.
struct NutritionSummaryCard: View {
    let summary: HomeViewModel.NutritionSummary
    var isBusy: Bool = false
    var onOpen: () -> Void
    var onAddWater: () -> Void

    @Environment(\.displayFormatter) private var formatter

    private var target: MacroNutrients? { summary.target }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: Metrics.spacing16) {
                        header
                        if target == nil {
                            noTargetContent
                        } else {
                            energyRow
                            macroRows
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(accessibilitySummary))
                .accessibilityHint(Text(L("home.nutrition.openTab")))
                .accessibilityAddTraits(.isButton)

                if summary.isWaterTracked {
                    Divider().overlay(Color.appSeparator)
                    waterRow
                }
            }
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: Metrics.spacing8) {
            Image(systemName: "fork.knife")
                .font(.caption)
                .foregroundStyle(Color.appNutrition)
                .accessibilityHidden(true)
            Text(L("home.nutrition.title"))
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
                .textCase(.uppercase)
            Spacer(minLength: Metrics.spacing8)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.appTextTertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var energyRow: some View {
        let targetKcal = target?.kilocalories ?? 0
        let remaining = summary.remainingKilocalories

        HStack(alignment: .center, spacing: Metrics.spacing16) {
            ProgressRing(
                fraction: targetKcal > 0 ? summary.consumed.kilocalories / targetKcal : 0,
                lineWidth: 8,
                tint: remaining < 0 ? .appWarning : .appNutrition
            ) {
                Image(systemName: remaining < 0 ? "exclamationmark" : "flame.fill")
                    .font(.caption)
                    .foregroundStyle(remaining < 0 ? Color.appWarning : Color.appNutrition)
            }
            .frame(width: 54, height: 54)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Metrics.spacing2) {
                Text(formatter.energy(abs(remaining)))
                    .font(.appNumeric(26))
                    .foregroundStyle(remaining < 0 ? Color.appWarning : Color.appTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(remaining < 0 ? L("home.nutrition.overLabel") : L("home.nutrition.remaining"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: Metrics.spacing2) {
                Text(L("home.nutrition.eaten"))
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                Text(L("home.nutrition.macroValue",
                       formatter.energy(summary.consumed.kilocalories, includeUnit: false),
                       formatter.energy(targetKcal)))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    @ViewBuilder
    private var macroRows: some View {
        if let target {
            VStack(spacing: Metrics.spacing12) {
                macroRow(
                    label: L("home.nutrition.protein"),
                    consumed: summary.consumed.proteinG,
                    target: target.proteinG,
                    tint: .appNutrition
                )
                macroRow(
                    label: L("home.nutrition.carbs"),
                    consumed: summary.consumed.carbsG,
                    target: target.carbsG,
                    tint: .appAccent
                )
                macroRow(
                    label: L("home.nutrition.fat"),
                    consumed: summary.consumed.fatG,
                    target: target.fatG,
                    tint: .appRecovery
                )
            }
        }
    }

    private func macroRow(label: String, consumed: Double, target: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                Spacer(minLength: Metrics.spacing8)
                Text(L("home.nutrition.macroValue", formatter.macro(consumed), formatter.macro(target)))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
            }
            ProgressBar(value: consumed, total: target, tint: tint, height: 6, warnsOnOverflow: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var noTargetContent: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            Text(L("home.nutrition.noTargetTitle"))
                .font(.headline)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("home.nutrition.noTargetMessage"))
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("home.nutrition.setTarget"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appNutrition)
                .padding(.top, Metrics.spacing4)
        }
    }

    private var waterRow: some View {
        HStack(spacing: Metrics.spacing12) {
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                HStack(spacing: Metrics.spacing6) {
                    Image(systemName: "drop.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.appRecovery)
                        .accessibilityHidden(true)
                    Text(L("home.nutrition.water"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                    Spacer(minLength: Metrics.spacing8)
                    Text(L("home.nutrition.waterProgress",
                           Int(summary.waterMilliliters.rounded()),
                           Int(summary.waterTargetMilliliters.rounded())))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(1)
                }
                ProgressBar(
                    value: summary.waterMilliliters,
                    total: summary.waterTargetMilliliters,
                    tint: .appRecovery,
                    height: 6
                )
            }
            .accessibilityElement(children: .combine)

            Button(action: onAddWater) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.appRecovery)
                    .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                    .background(Color.appRecovery.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(Text(L("home.nutrition.addWater",
                                       Int(HomeViewModel.quickWaterMilliliters))))
        }
    }

    private var accessibilitySummary: String {
        guard let target else {
            return "\(L("home.nutrition.title")), \(L("home.nutrition.noTargetTitle"))"
        }
        let remaining = summary.remainingKilocalories
        let energy = remaining < 0
            ? "\(formatter.energy(-remaining)) \(L("home.nutrition.overLabel"))"
            : "\(formatter.energy(remaining)) \(L("home.nutrition.remaining"))"
        let macros = [
            "\(L("home.nutrition.protein")) \(L("home.nutrition.macroValue", formatter.macro(summary.consumed.proteinG), formatter.macro(target.proteinG)))",
            "\(L("home.nutrition.carbs")) \(L("home.nutrition.macroValue", formatter.macro(summary.consumed.carbsG), formatter.macro(target.carbsG)))",
            "\(L("home.nutrition.fat")) \(L("home.nutrition.macroValue", formatter.macro(summary.consumed.fatG), formatter.macro(target.fatG)))"
        ].joined(separator: ", ")
        return "\(L("home.nutrition.title")), \(energy), \(macros)"
    }
}

#Preview("With target") {
    PreviewHost(scenario: .fullNutritionDay) {
        ScrollView {
            NutritionSummaryCard(
                summary: .init(
                    consumed: MacroNutrients(kilocalories: 1480, proteinG: 118, carbsG: 152, fatG: 46),
                    target: MacroNutrients(kilocalories: 2600, proteinG: 175, carbsG: 290, fatG: 78),
                    waterMilliliters: 1250,
                    waterTargetMilliliters: 2500,
                    isWaterTracked: true
                ),
                onOpen: {}, onAddWater: {}
            )
            .screenPadding()
        }
        .background(Color.appBackground)
    }
}
