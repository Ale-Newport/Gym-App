import Foundation
import SwiftData

// MARK: - Version bookkeeping

/// Remembers which revision of the bundled food database has been ingested.
///
/// Wrapping `UserDefaults` rather than passing it around keeps the importer free of non-`Sendable`
/// values and puts the one magic string in exactly one place.
struct FoodDatabaseVersionStore: Sendable {
    /// The key the rest of the app reads to show "food data: 2026.08.1" in settings.
    static let defaultsKey = "foodDatabaseVersion"

    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    var storedVersion: String? { defaults.string(forKey: Self.defaultsKey) }

    func record(_ version: String) { defaults.set(version, forKey: Self.defaultsKey) }

    func clear() { defaults.removeObject(forKey: Self.defaultsKey) }
}

// MARK: - Progress and summary

/// Progress of a running import, reported to the caller for a progress bar.
struct FoodImportProgress: Hashable, Sendable {
    enum Phase: String, Hashable, Sendable {
        case reading
        case matching
        case writing
        case pruning
        case finished

        var localizationKey: String { "food.import.phase.\(rawValue)" }
    }

    var phase: Phase
    var processed: Int
    var total: Int

    /// 0...1, and 1 whenever the total is unknown but the phase has finished.
    var fraction: Double {
        guard total > 0 else { return phase == .finished ? 1 : 0 }
        return min(1, Double(processed) / Double(total))
    }
}

/// What an import actually did. Returned so the caller can log it and so tests can assert on it.
struct FoodDatabaseImportSummary: Hashable, Sendable {
    var version: String
    /// `false` when the stored version already matched and nothing needed doing.
    var didRun: Bool
    var inserted: Int = 0
    var updated: Int = 0
    var unchanged: Int = 0
    /// Foods dropped from the new database that the user had used, converted to their own custom
    /// foods instead of being deleted.
    var adopted: Int = 0
    var removed: Int = 0
    var skipped: Int = 0

    static func upToDate(version: String) -> FoodDatabaseImportSummary {
        FoodDatabaseImportSummary(version: version, didRun: false)
    }
}

// MARK: - Importer

/// Ingests the bundled food database into SwiftData.
///
/// Four properties define the design, and every one of them is a correctness requirement rather
/// than a nicety:
///
/// - **Idempotent.** Rows are matched on `catalogID`, so running the import twice updates rather
///   than duplicates. Nothing here depends on the store being empty.
/// - **Versioned.** The manifest's `version` is recorded in `UserDefaults` under
///   `"foodDatabaseVersion"`. A launch where the version is unchanged does no work at all.
/// - **Never touches the user's own data.** Only rows whose source is `.builtIn` are considered.
///   Custom foods, recipes and every piece of user state on a built-in row — favourite, times
///   logged, last logged, cost — are read but never written.
/// - **Survives a database upgrade that adds, changes and removes foods.** Additions insert,
///   changes update in place so existing references keep working, and removals are pruned only
///   when nothing points at them; a removed food the user actually used is *adopted* as one of
///   their own custom foods rather than vanishing from their history.
///
/// It is a `@ModelActor`, so it owns a private `ModelContext` on its own executor and runs off the
/// main thread by construction.
@ModelActor
actor FoodDatabaseImporter {

    /// Shown on the food detail screen for every bundled food.
    static let builtInAttribution = "USDA FoodData Central (public domain)"

    /// Rows written between saves. Large enough that saving is not the bottleneck, small enough
    /// that a first-run import of ~600 foods never holds the whole change set in memory.
    private static let saveBatchSize = 200
    /// Progress is reported at most this often, so a fast import does not flood the main actor
    /// with updates the user cannot perceive.
    private static let progressStride = 25

    /// Runs the import if the bundled database differs from what was last ingested.
    ///
    /// - Parameters:
    ///   - loader: the bundle reader; injected so tests can point at a fixture bundle.
    ///   - versionStore: where the ingested version is remembered.
    ///   - force: re-import even when the version matches. Used by the "rebuild food database"
    ///     maintenance action.
    ///   - now: reference date written to `createdAt`/`updatedAt`. A parameter rather than a call
    ///     to `Date()` so the result is reproducible.
    ///   - progress: called on the importer's executor as work proceeds.
    @discardableResult
    func importIfNeeded(
        loader: FoodCatalogLoader = FoodCatalogLoader(),
        versionStore: FoodDatabaseVersionStore = FoodDatabaseVersionStore(),
        force: Bool = false,
        now: Date = Date(),
        progress: @Sendable (FoodImportProgress) -> Void = { _ in }
    ) throws -> FoodDatabaseImportSummary {
        progress(FoodImportProgress(phase: .reading, processed: 0, total: 0))

        let manifest = try loader.loadManifest()
        let existingBuiltIns = try fetchBuiltInFoods()

        // The row count is checked as well as the version: a user who reset their data would
        // otherwise be left with an empty food database because the version still "matched".
        if !force, versionStore.storedVersion == manifest.version, !existingBuiltIns.isEmpty {
            progress(FoodImportProgress(phase: .finished, processed: 0, total: 0))
            return .upToDate(version: manifest.version)
        }

        let records = try loader.loadRecords()
        var summary = FoodDatabaseImportSummary(version: manifest.version, didRun: true)

        progress(FoodImportProgress(phase: .matching, processed: 0, total: records.count))

        var byCatalogID: [String: FoodItem] = [:]
        for item in existingBuiltIns {
            guard let catalogID = item.catalogID, !catalogID.isEmpty else { continue }
            // A duplicate can only exist if an earlier build wrote one; keep the first and let the
            // prune step deal with the rest.
            if byCatalogID[catalogID] == nil { byCatalogID[catalogID] = item }
        }

        modelContext.autosaveEnabled = false

        var written = 0
        var seenIDs = Set<String>()

        for (offset, record) in records.enumerated() {
            guard seenIDs.insert(record.catalogID).inserted else {
                summary.skipped += 1
                continue
            }

            if let existing = byCatalogID[record.catalogID] {
                if apply(record, to: existing, now: now) {
                    summary.updated += 1
                    written += 1
                } else {
                    summary.unchanged += 1
                }
            } else {
                let item = FoodItem()
                item.catalogID = record.catalogID
                item.source = .builtIn
                item.createdAt = now
                _ = apply(record, to: item, now: now)
                modelContext.insert(item)
                summary.inserted += 1
                written += 1
            }

            if written >= Self.saveBatchSize {
                try modelContext.save()
                written = 0
            }
            if offset % Self.progressStride == 0 {
                progress(FoodImportProgress(phase: .writing, processed: offset, total: records.count))
            }
        }

        if written > 0 { try modelContext.save() }

        // --- Removals -------------------------------------------------------------------------
        let obsolete = existingBuiltIns.filter { item in
            guard let catalogID = item.catalogID else { return true }
            return !seenIDs.contains(catalogID) || byCatalogID[catalogID] !== item
        }

        if !obsolete.isEmpty {
            progress(FoodImportProgress(phase: .pruning, processed: 0, total: obsolete.count))
            let referenced = try referencedFoodIDs()
            for (offset, item) in obsolete.enumerated() {
                if referenced.contains(item.id) || item.isFavorite || item.timesLogged > 0 {
                    adopt(item, now: now)
                    summary.adopted += 1
                } else {
                    modelContext.delete(item)
                    summary.removed += 1
                }
                if offset % Self.progressStride == 0 {
                    progress(FoodImportProgress(phase: .pruning, processed: offset, total: obsolete.count))
                }
            }
            try modelContext.save()
        }

        versionStore.record(manifest.version)
        progress(FoodImportProgress(phase: .finished, processed: records.count, total: records.count))

        AppLog.nutrition.info(
            """
            Food database import \(manifest.version, privacy: .public): \
            +\(summary.inserted) ~\(summary.updated) =\(summary.unchanged) \
            adopted \(summary.adopted) removed \(summary.removed)
            """
        )
        return summary
    }

    // MARK: Fetching

    private func fetchBuiltInFoods() throws -> [FoodItem] {
        let builtIn = FoodSource.builtIn.rawValue
        let descriptor = FetchDescriptor<FoodItem>(
            predicate: #Predicate { $0.sourceRaw == builtIn }
        )
        return try modelContext.fetch(descriptor)
    }

    /// Every food id that some piece of user data points at.
    ///
    /// Gathered once, in three fetches, rather than per candidate: an upgrade that drops fifty
    /// foods would otherwise issue a hundred and fifty queries. Log entries snapshot their own
    /// nutrition, so a referenced log entry survives either way — but a saved meal or a recipe
    /// ingredient resolves its food live, and silently emptying someone's "usual breakfast" is not
    /// an acceptable outcome of a data refresh.
    private func referencedFoodIDs() throws -> Set<UUID> {
        var ids = Set<UUID>()
        for entry in try modelContext.fetch(FetchDescriptor<FoodLogEntry>()) {
            if let id = entry.foodID { ids.insert(id) }
        }
        for item in try modelContext.fetch(FetchDescriptor<SavedMealItem>()) {
            if let id = item.foodID { ids.insert(id) }
        }
        for ingredient in try modelContext.fetch(FetchDescriptor<RecipeIngredient>()) {
            if let id = ingredient.foodID { ids.insert(id) }
        }
        return ids
    }

    // MARK: Writing

    /// Copies the catalogue-owned fields onto `item`. Returns `true` when anything changed.
    ///
    /// User state (`isFavorite`, `timesLogged`, `lastLoggedAt`, `costPer100`) is deliberately not
    /// in this list: those belong to the user, not to the database, and a refresh must leave them
    /// exactly as they were.
    private func apply(_ record: FoodCatalogRecord, to item: FoodItem, now: Date) -> Bool {
        var changed = false

        func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<FoodItem, Value>, _ value: Value) {
            if item[keyPath: keyPath] != value {
                item[keyPath: keyPath] = value
                changed = true
            }
        }

        set(\.name, record.name)
        set(\.kilocaloriesPer100, record.kcal)
        set(\.proteinGPer100, record.protein)
        set(\.carbsGPer100, record.carbs)
        set(\.fatGPer100, record.fat)
        set(\.micronutrientsPer100, record.micros ?? .unknown)
        set(\.basisUnit, record.servingUnit)
        set(\.gramsPerPiece, record.gramsPerPiece)
        set(\.dietaryTags, record.dietaryTags)
        set(\.allergenTags, record.allergenTags)
        set(\.roleTags, record.roleTags)
        set(\.attribution, Self.builtInAttribution)
        set(\.sourceRaw, FoodSource.builtIn.rawValue)

        // `FoodServing` carries a fresh `UUID` on every construction, so a plain `!=` would report
        // a change every single run. Compare the fields that actually come from the file, and only
        // rebuild the array when one of them really moved.
        let incoming = record.foodServings
        if !Self.servingsMatch(item.servings, incoming) {
            item.servings = incoming
            changed = true
        }

        if changed { item.updatedAt = now }
        return changed
    }

    private static func servingsMatch(_ lhs: [FoodServing], _ rhs: [FoodServing]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            if left.name != right.name { return false }
            if left.nameKey != right.nameKey { return false }
            if abs(left.gramsPerServing - right.gramsPerServing) > 0.001 { return false }
        }
        return true
    }

    /// Hands a withdrawn built-in food to the user as their own.
    ///
    /// `catalogID` is cleared so a later database that reintroduces the same slug inserts a fresh
    /// built-in row instead of fighting over this one, and the source becomes `.custom` so this
    /// importer will never touch it again — which is precisely the guarantee custom foods have.
    private func adopt(_ item: FoodItem, now: Date) {
        item.catalogID = nil
        item.source = .custom
        item.attribution = Self.builtInAttribution
        item.updatedAt = now
    }

    // MARK: Maintenance

    /// Deletes every built-in row and forgets the recorded version, so the next import rebuilds
    /// from scratch. Custom foods, recipes and history are untouched.
    ///
    /// Exposed for the settings screen's "rebuild food database" action, which exists because a
    /// store that has gone strange is otherwise unrecoverable without deleting the whole app.
    @discardableResult
    func resetBuiltInFoods(versionStore: FoodDatabaseVersionStore = FoodDatabaseVersionStore()) throws -> Int {
        let existing = try fetchBuiltInFoods()
        for item in existing { modelContext.delete(item) }
        try modelContext.save()
        versionStore.clear()
        AppLog.nutrition.info("Food database reset: removed \(existing.count) built-in foods")
        return existing.count
    }
}
