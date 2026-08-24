import SwiftUI
import SwiftData

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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                environment.snapshotWriter.refresh(context: modelContext, catalog: environment.catalog)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            environment.handleMemoryPressure()
        }
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
    static func importFoodDatabase(container: ModelContainer) async {
        let importer = FoodDatabaseImporter(modelContainer: container)
        do {
            let summary = try await importer.importIfNeeded()
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
