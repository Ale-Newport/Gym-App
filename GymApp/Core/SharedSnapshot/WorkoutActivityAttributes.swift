import Foundation
import ActivityKit

/// Live Activity payload for an in-progress workout.
///
/// Declared in the shared source folder so both the app (which starts and updates the activity) and
/// the widget extension (which renders it) compile against the identical type.
struct WorkoutActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var exerciseName: String
        var setNumber: Int
        var totalSets: Int
        var completedSets: Int
        var plannedSets: Int
        /// When the current rest period ends, or `nil` when the user is mid-set.
        var restEndsAt: Date?
        var workoutStartedAt: Date
    }

    var workoutTitle: String
    var workoutID: String
}
