import SwiftUI

/// One exercise, filling the screen.
///
/// The layout is fixed on purpose. The animation is pinned between the title and the scrolling
/// detail, so it is still on screen while the user types a weight — seeing the movement is the
/// reason this app shows artwork at all, and an animation that scrolls away is an animation that is
/// never watched. Only the detail below it scrolls, and the Complete Set control is pinned to the
/// bottom where a thumb reaches it without looking.
struct ActiveExerciseCard: View {
    let record: ExerciseSession
    let position: Int
    let total: Int
    /// False for the neighbouring pages the pager keeps alive: their animations stay paused.
    let isCurrent: Bool
    /// How tall the animation may be on this device, computed once by the container.
    let heroMaxHeight: CGFloat
    let model: ActiveWorkoutViewModel

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var focusedSetID: UUID?
    @State private var showsInstructions = false
    @State private var instructionSteps: [String] = []

    private var exercise: Exercise? { model.exercise(for: record) }
    private var plan: SetFieldPlan {
        SetFieldPlan(
            mode: record.trackingMode,
            loadability: exercise?.metadata.loadability ?? .none
        )
    }
    private var activeSet: SetRecord? { model.activeSet(in: record) }
    private var focusedSet: SetRecord? {
        if let focusedSetID, let match = record.orderedSets.first(where: { $0.id == focusedSetID }),
           !match.isCompleted {
            return match
        }
        return activeSet
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .screenPadding()
                .padding(.bottom, Metrics.spacing12)

            heroSection
                .screenPadding()

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing20) {
                    if record.wasSkipped { skippedBanner }
                    explanation
                    targetsGrid
                    warmupRamp
                    SetLoggingList(
                        record: record,
                        plan: plan,
                        model: model,
                        focusedSetID: $focusedSetID
                    )
                    detailDisclosure
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Metrics.spacing16)
                .screenPadding()
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)

            CompleteSetButton(
                record: record,
                targetSet: focusedSet,
                plan: plan,
                model: model,
                hasNextExercise: position < total,
                onCompleted: { focusedSetID = nil },
                onNextExercise: { model.goToNextExercise() },
                onFinish: { model.prepareSummary(); model.presentedSheet = .finish }
            )
            .screenPadding()
            .padding(.top, Metrics.spacing8)
            .readableWidth()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Metrics.spacing12) {
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                Text(L("active.position", position, total))
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)

                Text(record.exerciseNameSnapshot.localizedCapitalized)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Metrics.spacing8) {
                    if let exercise {
                        Text(L(exercise.target.localizationKey))
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextSecondary)
                        Text("·").foregroundStyle(Color.appTextTertiary)
                        Text(L(exercise.equipment.localizationKey))
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if let originalID = record.substitutedFromExerciseID,
                   let original = environment.catalog.exercise(id: originalID) {
                    Text(L("active.substitutedFrom", original.name.localizedCapitalized))
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Menu {
                Button {
                    model.presentedSheet = .substitute(record.id)
                } label: {
                    Label(L("active.replace"), systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    model.setSkipped(!record.wasSkipped, on: record)
                } label: {
                    Label(
                        record.wasSkipped ? L("active.unskipExercise") : L("active.skipExercise"),
                        systemImage: record.wasSkipped ? "arrow.uturn.backward" : "forward.end"
                    )
                }
                Button {
                    model.presentedSheet = .edit
                } label: {
                    Label(L("active.editSession"), systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Color.appTextSecondary)
                    .minimumTapTarget(Metrics.gymTapTarget)
            }
            .accessibilityLabel(Text(L("active.exerciseOptions")))
        }
    }

    private var skippedBanner: some View {
        HStack(spacing: Metrics.spacing8) {
            Image(systemName: "forward.end.fill").font(.footnote)
            Text(L("active.skippedNotice"))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.spacing8)
            Button(L("active.unskipExercise")) { model.setSkipped(false, on: record) }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.appAccent)
                .minimumTapTarget()
        }
        .foregroundStyle(Color.appTextSecondary)
        .padding(Metrics.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
    }

    // MARK: - Media

    @ViewBuilder
    private var heroSection: some View {
        if model.isMediaCollapsed {
            collapsedMedia
        } else {
            VStack(spacing: Metrics.spacing6) {
                ZStack(alignment: .topTrailing) {
                    if let exercise {
                        ExerciseMediaHero(
                            exercise: exercise,
                            animationURL: environment.mediaProvider.animationURL(for: exercise),
                            thumbnailURL: environment.mediaProvider.thumbnailURL(for: exercise),
                            attribution: nil,
                            attributionURL: nil,
                            // Neighbouring pages stay decoded but paused, and Reduce Motion or the
                            // user's own setting drops to the still frame.
                            isPlaying: isCurrent && model.animationsEnabled && !reduceMotion,
                            showsAttribution: false
                        )
                    } else {
                        MediaUnavailableView()
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous))
                    }
                    collapseButton
                        .padding(Metrics.spacing8)
                }
                .frame(maxWidth: heroMaxHeight)
                .frame(maxWidth: .infinity)

                // Showing the credit is a licence condition, not a nicety.
                MediaAttributionLabel(
                    attribution: environment.mediaProvider.attribution,
                    url: environment.mediaProvider.attributionURL
                )
            }
        }
    }

    private var collapsedMedia: some View {
        Button {
            model.isMediaCollapsed = false
        } label: {
            HStack(spacing: Metrics.spacing12) {
                if let exercise {
                    ExerciseThumbnail(url: environment.mediaProvider.thumbnailURL(for: exercise))
                        .frame(width: 44, height: 44)
                }
                Text(L("active.showAnimation"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                Spacer(minLength: Metrics.spacing8)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(Metrics.spacing12)
            .frame(maxWidth: .infinity, minHeight: Metrics.minimumTapTarget)
            .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L("active.showAnimation")))
    }

    private var collapseButton: some View {
        Button {
            model.isMediaCollapsed = true
        } label: {
            Image(systemName: "chevron.up")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.appTextPrimary)
                .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                .background(Color.appSurface.opacity(0.85), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L("active.hideAnimation")))
    }

    // MARK: - Explanation

    @ViewBuilder
    private var explanation: some View {
        if let note = model.calibrationNote(for: record) {
            ExplanationNote(text: note.text, systemImage: "scalemass", tint: .appAccent)
        } else if model.awaitingCalibration.contains(record.exerciseID) {
            ExplanationNote(
                text: model.estimate(for: record)?.explanation.text
                    ?? model.decision(for: record)?.explanation.text
                    ?? L("active.calibration.prompt"),
                systemImage: "target",
                tint: .appAccent
            )
        } else if let decision = model.decision(for: record) {
            ExplanationNote(text: decision.explanation.text)
        }
    }

    // MARK: - Targets

    private var targetsGrid: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            SectionHeader(L("active.targets.title"), subtitle: lastTimeLine)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: Metrics.spacing12, alignment: .leading)],
                alignment: .leading,
                spacing: Metrics.spacing12
            ) {
                ForEach(targetItems, id: \.label) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(.appOverline)
                            .foregroundStyle(Color.appTextSecondary)
                        Text(item.value)
                            .font(.appNumeric(17))
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("\(item.label): \(item.value)"))
                }
            }
            .padding(Metrics.spacing12)
            .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        }
    }

    private var targetItems: [(label: String, value: String)] {
        let decision = model.decision(for: record)
        var items: [(String, String)] = [
            (L("active.target.sets"), "\(record.workingSets.count)")
        ]
        if plan.showsReps {
            let range = decision?.recommendedRepRange
                ?? RepRange(record.orderedSets.first?.targetReps ?? 8, record.orderedSets.first?.targetReps ?? 12)
            items.append((L("active.target.reps"), range.description))
        }
        if plan.showsDuration {
            let seconds = record.orderedSets.first?.targetDurationSeconds
                ?? (record.orderedSets.first.map { model.draft(for: $0).durationSeconds } ?? nil)
            if let seconds { items.append((L("active.target.hold"), Units.formatDuration(seconds: seconds))) }
        }
        if plan.showsWeight, let weight = recommendedWeight {
            items.append((plan.weightLabel, plan.isAssistance ? "−" + formatter.weight(weight) : formatter.weight(weight)))
        }
        items.append((L("active.target.rest"), Units.formatDuration(seconds: record.restSeconds)))
        if plan.showsEffort {
            items.append((L("active.target.rir"), "\(decision?.targetRIR ?? record.targetRIR)"))
        }
        return items.map { (label: $0.0, value: $0.1) }
    }

    private var recommendedWeight: Double? {
        model.decision(for: record)?.recommendedWeightKg
            ?? model.estimate(for: record)?.weightKg
            ?? record.orderedSets.first?.targetWeightKg
            ?? (record.orderedSets.first.map { model.draft(for: $0).weightKg } ?? nil)
    }

    private var lastTimeLine: String? {
        guard let performance = model.lastPerformance(for: record), let top = performance.topSet else {
            return L("active.lastTime.none")
        }
        let summary = SetSummaryText.parts(
            weightKg: top.weightKg,
            reps: top.reps,
            durationSeconds: top.durationSeconds,
            distanceMeters: top.distanceMeters,
            rir: nil,
            plan: plan,
            formatter: formatter
        )
        guard !summary.isEmpty else { return nil }
        return L("active.lastTime", summary, formatter.shortDate(performance.date))
    }

    // MARK: - Warm-up

    /// Shown as guidance rather than as rows to tick: the ramp is performed before the first working
    /// set, and adding it as sets would append it after them — the store keeps sets in the order they
    /// were created.
    @ViewBuilder
    private var warmupRamp: some View {
        let ramp = model.warmupRamp(for: record)
        if !ramp.isEmpty, record.completedWorkingSets.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                SectionHeader(L("active.warmup.title"), subtitle: L("active.warmup.subtitle"))
                InsetGroup {
                    VStack(alignment: .leading, spacing: Metrics.spacing6) {
                        ForEach(Array(ramp.enumerated()), id: \.offset) { index, warmup in
                            Text(L("active.warmup.row", index + 1, formatter.weight(warmup.weightKg), warmup.reps))
                                .font(.footnote)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Instructions and muscles

    @ViewBuilder
    private var detailDisclosure: some View {
        if let exercise {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        showsInstructions.toggle()
                    }
                } label: {
                    HStack {
                        Text(L("active.details.title"))
                            .font(.appCardTitle)
                            .foregroundStyle(Color.appTextPrimary)
                        Spacer()
                        Image(systemName: showsInstructions ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    .frame(minHeight: Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L("active.details.title")))
                .accessibilityValue(Text(showsInstructions ? L("common.showLess") : L("common.showMore")))

                if showsInstructions {
                    VStack(alignment: .leading, spacing: Metrics.spacing16) {
                        ExerciseInstructionsView(steps: instructionSteps)

                        VStack(alignment: .leading, spacing: Metrics.spacing8) {
                            Text(L("active.muscles.title"))
                                .font(.appOverline)
                                .foregroundStyle(Color.appTextSecondary)
                            FlowLayout {
                                ForEach(exercise.involvedGroups, id: \.self) { group in
                                    MuscleGroupBadge(group: group, showsIcon: true)
                                }
                            }
                        }
                    }
                    .task(id: exercise.id) {
                        instructionSteps = await environment.instructionStore.steps(
                            for: exercise.id,
                            language: LocalizationManager.shared.current
                        )
                    }
                }
            }
        }
    }
}
