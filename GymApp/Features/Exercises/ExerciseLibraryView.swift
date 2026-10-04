import SwiftUI
import SwiftData

/// The Exercises tab: the whole catalogue, searchable, filterable and browsable.
///
/// Two things drive the layout. First, the list is long — over thirteen hundred rows — so it is a
/// `LazyVStack` of value-type rows with thumbnails only, and an A–Z index bar so the far end of the
/// alphabet is one gesture away rather than forty flicks. Second, the list is a *reference*: when
/// nothing is being searched it opens on what the user actually trains (recently performed, then
/// favourites) before falling through to the full alphabetical catalogue.
struct ExerciseLibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The preference table is small, one row per exercise the user has an opinion about, and a
    /// live query is exactly the right tool for it: favouriting on the detail screen updates the
    /// list underneath with no refresh plumbing.
    @Query private var preferences: [ExercisePreference]

    @State private var viewModel = ExerciseLibraryViewModel(mode: .browse)
    @State private var isPresentingFilters = false

    var body: some View {
        @Bindable var viewModel = viewModel

        content
            .background(Color.appBackground)
            .navigationTitle(L("exercises.title"))
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text(L("exercises.searchPrompt", viewModel.catalogCount))
            )
            .toolbar { toolbarContent }
            .navigationDestination(for: ExerciseRoute.self) { route in
                switch route {
                case .detail(let exerciseID):
                    ExerciseDetailView(exerciseID: exerciseID)
                case .history(let exerciseID):
                    ExerciseHistoryView(exerciseID: exerciseID)
                }
            }
            .sheet(isPresented: $isPresentingFilters) {
                ExerciseFilterSheet(filters: $viewModel.filters, viewModel: viewModel)
            }
            .task { viewModel.load(catalog: environment.catalog, preferences: preferences) }
            // The query hands back the same row objects when a field changes, so the array itself
            // compares equal. The revision folds the fields the list actually depends on into one
            // value, which is what makes a favourite toggled two screens away land here.
            .onChange(of: preferenceRevision) {
                viewModel.load(catalog: environment.catalog, preferences: preferences)
            }
            .onChange(of: environment.catalog.state) {
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
                emptyState
            } else {
                listContent
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "magnifyingglass",
            title: L("exercises.empty.title"),
            message: L("exercises.empty.message")
        ) {
            Button(L("exercises.empty.action")) {
                viewModel.clearSearchAndFilters()
            }
            .buttonStyle(SecondaryButtonStyle())
            .frame(maxWidth: 260)
        }
        .readableWidth()
    }

    private var listContent: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(viewModel.sections) { section in
                            Section {
                                ForEach(section.items) { item in
                                    row(for: item)
                                }
                            } header: {
                                sectionHeader(section)
                                    .id(section.id)
                            }
                        }
                        footer
                    }
                    .padding(.horizontal, Metrics.screenPadding)
                    .padding(.trailing, showsIndexBar ? Metrics.spacing20 : 0)
                    .readableWidth()
                }
                .scrollDismissesKeyboard(.immediately)

                if showsIndexBar {
                    SectionIndexBar(titles: viewModel.indexTitles) { title in
                        guard let section = viewModel.sections.first(where: { $0.indexTitle == title }) else { return }
                        // Never animated. Animating the jump makes the lazy stack realise and
                        // measure every row it sweeps past — up to 1,300 of them, each starting a
                        // thumbnail load — and a finger dragging down the index crosses most of
                        // the alphabet in under a second. The unanimated jump realises only the
                        // destination, which is what the Reduce Motion path always did.
                        proxy.scrollTo(section.id, anchor: .top)
                    }
                }
            }
        }
    }

    private var showsIndexBar: Bool { viewModel.indexTitles.count > 1 }

    // MARK: - Pieces

    private func row(for item: ExerciseRowItem) -> some View {
        // `item.id` is section-scoped so the list can show the same exercise in several sections;
        // the route needs the exercise itself.
        NavigationLink(value: ExerciseRoute.detail(item.exerciseID)) {
            ExerciseLibraryRow(
                item: item,
                thumbnailURL: environment.mediaProvider.thumbnailURL(for: item.exercise)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(L("exercises.row.hint")))
    }

    private func sectionHeader(_ section: ExerciseListSection) -> some View {
        HStack(spacing: Metrics.spacing8) {
            Text(section.titleKey.map(L) ?? section.literalTitle ?? "")
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            Text(String(section.items.count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.appTextTertiary)
        }
        .padding(.vertical, Metrics.spacing8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appBackground)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var footer: some View {
        VStack(spacing: Metrics.spacing8) {
            Text(LPlural("exercises.resultCount", viewModel.resultCount))
                .font(.footnote)
                .foregroundStyle(Color.appTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            // Thumbnails are the rights holder's artwork, so the credit travels with the list.
            MediaAttributionLabel(
                attribution: environment.mediaProvider.attribution,
                url: environment.mediaProvider.attributionURL
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Metrics.spacing20)
        .padding(.bottom, Metrics.spacing32)
        .multilineTextAlignment(.center)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
                Image(systemName: "arrow.up.arrow.down")
                    .minimumTapTarget()
            }
            .accessibilityLabel(Text(L("exercises.sort.label")))
            .accessibilityValue(Text(L(viewModel.sort.localizationKey)))
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
            .accessibilityValue(Text(viewModel.filters.isActive
                ? LPlural("exercises.filters.activeCount", viewModel.filters.activeCount)
                : L("common.none")))
        }
    }

    /// Folds the preference fields the list depends on into a single comparable value.
    private var preferenceRevision: Int {
        var hasher = Hasher()
        hasher.combine(preferences.count)
        for preference in preferences {
            hasher.combine(preference.exerciseID)
            hasher.combine(preference.isFavorite)
            hasher.combine(preference.isExcluded)
            hasher.combine(preference.timesPerformed)
            hasher.combine(preference.lastPerformedAt)
        }
        return hasher.finalize()
    }
}

// MARK: - Row

/// One library row. Formats its own metadata so the view model stays free of finished strings.
struct ExerciseLibraryRow: View {
    let item: ExerciseRowItem
    let thumbnailURL: URL?

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        VStack(spacing: 0) {
            ExerciseRowView(
                exercise: item.exercise,
                thumbnailURL: thumbnailURL,
                detail: detail,
                isFavorite: item.isFavorite,
                isExcluded: item.isExcluded,
                trailingSystemImage: "chevron.right"
            )
            .padding(.vertical, Metrics.spacing8)
            .frame(minHeight: Metrics.gymTapTarget)

            Divider().overlay(Color.appSeparator.opacity(0.5))
        }
        .contentShape(Rectangle())
    }

    private var detail: String? {
        if let lastPerformedAt = item.lastPerformedAt {
            return L("exercises.row.lastPerformed", formatter.relativeDay(lastPerformedAt))
        }
        if item.timesPerformed > 0 {
            return LPlural("exercises.row.timesPerformed", item.timesPerformed)
        }
        return nil
    }
}

// MARK: - Index bar

/// The A–Z index down the trailing edge.
///
/// Twenty-seven separate 44-point targets cannot fit on a phone, so the bar is a single control the
/// finger slides along — which is how the system index behaves too. For VoiceOver it is therefore
/// one adjustable element rather than a row of buttons, and the hit area is widened to 44 points
/// without widening the glyphs.
private struct SectionIndexBar: View {
    let titles: [String]
    let onSelect: (String) -> Void

    @State private var activeIndex = 0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ForEach(titles, id: \.self) { title in
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in select(at: value.location.y, height: geometry.size.height) }
            )
        }
        .frame(width: Metrics.minimumTapTarget)
        .padding(.vertical, Metrics.spacing12)
        // Capped, not fixed. Twenty-seven letters share the full height of the list inside a 44pt
        // column; left to scale freely each glyph wants ~30pt at accessibility sizes and they
        // render on top of one another. The range form only ever caps — a user on a small text
        // size still gets their own size — and the bar stays available to VoiceOver, which the
        // people most likely to be running large text are also most likely to be using.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityElement()
        .accessibilityLabel(Text(L("exercises.index.label")))
        .accessibilityValue(Text(titles.indices.contains(activeIndex) ? titles[activeIndex] : ""))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(by: 1)
            case .decrement: move(by: -1)
            @unknown default: break
            }
        }
    }

    private func select(at y: CGFloat, height: CGFloat) {
        guard !titles.isEmpty, height > 0 else { return }
        let step = height / CGFloat(titles.count)
        let index = min(max(Int(y / step), 0), titles.count - 1)
        guard index != activeIndex else { return }
        activeIndex = index
        Haptics.selectionChanged()
        onSelect(titles[index])
    }

    private func move(by delta: Int) {
        let index = min(max(activeIndex + delta, 0), titles.count - 1)
        guard index != activeIndex else { return }
        activeIndex = index
        onSelect(titles[index])
    }
}

#Preview("Library") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            ExerciseLibraryView()
        }
    }
}
