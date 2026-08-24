import WidgetKit
import SwiftUI

/// Everything this extension offers: two Home Screen widgets, the Lock Screen family, and the
/// in-workout Live Activity.
///
/// The extension compiles against `GymAppWidgets/**` and `GymApp/Core/SharedSnapshot/**` only. It
/// has no access to the database, the exercise catalogue or the app's design system — all it reads
/// is a small JSON snapshot in the shared App Group container, which is what keeps a timeline
/// refresh cheap and unable to disturb the app's store.
@main
struct GymAppWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextWorkoutWidget()
        NutritionWidget()
        LockScreenWidget()
        WorkoutLiveActivity()
    }
}
