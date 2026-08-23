import Foundation
import ActivityKit
import Observation

/// Drives the Lock Screen / Dynamic Island Live Activity for an active workout.
///
/// Live Activities are a convenience, never a requirement: if the system refuses one — the user
/// disabled them, or too many are already running — the workout continues exactly as before.
@MainActor
@Observable
final class WorkoutLiveActivityService {
    private var activity: Activity<WorkoutActivityAttributes>?

    var isSupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(workoutID: UUID, title: String, state: WorkoutActivityAttributes.ContentState) {
        guard isSupported, activity == nil else { return }
        let attributes = WorkoutActivityAttributes(workoutTitle: title, workoutID: workoutID.uuidString)
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            AppLog.notifications.error("Live Activity could not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(_ state: WorkoutActivityAttributes.ContentState) {
        guard let activity else { return }
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Reattaches to an activity that survived an app relaunch, so a resumed workout does not end
    /// up with two Live Activities.
    func reattach(workoutID: UUID) {
        guard activity == nil else { return }
        activity = Activity<WorkoutActivityAttributes>.activities
            .first { $0.attributes.workoutID == workoutID.uuidString }
    }
}
