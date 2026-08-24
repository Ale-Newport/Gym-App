import Foundation
import Observation

// MARK: - Sorting

/// How the library orders what it shows.
enum ExerciseSortOrder: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Alphabetical. The only order that can carry the A–Z section index, because the index is a
    /// promise about where a name sits in the list.
    case name
    /// Search rank while a query is active; "how central is this movement" when it is not.
    case relevance
    case mostUsed
    case favoritesFirst

    var id: String { rawValue }
    var localizationKey: String { "exercises.sort.\(rawValue)" }

    var symbolName: String {
        switch self {
        case .name: "textformat.abc"
        case .relevance: "sparkles"
        case .mostUsed: "flame.fill"
        case .favoritesFirst: "heart.fill"
        }
    }
}

// MARK: - Filters

/// Every filter the library offers, combined with AND across dimensions and OR inside one.
///
/// Selecting "barbell" and "dumbbell" means *either* implement, while adding "chest" narrows both —
/// which is the behaviour every filter UI on a phone has trained people to expect.
struct ExerciseFilterState: Hashable, Sendable {
    var bodyParts: Set<BodyPart> = []
    var muscleGroups: Set<MuscleGroup> = []
    var equipment: Set<Equipment> = []
    var difficulties: Set<Difficulty> = []
    /// `nil` means "compound or isolation, no preference".
    var mechanic: Mechanic?
    var bodyweightOnly = false
    var favoritesOnly = false
    var recentlyPerformedOnly = false

    /// Number of active constraints, shown on the filter button so the user can see at a glance
    /// that the list they are looking at is not the whole catalogue.
    var activeCount: Int {
        var count = bodyParts.count + muscleGroups.count + equipment.count + difficulties.count
        if mechanic != nil { count += 1 }
        if bodyweightOnly { count += 1 }
        if favoritesOnly { count += 1 }
        if recentlyPerformedOnly { count += 1 }
        return count
    }

    var isActive: Bool { activeCount > 0 }

    mutating func clear() { self = ExerciseFilterState() }
}

/// How many catalogue records sit behind each filter option.
///
/// Derived from the catalogue rather than hard-coded, so the sheet can never offer a filter that
/// returns nothing, and so the numbers stay honest after a dataset update.
struct ExerciseFacetCounts: Sendable {
    var bodyParts: [BodyPart: Int] = [:]
    var muscleGroups: [MuscleGroup: Int] = [:]
    var equipment: [Equipment: Int] = [:]
    var difficulties: [Difficulty: Int] = [:]
    var mechanics: [Mechanic: Int] = [:]
    var bodyweight = 0
    var favorites = 0
    var recentlyPerformed = 0
}

// MARK: - List model

/// One row of the library, already resolved against the user's preferences.
///
/// Deliberately carries raw values rather than finished strings: the row view formats the date with
/// the environment's `DisplayFormatter`, so a unit or language change re-renders without the view
/// model having to rebuild anything.
struct ExerciseRowItem: Identifiable, Hashable, Sendable {
    let exercise: Exercise
    let isFavorite: Bool
    let isExcluded: Bool
    let timesPerformed: Int
    let lastPerformedAt: Date?
    /// The section this row belongs to. Part of the identity, not decoration — see `id`.
    let sectionID: String

    /// Unique **within the whole list**, not just within its section.
    ///
    /// A favourite that was trained yesterday legitimately appears three times: under Recently
    /// performed, under Favourites, and under its letter. All three sections live in one
    /// `LazyVStack`, and SwiftUI requires identities to be unique across the entire hierarchy — with
    /// a bare `exercise.id` the duplicates collapsed and whole sections rendered as blank space
    /// while still reserving their height.
    var id: String { "\(sectionID)#\(exercise.id)" }
    var exerciseID: String { exercise.id }
}

/// One section of the library list.
struct ExerciseListSection: Identifiable, Hashable, Sendable {
    let id: String
    /// Localisation key for the heading. `nil` for index-letter headings, which are not translatable.
    let titleKey: String?
    let literalTitle: String?
    /// Letter shown in the A–Z index, when this section participates in it.
    let indexTitle: String?
    let items: [ExerciseRowItem]
}

// MARK: - View model

/// Drives the exercise library and the reusable picker.
///
/// The whole catalogue — 1,324 records — is held in memory by `ExerciseCatalog`, so filtering is a
/// single pass over value types with set lookups and no allocation per rejected record. That is
/// what makes per-keystroke search viable without a debounce: `refresh()` costs well under a
/// millisecond, and the alternative (waiting 250 ms before showing results) is perceptibly worse.
///
/// The user's opinions arrive as `ExercisePreference` rows from a `@Query` in the view rather than
/// through a fetch here, so favouriting an exercise on the detail screen updates the library behind
/// it with no refresh plumbing at all.
@MainActor
@Observable
final class ExerciseLibraryViewModel {

    /// Browsing groups into sections; picking is always one flat, ranked list, because a picker is
    /// opened with a specific exercise in mind and section headings only get in the way.
    enum Mode {
        case browse
        case picker
    }

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    // Inputs the view binds to.
    var searchText = ""
    var filters = ExerciseFilterState()
    var sort: ExerciseSortOrder = .name

    private(set) var phase: Phase = .loading
    private(set) var sections: [ExerciseListSection] = []
    /// Rows currently listed, after search and filters.
    private(set) var resultCount = 0
    /// Size of the whole catalogue, used in the search prompt.
    private(set) var catalogCount = 0
    private(set) var facets = ExerciseFacetCounts()

    /// Values present in the catalogue, in a stable order, for the filter sheet.
    private(set) var availableBodyParts: [BodyPart] = []
    private(set) var availableMuscleGroups: [MuscleGroup] = []
    private(set) var availableEquipment: [Equipment] = []

    let mode: Mode

    private var catalog: ExerciseCatalog?
    private var exercises: [Exercise] = []
    private var preferences: [String: ExercisePreferenceSnapshot] = [:]
    /// Most recently performed first.
    private var recentIDs: [String] = []
    private var favoriteIDs: [String] = []
    private var recentSet: Set<String> = []
    private var favoriteSet: Set<String> = []

    /// How many recently performed exercises the pinned section shows. Twelve is about four screens
    /// of scrolling away from the top — enough to be a shortcut, short enough to stay one.
    private static let recentSectionLimit = 12

    init(mode: Mode = .browse) {
        self.mode = mode
    }

    // MARK: - Loading

    /// Binds the catalogue and the user's stored opinions, then builds the first list.
    ///
    /// Cheap enough to call again whenever the preference rows change: everything it does is an
    /// in-memory pass, and it is the only place the two sources are combined.
    func load(catalog: ExerciseCatalog, preferences rows: [ExercisePreference]) {
        self.catalog = catalog

        switch catalog.state {
        case .idle, .loading:
            phase = .loading
            return
        case .failed(let message):
            phase = .failed(message)
            return
        case .loaded:
            break
        }

        // Assigning is O(1): the catalogue's array is copy-on-write and nothing here mutates it.
        exercises = catalog.exercises
        catalogCount = exercises.count
        availableBodyParts = catalog.availableBodyParts
        availableMuscleGroups = catalog.availableMuscleGroups
        availableEquipment = catalog.availableEquipment

        apply(preferenceRows: rows)
        phase = .ready
        refresh()
    }

    /// Retries whatever failed. The only recoverable failure here is the catalogue itself; the
    /// preference rows come from a live query and cannot fail independently.
    func retry(preferences rows: [ExercisePreference]) async {
        guard let catalog else { return }
        phase = .loading
        await catalog.load()
        load(catalog: catalog, preferences: rows)
    }

    private func apply(preferenceRows rows: [ExercisePreference]) {
        preferences = Dictionary(
            rows.map { ($0.exerciseID, ExercisePreferenceRepository.snapshot(of: $0)) }
        ) { first, _ in first }

        favoriteIDs = rows
            .filter(\.isFavorite)
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.exerciseID)

        recentIDs = rows
            .compactMap { row in row.lastPerformedAt.map { (row.exerciseID, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(Self.recentSectionLimit)
            .map(\.0)

        favoriteSet = Set(favoriteIDs)
        recentSet = Set(recentIDs)

        facets = makeFacets()
    }

    // MARK: - Refreshing the list

    /// Anything the list depends on. The view watches this so one `onChange` covers search, filters
    /// and sort without three separate observers falling out of step.
    struct InputSignature: Equatable {
        var query: String
        var filters: ExerciseFilterState
        var sort: ExerciseSortOrder
    }

    var inputSignature: InputSignature {
        InputSignature(query: searchText, filters: filters, sort: sort)
    }

    var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSearching: Bool { !trimmedQuery.isEmpty }

    /// True when nothing survived the current search and filters.
    var hasNoResults: Bool { phase == .ready && resultCount == 0 }

    /// Rebuilds the sections from the current query, filters and sort order.
    func refresh() {
        guard phase == .ready else { return }

        let query = trimmedQuery
        // `ExerciseCatalog.search` already ranks exact name, name prefix, name substring, muscle,
        // equipment, body part and derived tags, so the library never re-implements matching.
        let base = query.isEmpty ? exercises : (catalog?.search(query) ?? [])
        let matched = base.filter(matches)
        resultCount = matched.count

        // Sections only make sense over the complete, alphabetically ordered catalogue. A search
        // result is already ranked by how well it answers the query, and re-grouping it by first
        // letter would throw that ranking away.
        let wantsSections = mode == .browse && query.isEmpty && sort == .name
        sections = wantsSections ? groupedSections(from: matched) : [flatSection(from: matched)]
    }

    /// The number of exercises a candidate filter set would show. Used by the filter sheet to label
    /// its dismiss button, so the user commits to a number rather than to a guess.
    func matchCount(for candidate: ExerciseFilterState) -> Int {
        let query = trimmedQuery
        let base = query.isEmpty ? exercises : (catalog?.search(query) ?? [])
        return base.reduce(into: 0) { total, exercise in
            if matches(exercise, candidate) { total += 1 }
        }
    }

    func clearFilters() {
        filters.clear()
        refresh()
    }

    func clearSearchAndFilters() {
        searchText = ""
        filters.clear()
        refresh()
    }

    // MARK: - Filtering

    private func matches(_ exercise: Exercise) -> Bool {
        matches(exercise, filters)
    }

    private func matches(_ exercise: Exercise, _ state: ExerciseFilterState) -> Bool {
        if !state.bodyParts.isEmpty, !state.bodyParts.contains(exercise.bodyPart) { return false }
        // Primary group only. Matching every group an exercise touches would surface barbell rows
        // under "biceps", which is true but not what somebody browsing for a curl means — and it
        // would also make the counts in the filter sheet disagree with the list.
        if !state.muscleGroups.isEmpty, !state.muscleGroups.contains(exercise.primaryGroup) { return false }
        if !state.equipment.isEmpty, !state.equipment.contains(exercise.equipment) { return false }
        if !state.difficulties.isEmpty, !state.difficulties.contains(exercise.metadata.difficulty) { return false }
        if let mechanic = state.mechanic, exercise.metadata.mechanic != mechanic { return false }
        if state.bodyweightOnly, exercise.equipment != .bodyWeight { return false }
        if state.favoritesOnly, !favoriteSet.contains(exercise.id) { return false }
        if state.recentlyPerformedOnly, !recentSet.contains(exercise.id) { return false }
        return true
    }

    // MARK: - Section building

    private func groupedSections(from matched: [Exercise]) -> [ExerciseListSection] {
        var result: [ExerciseListSection] = []
        let byID = Dictionary(matched.map { ($0.id, $0) }) { first, _ in first }

        let recent = recentIDs.compactMap { byID[$0] }
        if !recent.isEmpty {
            result.append(ExerciseListSection(
                id: "recent",
                titleKey: "exercises.section.recent",
                literalTitle: nil,
                indexTitle: nil,
                items: recent.map { makeItem($0, in: "recent") }
            ))
        }

        let favorites = favoriteIDs.compactMap { byID[$0] }
        if !favorites.isEmpty {
            result.append(ExerciseListSection(
                id: "favorites",
                titleKey: "exercises.section.favorites",
                literalTitle: nil,
                indexTitle: nil,
                items: favorites.map { makeItem($0, in: "favorites") }
            ))
        }

        // The alphabetical run is the complete filtered catalogue, including anything already shown
        // above: the pinned sections are shortcuts, not a partition, and a user scanning for "Bench
        // press" under B must find it whether or not they trained it yesterday.
        var letters: [String] = []
        var buckets: [String: [Exercise]] = [:]
        for exercise in matched {
            let letter = Self.indexLetter(for: exercise.name)
            if buckets[letter] == nil {
                buckets[letter] = []
                letters.append(letter)
            }
            buckets[letter]?.append(exercise)
        }
        // `matched` arrives alphabetically from the catalogue, so first-seen order is already A–Z
        // with "#" wherever a non-letter name sorts.
        for letter in letters {
            guard let bucket = buckets[letter] else { continue }
            result.append(ExerciseListSection(
                id: "letter-\(letter)",
                titleKey: nil,
                literalTitle: letter,
                indexTitle: letter,
                items: bucket.map { makeItem($0, in: "letter-\(letter)") }
            ))
        }
        return result
    }

    private func flatSection(from matched: [Exercise]) -> ExerciseListSection {
        ExerciseListSection(
            id: "results",
            titleKey: mode == .picker ? nil : "exercises.section.results",
            literalTitle: nil,
            indexTitle: nil,
            items: sorted(matched).map { makeItem($0, in: "results") }
        )
    }

    /// Applies the sort order. `relevance` is a no-op while searching because the search index has
    /// already ordered the result by match quality.
    private func sorted(_ matched: [Exercise]) -> [Exercise] {
        switch sort {
        case .name:
            return isSearching
                ? matched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                : matched
        case .relevance:
            guard !isSearching else { return matched }
            return matched.sorted { lhs, rhs in
                if lhs.metadata.stapleScore != rhs.metadata.stapleScore {
                    return lhs.metadata.stapleScore > rhs.metadata.stapleScore
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .mostUsed:
            return matched.sorted { lhs, rhs in
                let left = preferences[lhs.id]?.timesPerformed ?? 0
                let right = preferences[rhs.id]?.timesPerformed ?? 0
                if left != right { return left > right }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .favoritesFirst:
            return matched.sorted { lhs, rhs in
                let left = favoriteSet.contains(lhs.id)
                let right = favoriteSet.contains(rhs.id)
                if left != right { return left }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// Builds one row. `sectionID` is threaded through because it forms part of the row's identity:
    /// the same exercise legitimately appears in several sections at once.
    private func makeItem(_ exercise: Exercise, in sectionID: String) -> ExerciseRowItem {
        let preference = preferences[exercise.id]
        return ExerciseRowItem(
            exercise: exercise,
            isFavorite: preference?.isFavorite ?? false,
            isExcluded: preference?.isExcluded ?? false,
            timesPerformed: preference?.timesPerformed ?? 0,
            lastPerformedAt: preference?.lastPerformedAt,
            sectionID: sectionID
        )
    }

    /// First letter of a name, folded to ASCII so "Ćwiczenie" indexes under C rather than under a
    /// letter the index bar does not show. Anything that is not a letter collects under "#".
    private static func indexLetter(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let first = folded.first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    /// Letters currently present, in list order, for the A–Z index bar.
    var indexTitles: [String] {
        sections.compactMap(\.indexTitle)
    }

    // MARK: - Facets

    private func makeFacets() -> ExerciseFacetCounts {
        var counts = ExerciseFacetCounts()
        for exercise in exercises {
            counts.bodyParts[exercise.bodyPart, default: 0] += 1
            counts.muscleGroups[exercise.primaryGroup, default: 0] += 1
            counts.equipment[exercise.equipment, default: 0] += 1
            counts.difficulties[exercise.metadata.difficulty, default: 0] += 1
            counts.mechanics[exercise.metadata.mechanic, default: 0] += 1
            if exercise.equipment == .bodyWeight { counts.bodyweight += 1 }
        }
        counts.favorites = favoriteSet.count
        counts.recentlyPerformed = recentSet.count
        return counts
    }
}
