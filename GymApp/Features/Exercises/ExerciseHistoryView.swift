import SwiftUI
import SwiftData

// MARK: - View model

/// Every session the user has ever trained one exercise in, reduced to value types.
///
/// The rows are copies rather than live `SetRecord` objects on purpose: this screen is a record of
/// what happened, it never writes, and holding model objects across a context change is how a
/// history list ends up showing a row that no longer exists.
@MainActor
@Observable
final class ExerciseHistoryViewModel {

    enum Phase: Equatable {
        case loading
        case ready
        case empty
        case failed(String)
    }

    /// One logged set.
    struct SetLine: Identifiable, Hashable {
        let id: String
        let index: Int
        let kind: SetKind
        let weightKg: Double?
        let reps: Int?
        let durationSeconds: Int?
        let distanceMeters: Double?
        let rir: Int?
        let isCompleted: Bool
        let records: [PersonalRecordKind]
    }

    /// One stored personal record, copied out of the store for the same reason as the set lines.
    struct RecordLine: Identifiable, Hashable {
        let id: UUID
        let kind: PersonalRecordKind
        let value: Double
        let achievedAt: Date
    }

    /// One session's work on the exercise.
    struct Entry: Identifiable, Hashable {
        let id: UUID
        let date: Date
        let title: String
        let trackingMode: TrackingMode
        let sets: [SetLine]
        let volumeKg: Double
        let estimatedOneRepMaxKg: Double?
        let notes: String?
        /// Set when the exercise stood in for a different movement that day.
        let substitutedFromName: String?
    }

    let exerciseID: String

    private(set) var phase: Phase = .loading
    private(set) var exerciseName = ""
    private(set) var entries: [Entry] = []
    private(set) var records: [RecordLine] = []
    private(set) var totalVolumeKg: Double = 0
    private(set) var bestOneRepMaxKg: Double?

    init(exerciseID: String) {
        self.exerciseID = exerciseID
    }

    func load(catalog: ExerciseCatalog, context: ModelContext) {
        let exercise = catalog.exercise(id: exerciseID)
        exerciseName = exercise?.name.localizedCapitalized ?? exerciseID

        do {
            let workouts = WorkoutRepository(context: context)
            // `limit: 0` is "everything": this screen is the place the user comes to see the whole
            // arc, and the number of sessions containing one movement is bounded by how long they
            // have trained, not by the size of the store.
            let sessions = try workouts.sessions(forExerciseID: exerciseID, limit: 0)
            entries = sessions.compactMap { makeEntry(from: $0) }
            totalVolumeKg = entries.reduce(0) { $0 + $1.volumeKg }
            bestOneRepMaxKg = entries.compactMap(\.estimatedOneRepMaxKg).max()

            let progress = ProgressRepository(context: context)
            records = try progress.personalRecords(forExerciseID: exerciseID).map {
                RecordLine(id: $0.id, kind: $0.kind, value: $0.value, achievedAt: $0.achievedAt)
            }

            phase = entries.isEmpty && records.isEmpty ? .empty : .ready
        } catch {
            phase = .failed((error as? RepositoryError)?.explanation.text ?? L("common.error"))
        }
    }

    /// Folds every slot the exercise occupied in one session into a single entry.
    ///
    /// A movement can hold two slots in one workout — a heavy top set and a back-off block — and
    /// those are one session's work on it, not two.
    private func makeEntry(from session: WorkoutSession) -> Entry? {
        let slots = session.orderedExercises.filter { $0.exerciseID == exerciseID && !$0.wasSkipped }
        guard !slots.isEmpty else { return nil }

        var lines: [SetLine] = []
        var performed: [PerformedSet] = []
        var volume: Double = 0
        var notes: [String] = []
        var substitutedFrom: String?

        for slot in slots {
            if let original = slot.substitutedFromExerciseID, substitutedFrom == nil {
                substitutedFrom = original
            }
            if let note = slot.notes, !note.isEmpty { notes.append(note) }

            for set in slot.orderedSets {
                lines.append(SetLine(
                    id: set.id.uuidString,
                    index: lines.count + 1,
                    kind: set.kind,
                    weightKg: set.weightKg,
                    reps: set.reps,
                    durationSeconds: set.durationSeconds,
                    distanceMeters: set.distanceMeters,
                    rir: set.rir,
                    isCompleted: set.isCompleted,
                    records: set.achievedRecordKinds
                ))
                performed.append(PerformedSet(
                    kind: set.kind,
                    weightKg: set.weightKg,
                    reps: set.reps,
                    rir: set.rir,
                    rpe: set.rpe,
                    durationSeconds: set.durationSeconds,
                    distanceMeters: set.distanceMeters,
                    targetReps: set.targetReps,
                    targetWeightKg: set.targetWeightKg,
                    isCompleted: set.isCompleted
                ))
                if slot.trackingMode.contributesToTonnage, set.isCompleted, set.kind.countsAsWorkingSet {
                    volume += set.volumeKg
                }
            }
        }

        guard lines.contains(where: \.isCompleted) else { return nil }

        return Entry(
            id: session.id,
            date: session.endedAt ?? session.startedAt,
            title: session.titleSnapshot,
            trackingMode: slots.first?.trackingMode ?? .weightAndReps,
            sets: lines,
            volumeKg: volume,
            estimatedOneRepMaxKg: OneRepMaxCalculator.bestEstimate(from: performed),
            notes: notes.isEmpty ? nil : notes.joined(separator: "\n"),
            substitutedFromName: substitutedFrom
        )
    }
}

// MARK: - View

/// The complete log for one exercise: every session, every set, and the records they set.
struct ExerciseHistoryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var formatter

    @State private var viewModel: ExerciseHistoryViewModel

    init(exerciseID: String) {
        _viewModel = State(initialValue: ExerciseHistoryViewModel(exerciseID: exerciseID))
    }

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L("exercises.history.title"))
            .navigationBarTitleDisplayMode(.inline)
            .task { viewModel.load(catalog: environment.catalog, context: modelContext) }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            LoadingStateView(message: L("common.loading"))
        case .failed(let message):
            ErrorStateView(message: message, retryTitle: L("common.retry")) {
                viewModel.load(catalog: environment.catalog, context: modelContext)
            }
            .readableWidth()
        case .empty:
            EmptyStateView(
                systemImage: "clock.badge.questionmark",
                title: L("exercises.history.empty.title"),
                message: L("exercises.history.empty.message")
            )
            .readableWidth()
        case .ready:
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing16) {
                summary
                if !viewModel.records.isEmpty { recordsCard }
                ForEach(viewModel.entries) { entry in
                    sessionCard(entry)
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, Metrics.spacing16)
            .readableWidth()
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text(viewModel.exerciseName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: Metrics.spacing12) {
                StatTile(
                    value: String(viewModel.entries.count),
                    label: L("exercises.history.sessions"),
                    systemImage: "figure.strengthtraining.traditional"
                )
                StatTile(
                    value: formatter.volume(viewModel.totalVolumeKg),
                    label: L("exercises.history.totalVolume"),
                    systemImage: "sum"
                )
                if let best = viewModel.bestOneRepMaxKg {
                    StatTile(
                        value: formatter.weight(best),
                        label: L("exercises.history.oneRepMax"),
                        tint: .appAccent,
                        systemImage: "bolt"
                    )
                }
            }
        }
    }

    private var recordsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                SectionHeader(L("exercises.history.records"))
                ForEach(viewModel.records) { record in
                    HStack(spacing: Metrics.spacing8) {
                        Image(systemName: record.kind.symbolName)
                            .font(.caption)
                            .foregroundStyle(Color.appAccent)
                            .frame(width: 20)
                        Text(L(record.kind.localizationKey))
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Metrics.spacing8)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(recordValue(record))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Color.appTextPrimary)
                            Text(formatter.mediumDate(record.achievedAt))
                                .font(.caption2)
                                .foregroundStyle(Color.appTextTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func sessionCard(_ entry: ExerciseHistoryViewModel.Entry) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatter.weekdayAndDate(entry.date))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                    Text(entry.title)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                if let substituted = entry.substitutedFromName,
                   let original = environment.catalog.exercise(id: substituted) {
                    ExplanationNote(
                        text: L("exercises.history.substitutedFor", original.name.localizedCapitalized),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }

                VStack(spacing: Metrics.spacing8) {
                    ForEach(entry.sets) { line in
                        setRow(line, mode: entry.trackingMode)
                    }
                }

                HStack(spacing: Metrics.spacing16) {
                    if entry.volumeKg > 0 {
                        Label(formatter.volume(entry.volumeKg), systemImage: "sum")
                    }
                    if let estimate = entry.estimatedOneRepMaxKg {
                        Label(
                            L("exercises.history.oneRepMaxShort", formatter.weight(estimate)),
                            systemImage: "bolt"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)

                if let notes = entry.notes {
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func setRow(_ line: ExerciseHistoryViewModel.SetLine, mode: TrackingMode) -> some View {
        HStack(spacing: Metrics.spacing12) {
            Text(String(line.index))
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.appTextTertiary)
                .frame(width: 20, alignment: .leading)

            Text(description(of: line, mode: mode))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(line.isCompleted ? Color.appTextPrimary : Color.appTextTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Metrics.spacing8)

            if line.kind != .working {
                Text(L(line.kind.localizationKey))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
            }
            if let rir = line.rir {
                Text(L("exercises.history.rir", rir))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.appTextTertiary)
            }
            // A record is flagged with a glyph *and* named in the accessibility label, never with
            // colour alone.
            ForEach(line.records, id: \.self) { kind in
                Image(systemName: kind.symbolName)
                    .font(.caption2)
                    .foregroundStyle(Color.appAccent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel(for: line, mode: mode)))
    }

    // MARK: - Formatting

    private func description(of line: ExerciseHistoryViewModel.SetLine, mode: TrackingMode) -> String {
        var parts: [String] = []
        if let weight = line.weightKg, mode.usesWeight {
            parts.append(formatter.weight(weight))
        }
        if let reps = line.reps, mode.usesReps {
            parts.append(L("exercises.history.repsShort", reps))
        }
        if let seconds = line.durationSeconds, mode.usesDuration {
            parts.append(formatter.duration(seconds))
        }
        if let meters = line.distanceMeters, mode.usesDistance {
            parts.append(formatter.distance(meters))
        }
        if parts.isEmpty { return L("exercises.history.notLogged") }
        return parts.joined(separator: " × ")
    }

    private func accessibilityLabel(for line: ExerciseHistoryViewModel.SetLine, mode: TrackingMode) -> String {
        var parts = [L("exercises.history.setNumber", line.index), description(of: line, mode: mode)]
        if line.kind != .working { parts.append(L(line.kind.localizationKey)) }
        if let rir = line.rir { parts.append(L("exercises.history.rir", rir)) }
        if !line.isCompleted { parts.append(L("exercises.history.notLogged")) }
        for kind in line.records { parts.append(L(kind.localizationKey)) }
        return parts.joined(separator: ", ")
    }

    /// Records are stored in canonical units per kind, so each formats differently.
    private func recordValue(_ record: ExerciseHistoryViewModel.RecordLine) -> String {
        switch record.kind {
        case .heaviestWeight, .estimatedOneRepMax, .bestSetVolume, .sessionVolume, .lightestAssistance:
            return formatter.weight(record.value)
        case .mostReps:
            return L("exercises.history.repsShort", Int(record.value.rounded()))
        case .longestDuration:
            return formatter.duration(Int(record.value.rounded()))
        case .longestDistance:
            return formatter.distance(record.value)
        }
    }
}

#Preview("History") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            ExerciseHistoryView(exerciseID: "0025")
        }
    }
}
