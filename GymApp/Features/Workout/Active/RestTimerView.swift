import SwiftUI

/// The rest countdown, as it appears over the workout.
///
/// Sized to be read at arm's length: the countdown is the largest type anywhere in the app, and the
/// three controls are `gymTapTarget` tall because they are pressed one-handed, without looking,
/// between sets. The bar sits at the bottom of the screen rather than in the middle so it never
/// covers the set the user has just logged.
struct RestTimerView: View {
    let timer: RestTimerModel
    /// What the user is resting for — the next set, or the next exercise.
    let nextUp: String?
    let onAdjust: (Int) -> Void
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The nudge both adjustment buttons apply. Fifteen seconds is the smallest change that is
    /// actually felt between sets; anything finer turns into repeated tapping.
    private static let adjustment = 15

    var body: some View {
        VStack(spacing: Metrics.spacing12) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                Text(L("active.rest.title"))
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
                Spacer(minLength: Metrics.spacing8)
                if let nextUp {
                    Text(nextUp)
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Text(Units.formatDuration(seconds: timer.remainingSeconds))
                .font(.appNumeric(56, weight: .bold))
                .foregroundStyle(Color.appRecovery)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityLabel(Text(L("active.rest.remaining", Units.formatDuration(seconds: timer.remainingSeconds))))
                .accessibilityAddTraits(.updatesFrequently)

            ProgressBar(value: timer.elapsedFraction, total: 1, tint: .appRecovery, height: 6)
                .animation(reduceMotion ? nil : .linear(duration: 0.25), value: timer.remainingSeconds)

            HStack(spacing: Metrics.spacing12) {
                adjustButton(-Self.adjustment)
                Button(L("active.rest.skip"), action: onSkip)
                    .buttonStyle(PrimaryButtonStyle(tint: .appRecovery))
                    .accessibilityLabel(Text(L("active.rest.skip")))
                adjustButton(Self.adjustment)
            }
        }
        .padding(Metrics.spacing16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .fill(Color.appSurfaceElevated)
                .shadow(color: Color.appTextPrimary.opacity(0.12), radius: 18, y: -4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                .strokeBorder(Color.appRecovery.opacity(0.35), lineWidth: 1)
        )
    }

    private func adjustButton(_ delta: Int) -> some View {
        Button {
            onAdjust(delta)
        } label: {
            Text(delta > 0 ? L("active.rest.plus", delta) : L("active.rest.minus", abs(delta)))
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 78)
                .frame(minHeight: Metrics.gymTapTarget)
                .foregroundStyle(Color.appTextPrimary)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                        .fill(Color.appFill)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(
            delta > 0 ? L("active.rest.addSeconds", delta) : L("active.rest.removeSeconds", abs(delta))
        ))
    }
}

/// Shown for a few seconds once the countdown reaches zero.
///
/// The haptic and the sound can both be missed in a gym, and the timer bar disappears the instant it
/// finishes — so the end of a rest period gets its own visible statement rather than relying on the
/// absence of something.
struct RestFinishedBanner: View {
    var body: some View {
        HStack(spacing: Metrics.spacing8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.appSuccess)
            Text(L("active.rest.finished"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Metrics.spacing16)
        .padding(.vertical, Metrics.spacing12)
        .background(
            Capsule().fill(Color.appSurfaceElevated)
                .shadow(color: Color.appTextPrimary.opacity(0.12), radius: 12, y: -2)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L("active.rest.finished")))
    }
}
