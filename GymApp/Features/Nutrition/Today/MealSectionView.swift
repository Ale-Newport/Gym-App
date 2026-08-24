import SwiftUI

/// One meal of the day: its entries, its subtotal, and everything that adds to it.
///
/// The section takes the day's view model rather than a dozen callbacks because every action it
/// offers is a plain mutation of the day. Only the four things that need a sheet, an alert or a
/// navigation push are handed back to the hub, which is the view that owns presentation.
struct MealSectionView: View {
    let slot: MealSlot
    let model: NutritionDayViewModel
    let onAddFood: (MealSlot) -> Void
    let onEditEntry: (FoodLogEntry) -> Void
    let onShowDetails: (FoodLogEntry) -> Void
    let onSaveAsMeal: (MealSlot) -> Void

    @Environment(\.displayFormatter) private var formatter

    private var entries: [FoodLogEntry] { model.entries(in: slot) }
    private var subtotal: MacroNutrients { model.subtotal(of: slot) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                header

                if entries.isEmpty {
                    emptyRow
                } else {
                    ForEach(entries, id: \.id) { entry in
                        Divider().overlay(Color.appSeparator)
                        FoodLogRow(
                            entry: entry,
                            isFavorite: model.isFavorite(entry),
                            canDuplicate: model.canDuplicate(entry),
                            canFavorite: model.food(for: entry) != nil,
                            onEdit: { onEditEntry(entry) },
                            onShowDetails: { onShowDetails(entry) },
                            onMove: { model.move(entry, to: $0) },
                            onDuplicate: { model.duplicate(entry) },
                            onToggleFavorite: { model.toggleFavorite(entry) },
                            onDelete: { model.delete(entry) }
                        )
                    }
                }

                addButton
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
            Image(systemName: slot.symbolName)
                .font(.footnote)
                .foregroundStyle(Color.appNutrition)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(slot.localizationKey))
                    .font(.appCardTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !entries.isEmpty {
                    MacroSummaryLine(macros: subtotal, font: .caption2)
                }
            }
            Spacer(minLength: Metrics.spacing8)
            Text(formatter.energy(subtotal.kilocalories))
                .font(.appNumeric(17))
                .foregroundStyle(entries.isEmpty ? Color.appTextTertiary : Color.appTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            sectionMenu
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    private var sectionMenu: some View {
        Menu {
            Button {
                onAddFood(slot)
            } label: {
                Label(L("nutritionLog.action.addFood"), systemImage: "plus")
            }
            if model.yesterdaySlotsWithFood.contains(slot) {
                Button {
                    model.copyYesterday(into: slot)
                } label: {
                    Label(L("nutritionLog.action.copyYesterdayMeal", L(slot.localizationKey)), systemImage: "clock.arrow.circlepath")
                }
            }
            if !entries.isEmpty {
                Button {
                    onSaveAsMeal(slot)
                } label: {
                    Label(L("nutritionLog.action.saveAsMeal"), systemImage: "square.and.arrow.down")
                }
            }
            if !model.savedMeals.isEmpty {
                Menu {
                    ForEach(model.savedMeals, id: \.id) { meal in
                        Button {
                            model.logSavedMeal(meal, into: slot)
                        } label: {
                            Text("\(meal.name) · \(formatter.energy(model.nutrition(of: meal).kilocalories))")
                        }
                    }
                } label: {
                    Label(L("nutritionLog.action.logSavedMeal"), systemImage: "tray.full")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L("nutritionLog.a11y.mealActions", L(slot.localizationKey)))
    }

    private var emptyRow: some View {
        Text(L("nutritionLog.meal.empty"))
            .font(.footnote)
            .foregroundStyle(Color.appTextTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Metrics.spacing8)
    }

    private var addButton: some View {
        Button {
            onAddFood(slot)
        } label: {
            Label(L("nutritionLog.action.addFood"), systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appNutrition)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: Metrics.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("nutritionLog.a11y.addFoodTo", L(slot.localizationKey)))
    }
}

#Preview("Meal section") {
    PreviewHost(scenario: .fullNutritionDay) {
        MealSectionPreviewHarness()
    }
}

private struct MealSectionPreviewHarness: View {
    @Environment(\.modelContext) private var context
    @Environment(AppEnvironment.self) private var environment
    @State private var model: NutritionDayViewModel?

    var body: some View {
        ScrollView {
            if let model {
                VStack(spacing: Metrics.spacing16) {
                    MealSectionView(slot: .breakfast, model: model, onAddFood: { _ in }, onEditEntry: { _ in }, onShowDetails: { _ in }, onSaveAsMeal: { _ in })
                    MealSectionView(slot: .snacks, model: model, onAddFood: { _ in }, onEditEntry: { _ in }, onShowDetails: { _ in }, onSaveAsMeal: { _ in })
                }
                .screenPadding()
            } else {
                LoadingStateView(message: L("common.loading"))
            }
        }
        .background(Color.appBackground)
        .task {
            let created = NutritionDayViewModel(context: context, environment: environment)
            created.load()
            model = created
        }
    }
}
