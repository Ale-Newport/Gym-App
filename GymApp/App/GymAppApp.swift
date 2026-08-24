import SwiftUI
import SwiftData

@main
struct GymAppApp: App {
    @State private var environment: AppEnvironment
    @State private var router = AppRouter()
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
                .environment(LocalizationManager.shared)
                .environment(\.appEnvironment, environment)
                .tint(Color.appAccent)
        }
        .modelContainer(modelContainer)
    }
}
