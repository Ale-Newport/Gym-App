import SwiftUI
import SwiftData

/// The Nutrition tab: one day's food log, with everything needed to add to it.
///
/// The screen is organised around a single day and the four meal slots, because that is how people
/// actually think about eating. Day navigation sits in the header rather than behind a date picker
/// so "what did I eat yesterday?" — the question that drives the copy-yesterday shortcuts — is one
/// tap away. Everything heavier (targets, micronutrients, saved meals, recipes, suggestions) lives
/// behind the toolbar menu so the daily path stays uncluttered.
struct NutritionHubView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(\.displayFormatter) private var formatter

    @Query private var settings: [UserSettings]

    @State private var model: NutritionDayViewModel?
    @State private var addingToSlot: MealSlot?
    @State private var editingEntry: FoodLogEntry?
    @State private var detailEntry: FoodLogEntry?
    @State private var savingMealFromSlot: MealSlot?
    @State private var savedMealName = ""
    @State private var isPresentingCopyDay = false

    private var isNutritionEnabled: Bool { settings.first?.nutritionEnabled ?? true }

    var body: some View {
        Group {
            if !isNutritionEnabled {
                disabledState
            } else if let model {
                content(model)
            } else {
                LoadingStateView(message: L("nutritionLog.loading"))
            }
        }
        .background(Color.appBackground)
        .navigationTitle(L("tab.nutrition"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            let created = NutritionDayViewModel(context: modelContext, environment: environment)
            created.load()
            model = created
        }
        // A deep link from a widget, an App Intent or the Home card names the slot to open.
        .onChange(of: router.pendingMealSlot) { _, slot in
            guard let slot, isNutritionEnabled else { return }
            model?.goToToday()
            addingToSlot = slot
            router.pendingMealSlot = nil
        }
        .onChange(of: router.isPresentingWaterEntry) { _, isPresenting in
            guard isPresenting else { return }
            model?.goToToday()
            model?.addWater(milliliters: 250)
            router.isPresentingWaterEntry = false
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ model: NutritionDayViewModel) -> some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("nutritionLog.loading"))
        case .failed(let message):
            ErrorStateView(message: message, retryTitle: L("common.retry")) { model.load() }
                .readableWidth()
        case .content:
            dayScroll(model)
        }
    }

    private func dayScroll(_ model: NutritionDayViewModel) -> some View {
        ScrollView {
            VStack(spacing: Metrics.spacing16) {
                dayNavigator(model)
                MacroRingsHeader(progress: model.progress)

                if !model.hasTarget {
                    noTargetPrompt
                }

                if model.isWaterTrackingEnabled {
                    WaterTrackerView(
                        consumedMl: model.progress.waterMilliliters,
                        targetMl: model.waterTargetMl,
                        onAdd: { model.addWater(milliliters: $0) },
                        onUndo: { model.removeLastWater() }
                    )
                }

                ForEach(MealSlot.allCases.sorted { $0.sortIndex < $1.sortIndex }) { slot in
                    MealSectionView(
                        slot: slot,
                        model: model,
                        onAddFood: { addingToSlot = $0 },
                        onEditEntry: { editingEntry = $0 },
                        onShowDetails: { detailEntry = $0 },
                        onSaveAsMeal: { slot in
                            savedMealName = L(slot.localizationKey)
                            savingMealFromSlot = slot
                        }
                    )
                }

                if model.isEmptyDay {
                    emptyDayShortcuts(model)
                }

                suggestionsLink(model)
            }
            .screenPadding()
            .padding(.top, Metrics.spacing8)
            .padding(.bottom, Metrics.spacing40)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { model.load() }
        .toolbar { toolbarMenu(model) }
        .sheet(item: $addingToSlot) { slot in
            AddFoodFlowView(slot: slot, dayKey: model.dayKey)
                .onDisappear { model.load() }
        }
        .sheet(item: $editingEntry) { entry in
            portionEditor(for: entry, model: model)
        }
        .sheet(item: $detailEntry) { entry in
            entryDetail(for: entry, model: model)
        }
        .sheet(isPresented: $isPresentingCopyDay) {
            CopyDaySheet(model: model)
        }
        .alert(L("nutritionLog.saveMeal.title"), isPresented: savingMealBinding) {
            TextField(L("nutritionLog.saveMeal.namePlaceholder"), text: $savedMealName)
            Button(L("common.cancel"), role: .cancel) { savingMealFromSlot = nil }
            Button(L("common.save")) {
                if let slot = savingMealFromSlot {
                    model.saveAsMeal(named: savedMealName, slot: slot)
                }
                savingMealFromSlot = nil
            }
        } message: {
            Text(L("nutritionLog.saveMeal.message"))
        }
        .overlay(alignment: .bottom) { noticeBanner(model) }
    }

    // MARK: - Day navigation

    private func dayNavigator(_ model: NutritionDayViewModel) -> some View {
        HStack(spacing: Metrics.spacing12) {
            Button {
                model.goToPreviousDay()
                Haptics.selectionChanged()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .minimumTapTarget()
            }
            .accessibilityLabel(Text(L("nutritionLog.day.previous")))

            VStack(spacing: 2) {
                Text(formatter.relativeDay(model.date))
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                if !model.isToday {
                    Button(L("nutritionLog.day.jumpToToday")) { model.goToToday() }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appNutrition)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                model.goToNextDay()
                Haptics.selectionChanged()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .minimumTapTarget()
            }
            .disabled(!model.canGoForward)
            .accessibilityLabel(Text(L("nutritionLog.day.next")))
        }
        .foregroundStyle(Color.appTextPrimary)
    }

    // MARK: - Prompts

    private var noTargetPrompt: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Text(L("nutritionLog.noTarget.title"))
                    .font(.appCardTitle)
                    .foregroundStyle(Color.appTextPrimary)
                Text(L("nutritionLog.noTarget.message"))
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink { NutritionTargetsView() } label: {
                    Text(L("nutritionLog.noTarget.action"))
                }
                .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
            }
        }
    }

    /// The fastest routes into an empty day: yesterday's food, a saved meal, or a whole day copied.
    private func emptyDayShortcuts(_ model: NutritionDayViewModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Text(L("nutritionLog.empty.title"))
                    .font(.appCardTitle)
                    .foregroundStyle(Color.appTextPrimary)
                Text(L("nutritionLog.empty.message"))
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.entryCount(on: DayKey.offset(from: model.dayKey, days: -1)) > 0 {
                    Button {
                        model.copyDay(from: DayKey.offset(from: model.dayKey, days: -1))
                    } label: {
                        Label(L("nutritionLog.empty.copyYesterday"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Button {
                    isPresentingCopyDay = true
                } label: {
                    Label(L("nutritionLog.empty.copyAnotherDay"), systemImage: "calendar")
                }
                .buttonStyle(SecondaryButtonStyle())

                NavigationLink { SavedMealsView(dayKey: model.dayKey).onDisappear { model.load() } } label: {
                    Label(L("nutritionLog.empty.savedMeals"), systemImage: "square.stack.3d.up")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Metrics.minimumTapTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.appNutrition)
            }
        }
    }

    private func suggestionsLink(_ model: NutritionDayViewModel) -> some View {
        NavigationLink {
            MealRecommendationsView(slot: model.slotForNow, dayKey: model.dayKey)
        } label: {
            Card {
                HStack(spacing: Metrics.spacing12) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(Color.appNutrition)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("nutritionLog.suggestions.title"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                        Text(remainingSummary(model))
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Metrics.spacing8)
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func remainingSummary(_ model: NutritionDayViewModel) -> String {
        guard model.hasTarget else { return L("nutritionLog.suggestions.noTarget") }
        let remaining = model.progress.remaining
        return L(
            "nutritionLog.suggestions.remaining",
            formatter.energy(max(0, remaining.kilocalories)),
            formatter.macro(max(0, remaining.proteinG))
        )
    }

    // MARK: - Sheets

    @ViewBuilder
    private func portionEditor(for entry: FoodLogEntry, model: NutritionDayViewModel) -> some View {
        NavigationStack {
            PortionEditorView(
                basis: basis(for: entry, model: model),
                initial: PortionValue(
                    quantity: entry.quantity, unit: entry.unit, servingIndex: entry.servingIndex
                ),
                slot: entry.mealSlot,
                actionTitle: L("common.save")
            ) { portion, slot in
                model.updatePortion(of: entry, to: portion)
                if slot != entry.mealSlot { model.move(entry, to: slot) }
                editingEntry = nil
            }
            .navigationTitle(entry.foodNameSnapshot)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func entryDetail(for entry: FoodLogEntry, model: NutritionDayViewModel) -> some View {
        let food = model.food(for: entry)
        NavigationStack {
            FoodDetailView(
                basis: basis(for: entry, model: model),
                source: food?.source ?? .custom,
                barcode: food?.barcode,
                isFavorite: model.isFavorite(entry),
                onToggleFavorite: { model.toggleFavorite(entry) },
                defaultSlot: entry.mealSlot,
                initialPortion: PortionValue(
                    quantity: entry.quantity, unit: entry.unit, servingIndex: entry.servingIndex
                ),
                onLog: { portion, slot in
                    model.updatePortion(of: entry, to: portion)
                    if slot != entry.mealSlot { model.move(entry, to: slot) }
                    detailEntry = nil
                }
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.close")) { detailEntry = nil }
                }
            }
        }
    }

    /// The food's own values when it still exists, and the entry's frozen snapshot when it does not.
    /// A deleted food must never take its history with it.
    private func basis(for entry: FoodLogEntry, model: NutritionDayViewModel) -> PortionBasis {
        if let food = model.food(for: entry) { return .from(food) }
        return .fromSnapshot(of: entry)
    }

    private var savingMealBinding: Binding<Bool> {
        Binding(
            get: { savingMealFromSlot != nil },
            set: { if !$0 { savingMealFromSlot = nil } }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func toolbarMenu(_ model: NutritionDayViewModel) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                NavigationLink { NutritionTargetsView() } label: {
                    Label(L("nutritionLog.menu.targets"), systemImage: "target")
                }
                NavigationLink { MicronutrientDetailView(dayKey: model.dayKey) } label: {
                    Label(L("nutritionLog.menu.micronutrients"), systemImage: "chart.bar.doc.horizontal")
                }
                NavigationLink { SavedMealsView(dayKey: model.dayKey).onDisappear { model.load() } } label: {
                    Label(L("nutritionLog.menu.savedMeals"), systemImage: "square.stack.3d.up")
                }
                NavigationLink { RecipeListView(dayKey: model.dayKey).onDisappear { model.load() } } label: {
                    Label(L("nutritionLog.menu.recipes"), systemImage: "list.bullet.rectangle")
                }
                Divider()
                Button {
                    isPresentingCopyDay = true
                } label: {
                    Label(L("nutritionLog.menu.copyDay"), systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .minimumTapTarget()
            }
            .accessibilityLabel(Text(L("common.more")))
        }
    }

    // MARK: - Notices

    @ViewBuilder
    private func noticeBanner(_ model: NutritionDayViewModel) -> some View {
        if let message = model.actionError ?? model.notice {
            let isError = model.actionError != nil
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.appOnAccent)
                .padding(.horizontal, Metrics.spacing16)
                .padding(.vertical, Metrics.spacing12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (isError ? Color.appDanger : Color.appNutrition),
                    in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                )
                .padding(Metrics.screenPadding)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    // Auto-dismiss: these are confirmations, not decisions the user has to make.
                    Task {
                        try? await Task.sleep(for: .seconds(isError ? 4 : 2.5))
                        model.notice = nil
                        model.actionError = nil
                    }
                }
                .accessibilityAddTraits(.isStaticText)
        }
    }

    // MARK: - Disabled

    private var disabledState: some View {
        EmptyStateView(
            systemImage: "fork.knife",
            title: L("nutritionLog.disabled.title"),
            message: L("nutritionLog.disabled.message")
        ) {
            NavigationLink { NutritionSettingsView() } label: {
                Text(L("nutritionLog.disabled.action"))
            }
            .buttonStyle(PrimaryButtonStyle(tint: .appNutrition))
            .frame(maxWidth: 280)
        }
        .readableWidth()
    }
}

/// Picks a past day to copy an entire log from.
private struct CopyDaySheet: View {
    let model: NutritionDayViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayFormatter) private var formatter

    /// The fortnight behind the day being viewed. Anything older is easier to re-log than to find.
    private var candidates: [(dayKey: String, count: Int)] {
        (1...14)
            .map { DayKey.offset(from: model.dayKey, days: -$0) }
            .map { ($0, model.entryCount(on: $0)) }
            .filter { $0.1 > 0 }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    EmptyStateView(
                        systemImage: "calendar.badge.exclamationmark",
                        title: L("nutritionLog.copyDay.emptyTitle"),
                        message: L("nutritionLog.copyDay.emptyMessage")
                    )
                } else {
                    List(candidates, id: \.dayKey) { candidate in
                        Button {
                            model.copyDay(from: candidate.dayKey)
                            dismiss()
                        } label: {
                            HStack {
                                Text(formatter.relativeDay(
                                    DayKey.date(from: candidate.dayKey) ?? Date()
                                ))
                                .foregroundStyle(Color.appTextPrimary)
                                Spacer()
                                Text(LPlural("nutritionLog.copyDay.itemCount", candidate.count))
                                    .font(.footnote)
                                    .foregroundStyle(Color.appTextSecondary)
                            }
                            .frame(minHeight: Metrics.minimumTapTarget)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L("nutritionLog.copyDay.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview("Full day") {
    PreviewHost(scenario: .fullNutritionDay) {
        NavigationStack { NutritionHubView() }
    }
}

#Preview("Empty day") {
    PreviewHost(scenario: .emptyNutritionDay) {
        NavigationStack { NutritionHubView() }
    }
}
