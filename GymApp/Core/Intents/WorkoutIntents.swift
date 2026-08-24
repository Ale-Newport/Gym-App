import AppIntents
import Foundation

/// Starts today's session, or picks up the one already running.
///
/// Training needs a screen — a set has to be logged somewhere — so this intent opens the app and
/// leaves the routing to `AppRouter`, which knows whether there is a session in progress to resume
/// or a planned one to begin. Doing the work in an extension process would mean duplicating the
/// programme selection, the progression engine and the Live Activity, and none of that belongs
/// behind a Siri phrase.
struct StartWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intents.startWorkout.title")

    static var description = IntentDescription(
        LocalizedStringResource("intents.startWorkout.description")
    )

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkInbox.shared.post(.startWorkout)
        return .result()
    }
}

/// Opens today's session without starting it — the "what am I training today?" question, which is
/// asked far more often than "start it now".
struct OpenTodayWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("intents.openToday.title")

    static var description = IntentDescription(
        LocalizedStringResource("intents.openToday.description")
    )

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkInbox.shared.post(.todayWorkout)
        return .result()
    }
}
