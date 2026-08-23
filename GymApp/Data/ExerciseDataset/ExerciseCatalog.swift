import Foundation
import Observation

/// The in-memory, read-only exercise catalogue.
///
/// Deliberately not a SwiftData store. The catalogue is static reference data shipped with the app:
/// modelling it as 1,324 persistent rows would add migration risk, launch cost and query overhead
/// while buying nothing, because nothing about it ever changes on device. Everything the user
/// creates references an exercise by its stable dataset id instead.
///
/// The catalogue is loaded once at launch on a background task, then read from the main actor.
@MainActor
@Observable
final class ExerciseCatalog {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var exercises: [Exercise] = []
    private(set) var manifest: ExerciseDatasetManifest?

    private var byID: [String: Exercise] = [:]
    private var byTarget: [Muscle: [String]] = [:]
    private var byGroup: [MuscleGroup: [String]] = [:]
    private var byEquipment: [Equipment: [String]] = [:]
    private var byBodyPart: [BodyPart: [String]] = [:]
    private var byPattern: [MovementPattern: [String]] = [:]
    private var searchIndex: ExerciseSearchIndex?

    private let importer: ExerciseDatasetImporter

    init(importer: ExerciseDatasetImporter = ExerciseDatasetImporter()) {
        self.importer = importer
    }

    var isLoaded: Bool { state == .loaded }
    var count: Int { exercises.count }

    /// Copyright notice that must accompany every rendering of the bundled media.
    var mediaAttribution: String {
        manifest?.mediaAttribution ?? "© Gym visual — https://gymvisual.com/"
    }

    var datasetVersion: String { manifest?.datasetVersion ?? "unknown" }

    // MARK: - Loading

    func load() async {
        guard state == .idle || isFailed else { return }
        state = .loading

        let importer = self.importer
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> ([Exercise], ExerciseDatasetManifest) in
                let manifest = try importer.loadManifest()
                let exercises = try importer.loadExercises(expecting: manifest)
                return (exercises, manifest)
            }.value

            apply(exercises: result.0, manifest: result.1)
            state = .loaded
            AppLog.catalog.info("Catalogue loaded: \(self.exercises.count) exercises, dataset \(result.1.datasetVersion, privacy: .public)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            AppLog.catalog.error("Catalogue failed to load: \(message, privacy: .public)")
            state = .failed(message)
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Injects a catalogue directly. Used by previews and tests.
    func apply(exercises: [Exercise], manifest: ExerciseDatasetManifest?) {
        self.exercises = exercises.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.manifest = manifest

        byID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        byTarget = Dictionary(grouping: self.exercises, by: \.target).mapValues { $0.map(\.id) }
        byEquipment = Dictionary(grouping: self.exercises, by: \.equipment).mapValues { $0.map(\.id) }
        byBodyPart = Dictionary(grouping: self.exercises, by: \.bodyPart).mapValues { $0.map(\.id) }
        byPattern = Dictionary(grouping: self.exercises, by: \.metadata.movementPattern).mapValues { $0.map(\.id) }

        var groups: [MuscleGroup: [String]] = [:]
        for exercise in self.exercises {
            groups[exercise.primaryGroup, default: []].append(exercise.id)
        }
        byGroup = groups

        searchIndex = ExerciseSearchIndex(exercises: self.exercises)
        if state != .loaded { state = .loaded }
    }

    // MARK: - Lookup

    func exercise(id: String) -> Exercise? { byID[id] }

    func exercises(ids: [String]) -> [Exercise] { ids.compactMap { byID[$0] } }

    func exercises(targeting muscle: Muscle) -> [Exercise] { exercises(ids: byTarget[muscle] ?? []) }

    /// Every exercise whose **primary** target belongs to `group`.
    func exercises(primaryGroup group: MuscleGroup) -> [Exercise] { exercises(ids: byGroup[group] ?? []) }

    /// Every exercise that trains `group` at all, directly or indirectly.
    func exercises(involving group: MuscleGroup) -> [Exercise] {
        exercises.filter { $0.metadata.volumeCredit(for: group) > 0 }
    }

    func exercises(using equipment: Equipment) -> [Exercise] { exercises(ids: byEquipment[equipment] ?? []) }

    func exercises(bodyPart: BodyPart) -> [Exercise] { exercises(ids: byBodyPart[bodyPart] ?? []) }

    func exercises(pattern: MovementPattern) -> [Exercise] { exercises(ids: byPattern[pattern] ?? []) }

    /// Ranked search across name, muscles, equipment, body part and derived tags.
    func search(_ query: String, limit: Int = 400) -> [Exercise] {
        guard let searchIndex else { return [] }
        return exercises(ids: searchIndex.search(query, limit: limit))
    }

    // MARK: - Distinct values actually present in the catalogue

    /// Equipment values that at least one exercise uses. Derived from the data rather than
    /// hard-coded, so onboarding never offers equipment the catalogue cannot fill.
    var availableEquipment: [Equipment] {
        Equipment.allCases.filter { byEquipment[$0]?.isEmpty == false }
    }

    var availableBodyParts: [BodyPart] {
        BodyPart.allCases.filter { byBodyPart[$0]?.isEmpty == false }
    }

    var availableTargets: [Muscle] {
        Muscle.allCases.filter { byTarget[$0]?.isEmpty == false }
    }

    var availableMuscleGroups: [MuscleGroup] {
        MuscleGroup.allCases.filter { byGroup[$0]?.isEmpty == false }
    }

    func count(forEquipment equipment: Equipment) -> Int { byEquipment[equipment]?.count ?? 0 }
    func count(forBodyPart bodyPart: BodyPart) -> Int { byBodyPart[bodyPart]?.count ?? 0 }
    func count(forGroup group: MuscleGroup) -> Int { byGroup[group]?.count ?? 0 }
}
