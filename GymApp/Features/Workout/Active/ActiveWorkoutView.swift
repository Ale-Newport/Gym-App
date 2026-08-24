import SwiftData
import SwiftUI

/// The live workout, presented full screen from Home and from the Workout tab.
///
/// This screen is used one-handed, mid-set, in a noisy gym, so it is built around a single rule:
/// **one exercise owns the screen, and its animation never leaves it.** The container therefore does
/// very little of its own — it sizes the animation once for the device, pages between exercises,
/// hands the rest countdown a slot that cannot cover the Complete Set button, and routes the four
/// modals. Everything else lives in `ActiveExerciseCard` and in `ActiveWorkoutViewModel`, which owns
/// the state machine, the persistence and the timers.
struct ActiveWorkoutView: View {
    let workoutID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: ActiveWorkoutViewModel

    init(workoutID: UUID) {
        self.workoutID = workoutID
        _model = State(initialValue: ActiveWorkoutViewModel(workoutID: workoutID))
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appBackground)
                .navigationTitle(model.session?.titleSnapshot ?? L("active.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .task { await model.load(context: modelContext, environment: environment) }
        // Releases the idle-timer override and the tickers. The user may leave the screen with the
        // workout still running, so this is the only place that is guaranteed to run.
        .onDisappear { model.teardown() }
        .onChange(of: scenePhase) { _, phase in model.handleScenePhase(phase) }
        .sheet(item: $model.presentedSheet) { sheet in
            sheetContent(sheet)
        }
        .confirmationDialog(
            L("active.discard.title"),
            isPresented: $model.showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("active.discard.action"), role: .destructive) {
                model.discard()
                dismiss()
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(discardMessage)
        }
        .alert(
            L("active.error.title"),
            isPresented: Binding(
                get: { model.failure != nil },
                set: { if !$0 { model.failure = nil } }
            ),
            presenting: model.failure
        ) { failure in
            Button(L("common.retry")) { failure.retry() }
            Button(L("common.cancel"), role: .cancel) { model.failure = nil }
        } message: { failure in
            Text(failure.message)
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("active.loading"))
        case .failed(let message):
            ScrollView {
                ErrorStateView(message: message, retryTitle: L("common.retry")) {
                    Task { await model.retryLoad() }
                }
                .readableWidth()
            }
        case .ready:
            ready
        }
    }

    /// An in-progress session with no exercises is a real state: a freestyle session starts empty and
    /// is filled in as the user goes.
    @ViewBuilder
    private var ready: some View {
        if model.orderedExercises.isEmpty {
            ScrollView {
                EmptyStateView(
                    systemImage: "figure.strengthtraining.traditional",
                    title: L("active.empty.title"),
                    message: L("active.empty.message")
                ) {
                    Button(L("active.addExercise")) { model.presentedSheet = .edit }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: 280)
                }
                .readableWidth()
                .screenPadding()
            }
        } else {
            // The geometry is read outside the rest-timer inset on purpose: the animation is sized
            // once from the full screen, so starting a rest period never resizes it.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    progressStrip
                        .screenPadding()
                        .padding(.vertical, Metrics.spacing8)
                        .readableWidth()

                    // The credit rides with the artwork. When the hero is collapsed the card stops
                    // drawing it, so the container carries it instead — showing it is a licence
                    // condition, not a preference.
                    if model.isMediaCollapsed {
                        MediaAttributionLabel(
                            attribution: environment.mediaProvider.attribution,
                            url: environment.mediaProvider.attributionURL
                        )
                        .screenPadding()
                        .padding(.bottom, Metrics.spacing4)
                    }

                    pager(heroMaxHeight: heroMaxHeight(for: proxy.size.height))
                        .safeAreaInset(edge: .bottom, spacing: 0) { restLayer }
                }
            }
        }
    }

    // MARK: - Pager

    private func pager(heroMaxHeight: CGFloat) -> some View {
        TabView(selection: pageSelection) {
            ForEach(Array(model.orderedExercises.enumerated()), id: \.element.id) { index, record in
                ActiveExerciseCard(
                    record: record,
                    position: index + 1,
                    total: model.orderedExercises.count,
                    isCurrent: index == model.currentIndex,
                    heroMaxHeight: heroMaxHeight,
                    model: model
                )
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var pageSelection: Binding<Int> {
        Binding(
            get: { model.currentIndex },
            set: { model.select(index: $0) }
        )
    }

    /// How tall the animation may be on this device.
    ///
    /// Roughly a third of the screen, floored so that a small phone shrinks the artwork rather than
    /// reducing it to a thumbnail, and capped so a large phone does not push the set list off screen.
    private func heroMaxHeight(for height: CGFloat) -> CGFloat {
        min(max(height * 0.30, 156), 320)
    }

    // MARK: - Progress strip

    private var progressStrip: some View {
        HStack(spacing: Metrics.spacing8) {
            stepButton(
                systemImage: "chevron.left",
                label: L("active.previousExercise"),
                isEnabled: model.currentIndex > 0,
                action: { model.goToPreviousExercise() }
            )

            VStack(spacing: Metrics.spacing6) {
                HStack(spacing: 3) {
                    ForEach(Array(model.orderedExercises.enumerated()), id: \.element.id) { index, record in
                        segment(record, isCurrent: index == model.currentIndex)
                    }
                }
                .accessibilityHidden(true)

                HStack(spacing: Metrics.spacing8) {
                    Text(L("active.progress.sets", model.completedWorkingSets, model.plannedWorkingSets))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Metrics.spacing8)
                    elapsedLabel
                }
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(stripAccessibilityLabel))

            stepButton(
                systemImage: "chevron.right",
                label: L("active.nextExercise"),
                isEnabled: model.currentIndex + 1 < model.orderedExercises.count,
                action: { model.goToNextExercise() }
            )
        }
    }

    /// One exercise's share of the session, filled by the working sets already logged.
    ///
    /// Colour is never the only signal: the sets line underneath states the same progress in words,
    /// and the card names the exercise the user is on.
    private func segment(_ record: ExerciseSession, isCurrent: Bool) -> some View {
        let planned = max(record.workingSets.count, 1)
        let fraction = record.wasSkipped
            ? 0
            : min(1, Double(record.completedWorkingSets.count) / Double(planned))

        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.appFill)
                if fraction > 0 {
                    Capsule()
                        .fill(Color.appSuccess)
                        .frame(width: proxy.size.width * fraction)
                }
            }
        }
        .frame(height: 6)
        .frame(maxWidth: .infinity)
        .overlay(Capsule().strokeBorder(Color.appAccent, lineWidth: isCurrent ? 1.5 : 0))
        .opacity(record.wasSkipped ? 0.4 : 1)
    }

    /// Ticks once a second so the elapsed time is live without the view model owning another timer.
    /// The value counts foreground training time, not wall-clock time since the session started.
    private var elapsedLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: Metrics.spacing4) {
                Image(systemName: "stopwatch")
                    .font(.caption2)
                Text(Units.formatDuration(seconds: model.activeSeconds))
                    .monospacedDigit()
            }
        }
    }

    private var stripAccessibilityLabel: String {
        [
            L("active.progress.exercise", model.currentIndex + 1, model.orderedExercises.count),
            L("active.progress.sets", model.completedWorkingSets, model.plannedWorkingSets),
            L("active.elapsed", Units.formatDuration(seconds: model.activeSeconds))
        ].joined(separator: ", ")
    }

    private func stepButton(
        systemImage: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled ? Color.appTextPrimary : Color.appTextTertiary)
                .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                .background(Color.appFill, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(label))
    }

    // MARK: - Rest

    /// The rest countdown takes a bottom inset rather than an overlay, so it pushes the Complete Set
    /// button up instead of covering it. The end-of-rest banner reuses the same slot for its few
    /// seconds, which is why the two can never fight over the bottom of the screen.
    @ViewBuilder
    private var restLayer: some View {
        if model.restTimer.isRunning {
            RestTimerView(
                timer: model.restTimer,
                nextUp: restNextUp,
                onAdjust: { model.adjustRest(by: $0) },
                onSkip: { model.skipRest() }
            )
            .screenPadding()
            .padding(.bottom, Metrics.spacing8)
            .readableWidth()
        } else if model.restJustFinished {
            RestFinishedBanner()
                .padding(.bottom, Metrics.spacing8)
        }
    }

    /// What the rest period is for — the next set of this exercise, or the next exercise.
    private var restNextUp: String? {
        guard let record = model.currentExercise else { return nil }
        if let next = model.activeSet(in: record) {
            return next.kind == .warmup
                ? L("active.rest.nextWarmup")
                : L("active.rest.nextSet", next.setIndex + 1)
        }
        let exercises = model.orderedExercises
        let nextIndex = model.currentIndex + 1
        guard exercises.indices.contains(nextIndex) else { return nil }
        return L("active.rest.nextExercise", exercises[nextIndex].exerciseNameSnapshot.localizedCapitalized)
    }

    // MARK: - Toolbar

    private var isReady: Bool { model.phase == .ready }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // Leaving the screen does not end the workout: Home and the Workout tab both show a
            // resume banner, and the Live Activity keeps running.
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .minimumTapTarget()
            }
            .accessibilityLabel(Text(L("active.minimise")))
            .accessibilityHint(Text(L("active.minimise.hint")))
        }

        if isReady {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !model.restTimer.isRunning {
                        Button {
                            model.startRestForCurrentExercise()
                        } label: {
                            Label(L("active.rest.start"), systemImage: "timer")
                        }
                        .disabled(model.currentExercise == nil)
                    }
                    Button {
                        model.presentedSheet = .edit
                    } label: {
                        Label(L("active.editSession"), systemImage: "slider.horizontal.3")
                    }
                    Divider()
                    Button(role: .destructive) {
                        model.showsDiscardConfirmation = true
                    } label: {
                        Label(L("active.discard.action"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .minimumTapTarget()
                }
                .accessibilityLabel(Text(L("active.sessionOptions")))
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(L("active.finish")) {
                    model.prepareSummary()
                    model.presentedSheet = .finish
                }
                .font(.headline)
            }
        }
    }

    private var discardMessage: String {
        let impact = model.discardImpact
        return L(
            "active.discard.message",
            LPlural("active.discard.sets", impact.sets),
            formatter.durationCompact(impact.seconds)
        )
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveWorkoutSheet) -> some View {
        switch sheet {
        case .substitute(let recordID):
            if let record = model.orderedExercises.first(where: { $0.id == recordID }) {
                ExerciseSubstitutionSheet(
                    exerciseID: record.exerciseID,
                    sessionExerciseIDs: model.sessionExerciseIDs
                ) { exercise, reason in
                    model.substitute(record, with: exercise, reason: reason)
                }
            }
        case .calibrate(let recordID):
            if let record = model.orderedExercises.first(where: { $0.id == recordID }) {
                // Swiping this away would leave the exercise waiting to be calibrated and the sheet
                // would return after the next set, so the answer is given through the sheet's own
                // controls — one of which is "leave it as it is".
                CalibrationSheet(record: record, model: model)
                    .interactiveDismissDisabled()
            }
        case .edit:
            ActiveWorkoutEditSheet(model: model)
        case .finish:
            WorkoutFinishView(model: model) {
                model.presentedSheet = nil
                dismiss()
            }
        }
    }
}

#Preview("Active workout") {
    PreviewHost(scenario: .activeWorkout) {
        ActiveWorkoutPreviewHarness()
    }
}

/// Opens whichever session the sample data left in progress, so the preview never depends on an
/// identifier the builder does not produce.
private struct ActiveWorkoutPreviewHarness: View {
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var sessions: [WorkoutSession]

    var body: some View {
        if let session = sessions.first(where: { $0.status == .inProgress }) {
            ActiveWorkoutView(workoutID: session.id)
        } else {
            EmptyStateView(
                systemImage: "figure.strengthtraining.traditional",
                title: L("active.empty.title"),
                message: L("active.empty.message")
            )
        }
    }
}
