import SwiftUI

/// The deload recommendation, with the evidence that produced it.
///
/// `DeloadEngine` never recommends an easy week on one signal, so the card lists every signal that
/// fired rather than a single verdict: a user who cannot interrogate the reasoning cannot sensibly
/// overrule it, and overruling it — postponing or declining — has to be as easy as accepting.
struct DeloadPromptCard: View {
    let prompt: HomeViewModel.DeloadPrompt
    var isBusy: Bool = false
    var onRespond: (HomeViewModel.DeloadResponse) -> Void

    private var summary: Explanation? { prompt.reasons.first }
    private var signals: [Explanation] { Array(prompt.reasons.dropFirst()) }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                HStack(spacing: Metrics.spacing8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.appRecovery)
                        .accessibilityHidden(true)
                    Text(L("home.deload.title"))
                        .font(.appCardTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                if let summary {
                    Text(summary.text)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !signals.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.spacing8) {
                        Text(L("home.deload.why"))
                            .font(.appOverline)
                            .foregroundStyle(Color.appTextSecondary)
                        ForEach(Array(signals.enumerated()), id: \.offset) { _, reason in
                            HStack(alignment: .top, spacing: Metrics.spacing8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundStyle(Color.appTextTertiary)
                                    .padding(.top, 6)
                                    .accessibilityHidden(true)
                                Text(reason.text)
                                    .font(.footnote)
                                    .foregroundStyle(Color.appTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Text(L("home.deload.note"))
                    .font(.caption)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: Metrics.spacing8) {
                    Button(L("home.deload.accept")) { onRespond(.accept) }
                        .buttonStyle(PrimaryButtonStyle(tint: .appRecovery))
                        .disabled(isBusy)

                    HStack(spacing: Metrics.spacing8) {
                        Button(L("home.deload.postpone")) { onRespond(.postpone) }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(isBusy)

                        Button(L("home.deload.decline")) { onRespond(.decline) }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(isBusy)
                    }
                }
            }
        }
    }
}

#Preview {
    PreviewHost(scenario: .seasonedUser) {
        ScrollView {
            DeloadPromptCard(
                prompt: .init(
                    recommendationID: UUID(),
                    reasons: [
                        Explanation("deload.summary.recommended", ["44", "12"]),
                        Explanation("deload.reason.performanceRegression", ["3"]),
                        Explanation("deload.reason.blockLength", ["6"]),
                        Explanation("deload.reason.effortInflationSession")
                    ]
                ),
                onRespond: { _ in }
            )
            .screenPadding()
        }
        .background(Color.appBackground)
    }
}
