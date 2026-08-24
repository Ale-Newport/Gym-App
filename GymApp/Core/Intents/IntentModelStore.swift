import Foundation
import SwiftData

/// Where an App Intent gets a `ModelContext`.
///
/// Two intents — logging a body weight and logging water — write to the store without opening the
/// app, because making someone unlock their phone and find a screen to record "500 ml" defeats the
/// point of asking Siri. Writing from an intent is only safe if it cannot fight with the app's own
/// store, so:
///
/// * When the app is running, `forgeExternalEntryPoints(router:)` lends this type the app's live
///   container. The intent then writes through `mainContext` — the very context the screens observe
///   — so a weight logged by voice appears on the Progress tab without a refresh, and there is only
///   ever one writer.
/// * When the app is not running, the intent opens its own container against the same store file
///   and keeps it for the lifetime of the process. It is released the moment the app registers its
///   own, so the two never stay open together for longer than a launch takes.
///
/// Anything an intent cannot do this way — starting a workout, picking a food — opens the app
/// instead, through `DeepLinkInbox`. Those need a screen, not a write.
@MainActor
enum IntentModelStore {
    private static var appContainer: ModelContainer?
    private static var fallbackContainer: ModelContainer?

    /// Called by the app's root view. The app's container always supersedes a fallback one.
    static func register(_ container: ModelContainer) {
        appContainer = container
        fallbackContainer = nil
    }

    /// A context to write through, or `IntentFailure.storeUnavailable` if the store cannot be
    /// opened at all — which is a real possibility on a device whose disk is full or whose store is
    /// corrupt, and must be reported rather than crash a background process.
    static func context() throws -> ModelContext {
        if let appContainer { return appContainer.mainContext }
        if let fallbackContainer { return fallbackContainer.mainContext }
        do {
            let container = try PersistenceController.makeContainer()
            fallbackContainer = container
            return container.mainContext
        } catch {
            AppLog.persistence.error(
                "An App Intent could not open the store: \(String(describing: error), privacy: .public)"
            )
            throw IntentFailure.storeUnavailable
        }
    }

    /// Rebuilds the widgets' snapshot after an intent has changed something they show, and asks
    /// WidgetKit to reload. Without this a glass of water logged by voice would not reach the Home
    /// Screen until the next time the app was opened and backgrounded.
    static func publishSnapshot(context: ModelContext) {
        SharedSnapshotWriter().refresh(context: context, catalog: nil)
    }
}

/// The failures an App Intent can report back to Shortcuts and Siri.
///
/// `CustomLocalizedStringResourceConvertible` is what makes Siri say something a person can act on
/// instead of "Forge encountered an error".
enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    /// The SwiftData store could not be opened.
    case storeUnavailable
    /// The value handed in is not one the app will record — an empty measurement, or a body mass
    /// outside the range `InputValidation` accepts.
    case valueOutOfRange

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeUnavailable:
            LocalizedStringResource("intents.error.storeUnavailable")
        case .valueOutOfRange:
            LocalizedStringResource("intents.error.valueOutOfRange")
        }
    }
}
