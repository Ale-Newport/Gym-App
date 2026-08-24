import SwiftUI

/// The opening screen: what the app is going to do with the answers it is about to ask for.
///
/// It exists to buy the questionnaire its credibility. Onboarding asks for a lot — body metrics,
/// injuries, diet — and a user who does not know why is entitled to abandon it. Each promise below
/// maps to a real subsystem, so nothing here is marketing the app cannot keep.
struct WelcomeStepView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasAppeared = false

    private struct Promise: Identifiable {
        let id: String
        let symbol: String
        let titleKey: String
        let detailKey: String
    }

    private let promises: [Promise] = [
        Promise(id: "program", symbol: "square.stack.3d.up.fill",
                titleKey: "onboarding.welcome.program.title",
                detailKey: "onboarding.welcome.program.detail"),
        Promise(id: "progress", symbol: "chart.line.uptrend.xyaxis",
                titleKey: "onboarding.welcome.progress.title",
                detailKey: "onboarding.welcome.progress.detail"),
        Promise(id: "explain", symbol: "text.bubble.fill",
                titleKey: "onboarding.welcome.explain.title",
                detailKey: "onboarding.welcome.explain.detail"),
        Promise(id: "privacy", symbol: "lock.shield.fill",
                titleKey: "onboarding.welcome.privacy.title",
                detailKey: "onboarding.welcome.privacy.detail")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            ForEach(Array(promises.enumerated()), id: \.element.id) { index, promise in
                Card {
                    HStack(alignment: .top, spacing: Metrics.spacing12) {
                        Image(systemName: promise.symbol)
                            .font(.title3)
                            .foregroundStyle(Color.appAccent)
                            .frame(width: 30)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Metrics.spacing4) {
                            Text(L(promise.titleKey))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.appTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L(promise.detailKey))
                                .font(.footnote)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                // A short, staggered reveal reads as the app assembling itself. It is decoration, so
                // it is the first thing to go when the user has asked for reduced motion.
                .opacity(hasAppeared || reduceMotion ? 1 : 0)
                .offset(y: hasAppeared || reduceMotion ? 0 : 12)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.3).delay(Double(index) * 0.06),
                    value: hasAppeared
                )
            }

            Text(L("onboarding.welcome.time", environment.catalog.count))
                .font(.footnote)
                .foregroundStyle(Color.appTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Metrics.spacing4)
        }
        .onAppear { hasAppeared = true }
    }
}

#Preview("Welcome") {
    PreviewHost(scenario: .newUser) {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing20) {
                OnboardingStepHeader(step: .welcome)
                WelcomeStepView()
            }
            .screenPadding()
            .readableWidth()
        }
        .background(Color.appBackground)
    }
}
