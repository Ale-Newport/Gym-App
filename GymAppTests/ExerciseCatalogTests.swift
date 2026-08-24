import Foundation
import Testing
@testable import GymApp

// MARK: - Loading

@MainActor
@Suite("Exercise catalogue loading")
struct ExerciseCatalogLoadingTests {

    private func isFailed(_ state: ExerciseCatalog.LoadState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    @Test("A brand-new catalogue is idle and answers every query emptily")
    func idleCatalogueIsEmptyButUsable() {
        let catalog = ExerciseCatalog(importer: ExerciseDatasetFixture.importer)
        #expect(catalog.state == .idle)
        #expect(catalog.isLoaded == false)
        #expect(catalog.count == 0)
        #expect(catalog.exercise(id: "0025") == nil)
        #expect(catalog.search("bench press").isEmpty)
        #expect(catalog.availableEquipment.isEmpty)
        #expect(catalog.availableBodyParts.isEmpty)
        #expect(catalog.availableTargets.isEmpty)
        #expect(catalog.availableMuscleGroups.isEmpty)
        #expect(catalog.datasetVersion == "unknown")
        #expect(!catalog.mediaAttribution.isEmpty, "the attribution must survive even without a manifest")
    }

    @Test("Loading from the app bundle produces the whole catalogue")
    func loadFromBundleSucceeds() async throws {
        let catalog = ExerciseCatalog(importer: ExerciseDatasetFixture.importer)
        await catalog.load()

        #expect(catalog.state == .loaded)
        #expect(catalog.isLoaded)
        let manifest = try #require(catalog.manifest)
        #expect(catalog.count == manifest.exerciseCount)
        #expect(catalog.count == 1324)
        #expect(catalog.datasetVersion == manifest.datasetVersion)
        #expect(catalog.mediaAttribution == manifest.mediaAttribution)
    }

    @Test("Loading twice does not duplicate the catalogue")
    func loadIsIdempotent() async {
        let catalog = ExerciseCatalog(importer: ExerciseDatasetFixture.importer)
        await catalog.load()
        let first = catalog.count
        await catalog.load()
        #expect(catalog.count == first)
    }

    @Test("A catalogue whose dataset is missing reports failure instead of crashing")
    func failedLoadIsReportedAndLeavesTheCatalogueSafe() async throws {
        let importer = ExerciseDatasetImporter(bundle: try ExerciseDatasetFixture.emptyBundle())
        let catalog = ExerciseCatalog(importer: importer)
        await catalog.load()

        #expect(isFailed(catalog.state), "expected .failed but got \(catalog.state)")
        #expect(catalog.isLoaded == false)
        #expect(catalog.count == 0)
        #expect(catalog.exercise(id: "0025") == nil)
        #expect(catalog.search("bench press").isEmpty)
        #expect(catalog.availableEquipment.isEmpty)
        #expect(catalog.datasetVersion == "unknown")
    }

    @Test("Injecting a catalogue directly marks it loaded")
    func applyMarksTheCatalogueLoaded() {
        let catalog = ExerciseCatalog(importer: ExerciseDatasetFixture.importer)
        catalog.apply(exercises: ExerciseDatasetFixture.exercises, manifest: ExerciseDatasetFixture.manifest)
        #expect(catalog.isLoaded)
        #expect(catalog.count == ExerciseDatasetFixture.exercises.count)
    }

    @Test("Injecting an empty catalogue leaves every lookup empty rather than failing")
    func applyingNothingIsSafe() {
        let catalog = ExerciseCatalog(importer: ExerciseDatasetFixture.importer)
        catalog.apply(exercises: [], manifest: nil)
        #expect(catalog.count == 0)
        #expect(catalog.search("bench press").isEmpty)
        #expect(catalog.exercises(targeting: .pectorals).isEmpty)
        #expect(catalog.exercises(primaryGroup: .chest).isEmpty)
        #expect(catalog.exercises(using: .barbell).isEmpty)
        #expect(catalog.exercises(bodyPart: .chest).isEmpty)
        #expect(catalog.exercises(pattern: .horizontalPush).isEmpty)
        #expect(catalog.exercises(involving: .chest).isEmpty)
        #expect(catalog.availableEquipment.isEmpty)
        #expect(catalog.count(forEquipment: .barbell) == 0)
        #expect(catalog.count(forBodyPart: .chest) == 0)
        #expect(catalog.count(forGroup: .chest) == 0)
        #expect(catalog.datasetVersion == "unknown")
    }
}

// MARK: - Lookup

@MainActor
@Suite("Exercise catalogue lookup")
struct ExerciseCatalogLookupTests {

    private let catalog: ExerciseCatalog
    private let exercises: [Exercise]

    init() {
        exercises = ExerciseDatasetFixture.exercises
        catalog = ExerciseCatalog(importer: ExerciseDatasetFixture.importer)
        catalog.apply(exercises: exercises, manifest: ExerciseDatasetFixture.manifest)
    }

    @Test("Every exercise can be looked up by its id")
    func lookupByIDRoundTrips() {
        for exercise in exercises {
            #expect(catalog.exercise(id: exercise.id) == exercise, "\(exercise.id) is not retrievable by id")
        }
        #expect(catalog.exercise(id: "not-an-id") == nil)
        #expect(catalog.exercise(id: "") == nil)
    }

    @Test("Looking up a list of ids skips the ones that do not exist")
    func lookupByIDsSkipsUnknownIdentifiers() {
        let found = catalog.exercises(ids: ["0025", "not-an-id", "0043"])
        #expect(found.map(\.id) == ["0025", "0043"])
        #expect(catalog.exercises(ids: []).isEmpty)
        #expect(catalog.exercises(ids: ["nope"]).isEmpty)
    }

    @Test("The catalogue is sorted by name so lists render in a stable order")
    func catalogueIsSortedByName() {
        let names = catalog.exercises.map(\.name)
        let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #expect(names == sorted)
    }

    @Test("Lookup by target muscle agrees with the underlying records")
    func lookupByTargetAgreesWithTheData() {
        for muscle in Muscle.allCases {
            let expected = Set(exercises.filter { $0.target == muscle }.map(\.id))
            let actual = Set(catalog.exercises(targeting: muscle).map(\.id))
            #expect(actual == expected, "target \(muscle) disagrees with the data")
        }
    }

    @Test("Lookup by primary muscle group agrees with the underlying records")
    func lookupByGroupAgreesWithTheData() {
        for group in MuscleGroup.allCases {
            let expected = Set(exercises.filter { $0.primaryGroup == group }.map(\.id))
            let actual = Set(catalog.exercises(primaryGroup: group).map(\.id))
            #expect(actual == expected, "group \(group) disagrees with the data")
        }
    }

    @Test("Lookup by equipment agrees with the underlying records")
    func lookupByEquipmentAgreesWithTheData() {
        for equipment in Equipment.allCases {
            let expected = Set(exercises.filter { $0.equipment == equipment }.map(\.id))
            let actual = Set(catalog.exercises(using: equipment).map(\.id))
            #expect(actual == expected, "equipment \(equipment) disagrees with the data")
            #expect(catalog.count(forEquipment: equipment) == expected.count)
        }
    }

    @Test("Lookup by body part agrees with the underlying records")
    func lookupByBodyPartAgreesWithTheData() {
        for bodyPart in BodyPart.allCases {
            let expected = Set(exercises.filter { $0.bodyPart == bodyPart }.map(\.id))
            let actual = Set(catalog.exercises(bodyPart: bodyPart).map(\.id))
            #expect(actual == expected, "body part \(bodyPart) disagrees with the data")
            #expect(catalog.count(forBodyPart: bodyPart) == expected.count)
        }
    }

    @Test("Lookup by movement pattern agrees with the underlying records")
    func lookupByPatternAgreesWithTheData() {
        for pattern in MovementPattern.allCases {
            let expected = Set(exercises.filter { $0.metadata.movementPattern == pattern }.map(\.id))
            let actual = Set(catalog.exercises(pattern: pattern).map(\.id))
            #expect(actual == expected, "pattern \(pattern) disagrees with the data")
        }
    }

    @Test("Every exercise trains the group it is filed under")
    func involvedGroupsIncludeThePrimaryGroup() {
        for group in MuscleGroup.allCases {
            let involved = Set(catalog.exercises(involving: group).map(\.id))
            let primary = Set(
                catalog.exercises(primaryGroup: group)
                    .filter { !$0.metadata.volumeContribution.isEmpty }
                    .map(\.id)
            )
            #expect(primary.isSubset(of: involved), "\(group)'s primary exercises are not all counted as involving it")
            for exercise in catalog.exercises(involving: group) {
                #expect(exercise.metadata.volumeCredit(for: group) > 0)
            }
        }
    }

    @Test("Every exercise in the catalogue is reachable through at least one facet")
    func everyExerciseIsReachableThroughEveryFacet() {
        let byTarget = Set(Muscle.allCases.flatMap { catalog.exercises(targeting: $0).map(\.id) })
        let byEquipment = Set(Equipment.allCases.flatMap { catalog.exercises(using: $0).map(\.id) })
        let byBodyPart = Set(BodyPart.allCases.flatMap { catalog.exercises(bodyPart: $0).map(\.id) })
        let byGroup = Set(MuscleGroup.allCases.flatMap { catalog.exercises(primaryGroup: $0).map(\.id) })
        let all = Set(exercises.map(\.id))
        #expect(byTarget == all)
        #expect(byEquipment == all)
        #expect(byBodyPart == all)
        #expect(byGroup == all)
    }
}

// MARK: - Distinct values

@MainActor
@Suite("Exercise catalogue availability")
struct ExerciseCatalogAvailabilityTests {

    private let catalog: ExerciseCatalog
    private let exercises: [Exercise]

    init() {
        exercises = ExerciseDatasetFixture.exercises
        catalog = ExerciseCatalog(importer: ExerciseDatasetFixture.importer)
        catalog.apply(exercises: exercises, manifest: ExerciseDatasetFixture.manifest)
    }

    @Test("availableEquipment contains exactly the equipment at least one exercise uses")
    func availableEquipmentMatchesTheData() {
        let used = Set(exercises.map(\.equipment))
        #expect(Set(catalog.availableEquipment) == used)
        for equipment in catalog.availableEquipment {
            #expect(catalog.count(forEquipment: equipment) > 0, "\(equipment) is offered but has no exercises")
        }
        #expect(catalog.availableEquipment.contains(.other) == false, "the fallback bucket must never be offered")
    }

    @Test("availableBodyParts contains exactly the body parts at least one exercise is filed under")
    func availableBodyPartsMatchTheData() {
        let used = Set(exercises.map(\.bodyPart))
        #expect(Set(catalog.availableBodyParts) == used)
        for bodyPart in catalog.availableBodyParts {
            #expect(catalog.count(forBodyPart: bodyPart) > 0)
        }
        #expect(catalog.availableBodyParts.contains(.other) == false)
    }

    @Test("availableTargets contains exactly the muscles at least one exercise targets")
    func availableTargetsMatchTheData() {
        let used = Set(exercises.map(\.target))
        #expect(Set(catalog.availableTargets) == used)
        for target in catalog.availableTargets {
            #expect(!catalog.exercises(targeting: target).isEmpty)
        }
    }

    @Test("availableMuscleGroups contains exactly the groups at least one exercise is filed under")
    func availableMuscleGroupsMatchTheData() {
        let used = Set(exercises.map(\.primaryGroup))
        #expect(Set(catalog.availableMuscleGroups) == used)
        for group in catalog.availableMuscleGroups {
            #expect(catalog.count(forGroup: group) > 0)
        }
    }

    @Test("Availability lists keep the canonical enum order so pickers are stable")
    func availabilityListsKeepEnumOrder() {
        let equipmentOrder = Equipment.allCases.filter { catalog.availableEquipment.contains($0) }
        #expect(catalog.availableEquipment == equipmentOrder)
        let bodyPartOrder = BodyPart.allCases.filter { catalog.availableBodyParts.contains($0) }
        #expect(catalog.availableBodyParts == bodyPartOrder)
    }

    @Test("Facet counts sum to the size of the catalogue")
    func facetCountsSumToTheCatalogue() {
        let equipmentTotal = Equipment.allCases.reduce(0) { $0 + catalog.count(forEquipment: $1) }
        let bodyPartTotal = BodyPart.allCases.reduce(0) { $0 + catalog.count(forBodyPart: $1) }
        let groupTotal = MuscleGroup.allCases.reduce(0) { $0 + catalog.count(forGroup: $1) }
        #expect(equipmentTotal == catalog.count)
        #expect(bodyPartTotal == catalog.count)
        #expect(groupTotal == catalog.count)
    }
}

// MARK: - Search through the catalogue

@MainActor
@Suite("Exercise catalogue search")
struct ExerciseCatalogSearchTests {

    private let catalog: ExerciseCatalog

    init() {
        catalog = ExerciseCatalog(importer: ExerciseDatasetFixture.importer)
        catalog.apply(exercises: ExerciseDatasetFixture.exercises, manifest: ExerciseDatasetFixture.manifest)
    }

    @Test("Searching an exact name through the catalogue returns that exercise first")
    func exactNameSearchReturnsTheExercise() {
        #expect(catalog.search("barbell bench press").first?.id == "0025")
        #expect(catalog.search("barbell full squat").first?.id == "0043")
    }

    @Test("Search returns whole records, all of which are in the catalogue")
    func searchReturnsRealRecords() {
        let results = catalog.search("kettlebell swing")
        #expect(!results.isEmpty)
        for exercise in results {
            #expect(catalog.exercise(id: exercise.id) != nil)
        }
    }

    @Test("Search honours its limit")
    func searchHonoursItsLimit() {
        #expect(catalog.search("press", limit: 10).count == 10)
        #expect(catalog.search("press", limit: 0).isEmpty)
    }

    @Test("An empty or nonsense search returns nothing")
    func emptyAndNonsenseSearchesReturnNothing() {
        #expect(catalog.search("").isEmpty)
        #expect(catalog.search("    ").isEmpty)
        #expect(catalog.search("qzxjvkwyb").isEmpty)
    }
}
