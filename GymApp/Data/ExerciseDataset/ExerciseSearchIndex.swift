import Foundation

/// A precomputed, diacritic- and case-insensitive index over the catalogue.
///
/// Building it costs a single pass at launch; querying is then a linear scan over compact
/// pre-normalised strings, which keeps typing responsive across 1,324 records without any
/// per-keystroke allocation of normalised forms.
struct ExerciseSearchIndex: Sendable {

    /// One row of the index. Everything is pre-normalised so a query never re-folds catalogue text.
    struct Entry: Sendable {
        let id: String
        let normalizedName: String
        let nameTokens: [String]
        /// Target, synergist and secondary muscle names, plus the muscle group.
        let muscleTerms: [String]
        let equipmentTerm: String
        let bodyPartTerm: String
        let tagTerms: [String]
        let stapleScore: Double
    }

    /// Where a query matched, best first. Determines result ordering.
    enum MatchKind: Int, Comparable, Sendable {
        case exactName = 0
        case namePrefix = 1
        case nameTokenPrefix = 2
        case nameSubstring = 3
        case muscle = 4
        case equipment = 5
        case bodyPart = 6
        case tag = 7

        static func < (lhs: MatchKind, rhs: MatchKind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private let entries: [Entry]

    init(exercises: [Exercise]) {
        entries = exercises.map { exercise in
            let normalized = ExerciseNameTokenizer.normalize(exercise.name)
            var muscles: [String] = []
            for muscle in exercise.allMuscles {
                muscles.append(ExerciseNameTokenizer.normalize(muscle.rawValue))
                muscles.append(ExerciseNameTokenizer.normalize(muscle.group.rawValue))
            }
            return Entry(
                id: exercise.id,
                normalizedName: normalized,
                nameTokens: normalized.split(separator: " ").map(String.init),
                muscleTerms: Array(Set(muscles)),
                equipmentTerm: ExerciseNameTokenizer.normalize(exercise.equipment.rawValue),
                bodyPartTerm: ExerciseNameTokenizer.normalize(exercise.bodyPart.rawValue),
                tagTerms: Array(exercise.metadata.substitutionTags),
                stapleScore: exercise.metadata.stapleScore
            )
        }
    }

    /// Returns matching exercise ids, best match first.
    ///
    /// Multi-word queries require **every** word to match somewhere, which is what makes
    /// "cable incline fly" behave the way a user expects. The result's rank is the best (lowest)
    /// match kind across the words, with the staple score breaking ties.
    func search(_ query: String, limit: Int = 400) -> [String] {
        let normalizedQuery = ExerciseNameTokenizer.normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }
        let words = normalizedQuery.split(separator: " ").map(String.init)

        var scored: [(id: String, kind: MatchKind, staple: Double, length: Int)] = []
        scored.reserveCapacity(64)

        for entry in entries {
            var worstKind = MatchKind.exactName
            var matchedAll = true

            // Whole-phrase matches are strongest and are checked first.
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
            scored.append((entry.id, worstKind, entry.stapleScore, entry.normalizedName.count))
        }

        scored.sort { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            if lhs.staple != rhs.staple { return lhs.staple > rhs.staple }
            return lhs.length < rhs.length
        }
        return scored.prefix(limit).map(\.id)
    }

    private func match(word: String, in entry: Entry) -> MatchKind? {
        if entry.normalizedName == word { return .exactName }
        if entry.normalizedName.hasPrefix(word) { return .namePrefix }
        for token in entry.nameTokens where token.hasPrefix(word) { return .nameTokenPrefix }
        if entry.normalizedName.contains(word) { return .nameSubstring }
        for term in entry.muscleTerms where term.hasPrefix(word) || term.contains(word) { return .muscle }
        if entry.equipmentTerm.contains(word) { return .equipment }
        if entry.bodyPartTerm.contains(word) { return .bodyPart }
        for tag in entry.tagTerms where tag.contains(word) { return .tag }
        return nil
    }
}
