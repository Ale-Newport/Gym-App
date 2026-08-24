import SwiftData
import SwiftUI

/// Where the Workout tab can navigate to.
///
/// Declared here rather than in the router because these destinations only exist inside this tab;
/// the router carries the *path*, not the vocabulary of every feature that pushes onto it.
enum WorkoutHubRoute: Hashable {
    case history
    case session(UUID)
    case exercise(String)
    case program
}

/// The two faces of the Workout tab.
enum HubSection: String, CaseIterable, Identifiable {
    case today
    case calendar

    var id: String { rawValue }
    var localizationKey: String { "workoutHub.section.\(rawValue)" }
    var symbolName: String {
        switch self {
        case .today: "figure.strengthtraining.traditional"
        case .calendar: "calendar"
        }
    }
}

/// The Workout tab's landing screen.
///
/// It opens on today because that is the question the user came to answer — "what am I doing now?" —
/// and the calendar and the history sit one tap away rather than competing with it. The active
/// workout is presented from here as a full-screen cover: once training starts, nothing else on
/// screen matters.
struct WorkoutHubView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext

    @State private var model = WorkoutHubViewModel()
    @State private var section: HubSection = .today

    var body: some View {
        @Bindable var model = model

        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                sectionPicker

                if let title = model.inProgressTitle, model.inProgressSessionID != nil {
                    resumeBanner(title: title)
                }

                switch section {
                case .today:
                    TodayWorkoutView(model: model)
                case .calendar:
                    TrainingCalendarView()
                }
            }
        }
        .navigationTitle(L("workoutHub.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.workoutPath.append(WorkoutHubRoute.history)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel(Text(L("workoutHub.history.title")))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.isPresentingQuickStart = true
                } label: {
                    Image(systemName: "bolt.fill")
                }
                .accessibilityLabel(Text(L("workoutHub.quickStart.title")))
            }
        }
        .navigationDestination(for: WorkoutHubRoute.self) { route in
            switch route {
            case .history:
                WorkoutHistoryView()
            case .session(let id):
                WorkoutSessionDetailView(sessionID: id)
            case .exercise(let id):
                ExerciseDetailView(exerciseID: id)
            case .program:
                ProgramOverviewView()
            }
        }
        .fullScreenCover(item: presentedWorkout) { presentation in
            ActiveWorkoutView(workoutID: presentation.id)
        }
        .sheet(isPresented: $model.isPresentingQuickStart) {
            QuickStartSheet(model: model)
        }
        .alert(
            L("workoutHub.error.title"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button(L("common.done")) { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
        .task(id: reloadToken) {
            await model.load(context: modelContext, catalog: environment.catalog)
            handlePendingDeepLink()
        }
    }

    // MARK: - Pieces

    private var sectionPicker: some View {
        Picker(L("workoutHub.section.picker"), selection: $section) {
            ForEach(HubSection.allCases) { value in
                Text(L(value.localizationKey)).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .screenPadding()
        .padding(.top, Metrics.spacing8)
        .padding(.bottom, Metrics.spacing12)
        .readableWidth()
    }

    private func resumeBanner(title: String) -> some View {
        Button {
            model.resumeInProgressSession(router: router)
        } label: {
            HStack(spacing: Metrics.spacing12) {
                Image(systemName: "figure.run")
                    .font(.headline)
                    .foregroundStyle(Color.appAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("workoutHub.resume.title"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Metrics.spacing8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(Metrics.spacing12)
            .frame(minHeight: Metrics.gymTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    .fill(Color.appAccentMuted)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L("workoutHub.resume.accessibility", title)))
        .screenPadding()
        .padding(.bottom, Metrics.spacing12)
        .readableWidth()
    }

    // MARK: - Presentation plumbing

    /// `fullScreenCover(item:)` needs an identifiable payload, and a bare `UUID` is not one.
    private struct PresentedWorkout: Identifiable, Hashable {
        let id: UUID
    }

    private var presentedWorkout: Binding<PresentedWorkout?> {
        Binding(
            get: { router.presentedWorkoutID.map(PresentedWorkout.init) },
            set: { router.presentedWorkoutID = $0?.id }
        )
    }

    /// Reloading when the tab is re-entered keeps "today" honest across midnight and across a
    /// workout finishing behind the cover.
    private var reloadToken: String {
        "\(router.selectedTab.rawValue)-\(router.presentedWorkoutID?.uuidString ?? "none")"
    }

    private func handlePendingDeepLink() {
        guard let link = router.pendingDeepLink else { return }
        router.pendingDeepLink = nil
        switch link {
        case .startTodayWorkout:
            section = .today
            if model.inProgressSessionID != nil {
                model.resumeInProgressSession(router: router)
            } else {
                model.startPlannedSession(router: router)
            }
        case .resumeActiveWorkout:
            section = .today
            model.resumeInProgressSession(router: router)
        case .todayWorkout:
            section = .today
        default:
            break
        }
    }
}

#Preview("Today") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack { WorkoutHubView() }
    }
}

#Preview("No program") {
    PreviewHost(scenario: .newUser) {
        NavigationStack { WorkoutHubView() }
    }
}
