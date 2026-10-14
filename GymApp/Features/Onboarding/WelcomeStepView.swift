import SwiftUI

/// The opening screen: what the app is, and the one promise that matters before it asks for
/// anything — no account, nothing leaves the phone.
///
/// It is deliberately short. The questionnaire behind it takes about a minute, and the welcome only
/// has to earn the first tap.
struct WelcomeStepView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hasAppeared = false

    private struct Point: Identifiable {
        let id: String
        let symbol: String
        let titleKey: String
        let detailKey: String
    }

    private let points: [Point] = [
        Point(id: "private", symbol: "lock.shield.fill",
              titleKey: "start.welcome.private.title", detailKey: "start.welcome.private.detail"),
        Point(id: "plan", symbol: "square.stack.3d.up.fill",
              titleKey: "start.welcome.plan.title", detailKey: "start.welcome.plan.detail"),
        Point(id: "adapts", symbol: "chart.line.uptrend.xyaxis",
              titleKey: "start.welcome.adapts.title", detailKey: "start.welcome.adapts.detail")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing32) {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
                Text(L("start.welcome.title"))
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(L("start.welcome.subtitle"))
                    .font(.title3)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Metrics.spacing24)

            VStack(alignment: .leading, spacing: Metrics.spacing20) {
                ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                    HStack(alignment: .top, spacing: Metrics.spacing16) {
                        Image(systemName: point.symbol)
                            .font(.title3)
                            .foregroundStyle(Color.appAccent)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Metrics.spacing2) {
                            Text(L(point.titleKey))
                                .font(.headline)
                                .foregroundStyle(Color.appTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L(point.detailKey))
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    // A short, staggered reveal reads as the app assembling itself. It is
                    // decoration, so it is the first thing to go when motion is reduced.
                    .opacity(hasAppeared || reduceMotion ? 1 : 0)
                    .offset(y: hasAppeared || reduceMotion ? 0 : 12)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.3).delay(Double(index) * 0.08),
                        value: hasAppeared
                    )
                }
            }

            Text(L("start.welcome.time"))
                .font(.footnote)
                .foregroundStyle(Color.appTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { hasAppeared = true }
    }
}

#Preview("Welcome") {
    PreviewHost(scenario: .newUser) {
        ScrollView {
            WelcomeStepView()
                .screenPadding()
                .readableWidth()
        }
        .background(Color.appBackground)
    }
}
