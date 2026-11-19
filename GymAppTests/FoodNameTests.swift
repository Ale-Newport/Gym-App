import Foundation
import SwiftData
import Testing

@testable import GymApp

/// Food names in the user's language: shown, searched, and written to the store.
///
/// The bundled database is English. Searching it for "pollo" used to return pollock, because the
/// only text the index knew was English — which is exactly the failure a Spanish user hits on the
/// first meal they log.
@MainActor
@Suite("Food names")
struct FoodNameTests {

    // MARK: - The names file

    @Test("Every language covers every bundled food")
    func everyLanguageIsComplete() throws {
        let loader = FoodCatalogLoader()
        let records = try loader.loadRecords()
        let names = loader.loadNames()

        for language in ["es", "fr", "it", "tr", "ru", "zh", "hi", "pl", "ko"] {
            for record in records {
                #expect(
                    names.name(for: record.catalogID, language: language) != nil,
                    "\(record.catalogID) has no \(language) name"
                )
            }
        }
    }

    @Test("English is the record's own name and is not duplicated in the table")
    func englishFallsBack() throws {
        let names = FoodCatalogLoader().loadNames()
        #expect(names.name(for: "almond_butter", language: "en") == nil)
        #expect(names.name(for: "no_such_food", language: "es") == nil)
    }

    // MARK: - Normalising text in every script

    @Test("Normalising keeps letters of every script instead of discarding them")
    func normaliserKeepsNonLatinText() {
        #expect(FoodTextNormalizer.normalize("Pechuga de pollo, a la plancha") == "pechuga de pollo a la plancha")
        #expect(FoodTextNormalizer.normalize("Куриная грудка, сырая") == "куриная грудка сырая")
        #expect(FoodTextNormalizer.normalize("鸡胸肉，生") == "鸡胸肉 生")
        #expect(!FoodTextNormalizer.normalize("닭가슴살, 생것").isEmpty)
        #expect(!FoodTextNormalizer.normalize("चिकन ब्रेस्ट").isEmpty)
        // The Latin rules are unchanged.
        #expect(FoodTextNormalizer.normalize("Crème fraîche") == "creme fraiche")
    }

    // MARK: - Searching

    @Test("A Spanish search finds the food that used to come back as pollock")
    func spanishSearchFindsChicken() async throws {
        let results = try await LocalFoodDatabaseProvider().search("pollo", limit: 20)

        #expect(!results.isEmpty)
        #expect(
            results.contains { $0.externalID.contains("chicken") },
            "'pollo' found \(results.map(\.externalID))"
        )
        #expect(!results.prefix(5).contains { $0.externalID.contains("pollock") })
    }

    @Test("Searching in English still works, and an English name is found once")
    func englishSearchIsUnchangedAndDeduplicated() async throws {
        let results = try await LocalFoodDatabaseProvider().search("chicken breast", limit: 40)
        #expect(!results.isEmpty)
        #expect(Set(results.map(\.externalID)).count == results.count, "a food was listed twice")
    }

    @Test("Names in other scripts are searchable")
    func searchWorksInNonLatinScripts() async throws {
        let provider = LocalFoodDatabaseProvider()
        for query in ["鸡胸", "курин", "닭가슴", "चिकन"] {
            let results = try await provider.search(query, limit: 10)
            #expect(!results.isEmpty, "'\(query)' returned nothing")
        }
    }

    // MARK: - Importing

    @Test("The importer writes names in the requested language, and rewrites them when it changes")
    func importFollowsTheLanguage() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let suite = "FoodNameTests.\(UUID().uuidString)"
        let versionStore = FoodDatabaseVersionStore(suiteName: suite)
        defer { UserDefaults.standard.removeSuite(named: suite) }
        let importer = FoodDatabaseImporter(modelContainer: container)
        let context = ModelContext(container)

        _ = try await importer.importIfNeeded(versionStore: versionStore, language: "en")
        let english = try #require(
            try context.fetch(FetchDescriptor<FoodItem>()).first { $0.catalogID == "almond_butter" }
        )
        #expect(english.name == "Almond butter")

        let sameLanguage = try await importer.importIfNeeded(versionStore: versionStore, language: "en")
        #expect(!sameLanguage.didRun, "the same language must not trigger another import")

        let spanish = try await importer.importIfNeeded(versionStore: versionStore, language: "es")
        #expect(spanish.didRun, "a new language must re-import")
        #expect(spanish.inserted == 0, "re-importing for a language updates rows, it does not duplicate them")
        let translated = try #require(
            try context.fetch(FetchDescriptor<FoodItem>()).first { $0.catalogID == "almond_butter" }
        )
        #expect(translated.name == "Crema de almendras")
    }

    @Test("A food the user has logged keeps its favourite and count when the language changes")
    func languageChangeKeepsUserState() async throws {
        let container = try PersistenceController.makeInMemoryContainer()
        let suite = "FoodNameTests.\(UUID().uuidString)"
        let versionStore = FoodDatabaseVersionStore(suiteName: suite)
        defer { UserDefaults.standard.removeSuite(named: suite) }
        let importer = FoodDatabaseImporter(modelContainer: container)
        let context = ModelContext(container)

        _ = try await importer.importIfNeeded(versionStore: versionStore, language: "en")
        let food = try #require(
            try context.fetch(FetchDescriptor<FoodItem>()).first { $0.catalogID == "almond_butter" }
        )
        food.isFavorite = true
        food.timesLogged = 7
        try context.save()

        _ = try await importer.importIfNeeded(versionStore: versionStore, language: "fr")

        let after = try #require(
            try context.fetch(FetchDescriptor<FoodItem>()).first { $0.catalogID == "almond_butter" }
        )
        #expect(after.isFavorite)
        #expect(after.timesLogged == 7)
        #expect(after.id == food.id, "the row must be updated in place so references keep working")
    }
}
