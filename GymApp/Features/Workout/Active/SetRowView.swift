import SwiftUI

// MARK: - Field plan

/// Which fields a set of this exercise is actually measured in.
///
/// Driven entirely by `TrackingMode`, so the logger never asks for reps on a plank or a load on a
/// treadmill run. Every screen that edits a set derives its inputs from here rather than assuming
/// weight × reps.
struct SetFieldPlan {
    let mode: TrackingMode
    let loadability: Loadability

    /// A load is edited whenever the mode records one.
    var showsWeight: Bool { mode.usesWeight }
    var showsReps: Bool { mode.usesReps }
    var showsDuration: Bool { mode.usesDuration }
    var showsDistance: Bool { mode.usesDistance }

    /// Reps in reserve is asked for on everything except pure cardio, where it has no meaning. On a
    /// hold it reads as "how many more seconds could you have kept it", which is exactly the signal
    /// the recovery and autoregulation engines want out of a timed set.
    var showsEffort: Bool { mode != .distanceAndDuration }

    /// Assisted movements store the assistance as a positive magnitude, but the user is removing
    /// weight, not adding it — so the field is labelled and displayed as a subtraction.
    var isAssistance: Bool { loadability == .assistedBodyweight }

    /// A weighted dip or pull-up adds load to the body rather than lifting a total.
    var isAddedLoad: Bool { mode == .weightedBodyweight }

    /// Main-actor isolated because the label resolves through `LocalizationManager`. Every caller is
    /// a view, so this costs nothing and keeps the plan itself a plain value type.
    @MainActor
    var weightLabel: String {
        if isAssistance { return L("active.set.assistance") }
        if isAddedLoad { return L("active.set.addedLoad") }
        return L("active.set.weight")
    }
}

// MARK: - Row

/// One set: what was asked for, what the user is doing, and the control that logs it.
///
/// The row has three states, and the difference between them is the whole ergonomic argument of the
/// screen. The **active** set — the next one due — expands into full-size entry fields, because that
/// is the only row the user touches mid-set. Every other pending row collapses to a single line, so
/// four sets of an exercise still fit above the fold. A **completed** row shows what was logged and
/// nothing else, with one control to take it back.
struct SetRowView: View {
    let set: SetRecord
    let record: ExerciseSession
    let plan: SetFieldPlan
    let isActive: Bool
    let model: ActiveWorkoutViewModel
    /// Called when a collapsed pending row is tapped, to move the focus here.
    let onFocus: () -> Void

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            header
            if isActive && !set.isCompleted {
                editors
            }
        }
        .padding(Metrics.spacing12)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                .strokeBorder(isActive && !set.isCompleted ? Color.appAccent.opacity(0.55) : .clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        .onTapGesture { if !isActive && !set.isCompleted { onFocus() } }
        .contextMenu { contextMenu }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
            .fill(set.isCompleted ? Color.appSuccess.opacity(0.10) : Color.appFill)
    }

    // MARK: Header line

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing12) {
            indexBadge

            VStack(alignment: .leading, spacing: 2) {
                Text(valueLine)
                    .font(.subheadline.weight(set.isCompleted ? .semibold : .regular))
                    .foregroundStyle(set.isCompleted ? Color.appTextPrimary : Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let targetLine {
                    Text(targetLine)
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !set.achievedRecordKinds.isEmpty {
                    recordBadge
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingControl
        }
        .accessibilityElement(children: .contain)
    }

    private var indexBadge: some View {
        Group {
            if set.kind == .warmup {
                Image(systemName: "flame")
                    .font(.caption.weight(.bold))
            } else {
                Text("\(set.setIndex + 1)")
                    .font(.appNumeric(15, weight: .bold))
            }
        }
        .foregroundStyle(set.isCompleted ? Color.appSuccess : Color.appTextSecondary)
        .frame(width: 26, height: 26)
        .background(
            Circle().fill(set.isCompleted ? Color.appSuccess.opacity(0.18) : Color.appFillSecondary)
        )
        .accessibilityLabel(Text(set.kind == .warmup ? L("active.set.warmup") : L("active.set.number", set.setIndex + 1)))
    }

    /// A record is never signalled by colour alone: the trophy carries a word next to it.
    private var recordBadge: some View {
        HStack(spacing: Metrics.spacing4) {
            Image(systemName: "trophy.fill").font(.caption2)
            Text(L("active.set.personalRecord"))
                .font(.caption2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.appWarning)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if set.isCompleted {
            Button {
                model.uncomplete(set)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .minimumTapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L("active.set.undoOne", set.setIndex + 1)))
        } else if !isActive {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextTertiary)
                .accessibilityHidden(true)
        }
    }

    // MARK: Editors

    /// Stacked rather than side by side on purpose: a 56 pt field with a stepper on either side
    /// already needs the full width of the narrowest supported iPhone, and larger Dynamic Type sizes
    /// make that worse rather than better. Vertical costs scrolling; horizontal costs unusable
    /// controls mid-set.
    private var editors: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            if plan.showsWeight {
                NumberEntryField(
                    title: plan.weightLabel,
                    value: weightBinding,
                    unit: formatter.weightUnitLabel,
                    allowsDecimals: true,
                    range: 0...2000,
                    step: weightStep
                )
            }
            if plan.showsReps {
                IntegerEntryField(
                    title: L("active.set.reps"),
                    value: repsBinding,
                    range: 0...500,
                    step: 1
                )
            }
            if plan.showsDuration {
                durationField
            }
            if plan.showsDistance {
                NumberEntryField(
                    title: L("active.set.distance"),
                    value: distanceBinding,
                    unit: formatter.distanceUnit.rawValue,
                    allowsDecimals: true,
                    range: 0...500,
                    step: 0.1
                )
            }
            if plan.showsEffort {
                SegmentedValuePicker(
                    title: L("active.set.rir"),
                    values: Array(0...5),
                    label: { "\($0)" },
                    selection: rirBinding
                )
                .accessibilityHint(Text(L("active.set.rirHint")))
            }
        }
    }

    /// A hold is timed, not typed. The stopwatch fills the field, and the field stays editable for
    /// the user who forgot to start it.
    private var durationField: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            IntegerEntryField(
                title: L("active.set.seconds"),
                value: durationBinding,
                range: 0...3600,
                step: 5
            )
            Button {
                if model.holdTimer.isRunning(for: set.id) {
                    let held = model.holdTimer.stop()
                    model.updateDraft(set) { $0.durationSeconds = held }
                    Haptics.setCompleted()
                } else {
                    model.holdTimer.start(setID: set.id, from: 0)
                    Haptics.tap()
                }
            } label: {
                HStack(spacing: Metrics.spacing8) {
                    Image(systemName: model.holdTimer.isRunning(for: set.id) ? "stop.fill" : "timer")
                    Text(holdButtonTitle)
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityLabel(Text(holdButtonTitle))
        }
    }

    private var holdButtonTitle: String {
        if model.holdTimer.isRunning(for: set.id) {
            return L("active.hold.stop", Units.formatDuration(seconds: model.holdTimer.elapsedSeconds))
        }
        return L("active.hold.start")
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if !set.isCompleted {
            Button {
                model.toggleWarmup(set)
            } label: {
                Label(
                    set.kind == .warmup ? L("active.set.markWorking") : L("active.set.markWarmup"),
                    systemImage: set.kind == .warmup ? "dumbbell" : "flame"
                )
            }
        } else {
            Button {
                model.uncomplete(set)
            } label: {
                Label(L("active.set.undoOne", set.setIndex + 1), systemImage: "arrow.uturn.backward")
            }
        }
        Button(role: .destructive) {
            model.removeSet(set)
        } label: {
            Label(L("active.set.remove"), systemImage: "trash")
        }
    }

    // MARK: Text

    /// What the row reads as: the logged values once completed, the drafted values while active,
    /// and a dash for a pending row with nothing entered.
    private var valueLine: String {
        let draft = model.draft(for: set)
        let parts = SetSummaryText.parts(
            weightKg: set.isCompleted ? set.weightKg : draft.weightKg,
            reps: set.isCompleted ? set.reps : draft.reps,
            durationSeconds: set.isCompleted ? set.durationSeconds : draft.durationSeconds,
            distanceMeters: set.isCompleted ? set.distanceMeters : draft.distanceMeters,
            rir: set.isCompleted ? set.rir : nil,
            plan: plan,
            formatter: formatter
        )
        return parts.isEmpty ? L("active.set.noValues") : parts
    }

    private var targetLine: String? {
        guard !set.isCompleted else { return nil }
        let target = SetSummaryText.parts(
            weightKg: set.targetWeightKg,
            reps: set.targetReps,
            durationSeconds: set.targetDurationSeconds,
            distanceMeters: nil,
            rir: nil,
            plan: plan,
            formatter: formatter
        )
        guard !target.isEmpty else { return nil }
        return L("active.set.target", target)
    }

    // MARK: Bindings

    /// The editors work in the user's own unit; the draft always holds kilograms.
    private var weightBinding: Binding<Double?> {
        Binding(
            get: {
                guard let kilograms = model.draft(for: set).weightKg else { return nil }
                return formatter.weightValue(kilograms)
            },
            set: { displayed in
                model.updateDraft(set) { draft in
                    draft.weightKg = displayed.map { formatter.kilograms(fromDisplayed: $0) }
                }
            }
        )
    }

    /// The step follows the gym's own ladder in kilograms; in pounds a round 5 lb is friendlier than
    /// the 5.5 lb that converting a 2.5 kg plate pair would produce.
    private var weightStep: Double {
        formatter.weightUnit == .pounds ? 5 : model.loadStepKg(for: record)
    }

    private var repsBinding: Binding<Int?> {
        Binding(
            get: { model.draft(for: set).reps },
            set: { value in model.updateDraft(set) { $0.reps = value } }
        )
    }

    private var durationBinding: Binding<Int?> {
        Binding(
            get: {
                model.holdTimer.isRunning(for: set.id)
                    ? model.holdTimer.elapsedSeconds
                    : model.draft(for: set).durationSeconds
            },
            set: { value in model.updateDraft(set) { $0.durationSeconds = value } }
        )
    }

    private var distanceBinding: Binding<Double?> {
        Binding(
            get: {
                guard let meters = model.draft(for: set).distanceMeters else { return nil }
                return meters / formatter.distanceUnit.metersPerUnit
            },
            set: { displayed in
                model.updateDraft(set) { draft in
                    draft.distanceMeters = displayed.map { $0 * formatter.distanceUnit.metersPerUnit }
                }
            }
        )
    }

    private var rirBinding: Binding<Int> {
        Binding(
            get: { model.draft(for: set).rir ?? record.targetRIR },
            set: { value in model.updateDraft(set) { $0.rir = value } }
        )
    }
}

// MARK: - Shared formatting

/// Renders a set's numbers as one line, in whatever combination its tracking mode uses.
@MainActor
enum SetSummaryText {
    static func parts(
        weightKg: Double?,
        reps: Int?,
        durationSeconds: Int?,
        distanceMeters: Double?,
        rir: Int?,
        plan: SetFieldPlan,
        formatter: DisplayFormatter
    ) -> String {
        var components: [String] = []

        if plan.showsWeight, let weightKg, weightKg > 0 {
            // Assistance is a subtraction from body weight, so it reads as one.
            components.append(plan.isAssistance ? "−" + formatter.weight(weightKg) : formatter.weight(weightKg))
        }
        if plan.showsReps, let reps {
            components.append(L("active.set.repsValue", reps))
        }
        if plan.showsDuration, let durationSeconds, durationSeconds > 0 {
            components.append(Units.formatDuration(seconds: durationSeconds))
        }
        if plan.showsDistance, let distanceMeters, distanceMeters > 0 {
            components.append(formatter.distance(distanceMeters))
        }

        var line = components.joined(separator: " · ")
        if let rir {
            let effort = L("active.set.rirValue", rir)
            line = line.isEmpty ? effort : line + " · " + effort
        }
        return line
    }
}
