import SwiftUI
import SwiftData

/// `sheet(item:)` needs something `Identifiable`; a bare `UUID` is not, and conforming Foundation's
/// type app-wide would be a surprising thing for one screen to do.
private struct EditingSavedMeal: Identifiable, Hashable {
    let id: UUID
}

/// The user's saved meals: build one, edit it, log it into any slot in a single tap.
///
/// Two ways in, because they match how people actually discover they have a "usual breakfast" —
/// either they assemble one deliberately, or they notice after eating it that they eat the same
/// thing every Tuesday. The second path is the one that gets used, so it is on this screen rather
/// than buried in the diary.
struct SavedMealsView: View {
    var dayKey: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model: SavedMealsViewModel
    @State private var editingMeal: EditingSavedMeal?
    @State private var isCreatingMeal = false
    @State private var pendingDayOption: DayMealOption?
    @State private var newMealName = ""

    init(dayKey: String = DayKey.today) {
        self.dayKey = dayKey
        _model = State(initialValue: SavedMealsViewModel(dayKey: dayKey))
    }

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L("nutritionLibrary.meals.title"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreatingMeal = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text(L("nutritionLibrary.meals.newTitle")))
                }
            }
            .task { await model.load(context: modelContext) }
            .sheet(isPresented: $isCreatingMeal) {
                NavigationStack {
                    SavedMealEditorView(defaultSlot: .breakfast) {
                        Task { await model.load(context: modelContext) }
                    }
                }
            }
            .sheet(item: $editingMeal) { editing in
                NavigationStack {
                    SavedMealEditorView(mealID: editing.id) {
                        Task { await model.load(context: modelContext) }
                    }
                }
            }
            .alert(
                L("nutritionLibrary.meals.nameFromDayTitle"),
                isPresented: Binding(
                    get: { pendingDayOption != nil },
                    set: { if !$0 { pendingDayOption = nil } }
                ),
                actions: {
                    TextField(L("nutritionLibrary.meals.namePlaceholder"), text: $newMealName)
                    Button(L("common.cancel"), role: .cancel) { pendingDayOption = nil }
                    Button(L("common.save")) { saveFromDay() }
                },
                message: { Text(L("nutritionLibrary.meals.nameFromDayMessage")) }
            )
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
                    if let failure = model.actionFailure {
                        FailureBanner(explanation: failure) { model.clearFailure() }
                    }
                    if model.meals.isEmpty {
                        EmptyStateView(
                            systemImage: "square.stack.3d.up",
                            title: L("nutritionLibrary.meals.emptyTitle"),
                            message: L("nutritionLibrary.meals.emptyMessage")
                        ) {
                            Button(L("nutritionLibrary.meals.newTitle")) { isCreatingMeal = true }
                                .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
                                .frame(maxWidth: 280)
                        }
                    } else {
                        LazyVStack(spacing: Metrics.spacing12) {
                            ForEach(model.meals) { meal in
                                mealCard(meal)
                            }
                        }
                    }
                    if !model.dayOptions.isEmpty {
                        buildFromDayCard
                    }
                }
                .screenPadding()
                .padding(.vertical, Metrics.spacing16)
                .readableWidth()
            }
        }
    }

    // MARK: - Rows

    private func mealCard(_ meal: SavedMealSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                HStack(alignment: .top, spacing: Metrics.spacing8) {
                    VStack(alignment: .leading, spacing: Metrics.spacing4) {
                        Text(meal.name)
                            .font(.appCardTitle)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(meal.itemNames.joined(separator: ", "))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Metrics.spacing8)
                    if meal.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.appAccent)
                            .accessibilityHidden(true)
                    }
                }

                HStack(spacing: Metrics.spacing8) {
                    Chip(title: L(meal.slot.localizationKey), systemImage: meal.slot.symbolName, tint: .appNutrition)
                    Text(macroLine(meal.macros))
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if meal.unresolvedItemCount > 0 {
                    Text(L("nutritionLibrary.meals.unresolvedItems", meal.unresolvedItemCount))
                        .font(.caption)
                        .foregroundStyle(Color.appWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.lastLoggedMealID == meal.id {
                    Label(L("nutritionLibrary.meals.logged"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.appSuccess)
                }

                actionRow(meal)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L(
            "nutritionLibrary.meals.rowLabel",
            meal.name,
            L(meal.slot.localizationKey),
            macroLine(meal.macros)
        )))
    }

    private func actionRow(_ meal: SavedMealSummary) -> some View {
        HStack(spacing: Metrics.spacing8) {
            Menu {
                ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                    Button {
                        Task { await model.logMeal(id: meal.id, to: slot) }
                    } label: {
                        Label(L(slot.localizationKey), systemImage: slot.symbolName)
                    }
                }
            } label: {
                Label(L("nutritionLibrary.meals.log"), systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Metrics.minimumTapTarget)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                            .fill(Color.appNutrition)
                    )
            }
            .accessibilityLabel(Text(L("nutritionLibrary.meals.logAccessibility", meal.name)))

            Button {
                editingMeal = EditingSavedMeal(id: meal.id)
            } label: {
                Text(L("common.edit"))
            }
            .buttonStyle(SecondaryButtonStyle())
            .frame(maxWidth: 110)

            Menu {
                Button {
                    Task { await model.toggleFavorite(id: meal.id) }
                } label: {
                    Label(
                        L(meal.isFavorite ? "nutritionLibrary.meals.unfavorite" : "nutritionLibrary.meals.favorite"),
                        systemImage: meal.isFavorite ? "star.slash" : "star"
                    )
                }
                Button(role: .destructive) {
                    Task { await model.delete(id: meal.id) }
                } label: {
                    Label(L("common.delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Color.appTextSecondary)
                    .minimumTapTarget()
            }
            .accessibilityLabel(Text(L("nutritionLibrary.meals.moreAccessibility", meal.name)))
        }
    }

    /// Turns a meal already in the diary into a saved one. This is the path people actually use.
    private var buildFromDayCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(
                    title: L("nutritionLibrary.meals.fromDayTitle"),
                    subtitle: L("nutritionLibrary.meals.fromDayMessage")
                ) { EmptyView() }

                ForEach(model.dayOptions) { option in
                    Button {
                        newMealName = option.suggestedName
                        pendingDayOption = option
                    } label: {
                        HStack(spacing: Metrics.spacing12) {
                            Image(systemName: option.slot.symbolName)
                                .font(.footnote)
                                .foregroundStyle(Color.appNutrition)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L(option.slot.localizationKey))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.appTextPrimary)
                                Text(L(
                                    "nutritionLibrary.meals.fromDayDetail",
                                    option.entryCount,
                                    formatter.energy(option.macros.kilocalories)
                                ))
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: Metrics.spacing8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appTextTertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func macroLine(_ macros: MacroNutrients) -> String {
        L(
            "nutritionLibrary.common.macroLine",
            formatter.energy(macros.kilocalories),
            formatter.macro(macros.proteinG),
            formatter.macro(macros.carbsG),
            formatter.macro(macros.fatG)
        )
    }

    private func saveFromDay() {
        guard let option = pendingDayOption else { return }
        let name = newMealName
        pendingDayOption = nil
        Task {
            if await model.saveMealFromDay(option, named: name) {
                Haptics.success()
            } else {
                Haptics.error()
            }
        }
    }
}

#Preview("Saved meals") {
    PreviewHost(scenario: .fullNutritionDay) {
        NavigationStack {
            SavedMealsView()
        }
    }
}
