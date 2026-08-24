import ActivityKit
import WidgetKit
import SwiftUI

/// The Live Activity for a session that is currently running.
///
/// Everything on screen either comes from the last `ContentState` the app pushed or ticks by itself.
/// The rest countdown in particular is a `Text(timerInterval:)`, which the system animates locally:
/// a workout must not spend a Live Activity update budget — capped by the system and shared with
/// every other activity — on redrawing a number once a second.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutActivityLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(WidgetPalette.background)
                .activitySystemActionForegroundColor(WidgetPalette.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivitySetCounter(state: context.state)
                        .padding(.leading, WidgetMetrics.spacing4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityTimerColumn(state: context.state, alignment: .trailing)
                        .padding(.trailing, WidgetMetrics.spacing4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.workoutTitle)
                        .font(.widgetOverline)
                        .foregroundStyle(WidgetPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: WidgetMetrics.spacing6) {
                        Text(displayExerciseName(context.state, fallback: context.attributes.workoutTitle))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(WidgetPalette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        ActivitySessionProgress(state: context.state)
                    }
                    .padding(.top, WidgetMetrics.spacing2)
                }
            } compactLeading: {
                Image(systemName: context.state.restEndsAt == nil ? "figure.strengthtraining.traditional" : "timer")
                    .foregroundStyle(WidgetPalette.accent)
                    .accessibilityLabel(Text(L("app.name")))
            } compactTrailing: {
                ActivityCompactTrailing(state: context.state)
            } minimal: {
                ActivityMinimal(state: context.state)
            }
            .widgetURL(WidgetLink.resumeWorkout)
            .keylineTint(WidgetPalette.accent)
        }
    }
}

/// The exercise name, or the session title when the app has not sent one yet (the first state is
/// pushed before the user has opened an exercise).
private func displayExerciseName(
    _ state: WorkoutActivityAttributes.ContentState,
    fallback: String
) -> String {
    let trimmed = state.exerciseName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
}

// MARK: - Lock Screen

/// The banner shown on the Lock Screen and in the Notification Centre.
struct WorkoutActivityLockScreenView: View {
    let attributes: WorkoutActivityAttributes
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.spacing8) {
            HStack(alignment: .top, spacing: WidgetMetrics.spacing12) {
                VStack(alignment: .leading, spacing: WidgetMetrics.spacing2) {
                    HStack(spacing: WidgetMetrics.spacing4) {
                        Image(systemName: "record.circle")
                            .font(.system(size: 10, weight: .bold))
                        Text(attributes.workoutTitle)
                            .font(.widgetOverline)
                            .lineLimit(1)
                    }
                    .foregroundStyle(WidgetPalette.accent)

                    Text(displayExerciseName(state, fallback: attributes.workoutTitle))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(WidgetPalette.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: false, vertical: true)

                    if state.totalSets > 0 {
                        Text(L("widget.live.setOfTotal", state.setNumber, state.totalSets))
                            .font(.widgetCaption)
                            .foregroundStyle(WidgetPalette.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                ActivityTimerColumn(state: state, alignment: .trailing)
            }

            ActivitySessionProgress(state: state)
        }
        .padding(WidgetMetrics.spacing12)
        .widgetURL(WidgetLink.resumeWorkout)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pieces

/// "Set 2 / 4" for the exercise in front of the user right now.
struct ActivitySetCounter: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("widget.live.set"))
                .font(.widgetOverline)
                .foregroundStyle(WidgetPalette.textSecondary)
            Text(state.totalSets > 0
                 ? L("widget.live.setValue", state.setNumber, state.totalSets)
                 : WidgetFormat.whole(state.setNumber))
                .font(.widgetNumeric(20, weight: .bold))
                .foregroundStyle(WidgetPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("widget.live.setOfTotal", state.setNumber, max(state.totalSets, state.setNumber))))
    }
}

/// The rest countdown when the user is resting, the session's elapsed time when they are not.
/// Both are self-updating: neither costs the app an activity update.
struct ActivityTimerColumn: View {
    let state: WorkoutActivityAttributes.ContentState
    var alignment: HorizontalAlignment = .trailing

    private var restRange: ClosedRange<Date>? {
        guard let end = state.restEndsAt else { return nil }
        let now = Date()
        guard end > now else { return nil }
        return now...end
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(restRange == nil ? L("widget.live.elapsed") : L("widget.live.rest"))
                .font(.widgetOverline)
                .foregroundStyle(restRange == nil ? WidgetPalette.textSecondary : WidgetPalette.accent)

            if let restRange {
                Text(timerInterval: restRange, countsDown: true)
                    .font(.widgetNumeric(20, weight: .bold))
                    .foregroundStyle(WidgetPalette.accent)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                    .frame(minWidth: 56)
            } else {
                Text(state.workoutStartedAt, style: .timer)
                    .font(.widgetNumeric(20, weight: .bold))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                    .frame(minWidth: 56)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }
}

/// Sets completed against sets planned for the whole session.
struct ActivitySessionProgress: View {
    let state: WorkoutActivityAttributes.ContentState

    private var planned: Int { max(state.plannedSets, state.completedSets) }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.spacing4) {
            HStack(spacing: WidgetMetrics.spacing4) {
                Text(L("widget.live.sets"))
                    .font(.widgetOverline)
                    .foregroundStyle(WidgetPalette.textSecondary)
                Spacer(minLength: 0)
                Text(L("widget.live.setValue", state.completedSets, planned))
                    .font(.widgetNumeric(12, weight: .semibold))
                    .foregroundStyle(WidgetPalette.textPrimary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            WidgetProgressBar(
                value: Double(state.completedSets),
                total: Double(planned),
                tint: WidgetPalette.accent,
                height: 6
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("widget.accessibility.setsCompleted", state.completedSets, planned)))
    }
}

/// The right-hand side of the compact island: the rest countdown while resting, otherwise how far
/// through the current exercise the user is.
struct ActivityCompactTrailing: View {
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        if let end = state.restEndsAt, end > Date() {
            Text(timerInterval: Date()...end, countsDown: true)
                .font(.widgetNumeric(13, weight: .semibold))
                .foregroundStyle(WidgetPalette.accent)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text(L("widget.live.rest")))
        } else if state.totalSets > 0 {
            Text(L("widget.live.setValue", state.setNumber, state.totalSets))
                .font(.widgetNumeric(13, weight: .semibold))
                .foregroundStyle(WidgetPalette.textPrimary)
                .accessibilityLabel(Text(L("widget.live.setOfTotal", state.setNumber, state.totalSets)))
        } else {
            Text(state.workoutStartedAt, style: .timer)
                .font(.widgetNumeric(13, weight: .semibold))
                .foregroundStyle(WidgetPalette.textPrimary)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Text(L("widget.live.elapsed")))
        }
    }
}

/// The 24-point circle the island collapses to when another activity is sharing it. A ring of the
/// session's set completion: no text fits, but a filling ring still says "you are part-way through".
struct ActivityMinimal: View {
    let state: WorkoutActivityAttributes.ContentState

    private var fraction: Double {
        let planned = max(state.plannedSets, state.completedSets)
        guard planned > 0 else { return 0 }
        return min(1, Double(state.completedSets) / Double(planned))
    }

    var body: some View {
        ZStack {
            WidgetRing(fraction: fraction, lineWidth: 3, tint: WidgetPalette.accent, trackOpacity: 0.35) {
                Image(systemName: state.restEndsAt == nil ? "figure.strengthtraining.traditional" : "timer")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(WidgetPalette.accent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("widget.accessibility.setsCompleted",
                                   state.completedSets,
                                   max(state.plannedSets, state.completedSets))))
    }
}

// MARK: - Previews

private let previewAttributes = WorkoutActivityAttributes(
    workoutTitle: "Upper Body A",
    workoutID: "preview-session"
)

private let previewResting = WorkoutActivityAttributes.ContentState(
    exerciseName: "Barbell Bench Press",
    setNumber: 2,
    totalSets: 4,
    completedSets: 5,
    plannedSets: 20,
    restEndsAt: Date().addingTimeInterval(96),
    workoutStartedAt: Date().addingTimeInterval(-18 * 60)
)

private let previewWorking = WorkoutActivityAttributes.ContentState(
    exerciseName: "Romanian Deadlift",
    setNumber: 3,
    totalSets: 3,
    completedSets: 14,
    plannedSets: 20,
    restEndsAt: nil,
    workoutStartedAt: Date().addingTimeInterval(-42 * 60)
)

#Preview("Lock Screen", as: .content, using: previewAttributes) {
    WorkoutLiveActivity()
} contentStates: {
    previewResting
    previewWorking
}

#Preview("Island — expanded", as: .dynamicIsland(.expanded), using: previewAttributes) {
    WorkoutLiveActivity()
} contentStates: {
    previewResting
    previewWorking
}

#Preview("Island — compact", as: .dynamicIsland(.compact), using: previewAttributes) {
    WorkoutLiveActivity()
} contentStates: {
    previewResting
    previewWorking
}

#Preview("Island — minimal", as: .dynamicIsland(.minimal), using: previewAttributes) {
    WorkoutLiveActivity()
} contentStates: {
    previewResting
    previewWorking
}
