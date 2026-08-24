import SwiftUI

/// Asks how the first set of a brand-new movement felt, and sizes the rest of the exercise from the
/// answer.
///
/// The app refuses to invent a working load. When `ProgressionEngine` has no history to reason from
/// it returns `.calibrate` and `LoadEstimator` offers a deliberately light starting point — this
/// sheet is how that guess is corrected, in the ten seconds after the set while the effort is still
/// fresh. Each option previews the load it would produce, so the user is choosing a number rather
/// than trusting an adjective.
struct CalibrationSheet: View {
    let record: ExerciseSession
    let model: ActiveWorkoutViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayFormatter) private var formatter

    private var completedSet: SetRecord? {
        record.orderedSets.last { $0.isCompleted }
    }

    private var plan: SetFieldPlan {
        SetFieldPlan(
            mode: record.trackingMode,
            loadability: model.exercise(for: record)?.metadata.loadability ?? .none
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing20) {
                    VStack(alignment: .leading, spacing: Metrics.spacing8) {
                        Text(L("active.calibration.heading", record.exerciseNameSnapshot.localizedCapitalized))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let performed {
                            Text(L("active.calibration.performed", performed))
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(L("active.calibration.explainer"))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: Metrics.spacing12) {
                        ForEach(CalibrationFeedback.allCases) { feedback in
                            optionButton(feedback)
                        }
                    }
                }
                .padding(.vertical, Metrics.spacing16)
                .screenPadding()
                .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(L("active.calibration.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Dismissing without answering keeps the load exactly as it is — a defensible
                    // outcome, so it is offered plainly rather than hidden behind a swipe.
                    Button(L("active.calibration.keepAsIs")) {
                        model.applyCalibration(.correct, to: record)
                        dismiss()
                    }
                }
            }
        }
    }

    private var performed: String? {
        guard let completedSet else { return nil }
        let line = SetSummaryText.parts(
            weightKg: completedSet.weightKg,
            reps: completedSet.reps,
            durationSeconds: completedSet.durationSeconds,
            distanceMeters: completedSet.distanceMeters,
            rir: nil,
            plan: plan,
            formatter: formatter
        )
        return line.isEmpty ? nil : line
    }

    private func optionButton(_ feedback: CalibrationFeedback) -> some View {
        Button {
            model.applyCalibration(feedback, to: record)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: Metrics.spacing12) {
                Image(systemName: symbol(for: feedback))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint(for: feedback))
                    .frame(width: 28)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L(feedback.localizationKey))
                        .font(.headline)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail(for: feedback))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let preview = previewText(for: feedback) {
                        Text(preview)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(tint(for: feedback))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Metrics.spacing16)
            .frame(maxWidth: .infinity, minHeight: Metrics.gymTapTarget, alignment: .leading)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    .strokeBorder(Color.appSeparator.opacity(0.7), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// The exact load each answer would produce. Nothing here is a surprise after the fact.
    private func previewText(for feedback: CalibrationFeedback) -> String? {
        guard let proposed = model.previewCalibration(feedback, for: record) else { return nil }
        let text = plan.isAssistance ? "−" + formatter.weight(proposed) : formatter.weight(proposed)
        return L("active.calibration.preview", text)
    }

    /// Written out per case rather than built from the raw value, so every key is visible to the
    /// localisation checker.
    private func detail(for feedback: CalibrationFeedback) -> String {
        switch feedback {
        case .tooEasy: L("active.calibration.detail.tooEasy")
        case .correct: L("active.calibration.detail.correct")
        case .hard: L("active.calibration.detail.hard")
        case .tooHeavy: L("active.calibration.detail.tooHeavy")
        }
    }

    private func symbol(for feedback: CalibrationFeedback) -> String {
        switch feedback {
        case .tooEasy: "arrow.up.circle.fill"
        case .correct: "checkmark.circle.fill"
        case .hard: "flame.fill"
        case .tooHeavy: "arrow.down.circle.fill"
        }
    }

    /// Colour reinforces the direction of the change but never carries it alone — every option is
    /// labelled, described, and shows the load it leads to.
    private func tint(for feedback: CalibrationFeedback) -> Color {
        switch feedback {
        case .tooEasy: .appAccent
        case .correct: .appSuccess
        case .hard: .appWarning
        case .tooHeavy: .appDanger
        }
    }
}
