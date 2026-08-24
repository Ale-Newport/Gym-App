import Foundation
import Observation

/// Central string lookup.
///
/// Every user-visible string in the app resolves through here rather than through SwiftUI's
/// implicit `Text("key")` lookup. The reason is the in-app language override in Settings: SwiftUI's
/// implicit lookup always follows the *system* language, so honouring a manual override requires
/// pointing lookups at a specific `.lproj` bundle.
///
/// It is `@Observable` rather than an `ObservableObject`, and that choice does real work. Because
/// `localized(_:)` reads observable state, every view that calls `L(_:)` inside its `body`
/// registers a dependency on the language automatically — no `@EnvironmentObject` to remember, and
/// no `.id()` on the root view. The `.id()` approach did re-render everything, but by *replacing*
/// the whole tree: switching language threw the user out of whatever screen they were on, which is
/// a strange thing for a settings toggle to do.
@MainActor
@Observable
final class LocalizationManager {
    @ObservationIgnored
    static let shared = LocalizationManager()

    /// `nil` means "follow the device language".
    private(set) var override: AppLanguage?
    private(set) var current: AppLanguage

    private var bundle: Bundle
    private static let defaultsKey = "settings.languageOverride"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        let overrideLanguage = stored.flatMap(AppLanguage.init(rawValue:))
        self.override = overrideLanguage
        let resolved = overrideLanguage ?? AppLanguage.resolvedFromSystem()
        self.current = resolved
        self.bundle = Self.bundle(for: resolved) ?? .main
    }

    /// Sets or clears the manual override. Passing `nil` returns to the device language.
    func setOverride(_ language: AppLanguage?) {
        override = language
        if let language {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        let resolved = language ?? AppLanguage.resolvedFromSystem()
        current = resolved
        bundle = Self.bundle(for: resolved) ?? .main
    }

    /// Looks up `key`. Falls back to the English table and then to the key itself, so a missing
    /// translation shows English text rather than a raw identifier.
    func localized(_ key: String) -> String {
        // Reading `current` here is what registers the observation dependency: a view that calls
        // `L(_:)` in its body is now re-evaluated when the language changes, and nothing else is.
        // Do not "optimise" this line away.
        let language = current
        let value = bundle.localizedString(forKey: key, value: Self.missing, table: nil)
        if value != Self.missing { return value }
        if language != .english, let english = Self.bundle(for: .english) {
            let fallback = english.localizedString(forKey: key, value: Self.missing, table: nil)
            if fallback != Self.missing { return fallback }
        }
        assertionFailure("Missing localization for key \(key)")
        return key
    }

    private static let missing = "\u{0}__missing__"

    private static func bundle(for language: AppLanguage) -> Bundle? {
        guard let path = Bundle.main.path(forResource: language.bundleIdentifierCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle
    }
}

// MARK: - Lookup helpers

/// Localises `key`. The single entry point for user-visible text.
@MainActor
func L(_ key: String) -> String {
    LocalizationManager.shared.localized(key)
}

/// Localises `key` and substitutes positional arguments (`%@`, `%lld`, `%.1f`, …).
@MainActor
func L(_ key: String, _ arguments: any CVarArg...) -> String {
    String(format: LocalizationManager.shared.localized(key), locale: LocalizationManager.shared.current.locale, arguments: arguments)
}

/// Localises a plural-aware key. The catalogue entry must declare plural variations keyed on the
/// first format argument.
@MainActor
func LPlural(_ key: String, _ count: Int) -> String {
    String(format: LocalizationManager.shared.localized(key), locale: LocalizationManager.shared.current.locale, count)
}
