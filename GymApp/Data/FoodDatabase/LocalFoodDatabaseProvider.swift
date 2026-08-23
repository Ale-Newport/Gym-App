import Foundation

// MARK: - Text normalisation

/// Folds food text into a comparable form.
///
/// Deliberately a separate, tiny type rather than a reuse of `ExerciseNameTokenizer`: the two
/// datasets are owned by different layers and a change made for exercise search must not silently
/// re-rank food search. The rules are the same ones the exercise index uses — lowercase, strip
/// diacritics, collapse punctuation to spaces — so "creme fraiche" finds "Crème fraîche" and
/// "chicken, breast" finds "Chicken breast".
enum FoodTextNormalizer {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posixLocale)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }
}

// MARK: - On-disk shape

/// One record of `foods.json`.
///
/// Field names mirror the file exactly. `micros` decodes straight into `Micronutrients`, whose
/// properties are all optional, so a key the file omits stays `nil` — which is the whole point:
/// "not measured" and "contains none" must never collapse into the same number.
struct FoodCatalogRecord: Codable, Hashable, Sendable {
    struct Serving: Codable, Hashable, Sendable {
        let name: String
        let nameKey: String?
        let grams: Double
    }

    let catalogID: String
    let name: String
    /// Present only for the curated set of everyday foods that ship translated.
    let nameKey: String?
    /// `"g"` or `"ml"`.
    let basisUnit: String
    let kcal: Double
    let protein: Double
    let carbs: Double
    let fat: Double
    let micros: Micronutrients?
    let servings: [Serving]?
    let gramsPerPiece: Double?
    let dietaryTags: [String]
    let allergenTags: [String]
    let roleTags: [String]

    var servingUnit: ServingUnit { basisUnit == "ml" ? .milliliters : .grams }

    var foodServings: [FoodServing] {
        (servings ?? []).map { FoodServing(name: $0.name, nameKey: $0.nameKey, gramsPerServing: $0.grams) }
    }

    /// The name the user should see, translated when the record ships a key.
    @MainActor
    var localizedName: String {
        guard let nameKey else { return name }
        return LocalizationManager.shared.localized(nameKey)
    }

    func asSearchResult(providerID: String, attribution: String?) -> FoodSearchResult {
        FoodSearchResult(
            providerID: providerID,
            externalID: catalogID,
            name: name,
            brand: nil,
            barcode: nil,
            basisUnit: servingUnit,
            kilocaloriesPer100: kcal,
            proteinGPer100: protein,
            carbsGPer100: carbs,
            fatGPer100: fat,
            micronutrientsPer100: micros ?? .unknown,
            servings: foodServings,
            gramsPerPiece: gramsPerPiece,
            dietaryTags: dietaryTags,
            allergenTags: allergenTags,
            roleTags: roleTags,
            source: .builtIn,
            attribution: attribution
        )
    }
}

/// `food-database-manifest.json`. `version` is what the importer records in user defaults.
struct FoodCatalogManifest: Codable, Sendable {
    let schemaVersion: Int
    let version: String
    let foodCount: Int
    let source: String
    let notes: String
    let generatedFor: String
}

/// Errors raised while reading the bundled food database.
enum FoodCatalogError: LocalizedError, Hashable, Sendable {
    case manifestMissing
    case dataMissing
    case decodingFailed(String)
    case empty
    case schemaTooNew(found: Int, supported: Int)

    var errorDescription: String? {
        switch self {
        case .manifestMissing: "The food database manifest is missing from the app bundle."
        case .dataMissing: "The food database is missing from the app bundle."
        case .decodingFailed(let detail): "The food database could not be read: \(detail)"
        case .empty: "The food database contains no records."
        case .schemaTooNew(let found, let supported):
            "The food database uses schema \(found) but this build understands \(supported)."
        }
    }
}

// MARK: - Search index

/// A precomputed, diacritic- and case-insensitive index over the bundled foods.
///
/// Built once when the catalogue loads; querying is then a linear scan over pre-normalised strings
/// with no per-keystroke allocation, which is what keeps typing responsive across ~600 records.
/// The approach mirrors `ExerciseSearchIndex` on purpose, so search behaves the same way in both
/// halves of the app.
struct FoodSearchIndex: Sendable {

    /// One row of the index, fully pre-normalised.
    struct Entry: Sendable {
        let catalogID: String
        let normalizedName: String
        let nameTokens: [String]
        /// Role, dietary and allergen tags plus portion names, normalised (underscores folded to
        /// spaces). Portion names are indexed because "cod fillet" and "chicken breast" are how
        /// people describe food, even when the catalogue calls the portion a serving.
        let tagTerms: [String]
        /// Tie-breaker: how likely this food is to be the one the user meant.
        let prominence: Double
    }

    /// Where a query matched, best first. Determines result ordering.
    enum MatchKind: Int, Comparable, Sendable {
        case exactName = 0
        case namePrefix = 1
        case nameTokenPrefix = 2
        case nameSubstring = 3
        /// Matched only after singularising the word or following a synonym.
        case synonym = 4
        case tag = 5

        static func < (lhs: MatchKind, rhs: MatchKind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private let entries: [Entry]

    init(records: [FoodCatalogRecord]) {
        entries = records.map { record in
            let normalized = FoodTextNormalizer.normalize(record.name)
            var tags: [String] = []
            for tag in record.roleTags + record.dietaryTags + record.allergenTags {
                tags.append(FoodTextNormalizer.normalize(tag))
            }
            for serving in record.servings ?? [] {
                // "1 breast" indexes as "breast": the leading count would never be typed.
                for token in FoodTextNormalizer.tokens(serving.name) where token.count > 2 {
                    tags.append(token)
                }
            }
            return Entry(
                catalogID: record.catalogID,
                normalizedName: normalized,
                nameTokens: normalized.split(separator: " ").map(String.init),
                tagTerms: Array(Set(tags)),
                prominence: Self.prominence(of: record)
            )
        }
    }

    /// How strongly a record should win a tie.
    ///
    /// The curated `nameKey` set is the list of foods judged common enough to be worth
    /// translating, which makes it the best available proxy for "what people actually log", so it
    /// dominates. Named portions are a weaker signal of the same thing. Everything else is left to
    /// name length, which favours "Egg, whole, raw" over "Egg noodles, boiled" for the query "egg".
    private static func prominence(of record: FoodCatalogRecord) -> Double {
        var score = 0.0
        if record.nameKey != nil { score += 1.0 }
        if record.servings?.isEmpty == false { score += 0.2 }
        if record.roleTags.contains("budget") { score += 0.1 }
        return score
    }

    /// Returns matching catalogue ids, best match first.
    ///
    /// Every word of a multi-word query must match somewhere, which is what makes "greek yogurt 0"
    /// behave the way a user expects. The result's rank is the worst match kind across the words,
    /// with prominence and then name length breaking ties.
    func search(_ query: String, limit: Int = 40) -> [String] {
        let normalizedQuery = FoodTextNormalizer.normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let words = normalizedQuery.split(separator: " ").map(String.init)

        var scored: [(id: String, kind: MatchKind, prominence: Double, length: Int)] = []
        scored.reserveCapacity(64)

        for entry in entries {
            var worstKind = MatchKind.exactName
            var matchedAll = true

            // Whole-phrase matches are strongest and are checked before the per-word fallback.
            if entry.normalizedName == normalizedQuery {
                worstKind = .exactName
            } else if entry.normalizedName.hasPrefix(normalizedQuery) {
                worstKind = .namePrefix
            } else if words.count > 1 && entry.normalizedName.contains(normalizedQuery) {
                worstKind = .nameSubstring
            } else {
                for word in words {
                    guard let kind = match(word: word, in: entry) else {
                        matchedAll = false
                        break
                    }
                    if kind > worstKind { worstKind = kind }
                }
            }

            guard matchedAll else { continue }
            scored.append((entry.catalogID, worstKind, entry.prominence, entry.normalizedName.count))
        }

        scored.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            if lhs.prominence != rhs.prominence { return lhs.prominence > rhs.prominence }
            if lhs.length != rhs.length { return lhs.length < rhs.length }
            return lhs.id < rhs.id
        }
        // `prefix(_:)` traps on a negative length, and `limit` arrives from a caller rather than
        // from here — the remote provider already caps its own, so this one must too.
        return scored.prefix(max(0, limit)).map(\.id)
    }

    private func match(word: String, in entry: Entry) -> MatchKind? {
        if let kind = nameMatch(word, in: entry) { return kind }
        for candidate in Self.singularCandidates(word) {
            if let kind = nameMatch(candidate, in: entry) { return max(kind, .synonym) }
        }
        for alternative in Self.synonyms[word] ?? [] where nameMatch(alternative, in: entry) != nil {
            return .synonym
        }
        for tag in entry.tagTerms where tag.contains(word) { return .tag }
        return nil
    }

    private func nameMatch(_ word: String, in entry: Entry) -> MatchKind? {
        if entry.normalizedName == word { return .exactName }
        if entry.normalizedName.hasPrefix(word) { return .namePrefix }
        for token in entry.nameTokens where token.hasPrefix(word) { return .nameTokenPrefix }
        if entry.normalizedName.contains(word) { return .nameSubstring }
        return nil
    }

    /// Crude English singularisation, applied only as a fallback.
    ///
    /// A stemmer would be overkill: the catalogue is a fixed 600 English names, and the only
    /// failure this needs to fix is a user typing "eggs" or "tomatoes". Both candidates are tried
    /// because "-es" is ambiguous — "tomatoes" needs two characters dropped, "grapes" one.
    private static func singularCandidates(_ word: String) -> [String] {
        guard word.count > 3 else { return [] }
        if word.hasSuffix("ies") { return [String(word.dropLast(3)) + "y"] }
        if word.hasSuffix("es") { return [String(word.dropLast()), String(word.dropLast(2))] }
        if word.hasSuffix("s") { return [String(word.dropLast())] }
        return []
    }

    /// Words that mean the same food under a different name.
    ///
    /// Two groups, both drawn from real search misses rather than invented: cooking states, since
    /// the catalogue says "boiled" where a user types "cooked"; and British/American names, since
    /// the names follow USDA spelling in places and British usage in others, and nobody should
    /// have to guess which. Kept small deliberately — every entry here is a rule someone must
    /// maintain, and a broad synonym list makes search vaguer, not better.
    private static let synonyms: [String: [String]] = [
        "cooked": ["boiled", "grilled", "roasted", "baked", "steamed"],
        "boiled": ["cooked"],
        "grilled": ["cooked", "roasted"],
        "roasted": ["cooked", "baked", "grilled"],
        "baked": ["cooked", "roasted"],
        "fried": ["cooked"],
        "raw": ["fresh"],
        "fresh": ["raw"],
        "canned": ["tinned"],
        "tinned": ["canned"],
        "ground": ["mince"],
        "mince": ["ground"],
        "yoghurt": ["yogurt"],
        "yogurt": ["yoghurt"],
        "eggplant": ["aubergine"],
        "aubergine": ["eggplant"],
        "zucchini": ["courgette"],
        "courgette": ["zucchini"],
        "arugula": ["rocket"],
        "rocket": ["arugula"],
        "cilantro": ["coriander"],
        "coriander": ["cilantro"],
        "shrimp": ["prawn", "prawns"],
        "prawn": ["shrimp"],
        "garbanzo": ["chickpea", "chickpeas"],
        "rutabaga": ["swede"],
        "swede": ["rutabaga"],
        "capsicum": ["pepper"],
        "beet": ["beetroot"],
        "corn": ["sweetcorn"],
        "sweetcorn": ["corn"],
        "fries": ["chips"],
        "crisps": ["chips"],
        "chips": ["crisps", "fries"],
        "wholewheat": ["wholemeal", "wholegrain"],
        "wholemeal": ["wholewheat", "wholegrain"],
        "wholegrain": ["wholemeal", "wholewheat"],
        "pita": ["pitta"],
        "pitta": ["pita"],
        "cookie": ["biscuit"],
        "biscuit": ["cookie"],
        "soda": ["cola"],
        "porridge": ["oats"],
        "linseed": ["flaxseed"],
        "flaxseed": ["linseed"],
    ]
}

// MARK: - Catalogue

/// The decoded bundled catalogue plus its index. Immutable, so it is trivially `Sendable`.
struct FoodCatalog: Sendable {
    let manifest: FoodCatalogManifest
    let records: [FoodCatalogRecord]
    let index: FoodSearchIndex
    private let byID: [String: FoodCatalogRecord]

    init(manifest: FoodCatalogManifest, records: [FoodCatalogRecord]) {
        self.manifest = manifest
        self.records = records
        self.index = FoodSearchIndex(records: records)
        self.byID = Dictionary(records.map { ($0.catalogID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var count: Int { records.count }

    func record(id: String) -> FoodCatalogRecord? { byID[id] }

    func search(_ query: String, limit: Int) -> [FoodCatalogRecord] {
        index.search(query, limit: limit).compactMap { byID[$0] }
    }
}

/// Reads and validates `foods.json` and `food-database-manifest.json` from the app bundle.
///
/// Synchronous and free of actor isolation on purpose: both the search provider and the SwiftData
/// importer need the same decoded records, and each wants to run the decode on its own executor.
struct FoodCatalogLoader: Sendable {
    /// The schema revision this build understands. A file claiming a newer schema is rejected
    /// rather than half-read, because silently ignoring fields it does not know about is how a
    /// future database ends up importing foods with missing macros.
    static let supportedSchemaVersion = 1

    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Resources are added as a folder reference, so the subdirectory survives into the built
    /// product; the flat lookup is the fallback for test bundles that flatten resources.
    private func url(_ component: String) -> URL? {
        if let url = bundle.url(forResource: component, withExtension: nil, subdirectory: "FoodDatabase") {
            return url
        }
        return bundle.url(forResource: component, withExtension: nil)
    }

    func loadManifest() throws -> FoodCatalogManifest {
        guard let url = url("food-database-manifest.json"), let data = try? Data(contentsOf: url) else {
            throw FoodCatalogError.manifestMissing
        }
        let manifest: FoodCatalogManifest
        do {
            manifest = try JSONDecoder().decode(FoodCatalogManifest.self, from: data)
        } catch {
            throw FoodCatalogError.decodingFailed(String(describing: error))
        }
        guard manifest.schemaVersion <= Self.supportedSchemaVersion else {
            throw FoodCatalogError.schemaTooNew(
                found: manifest.schemaVersion,
                supported: Self.supportedSchemaVersion
            )
        }
        return manifest
    }

    func loadRecords() throws -> [FoodCatalogRecord] {
        guard let url = url("foods.json"), let data = try? Data(contentsOf: url) else {
            throw FoodCatalogError.dataMissing
        }
        let decoded: [FoodCatalogRecord]
        do {
            decoded = try JSONDecoder().decode([FoodCatalogRecord].self, from: data)
        } catch {
            throw FoodCatalogError.decodingFailed(String(describing: error))
        }

        // A single defective record is dropped and logged rather than failing the whole load, so
        // one bad row in a future database revision cannot leave the user without a food log.
        var seen = Set<String>()
        var records: [FoodCatalogRecord] = []
        records.reserveCapacity(decoded.count)
        for record in decoded {
            guard !record.catalogID.isEmpty, !record.name.isEmpty else {
                AppLog.nutrition.error("Food database: skipping a record with an empty id or name")
                continue
            }
            guard seen.insert(record.catalogID).inserted else {
                AppLog.nutrition.error("Food database: skipping duplicate id \(record.catalogID, privacy: .public)")
                continue
            }
            guard record.kcal >= 0, record.protein >= 0, record.carbs >= 0, record.fat >= 0 else {
                AppLog.nutrition.error("Food database: skipping \(record.catalogID, privacy: .public) with negative values")
                continue
            }
            records.append(record)
        }
        guard !records.isEmpty else { throw FoodCatalogError.empty }
        return records
    }

    /// Loads manifest and records together and builds the search index.
    func load() throws -> FoodCatalog {
        let manifest = try loadManifest()
        let records = try loadRecords()
        if records.count != manifest.foodCount {
            AppLog.nutrition.error(
                "Food database count mismatch: manifest says \(manifest.foodCount) but \(records.count) loaded"
            )
        }
        return FoodCatalog(manifest: manifest, records: records)
    }
}

// MARK: - Provider

/// The bundled food database, exposed as a provider.
///
/// **This is the provider that makes the app work offline.** It loads `foods.json` once, lazily,
/// off the main actor, and answers from memory afterwards. Nothing here touches the network or the
/// store, so a food search is correct and instant on a plane, in a basement gym, or on a device
/// that has never been online.
actor LocalFoodDatabaseProvider: FoodDataProvider {

    /// Load progresses `idle → loading → loaded`, and falls back to `idle` on failure so a
    /// transient problem (a resource not yet unpacked, say) can be retried by the next caller.
    private enum LoadState {
        case idle
        case loading(Task<FoodCatalog, any Error>)
        case loaded(FoodCatalog)
    }

    let identifier: String
    nonisolated var isRemote: Bool { false }

    private let loader: FoodCatalogLoader
    private var state: LoadState = .idle

    init(loader: FoodCatalogLoader = FoodCatalogLoader(), identifier: String = "local") {
        self.loader = loader
        self.identifier = identifier
    }

    // MARK: Loading

    /// Warms the catalogue. Call it during launch so the first search never pays for the decode.
    /// Failures are logged rather than thrown: a warm-up that fails must not break launch.
    func preload() async {
        do {
            _ = try await catalog()
        } catch {
            AppLog.nutrition.error("Food database preload failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The decoded catalogue, loading it on first use. Concurrent callers share one decode.
    private func catalog() async throws -> FoodCatalog {
        switch state {
        case .loaded(let catalog):
            return catalog
        case .loading(let task):
            return try await task.value
        case .idle:
            let loader = self.loader
            // Detached so the decode runs on the cooperative pool at its own priority and does not
            // inherit — or block — whatever actor asked for it.
            let task = Task.detached(priority: .userInitiated) { try loader.load() }
            state = .loading(task)
            do {
                let catalog = try await task.value
                state = .loaded(catalog)
                AppLog.nutrition.info(
                    "Food database loaded: \(catalog.count) foods, version \(catalog.manifest.version, privacy: .public)"
                )
                return catalog
            } catch {
                state = .idle
                throw error
            }
        }
    }

    /// Version string of the loaded database, for the settings screen and the importer.
    func databaseVersion() async throws -> String {
        try await catalog().manifest.version
    }

    func manifest() async throws -> FoodCatalogManifest {
        try await catalog().manifest
    }

    /// Every record, for the importer and for browse-by-category screens.
    func allRecords() async throws -> [FoodCatalogRecord] {
        try await catalog().records
    }

    var attribution: String { "USDA FoodData Central (public domain)" }

    // MARK: FoodDataProvider

    func search(_ query: String, limit: Int) async throws -> [FoodSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        do {
            let catalog = try await catalog()
            return catalog.search(trimmed, limit: limit)
                .map { $0.asSearchResult(providerID: identifier, attribution: attribution) }
        } catch let error as FoodCatalogError {
            throw FoodProviderError.decoding(error.errorDescription ?? String(describing: error))
        }
    }

    /// The bundled database describes generic foods, not packaged products, so it holds no
    /// barcodes. Returning `nil` rather than throwing lets the composite provider fall straight
    /// through to a remote lookup.
    func food(withBarcode barcode: String) async throws -> FoodSearchResult? {
        nil
    }

    func food(withIdentifier identifier: String) async throws -> FoodSearchResult? {
        do {
            let catalog = try await catalog()
            return catalog.record(id: identifier)?
                .asSearchResult(providerID: self.identifier, attribution: attribution)
        } catch let error as FoodCatalogError {
            throw FoodProviderError.decoding(error.errorDescription ?? String(describing: error))
        }
    }

    // MARK: Curated slices

    /// Every food carrying `roleTag`, ordered by prominence then name — the input the meal
    /// recommender uses when it needs "a lean protein" or "a quick breakfast carb".
    func records(withRoleTag roleTag: String, limit: Int = 100) async throws -> [FoodCatalogRecord] {
        let catalog = try await catalog()
        return catalog.records
            .filter { $0.roleTags.contains(roleTag) }
            .sorted { lhs, rhs in
                let lhsCurated = lhs.nameKey != nil, rhsCurated = rhs.nameKey != nil
                if lhsCurated != rhsCurated { return lhsCurated }
                return lhs.name < rhs.name
            }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
