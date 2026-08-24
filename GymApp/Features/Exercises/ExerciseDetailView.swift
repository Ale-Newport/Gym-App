import SwiftUI
import SwiftData
import Charts

/// Everything the app knows about one exercise, and everything the user can do with it.
///
/// The order of the screen is the order of the questions somebody actually asks: what does it look
/// like, what is it for, how do I do it, how have I done it before, and then — once they have
/// decided — put it in my training. The animation is first and large because seeing the movement is
/// the thing this screen exists for.
struct ExerciseDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ExerciseDetailViewModel
    @State private var isPresentingAlternatives = false
    @State private var isPresentingTemplatePicker = false

    init(exerciseID: String) {
        _viewModel = State(initialValue: ExerciseDetailViewModel(exerciseID: exerciseID))
    }

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(viewModel.exercise?.name.localizedCapitalized ?? L("exercises.detail.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if viewModel.phase == .ready {
                    ToolbarItem(placement: .topBarTrailing) { favoriteButton }
                }
            }
            .task {
                await viewModel.load(
                    catalog: environment.catalog,
                    instructionStore: environment.instructionStore,
                    context: modelContext,
                    language: LocalizationManager.shared.current
                )
            }
            .sheet(isPresented: $isPresentingAlternatives) {
                ExerciseAlternativesSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $isPresentingTemplatePicker) {
                TemplatePickerSheet(viewModel: viewModel)
            }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            LoadingStateView(message: L("common.loading"))
        case .failed(let message):
            ErrorStateView(message: message, retryTitle: L("common.retry")) {
                viewModel.reload(context: modelContext)
            }
            .readableWidth()
        case .missing:
            EmptyStateView(
                systemImage: "questionmark.folder",
                title: L("exercises.detail.missing.title"),
                message: L("exercises.detail.missing.message")
            ) {
                Button(L("common.back")) { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 240)
            }
            .readableWidth()
        case .ready:
            readyContent
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if let exercise = viewModel.exercise {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing20) {
                    if let banner = viewModel.banner {
                        BannerCard(banner: banner) { follow(banner.follow) } dismiss: {
                            viewModel.banner = nil
                        }
                    }

                    ExerciseMediaHero(
                        exercise: exercise,
                        animationURL: environment.mediaProvider.animationURL(for: exercise),
                        thumbnailURL: environment.mediaProvider.thumbnailURL(for: exercise),
                        attribution: environment.mediaProvider.attribution,
                        attributionURL: environment.mediaProvider.attributionURL
                    )

                    header(exercise)
                    primaryActions
                    feedbackCard
                    historyCard(exercise)
                    instructionsCard
                    factsCard(exercise)
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.bottom, Metrics.spacing40)
                .readableWidth()
            }
        }
    }

    // MARK: - Header

    private func header(_ exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text(exercise.name.localizedCapitalized)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: Metrics.spacing6, lineSpacing: Metrics.spacing6) {
                MuscleGroupBadge(group: exercise.primaryGroup, showsIcon: true)
                Chip(title: L(exercise.equipment.localizationKey), systemImage: exercise.equipment.symbolName)
                Chip(title: L(exercise.metadata.mechanic.localizationKey))
                Chip(title: L(exercise.metadata.difficulty.localizationKey))
                if viewModel.isExcluded {
                    Chip(title: L("exercise.excluded"), systemImage: "nosign", isSelected: true, tint: .appWarning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var favoriteButton: some View {
        Button {
            viewModel.toggleFavorite(context: modelContext)
        } label: {
            Image(systemName: viewModel.isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(viewModel.isFavorite ? Color.appAccent : Color.appTextSecondary)
                .minimumTapTarget()
        }
        .accessibilityLabel(Text(viewModel.isFavorite
            ? L("exercises.action.unfavorite")
            : L("exercises.action.favorite")))
        .accessibilityAddTraits(viewModel.isFavorite ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Actions

    private var primaryActions: some View {
        VStack(spacing: Metrics.spacing12) {
            Button {
                viewModel.addToTodaysWorkout(context: modelContext)
            } label: {
                Label(L("exercises.action.addToToday"), systemImage: "plus.circle.fill")
            }
            .buttonStyle(PrimaryButtonStyle())

            HStack(spacing: Metrics.spacing12) {
                Button {
                    viewModel.loadTemplateChoices(context: modelContext)
                    isPresentingTemplatePicker = true
                } label: {
                    Label(L("exercises.action.addToTemplate"), systemImage: "calendar.badge.plus")
                }
                .buttonStyle(SecondaryButtonStyle())

                Button {
                    isPresentingAlternatives = true
                } label: {
                    Label(L("exercises.action.findAlternatives"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Button {
                viewModel.toggleExcluded(context: modelContext)
            } label: {
                Label(
                    viewModel.isExcluded ? L("exercises.action.include") : L("exercises.action.exclude"),
                    systemImage: viewModel.isExcluded ? "arrow.uturn.backward.circle" : "nosign"
                )
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityHint(Text(L("exercises.action.exclude.hint")))
        }
    }

    private var feedbackCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(L("exercises.feedback.title"), subtitle: L("exercises.feedback.subtitle"))
                FlowLayout(spacing: Metrics.spacing8, lineSpacing: Metrics.spacing8) {
                    ForEach(ExerciseFeedback.allCases) { option in
                        Button {
                            viewModel.setFeedback(option, context: modelContext)
                        } label: {
                            Chip(
                                title: L(option.localizationKey),
                                systemImage: option.symbolName,
                                isSelected: viewModel.feedback == option
                            )
                            .frame(minHeight: Metrics.minimumTapTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(L(option.localizationKey)))
                        .accessibilityAddTraits(
                            viewModel.feedback == option ? [.isButton, .isSelected] : .isButton
                        )
                    }
                }
            }
        }
    }

    // MARK: - History

    @ViewBuilder
    private func historyCard(_ exercise: Exercise) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                SectionHeader(L("exercises.history.title"))

                if viewModel.hasHistory {
                    statGrid(exercise)
                    chartSection
                    NavigationLink(value: ExerciseRoute.history(viewModel.exerciseID)) {
                        HStack {
                            Text(L("exercises.history.viewAll"))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote)
                        }
                        .foregroundStyle(Color.appAccent)
                        .frame(minHeight: Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    EmptyStateView(
                        systemImage: "chart.line.uptrend.xyaxis",
                        title: L("exercises.history.empty.title"),
                        message: L("exercises.history.empty.message")
                    ) {
                        Button(L("exercises.action.addToToday")) {
                            viewModel.addToTodaysWorkout(context: modelContext)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 260)
                    }
                }
            }
        }
    }

    private func statGrid(_ exercise: Exercise) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: Metrics.spacing12, alignment: .leading)],
            alignment: .leading,
            spacing: Metrics.spacing16
        ) {
            if let lastPerformedAt = viewModel.lastPerformedAt ?? viewModel.history.lastPerformedAt {
                StatTile(
                    value: formatter.relativeDay(lastPerformedAt),
                    label: L("exercises.history.lastPerformed"),
                    systemImage: "calendar"
                )
            }
            if let load = viewModel.lastLoadKg {
                StatTile(
                    value: formatter.weight(load),
                    label: L("exercises.history.lastLoad"),
                    caption: viewModel.lastPerformanceReps.map { LPlural("exercises.history.reps", $0) },
                    systemImage: "scalemass"
                )
            }
            if let best = viewModel.bestSet {
                StatTile(
                    value: L("exercises.history.setFormat", formatter.weight(best.weightKg), best.reps),
                    label: L("exercises.history.bestSet"),
                    systemImage: "trophy"
                )
            }
            if let oneRepMax = viewModel.estimatedOneRepMaxKg {
                StatTile(
                    value: formatter.weight(oneRepMax),
                    label: L("exercises.history.oneRepMax"),
                    caption: L("exercises.history.oneRepMax.caption"),
                    tint: .appAccent,
                    systemImage: "bolt"
                )
            }
            StatTile(
                value: formatter.volume(viewModel.totalVolumeKg),
                label: L("exercises.history.totalVolume"),
                systemImage: "sum"
            )
            StatTile(
                value: String(viewModel.totalSessions),
                label: L("exercises.history.sessions"),
                caption: viewModel.timesPerformed > viewModel.totalSessions
                    ? LPlural("exercises.history.logged", viewModel.timesPerformed)
                    : nil,
                systemImage: "figure.strengthtraining.traditional"
            )
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        let metrics = viewModel.availableMetrics
        if metrics.isEmpty {
            Text(L("exercises.history.noChart"))
                .font(.footnote)
                .foregroundStyle(Color.appTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                if metrics.count > 1 {
                    Picker(L("exercises.trend.label"), selection: Binding(
                        get: { metrics.contains(viewModel.trendMetric) ? viewModel.trendMetric : metrics[0] },
                        set: { viewModel.trendMetric = $0 }
                    )) {
                        ForEach(metrics) { metric in
                            Text(L(metric.localizationKey)).tag(metric)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                strengthChart(for: metrics.contains(viewModel.trendMetric) ? viewModel.trendMetric : metrics[0])
            }
        }
    }

    private func strengthChart(for metric: ExerciseTrendMetric) -> some View {
        let samples = viewModel.samples(for: metric)
        let unitLabel = L(metric.localizationKey)
        return Chart(samples) { sample in
            LineMark(
                x: .value(L("exercises.trend.date"), sample.date),
                y: .value(unitLabel, formatter.weightValue(sample.valueKg))
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(Color.appAccent)

            PointMark(
                x: .value(L("exercises.trend.date"), sample.date),
                y: .value(unitLabel, formatter.weightValue(sample.valueKg))
            )
            .symbolSize(28)
            .foregroundStyle(Color.appAccent)
        }
        .chartYAxisLabel(formatter.weightUnitLabel)
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 180)
        // One series with a labelled axis, so nothing here depends on telling colours apart. For
        // VoiceOver the shape is summarised instead of read point by point.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("exercises.trend.chartLabel", unitLabel)))
        .accessibilityValue(Text(chartSummary(samples)))
    }

    private func chartSummary(_ samples: [ExerciseTrendSample]) -> String {
        guard let first = samples.first, let last = samples.last else { return L("common.none") }
        return L(
            "exercises.trend.summary",
            samples.count,
            formatter.weight(first.valueKg),
            formatter.shortDate(first.date),
            formatter.weight(last.valueKg),
            formatter.shortDate(last.date)
        )
    }

    // MARK: - Instructions and facts

    private var instructionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(L("exercises.instructions.title"))
                if viewModel.isLoadingInstructions {
                    HStack(spacing: Metrics.spacing8) {
                        ProgressView()
                        Text(L("common.loading"))
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ExerciseInstructionsView(steps: viewModel.instructions)
                }
            }
        }
    }

    private func factsCard(_ exercise: Exercise) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                SectionHeader(L("exercises.facts.title"))
                ExerciseFactsGrid(exercise: exercise)
            }
        }
    }

    // MARK: - Banner follow-up

    private func follow(_ action: ExerciseDetailViewModel.Banner.Follow) {
        switch action {
        case .none:
            break
        case .openWorkoutTab:
            router.selectedTab = .workout
        case .openActiveWorkout(let id):
            router.presentedWorkoutID = id
        }
        viewModel.banner = nil
    }
}

// MARK: - Banner

/// Confirms an action, or explains why one failed, without stealing focus the way an alert does.
private struct BannerCard: View {
    let banner: ExerciseDetailViewModel.Banner
    let follow: () -> Void
    let dismiss: () -> Void

    var body: some View {
        Card(background: banner.isError ? Color.appDanger.opacity(0.1) : Color.appSuccess.opacity(0.1)) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                HStack(alignment: .top, spacing: Metrics.spacing8) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(banner.isError ? Color.appDanger : Color.appSuccess)
                    Text(banner.message)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Metrics.spacing8)
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.appTextSecondary)
                            .minimumTapTarget()
                    }
                    .accessibilityLabel(Text(L("common.close")))
                }

                if banner.follow != .none {
                    Button(action: follow) {
                        Text(followTitle)
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: Metrics.minimumTapTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var followTitle: String {
        switch banner.follow {
        case .none: ""
        case .openWorkoutTab: L("exercises.action.goToWorkouts")
        case .openActiveWorkout: L("exercises.action.openWorkout")
        }
    }
}

// MARK: - Alternatives

/// The substitution engine's answer to "give me something else that trains this".
///
/// Presented in its own navigation stack so tapping a candidate opens *its* detail screen inside the
/// sheet. That keeps the exploration self-contained: the user can dig through three alternatives and
/// still be one swipe away from the exercise they started on.
private struct ExerciseAlternativesSheet: View {
    let viewModel: ExerciseDetailViewModel

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoadingAlternatives {
                    LoadingStateView(message: L("exercises.alternatives.loading"))
                } else if viewModel.alternatives.isEmpty {
                    EmptyStateView(
                        systemImage: "arrow.triangle.2.circlepath",
                        title: L("exercises.alternatives.empty.title"),
                        message: L("exercises.alternatives.empty.message")
                    ) {
                        Button(L("common.retry")) {
                            Task { await viewModel.loadAlternatives(catalog: environment.catalog, context: modelContext) }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 240)
                    }
                } else {
                    list
                }
            }
            .background(Color.appBackground)
            .navigationTitle(L("exercises.alternatives.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.done")) { dismiss() }
                }
            }
            .navigationDestination(for: ExerciseRoute.self) { route in
                switch route {
                case .detail(let id): ExerciseDetailView(exerciseID: id)
                case .history(let id): ExerciseHistoryView(exerciseID: id)
                }
            }
        }
        .task { await viewModel.loadAlternatives(catalog: environment.catalog, context: modelContext) }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing12) {
                ForEach(viewModel.alternatives) { candidate in
                    NavigationLink(value: ExerciseRoute.detail(candidate.exercise.id)) {
                        Card {
                            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                                ExerciseRowView(
                                    exercise: candidate.exercise,
                                    thumbnailURL: environment.mediaProvider.thumbnailURL(for: candidate.exercise),
                                    detail: L("exercises.alternatives.similarity", Int((candidate.similarity * 100).rounded())),
                                    trailingSystemImage: "chevron.right"
                                )
                                ForEach(Array(candidate.reasons.enumerated()), id: \.offset) { _, reason in
                                    ExplanationNote(text: reason.text, systemImage: "checkmark.seal")
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                MediaAttributionLabel(
                    attribution: environment.mediaProvider.attribution,
                    url: environment.mediaProvider.attributionURL
                )
                .frame(maxWidth: .infinity)
                .padding(.top, Metrics.spacing12)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, Metrics.spacing16)
            .readableWidth()
        }
    }
}

// MARK: - Template picker

/// Chooses which training day the exercise joins.
private struct TemplatePickerSheet: View {
    let viewModel: ExerciseDetailViewModel

    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.templateChoices.isEmpty {
                    EmptyStateView(
                        systemImage: "calendar.badge.exclamationmark",
                        title: L("exercises.templates.empty.title"),
                        message: L("exercises.templates.empty.message")
                    ) {
                        Button(L("exercises.action.goToWorkouts")) {
                            router.selectedTab = .workout
                            dismiss()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 260)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: Metrics.spacing8) {
                            ForEach(viewModel.templateChoices) { choice in
                                Button {
                                    viewModel.addToTemplate(choice, context: modelContext)
                                    dismiss()
                                } label: {
                                    templateRow(choice)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Metrics.screenPadding)
                        .padding(.vertical, Metrics.spacing16)
                        .readableWidth()
                    }
                }
            }
            .background(Color.appBackground)
            .navigationTitle(L("exercises.templates.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.cancel")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func templateRow(_ choice: TemplateChoice) -> some View {
        Card {
            HStack(spacing: Metrics.spacing12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(choice.isInActiveProgram
                        ? L("exercises.templates.activeProgram", choice.programTitle)
                        : choice.programTitle)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Metrics.spacing8)
                Text(LPlural("exercises.templates.exerciseCount", choice.exerciseCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.appTextTertiary)
                Image(systemName: "plus.circle")
                    .foregroundStyle(Color.appAccent)
            }
            .frame(minHeight: Metrics.minimumTapTarget)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("Detail") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            // Barbell bench press: the record in the fixture with the deepest history.
            ExerciseDetailView(exerciseID: "0025")
        }
    }
}
