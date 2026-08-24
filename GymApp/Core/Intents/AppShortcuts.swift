import AppIntents

/// The phrases Siri and Spotlight recognise, and the tiles the Shortcuts app offers without the
/// user having to build anything.
///
/// Every phrase has to contain `\(.applicationName)` — that is what tells the system which app the
/// utterance belongs to — and each intent gets several wordings, because the difference between
/// "start my workout" and "begin today's workout" is the difference between a feature that works
/// and one the user tries once.
///
/// Phrases are written in English here rather than through `L(…)`: they must be static literals the
/// App Intents metadata extractor can read at build time, and Apple localises them through a
/// separate `AppShortcuts.strings` file per language rather than through the app's catalogue. The
/// titles beside them do resolve through the catalogue, so what the user *sees* follows their
/// language even before those phrase files exist.
struct ForgeAppShortcuts: AppShortcutsProvider {

    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWorkoutIntent(),
            phrases: [
                "Start my \(.applicationName) workout",
                "Start today's workout in \(.applicationName)",
                "Begin my workout with \(.applicationName)",
                "Start training in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("intents.startWorkout.shortTitle"),
            systemImageName: "figure.strengthtraining.traditional"
        )

        AppShortcut(
            intent: OpenTodayWorkoutIntent(),
            phrases: [
                "What am I training today in \(.applicationName)",
                "Show today's workout in \(.applicationName)",
                "Open today's session in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("intents.openToday.shortTitle"),
            systemImageName: "calendar"
        )

        AppShortcut(
            intent: LogBodyWeightIntent(),
            phrases: [
                "Log my weight in \(.applicationName)",
                "Record my body weight in \(.applicationName)",
                "Add a weigh-in to \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("intents.logBodyWeight.shortTitle"),
            systemImageName: "scalemass"
        )

        AppShortcut(
            intent: LogWaterIntent(),
            phrases: [
                "Log water in \(.applicationName)",
                "Add a glass of water to \(.applicationName)",
                "Record a drink in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("intents.logWater.shortTitle"),
            systemImageName: "drop.fill"
        )

        AppShortcut(
            intent: AddMealIntent(),
            phrases: [
                "Log a meal in \(.applicationName)",
                "Add food to \(.applicationName)",
                "Record what I ate in \(.applicationName)"
            ],
            shortTitle: LocalizedStringResource("intents.addMeal.shortTitle"),
            systemImageName: "fork.knife"
        )
    }
}
