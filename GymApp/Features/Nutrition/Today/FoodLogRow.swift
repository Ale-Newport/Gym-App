import SwiftUI

/// One logged food inside a meal.
///
/// The row is two controls, not one: tapping the body opens the portion editor, and the trailing
/// menu carries the destructive and secondary actions. Nesting a menu inside a button would make
/// both unreliable, and swipe actions are unavailable here because the day is a `LazyVStack` rather
/// than a `List` — a list would fight the meal-section layout for very little gain.
struct FoodLogRow: View {
    let entry: FoodLogEntry
    var isFavorite: Bool = false
    var canDuplicate: Bool = true
    var canFavorite: Bool = true

    let onEdit: () -> Void
    let onShowDetails: () -> Void
    let onMove: (MealSlot) -> Void
    let onDuplicate: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void

    @Environment(\.displayFormatter) private var formatter
    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacing8) {
            Button(action: onEdit) {
                rowContent
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(L("nutritionLog.a11y.rowHint"))
            .accessibilityActions { accessibilityActions }

            menuButton
        }
        .padding(.vertical, Metrics.spacing8)
        .contentShape(Rectangle())
        .contextMenu { actionMenu }
        .confirmationDialog(
            L("nutritionLog.action.deleteConfirm", entry.foodNameSnapshot),
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(L("common.delete"), role: .destructive, action: onDelete)
            Button(L("common.cancel"), role: .cancel) {}
        }
    }

    // MARK: Content

    private var rowContent: some View {
        HStack(alignment: .top, spacing: Metrics.spacing12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Metrics.spacing4) {
                    Text(entry.foodNameSnapshot)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.appAccent)
                            .accessibilityHidden(true)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                MacroSummaryLine(macros: entry.macrosSnapshot, font: .caption2)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatter.energy(entry.macrosSnapshot.kilocalories, includeUnit: false))
                .font(.appNumeric(17))
                .foregroundStyle(Color.appTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var menuButton: some View {
        Menu {
            actionMenu
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L("nutritionLog.a11y.rowActions", entry.foodNameSnapshot))
    }

    @ViewBuilder
    private var actionMenu: some View {
        Button {
            onEdit()
        } label: {
            Label(L("nutritionLog.action.editPortion"), systemImage: "slider.horizontal.3")
        }
        Button {
            onShowDetails()
        } label: {
            Label(L("nutritionLog.food.details"), systemImage: "info.circle")
        }
        if canDuplicate {
            Button {
                onDuplicate()
            } label: {
                Label(L("common.duplicate"), systemImage: "plus.square.on.square")
            }
        }
        if canFavorite {
            Button {
                onToggleFavorite()
            } label: {
                Label(
                    isFavorite ? L("nutritionLog.action.unfavorite") : L("nutritionLog.action.favorite"),
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }
        }
        Menu {
            ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                Button {
                    onMove(slot)
                } label: {
                    Label(L(slot.localizationKey), systemImage: slot.symbolName)
                }
                .disabled(slot == entry.mealSlot)
            }
        } label: {
            Label(L("nutritionLog.action.moveTo"), systemImage: "arrow.left.arrow.right")
        }
        Divider()
        Button(role: .destructive) {
            isConfirmingDelete = true
        } label: {
            Label(L("common.delete"), systemImage: "trash")
        }
    }

    @ViewBuilder
    private var accessibilityActions: some View {
        Button(L("nutritionLog.action.editPortion"), action: onEdit)
        Button(L("nutritionLog.food.details"), action: onShowDetails)
        if canDuplicate { Button(L("common.duplicate"), action: onDuplicate) }
        if canFavorite {
            Button(isFavorite ? L("nutritionLog.action.unfavorite") : L("nutritionLog.action.favorite"), action: onToggleFavorite)
        }
        Button(L("common.delete")) { isConfirmingDelete = true }
    }

    // MARK: Text

    /// Portion and brand on one line. A named serving is described generically because the entry
    /// stores only the index of the serving it used — the name belongs to the food, which may since
    /// have been edited or deleted, and inventing a name here would be a lie about history.
    private var subtitle: String {
        var parts = [portionText]
        if let brand = entry.brandSnapshot, !brand.isEmpty { parts.append(brand) }
        return parts.joined(separator: " · ")
    }

    private var portionText: String {
        let amount = Units.formatDecimal(
            entry.quantity,
            digits: entry.quantity < 10 && entry.quantity != entry.quantity.rounded() ? 1 : 0,
            locale: formatter.locale
        )
        switch entry.unit {
        case .grams, .milliliters:
            return "\(amount) \(L(entry.unit.localizationKey))"
        case .piece, .serving:
            return "\(amount) × \(L(entry.unit.localizationKey))"
        }
    }

    private var accessibilityLabel: String {
        L(
            "nutritionLog.a11y.entry",
            entry.foodNameSnapshot,
            portionText,
            formatter.energy(entry.macrosSnapshot.kilocalories),
            formatter.macro(entry.macrosSnapshot.proteinG),
            formatter.macro(entry.macrosSnapshot.carbsG),
            formatter.macro(entry.macrosSnapshot.fatG)
        )
    }
}

#Preview("Food log row") {
    PreviewHost(scenario: .fullNutritionDay) {
        FoodLogRowPreviewHarness()
    }
}

/// Pulls a real logged entry out of the preview store so the row is previewed against the same
/// shape of data it renders in the app.
private struct FoodLogRowPreviewHarness: View {
    @Environment(\.modelContext) private var context
    @State private var entry: FoodLogEntry?

    var body: some View {
        Group {
            if let entry {
                Card {
                    FoodLogRow(
                        entry: entry,
                        isFavorite: true,
                        onEdit: {}, onShowDetails: {}, onMove: { _ in },
                        onDuplicate: {}, onToggleFavorite: {}, onDelete: {}
                    )
                }
                .screenPadding()
            } else {
                LoadingStateView(message: L("common.loading"))
            }
        }
        .task {
            entry = try? NutritionRepository(context: context).dayLog(for: DayKey.today).first
        }
    }
}
