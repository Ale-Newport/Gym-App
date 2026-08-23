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
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            await environment.bootstrap()
            await AppBootstrap.ensureBaselineRecords(in: modelContext)
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
}
