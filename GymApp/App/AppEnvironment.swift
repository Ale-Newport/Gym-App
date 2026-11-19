import Foundation
import Observation
import SwiftData
import SwiftUI

/// The app's composition root.
///
/// Everything with a lifetime longer than a view — the exercise catalogue, the media provider, the
/// health and notification services — is created here and handed down through the SwiftUI
/// environment. Views and view models receive their collaborators instead of reaching for
/// singletons, which is what makes the engines testable without a running app.
@MainActor
@Observable
final class AppEnvironment {
    let catalog: ExerciseCatalog
    let mediaProvider: any ExerciseMediaProviding
    let instructionStore: ExerciseInstructionStore
    let modelContainer: ModelContainer
    /// True when the on-disk store could not be opened and an in-memory one is standing in.
    let isRunningOnFallbackStore: Bool

    let healthService: HealthService
    let notificationService: NotificationService
    let liveActivityService: WorkoutLiveActivityService
    let snapshotWriter: SharedSnapshotWriter

    /// Tracks the workout the user is currently in, across app launches.
    var activeWorkoutID: UUID?

    init(
        modelContainer: ModelContainer,
        isRunningOnFallbackStore: Bool = false,
        catalog: ExerciseCatalog? = nil,
        mediaProvider: (any ExerciseMediaProviding)? = nil,
        instructionStore: ExerciseInstructionStore = .shared
    ) {
        self.modelContainer = modelContainer
        self.isRunningOnFallbackStore = isRunningOnFallbackStore
        self.catalog = catalog ?? ExerciseCatalog()
        self.mediaProvider = mediaProvider ?? BundledExerciseMediaProvider()
        self.instructionStore = instructionStore
        self.healthService = HealthService()
        self.notificationService = NotificationService()
        self.liveActivityService = WorkoutLiveActivityService()
        self.snapshotWriter = SharedSnapshotWriter()
    }

    /// Loads everything the first screen needs. Called once, from the root view's `task`.
    func bootstrap() async {
        Haptics.prepare()
        await catalog.load()
        let language = LocalizationManager.shared.current
        await instructionStore.preload(language)
    }

    /// Called after the store has been wiped or replaced wholesale.
    ///
    /// Three things live outside the store and would go on describing a workout that no longer
    /// exists: the Live Activity, which survives the app process; the active-workout id; and the
    /// widget snapshot, which would keep advertising the deleted program and today's deleted log.
    func storeWasReplaced(context: ModelContext) {
        liveActivityService.endAll()
        // A replaced store is a different set of reminders: rebuild the queue from the new
        // settings, which clears it when they are the defaults of a wiped store. The guide is owed
        // again once the user has been through setup.
        let notifications = notificationService
        let repository = ProfileRepository(context: context)
        if let settings = try? repository.settings(), let profile = try? repository.profile() {
            let weekdays = profile.availableWeekdays
            Task { await notifications.applySettings(settings, weekdays: weekdays) }
        } else {
            notifications.cancelAll()
        }
        GuidedTourStore.clearPending()
        activeWorkoutID = nil
        snapshotWriter.refresh(context: context, catalog: catalog)
    }

    /// Frees decoded media. Wired to `UIApplication.didReceiveMemoryWarningNotification`.
    func handleMemoryPressure() {
        Task {
            await AnimatedImageStore.shared.purge()
            await ThumbnailStore.shared.purge()
            await instructionStore.purge(keeping: LocalizationManager.shared.current)
        }
    }
}

private struct AppEnvironmentKey: EnvironmentKey {
    @MainActor
    static var defaultValue: AppEnvironment {
        // Only reached in previews that forgot to inject one; an in-memory store keeps them working.
        AppEnvironment(modelContainer: PreviewSupport.emptyContainer)
    }
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
