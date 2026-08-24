import SwiftData
import SwiftUI

/// Rework the session without leaving it.
///
/// Plans meet reality: a rack is taken, a shoulder complains, an hour turns into forty minutes. Every
/// change here applies to today and only today — with one exception. Adding or removing an exercise
/// is the kind of change that tends to recur, so those two ask whether the routine should follow.
/// Adding a set because today felt good is autoregulation rather than a routine change, and asking
/// about it would train the user to dismiss the question without reading it.
struct ActiveWorkoutEditSheet: View {
    let model: ActiveWorkoutViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var editMode: EditMode = .inactive
    @State private var isPresentingPicker = false
    @State private var routineQuestion: RoutineQuestion?
    @State private var pendingRoutineQuestion: RoutineQuestion?

    /// A structural change already applied to today, waiting on "should the routine follow?".
    private struct RoutineQuestion: Identifiable {
        enum Kind {
            case added
            case removed
        }

        let id = UUID()
        let kind: Kind
        let exerciseName: String
        let change: ActiveWorkoutViewModel.RoutineChange
    }

    /// The question is only worth asking when this session came from a template that can be changed.
    private var canPropagate: Bool { model.session?.templateID != nil }

    var body: some View {
        NavigationStack {
            List {
                exerciseSection
                addSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .environment(\.editMode, $editMode)
            .navigationTitle(L("active.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $isPresentingPicker, onDismiss: presentPendingQuestion) {
            ExercisePickerSheet(title: L("active.addExercise")) { exercise in
                add(exercise)
            }
        }
        .confirmationDialog(
            L("active.edit.routineTitle"),
            isPresented: Binding(
                get: { routineQuestion != nil },
                set: { if !$0 { routineQuestion = nil } }
            ),
            titleVisibility: .visible,
            presenting: routineQuestion
        ) { question in
            // Today-only is first and is what happens if the dialog is dismissed: the change is
            // already applied to this session and nothing else has been touched.
            Button(L("active.edit.justToday")) { routineQuestion = nil }
            Button(L("active.edit.updateRoutine")) {
                model.propagateToRoutine(question.change)
                routineQuestion = nil
            }
        } message: { question in
            // Written out per case rather than built from a ternary, so every key stays visible to
            // the localisation checker.
            switch question.kind {
            case .added:
                Text(L("active.edit.routineAddedMessage", question.exerciseName))
            case .removed:
                Text(L("active.edit.routineRemovedMessage", question.exerciseName))
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var exerciseSection: some View {
        Section {
            if model.orderedExercises.isEmpty {
                Text(L("active.edit.noExercises"))
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.orderedExercises, id: \.id) { record in
                    row(record)
                }
                .onMove { source, destination in
                    model.moveExercises(from: source, to: destination)
                }
                .onDelete { offsets in
                    for record in offsets.map({ model.orderedExercises[$0] }) { remove(record) }
                }
            }
        } header: {
            Text(L("active.edit.exercises"))
        } footer: {
            Text(L("active.edit.exercisesFooter"))
        }
    }

    private var addSection: some View {
        Section {
            Button {
                isPresentingPicker = true
            } label: {
                Label(L("active.addExercise"), systemImage: "plus")
                    .frame(minHeight: Metrics.minimumTapTarget)
            }
        }
    }

    // MARK: - Rows

    private func row(_ record: ExerciseSession) -> some View {
        let index = model.orderedExercises.firstIndex { $0.id == record.id } ?? 0

        return HStack(spacing: Metrics.spacing12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.exerciseNameSnapshot.localizedCapitalized)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(record.wasSkipped ? Color.appTextTertiary : Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle(for: record))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Row controls are inert while the list is in reordering mode, so they are taken away
            // rather than left there looking tappable.
            if !editMode.isEditing {
                setStepper(record)
                optionsMenu(record, index: index)
            }
        }
        .padding(.vertical, Metrics.spacing4)
    }

    private func subtitle(for record: ExerciseSession) -> String {
        var parts = [
            LPlural("active.edit.setCount", record.workingSets.count),
            L("active.edit.restValue", Units.formatDuration(seconds: record.restSeconds))
        ]
        if record.wasSkipped { parts.append(L("active.edit.skipped")) }
        return parts.joined(separator: " · ")
    }

    private func setStepper(_ record: ExerciseSession) -> some View {
        HStack(spacing: 0) {
            Button {
                if let target = removableSet(in: record) { model.removeSet(target) }
            } label: {
                Image(systemName: "minus")
                    .font(.body.weight(.semibold))
                    .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(removableSet(in: record) == nil ? Color.appTextTertiary : Color.appAccent)
            .disabled(removableSet(in: record) == nil)
            .accessibilityLabel(Text(L("active.edit.removeSet")))

            Text("\(record.workingSets.count)")
                .font(.appNumeric(17))
                .foregroundStyle(Color.appTextPrimary)
                .frame(minWidth: 22)
                .accessibilityLabel(Text(LPlural("active.edit.setCount", record.workingSets.count)))

            Button {
                model.addSet(to: record)
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.appAccent)
            .accessibilityLabel(Text(L("active.edit.addSet")))
        }
    }

    private func optionsMenu(_ record: ExerciseSession, index: Int) -> some View {
        Menu {
            // Explicit move commands as well as drag-to-reorder: dragging a row one-handed with a
            // barbell in the other is not a realistic ask.
            Button {
                move(from: index, by: -1)
            } label: {
                Label(L("active.edit.moveUp"), systemImage: "arrow.up")
            }
            .disabled(index == 0)

            Button {
                move(from: index, by: 1)
            } label: {
                Label(L("active.edit.moveDown"), systemImage: "arrow.down")
            }
            .disabled(index >= model.orderedExercises.count - 1)

            Button {
                model.setSkipped(!record.wasSkipped, on: record)
            } label: {
                Label(
                    record.wasSkipped ? L("active.unskipExercise") : L("active.skipExercise"),
                    systemImage: record.wasSkipped ? "arrow.uturn.backward" : "forward.end"
                )
            }

            Divider()

            Button(role: .destructive) {
                remove(record)
            } label: {
                Label(L("active.edit.removeExercise"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
                .foregroundStyle(Color.appTextSecondary)
                .minimumTapTarget()
        }
        .accessibilityLabel(Text(L("active.exerciseOptions")))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L("common.done")) { dismiss() }
        }
        if !model.orderedExercises.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                } label: {
                    Image(systemName: editMode.isEditing ? "checkmark" : "arrow.up.arrow.down")
                        .minimumTapTarget()
                }
                .accessibilityLabel(Text(
                    editMode.isEditing ? L("active.edit.reorderDone") : L("active.edit.reorder")
                ))
            }
        }
    }

    // MARK: - Actions

    /// The last set that has not been performed. A completed set is history and is taken back from
    /// the set list, one row at a time, rather than by a stepper.
    private func removableSet(in record: ExerciseSession) -> SetRecord? {
        record.orderedSets.last { !$0.isCompleted }
    }

    private func move(from index: Int, by delta: Int) {
        let destination = delta < 0 ? index - 1 : index + 2
        model.moveExercises(from: IndexSet(integer: index), to: destination)
    }

    private func add(_ exercise: Exercise) {
        guard let created = model.addExercise(exercise) else { return }
        guard canPropagate else { return }
        pendingRoutineQuestion = RoutineQuestion(
            kind: .added,
            exerciseName: exercise.name.localizedCapitalized,
            change: .addExercise(
                exerciseID: exercise.id,
                sets: max(1, created.workingSets.count),
                repRange: exercise.metadata.recommendedRepRange,
                restSeconds: created.restSeconds,
                targetRIR: created.targetRIR
            )
        )
    }

    private func remove(_ record: ExerciseSession) {
        let exerciseID = record.exerciseID
        let name = record.exerciseNameSnapshot.localizedCapitalized
        model.removeExercise(record)
        guard canPropagate else { return }
        routineQuestion = RoutineQuestion(
            kind: .removed,
            exerciseName: name,
            change: .removeExercise(exerciseID: exerciseID)
        )
    }

    /// Asked only once the picker has gone: a dialog raised while a sheet is still dismissing is a
    /// dialog the user never sees.
    private func presentPendingQuestion() {
        guard let pending = pendingRoutineQuestion else { return }
        pendingRoutineQuestion = nil
        routineQuestion = pending
    }
}

#Preview("Edit session") {
    PreviewHost(scenario: .activeWorkout) {
        EditSheetPreviewHarness()
    }
}

/// Loads the in-progress sample session so the sheet previews against real exercises.
private struct EditSheetPreviewHarness: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var sessions: [WorkoutSession]

    @State private var model: ActiveWorkoutViewModel?

    var body: some View {
        Group {
            if let model {
                ActiveWorkoutEditSheet(model: model)
            } else {
                LoadingStateView(message: L("active.loading"))
            }
        }
        .task {
            guard model == nil, let session = sessions.first(where: { $0.status == .inProgress }) else { return }
            await environment.catalog.load()
            let created = ActiveWorkoutViewModel(workoutID: session.id)
            await created.load(context: modelContext, environment: environment)
            model = created
        }
    }
}
