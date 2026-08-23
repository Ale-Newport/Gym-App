import Foundation
import Combine

/// Central string lookup.
///
/// Every user-visible string in the app resolves through here rather than through SwiftUI's
/// implicit `Text("key")` lookup. The reason is the in-app language override in Settings: SwiftUI's
/// implicit lookup always follows the *system* language, so honouring a manual override requires
/// pointing lookups at a specific `.lproj` bundle. `LocalizationManager` owns that bundle and
/// publishes changes, which re-renders the whole UI when the user switches language.
@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    /// `nil` means "follow the device language".
    @Published private(set) var override: AppLanguage?
    @Published private(set) var current: AppLanguage

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
        let value = bundle.localizedString(forKey: key, value: Self.missing, table: nil)
        if value != Self.missing { return value }
        if current != .english, let english = Self.bundle(for: .english) {
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
