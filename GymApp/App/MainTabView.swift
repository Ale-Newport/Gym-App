import SwiftData
import SwiftUI

/// The five-tab shell.
///
/// Home / Workout / Exercises / Nutrition / Progress. Settings lives behind the profile button on
/// Home rather than taking a sixth tab slot: it is visited rarely, and five tabs already fill the
/// bar comfortably on the narrowest supported iPhone.
struct MainTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        @Bindable var router = router

        TabView(selection: tabSelection) {
            Tab(L(AppTab.home.localizationKey), systemImage: AppTab.home.symbolName, value: AppTab.home) {
                NavigationStack(path: $router.homePath) { HomeView() }
            }
            Tab(L(AppTab.workout.localizationKey), systemImage: AppTab.workout.symbolName, value: AppTab.workout) {
                NavigationStack(path: $router.workoutPath) { WorkoutHubView() }
            }
            Tab(L(AppTab.exercises.localizationKey), systemImage: AppTab.exercises.symbolName, value: AppTab.exercises)
            {
                NavigationStack(path: $router.exercisesPath) { ExerciseLibraryView() }
            }
            Tab(L(AppTab.nutrition.localizationKey), systemImage: AppTab.nutrition.symbolName, value: AppTab.nutrition)
            {
                NavigationStack(path: $router.nutritionPath) { NutritionHubView() }
            }
            Tab(L(AppTab.progress.localizationKey), systemImage: AppTab.progress.symbolName, value: AppTab.progress) {
                NavigationStack(path: $router.progressPath) { ProgressHubView() }
            }
        }
        .tint(Color.appAccent)
        .overlay {
            if router.isShowingTour {
                GuidedTourView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: router.isShowingTour)
        .task {
            // Setup just finished, or the app was closed before the guide was seen.
            if GuidedTourStore.isPending { router.isShowingTour = true }
        }
    }

    /// Tapping the already-selected tab pops that tab's stack to its root.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { router.selectedTab },
            set: { newValue in
                if newValue == router.selectedTab {
                    router.resetPath(for: newValue)
                } else {
                    router.selectedTab = newValue
                    Haptics.selectionChanged()
                }
            }
        )
    }
}
