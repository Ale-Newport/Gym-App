import SwiftUI

/// A compact reading of how recovered the user is, plus the daily check-in that sharpens it.
///
/// Two rules govern this card. It never claims to *measure* anything about the user's body — the
/// wording, and the footnote, say what the app can see and what it suggests. And it never nags: the
/// check-in is one collapsed row until it is tapped, and once answered it disappears for the day.
struct RecoveryCard: View {
    /// One check-in. Every answer is optional, because a user who only wants to answer "I slept
    /// badly" has still told the recovery engine something true.
    struct Answers: Equatable {
        var energy: Int?
        var sleepQuality: Int?
        var soreness: Int?
        var motivation: Int?

        var isEmpty: Bool {
            energy == nil && sleepQuality == nil && soreness == nil && motivation == nil
        }
    }

    let summary: HomeViewModel.RecoverySummary
    var isBusy: Bool = false
    var onSave: (Answers) -> Void

    @State private var isExpanded = false
    @State private var answers = Answers()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                header
                readinessRow
                ExplanationNote(text: summary.summary.text, systemImage: "bolt.heart")

                if !summary.readyGroups.isEmpty {
                    groupSection(title: L("home.recovery.readyGroups"), groups: summary.readyGroups)
                }
                if !summary.recoveringGroups.isEmpty {
                    groupSection(title: L("home.recovery.loadedGroups"), groups: summary.recoveringGroups)
                }

                Text(L("home.recovery.disclaimer"))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Color.appSeparator)
                checkInSection
            }
        }
    }

    // MARK: - Readiness

    private var header: some View {
        HStack(spacing: Metrics.spacing8) {
            Image(systemName: "heart.text.square")
                .font(.caption)
                .foregroundStyle(Color.appRecovery)
                .accessibilityHidden(true)
            Text(L("home.recovery.title"))
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var readinessRow: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("home.recovery.readiness"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                Spacer(minLength: Metrics.spacing8)
                Text(L("home.recovery.readinessValue", Int((summary.readiness * 100).rounded())))
                    .font(.appNumeric(18))
                    .foregroundStyle(Color.appTextPrimary)
            }
            ProgressBar(value: summary.readiness, total: 1, tint: .appRecovery, height: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private func groupSection(title: String, groups: [MuscleGroup]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            Text(title)
                .font(.appOverline)
                .foregroundStyle(Color.appTextSecondary)
            FlowLayout(spacing: Metrics.spacing6, lineSpacing: Metrics.spacing6) {
                ForEach(groups) { group in
                    MuscleGroupBadge(group: group)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title): \(groups.map { L($0.localizationKey) }.joined(separator: ", "))"))
    }

    // MARK: - Check-in

    @ViewBuilder
    private var checkInSection: some View {
        if summary.hasCheckedInToday {
            HStack(spacing: Metrics.spacing8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.appSuccess)
                    .accessibilityHidden(true)
                Text(L("home.recovery.checkInDone"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) {
                        isExpanded.toggle()
                    }
                    Haptics.tap()
                } label: {
                    HStack(alignment: .top, spacing: Metrics.spacing8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("home.recovery.checkInPrompt"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.appTextPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L("home.recovery.checkInHint"))
                                .font(.caption)
                                .foregroundStyle(Color.appTextSecondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Metrics.spacing8)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appTextTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: Metrics.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L("home.recovery.checkInPrompt")))
                .accessibilityHint(Text(isExpanded ? L("home.recovery.collapse") : L("home.recovery.expand")))

                if isExpanded {
                    VStack(spacing: Metrics.spacing16) {
                        RatingRow(
                            title: L("home.recovery.energy"),
                            lowLabel: L("home.recovery.scale.low"),
                            highLabel: L("home.recovery.scale.high"),
                            value: $answers.energy
                        )
                        RatingRow(
                            title: L("home.recovery.sleep"),
                            lowLabel: L("home.recovery.scale.low"),
                            highLabel: L("home.recovery.scale.high"),
                            value: $answers.sleepQuality
                        )
                        RatingRow(
                            title: L("home.recovery.soreness"),
                            lowLabel: L("home.recovery.scale.none"),
                            highLabel: L("home.recovery.scale.lots"),
                            value: $answers.soreness
                        )
                        RatingRow(
                            title: L("home.recovery.motivation"),
                            lowLabel: L("home.recovery.scale.low"),
                            highLabel: L("home.recovery.scale.high"),
                            value: $answers.motivation
                        )

                        Button(L("home.recovery.save")) {
                            onSave(answers)
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                isExpanded = false
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle(tint: .appRecovery))
                        .disabled(answers.isEmpty || isBusy)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

// MARK: - Rating control

/// A 1–5 answer.
///
/// The scale's ends are labelled in words rather than left to the numbers, because "5" means
/// opposite things for energy and for soreness. Selection is shown by fill *and* by weight, and
/// carries the selected accessibility trait, so it never depends on colour.
private struct RatingRow: View {
    let title: String
    let lowLabel: String
    let highLabel: String
    @Binding var value: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Metrics.spacing8) {
                ForEach(1...5, id: \.self) { score in
                    Button {
                        // Tapping the chosen answer again clears it: an answer given by accident
                        // must be removable, and "no answer" is meaningful to the engine.
                        value = (value == score) ? nil : score
                        Haptics.selectionChanged()
                    } label: {
                        Text("\(score)")
                            .font(.subheadline.weight(value == score ? .bold : .regular))
                            // `appSurface` reads as the opposite of the fill in both themes, which
                            // keeps the selected number legible on the tinted background.
                            .foregroundStyle(value == score ? Color.appSurface : Color.appTextSecondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: Metrics.minimumTapTarget)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                                    .fill(value == score ? Color.appRecovery : Color.appFill)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L("home.recovery.rating", title, score)))
                    .accessibilityAddTraits(value == score ? [.isButton, .isSelected] : .isButton)
                }
            }

            HStack {
                Text(lowLabel)
                Spacer(minLength: Metrics.spacing8)
                Text(highLabel)
            }
            .font(.caption2)
            .foregroundStyle(Color.appTextTertiary)
            .accessibilityHidden(true)
        }
    }
}

#Preview {
    PreviewHost(scenario: .seasonedUser) {
        ScrollView {
            RecoveryCard(
                summary: .init(
                    readiness: 0.72,
                    summary: Explanation("recovery.summary.ready"),
                    readyGroups: [.chest, .biceps, .calves, .abs],
                    recoveringGroups: [.quads, .glutes],
                    hasCheckedInToday: false
                ),
                onSave: { _ in }
            )
            .screenPadding()
        }
        .background(Color.appBackground)
    }
}
