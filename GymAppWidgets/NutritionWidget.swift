import WidgetKit
import SwiftUI

/// Today's food: what has been eaten, what is left, and how the three macronutrients are tracking.
struct NutritionWidget: Widget {
    static let kind = "NutritionWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            NutritionWidgetView(entry: entry)
                .containerBackground(WidgetPalette.background, for: .widget)
        }
        .configurationDisplayName(Text(L("widget.nutrition.displayName")))
        .description(Text(L("widget.nutrition.description")))
        .supportedFamilies([.systemMedium])
    }
}

struct NutritionWidgetView: View {
    let entry: SnapshotEntry

    private var snapshot: SharedSnapshot { entry.snapshot }

    var body: some View {
        Group {
            if !entry.isLive {
                WidgetNeutralMessage(
                    symbolName: "square.dashed",
                    title: L("widget.unavailable.title"),
                    message: L("widget.unavailable.message")
                )
            } else if !snapshot.nutritionEnabled {
                WidgetNeutralMessage(
                    symbolName: "fork.knife",
                    title: L("widget.nutrition.disabled.title"),
                    message: L("widget.nutrition.disabled.message"),
                    tint: WidgetPalette.nutrition
                )
            } else if !snapshot.hasNutritionTarget {
                WidgetNeutralMessage(
                    symbolName: "target",
                    title: L("widget.nutrition.noTarget.title"),
                    message: L("widget.nutrition.noTarget.message"),
                    tint: WidgetPalette.nutrition
                )
            } else if !snapshot.coversDay(of: entry.date) {
                // The snapshot predates today, so its consumption figures describe another day.
                // Showing them under today's heading would be a quiet lie, so the widget says so.
                WidgetNeutralMessage(
                    symbolName: "clock.arrow.circlepath",
                    title: L("widget.nutrition.stale.title"),
                    message: L("widget.nutrition.stale.message"),
                    tint: WidgetPalette.nutrition
                )
            } else {
                content
            }
        }
        .widgetURL(WidgetLink.nutritionToday)
    }

    // MARK: Content

    private var content: some View {
        HStack(alignment: .top, spacing: WidgetMetrics.spacing12) {
            energyColumn
            Spacer(minLength: 0)
            macroColumn
        }
    }

    private var energyColumn: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.spacing4) {
            HStack(spacing: WidgetMetrics.spacing4) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 10, weight: .bold))
                Text(L("widget.nutrition.today"))
                    .font(.widgetOverline)
                    .tracking(0.6)
            }
            .foregroundStyle(WidgetPalette.nutrition)

            Text(WidgetFormat.whole(snapshot.caloriesConsumed))
                .font(.widgetNumeric(30, weight: .bold))
                .foregroundStyle(WidgetPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(L("widget.calories.ofTarget", WidgetFormat.whole(snapshot.caloriesTarget)))
                .font(.widgetCaption)
                .foregroundStyle(WidgetPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            WidgetProgressBar(
                value: snapshot.caloriesConsumed,
                total: snapshot.caloriesTarget,
                tint: WidgetPalette.nutrition,
                height: 6,
                warnsOnOverflow: true
            )
            .padding(.top, WidgetMetrics.spacing2)

            Spacer(minLength: 0)

            HStack(spacing: WidgetMetrics.spacing4) {
                Image(systemName: snapshot.isOverCalories ? "exclamationmark.circle.fill" : "leaf.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(remainingText)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(snapshot.isOverCalories ? WidgetPalette.warning : WidgetPalette.nutrition)
        }
        .frame(width: 132, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("widget.accessibility.calories",
                                   WidgetFormat.whole(snapshot.caloriesConsumed),
                                   WidgetFormat.whole(snapshot.caloriesTarget))))
        .accessibilityValue(Text(remainingText))
    }

    private var remainingText: String {
        snapshot.isOverCalories
            ? L("widget.calories.over", WidgetFormat.whole(abs(snapshot.caloriesRemaining)))
            : L("widget.calories.remaining", WidgetFormat.whole(max(0, snapshot.caloriesRemaining)))
    }

    private var macroColumn: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.spacing8) {
            WidgetMacroBar(
                title: L("widget.macro.protein"),
                consumed: snapshot.proteinConsumedG,
                target: snapshot.proteinTargetG,
                tint: WidgetPalette.protein
            )
            WidgetMacroBar(
                title: L("widget.macro.carbs"),
                consumed: snapshot.carbsConsumedG,
                target: snapshot.carbsTargetG,
                tint: WidgetPalette.carbs
            )
            WidgetMacroBar(
                title: L("widget.macro.fat"),
                consumed: snapshot.fatConsumedG,
                target: snapshot.fatTargetG,
                tint: WidgetPalette.fat
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Previews

#Preview("On target", as: .systemMedium) {
    NutritionWidget()
} timeline: {
    SnapshotEntry.placeholder()
}

#Preview("Over target", as: .systemMedium) {
    NutritionWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .overTargetSample, isLive: true)
}

#Preview("No targets yet", as: .systemMedium) {
    NutritionWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .emptyPlanSample, isLive: true)
}
