import SwiftUI

/// Stable accessibility identifiers for Home's primary controls.
///
/// Their spoken labels are deliberately contextual — "Start Upper A. 7 exercises · 23 sets" is far
/// more useful to a VoiceOver user than "Start workout" — which is exactly why they need a handle
/// that does not change with the content.
enum HomeAccessibility {
    /// Whichever action today's card currently offers: start, resume, train again, light session,
    /// or create a program. One slot, one identifier.
    static let todayAction = "home.todayAction"
    /// The profile button in Home's toolbar, which is the only way into Settings.
    static let profile = "home.profile"
}


/// The dashboard's centre of gravity: what the user is meant to do today, and one button to do it.
///
/// Five states, one call to action each. The button is deliberately the widest, tallest thing on
/// the screen — it is pressed with a thumb, often in a hurry, sometimes with chalk on the hands.
struct TodaySessionCard: View {
    let state: HomeViewModel.TodayState
    var isBusy: Bool = false
    var onStart: () -> Void
    var onResume: () -> Void
    var onCreateProgram: () -> Void
    var onViewProgram: () -> Void
    var onViewSummary: (UUID) -> Void
    var onStartLight: () -> Void
    var onOpenStretch: (String) -> Void

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                switch state {
                case .scheduled(let plan): scheduledContent(plan)
                case .inProgress(let session): inProgressContent(session)
                case .completed(let session): completedContent(session)
                case .rest(let rest): restContent(rest)
                case .noProgram: noProgramContent
                }
            }
        }
    }

    // MARK: - Scheduled

    @ViewBuilder
    private func scheduledContent(_ plan: HomeViewModel.Scheduled) -> some View {
        header(
            title: L("home.today.title"),
            systemImage: "figure.strengthtraining.traditional",
            tint: .appAccent,
            trailing: plan.isEasyWeek ? L("home.today.deloadChip") : nil
        )

        Text(plan.title)
            .font(.title2.weight(.bold))
            .foregroundStyle(Color.appTextPrimary)
            .fixedSize(horizontal: false, vertical: true)

        if !plan.focusGroups.isEmpty {
            FlowLayout(spacing: Metrics.spacing6, lineSpacing: Metrics.spacing6) {
                ForEach(plan.focusGroups) { group in
                    MuscleGroupBadge(group: group)
                }
            }
            .accessibilityElement(children: .combine)
        }

        Text(metadataLine(
            exercises: plan.exerciseCount,
            sets: plan.setCount,
            minutes: plan.estimatedMinutes
        ))
        .font(.subheadline)
        .foregroundStyle(Color.appTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

        Button(action: onStart) {
            Label(isBusy ? L("home.today.working") : L("home.today.start"), systemImage: "play.fill")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isBusy)
        .accessibilityLabel(Text(L(
            "home.today.startAccessibility",
            plan.title,
            metadataLine(exercises: plan.exerciseCount, sets: plan.setCount, minutes: plan.estimatedMinutes)
        )))
        // The spoken label names the session ("Start Upper A. 7 exercises…"), which is what a
        // VoiceOver user wants and what makes the control unaddressable by name. The identifier is
        // the stable handle.
        .accessibilityIdentifier(HomeAccessibility.todayAction)

        Button(L("home.today.viewProgram"), action: onViewProgram)
            .buttonStyle(SecondaryButtonStyle())
    }

    // MARK: - In progress

    @ViewBuilder
    private func inProgressContent(_ session: HomeViewModel.InProgress) -> some View {
        header(
            title: L("home.today.inProgress"),
            systemImage: "timer",
            tint: .appAccent,
            trailing: nil
        )

        Text(session.title)
            .font(.title2.weight(.bold))
            .foregroundStyle(Color.appTextPrimary)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            ProgressBar(value: Double(session.completedSets), total: Double(session.plannedSets))
            HStack(spacing: Metrics.spacing8) {
                Text(L("home.today.setsDone", session.completedSets, session.plannedSets))
                Text("·")
                Text(L("home.today.startedAt", formatter.time(session.startedAt)))
            }
            .font(.footnote)
            .foregroundStyle(Color.appTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)

        Button(action: onResume) {
            Label(L("home.today.resume"), systemImage: "arrow.right.circle.fill")
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityLabel(Text("\(L("home.today.resume")), \(session.title)"))
        .accessibilityIdentifier(HomeAccessibility.todayAction)
    }

    // MARK: - Completed

    @ViewBuilder
    private func completedContent(_ session: HomeViewModel.Completed) -> some View {
        header(
            title: L("home.today.doneTitle"),
            systemImage: "checkmark.seal.fill",
            tint: .appSuccess,
            trailing: nil
        )

        Text(L("home.today.doneMessage", session.title))
            .font(.headline)
            .foregroundStyle(Color.appTextPrimary)
            .fixedSize(horizontal: false, vertical: true)

        HStack(alignment: .top, spacing: Metrics.spacing12) {
            StatTile(
                value: "\(session.completedSets)",
                label: L("home.today.statSets"),
                systemImage: "checkmark"
            )
            StatTile(
                value: formatter.durationCompact(session.durationSeconds),
                label: L("home.today.statTime"),
                systemImage: "clock"
            )
            if session.volumeKg > 0 {
                StatTile(
                    value: formatter.volume(session.volumeKg),
                    label: L("home.today.statVolume"),
                    systemImage: "scalemass"
                )
            }
        }

        Button(L("home.today.viewSummary")) { onViewSummary(session.sessionID) }
            .buttonStyle(PrimaryButtonStyle(tint: .appAccent, isProminent: false))

        Button(L("home.today.trainAgain"), action: onStartLight)
            .accessibilityIdentifier(HomeAccessibility.todayAction)
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isBusy)
    }

    // MARK: - Rest

    @ViewBuilder
    private func restContent(_ rest: HomeViewModel.Rest) -> some View {
        header(
            title: L("home.today.restTitle"),
            systemImage: "moon.stars.fill",
            tint: .appRecovery,
            trailing: nil
        )

        Text(L("home.today.restMessage"))
            .font(.subheadline)
            .foregroundStyle(Color.appTextSecondary)
            .fixedSize(horizontal: false, vertical: true)

        if let nextTitle = rest.nextTitle {
            InsetGroup {
                HStack(spacing: Metrics.spacing8) {
                    Image(systemName: "calendar")
                        .font(.footnote)
                        .foregroundStyle(Color.appRecovery)
                    Text(nextUpText(title: nextTitle, weekday: rest.nextWeekday))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }

        Button(L("home.today.startLight"), action: onStartLight)
            .accessibilityIdentifier(HomeAccessibility.todayAction)
            .buttonStyle(PrimaryButtonStyle(tint: .appRecovery, isProminent: false))
            .disabled(isBusy)

        if let stretchID = rest.stretchExerciseID, let stretchName = rest.stretchName {
            Button {
                onOpenStretch(stretchID)
            } label: {
                HStack(spacing: Metrics.spacing8) {
                    Text(L("home.today.stretchSuggestion", stretchName))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Metrics.spacing8)
                    Text(L("home.today.stretchAction"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.appRecovery)
                }
                .frame(minHeight: Metrics.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L("home.today.stretchSuggestion", stretchName)))
            .accessibilityHint(Text(L("home.today.stretchAction")))
        }
    }

    // MARK: - No program

    @ViewBuilder
    private var noProgramContent: some View {
        header(
            title: L("home.today.noProgramTitle"),
            systemImage: "sparkles",
            tint: .appAccent,
            trailing: nil
        )

        Text(L("home.today.noProgramMessage"))
            .font(.subheadline)
            .foregroundStyle(Color.appTextSecondary)
            .fixedSize(horizontal: false, vertical: true)

        Button(action: onCreateProgram) {
            Label(
                isBusy ? L("home.today.creatingProgram") : L("home.today.createProgram"),
                systemImage: "wand.and.stars"
            )
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isBusy)
        .accessibilityIdentifier(HomeAccessibility.todayAction)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func header(title: String, systemImage: String, tint: Color, trailing: String?) -> some View {
        HStack(spacing: Metrics.spacing8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
                .textCase(.uppercase)
            Spacer(minLength: Metrics.spacing8)
            if let trailing {
                Chip(title: trailing, systemImage: "arrow.down.right", isSelected: true, tint: .appRecovery)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func metadataLine(exercises: Int, sets: Int, minutes: Int) -> String {
        [
            LPlural("home.today.exercises", exercises),
            LPlural("home.today.sets", sets),
            L("duration.minutes", minutes)
        ].joined(separator: " · ")
    }

    private func nextUpText(title: String, weekday: Weekday?) -> String {
        guard let weekday else { return L("home.today.restNextUnscheduled", title) }
        return L("home.today.restNext", title, L(weekday.localizationKey))
    }
}

#Preview("Scheduled") {
    PreviewHost(scenario: .freshProgram) {
        ScrollView {
            TodaySessionCard(
                state: .scheduled(.init(
                    templateID: UUID(),
                    title: "Upper A",
                    focusGroups: [.chest, .back, .shoulders, .triceps],
                    exerciseCount: 6,
                    setCount: 22,
                    estimatedMinutes: 58,
                    isEasyWeek: true
                )),
                onStart: {}, onResume: {}, onCreateProgram: {}, onViewProgram: {},
                onViewSummary: { _ in }, onStartLight: {}, onOpenStretch: { _ in }
            )
            .screenPadding()
        }
        .background(Color.appBackground)
    }
}

#Preview("Rest day") {
    PreviewHost(scenario: .seasonedUser) {
        ScrollView {
            TodaySessionCard(
                state: .rest(.init(
                    nextTitle: "Lower B",
                    nextWeekday: .thursday,
                    stretchExerciseID: "0001",
                    stretchName: "Standing Hamstring Stretch"
                )),
                onStart: {}, onResume: {}, onCreateProgram: {}, onViewProgram: {},
                onViewSummary: { _ in }, onStartLight: {}, onOpenStretch: { _ in }
            )
            .screenPadding()
        }
        .background(Color.appBackground)
    }
}
