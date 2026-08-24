import SwiftData
import SwiftUI

/// One performed session, exactly as it happened.
///
/// Everything here except the note is read-only, and deliberately so: a training log whose numbers
/// can be edited afterwards is a log that cannot be trusted to explain a plateau. Substitutions and
/// skips are shown rather than tidied away, and the comparison block answers the only question the
/// user really has about a past session — was this better than the last one?
struct WorkoutSessionDetailView: View {
    let sessionID: UUID

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var model = WorkoutSessionDetailViewModel()
    @FocusState private var isEditingNotes: Bool

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }

    var body: some View {
        @Bindable var model = model

        ZStack {
            Color.appBackground.ignoresSafeArea()

            switch model.state {
            case .loading:
                LoadingStateView(message: L("workoutHub.detail.loading"))
            case .failed(let message):
                ScrollView {
                    ErrorStateView(message: message, retryTitle: L("common.retry")) { reload() }
                        .readableWidth()
                }
            case .empty:
                ScrollView {
                    EmptyStateView(
                        systemImage: "doc.text.magnifyingglass",
                        title: L("workoutHub.detail.notFound"),
                        message: L("workoutHub.detail.notFoundMessage")
                    )
                    .readableWidth()
                }
            case .content:
                content
            }
        }
        .navigationTitle(model.title.isEmpty ? L("workoutHub.detail.title") : model.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            L("workoutHub.error.title"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            actions: { Button(L("common.done")) { model.errorMessage = nil } },
            message: { Text(model.errorMessage ?? "") }
        )
        .task(id: sessionID) {
            await model.load(sessionID: sessionID, context: modelContext, catalog: environment.catalog)
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                summaryCard
                if model.hasComparison { comparisonCard }
                if !model.records.isEmpty { recordsCard }

                SectionHeader(
                    L("workoutHub.detail.performed"),
                    subtitle: L("workoutHub.detail.performedSubtitle")
                )

                LazyVStack(spacing: Metrics.spacing12) {
                    ForEach(model.exercises) { exercise in
                        ExerciseHistoryCard(exercise: exercise)
                    }
                }

                notesCard
            }
            .screenPadding()
            .padding(.vertical, Metrics.spacing16)
            .readableWidth()
        }
    }

    private var summaryCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title)
                        .font(.appSectionTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(formatter.weekdayAndDate(model.date) + " · " + formatter.time(model.date))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.status != .completed {
                    HStack(spacing: Metrics.spacing6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.appWarning)
                        Text(L(model.status.localizationKey))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appWarning)
                    }
                    .accessibilityElement(children: .combine)
                }

                if !model.focusGroups.isEmpty {
                    FlowLayout {
                        ForEach(model.focusGroups, id: \.self) { group in
                            MuscleGroupBadge(group: group)
                        }
                    }
                }

                HStack(alignment: .top, spacing: Metrics.spacing12) {
                    StatTile(
                        value: formatter.durationCompact(model.durationSeconds),
                        label: L("workoutHub.detail.duration"),
                        systemImage: "clock"
                    )
                    StatTile(
                        value: formatter.volume(model.volumeKg),
                        label: L("workoutHub.detail.volume"),
                        systemImage: "scalemass"
                    )
                    StatTile(
                        value: "\(model.completedSets)/\(model.plannedSets)",
                        label: L("workoutHub.detail.sets"),
                        systemImage: "square.stack.3d.up"
                    )
                }

                if let effort = model.effort {
                    HStack(spacing: Metrics.spacing8) {
                        Image(systemName: effort.symbolName)
                            .font(.footnote)
                            .foregroundStyle(Color.appRecovery)
                        Text(L("workoutHub.detail.effort", L(effort.localizationKey)))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var comparisonCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Text(L("workoutHub.detail.comparisonTitle"))
                    .font(.appCardTitle)
                    .foregroundStyle(Color.appTextPrimary)
                if let previousDate = model.previousDate {
                    Text(L("workoutHub.detail.comparisonSubtitle", formatter.mediumDate(previousDate)))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: Metrics.spacing8) {
                    if let previous = model.previousVolumeKg {
                        DeltaRow(
                            label: L("workoutHub.detail.volume"),
                            current: formatter.volume(model.volumeKg),
                            previous: formatter.volume(previous),
                            delta: model.volumeKg - previous,
                            formatDelta: { formatter.volume(abs($0)) }
                        )
                    }
                    if let previous = model.previousCompletedSets {
                        DeltaRow(
                            label: L("workoutHub.detail.sets"),
                            current: "\(model.completedSets)",
                            previous: "\(previous)",
                            delta: Double(model.completedSets - previous),
                            formatDelta: { "\(Int(abs($0)))" }
                        )
                    }
                    if let previous = model.previousDurationSeconds {
                        DeltaRow(
                            label: L("workoutHub.detail.duration"),
                            current: formatter.durationCompact(model.durationSeconds),
                            previous: formatter.durationCompact(previous),
                            delta: Double(model.durationSeconds - previous),
                            formatDelta: { formatter.durationCompact(Int(abs($0))) },
                            higherIsBetter: false
                        )
                    }
                }
            }
        }
    }

    private var recordsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                HStack(spacing: Metrics.spacing8) {
                    Image(systemName: "trophy.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.appWarning)
                    Text(L("workoutHub.detail.records"))
                        .font(.appCardTitle)
                        .foregroundStyle(Color.appTextPrimary)
                }
                ForEach(model.records, id: \.id) { record in
                    HStack(alignment: .top, spacing: Metrics.spacing8) {
                        Image(systemName: record.kind.symbolName)
                            .font(.caption)
                            .foregroundStyle(Color.appWarning)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.exerciseNameSnapshot.localizedCapitalized)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.appTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(recordDetail(record))
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var notesCard: some View {
        @Bindable var model = model
        return Card {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text(L("workoutHub.detail.notes"))
                    .font(.appCardTitle)
                    .foregroundStyle(Color.appTextPrimary)
                Text(L("workoutHub.detail.notesHint"))
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField(
                    L("workoutHub.detail.notesPlaceholder"),
                    text: $model.notes,
                    axis: .vertical
                )
                .lineLimit(3...10)
                .font(.subheadline)
                .foregroundStyle(Color.appTextPrimary)
                .focused($isEditingNotes)
                .padding(Metrics.spacing12)
                .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
                .accessibilityLabel(Text(L("workoutHub.detail.notes")))

                if model.hasUnsavedNotes {
                    Button {
                        isEditingNotes = false
                        model.saveNotes()
                    } label: {
                        Label(L("common.save"), systemImage: "checkmark")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isSavingNotes)
                }
            }
        }
    }

    private func recordDetail(_ record: PersonalRecord) -> String {
        let value: String
        switch record.kind {
        case .heaviestWeight, .estimatedOneRepMax, .bestSetVolume, .sessionVolume, .lightestAssistance:
            value = formatter.weight(record.value)
        case .mostReps:
            value = L("workoutHub.detail.repsValue", Int(record.value))
        case .longestDuration:
            value = formatter.durationCompact(Int(record.value))
        case .longestDistance:
            value = formatter.distance(record.value)
        }
        guard let previous = record.previousValue, previous > 0 else {
            return L("workoutHub.detail.recordFirst", L(record.kind.localizationKey), value)
        }
        let previousText: String
        switch record.kind {
        case .heaviestWeight, .estimatedOneRepMax, .bestSetVolume, .sessionVolume, .lightestAssistance:
            previousText = formatter.weight(previous)
        case .mostReps:
            previousText = L("workoutHub.detail.repsValue", Int(previous))
        case .longestDuration:
            previousText = formatter.durationCompact(Int(previous))
        case .longestDistance:
            previousText = formatter.distance(previous)
        }
        return L("workoutHub.detail.recordBeat", L(record.kind.localizationKey), value, previousText)
    }

    private func reload() {
        Task { await model.load(sessionID: sessionID, context: modelContext, catalog: environment.catalog) }
    }
}

// MARK: - Delta row

/// One "then versus now" line.
///
/// The direction is carried by an arrow and by the words as well as by the colour, so the comparison
/// still reads for anyone who cannot separate the green from the red.
private struct DeltaRow: View {
    let label: String
    let current: String
    let previous: String
    let delta: Double
    let formatDelta: (Double) -> String
    var higherIsBetter: Bool = true

    private var isImprovement: Bool { higherIsBetter ? delta > 0 : delta < 0 }
    private var isUnchanged: Bool { abs(delta) < 0.001 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.spacing8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(current)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                HStack(spacing: 3) {
                    if !isUnchanged {
                        Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                    Text(deltaText)
                        .font(.caption2)
                }
                .foregroundStyle(isUnchanged ? Color.appTextTertiary : (isImprovement ? Color.appSuccess : Color.appWarning))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label), \(current), \(deltaAccessibility)"))
    }

    private var deltaText: String {
        isUnchanged ? L("workoutHub.detail.unchanged") : "\(formatDelta(delta)) · \(previous)"
    }

    private var deltaAccessibility: String {
        if isUnchanged { return L("workoutHub.detail.unchanged") }
        return delta > 0
            ? L("workoutHub.detail.upBy", formatDelta(delta), previous)
            : L("workoutHub.detail.downBy", formatDelta(delta), previous)
    }
}

// MARK: - Exercise card

/// One exercise of a finished session with every set it contained.
private struct ExerciseHistoryCard: View {
    let exercise: WorkoutSessionDetailViewModel.ExerciseLine

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                HStack(spacing: Metrics.spacing12) {
                    ExerciseThumbnail(url: thumbnailURL)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(exercise.name.localizedCapitalized)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L(
                            "workoutHub.detail.exerciseSummary",
                            exercise.sets.filter(\.isCompleted).count,
                            formatter.volume(exercise.volumeKg)
                        ))
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)

                if exercise.wasSkipped || exercise.substitutedFromName != nil {
                    FlowLayout {
                        if exercise.wasSkipped {
                            Chip(
                                title: L("workoutHub.detail.skipped"),
                                systemImage: "forward.end.fill",
                                isSelected: true,
                                tint: .appWarning
                            )
                        }
                        if let original = exercise.substitutedFromName {
                            Chip(
                                title: L("workoutHub.detail.replaced", original),
                                systemImage: "arrow.triangle.2.circlepath",
                                isSelected: true,
                                tint: .appRecovery
                            )
                        }
                    }
                }

                if let reasonKey = exercise.substitutionReasonKey {
                    Text(L("workoutHub.detail.substitutionReason", L(reasonKey)))
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        SetRow(set: set, trackingMode: exercise.trackingMode)
                        if index < exercise.sets.count - 1 {
                            Divider().overlay(Color.appSeparator)
                        }
                    }
                }

                if let previousTop = exercise.previousTopSet {
                    Text(L("workoutHub.detail.previousTopSet", previousTop))
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let notes = exercise.notes, !notes.isEmpty {
                    ExplanationNote(text: notes, systemImage: "text.quote", tint: .appTextSecondary)
                }
            }
        }
    }

    private var thumbnailURL: URL? {
        environment.catalog.exercise(id: exercise.exerciseID).flatMap {
            environment.mediaProvider.thumbnailURL(for: $0)
        }
    }
}

// MARK: - Set row

/// One set as performed, with what was asked for when it differs from what happened.
private struct SetRow: View {
    let set: WorkoutSessionDetailViewModel.SetLine
    let trackingMode: TrackingMode

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing12) {
            Text("\(set.index + 1)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextTertiary)
                .frame(minWidth: 18, alignment: .leading)

            if set.kind != .working {
                Text(L(set.kind.localizationKey))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
            }

            Text(performedText)
                .font(.appNumeric(15, weight: .medium))
                .foregroundStyle(set.isCompleted ? Color.appTextPrimary : Color.appTextTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Metrics.spacing8)

            if !set.records.isEmpty {
                Image(systemName: "trophy.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.appWarning)
            }
            if !set.isCompleted {
                Image(systemName: "minus.circle")
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
            }
            if let rir = set.rir {
                Text(L("workoutHub.today.rirShort", rir))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
        .padding(.vertical, Metrics.spacing8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var performedText: String {
        guard set.isCompleted else { return L("workoutHub.detail.notPerformed") }
        var parts: [String] = []
        if trackingMode.usesWeight, let weight = set.weightKg {
            parts.append(formatter.weight(weight))
        }
        if trackingMode.usesReps, let reps = set.reps {
            parts.append(L("workoutHub.detail.repsValue", reps))
        }
        if trackingMode.usesDuration, let seconds = set.durationSeconds {
            parts.append(formatter.duration(seconds))
        }
        if trackingMode.usesDistance, let metres = set.distanceMeters {
            parts.append(formatter.distance(metres))
        }
        return parts.isEmpty ? L("workoutHub.detail.completed") : parts.joined(separator: " × ")
    }

    private var accessibilityLabel: String {
        var parts = [L("workoutHub.detail.setNumber", set.index + 1), performedText]
        if let rir = set.rir { parts.append(L("workoutHub.today.rirShort", rir)) }
        if !set.records.isEmpty {
            parts.append(set.records.map { L($0.localizationKey) }.joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }
}

#Preview("Session detail") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack { SessionDetailPreviewHarness() }
    }
}

/// Opens the newest stored session, so the preview always lands on real data rather than on a
/// hard-coded identifier that the sample builder may not produce.
private struct SessionDetailPreviewHarness: View {
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var sessions: [WorkoutSession]

    var body: some View {
        if let session = sessions.first {
            WorkoutSessionDetailView(sessionID: session.id)
        } else {
            EmptyStateView(
                systemImage: "clock.arrow.circlepath",
                title: L("workoutHub.history.emptyTitle"),
                message: L("workoutHub.history.emptyMessage")
            )
        }
    }
}
