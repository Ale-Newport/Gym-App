import Foundation
import SwiftData
import SwiftUI

/// Sample data for SwiftUI previews and UI tests.
///
/// Kept strictly separate from anything the shipping app can reach: the only entry points are
/// `#Preview` blocks and the `-uiTestScenario` launch argument. Production code never inserts a
/// sample record.
@MainActor
enum PreviewSupport {

    /// Which fixture to build. Mirrors the states worth designing against.
    enum Scenario: String, CaseIterable {
        /// Nothing at all — the true first launch.
        case newUser
        /// Onboarded, program generated, no history yet.
        case freshProgram
        /// Three months of training, nutrition and body-weight history.
        case seasonedUser
        /// A workout currently in progress, mid-exercise.
        case activeWorkout
        /// Onboarded with nutrition targets but an empty food log for today.
        case emptyNutritionDay
        /// A fully logged day of food.
        case fullNutritionDay
    }

    static let emptyContainer: ModelContainer = {
        do { return try PersistenceController.makeInMemoryContainer() } catch {
            fatalError("Preview container unavailable: \(error)")
        }
    }()

    /// Builds an in-memory container populated for `scenario`.
    static func container(_ scenario: Scenario) -> ModelContainer {
        do {
            let container = try PersistenceController.makeInMemoryContainer()
            SampleDataBuilder.populate(container.mainContext, scenario: scenario)
            return container
        } catch {
            fatalError("Preview container unavailable: \(error)")
        }
    }

    /// An `AppEnvironment` wired to an in-memory store and a catalogue loaded from the real bundle.
    static func environment(_ scenario: Scenario = .seasonedUser) -> AppEnvironment {
        let container = container(scenario)
        let environment = AppEnvironment(modelContainer: container)
        Task { await environment.catalog.load() }
        return environment
    }
}

/// Injects the standard preview environment.
struct PreviewHost<Content: View>: View {
    var scenario: PreviewSupport.Scenario = .seasonedUser
    @ViewBuilder var content: Content

    @State private var environment: AppEnvironment
    @State private var router = AppRouter()
    private let container: ModelContainer

    init(scenario: PreviewSupport.Scenario = .seasonedUser, @ViewBuilder content: () -> Content) {
        self.scenario = scenario
        self.content = content()
        let container = PreviewSupport.container(scenario)
        self.container = container
        let environment = AppEnvironment(modelContainer: container)
        _environment = State(initialValue: environment)
    }

    var body: some View {
        content
            .environment(environment)
            .environment(router)
            .environmentObject(LocalizationManager.shared)
            .environment(\.appEnvironment, environment)
            .modelContainer(container)
            .tint(Color.appAccent)
            .task { await environment.catalog.load() }
    }
}
