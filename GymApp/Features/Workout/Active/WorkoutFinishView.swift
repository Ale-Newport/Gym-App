import SwiftData
import SwiftUI

/// The end of a session: what was done, what was beaten, and how it felt.
///
/// Nothing here is written until the user commits. `prepareSummary()` only reads, so backing out
/// leaves the session exactly as it was and the user can go back and add the set they forgot.
///
/// The effort rating is asked for last and is not optional, because it is the single input the
/// autoregulation engine leans on hardest — and once it is given, the screen says plainly what the
/// engine changed for next time rather than letting the next session differ mysteriously.
struct WorkoutFinishView: View {
    let model: ActiveWorkoutViewModel
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayFormatter) private var formatter

    @State private var effort: SessionEffortFeedback?
    @State private var stage: Stage = .review
    @State private var isConfirmingDiscard = false

    private enum Stage: Equatable {
        case review
        case saving
        case saved([AutoregulationAdjustment])
    }

    private var summary: WorkoutSummary? { model.summary }

    var body: some View {
        NavigationStack {
            content
                .background(Color.appBackground)
                .navigationTitle(L("active.finish.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .presentationDragIndicator(stage == .review ? .visible : .hidden)
        .interactiveDismissDisabled(stage != .review)
        .task { if model.summary == nil { model.prepareSummary() } }
        .confirmationDialog(
            L("active.discard.title"),
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button(L("active.discard.action"), role: .destructive) {
                model.discard()
                onFinished()
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L(
                "active.discard.message",
                LPlural("active.discard.sets", model.discardImpact.sets),
                formatter.durationCompact(model.discardImpact.seconds)
            ))
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .saving:
            LoadingStateView(message: L("active.finish.saving"))
        case .saved(let adjustments):
            savedStage(adjustments)
        case .review:
            if let summary, summary.completedSets > 0 {
                reviewStage(summary)
            } else {
                nothingLoggedStage
            }
        }
    }

    /// Finishing a session with nothing in it would store an empty workout and teach the progression
    /// engine that the user trained. So the honest options are offered instead.
    private var nothingLoggedStage: some View {
        ScrollView {
            EmptyStateView(
                systemImage: "list.bullet.rectangle",
                title: L("active.finish.nothingTitle"),
                message: L("active.finish.nothingMessage")
            ) {
                VStack(spacing: Metrics.spacing12) {
                    Button(L("active.finish.keepTraining")) { dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button(L("active.discard.action")) { isConfirmingDiscard = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: 280)
            }
            .readableWidth()
            .screenPadding()
        }
    }

    private func reviewStage(_ summary: WorkoutSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing24) {
                headline(summary)
                statTiles(summary)
                records(summary)
                muscleGroups(summary)
                comparison(summary)
                effortSection
            }
            .padding(.vertical, Metrics.spacing16)
            .screenPadding()
            .readableWidth()
        }
    }

    private func savedStage(_ adjustments: [AutoregulationAdjustment]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing20) {
                VStack(alignment: .leading, spacing: Metrics.spacing6) {
                    Text(L("active.finish.savedTitle"))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("active.finish.savedMessage"))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if adjustments.isEmpty {
                    ExplanationNote(text: L("active.finish.noAdjustments"))
                } else {
                    VStack(alignment: .leading, spacing: Metrics.spacing8) {
                        SectionHeader(
                            L("active.finish.adjustmentsTitle"),
                            subtitle: L("active.finish.adjustmentsSubtitle")
                        )
                        ForEach(adjustments) { adjustment in
                            ExplanationNote(
                                text: adjustment.explanation.text,
                                systemImage: "wand.and.stars",
                                tint: .appAccent
                            )
                        }
                    }
                }

                Button(L("common.done")) { onFinished() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.vertical, Metrics.spacing16)
            .screenPadding()
            .readableWidth()
        }
    }

    // MARK: - Review pieces

    private func headline(_ summary: WorkoutSummary) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            Text(L("active.finish.heading"))
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
            Text(summary.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func statTiles(_ summary: WorkoutSummary) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132), spacing: Metrics.spacing12, alignment: .leading)],
            alignment: .leading,
            spacing: Metrics.spacing16
        ) {
            StatTile(
                value: formatter.durationCompact(summary.durationSeconds),
                label: L("active.finish.duration"),
                systemImage: "stopwatch"
            )
            StatTile(
                value: "\(summary.exercisesPerformed)",
                label: L("active.finish.exercises"),
                caption: L("active.finish.ofPlanned", summary.exercisesPlanned),
                systemImage: "figure.strengthtraining.traditional"
            )
            StatTile(
                value: "\(summary.completedSets)",
                label: L("active.finish.sets"),
                caption: L("active.finish.ofPlanned", summary.plannedSets),
                systemImage: "checkmark.circle"
            )
            // Tonnage is meaningless for a session of holds and cardio, so it is only shown when
            // something in it actually carried a load.
            if summary.carriesVolume {
                StatTile(
                    value: formatter.volume(summary.totalVolumeKg),
                    label: L("active.finish.volume"),
                    systemImage: "scalemass"
                )
            }
        }
        .padding(Metrics.spacing12)
        .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
    }

    @ViewBuilder
    private func records(_ summary: WorkoutSummary) -> some View {
        if !summary.records.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                SectionHeader(
                    L("active.finish.recordsTitle"),
                    subtitle: LPlural("active.finish.recordsCount", summary.records.count)
                )
                VStack(spacing: Metrics.spacing8) {
                    ForEach(summary.records) { record in
                        recordRow(record)
                    }
                }
            }
        }
    }

    private func recordRow(_ record: SessionRecordSummary) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacing12) {
            Image(systemName: record.kind.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.appWarning)
                .frame(width: 28)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.exerciseName.localizedCapitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L(
                    "active.finish.recordDetail",
                    L(record.kind.localizationKey),
                    recordValue(record)
                ))
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(previousText(for: record))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Metrics.spacing12)
        .background(
            Color.appWarning.opacity(0.10),
            in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    /// A record's number means something different for every kind, so the unit follows the kind
    /// rather than assuming kilograms.
    private func recordValue(_ record: SessionRecordSummary) -> String {
        switch record.kind {
        case .heaviestWeight, .estimatedOneRepMax, .lightestAssistance:
            formatter.weight(record.value)
        case .mostReps:
            L("active.set.repsValue", Int(record.value.rounded()))
        case .bestSetVolume, .sessionVolume:
            formatter.volume(record.value)
        case .longestDuration:
            Units.formatDuration(seconds: Int(record.value.rounded()))
        case .longestDistance:
            formatter.distance(record.value)
        }
    }

    private func previousText(for record: SessionRecordSummary) -> String {
        guard let previous = record.previousValue, previous > 0 else {
            return L("active.finish.recordFirst")
        }
        let mirrored = SessionRecordSummary(
            exerciseID: record.exerciseID,
            exerciseName: record.exerciseName,
            kind: record.kind,
            value: previous,
            repsContext: record.repsContext,
            previousValue: nil
        )
        return L("active.finish.recordPrevious", recordValue(mirrored))
    }

    @ViewBuilder
    private func muscleGroups(_ summary: WorkoutSummary) -> some View {
        if !summary.groupSets.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                SectionHeader(
                    L("active.finish.musclesTitle"),
                    subtitle: L("active.finish.musclesSubtitle")
                )
                InsetGroup {
                    VStack(spacing: Metrics.spacing8) {
                        ForEach(summary.groupSets, id: \.group) { entry in
                            HStack(spacing: Metrics.spacing8) {
                                MuscleGroupBadge(group: entry.group, showsIcon: true)
                                Spacer(minLength: Metrics.spacing8)
                                Text(Units.formatDecimal(entry.sets, digits: 1))
                                    .font(.appNumeric(15))
                                    .foregroundStyle(Color.appTextPrimary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(Text(L(
                                "active.finish.groupSets",
                                L(entry.group.localizationKey),
                                Units.formatDecimal(entry.sets, digits: 1)
                            )))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func comparison(_ summary: WorkoutSummary) -> some View {
        if let comparison = summary.comparison {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                SectionHeader(
                    L("active.finish.comparisonTitle"),
                    subtitle: L("active.finish.comparisonSubtitle", formatter.mediumDate(comparison.previousDate))
                )
                InsetGroup {
                    VStack(spacing: Metrics.spacing8) {
                        if summary.carriesVolume {
                            comparisonRow(
                                label: L("active.finish.volume"),
                                delta: comparison.volumeDeltaKg,
                                magnitude: formatter.volume(abs(comparison.volumeDeltaKg))
                            )
                        }
                        comparisonRow(
                            label: L("active.finish.sets"),
                            delta: Double(comparison.setsDelta),
                            magnitude: LPlural("active.finish.setsCount", abs(comparison.setsDelta))
                        )
                        comparisonRow(
                            label: L("active.finish.duration"),
                            delta: Double(comparison.durationDeltaSeconds),
                            magnitude: formatter.durationCompact(abs(comparison.durationDeltaSeconds))
                        )
                    }
                }
            }
        }
    }

    /// Direction is stated in words as well as coloured, so the comparison still reads without
    /// colour vision.
    private func comparisonRow(label: String, delta: Double, magnitude: String) -> some View {
        let isFlat = abs(delta) < 0.5
        // Written out per branch rather than built from a ternary, so every key stays visible to the
        // localisation checker.
        let text: String
        if isFlat {
            text = L("active.finish.unchanged")
        } else if delta > 0 {
            text = L("active.finish.up", magnitude)
        } else {
            text = L("active.finish.down", magnitude)
        }

        return HStack(spacing: Metrics.spacing8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
            Spacer(minLength: Metrics.spacing8)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isFlat ? Color.appTextSecondary : (delta > 0 ? Color.appSuccess : Color.appTextPrimary))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label), \(text)"))
    }

    private var effortSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            SectionHeader(
                L("active.finish.effortTitle"),
                subtitle: L("active.finish.effortSubtitle")
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: Metrics.spacing8)],
                spacing: Metrics.spacing8
            ) {
                ForEach(SessionEffortFeedback.allCases) { option in
                    effortButton(option)
                }
            }

            VStack(spacing: Metrics.spacing6) {
                Button(L("active.finish.save")) { save() }
                    .buttonStyle(PrimaryButtonStyle(tint: .appSuccess))
                    .disabled(effort == nil)

                if effort == nil {
                    Text(L("active.finish.effortRequired"))
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func effortButton(_ option: SessionEffortFeedback) -> some View {
        let isSelected = effort == option
        return Button {
            effort = option
            Haptics.selectionChanged()
        } label: {
            HStack(spacing: Metrics.spacing8) {
                Image(systemName: option.symbolName)
                    .font(.body)
                Text(L(option.localizationKey))
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                }
            }
            .foregroundStyle(isSelected ? Color.appAccent : Color.appTextSecondary)
            .padding(.horizontal, Metrics.spacing12)
            .frame(maxWidth: .infinity, minHeight: Metrics.gymTapTarget, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    .fill(isSelected ? Color.appAccent.opacity(0.14) : Color.appFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    .strokeBorder(isSelected ? Color.appAccent.opacity(0.55) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Toolbar and commit

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if stage == .review {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("active.finish.keepTraining")) { dismiss() }
            }
        }
    }

    private func save() {
        guard let effort else { return }
        stage = .saving
        Task {
            let adjustments = await model.finishWorkout(effort: effort)
            stage = .saved(adjustments)
        }
    }
}

#Preview("Finish workout") {
    PreviewHost(scenario: .activeWorkout) {
        FinishPreviewHarness()
    }
}

/// Loads the in-progress sample session and prepares its summary, so the preview shows real numbers
/// rather than an empty shell.
private struct FinishPreviewHarness: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var sessions: [WorkoutSession]

    @State private var model: ActiveWorkoutViewModel?

    var body: some View {
        Group {
            if let model {
                WorkoutFinishView(model: model) {}
            } else {
                LoadingStateView(message: L("active.loading"))
            }
        }
        .task {
            guard model == nil, let session = sessions.first(where: { $0.status == .inProgress }) else { return }
            await environment.catalog.load()
            let created = ActiveWorkoutViewModel(workoutID: session.id)
            await created.load(context: modelContext, environment: environment)
            created.prepareSummary()
            model = created
        }
    }
}
