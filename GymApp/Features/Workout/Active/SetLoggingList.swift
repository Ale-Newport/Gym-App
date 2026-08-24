import SwiftUI

// MARK: - The rows

/// The sets of one exercise, plus the controls that add to and correct them.
///
/// `LazyVStack` rather than `List`: the rows sit inside the exercise page's own scroll view, under
/// a pinned animation, and a nested `List` would fight it for scrolling and gestures.
struct SetLoggingList: View {
    let record: ExerciseSession
    let plan: SetFieldPlan
    let model: ActiveWorkoutViewModel
    /// Which row is expanded. Normally the first incomplete set; the user may move it by tapping a
    /// later row, because sets are not always performed in order.
    @Binding var focusedSetID: UUID?

    private var sets: [SetRecord] { record.orderedSets }

    private var activeSetID: UUID? {
        if let focusedSetID, sets.contains(where: { $0.id == focusedSetID && !$0.isCompleted }) {
            return focusedSetID
        }
        return sets.first { !$0.isCompleted }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            SectionHeader(
                title: L("active.sets.title"),
                subtitle: L("active.sets.progress", record.completedWorkingSets.count, record.workingSets.count)
            ) {
                if model.lastCompletedSetID != nil {
                    Button {
                        model.undoLastCompletion()
                    } label: {
                        Label(L("active.set.undo"), systemImage: "arrow.uturn.backward")
                            .labelStyle(.titleAndIcon)
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
                    .minimumTapTarget()
                    .accessibilityLabel(Text(L("active.set.undo")))
                }
            }

            if sets.isEmpty {
                EmptyStateView(
                    systemImage: "list.bullet.rectangle",
                    title: L("active.sets.empty.title"),
                    message: L("active.sets.empty.message")
                ) {
                    Button(L("active.addSet")) { model.addSet(to: record) }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 260)
                }
            } else {
                LazyVStack(spacing: Metrics.spacing8) {
                    ForEach(sets, id: \.id) { set in
                        SetRowView(
                            set: set,
                            record: record,
                            plan: plan,
                            isActive: set.id == activeSetID,
                            model: model,
                            onFocus: { focusedSetID = set.id }
                        )
                    }
                }

                HStack(spacing: Metrics.spacing12) {
                    Button {
                        model.addSet(to: record)
                    } label: {
                        Label(L("active.addSet"), systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel(Text(L("active.addSet")))

                    Button {
                        model.addSet(to: record, kind: .warmup)
                    } label: {
                        Label(L("active.addWarmupSet"), systemImage: "flame")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel(Text(L("active.addWarmupSet")))
                }
            }
        }
    }
}

// MARK: - The Complete Set control

/// The one control the user reaches for mid-set, pinned above the home indicator so it is always
/// under the thumb.
///
/// It is deliberately the only prominent button on the screen, and it changes meaning rather than
/// disappearing: once every set of the exercise is logged it becomes the way on to the next
/// exercise, and on the last exercise it becomes the way to finish. A dead-ended primary action is
/// how a user ends up hunting through a toolbar with a barbell in one hand.
struct CompleteSetButton: View {
    let record: ExerciseSession
    let targetSet: SetRecord?
    let plan: SetFieldPlan
    let model: ActiveWorkoutViewModel
    let hasNextExercise: Bool
    let onCompleted: () -> Void
    let onNextExercise: () -> Void
    let onFinish: () -> Void

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        VStack(spacing: Metrics.spacing6) {
            Button(action: act) {
                Text(title)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.spacing12)
            }
            .buttonStyle(PrimaryButtonStyle(tint: tint))
            .accessibilityLabel(Text(accessibilityLabel))

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func act() {
        if let targetSet {
            model.completeSet(targetSet)
            onCompleted()
        } else if hasNextExercise {
            onNextExercise()
        } else {
            onFinish()
        }
    }

    private var tint: Color {
        targetSet == nil && !hasNextExercise ? .appSuccess : .appAccent
    }

    private var title: String {
        if let targetSet {
            return targetSet.kind == .warmup
                ? L("active.completeWarmupSet")
                : L("active.completeSet", targetSet.setIndex + 1)
        }
        return hasNextExercise ? L("active.nextExercise") : L("active.finish")
    }

    /// Repeats the numbers about to be written, so the user can confirm them without looking back
    /// up at the fields.
    private var subtitle: String? {
        guard let targetSet else { return nil }
        let draft = model.draft(for: targetSet)
        let line = SetSummaryText.parts(
            weightKg: draft.weightKg,
            reps: draft.reps,
            durationSeconds: draft.durationSeconds,
            distanceMeters: draft.distanceMeters,
            rir: plan.showsEffort ? draft.rir : nil,
            plan: plan,
            formatter: formatter
        )
        return line.isEmpty ? nil : line
    }

    private var accessibilityLabel: String {
        guard let subtitle else { return title }
        return title + ", " + subtitle
    }
}
