import Foundation

/// Normalises exercise names into comparable tokens.
///
/// Used by both the metadata deriver (keyword rules) and the search index (matching). Keeping the
/// two on the same tokenizer means a name that classifies as "incline" is also findable by typing
/// "incline".
enum ExerciseNameTokenizer {
    /// Lowercases, strips diacritics and collapses punctuation to spaces.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Normalised whitespace-separated tokens.
    static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// Normalised name with single spaces, padded so `contains(" word ")` cannot match mid-token.
    static func paddedNormalized(_ text: String) -> String {
        " " + normalize(text) + " "
    }
}

/// Convenience matcher over a padded normalised name.
struct NameMatcher {
    let padded: String
    let tokenSet: Set<String>

    init(_ name: String) {
        self.padded = ExerciseNameTokenizer.paddedNormalized(name)
        self.tokenSet = Set(ExerciseNameTokenizer.tokens(name))
    }

    /// True when the name contains any of the given whole words or phrases.
    ///
    /// Matching is plural-tolerant: a phrase also matches its `-s` and `-es` forms, so a single
    /// rule for "hip thrust" catches "hip thrusts" and one for "press" catches "presses". The
    /// dataset spells the same movement both ways, and missing a plural silently mis-classifies
    /// the exercise rather than failing loudly.
    func has(_ phrases: String...) -> Bool { has(phrases) }

    func has(_ phrases: [String]) -> Bool {
        for phrase in phrases {
            let stem = ExerciseNameTokenizer.normalize(phrase)
            if padded.contains(" " + stem + " ") { return true }
            if padded.contains(" " + stem + "s ") { return true }
            if padded.contains(" " + stem + "es ") { return true }
        }
        return false
    }

    var wordCount: Int { tokenSet.count }
}
