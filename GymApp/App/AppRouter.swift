import Foundation
import SwiftUI
import Observation

/// Top-level tabs.
enum AppTab: String, CaseIterable, Hashable, Identifiable {
    case home
    case workout
    case exercises
    case nutrition
    case progress

    var id: String { rawValue }
    var localizationKey: String { "tab.\(rawValue)" }

    var symbolName: String {
        switch self {
        case .home: "house.fill"
        case .workout: "figure.strengthtraining.traditional"
        case .exercises: "square.grid.2x2.fill"
        case .nutrition: "fork.knife"
        case .progress: "chart.xyaxis.line"
        }
    }
}

/// Destinations reachable from outside the app: widgets, App Intents, Shortcuts and Spotlight.
enum AppDeepLink: Hashable {
    case startTodayWorkout
    case resumeActiveWorkout
    case logBodyWeight
    case logWater
    case addMeal(MealSlot)
    case exercise(String)
    case todayWorkout
}

/// Owns navigation state for the whole app, so a deep link can move the user anywhere without a
/// view needing to know who called it.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .home

    var homePath = NavigationPath()
    var workoutPath = NavigationPath()
    var exercisesPath = NavigationPath()
    var nutritionPath = NavigationPath()
    var progressPath = NavigationPath()

    /// Set to present the active-workout screen over whatever is on screen.
    var presentedWorkoutID: UUID?
    var pendingDeepLink: AppDeepLink?
    var isPresentingWeightEntry = false
    var isPresentingWaterEntry = false
    var pendingMealSlot: MealSlot?

    func handle(_ link: AppDeepLink) {
        switch link {
        case .startTodayWorkout, .resumeActiveWorkout, .todayWorkout:
            selectedTab = .workout
            pendingDeepLink = link
        case .logBodyWeight:
            selectedTab = .progress
            isPresentingWeightEntry = true
        case .logWater:
            selectedTab = .nutrition
            isPresentingWaterEntry = true
        case .addMeal(let slot):
            selectedTab = .nutrition
            pendingMealSlot = slot
        case .exercise(let id):
            selectedTab = .exercises
            exercisesPath.append(ExerciseRoute.detail(id))
        }
    }

    func resetPath(for tab: AppTab) {
        switch tab {
        case .home: homePath = NavigationPath()
        case .workout: workoutPath = NavigationPath()
        case .exercises: exercisesPath = NavigationPath()
        case .nutrition: nutritionPath = NavigationPath()
        case .progress: progressPath = NavigationPath()
        }
    }
}

/// Routes inside the Exercises tab.
enum ExerciseRoute: Hashable {
    case detail(String)
    case history(String)
}
