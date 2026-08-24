import SwiftUI

/// The day's energy and macronutrients: a ring for calories, a bar for each macro.
///
/// Two decisions worth knowing about. First, the ring's headline number is what is *left*, not what
/// has been eaten — that is the number somebody standing in front of the fridge actually needs.
/// Second, going over target is never signalled by colour alone: the amount over is written out, so
/// the state survives both a colour-vision deficiency and a glance at a dimmed screen.
struct MacroRingsHeader: View {
    let progress: DailyNutritionProgress

    @Environment(\.displayFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var target: MacroNutrients? { progress.target }
    private var consumed: MacroNutrients { progress.consumed }

    private var energyRemaining: Double { (target?.kilocalories ?? 0) - consumed.kilocalories }
    private var isOverEnergy: Bool { target != nil && energyRemaining < 0 }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Metrics.spacing16) {
                        ring
                        energyFigures
                    }
                } else {
                    HStack(alignment: .center, spacing: Metrics.spacing20) {
                        ring
                        energyFigures
                    }
                }

                Divider().overlay(Color.appSeparator)

                VStack(spacing: Metrics.spacing12) {
                    macroRow(
                        title: L("nutritionLog.macro.protein"),
                        consumed: consumed.proteinG,
                        target: target?.proteinG,
                        tint: .appAccent
                    )
                    macroRow(
                        title: L("nutritionLog.macro.carbs"),
                        consumed: consumed.carbsG,
                        target: target?.carbsG,
                        tint: .appRecovery
                    )
                    macroRow(
                        title: L("nutritionLog.macro.fat"),
                        consumed: consumed.fatG,
                        target: target?.fatG,
                        tint: .appWarning
                    )
                }
            }
        }
    }

    // MARK: Energy

    private var ring: some View {
        ProgressRing(
            fraction: min(energyFraction, 1),
            lineWidth: 12,
            tint: isOverEnergy ? .appWarning : .appNutrition
        ) {
            VStack(spacing: 2) {
                Text(ringValue)
                    .font(.appNumeric(24))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(ringCaption)
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(Metrics.spacing8)
        }
        .frame(width: 116, height: 116)
        // The ring is a picture of the numbers spelled out beside it, so it is not a second
        // announcement for VoiceOver.
        .accessibilityHidden(true)
    }

    private var energyFigures: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            figure(label: L("nutritionLog.energy.eaten"), value: formatter.energy(consumed.kilocalories))
            if let target {
                figure(label: L("nutritionLog.energy.target"), value: formatter.energy(target.kilocalories))
                figure(
                    label: isOverEnergy ? L("nutritionLog.energy.over") : L("nutritionLog.energy.remaining"),
                    value: formatter.energy(abs(energyRemaining)),
                    tint: isOverEnergy ? .appWarning : .appNutrition
                )
            } else {
                Text(L("nutritionLog.energy.noTarget"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(energyAccessibilityLabel)
        // One element carrying the whole energy picture — eaten, target and remaining — so
        // VoiceOver reads it as a sentence and anything watching it sees the numbers move.
        .accessibilityIdentifier("nutritionLog.energySummary")
    }

    private func figure(label: String, value: String, tint: Color = .appTextPrimary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
            Spacer(minLength: Metrics.spacing4)
            Text(value)
                .font(.appNumeric(17))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var energyFraction: Double {
        guard let target, target.kilocalories > 0 else { return 0 }
        return consumed.kilocalories / target.kilocalories
    }

    private var ringValue: String {
        guard target != nil else { return formatter.energy(consumed.kilocalories, includeUnit: false) }
        return formatter.energy(abs(energyRemaining), includeUnit: false)
    }

    private var ringCaption: String {
        guard target != nil else { return formatter.energyUnitLabel }
        return isOverEnergy ? L("nutritionLog.energy.over") : L("nutritionLog.energy.left")
    }

    private var energyAccessibilityLabel: String {
        guard let target else {
            return L("nutritionLog.a11y.energyNoTarget", formatter.energy(consumed.kilocalories))
        }
        return L(
            isOverEnergy ? "nutritionLog.a11y.energyOver" : "nutritionLog.a11y.energyRemaining",
            formatter.energy(consumed.kilocalories),
            formatter.energy(target.kilocalories),
            formatter.energy(abs(energyRemaining))
        )
    }

    // MARK: Macros

    private func macroRow(title: String, consumed: Double, target: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Metrics.spacing8)
                Text(macroFigure(consumed: consumed, target: target))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if let target, target > 0 {
                ProgressBar(value: consumed, total: target, tint: tint, height: 8, warnsOnOverflow: true)
                Text(macroCaption(consumed: consumed, target: target))
                    .font(.caption2)
                    .foregroundStyle(consumed > target ? Color.appWarning : Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(macroAccessibilityLabel(title: title, consumed: consumed, target: target))
    }

    private func macroFigure(consumed: Double, target: Double?) -> String {
        guard let target else { return formatter.macro(consumed) }
        return "\(Units.formatDecimal(consumed, digits: 0, locale: formatter.locale)) / \(formatter.macro(target))"
    }

    private func macroCaption(consumed: Double, target: Double) -> String {
        let difference = target - consumed
        return difference < 0
            ? L("nutritionLog.macro.over", formatter.macro(-difference))
            : L("nutritionLog.macro.left", formatter.macro(difference))
    }

    private func macroAccessibilityLabel(title: String, consumed: Double, target: Double?) -> String {
        guard let target, target > 0 else {
            return L("nutritionLog.a11y.macroNoTarget", title, formatter.macro(consumed))
        }
        let difference = target - consumed
        return L(
            difference < 0 ? "nutritionLog.a11y.macroOver" : "nutritionLog.a11y.macroRemaining",
            title,
            formatter.macro(consumed),
            formatter.macro(target),
            formatter.macro(abs(difference))
        )
    }
}

#Preview("Macro rings") {
    PreviewHost(scenario: .fullNutritionDay) {
        ScrollView {
            VStack(spacing: Metrics.spacing16) {
                MacroRingsHeader(progress: DailyNutritionProgress(
                    dayKey: DayKey.today,
                    target: MacroNutrients(kilocalories: 2760, proteinG: 165, carbsG: 320, fatG: 82),
                    consumed: MacroNutrients(kilocalories: 1980, proteinG: 148, carbsG: 210, fatG: 61),
                    remaining: MacroNutrients(kilocalories: 780, proteinG: 17, carbsG: 110, fatG: 21),
                    energyProgress: 0.72,
                    waterMilliliters: 1500
                ))
                MacroRingsHeader(progress: DailyNutritionProgress(
                    dayKey: DayKey.today,
                    target: MacroNutrients(kilocalories: 2200, proteinG: 150, carbsG: 220, fatG: 70),
                    consumed: MacroNutrients(kilocalories: 2480, proteinG: 121, carbsG: 300, fatG: 88),
                    remaining: MacroNutrients(kilocalories: -280, proteinG: 29, carbsG: -80, fatG: -18),
                    energyProgress: 1.13,
                    waterMilliliters: 500
                ))
            }
            .screenPadding()
        }
        .background(Color.appBackground)
    }
}
