import SwiftData
import SwiftUI

/// Decides what the user sees at launch: onboarding, the main app, or a blocking failure state.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query private var profiles: [UserProfile]
    @Query private var settings: [UserSettings]

    @State private var didBootstrap = false

    private var profile: UserProfile? { profiles.first }
    private var isOnboarded: Bool { profile?.isOnboarded == true }

    var body: some View {
        // Every screen formats loads, distances, energy and dates through the environment's
        // DisplayFormatter. It is injected once here, from the user's stored units and the active
        // language, so changing either updates the whole app at once — and so no screen silently
        // falls back to kilograms and the device locale.
        DisplayFormatterProvider {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if environment.isRunningOnFallbackStore {
            // The on-disk store could not be opened and the app is running on an empty in-memory
            // one. Anything entered now would vanish at the next launch, and onboarding would look
            // like a fresh install, so block instead. Nothing below runs: no bootstrap, no widget
            // or reminder refresh, no App Intent draining into a store that will not persist.
            StoreFailureView()
        } else {
            appContent
        }
    }

    @ViewBuilder
    private var appContent: some View {
        Group {
            switch environment.catalog.state {
            case .idle, .loading:
                LaunchView()
            case .failed(let message):
                CatalogFailureView(message: message) {
                    Task { await environment.catalog.load() }
                }
            case .loaded:
                if isOnboarded {
                    MainTabView()
                        .transition(.opacity)
                } else {
                    OnboardingFlowView()
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: environment.catalog.state)
        .animation(.easeInOut(duration: 0.25), value: isOnboarded)
        .preferredColorScheme(colorScheme)
        // Routes incoming forge:// URLs from widgets and Shortcuts, drains anything an App Intent
        // queued while the app was not running, and lends the live ModelContainer to the logging
        // intents. Applied here because this is the highest view that has both the router and a
        // model context.
        .forgeExternalEntryPoints(router: router)
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            #if DEBUG
                // Seeds a UI-test fixture before anything reads the store. No-op unless the launch
                // arguments ask for it, and compiled out of Release entirely.
                UITestLaunchSupport.prepareIfNeeded(context: modelContext)
                if let tab = UITestLaunchSupport.initialTab { router.selectedTab = tab }
            #endif
            await environment.bootstrap()
            await AppBootstrap.ensureBaselineRecords(in: modelContext)
            await AppBootstrap.importFoodDatabase(container: environment.modelContainer)
            // Seed the widget once the store is ready. Every meaningful change refreshes it
            // afterwards, but without this a user who installs the app, adds the widget and has not
            // yet finished a workout would keep seeing the placeholder.
            environment.snapshotWriter.refresh(context: modelContext, catalog: environment.catalog)
            await refreshReminders()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                environment.snapshotWriter.refresh(context: modelContext, catalog: environment.catalog)
            }
            if phase == .active {
                Task { await refreshReminders() }
            }
        }
        .onChange(of: LocalizationManager.shared.current) {
            Task { await AppBootstrap.importFoodDatabase(container: environment.modelContainer) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            environment.handleMemoryPressure()
        }
    }

    /// Rebuilds the reminder queue from the stored settings.
    ///
    /// The queue is derived state: it depends on the training days, which Settings can change
    /// without ever visiting the notification screen, and on a permission the user can withdraw in
    /// iOS Settings while the app is closed. Re-deriving it whenever the app comes forward is what
    /// keeps what iOS will deliver the same as what the app says it will deliver.
    private func refreshReminders() async {
        guard isOnboarded, let row = settings.first else { return }
        await environment.notificationService.applySettings(row, weekdays: profile?.availableWeekdays ?? [])
    }

    private var colorScheme: ColorScheme? {
        switch settings.first?.appearance ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Shown while the catalogue parses. Matches the launch screen so the transition is invisible.
struct LaunchView: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: Metrics.spacing20) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Color.appAccent)
                    .scaleEffect(isAnimating ? 1.04 : 0.96)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: isAnimating)
                ProgressView()
                    .tint(Color.appTextTertiary)
            }
        }
        .onAppear { isAnimating = true }
        .accessibilityElement()
        .accessibilityLabel(Text(L("launch.loading")))
    }
}

/// The catalogue is the app's foundation; if it cannot load, say so plainly and offer a retry.
struct CatalogFailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ErrorStateView(message: message, retryTitle: L("common.retry"), retry: retry)
                .readableWidth()
        }
    }
}

/// Shown when the saved data could not be opened at launch.
///
/// The store on disk is left untouched (it may be recoverable after a relaunch or once storage is
/// freed), so the honest message is: nothing was deleted, nothing new would be kept, restart.
struct StoreFailureView: View {
    static let supportURL = URL(string: "https://ale-newport.github.io/Gym-App/")

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Metrics.spacing16) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(Color.appWarning)
                        .accessibilityHidden(true)
                    Text(L("storeFailure.title"))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("storeFailure.title")
                    Text(L("storeFailure.body"))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                    if let url = Self.supportURL {
                        Link(L("storeFailure.support"), destination: url)
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(maxWidth: 260)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(Metrics.spacing24)
                .readableWidth()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Creates the single-row records the rest of the app assumes exist.
enum AppBootstrap {
    @MainActor
    static func ensureBaselineRecords(in context: ModelContext) async {
        do {
            if try context.fetch(FetchDescriptor<UserSettings>()).isEmpty {
                let settings = UserSettings()
                settings.languageOverride = LocalizationManager.shared.override
                context.insert(settings)
            }
            if try context.fetch(FetchDescriptor<EquipmentProfile>()).isEmpty {
                let profile = EquipmentProfile()
                profile.availableEquipment = Array(Equipment.fullGym)
                context.insert(profile)
            }
            if try context.fetch(FetchDescriptor<UserProfile>()).isEmpty {
                context.insert(UserProfile())
            }
            if context.hasChanges { try context.save() }
        } catch {
            AppLog.persistence.error("Baseline bootstrap failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Ingests the bundled food database if it has changed since the last launch.
    ///
    /// Runs on `FoodDatabaseImporter`'s own executor — it is a `@ModelActor` with a private context
    /// — so ~600 rows are written off the main thread and the first frame is never delayed by it.
    /// The importer is idempotent and version-checked, so this is a cheap no-op on every launch
    /// after the first, and a failure is logged rather than surfaced: the app is entirely usable
    /// with only the user's own foods.
    /// - Parameter force: re-runs the import even when the stored version and language match.
    ///   Used after a reset or a "Replace" restore, which can leave only the handful of bundled
    ///   foods the backup carried — enough to defeat the importer's empty-database check.
    static func importFoodDatabase(container: ModelContainer, force: Bool = false) async {
        let importer = FoodDatabaseImporter(modelContainer: container)
        // Food names are written in the interface language, so a change of language re-imports. The
        // importer compares against the language it last wrote and does nothing when it is the same.
        let language = await MainActor.run { LocalizationManager.shared.current.datasetCode }
        do {
            let summary = try await importer.importIfNeeded(language: language, force: force)
            if summary.didRun {
                AppLog.nutrition.info(
                    "Food database imported: version \(summary.version, privacy: .public), \(summary.inserted) added, \(summary.updated) updated, \(summary.removed) removed"
                )
            }
        } catch {
            AppLog.nutrition.error(
                "Food database import failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
