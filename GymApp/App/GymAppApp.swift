import SwiftUI
import SwiftData

@main
struct GymAppApp: App {
    @State private var environment: AppEnvironment
    @State private var router = AppRouter()
    @StateObject private var localization = LocalizationManager.shared
    private let modelContainer: ModelContainer

    init() {
        let result = PersistenceController.makeResilientContainer()
        modelContainer = result.container
        _environment = State(
            initialValue: AppEnvironment(
                modelContainer: result.container,
                isRunningOnFallbackStore: result.didFallBackToMemory
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(router)
                .environmentObject(localization)
                .environment(\.appEnvironment, environment)
                // Re-render the whole tree when the in-app language override changes.
                .id(localization.current)
                .tint(Color.appAccent)
        }
        .modelContainer(modelContainer)
    }
}
