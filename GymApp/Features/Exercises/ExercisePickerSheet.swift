import SwiftUI
import SwiftData

/// The reusable "choose an exercise" sheet.
///
/// Every screen that needs an exercise — the program editor, the substitution flow, adding a
/// movement mid-session — presents this one, so picking an exercise feels the same everywhere and
/// the search behaviour only has to be right once.
///
/// A picker is opened with something specific in mind, so it is deliberately flatter than the
/// library: one ranked list, one tap to choose, and it dismisses itself. There is no navigation out
/// of it, because a picker that lets the user wander off is a picker they have to start again.
struct ExercisePickerSheet: View {
    let title: String
    let onSelect: (Exercise) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @Query private var preferences: [ExercisePreference]

    @State private var viewModel = ExerciseLibraryViewModel(mode: .picker)
    @State private var isPresentingFilters = false

    init(title: String, onSelect: @escaping (Exercise) -> Void) {
        self.title = title
        self.onSelect = onSelect
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        NavigationStack {
            content
                .background(Color.appBackground)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $viewModel.searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(L("exercises.searchPrompt", viewModel.catalogCount))
                )
                .toolbar { toolbarContent }
                .sheet(isPresented: $isPresentingFilters) {
                    ExerciseFilterSheet(filters: $viewModel.filters, viewModel: viewModel)
                }
        }
        .presentationDragIndicator(.visible)
        .task { viewModel.load(catalog: environment.catalog, preferences: preferences) }
        .onChange(of: preferenceRevision) {
            viewModel.load(catalog: environment.catalog, preferences: preferences)
        }
        .onChange(of: viewModel.inputSignature) { viewModel.refresh() }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            LoadingStateView(message: L("exercises.loading"))
        case .failed(let message):
            ErrorStateView(message: message, retryTitle: L("common.retry")) {
                Task { await viewModel.retry(preferences: preferences) }
            }
            .readableWidth()
        case .ready:
            if viewModel.hasNoResults {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: L("exercises.empty.title"),
                    message: L("exercises.empty.message")
                ) {
                    Button(L("exercises.empty.action")) { viewModel.clearSearchAndFilters() }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 260)
                }
                .readableWidth()
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.sections) { section in
                    ForEach(section.items) { item in
                        Button {
                            onSelect(item.exercise)
                            Haptics.tap()
                            dismiss()
                        } label: {
                            ExerciseLibraryRow(
                                item: item,
                                thumbnailURL: environment.mediaProvider.thumbnailURL(for: item.exercise)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text(L("exercises.picker.hint")))
                    }
                }

                VStack(spacing: Metrics.spacing8) {
                    Text(LPlural("exercises.resultCount", viewModel.resultCount))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextTertiary)
                    MediaAttributionLabel(
                        attribution: environment.mediaProvider.attribution,
                        url: environment.mediaProvider.attributionURL
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.spacing24)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(L("common.cancel")) { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker(L("exercises.sort.label"), selection: Binding(
                    get: { viewModel.sort },
                    set: { viewModel.sort = $0 }
                )) {
                    ForEach(ExerciseSortOrder.allCases) { order in
                        Label(L(order.localizationKey), systemImage: order.symbolName).tag(order)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down").minimumTapTarget()
            }
            .accessibilityLabel(Text(L("exercises.sort.label")))
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPresentingFilters = true
            } label: {
                HStack(spacing: Metrics.spacing4) {
                    Image(systemName: viewModel.filters.isActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                    if viewModel.filters.isActive {
                        Text(String(viewModel.filters.activeCount))
                            .font(.footnote.weight(.semibold).monospacedDigit())
                    }
                }
                .minimumTapTarget()
            }
            .accessibilityLabel(Text(L("exercises.filters.label")))
        }
    }

    /// Same trick as the library: the query returns the same objects when a field changes, so the
    /// fields the list depends on are folded into one comparable value.
    private var preferenceRevision: Int {
        var hasher = Hasher()
        hasher.combine(preferences.count)
        for preference in preferences {
            hasher.combine(preference.exerciseID)
            hasher.combine(preference.isFavorite)
            hasher.combine(preference.timesPerformed)
            hasher.combine(preference.lastPerformedAt)
        }
        return hasher.finalize()
    }
}

#Preview("Picker") {
    PreviewHost(scenario: .seasonedUser) {
        PickerPreviewHost()
    }
}

/// Presents the sheet the way a caller would, so the preview covers the dismissal path too.
private struct PickerPreviewHost: View {
    @State private var isPresenting = true
    @State private var chosen: String?

    var body: some View {
        VStack(spacing: Metrics.spacing16) {
            Text(chosen ?? L("exercises.picker.noneChosen"))
                .font(.headline)
            Button(L("common.select")) { isPresenting = true }
                .buttonStyle(SecondaryButtonStyle())
                .frame(maxWidth: 240)
        }
        .padding(Metrics.screenPadding)
        .sheet(isPresented: $isPresenting) {
            ExercisePickerSheet(title: L("exercises.picker.title")) { exercise in
                chosen = exercise.name.localizedCapitalized
            }
        }
    }
}
