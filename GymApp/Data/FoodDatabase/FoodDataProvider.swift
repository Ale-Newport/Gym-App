import Foundation

// MARK: - Result

/// One food exactly as a provider returns it, before anything is written to the store.
///
/// Providers return values, never model objects. That is what lets the search screen merge a
/// bundled record, a remote hit and a barcode lookup into one list without knowing or caring which
/// of them will ever be persisted — only a food the user actually logs is turned into a
/// `FoodItem`. Everything is normalised to the app's canonical basis of 100 g (or 100 ml), so a
/// caller never has to ask which unit a particular provider happened to use.
struct FoodSearchResult: Hashable, Sendable, Identifiable {
    /// Identifier of the provider that produced this result, e.g. `"local"`.
    var providerID: String
    /// The provider's own stable id: a catalogue slug locally, a barcode remotely.
    var externalID: String
    var name: String
    var brand: String?
    var barcode: String?
    /// Whether the per-100 values are per 100 g or per 100 ml.
    var basisUnit: ServingUnit

    var kilocaloriesPer100: Double
    var proteinGPer100: Double
    var carbsGPer100: Double
    var fatGPer100: Double
    /// Unknown nutrients stay `nil`; see `Micronutrients` for why that distinction is load-bearing.
    var micronutrientsPer100: Micronutrients

    var servings: [FoodServing]
    var gramsPerPiece: Double?

    var dietaryTags: [String]
    var allergenTags: [String]
    var roleTags: [String]

    var source: FoodSource
    /// Provenance shown on the food detail screen. Required by Open Food Facts' licence.
    var attribution: String?

    init(
        providerID: String,
        externalID: String,
        name: String,
        brand: String? = nil,
        barcode: String? = nil,
        basisUnit: ServingUnit = .grams,
        kilocaloriesPer100: Double,
        proteinGPer100: Double,
        carbsGPer100: Double,
        fatGPer100: Double,
        micronutrientsPer100: Micronutrients = .unknown,
        servings: [FoodServing] = [],
        gramsPerPiece: Double? = nil,
        dietaryTags: [String] = [],
        allergenTags: [String] = [],
        roleTags: [String] = [],
        source: FoodSource,
        attribution: String? = nil
    ) {
        self.providerID = providerID
        self.externalID = externalID
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.basisUnit = basisUnit
        self.kilocaloriesPer100 = kilocaloriesPer100
        self.proteinGPer100 = proteinGPer100
        self.carbsGPer100 = carbsGPer100
        self.fatGPer100 = fatGPer100
        self.micronutrientsPer100 = micronutrientsPer100
        self.servings = servings
        self.gramsPerPiece = gramsPerPiece
        self.dietaryTags = dietaryTags
        self.allergenTags = allergenTags
        self.roleTags = roleTags
        self.source = source
        self.attribution = attribution
    }

    /// Stable across providers, so two providers returning the same barcode do not collide.
    var id: String { "\(providerID)#\(externalID)" }

    var macrosPer100: MacroNutrients {
        MacroNutrients(
            kilocalories: kilocaloriesPer100,
            proteinG: proteinGPer100,
            carbsG: carbsGPer100,
            fatG: fatGPer100
        )
    }

    /// Energy implied by the macros. Remote data is frequently self-inconsistent, so the UI can
    /// use this to decide whether to show a "these numbers may be wrong" hint.
    var derivedKilocaloriesPer100: Double { macrosPer100.derivedKilocalories }

    /// True when the stated energy and the macros disagree by more than `tolerance`.
    ///
    /// The default of 25% is deliberately looser than the 12% the bundled database is held to:
    /// crowd-sourced label data legitimately drifts (rounded label values, polyols, fibre counted
    /// differently), and flagging a quarter of Open Food Facts would train the user to ignore the
    /// warning.
    func hasInconsistentEnergy(tolerance: Double = 0.25) -> Bool {
        guard kilocaloriesPer100 > 0 else { return false }
        let derived = derivedKilocaloriesPer100
        guard derived > 0 else { return false }
        return abs(derived - kilocaloriesPer100) / kilocaloriesPer100 > tolerance
    }

    /// True when this food is excluded by `diet`. Matching is on `FoodItem.dietaryTags`, which is
    /// exactly the vocabulary `DietType.excludedTags` uses.
    func isExcluded(by diet: DietType) -> Bool {
        let excluded = diet.excludedTags
        guard !excluded.isEmpty else { return false }
        return dietaryTags.contains { excluded.contains($0) }
    }

    /// True when any of the user's declared allergens appears in `allergenTags`.
    func containsAllergen(from allergens: Set<String>) -> Bool {
        guard !allergens.isEmpty else { return false }
        return allergenTags.contains { allergens.contains($0) }
    }
}

// MARK: - Tag vocabularies

/// The closed tag vocabularies the whole food layer agrees on.
///
/// They are declared once, here, because three different things depend on them staying in step:
/// the bundled JSON, the Open Food Facts mapper and the dietary filters. `dietary` is exactly the
/// set `DietType.excludedTags` can produce — anything else would silently fail to filter.
enum FoodTagVocabulary {
    static let dietary: Set<String> = ["meat", "poultry", "fish", "seafood", "dairy", "egg", "honey"]
    static let allergen: Set<String> = ["gluten", "nuts", "peanut", "soy", "shellfish", "sesame"]
    static let role: Set<String> = [
        "protein_source", "carb_source", "fat_source", "vegetable", "fruit",
        "breakfast", "lunch", "dinner", "snack", "quick", "lean", "high_fiber",
        "drink", "supplement", "budget",
    ]

    /// Drops anything outside the vocabulary and de-duplicates, preserving order.
    /// Remote data is untrusted input: a stray tag would leak into dietary filtering.
    static func sanitise(_ tags: [String], against vocabulary: Set<String>) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let lowered = tag.lowercased()
            guard vocabulary.contains(lowered), seen.insert(lowered).inserted else { continue }
            result.append(lowered)
        }
        return result
    }
}

/// Derives the role tags the meal recommender reads, from macros alone.
///
/// The bundled database ships these tags precomputed; remote records have to have them derived on
/// arrival, and both must agree or the recommender would treat an imported tuna tin differently
/// from the bundled one. The thresholds are the regulatory nutrition-claim definitions rather than
/// invented numbers: EU Regulation 1924/2006 calls a food a protein source when protein supplies
/// at least 20% of its energy (raised to 25% here, since a "protein source" in a training app
/// should mean something stronger than yogurt-coated cereal), "high fibre" at 6 g per 100 g, and
/// USDA labelling calls a meat "lean" below 10 g fat and 4.5 g saturated fat per 100 g.
enum FoodRoleTagDeriver {
    static func roleTags(
        kilocaloriesPer100: Double,
        proteinGPer100: Double,
        carbsGPer100: Double,
        fatGPer100: Double,
        micronutrientsPer100: Micronutrients,
        basisUnit: ServingUnit
    ) -> [String] {
        var tags: [String] = []
        if kilocaloriesPer100 > 0 {
            if proteinGPer100 >= 10, proteinGPer100 * 4 / kilocaloriesPer100 >= 0.25 {
                tags.append("protein_source")
            }
            if carbsGPer100 >= 20, carbsGPer100 * 4 / kilocaloriesPer100 >= 0.45 {
                tags.append("carb_source")
            }
            if fatGPer100 >= 15, fatGPer100 * 9 / kilocaloriesPer100 >= 0.50 {
                tags.append("fat_source")
            }
        }
        if let fibre = micronutrientsPer100.fiberG, fibre >= 6 {
            tags.append("high_fiber")
        }
        if tags.contains("protein_source"),
           fatGPer100 <= 10,
           (micronutrientsPer100.saturatedFatG ?? 0) <= 4.5 {
            tags.append("lean")
        }
        if basisUnit == .milliliters {
            tags.append("drink")
        }
        return tags
    }
}

// MARK: - Errors

/// Every way a food lookup can fail, from any provider.
///
/// The cases are deliberately coarse. The caller's only real decision is "show something else
/// instead", so a taxonomy finer than this would be detail the UI cannot act on. `errorDescription`
/// is a diagnostic string for logs; user-facing text goes through `localizationKey`.
enum FoodProviderError: LocalizedError, Hashable, Sendable {
    case notFound
    case network(String)
    case decoding(String)
    case rateLimited
    case offline
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notFound: "No matching food was found."
        case .network(let detail): "The food service could not be reached: \(detail)"
        case .decoding(let detail): "The food service returned data that could not be read: \(detail)"
        case .rateLimited: "Too many requests were made to the food service."
        case .offline: "There is no internet connection."
        case .cancelled: "The lookup was cancelled."
        }
    }

    /// Localisation key for the message shown to the user.
    var localizationKey: String {
        switch self {
        case .notFound: "food.error.notFound"
        case .network: "food.error.network"
        case .decoding: "food.error.decoding"
        case .rateLimited: "food.error.rateLimited"
        case .offline: "food.error.offline"
        case .cancelled: "food.error.cancelled"
        }
    }

    /// Whether retrying the same request could plausibly succeed. `.notFound` and `.decoding`
    /// are properties of the data, so retrying them only wastes the user's battery.
    var isRetryable: Bool {
        switch self {
        case .network, .rateLimited, .offline: true
        case .notFound, .decoding, .cancelled: false
        }
    }

    /// Maps a `URLSession` failure onto the right case, so callers never inspect `URLError` codes.
    static func from(urlError: URLError) -> FoodProviderError {
        switch urlError.code {
        case .cancelled: .cancelled
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: .offline
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .secureConnectionFailed: .network(urlError.code.rawValue.description)
        default: .network(urlError.code.rawValue.description)
        }
    }
}

// MARK: - Provider

/// A source of food records.
///
/// The app is built so that every provider is optional except the bundled one: search runs local
/// first, then folds in whatever remote results arrive, and any remote failure is swallowed into a
/// non-fatal `FoodProviderError`. That is what makes the food log work on a plane.
protocol FoodDataProvider: Sendable {
    /// Stable, non-localised identifier, used to key results and to record provenance.
    var identifier: String { get }
    /// `true` when answering requires the network. Callers use it to order and to degrade.
    var isRemote: Bool { get }

    /// Ranked matches for a free-text query. Returns an empty array rather than throwing when the
    /// query simply matches nothing.
    func search(_ query: String, limit: Int) async throws -> [FoodSearchResult]

    /// A single product by EAN/UPC barcode, or `nil` when the provider has no record of it.
    func food(withBarcode barcode: String) async throws -> FoodSearchResult?

    /// A single record by this provider's own identifier.
    func food(withIdentifier identifier: String) async throws -> FoodSearchResult?
}

extension FoodDataProvider {
    /// Search with the app's default page size.
    func search(_ query: String) async throws -> [FoodSearchResult] {
        try await search(query, limit: 40)
    }
}

// MARK: - Aggregation

/// Runs several providers and merges their results, local first.
///
/// Ordering is intentional rather than by relevance score: the bundled catalogue is clean,
/// de-duplicated data the user can trust, so it leads. Remote hits follow, de-duplicated against
/// the local ones by barcode and by normalised name, and any provider that fails is dropped with a
/// logged reason instead of taking the whole search down with it.
struct CompositeFoodDataProvider: Sendable {
    let providers: [any FoodDataProvider]

    init(providers: [any FoodDataProvider]) {
        self.providers = providers
    }

    /// Searches every provider concurrently and returns the merged, de-duplicated list.
    ///
    /// `remoteTimeout` bounds how long the local results wait for the remote ones. Beyond it the
    /// remote task is cancelled and whatever is already in hand is returned, because a food search
    /// that stalls is worse than one that is merely incomplete.
    func search(
        _ query: String,
        limit: Int = 40,
        remoteTimeout: Duration = .seconds(6)
    ) async -> (results: [FoodSearchResult], failures: [String: FoodProviderError]) {
        let localProviders = providers.filter { !$0.isRemote }
        let remoteProviders = providers.filter(\.isRemote)

        var merged: [FoodSearchResult] = []
        var failures: [String: FoodProviderError] = [:]

        for provider in localProviders {
            do {
                merged.append(contentsOf: try await provider.search(query, limit: limit))
            } catch {
                failures[provider.identifier] = Self.mapped(error)
            }
        }

        guard !remoteProviders.isEmpty else {
            return (Self.deduplicated(merged, limit: limit), failures)
        }

        let remote = await withTaskGroup(
            of: (String, Result<[FoodSearchResult], FoodProviderError>).self
        ) { group -> [(String, Result<[FoodSearchResult], FoodProviderError>)] in
            for provider in remoteProviders {
                group.addTask {
                    do {
                        let hits = try await Self.withTimeout(remoteTimeout) {
                            try await provider.search(query, limit: limit)
                        }
                        return (provider.identifier, .success(hits))
                    } catch {
                        return (provider.identifier, .failure(Self.mapped(error)))
                    }
                }
            }
            var collected: [(String, Result<[FoodSearchResult], FoodProviderError>)] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        // Reassemble in the declared provider order so results do not reshuffle between searches.
        for provider in remoteProviders {
            guard let outcome = remote.first(where: { $0.0 == provider.identifier })?.1 else { continue }
            switch outcome {
            case .success(let hits): merged.append(contentsOf: hits)
            case .failure(let error): failures[provider.identifier] = error
            }
        }

        return (Self.deduplicated(merged, limit: limit), failures)
    }

    /// Looks a barcode up provider by provider and returns the first hit. Local first, so a
    /// bundled record always wins over a crowd-sourced one for the same product.
    func food(withBarcode barcode: String) async -> (result: FoodSearchResult?, failures: [String: FoodProviderError]) {
        var failures: [String: FoodProviderError] = [:]
        for provider in providers.sorted(by: { !$0.isRemote && $1.isRemote }) {
            do {
                if let hit = try await provider.food(withBarcode: barcode) { return (hit, failures) }
            } catch {
                failures[provider.identifier] = Self.mapped(error)
            }
        }
        return (nil, failures)
    }

    /// Races `operation` against a sleep, so one unresponsive provider cannot hold the merged
    /// result set hostage. The loser is cancelled rather than left running.
    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw FoodProviderError.network("timeout")
            }
            guard let first = try await group.next() else {
                throw FoodProviderError.network("timeout")
            }
            group.cancelAll()
            return first
        }
    }

    private static func mapped(_ error: any Error) -> FoodProviderError {
        if let providerError = error as? FoodProviderError { return providerError }
        if let urlError = error as? URLError { return .from(urlError: urlError) }
        if error is CancellationError { return .cancelled }
        return .network(String(describing: error))
    }

    /// Drops later duplicates. Two results are the same food when they share a barcode, or when
    /// their names fold to the same string and their energy agrees to within 5 kcal.
    private static func deduplicated(_ results: [FoodSearchResult], limit: Int) -> [FoodSearchResult] {
        var seenBarcodes = Set<String>()
        var seenNames: [(name: String, kcal: Double)] = []
        var output: [FoodSearchResult] = []
        output.reserveCapacity(min(results.count, limit))

        for result in results {
            if let barcode = result.barcode, !barcode.isEmpty {
                guard seenBarcodes.insert(barcode).inserted else { continue }
            }
            let folded = FoodTextNormalizer.normalize(result.name + " " + (result.brand ?? ""))
            let isDuplicate = seenNames.contains {
                $0.name == folded && abs($0.kcal - result.kilocaloriesPer100) < 5
            }
            guard !isDuplicate else { continue }
            seenNames.append((folded, result.kilocaloriesPer100))
            output.append(result)
            if output.count >= limit { break }
        }
        return output
    }
}
