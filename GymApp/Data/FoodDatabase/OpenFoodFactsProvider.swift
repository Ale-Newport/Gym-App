import Foundation

// MARK: - Flexible JSON number

/// A JSON value that Open Food Facts may return as a number **or** as a string.
///
/// Their nutriment values are contributor-entered and pass through several import pipelines, so
/// `"proteins_100g": 12.5` and `"proteins_100g": "12.5"` both occur in live data — as do `"12,5"`
/// (comma decimal separator), `""` and `"traces"`. Decoding into `Double` directly would throw and
/// lose the entire product over one bad field, so every numeric read goes through this type.
struct LooseNumber: Decodable, Hashable, Sendable {
    let value: Double?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            value = double.isFinite ? double : nil
            return
        }
        if let int = try? container.decode(Int.self) {
            value = Double(int)
            return
        }
        if let string = try? container.decode(String.self) {
            let cleaned = string
                .replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespaces)
            value = Double(cleaned)
            return
        }
        // Explicit null, an object, an array — all mean "no usable number here".
        value = nil
    }
}

// MARK: - Wire types

/// The subset of an Open Food Facts product this app reads.
private struct OFFProduct: Decodable, Sendable {
    let code: String?
    let productName: String?
    let productNameEN: String?
    let genericName: String?
    let brands: String?
    let quantity: String?
    let servingSize: String?
    let servingQuantity: LooseNumber?
    let nutritionDataPer: String?
    let nutriments: [String: LooseNumber]?
    let categoriesTags: [String]?
    let allergensTags: [String]?
    let ingredientsAnalysisTags: [String]?

    enum CodingKeys: String, CodingKey {
        case code
        case productName = "product_name"
        case productNameEN = "product_name_en"
        case genericName = "generic_name"
        case brands
        case quantity
        case servingSize = "serving_size"
        case servingQuantity = "serving_quantity"
        case nutritionDataPer = "nutrition_data_per"
        case nutriments
        case categoriesTags = "categories_tags"
        case allergensTags = "allergens_tags"
        case ingredientsAnalysisTags = "ingredients_analysis_tags"
    }
}

/// `/api/v2/product/<barcode>.json`. `status` is an integer in v2 but has been a string in the
/// past, so it is read loosely and the real test is whether a product body came back at all.
private struct OFFProductResponse: Decodable, Sendable {
    let status: LooseNumber?
    let product: OFFProduct?
}

/// `/cgi/search.pl?...&json=1`.
private struct OFFSearchResponse: Decodable, Sendable {
    let count: Int?
    let products: [OFFProduct]?
}

// MARK: - Provider

/// Open Food Facts, the crowd-sourced packaged-food database.
///
/// Three things shape this implementation:
///
/// 1. **No API keys, ever.** Open Food Facts' read API is open. Nothing here ships a secret,
///    which is also why the whole provider can be deleted without touching the rest of the app.
/// 2. **Their terms require an identifying `User-Agent`.** Requests carry the app name, version
///    and a contact URL. Sending a generic agent is grounds for being blocked.
/// 3. **Every failure is non-fatal.** Anything that goes wrong becomes a `FoodProviderError`, and
///    the caller falls back to the bundled catalogue. Remote search is an enhancement, never a
///    dependency.
///
/// The provider is an `actor` because its cache and rate-limit windows are shared mutable state
/// touched from whatever task happens to be typing in the search field.
actor OpenFoodFactsProvider: FoodDataProvider {

    // MARK: Configuration

    /// Tunables, gathered so a change is one edit and one place to read.
    struct Configuration: Sendable {
        var host: String = "world.openfoodfacts.org"
        /// Open Food Facts asks that clients identify themselves; see their API terms.
        var appName: String = "Forge"
        var contactURL: String = "https://openfoodfacts.org"
        /// 8 s: long enough for a slow mobile connection, short enough that a barcode scan that
        /// is going nowhere returns to the local fallback before the user gives up.
        var timeout: TimeInterval = 8
        /// Their published limits: 100 product reads and 10 searches per minute per client.
        var productRequestsPerMinute: Int = 100
        var searchRequestsPerMinute: Int = 10
        var productCacheLifetime: TimeInterval = 30 * 60
        var searchCacheLifetime: TimeInterval = 10 * 60
        /// A barcode nobody has heard of is worth remembering briefly, so re-scanning the same
        /// packet does not fire the same doomed request again.
        var missCacheLifetime: TimeInterval = 5 * 60
        var maximumCacheEntries: Int = 200

        init() {}
    }

    let identifier: String
    nonisolated var isRemote: Bool { true }

    private let configuration: Configuration
    private let session: URLSession
    private let clock: @Sendable () -> Date
    private let userAgent: String

    /// Cached responses keyed by the request that produced them.
    private enum CacheKey: Hashable {
        case barcode(String)
        case search(String, Int)
    }

    private struct CacheEntry {
        let results: [FoodSearchResult]
        let expiresAt: Date
    }

    private var cache: [CacheKey: CacheEntry] = [:]
    /// Insertion order, so eviction can drop the oldest without sorting the dictionary.
    private var cacheOrder: [CacheKey] = []
    /// Rolling one-minute windows of request timestamps, one per endpoint class.
    private var productRequestTimes: [Date] = []
    private var searchRequestTimes: [Date] = []

    /// - Parameters:
    ///   - clock: injected so rate limiting and cache expiry are testable and deterministic;
    ///     nothing in this type reads the wall clock directly.
    init(
        configuration: Configuration = Configuration(),
        session: URLSession? = nil,
        identifier: String = "openFoodFacts",
        appVersion: String? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.identifier = identifier
        self.clock = clock

        let version = appVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "1.0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        self.userAgent = "\(configuration.appName)/\(version) (iOS \(os.majorVersion).\(os.minorVersion); +\(configuration.contactURL))"

        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
            sessionConfiguration.timeoutIntervalForResource = configuration.timeout * 2
            sessionConfiguration.waitsForConnectivity = false
            sessionConfiguration.httpAdditionalHeaders = [
                "User-Agent": self.userAgent,
                "Accept": "application/json",
            ]
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    /// Required attribution: Open Food Facts data is published under the Open Database Licence.
    nonisolated var attribution: String { "Open Food Facts — ODbL" }

    // MARK: FoodDataProvider

    func search(_ query: String, limit: Int) async throws -> [FoodSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let cappedLimit = max(1, min(limit, 50))

        let key = CacheKey.search(trimmed.lowercased(), cappedLimit)
        if let cached = cachedResults(for: key) { return cached }

        try checkCancellation()
        try reserveSlot(forSearch: true)

        var components = URLComponents()
        components.scheme = "https"
        components.host = configuration.host
        components.path = "/cgi/search.pl"
        components.queryItems = [
            URLQueryItem(name: "search_terms", value: trimmed),
            URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "action", value: "process"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "page_size", value: String(cappedLimit)),
            URLQueryItem(name: "fields", value: Self.requestedFields),
        ]
        guard let url = components.url else { throw FoodProviderError.network("invalid search URL") }

        let data = try await fetch(url)
        let decoded: OFFSearchResponse
        do {
            decoded = try JSONDecoder().decode(OFFSearchResponse.self, from: data)
        } catch {
            throw FoodProviderError.decoding(String(describing: error))
        }

        let results = (decoded.products ?? []).compactMap { mapped($0, requestedBarcode: nil) }
        store(results, for: key, lifetime: configuration.searchCacheLifetime)
        return results
    }

    func food(withBarcode barcode: String) async throws -> FoodSearchResult? {
        guard let normalised = Self.normalisedBarcode(barcode) else { return nil }

        if let hit = try await product(barcode: normalised) { return hit }

        // A UPC-A scan is a 12-digit code; Open Food Facts stores those as EAN-13 with a leading
        // zero. Retrying once with the zero costs one request and rescues most US products.
        if normalised.count == 12, let padded = Self.normalisedBarcode("0" + normalised) {
            return try await product(barcode: padded)
        }
        return nil
    }

    func food(withIdentifier identifier: String) async throws -> FoodSearchResult? {
        // Open Food Facts identifies every product by its barcode, so the two lookups coincide.
        try await food(withBarcode: identifier)
    }

    // MARK: Product lookup

    private func product(barcode: String) async throws -> FoodSearchResult? {
        let key = CacheKey.barcode(barcode)
        if let cached = cachedResults(for: key) { return cached.first }

        try checkCancellation()
        try reserveSlot(forSearch: false)

        var components = URLComponents()
        components.scheme = "https"
        components.host = configuration.host
        components.path = "/api/v2/product/\(barcode).json"
        components.queryItems = [URLQueryItem(name: "fields", value: Self.requestedFields)]
        guard let url = components.url else { throw FoodProviderError.network("invalid product URL") }

        let data: Data
        do {
            data = try await fetch(url)
        } catch FoodProviderError.notFound {
            // A 404 is a legitimate answer, not an error: this product is simply unknown.
            store([], for: key, lifetime: configuration.missCacheLifetime)
            return nil
        }

        let decoded: OFFProductResponse
        do {
            decoded = try JSONDecoder().decode(OFFProductResponse.self, from: data)
        } catch {
            throw FoodProviderError.decoding(String(describing: error))
        }

        guard let product = decoded.product, let result = mapped(product, requestedBarcode: barcode) else {
            store([], for: key, lifetime: configuration.missCacheLifetime)
            return nil
        }
        store([result], for: key, lifetime: configuration.productCacheLifetime)
        return result
    }

    /// The field list requested from the API. Asking for named fields rather than whole documents
    /// cuts a product payload from tens of kilobytes to a fraction of one, which matters on mobile
    /// data and is also what Open Food Facts asks clients to do.
    private static let requestedFields = [
        "code", "product_name", "product_name_en", "generic_name", "brands", "quantity",
        "serving_size", "serving_quantity", "nutrition_data_per", "nutriments",
        "categories_tags", "allergens_tags", "ingredients_analysis_tags",
    ].joined(separator: ",")

    // MARK: Networking

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            try checkCancellation()
            guard let http = response as? HTTPURLResponse else { return data }
            switch http.statusCode {
            case 200...299: return data
            case 404: throw FoodProviderError.notFound
            case 429: throw FoodProviderError.rateLimited
            default: throw FoodProviderError.network("HTTP \(http.statusCode)")
            }
        } catch let error as FoodProviderError {
            throw error
        } catch let error as URLError {
            throw FoodProviderError.from(urlError: error)
        } catch is CancellationError {
            throw FoodProviderError.cancelled
        } catch {
            throw FoodProviderError.network(String(describing: error))
        }
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw FoodProviderError.cancelled }
    }

    // MARK: Rate limiting

    /// Client-side rate limiting against a rolling one-minute window.
    ///
    /// Being throttled server-side costs the user a failed search; refusing locally costs them
    /// nothing, because the caller still has the bundled results. The window is a plain array of
    /// timestamps — at 100 entries a linear prune is cheaper than any cleverer structure.
    private func reserveSlot(forSearch isSearch: Bool) throws {
        let now = clock()
        let cutoff = now.addingTimeInterval(-60)
        if isSearch {
            searchRequestTimes.removeAll { $0 < cutoff }
            guard searchRequestTimes.count < configuration.searchRequestsPerMinute else {
                throw FoodProviderError.rateLimited
            }
            searchRequestTimes.append(now)
        } else {
            productRequestTimes.removeAll { $0 < cutoff }
            guard productRequestTimes.count < configuration.productRequestsPerMinute else {
                throw FoodProviderError.rateLimited
            }
            productRequestTimes.append(now)
        }
    }

    // MARK: Cache

    private func cachedResults(for key: CacheKey) -> [FoodSearchResult]? {
        guard let entry = cache[key] else { return nil }
        guard entry.expiresAt > clock() else {
            cache[key] = nil
            cacheOrder.removeAll { $0 == key }
            return nil
        }
        return entry.results
    }

    private func store(_ results: [FoodSearchResult], for key: CacheKey, lifetime: TimeInterval) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = CacheEntry(results: results, expiresAt: clock().addingTimeInterval(lifetime))
        while cacheOrder.count > configuration.maximumCacheEntries {
            let oldest = cacheOrder.removeFirst()
            cache[oldest] = nil
        }
    }

    /// Empties the cache. Used when the user explicitly refreshes a product.
    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: Barcode normalisation

    /// Accepts only the symbologies the scanner emits, after stripping separators.
    /// Lengths: EAN-8 (8), UPC-A (12), EAN-13 (13), ITF-14/GTIN-14 (14).
    static func normalisedBarcode(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard [8, 12, 13, 14].contains(digits.count) else { return nil }
        return digits
    }

    // MARK: Mapping

    private func mapped(_ product: OFFProduct, requestedBarcode: String?) -> FoodSearchResult? {
        let name = [product.productNameEN, product.productName, product.genericName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let name, !name.isEmpty else { return nil }

        let nutriments = product.nutriments ?? [:]
        let servingGrams = product.servingQuantity?.value

        /// Reads a per-100 value, falling back to the per-serving value rescaled to 100 g when the
        /// contributor entered nutrition per serving only.
        func per100(_ base: String) -> Double? {
            if let value = nutriments["\(base)_100g"]?.value { return value }
            if let perServing = nutriments["\(base)_serving"]?.value,
               let servingGrams, servingGrams > 0 {
                return perServing * 100 / servingGrams
            }
            return nil
        }

        let protein = Self.clampedMacro(per100("proteins"))
        let carbs = Self.clampedMacro(per100("carbohydrates"))
        let fat = Self.clampedMacro(per100("fat"))

        // Energy, best source first: kcal as entered, then kJ, then the generic energy field
        // (which Open Food Facts stores in kJ), then Atwater from the macros.
        var energy = per100("energy-kcal")
        if energy == nil, let kilojoules = per100("energy-kj") { energy = kilojoules / 4.184 }
        if energy == nil, let generic = per100("energy") { energy = generic / 4.184 }
        let kilocalories = Self.clampedEnergy(energy) ?? (protein * 4 + carbs * 4 + fat * 9)

        // A product with neither energy nor any macro carries no information worth logging.
        guard kilocalories > 0 || protein > 0 || carbs > 0 || fat > 0 else { return nil }

        var micros = Micronutrients()
        for (nutrient, mapping) in Self.micronutrientMap {
            guard let raw = per100(mapping.key) else { continue }
            let converted = raw * mapping.scale
            guard converted.isFinite, converted >= 0, converted <= mapping.plausibleMaximum else { continue }
            micros[nutrient] = converted
        }
        // Open Food Facts stores salt and sodium separately; either can be missing. Salt converts
        // at the standard 1 g salt = 400 mg sodium (molar mass ratio of NaCl to Na).
        if micros.sodiumMg == nil, let salt = per100("salt") {
            let sodium = salt * 400
            if sodium.isFinite, sodium >= 0, sodium <= 40_000 { micros.sodiumMg = sodium }
        }

        let basisUnit: ServingUnit = Self.isLiquid(product) ? .milliliters : .grams
        let dietary = Self.dietaryTags(for: product)
        let allergens = Self.allergenTags(for: product)
        let roles = FoodTagVocabulary.sanitise(
            FoodRoleTagDeriver.roleTags(
                kilocaloriesPer100: kilocalories,
                proteinGPer100: protein,
                carbsGPer100: carbs,
                fatGPer100: fat,
                micronutrientsPer100: micros,
                basisUnit: basisUnit
            ),
            against: FoodTagVocabulary.role
        )

        var servings: [FoodServing] = []
        if let grams = servingGrams, grams > 0, grams < 2000 {
            let label = product.servingSize?.trimmingCharacters(in: .whitespacesAndNewlines)
            servings.append(
                FoodServing(
                    name: (label?.isEmpty == false ? label! : "1 serving"),
                    nameKey: label?.isEmpty == false ? nil : "food.serving.serving",
                    gramsPerServing: grams
                )
            )
        }

        let brand = product.brands?
            .split(separator: ",")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let barcode = product.code ?? requestedBarcode

        return FoodSearchResult(
            providerID: identifier,
            externalID: barcode ?? name,
            name: name,
            brand: (brand?.isEmpty == false) ? brand : nil,
            barcode: barcode,
            basisUnit: basisUnit,
            kilocaloriesPer100: kilocalories,
            proteinGPer100: protein,
            carbsGPer100: carbs,
            fatGPer100: fat,
            micronutrientsPer100: micros,
            servings: servings,
            gramsPerPiece: nil,
            dietaryTags: dietary,
            allergenTags: allergens,
            roleTags: roles,
            source: .openFoodFacts,
            attribution: attribution
        )
    }

    /// Per-100 g macro grams, with nonsense rejected. A macro above 100 g per 100 g is a units
    /// error somewhere upstream, and importing it would poison the user's daily totals.
    private static func clampedMacro(_ value: Double?) -> Double {
        guard let value, value.isFinite, value >= 0, value <= 100 else { return 0 }
        return value
    }

    /// Pure fat is 900 kcal per 100 g, so anything beyond that is a units error.
    private static func clampedEnergy(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0, value <= 950 else { return nil }
        return value
    }

    /// Open Food Facts stores every mineral and vitamin in **grams** in its `_100g` fields, so each
    /// one needs scaling into the unit `Micronutrients` uses (mg or µg). `plausibleMaximum` is a
    /// crude guard against contributor typos — a hundredfold error is common when someone types
    /// milligrams into a grams field.
    private static let micronutrientMap: [(Micronutrient, (key: String, scale: Double, plausibleMaximum: Double))] = [
        (.fiber, ("fiber", 1, 100)),
        (.sugar, ("sugars", 1, 100)),
        (.saturatedFat, ("saturated-fat", 1, 100)),
        (.cholesterol, ("cholesterol", 1000, 5000)),
        (.sodium, ("sodium", 1000, 40_000)),
        (.potassium, ("potassium", 1000, 10_000)),
        (.calcium, ("calcium", 1000, 5000)),
        (.iron, ("iron", 1000, 500)),
        (.magnesium, ("magnesium", 1000, 2000)),
        (.zinc, ("zinc", 1000, 200)),
        (.phosphorus, ("phosphorus", 1000, 3000)),
        (.selenium, ("selenium", 1_000_000, 5000)),
        (.vitaminA, ("vitamin-a", 1_000_000, 20_000)),
        (.vitaminC, ("vitamin-c", 1000, 3000)),
        (.vitaminD, ("vitamin-d", 1_000_000, 500)),
        (.vitaminE, ("vitamin-e", 1000, 500)),
        (.vitaminK, ("vitamin-k", 1_000_000, 5000)),
        (.thiamin, ("vitamin-b1", 1000, 200)),
        (.riboflavin, ("vitamin-b2", 1000, 200)),
        (.niacin, ("vitamin-pp", 1000, 500)),
        (.vitaminB6, ("vitamin-b6", 1000, 200)),
        (.folate, ("vitamin-b9", 1_000_000, 5000)),
        (.vitaminB12, ("vitamin-b12", 1_000_000, 500)),
    ]

    /// Category keywords that imply a dietary tag. Matched against `categories_tags`, which are
    /// language-prefixed slugs such as `en:chicken-breasts`.
    private static let dietaryCategoryKeywords: [(tag: String, needles: [String])] = [
        ("poultry", ["poultry", "chicken", "turkey", "duck", "goose"]),
        ("meat", ["meat", "beef", "pork", "lamb", "veal", "bacon", "ham", "sausage",
                  "charcuterie", "salami", "venison", "offal"]),
        ("fish", ["fish", "salmon", "tuna", "cod", "sardine", "anchov", "mackerel", "herring"]),
        ("seafood", ["seafood", "shellfish", "crustacean", "mollusc", "prawn", "shrimp",
                     "crab", "lobster", "mussel", "oyster", "squid", "octopus"]),
        ("dairy", ["dairy", "dairies", "milk", "cheese", "yogurt", "yoghurt", "cream", "butter"]),
        ("egg", ["egg"]),
        ("honey", ["honey"]),
    ]

    private static func dietaryTags(for product: OFFProduct) -> [String] {
        let analysis = Set(product.ingredientsAnalysisTags ?? [])
        // A product Open Food Facts has analysed as vegan cannot carry any of these tags, and that
        // signal is far more reliable than category-name matching, so it wins outright.
        if analysis.contains("en:vegan") { return [] }

        let categories = (product.categoriesTags ?? []).map { $0.lowercased() }
        let allergens = Set((product.allergensTags ?? []).map { $0.lowercased() })
        var tags: [String] = []

        for entry in dietaryCategoryKeywords {
            let matches = categories.contains { category in
                entry.needles.contains { category.contains($0) }
            }
            if matches { tags.append(entry.tag) }
        }
        // Declared allergens are a legal statement about the contents, so they are trusted.
        if allergens.contains("en:milk") { tags.append("dairy") }
        if allergens.contains("en:eggs") { tags.append("egg") }
        if allergens.contains("en:fish") { tags.append("fish") }
        if allergens.contains("en:crustaceans") || allergens.contains("en:molluscs") {
            tags.append("seafood")
        }

        if analysis.contains("en:vegetarian") {
            tags.removeAll { ["meat", "poultry", "fish", "seafood"].contains($0) }
        }
        return FoodTagVocabulary.sanitise(tags, against: FoodTagVocabulary.dietary)
    }

    /// EU allergen slugs mapped onto the six the app filters on.
    private static let allergenSlugMap: [String: String] = [
        "en:gluten": "gluten",
        "en:wheat": "gluten",
        "en:barley": "gluten",
        "en:rye": "gluten",
        "en:oats": "gluten",
        "en:nuts": "nuts",
        "en:tree-nuts": "nuts",
        "en:almonds": "nuts",
        "en:hazelnuts": "nuts",
        "en:walnuts": "nuts",
        "en:cashew-nuts": "nuts",
        "en:pistachio-nuts": "nuts",
        "en:pecan-nuts": "nuts",
        "en:macadamia-nuts": "nuts",
        "en:brazil-nuts": "nuts",
        "en:peanuts": "peanut",
        "en:soybeans": "soy",
        "en:soy": "soy",
        "en:crustaceans": "shellfish",
        "en:molluscs": "shellfish",
        "en:sesame-seeds": "sesame",
        "en:sesame": "sesame",
    ]

    private static func allergenTags(for product: OFFProduct) -> [String] {
        let declared = (product.allergensTags ?? []).map { $0.lowercased() }
        let mapped = declared.compactMap { allergenSlugMap[$0] }
        return FoodTagVocabulary.sanitise(mapped, against: FoodTagVocabulary.allergen)
    }

    /// Whether the per-100 basis should be millilitres.
    ///
    /// Open Food Facts has no explicit flag, so this reads the pack quantity: a product sold as
    /// "330 ml" or "1 l" is a liquid. Getting it wrong only changes the unit label the user sees,
    /// never the arithmetic, because both bases are per-100.
    private static func isLiquid(_ product: OFFProduct) -> Bool {
        let quantity = (product.quantity ?? "").lowercased()
        let serving = (product.servingSize ?? "").lowercased()
        for text in [quantity, serving] {
            if text.contains("ml") || text.contains("cl") || text.hasSuffix("l")
                || text.contains(" l") || text.contains("litre") || text.contains("liter") {
                return true
            }
        }
        let categories = (product.categoriesTags ?? []).map { $0.lowercased() }
        return categories.contains { $0.contains("beverage") || $0.contains("drink") || $0.contains("water") }
    }
}
