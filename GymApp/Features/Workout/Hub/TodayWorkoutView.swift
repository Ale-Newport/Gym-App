import SwiftData
import SwiftUI

/// Today's session, in full, before a single set is logged.
///
/// The screen exists because a plan the user cannot inspect is a plan they cannot trust. Every
/// exercise shows its sets, its rep target, the load the progression engine arrived at and the
/// sentence explaining why — and every one of those numbers is editable here, because the person
/// holding the phone knows things the engine does not. The edits change the session that is about to
/// start, never the template behind it: today's bad shoulder must not rewrite every future push day.
struct TodayWorkoutView: View {
    let model: WorkoutHubViewModel

    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expandedItemID: UUID?

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.state {
            case .loading:
                LoadingStateView(message: L("workoutHub.today.loading"))
            case .failed(let message):
                ScrollView {
                    ErrorStateView(message: message, retryTitle: L("common.retry")) {
                        reload()
                    }
                    .readableWidth()
                }
            case .empty:
                ScrollView { emptyState.readableWidth().screenPadding() }
            case .content:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $model.substitutionTarget) { target in
            ExerciseSubstitutionSheet(
                exerciseID: target.exerciseID,
                sessionExerciseIDs: model.plannedExerciseIDs
            ) { exercise, reason in
                model.substitute(itemID: target.id, with: exercise, reason: reason)
            }
        }
        .sheet(isPresented: $model.isPresentingExercisePicker) {
            ExercisePickerSheet(title: L("workoutHub.today.addExercise")) { exercise in
                model.addExercise(exercise)
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                if let plan = model.plan {
                    planHeader(plan)

                    ForEach(plan.notes, id: \.self) { note in
                        ExplanationNote(text: note.text)
                    }

                    SectionHeader(
                        L("workoutHub.today.exercises"),
                        subtitle: L("workoutHub.today.exercisesSubtitle")
                    )

                    LazyVStack(spacing: Metrics.spacing12) {
                        ForEach(plan.items) { item in
                            TodayExerciseCard(
                                item: item,
                                model: model,
                                isExpanded: expandedItemID == item.id,
                                onToggle: { toggle(item.id) }
                            )
                        }
                    }

                    Button {
                        model.isPresentingExercisePicker = true
                    } label: {
                        Label(L("workoutHub.today.addExercise"), systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel(Text(L("workoutHub.today.addExercise")))
                }
            }
            .screenPadding()
            .padding(.bottom, Metrics.spacing24)
            .readableWidth()
        }
        .safeAreaInset(edge: .bottom) { startBar }
    }

    private func planHeader(_ plan: HubTodayPlan) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Text(plan.title)
                    .font(.appSectionTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !plan.focusGroups.isEmpty {
                    FlowLayout {
                        ForEach(plan.focusGroups, id: \.self) { group in
                            MuscleGroupBadge(group: group, showsIcon: true)
                        }
                    }
                }

                HStack(alignment: .top, spacing: Metrics.spacing12) {
                    StatTile(
                        value: "\(plan.items.count)",
                        label: L("workoutHub.today.exerciseCount"),
                        systemImage: "list.bullet"
                    )
                    StatTile(
                        value: "\(plan.totalSets)",
                        label: L("workoutHub.today.setCount"),
                        systemImage: "square.stack.3d.up"
                    )
                    StatTile(
                        value: formatter.durationCompact(plan.estimatedMinutes * 60),
                        label: L("workoutHub.today.estimate"),
                        systemImage: "clock"
                    )
                }
            }
        }
    }

    private var startBar: some View {
        VStack(spacing: Metrics.spacing8) {
            Button {
                if model.inProgressSessionID != nil {
                    model.resumeInProgressSession(router: router)
                } else {
                    model.startPlannedSession(router: router)
                }
            } label: {
                Label(
                    model.inProgressSessionID != nil
                        ? L("workoutHub.today.resume")
                        : L("workoutHub.today.start"),
                    systemImage: model.inProgressSessionID != nil ? "figure.run" : "play.fill"
                )
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.isStarting)
            .accessibilityLabel(Text(
                model.inProgressSessionID != nil
                    ? L("workoutHub.today.resume")
                    : L("workoutHub.today.start")
            ))
        }
        .screenPadding()
        .padding(.vertical, Metrics.spacing12)
        .readableWidth()
        .background(.bar)
    }

    // MARK: - Empty

    @ViewBuilder
    private var emptyState: some View {
        if !model.hasProgram {
            EmptyStateView(
                systemImage: "square.grid.3x3",
                title: L("workoutHub.today.noProgramTitle"),
                message: L("workoutHub.today.noProgramMessage")
            ) {
                VStack(spacing: Metrics.spacing12) {
                    Button(L("workoutHub.today.buildProgram")) {
                        router.workoutPath.append(WorkoutHubRoute.program)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button(L("workoutHub.quickStart.title")) {
                        model.isPresentingQuickStart = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: 320)
            }
        } else {
            EmptyStateView(
                systemImage: "moon.zzz.fill",
                title: L("workoutHub.today.restDayTitle"),
                message: L("workoutHub.today.restDayMessage")
            ) {
                VStack(spacing: Metrics.spacing12) {
                    Button(L("workoutHub.today.trainAnyway")) {
                        model.isPresentingQuickStart = true
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button(L("workoutHub.today.viewProgram")) {
                        router.workoutPath.append(WorkoutHubRoute.program)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: 320)
            }
        }
    }

    // MARK: - Actions

    private func toggle(_ id: UUID) {
        let next = expandedItemID == id ? nil : id
        if reduceMotion {
            expandedItemID = next
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { expandedItemID = next }
        }
        Haptics.selectionChanged()
    }

    private func reload() {
        Task { await model.load(context: modelContext, catalog: environment.catalog) }
    }
}

// MARK: - Exercise card

/// One line of today's plan, collapsed to a summary and expanded to a full editor.
///
/// Collapsed by default because twelve simultaneous editors is a wall of steppers; expanded on tap
/// because "change one number before I start" is a real and frequent need. The controls inside are
/// sized for the gym rather than for a desk, since the same screen is often revisited between sets.
private struct TodayExerciseCard: View {
    let item: HubPlannedItem
    let model: WorkoutHubViewModel
    let isExpanded: Bool
    let onToggle: () -> Void

    @Environment(AppRouter.self) private var router
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.displayFormatter) private var formatter

    private var exercise: Exercise? { environment.catalog.exercise(id: item.exerciseID) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                header

                if item.isSubstituted || item.requiresCalibration {
                    FlowLayout {
                        if item.isSubstituted {
                            Chip(
                                title: L("workoutHub.today.swapped"),
                                systemImage: "arrow.triangle.2.circlepath",
                                isSelected: true,
                                tint: .appRecovery
                            )
                        }
                        if item.requiresCalibration {
                            Chip(
                                title: L("workoutHub.today.needsCalibration"),
                                systemImage: "target",
                                isSelected: true,
                                tint: .appWarning
                            )
                        }
                    }
                }

                if let rationale = item.rationale {
                    ExplanationNote(text: rationale.text)
                }

                if isExpanded { editor }
            }
        }
    }

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: Metrics.spacing12) {
                ExerciseThumbnail(url: exercise.flatMap { environment.mediaProvider.thumbnailURL(for: $0) })
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name.localizedCapitalized)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(prescriptionLine)
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: isExpanded ? "chevron.up" : "slider.horizontal.3")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
                    .minimumTapTarget()
            }
            .frame(minHeight: Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item.name), \(prescriptionLine)"))
        .accessibilityHint(Text(L("workoutHub.today.editHint")))
        .accessibilityAddTraits(.isButton)
    }

    /// "4 × 8–12 · 60 kg", adapted to what the movement is actually measured in.
    private var prescriptionLine: String {
        var parts: [String] = []
        if item.trackingMode.usesReps {
            parts.append(L("workoutHub.today.setsByReps", item.sets, item.repRange.description))
        } else {
            parts.append(L("workoutHub.today.setsOnly", item.sets))
        }
        if let weight = item.weightKg, item.trackingMode.usesWeight {
            parts.append(formatter.weight(weight))
        }
        parts.append(L("workoutHub.today.rirShort", item.targetRIR))
        return parts.joined(separator: " · ")
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            Divider().overlay(Color.appSeparator)

            HubStepperRow(
                title: L("workoutHub.today.sets"),
                value: item.sets,
                range: InputValidation.setsPerExercise,
                format: { "\($0)" }
            ) { model.setSets($0, for: item.id) }

            if item.trackingMode.usesReps {
                HubStepperRow(
                    title: L("workoutHub.today.repTargetLow"),
                    value: item.repRange.lower,
                    range: 1...50,
                    format: { "\($0)" }
                ) { model.setRepRange(RepRange($0, max($0, item.repRange.upper)), for: item.id) }

                HubStepperRow(
                    title: L("workoutHub.today.repTargetHigh"),
                    value: item.repRange.upper,
                    range: 1...50,
                    format: { "\($0)" }
                ) { model.setRepRange(RepRange(min(item.repRange.lower, $0), $0), for: item.id) }
            }

            HubStepperRow(
                title: L("workoutHub.today.targetRIR"),
                value: item.targetRIR,
                range: InputValidation.repsInReserve,
                format: { "\($0)" }
            ) { model.setTargetRIR($0, for: item.id) }

            if item.trackingMode.usesWeight {
                NumberEntryField(
                    title: L("workoutHub.today.load"),
                    value: weightBinding,
                    unit: formatter.weightUnitLabel,
                    range: 0...InputValidation.loadKg.upperBound,
                    step: HubFormat.loadStep(for: weightUnit)
                )
            }

            HStack(spacing: Metrics.spacing12) {
                Button {
                    model.substitutionTarget = HubSubstitutionTarget(id: item.id, exerciseID: item.exerciseID)
                } label: {
                    Label(L("workoutHub.today.swap"), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(SecondaryButtonStyle())

                Button(role: .destructive) {
                    model.remove(itemID: item.id)
                    Haptics.tap()
                } label: {
                    Label(L("common.remove"), systemImage: "minus.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Button {
                router.workoutPath.append(WorkoutHubRoute.exercise(item.exerciseID))
            } label: {
                Label(L("workoutHub.today.howTo"), systemImage: "info.circle")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .transition(.opacity)
    }

    private var weightUnit: WeightUnit {
        formatter.weightUnitLabel == WeightUnit.pounds.rawValue ? .pounds : .kilograms
    }

    /// The field works in the user's unit; the model only ever stores kilograms.
    private var weightBinding: Binding<Double?> {
        Binding(
            get: { item.weightKg.map { formatter.weightValue($0) } },
            set: { model.setWeight($0.map { formatter.kilograms(fromDisplayed: $0) }, for: item.id) }
        )
    }
}

// MARK: - Stepper row

/// A label with a value and two large step buttons.
///
/// A SwiftUI `Stepper` has 28 pt targets and no visible value of its own, which is unusable with wet
/// hands mid-session; this keeps the same semantics with gym-sized buttons.
struct HubStepperRow: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let format: (Int) -> String
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: Metrics.spacing12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Metrics.spacing8)

            Button {
                change(to: value - 1)
            } label: {
                Image(systemName: "minus")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                    .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(value <= range.lowerBound)
            .accessibilityLabel(Text(L("workoutHub.today.decrease", title)))

            Text(format(value))
                .font(.appNumeric(20))
                .foregroundStyle(Color.appTextPrimary)
                .frame(minWidth: 44)
                .accessibilityHidden(true)

            Button {
                change(to: value + 1)
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                    .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(value >= range.upperBound)
            .accessibilityLabel(Text(L("workoutHub.today.increase", title)))
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(format(value)))
    }

    private func change(to newValue: Int) {
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        guard clamped != value else { return }
        onChange(clamped)
        Haptics.selectionChanged()
    }
}

#Preview("Planned session") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack { WorkoutHubView() }
    }
}
