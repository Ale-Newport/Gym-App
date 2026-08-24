import SwiftUI
import SwiftData

/// Destinations pushed from Home. Settings lives behind the profile button rather than in a sixth
/// tab, and the program and session-summary screens are reachable from the cards that mention them.
enum HomeDestination: Hashable {
    case settings
    case program
    case sessionDetail(UUID)
}

/// The screen the user opens most.
///
/// Its job is to answer one question — *what should I do right now?* — and then get out of the way.
/// Cards are therefore conditional: each one appears only when it has something to say, and the
/// order puts the thing the user came for first. Everything expensive happens in `HomeViewModel`,
/// so this file is layout, navigation and nothing else.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model = HomeViewModel()

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                LoadingStateView(message: L("home.loading"))
            case .failed(let explanation):
                ErrorStateView(message: explanation.text, retryTitle: L("common.retry")) {
                    Task { await model.refresh() }
                }
                .readableWidth()
            case .content:
                if model.isEmpty { emptyState } else { dashboard }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.appBackground)
        .navigationTitle(greeting)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.homePath.append(HomeDestination.settings)
                } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.title3)
                        .minimumTapTarget()
                }
                .accessibilityLabel(Text(L("home.profileButton")))
            }
        }
        .navigationDestination(for: HomeDestination.self) { destination in
            switch destination {
            case .settings: SettingsView()
            case .program: ProgramOverviewView()
            case .sessionDetail(let id): WorkoutSessionDetailView(sessionID: id)
            }
        }
        .task {
            await model.bootstrap(context: modelContext, environment: environment)
            handleDeepLink(router.pendingDeepLink)
        }
        .fullScreenCover(item: activeWorkoutPresentation) { presentation in
            ActiveWorkoutView(workoutID: presentation.id)
        }
        .onChange(of: router.pendingDeepLink) { _, link in handleDeepLink(link) }
    }

    // MARK: - Content

    private var dashboard: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing16) {
                Text(formatter.weekdayAndDate(Date()))
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let failure = model.actionFailure {
                    actionFailureBanner(failure)
                }

                // A pending deload changes what today *should* look like, so it comes before the
                // session card — unless a workout is already running, in which case nothing outranks
                // getting back into it.
                if isWorkoutRunning {
                    todayCard
                    deloadCard
                } else {
                    deloadCard
                    todayCard
                }

                if let recovery = model.recovery {
                    RecoveryCard(summary: recovery, isBusy: model.isBusy) { answers in
                        Task {
                            await model.saveCheckIn(
                                energy: answers.energy,
                                sleepQuality: answers.sleepQuality,
                                soreness: answers.soreness,
                                motivation: answers.motivation
                            )
                        }
                    }
                }

                if let nutrition = model.nutrition {
                    NutritionSummaryCard(
                        summary: nutrition,
                        isBusy: model.isBusy,
                        onOpen: { router.selectedTab = .nutrition },
                        onAddWater: { Task { await model.logWater() } }
                    )
                }

                if let progress = model.progress {
                    ProgressSummaryCard(
                        summary: progress,
                        onOpen: { router.selectedTab = .progress },
                        onLogWeight: {
                            // The weigh-in sheet belongs to the Progress tab, which owns the entry
                            // flow; the router carries the request across.
                            router.handle(.logBodyWeight)
                        }
                    )
                }
            }
            .screenPadding()
            .padding(.vertical, Metrics.spacing16)
            .readableWidth()
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.refresh() }
    }

    private var todayCard: some View {
        TodaySessionCard(
            state: model.today,
            isBusy: model.isBusy,
            onStart: { start() },
            onResume: { resume() },
            onCreateProgram: { Task { await model.generateProgram() } },
            onViewProgram: { router.homePath.append(HomeDestination.program) },
            onViewSummary: { router.homePath.append(HomeDestination.sessionDetail($0)) },
            onStartLight: { startLight() },
            onOpenStretch: { router.handle(.exercise($0)) }
        )
    }

    @ViewBuilder
    private var deloadCard: some View {
        if let prompt = model.deload {
            DeloadPromptCard(prompt: prompt, isBusy: model.isBusy) { response in
                Task { await model.respondToDeload(response) }
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "figure.strengthtraining.traditional",
            title: L("home.empty.title"),
            message: L("home.empty.message")
        ) {
            Button(action: { Task { await model.generateProgram() } }) {
                Label(
                    model.isBusy ? L("home.today.creatingProgram") : L("home.empty.action"),
                    systemImage: "wand.and.stars"
                )
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isBusy)
            .frame(maxWidth: 320)
        }
        .readableWidth()
        .padding(.top, Metrics.spacing40)
    }

    /// An action failed. The screen stays usable and the message offers the one thing that can help.
    private func actionFailureBanner(_ explanation: Explanation) -> some View {
        Card(background: .appSurfaceElevated) {
            HStack(alignment: .top, spacing: Metrics.spacing12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.appWarning)
                    .accessibilityHidden(true)
                Text(explanation.text)
                    .font(.footnote)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Metrics.spacing8)
                Button(L("common.retry")) {
                    model.dismissActionFailure()
                    Task { await model.refresh() }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.appAccent)
                .minimumTapTarget()
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Actions

    private func start() {
        Task {
            if let id = await model.startScheduledSession() {
                Haptics.success()
                router.presentedWorkoutID = id
            }
        }
    }

    private func startLight() {
        Task {
            if let id = await model.startLightSession() {
                Haptics.success()
                router.presentedWorkoutID = id
            }
        }
    }

    private func resume() {
        guard case .inProgress(let session) = model.today else { return }
        router.presentedWorkoutID = session.sessionID
    }

    private var isWorkoutRunning: Bool {
        if case .inProgress = model.today { return true }
        return false
    }

    // MARK: - Deep links

    /// Widgets, App Intents and Shortcuts all arrive here through `AppRouter`.
    ///
    /// The link is only consumed while Home is the selected tab: `AppRouter.handle` sends training
    /// links to the Workout tab, and whichever screen is actually on screen should be the one that
    /// acts on them — never both.
    private func handleDeepLink(_ link: AppDeepLink?) {
        guard router.selectedTab == .home, let link else { return }
        switch link {
        case .startTodayWorkout, .todayWorkout:
            router.pendingDeepLink = nil
            if case .inProgress = model.today { resume() } else { start() }
        case .resumeActiveWorkout:
            router.pendingDeepLink = nil
            resume()
        default:
            break
        }
    }

    // MARK: - Presentation

    /// Wraps the router's workout id so `fullScreenCover(item:)` can carry it.
    private struct WorkoutPresentation: Identifiable {
        let id: UUID
    }

    /// Gated on the Home tab so that only the visible tab ever presents the workout, however many
    /// tabs the user has already visited in this session.
    private var activeWorkoutPresentation: Binding<WorkoutPresentation?> {
        Binding(
            get: {
                guard router.selectedTab == .home, let id = router.presentedWorkoutID else { return nil }
                return WorkoutPresentation(id: id)
            },
            set: { newValue in
                router.presentedWorkoutID = newValue?.id
                if newValue == nil {
                    Task { await model.handleWorkoutDismissed() }
                }
            }
        )
    }

    // MARK: - Greeting

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let slot: String
        switch hour {
        case 5..<12: slot = "morning"
        case 12..<18: slot = "afternoon"
        case 18..<23: slot = "evening"
        default: slot = "night"
        }
        if let name = model.userName {
            return L("home.greeting.\(slot).named", name)
        }
        return L("home.greeting.\(slot)")
    }
}

#Preview("Seasoned user") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack { HomeView() }
    }
}

#Preview("First launch") {
    PreviewHost(scenario: .newUser) {
        NavigationStack { HomeView() }
    }
}

#Preview("Workout in progress") {
    PreviewHost(scenario: .activeWorkout) {
        NavigationStack { HomeView() }
    }
}
