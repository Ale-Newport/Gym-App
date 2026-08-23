import Foundation

/// The ten languages the app ships in — the same ten the exercise dataset provides instructions
/// for. Adding an eleventh means: add a case here, add a column to `Tools/l10n/`, regenerate
/// `Localizable.xcstrings`, and provide `instructions.<code>.json`. See `README.md`.
enum AppLanguage: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case english = "en"
    case spanish = "es"
    case italian = "it"
    case turkish = "tr"
    case russian = "ru"
    case chinese = "zh"
    case hindi = "hi"
    case polish = "pl"
    case korean = "ko"
    case french = "fr"

    var id: String { rawValue }

    /// The `.lproj` folder name inside the app bundle. Chinese uses the script-qualified form.
    var bundleIdentifierCode: String {
        switch self {
        case .chinese: "zh-Hans"
        default: rawValue
        }
    }

    /// The key used inside the dataset's `instructions` map.
    var datasetCode: String { rawValue }

    /// Name of the language written in that language, as users expect to see it in a picker.
    var endonym: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        case .italian: "Italiano"
        case .turkish: "Türkçe"
        case .russian: "Русский"
        case .chinese: "中文"
        case .hindi: "हिन्दी"
        case .polish: "Polski"
        case .korean: "한국어"
        case .french: "Français"
        }
    }

    var locale: Locale { Locale(identifier: bundleIdentifierCode) }

    /// Resolves the language to use when the user has not chosen one explicitly: the first
    /// preferred system language the app supports, falling back to English.
    static func resolvedFromSystem(
        preferred: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        for identifier in preferred {
            let code = Locale(identifier: identifier).language.languageCode?.identifier ?? ""
            if let match = AppLanguage(rawValue: code) { return match }
        }
        return .english
    }
}
