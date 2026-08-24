import WidgetKit
import SwiftUI

/// The training widget: what to train next, or how long the current session has been running.
struct NextWorkoutWidget: Widget {
    static let kind = "NextWorkoutWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            NextWorkoutWidgetView(entry: entry)
                .containerBackground(WidgetPalette.background, for: .widget)
        }
        .configurationDisplayName(Text(L("widget.nextWorkout.displayName")))
        .description(Text(L("widget.nextWorkout.description")))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Family switch

struct NextWorkoutWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        switch family {
        case .systemMedium:
            NextWorkoutMediumView(entry: entry)
        default:
            NextWorkoutSmallView(entry: entry)
        }
    }
}

// MARK: - Small

/// Session name, muscle groups and a start affordance — or, when a session is already running, the
/// elapsed time, because that is the only number that matters mid-workout.
struct NextWorkoutSmallView: View {
    let entry: SnapshotEntry

    private var snapshot: SharedSnapshot { entry.snapshot }

    var body: some View {
        Group {
            if !entry.isLive {
                WidgetNeutralMessage(
                    symbolName: "square.dashed",
                    title: L("widget.unavailable.title"),
                    message: L("widget.unavailable.message")
                )
            } else if snapshot.hasActiveWorkout {
                activeBody
            } else if snapshot.isRestDay {
                WidgetNeutralMessage(
                    symbolName: "moon.zzz.fill",
                    title: L("widget.restDay.title"),
                    message: L("widget.restDay.message"),
                    tint: WidgetPalette.recovery
                )
            } else if snapshot.hasPlannedWorkout {
                plannedBody
            } else {
                WidgetNeutralMessage(
                    symbolName: "calendar.badge.plus",
                    title: L("widget.noProgram.title"),
                    message: L("widget.noProgram.message")
                )
            }
        }
        .widgetURL(destination)
    }

    private var destination: URL {
        guard entry.isLive else { return WidgetLink.todayWorkout }
        if snapshot.hasActiveWorkout { return WidgetLink.resumeWorkout }
        return snapshot.hasPlannedWorkout ? WidgetLink.startWorkout : WidgetLink.todayWorkout
    }

    // MARK: In progress

    private var activeBody: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.spacing4) {
            HStack(spacing: WidgetMetrics.spacing4) {
                Image(systemName: "record.circle")
                    .font(.system(size: 10, weight: .bold))
                Text(L("widget.inProgress.label"))
                    .font(.widgetOverline)
            }
            .foregroundStyle(WidgetPalette.accent)

            Text(snapshot.activeWorkoutTitle ?? snapshot.nextWorkoutTitle ?? L("widget.workout.generic"))
                .font(.widgetTitle)
                .foregroundStyle(WidgetPalette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let started = snapshot.activeWorkoutStartedAt {
                Text(started, style: .timer)
                    .font(.widgetNumeric(28, weight: .bold))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            WidgetActionPill(title: L("widget.resume"), symbolName: "arrow.forward")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L("widget.accessibility.inProgress",
                                   snapshot.activeWorkoutTitle ?? L("widget.workout.generic"))))
    }

    // MARK: Planned

    private var plannedBody: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.spacing4) {
            WidgetBrandMark()

            Text(snapshot.nextWorkoutTitle ?? L("widget.workout.generic"))
                .font(.widgetTitle)
                .foregroundStyle(WidgetPalette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)

            if !snapshot.focusLine.isEmpty {
                Text(snapshot.focusLine)
                    .font(.widgetCaption)
                    .foregroundStyle(WidgetPalette.textSecondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            WidgetActionPill(title: L("widget.start"), symbolName: "play.fill")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L("widget.accessibility.startWorkout",
                                   snapshot.nextWorkoutTitle ?? L("widget.workout.generic"))))
    }
}

// MARK: - Medium

/// The fuller picture: what the session is, how big it is, and how the week is going.
struct NextWorkoutMediumView: View {
    let entry: SnapshotEntry

    private var snapshot: SharedSnapshot { entry.snapshot }
    private var weekIsCurrent: Bool { snapshot.coversWeek(of: entry.date) }

    var body: some View {
        Group {
            if !entry.isLive {
                WidgetNeutralMessage(
                    symbolName: "square.dashed",
                    title: L("widget.unavailable.title"),
                    message: L("widget.unavailable.message")
                )
            } else {
                HStack(alignment: .top, spacing: WidgetMetrics.spacing12) {
                    detailColumn
                    Spacer(minLength: 0)
                    sideColumn
                }
            }
        }
        .widgetURL(WidgetLink.todayWorkout)
    }

    // MARK: Left

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.spacing6) {
            if snapshot.hasActiveWorkout {
                HStack(spacing: WidgetMetrics.spacing4) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 10, weight: .bold))
                    Text(L("widget.inProgress.label"))
                        .font(.widgetOverline)
                }
                .foregroundStyle(WidgetPalette.accent)
            } else {
                WidgetBrandMark()
            }

            Text(headlineTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(WidgetPalette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)

            if snapshot.hasActiveWorkout, let started = snapshot.activeWorkoutStartedAt {
                Text(started, style: .timer)
                    .font(.widgetNumeric(24, weight: .bold))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if snapshot.hasPlannedWorkout {
                focusChips
                metaRow
            } else if snapshot.isRestDay {
                Text(L("widget.restDay.message"))
                    .font(.widgetCaption)
                    .foregroundStyle(WidgetPalette.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("widget.noProgram.message"))
                    .font(.widgetCaption)
                    .foregroundStyle(WidgetPalette.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(detailAccessibilityLabel))
    }

    private var headlineTitle: String {
        if snapshot.hasActiveWorkout {
            return snapshot.activeWorkoutTitle ?? L("widget.workout.generic")
        }
        if snapshot.isRestDay { return L("widget.restDay.title") }
        return snapshot.nextWorkoutTitle ?? L("widget.noProgram.title")
    }

    private var detailAccessibilityLabel: String {
        if snapshot.hasActiveWorkout {
            return L("widget.accessibility.inProgress", headlineTitle)
        }
        if snapshot.hasPlannedWorkout {
            return L(
                "widget.accessibility.plannedSession",
                headlineTitle,
                LPlural("widget.exercises", snapshot.nextWorkoutExerciseCount),
                L("widget.minutes", snapshot.nextWorkoutEstimatedMinutes)
            )
        }
        return headlineTitle
    }

    private var focusChips: some View {
        HStack(spacing: WidgetMetrics.spacing4) {
            ForEach(snapshot.focusGroups(limit: 3), id: \.self) { group in
                Text(group)
                    .font(.widgetOverline)
                    .foregroundStyle(WidgetPalette.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, WidgetMetrics.spacing6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(WidgetPalette.fill)
                    )
            }
            if snapshot.hiddenFocusCount(limit: 3) > 0 {
                Text(L("widget.focus.more", snapshot.hiddenFocusCount(limit: 3)))
                    .font(.widgetOverline)
                    .foregroundStyle(WidgetPalette.textTertiary)
            }
        }
        .minimumScaleFactor(0.8)
    }

    private var metaRow: some View {
        HStack(spacing: WidgetMetrics.spacing8) {
            Label {
                Text(LPlural("widget.exercises", snapshot.nextWorkoutExerciseCount))
            } icon: {
                Image(systemName: "list.bullet")
            }
            if snapshot.nextWorkoutEstimatedMinutes > 0 {
                Label {
                    Text(L("widget.minutes", snapshot.nextWorkoutEstimatedMinutes))
                } icon: {
                    Image(systemName: "clock")
                }
            }
        }
        .font(.widgetCaption)
        .foregroundStyle(WidgetPalette.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    // MARK: Right

    private var sideColumn: some View {
        VStack(alignment: .trailing, spacing: WidgetMetrics.spacing8) {
            if weekIsCurrent && snapshot.plannedWorkoutsThisWeek > 0 {
                weekRing
            } else if weekIsCurrent && snapshot.completedWorkoutsThisWeek > 0 {
                weekCount
            }

            Spacer(minLength: 0)

            Link(destination: primaryActionURL) {
                WidgetActionPill(title: primaryActionTitle, symbolName: primaryActionSymbol)
                    .frame(minHeight: 44)
            }
            .accessibilityLabel(Text(primaryActionAccessibilityLabel))
        }
        .frame(width: 104)
    }

    private var weekRing: some View {
        VStack(spacing: WidgetMetrics.spacing2) {
            WidgetRing(fraction: snapshot.weekFraction, lineWidth: 6, tint: WidgetPalette.accent) {
                Text(L("widget.week.progress",
                       snapshot.completedWorkoutsThisWeek,
                       snapshot.plannedWorkoutsThisWeek))
                    .font(.widgetNumeric(13, weight: .semibold))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(2)
            }
            .frame(width: 52, height: 52)

            Text(L("widget.week.label"))
                .font(.widgetOverline)
                .foregroundStyle(WidgetPalette.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("widget.accessibility.weekProgress",
                                   snapshot.completedWorkoutsThisWeek,
                                   snapshot.plannedWorkoutsThisWeek)))
    }

    private var weekCount: some View {
        VStack(alignment: .trailing, spacing: WidgetMetrics.spacing2) {
            Text(WidgetFormat.whole(snapshot.completedWorkoutsThisWeek))
                .font(.widgetNumeric(24, weight: .bold))
                .foregroundStyle(WidgetPalette.textPrimary)
            Text(L("widget.week.label"))
                .font(.widgetOverline)
                .foregroundStyle(WidgetPalette.textTertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("widget.accessibility.weekCompleted", snapshot.completedWorkoutsThisWeek)))
    }

    private var primaryActionURL: URL {
        if snapshot.hasActiveWorkout { return WidgetLink.resumeWorkout }
        return snapshot.hasPlannedWorkout ? WidgetLink.startWorkout : WidgetLink.todayWorkout
    }

    private var primaryActionTitle: String {
        if snapshot.hasActiveWorkout { return L("widget.resume") }
        return snapshot.hasPlannedWorkout ? L("widget.start") : L("widget.open")
    }

    private var primaryActionSymbol: String {
        if snapshot.hasActiveWorkout { return "arrow.forward" }
        return snapshot.hasPlannedWorkout ? "play.fill" : "arrow.up.right"
    }

    private var primaryActionAccessibilityLabel: String {
        if snapshot.hasActiveWorkout {
            return L("widget.accessibility.resumeWorkout", headlineTitle)
        }
        if snapshot.hasPlannedWorkout {
            return L("widget.accessibility.startWorkout", headlineTitle)
        }
        return L("widget.accessibility.openApp")
    }
}

// MARK: - Action pill

/// The filled affordance that tells the user the widget is tappable. On the small family the whole
/// widget is the link, so this is purely a label; on the medium family it is wrapped in a `Link` and
/// is a real 44 pt target.
struct WidgetActionPill: View {
    let title: String
    let symbolName: String
    var tint: Color = WidgetPalette.accent

    var body: some View {
        HStack(spacing: WidgetMetrics.spacing4) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .bold))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(WidgetPalette.onAccent)
        .padding(.horizontal, WidgetMetrics.spacing10)
        .padding(.vertical, WidgetMetrics.spacing6)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(tint))
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Small — planned", as: .systemSmall) {
    NextWorkoutWidget()
} timeline: {
    SnapshotEntry.placeholder()
}

#Preview("Small — no data", as: .systemSmall) {
    NextWorkoutWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .placeholder, isLive: false)
}

#Preview("Medium — planned", as: .systemMedium) {
    NextWorkoutWidget()
} timeline: {
    SnapshotEntry.placeholder()
}

#Preview("Medium — in progress", as: .systemMedium) {
    NextWorkoutWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .activeWorkoutSample, isLive: true)
}
