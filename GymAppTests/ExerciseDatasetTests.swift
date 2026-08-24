import Foundation
import Testing
@testable import GymApp

// MARK: - Shared fixture

/// Anchor type used only to locate the unit-test bundle.
final class ExerciseDatasetTestAnchor {}

/// One decode of the bundled dataset, shared by every data-integrity suite.
///
/// The catalogue is static reference data, so loading it once and reusing it keeps the suite fast
/// while staying entirely deterministic: the same bundle always produces the same records.
enum ExerciseDatasetFixture {

    /// The on-disk shape of one record, decoded independently of the importer so the tests can
    /// assert what the *raw* dataset says rather than what the importer chose to keep.
    struct Row: Decodable {
        let id: String
        let name: String
        let bodyPart: String
        let equipment: String
        let target: String
        let muscleGroup: String
        let secondaryMuscles: [String]
        let mediaId: String
        let thumbnail: String
        let animation: String
        let attribution: String
        let createdAt: String
    }

    /// The bundle that actually carries the dataset. Unit tests are hosted inside the app, so this
    /// is normally `Bundle.main`; searching keeps the suite working if that ever changes.
    static let appBundle: Bundle = {
        var candidates: [Bundle] = [.main, Bundle(for: ExerciseDatasetTestAnchor.self)]
        candidates.append(contentsOf: Bundle.allBundles)
        for bundle in candidates
        where bundle.url(forResource: "dataset-manifest.json", withExtension: nil, subdirectory: "ExerciseDataset") != nil
            || bundle.url(forResource: "dataset-manifest.json", withExtension: nil) != nil {
            return bundle
        }
        return .main
    }()

    static let importer = ExerciseDatasetImporter(bundle: appBundle)

    static let manifest: ExerciseDatasetManifest? = try? importer.loadManifest()

    static let exercises: [Exercise] = {
        guard let manifest else { return [] }
        return (try? importer.loadExercises(expecting: manifest)) ?? []
    }()

    static let rows: [Row] = {
        let url = appBundle.url(forResource: "exercises.core.json", withExtension: nil, subdirectory: "ExerciseDataset")
            ?? appBundle.url(forResource: "exercises.core.json", withExtension: nil)
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Row].self, from: data)) ?? []
    }()

    static let mediaProvider = BundledExerciseMediaProvider(bundle: appBundle)

    enum FixtureError: Error, CustomStringConvertible {
        case missingExercise(String)
        case couldNotMakeBundle

        var description: String {
            switch self {
            case .missingExercise(let id): "exercise \(id) is not in the bundled catalogue"
            case .couldNotMakeBundle: "could not create a scratch bundle"
            }
        }
    }

    /// A bundle that provably contains none of the dataset, used for the missing-data paths.
    static func emptyBundle() throws -> Bundle {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("forge-empty-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let bundle = Bundle(url: root) else { throw FixtureError.couldNotMakeBundle }
        return bundle
    }

    /// Exercises whose classification the suites assert by name.
    static func exercise(id: String) throws -> Exercise {
        guard let match = exercises.first(where: { $0.id == id }) else {
            throw FixtureError.missingExercise(id)
        }
        return match
    }
}

// MARK: - Manifest

@Suite("Bundled dataset manifest")
struct ExerciseDatasetManifestTests {

    @Test("The dataset manifest is present in the app bundle and decodes")
    func manifestDecodes() throws {
        let manifest = try #require(
            ExerciseDatasetFixture.manifest,
            "dataset-manifest.json could not be read from the app bundle"
        )
        #expect(manifest.schemaVersion == 1)
        #expect(!manifest.datasetVersion.isEmpty)
        #expect(!manifest.sourceChecksum.isEmpty)
        #expect(!manifest.sourceRepository.isEmpty)
        #expect(!manifest.mediaAttribution.isEmpty)
        #expect(!manifest.mediaLicense.isEmpty)
        #expect(manifest.mediaResolution == "180x180")
    }

    @Test("The manifest declares 1,324 exercises")
    func manifestDeclaresTheShippedRecordCount() throws {
        let manifest = try #require(ExerciseDatasetFixture.manifest)
        #expect(manifest.exerciseCount == 1324)
    }

    @Test("The manifest declares exactly the ten languages the app ships in")
    func manifestLanguagesMatchAppLanguage() throws {
        let manifest = try #require(ExerciseDatasetFixture.manifest)
        #expect(manifest.languages.count == AppLanguage.allCases.count)
        #expect(Set(manifest.languages) == Set(AppLanguage.allCases.map(\.datasetCode)))
    }

    @Test("An importer pointed at a bundle without the dataset reports a missing manifest")
    func missingManifestIsReportedRatherThanCrashing() throws {
        let importer = ExerciseDatasetImporter(bundle: try ExerciseDatasetFixture.emptyBundle())
        #expect(throws: ExerciseDatasetError.self) {
            _ = try importer.loadManifest()
        }
    }

    @Test("An importer pointed at a bundle without the core file reports missing core data")
    func missingCoreDataIsReportedRatherThanCrashing() throws {
        let manifest = try #require(ExerciseDatasetFixture.manifest)
        let importer = ExerciseDatasetImporter(bundle: try ExerciseDatasetFixture.emptyBundle())
        #expect(throws: ExerciseDatasetError.self) {
            _ = try importer.loadExercises(expecting: manifest)
        }
    }
}

// MARK: - Record integrity

@Suite("Bundled exercise records")
struct ExerciseDatasetRecordTests {

    @Test("Every record the manifest promises is loaded")
    func loadsExactlyTheDeclaredNumberOfRecords() throws {
        let manifest = try #require(ExerciseDatasetFixture.manifest)
        #expect(ExerciseDatasetFixture.exercises.count == manifest.exerciseCount)
    }

    @Test("The importer drops no record from the raw dataset")
    func importerKeepsEveryRawRecord() {
        #expect(ExerciseDatasetFixture.rows.isEmpty == false)
        #expect(ExerciseDatasetFixture.exercises.count == ExerciseDatasetFixture.rows.count)
    }

    @Test("Exercise ids are unique")
    func idsAreUnique() {
        let exercises = ExerciseDatasetFixture.exercises
        var seen = Set<String>()
        var duplicates: [String] = []
        for exercise in exercises where !seen.insert(exercise.id).inserted {
            duplicates.append(exercise.id)
        }
        #expect(duplicates.isEmpty, "duplicate ids in the bundled dataset: \(duplicates.prefix(10))")
        #expect(seen.count == exercises.count)
    }

    @Test("No exercise has an empty id or name")
    func noEmptyIdentifiersOrNames() {
        let blank = ExerciseDatasetFixture.exercises.filter {
            $0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        #expect(blank.isEmpty, "\(blank.count) exercises have a blank id or name")
    }

    @Test("Every exercise resolves to a known body part rather than falling through to .other")
    func everyBodyPartResolves() {
        let unresolved = ExerciseDatasetFixture.rows
            .filter { BodyPart(datasetValue: $0.bodyPart) == .other }
            .map { "\($0.id) '\($0.bodyPart)'" }
        #expect(unresolved.isEmpty, "unmapped body-part strings: \(unresolved.prefix(10))")
        #expect(ExerciseDatasetFixture.exercises.allSatisfy { $0.bodyPart != .other })
    }

    @Test("Every exercise resolves to a known equipment rather than falling through to .other")
    func everyEquipmentResolves() {
        let unresolved = ExerciseDatasetFixture.rows
            .filter { Equipment(datasetValue: $0.equipment) == .other }
            .map { "\($0.id) '\($0.equipment)'" }
        #expect(unresolved.isEmpty, "unmapped equipment strings: \(unresolved.prefix(10))")
        #expect(ExerciseDatasetFixture.exercises.allSatisfy { $0.equipment != .other })
    }

    @Test("Every target muscle string in the dataset maps onto a canonical muscle")
    func everyTargetResolves() {
        let unresolved = ExerciseDatasetFixture.rows
            .filter { Muscle(datasetValue: $0.target) == nil }
            .map { "\($0.id) '\($0.target)'" }
        #expect(unresolved.isEmpty, "unmapped target strings: \(unresolved.prefix(10))")
    }

    @Test("Every synergist and secondary muscle string maps onto a canonical muscle")
    func everySecondaryMuscleResolves() {
        var unresolved: [String] = []
        for row in ExerciseDatasetFixture.rows {
            if Muscle(datasetValue: row.muscleGroup) == nil {
                unresolved.append("\(row.id) synergist '\(row.muscleGroup)'")
            }
            for muscle in row.secondaryMuscles where Muscle(datasetValue: muscle) == nil {
                unresolved.append("\(row.id) secondary '\(muscle)'")
            }
        }
        #expect(unresolved.isEmpty, "unmapped muscle strings: \(unresolved.prefix(10))")
    }

    @Test("Secondary muscles never repeat the target or the synergist")
    func secondaryMusclesAreDeduplicated() {
        for exercise in ExerciseDatasetFixture.exercises {
            var seen: Set<Muscle> = [exercise.target]
            if let synergist = exercise.synergist { seen.insert(synergist) }
            let overlap = exercise.secondaryMuscles.filter { seen.contains($0) }
            #expect(overlap.isEmpty, "\(exercise.id) repeats \(overlap) in its secondary muscles")
        }
    }

    @Test("Every exercise carries a non-empty attribution matching the manifest")
    func everyExerciseCarriesAttribution() throws {
        let manifest = try #require(ExerciseDatasetFixture.manifest)
        let blank = ExerciseDatasetFixture.exercises.filter {
            $0.attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        #expect(blank.isEmpty, "\(blank.count) exercises ship with no attribution string")

        let mismatched = ExerciseDatasetFixture.exercises.filter { $0.attribution != manifest.mediaAttribution }
        #expect(
            mismatched.isEmpty,
            "\(mismatched.count) exercises carry an attribution other than the manifest's"
        )
    }

    @Test("Every createdAt timestamp parses instead of falling back to the epoch")
    func everyCreatedAtParses() {
        let epoch = Date(timeIntervalSince1970: 0)
        let unparsed = ExerciseDatasetFixture.exercises.filter { $0.createdAt == epoch }.map(\.id)
        #expect(unparsed.isEmpty, "\(unparsed.count) exercises fell back to the epoch: \(unparsed.prefix(10))")
    }
}

// MARK: - Media

@Suite("Bundled exercise media")
struct ExerciseMediaIntegrityTests {

    @Test("Every exercise names a thumbnail and an animation file")
    func everyExerciseNamesItsMedia() {
        let blank = ExerciseDatasetFixture.exercises.filter {
            $0.thumbnailFileName.isEmpty || $0.animationFileName.isEmpty || $0.mediaID.isEmpty
        }.map(\.id)
        #expect(blank.isEmpty, "\(blank.count) exercises have a blank media reference: \(blank.prefix(10))")
    }

    @Test("Media file names follow the id-mediaID convention")
    func mediaFileNamesFollowTheConvention() {
        let wrong = ExerciseDatasetFixture.exercises.filter {
            $0.thumbnailFileName != "\($0.id)-\($0.mediaID).jpg"
                || $0.animationFileName != "\($0.id)-\($0.mediaID).gif"
        }.map(\.id)
        #expect(wrong.isEmpty, "\(wrong.count) exercises break the media naming convention: \(wrong.prefix(10))")
    }

    @Test("Every one of the 1,324 thumbnails exists in the bundle")
    func everyThumbnailFileExists() {
        let provider = ExerciseDatasetFixture.mediaProvider
        let missing = ExerciseDatasetFixture.exercises
            .filter { provider.thumbnailURL(for: $0) == nil }
            .map { "\($0.id) → \($0.thumbnailFileName)" }
        #expect(missing.isEmpty, "\(missing.count) thumbnails are missing from the bundle: \(missing.prefix(10))")
    }

    @Test("Every one of the 1,324 animations exists in the bundle")
    func everyAnimationFileExists() {
        let provider = ExerciseDatasetFixture.mediaProvider
        let missing = ExerciseDatasetFixture.exercises
            .filter { provider.animationURL(for: $0) == nil }
            .map { "\($0.id) → \($0.animationFileName)" }
        #expect(missing.isEmpty, "\(missing.count) animations are missing from the bundle: \(missing.prefix(10))")
    }

    @Test("Media file names are unique, so no two exercises share artwork")
    func mediaFileNamesAreUnique() {
        let thumbnails = Set(ExerciseDatasetFixture.exercises.map(\.thumbnailFileName))
        let animations = Set(ExerciseDatasetFixture.exercises.map(\.animationFileName))
        #expect(thumbnails.count == ExerciseDatasetFixture.exercises.count)
        #expect(animations.count == ExerciseDatasetFixture.exercises.count)
    }

    @Test("The bundled media provider surfaces the mandatory copyright line")
    func providerCarriesAttribution() throws {
        let provider = ExerciseDatasetFixture.mediaProvider
        let attribution = try #require(provider.attribution)
        #expect(!attribution.isEmpty)
        #expect(provider.attributionURL != nil)
    }

    @Test("A provider pointed at a bundle with no media returns no URLs instead of failing")
    func missingMediaRootDegradesGracefully() throws {
        let provider = BundledExerciseMediaProvider(bundle: try ExerciseDatasetFixture.emptyBundle())
        let exercise = try ExerciseDatasetFixture.exercise(id: "0025")
        #expect(provider.thumbnailURL(for: exercise) == nil)
        #expect(provider.animationURL(for: exercise) == nil)
    }

    @Test("The empty provider is a safe stand-in with no artwork and no attribution")
    func emptyProviderReturnsNothing() throws {
        let provider = EmptyExerciseMediaProvider()
        let exercise = try ExerciseDatasetFixture.exercise(id: "0025")
        #expect(provider.thumbnailURL(for: exercise) == nil)
        #expect(provider.animationURL(for: exercise) == nil)
        #expect(provider.attribution == nil)
        #expect(provider.attributionURL == nil)
    }
}

// MARK: - Instructions

@Suite("Bundled exercise instructions")
struct ExerciseInstructionStoreTests {

    /// A spread across the id space plus the exercises the other suites assert by name.
    private static let sampleIDs = ["0001", "0025", "0043", "0294", "0472", "0685", "2612", "3236"]

    private func store() -> ExerciseInstructionStore {
        ExerciseInstructionStore(bundle: ExerciseDatasetFixture.appBundle)
    }

    @Test("Instructions load in all ten languages for a sample of exercises")
    func instructionsLoadForEveryLanguage() async {
        let store = store()
        for language in AppLanguage.allCases {
            for id in Self.sampleIDs {
                let steps = await store.steps(for: id, language: language)
                #expect(!steps.isEmpty, "no \(language.rawValue) instructions for exercise \(id)")
                let blank = steps.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                #expect(blank.isEmpty, "\(language.rawValue)/\(id) contains a blank instruction step")
            }
        }
    }

    @Test("A non-English language returns text that is not merely the English fallback")
    func translationsAreActuallyTranslated() async {
        let store = store()
        let english = await store.steps(for: "0025", language: .english)
        for language in AppLanguage.allCases where language != .english {
            let translated = await store.steps(for: "0025", language: language)
            #expect(!translated.isEmpty)
            #expect(translated != english, "\(language.rawValue) instructions are identical to English")
        }
    }

    @Test("An unknown exercise id returns no instructions rather than crashing")
    func unknownIdentifierReturnsEmpty() async {
        let store = store()
        for language in AppLanguage.allCases {
            let steps = await store.steps(for: "no-such-exercise-id", language: language)
            #expect(steps.isEmpty, "\(language.rawValue) returned steps for an unknown id")
        }
        #expect(await store.steps(for: "", language: .english).isEmpty)
    }

    @Test("Purging a cached language leaves later lookups working")
    func purgeKeepsLookupsWorking() async {
        let store = store()
        await store.preload(.spanish)
        let before = await store.steps(for: "0025", language: .spanish)
        await store.purge(keeping: .english)
        let after = await store.steps(for: "0025", language: .spanish)
        #expect(!before.isEmpty)
        #expect(after == before)
    }

    @Test("A bundle with no instruction files yields empty steps instead of failing")
    func missingInstructionFilesDegradeGracefully() async throws {
        let store = ExerciseInstructionStore(bundle: try ExerciseDatasetFixture.emptyBundle())
        for language in AppLanguage.allCases {
            #expect(await store.steps(for: "0025", language: language).isEmpty)
        }
    }
}
