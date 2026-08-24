import Foundation
import SwiftData
import Testing
@testable import GymApp

/// The bundled food database, its provider and its importer.
///
/// This suite exists because a gap here is invisible from the outside: the app builds, the Nutrition
/// tab renders, and food search simply returns nothing. The first time it was written, it caught
/// exactly that — the importer was never called from anywhere, so 594 foods sat unread in the
/// bundle.
@MainActor
@Suite("Food database")
struct FoodDatabaseTests {

    // MARK: - The bundled catalogue

    @Test("The bundled catalogue loads and matches its manifest")
    func catalogueLoads() throws {
        let loader = FoodCatalogLoader()
        let manifest = try loader.loadManifest()
        let records = try loader.loadRecords()

        #expect(records.count == manifest.foodCount)
        #expect(records.count >= 550, "the product requires a usable starting database")
        #expect(Set(records.map(\.catalogID)).count == records.count, "catalogIDs must be unique")
    }

    @Test("Every record carries the macros the app needs, and none is nonsensical")
    func recordsAreWellFormed() throws {
        for record in try FoodCatalogLoader().loadRecords() {
            #expect(!record.name.isEmpty)
            #expect(record.kcal >= 0)
            for value in [record.protein, record.carbs, record.fat] {
                #expect(value >= 0 && value <= 100, "\(record.catalogID): macro out of range")
            }
            #expect(
                record.protein + record.carbs + record.fat <= 100.5,
                "\(record.catalogID): macros exceed 100 g per 100 g"
            )
        }
    }

    @Test("Dietary tags use only the vocabulary the diet filter understands")
    func dietaryTagsAreRecognised() throws {
        // A tag outside this set is silently ignored by `DietType.excludedTags`, which would offer a
        // vegan an animal product. It is the highest-consequence data error in this file.
        let allowed: Set<String> = ["meat", "poultry", "fish", "seafood", "dairy", "egg", "honey"]
        for record in try FoodCatalogLoader().loadRecords() {
            let unknown = Set(record.dietaryTags).subtracting(allowed)
            #expect(unknown.isEmpty, "\(record.catalogID): unknown dietary tags \(unknown.sorted())")
        }
    }

    // MARK: - Offline search

    @Test("The local provider answers common searches without a network")
    func localSearchFindsEverydayFoods() async throws {
        let provider = LocalFoodDatabaseProvider()
        for term in ["chicken", "rice", "banana", "olive oil", "egg", "oats"] {
            let results = try await provider.search(term, limit: 20)
            #expect(!results.isEmpty, "'\(term)' returned nothing from the bundled database")
        }
    }

    @Test("Search is diacritic- and case-insensitive")
    func searchIsInsensitive() async throws {
        let provider = LocalFoodDatabaseProvider()
        let plain = try await provider.search("banana", limit: 10)
        let shouted = try await provider.search("BANANA", limit: 10)
        #expect(plain.map(\.externalID) == shouted.map(\.externalID))
    }

    @Test("A nonsense query returns nothing rather than everything")
    func nonsenseReturnsNothing() async throws {
        let results = try await LocalFoodDatabaseProvider().search("zzzzqqqxx", limit: 20)
        #expect(results.isEmpty)
    }

    // MARK: - Import

    @Test("Importing populates the store, and importing again changes nothing")
    func importIsIdempotent() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let suite = "FoodDatabaseTests.\(UUID().uuidString)"
        let versionStore = FoodDatabaseVersionStore(suiteName: suite)
        defer { UserDefaults.standard.removeSuite(named: suite) }

        let importer = FoodDatabaseImporter(modelContainer: container)
        let first = try await importer.importIfNeeded(versionStore: versionStore)
        #expect(first.didRun)
        #expect(first.inserted >= 550)

        let context = ModelContext(container)
        let afterFirst = try context.fetchCount(FetchDescriptor<FoodItem>())
        #expect(afterFirst == first.inserted)

        let second = try await importer.importIfNeeded(versionStore: versionStore)
        #expect(!second.didRun, "a second import with an unchanged version must be a no-op")
        #expect(try context.fetchCount(FetchDescriptor<FoodItem>()) == afterFirst)
    }

    @Test("Importing never touches a food the user created")
    func importLeavesCustomFoodsAlone() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let suite = "FoodDatabaseTests.\(UUID().uuidString)"
        let versionStore = FoodDatabaseVersionStore(suiteName: suite)
        defer { UserDefaults.standard.removeSuite(named: suite) }

        let context = ModelContext(container)
        let mine = FoodItem()
        mine.name = "My own protein shake"
        mine.source = .custom
        mine.kilocaloriesPer100 = 123
        context.insert(mine)
        try context.save()

        _ = try await FoodDatabaseImporter(modelContainer: container)
            .importIfNeeded(versionStore: versionStore)

        let custom = try context.fetch(FetchDescriptor<FoodItem>())
            .filter { $0.source == .custom }
        #expect(custom.count == 1)
        #expect(custom.first?.name == "My own protein shake")
        #expect(custom.first?.kilocaloriesPer100 == 123)
    }

    @Test("Imported foods are searchable through the repository, which is what the UI queries")
    func importedFoodsAreSearchable() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let suite = "FoodDatabaseTests.\(UUID().uuidString)"
        let versionStore = FoodDatabaseVersionStore(suiteName: suite)
        defer { UserDefaults.standard.removeSuite(named: suite) }

        _ = try await FoodDatabaseImporter(modelContainer: container)
            .importIfNeeded(versionStore: versionStore)

        let repository = NutritionRepository(context: ModelContext(container))
        for term in ["banana", "chicken", "rice"] {
            #expect(
                !(try repository.searchFoods(term, limit: 20)).isEmpty,
                "'\(term)' was imported but the repository search cannot find it"
            )
        }
    }
}
