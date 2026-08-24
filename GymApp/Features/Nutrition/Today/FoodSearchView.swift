import SwiftData
import SwiftUI

// MARK: - Providers

/// The food providers, created once for the whole process.
///
/// `LocalFoodDatabaseProvider` decodes and indexes the bundled catalogue on first use and holds it;
/// creating one per screen would repeat that work on every search sheet. They live here rather than
/// on `AppEnvironment` only because this feature does not own that file — a shared instance on the
/// composition root would be the better home.
@MainActor
enum NutritionProviders {
    static let local = LocalFoodDatabaseProvider()
    static let remote = OpenFoodFactsProvider()

    /// Local only: instant, offline, and the default for every keystroke.
    static let offline = CompositeFoodDataProvider(providers: [local])
    /// Local plus Open Food Facts, used only when the user explicitly asks to look further.
    static let online = CompositeFoodDataProvider(providers: [local, remote])
}

// MARK: - View model

/// Search across the user's own foods, the bundled database and — on request — Open Food Facts.
///
/// The remote provider is never consulted automatically. A food search has to answer while somebody
/// is standing in a kitchen holding a packet, and the bundled catalogue answers in microseconds
/// with no network at all; going online is therefore an explicit, labelled choice, and when it
/// fails the local results simply stay on screen with a quiet note rather than an error dialog.
@MainActor
@Observable
final class FoodSearchViewModel {

    enum RemoteState: Equatable {
        case notRequested
        case searching
        case completed(Int)
        case failed(String)
    }

    var query: String = ""
    private(set) var isSearching = false
    private(set) var storedResults: [FoodItem] = []
    private(set) var catalogResults: [FoodSearchResult] = []
    private(set) var remoteResults: [FoodSearchResult] = []
    private(set) var remoteState: RemoteState = .notRequested
    private(set) var failureMessage: String?

    private let repository: NutritionRepository

    init(context: ModelContext) {
        self.repository = NutritionRepository(context: context)
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasQuery: Bool { trimmedQuery.count >= 2 }
    var hasAnyResult: Bool { !storedResults.isEmpty || !catalogResults.isEmpty || !remoteResults.isEmpty }

    /// Runs the offline search. Called from a `.task(id:)`, so a new keystroke cancels the previous
    /// pass before it touches the store.
    func search() async {
        let term = trimmedQuery
        remoteResults = []
        remoteState = .notRequested
        failureMessage = nil

        guard term.count >= 2 else {
            storedResults = []
            catalogResults = []
            isSearching = false
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            storedResults = try repository.searchFoods(term, limit: 40)
        } catch {
            storedResults = []
            failureMessage = NutritionDayViewModel.message(for: error)
        }

        let (results, _) = await NutritionProviders.offline.search(term, limit: 40)
        guard !Task.isCancelled else { return }
        // A catalogue record the user already has as a stored row would otherwise appear twice.
        let knownCatalogIDs = Set(storedResults.compactMap(\.catalogID))
        catalogResults = results.filter { !knownCatalogIDs.contains($0.externalID) }
    }

    /// Explicit online search. Failures degrade to the local results already on screen.
    func searchOnline() async {
        let term = trimmedQuery
        guard term.count >= 2 else { return }
        remoteState = .searching

        let (results, failures) = await NutritionProviders.online.search(term, limit: 40)
        guard !Task.isCancelled else { return }

        let knownCatalogIDs = Set(storedResults.compactMap(\.catalogID))
        let knownBarcodes = Set(storedResults.compactMap(\.barcode))
        let fresh = results.filter { result in
            result.providerID != NutritionProviders.local.identifier
                && !knownCatalogIDs.contains(result.externalID)
                && !(result.barcode.map(knownBarcodes.contains) ?? false)
        }
        remoteResults = fresh

        if let failure = failures.values.first, fresh.isEmpty {
            remoteState = .failed(L(failure.localizationKey))
            AppLog.nutrition.info("Remote food search degraded to local results: \(failure.localizationKey, privacy: .public)")
        } else {
            remoteState = .completed(fresh.count)
        }
    }
}

// MARK: - View

/// The search tab of the add-food flow.
struct FoodSearchView: View {
    let onSelect: (FoodSelection) -> Void
    let onShowDetails: (FoodSelection) -> Void

    @State private var model: FoodSearchViewModel?
    @Environment(\.modelContext) private var context
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                content(model)
            } else {
                LoadingStateView(message: L("common.loading"))
            }
        }
        .task {
            if model == nil { model = FoodSearchViewModel(context: context) }
        }
    }

    @ViewBuilder
    private func content(_ model: FoodSearchViewModel) -> some View {
        @Bindable var model = model

        VStack(spacing: Metrics.spacing12) {
            searchField(model)

            if model.isSearching && !model.hasAnyResult {
                LoadingStateView(message: L("nutritionLog.search.searching"))
            } else if !model.hasQuery {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: L("nutritionLog.search.promptTitle"),
                    message: L("nutritionLog.search.promptMessage")
                )
            } else if let failure = model.failureMessage, !model.hasAnyResult {
                ErrorStateView(message: failure, retryTitle: L("common.retry")) {
                    Task { await model.search() }
                }
            } else if !model.hasAnyResult {
                EmptyStateView(
                    systemImage: "questionmark.circle",
                    title: L("food.error.notFound"),
                    message: L("nutritionLog.search.noResultsMessage")
                ) {
                    onlineButton(model)
                }
            } else {
                results(model)
            }
        }
        .task(id: model.query) {
            // Debounce: a search per keystroke would re-run the store query four times a word for
            // no benefit the user can perceive.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await model.search()
        }
    }

    private func searchField(_ model: FoodSearchViewModel) -> some View {
        @Bindable var model = model

        return HStack(spacing: Metrics.spacing8) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(Color.appTextTertiary)
                .accessibilityHidden(true)
            TextField(L("nutritionLog.search.placeholder"), text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFieldFocused)
                .accessibilityLabel(L("nutritionLog.search.placeholder"))
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.appTextTertiary)
                        .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("common.clear"))
            }
        }
        .padding(.leading, Metrics.spacing12)
        .frame(minHeight: Metrics.minimumTapTarget)
        .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        .screenPadding()
    }

    private func results(_ model: FoodSearchViewModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing16, pinnedViews: []) {
                if !model.storedResults.isEmpty {
                    resultGroup(title: L("nutritionLog.search.yourFoods")) {
                        ForEach(model.storedResults, id: \.id) { food in
                            FoodPickerRow(
                                title: food.name,
                                subtitle: food.brand,
                                macrosPer100: food.macrosPer100,
                                basisUnit: food.basisUnit,
                                isFavorite: food.isFavorite,
                                onTap: { onSelect(.stored(food.id)) },
                                onShowDetails: { onShowDetails(.stored(food.id)) }
                            )
                        }
                    }
                }

                if !model.catalogResults.isEmpty {
                    resultGroup(title: L("food.provider.local")) {
                        ForEach(model.catalogResults) { result in
                            FoodPickerRow(
                                title: result.name,
                                subtitle: result.brand,
                                macrosPer100: result.macrosPer100,
                                basisUnit: result.basisUnit,
                                onTap: { onSelect(.result(result)) },
                                onShowDetails: { onShowDetails(.result(result)) }
                            )
                        }
                    }
                }

                if !model.remoteResults.isEmpty {
                    resultGroup(title: L("food.provider.openFoodFacts")) {
                        ForEach(model.remoteResults) { result in
                            FoodPickerRow(
                                title: result.name,
                                subtitle: result.brand,
                                macrosPer100: result.macrosPer100,
                                basisUnit: result.basisUnit,
                                badge: result.hasInconsistentEnergy() ? L("nutritionLog.search.checkLabel") : nil,
                                onTap: { onSelect(.result(result)) },
                                onShowDetails: { onShowDetails(.result(result)) }
                            )
                        }
                    }
                }

                onlineFooter(model)
            }
            .screenPadding()
            .padding(.bottom, Metrics.spacing32)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func resultGroup<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text(title)
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
                .accessibilityAddTraits(.isHeader)
            Card(padding: Metrics.spacing8) {
                VStack(spacing: 0) { content() }
            }
        }
    }

    @ViewBuilder
    private func onlineFooter(_ model: FoodSearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            switch model.remoteState {
            case .notRequested:
                onlineButton(model)
            case .searching:
                HStack(spacing: Metrics.spacing8) {
                    ProgressView()
                    Text(L("nutritionLog.search.searchingOnline"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(minHeight: Metrics.minimumTapTarget)
            case .completed(let count):
                if count == 0 {
                    Text(L("nutritionLog.search.onlineNoResults"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("food.provider.openFoodFacts.attribution"))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                // Degrading silently means the local results stay: this is a note, not an error
                // state, and it always leaves the retry available.
                ExplanationNote(text: message, systemImage: "wifi.slash", tint: .appWarning)
                onlineButton(model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func onlineButton(_ model: FoodSearchViewModel) -> some View {
        Button {
            Task { await model.searchOnline() }
        } label: {
            Label(L("nutritionLog.search.online"), systemImage: "globe")
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(!model.hasQuery)
        .accessibilityHint(L("nutritionLog.search.onlineHint"))
    }
}

// MARK: - Row

/// One selectable food, wherever it came from. Tapping the body picks it; the trailing button opens
/// its full nutrition, so a user can check a product before committing to logging it.
struct FoodPickerRow: View {
    let title: String
    var subtitle: String?
    let macrosPer100: MacroNutrients
    var basisUnit: ServingUnit = .grams
    var isFavorite: Bool = false
    /// Short warning shown beside the name, e.g. when a product's label does not add up.
    var badge: String?
    let onTap: () -> Void
    var onShowDetails: (() -> Void)?

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        HStack(spacing: Metrics.spacing8) {
            Button(action: onTap) {
                HStack(alignment: .top, spacing: Metrics.spacing12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Metrics.spacing4) {
                            Text(title)
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
                        Text(perBasisText)
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if let badge {
                            Label(badge, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(Color.appWarning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "plus.circle")
                        .font(.body)
                        .foregroundStyle(Color.appNutrition)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, Metrics.spacing8)
                .padding(.horizontal, Metrics.spacing8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(L("nutritionLog.a11y.pickHint"))

            if let onShowDetails {
                Button(action: onShowDetails) {
                    Image(systemName: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("nutritionLog.a11y.foodDetails", title))
            }
        }
    }

    private var perBasisText: String {
        var parts: [String] = []
        if let subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        parts.append(basisUnit == .milliliters ? L("food.result.per100ml") : L("food.result.per100g"))
        parts.append(formatter.energy(macrosPer100.kilocalories))
        parts.append(L(
            "nutritionLog.search.macroSummary",
            formatter.macro(macrosPer100.proteinG),
            formatter.macro(macrosPer100.carbsG),
            formatter.macro(macrosPer100.fatG)
        ))
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        [title, perBasisText, isFavorite ? L("exercise.favorite") : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

#Preview("Food search") {
    PreviewHost(scenario: .emptyNutritionDay) {
        NavigationStack {
            FoodSearchView(onSelect: { _ in }, onShowDetails: { _ in })
                .background(Color.appBackground)
                .navigationTitle(L("nutritionLog.tab.search"))
        }
    }
}
