import SwiftUI

// MARK: - Persistence

/// Remembers that the guide is still owed to the user.
///
/// A flag in `UserDefaults` rather than a column on the profile: it is presentation state, not
/// something to back up or export, and it must survive the app being killed between the end of
/// onboarding and the first look at the main screen. It is set when onboarding finishes, cleared
/// when the guide is finished or skipped, and cleared again whenever the store is wiped, so a
/// fresh start gets a fresh guide.
enum GuidedTourStore {
    private static let key = "forge.guidedTour.pending"

    static var isPending: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markPending() { UserDefaults.standard.set(true, forKey: key) }
    static func clearPending() { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: - Content

/// One stop of the guide: a tab, and the one thing worth knowing about it.
private struct TourStop: Identifiable {
    let tab: AppTab
    let symbol: String
    let tint: Color
    var id: AppTab { tab }
    var titleKey: String { "tour.\(tab.rawValue).title" }
    var bodyKey: String { "tour.\(tab.rawValue).body" }
}

private let tourStops: [TourStop] = [
    TourStop(tab: .home, symbol: "house.fill", tint: .appAccent),
    TourStop(tab: .workout, symbol: "figure.strengthtraining.traditional", tint: .appAccent),
    TourStop(tab: .exercises, symbol: "square.grid.2x2.fill", tint: .appAccent),
    TourStop(tab: .nutrition, symbol: "fork.knife", tint: .appNutrition),
    TourStop(tab: .progress, symbol: "chart.xyaxis.line", tint: .appRecovery)
]

// MARK: - View

/// A five-card walk through the tab bar, shown once after setup.
///
/// Each card names one tab and says what it is for in a sentence, and the screen behind it switches
/// to that tab, so the words and the thing they describe are on screen together. It sits over the
/// real interface instead of a slideshow of screenshots, which would be out of date by the next
/// release. The last card ends on the action the whole app is for — starting a session.
struct GuidedTourView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var index = 0

    private var stop: TourStop { tourStops[index] }
    private var isLast: Bool { index == tourStops.count - 1 }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.appScrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    // Taps on the dim must not fall through to the screen being described.
                    .onTapGesture {}
                    .accessibilityHidden(true)

                VStack(spacing: 0) {
                    card
                    if horizontalSizeClass == .compact {
                        pointer(in: proxy.size.width)
                    }
                }
                .padding(.horizontal, Metrics.spacing16)
                .padding(.bottom, horizontalSizeClass == .compact ? 76 : Metrics.spacing24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { show(index) }
        .onChange(of: index) { _, newValue in show(newValue) }
    }

    // MARK: - Card

    private var card: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            HStack {
                progressDots
                Spacer(minLength: Metrics.spacing8)
                Button(L("tour.skip")) { finish(goToWorkout: false) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .buttonStyle(.plain)
                    .minimumTapTarget()
                    .accessibilityIdentifier(GuidedTourAccessibility.skip)
            }

            HStack(alignment: .top, spacing: Metrics.spacing12) {
                Image(systemName: stop.symbol)
                    .font(.title3)
                    .foregroundStyle(stop.tint)
                    .frame(width: 44, height: 44)
                    .background(stop.tint.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.spacing4) {
                    Text(L(stop.titleKey))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(L(stop.bodyKey))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .id(index)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            HStack(spacing: Metrics.spacing8) {
                if index > 0 {
                    Button {
                        Haptics.tap()
                        withAnimation(stepAnimation) { index -= 1 }
                    } label: {
                        Text(L("common.back"))
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 110)
                }
                Button {
                    Haptics.tap()
                    if isLast {
                        finish(goToWorkout: true)
                    } else {
                        withAnimation(stepAnimation) { index += 1 }
                    }
                } label: {
                    Text(L(isLast ? "start.action.finish" : "common.next"))
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier(GuidedTourAccessibility.next)
            }
        }
        .padding(Metrics.spacing16)
        .background(Color.appSurfaceElevated, in: RoundedRectangle(cornerRadius: Metrics.cornerXLarge, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
    }

    private var progressDots: some View {
        HStack(spacing: Metrics.spacing4) {
            ForEach(tourStops.indices, id: \.self) { position in
                Capsule()
                    .fill(position == index ? Color.appAccent : Color.appSeparator)
                    .frame(width: position == index ? 18 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("onboarding.progress.counter", index + 1, tourStops.count)))
    }

    // MARK: - Pointer

    /// A small triangle under the card that points down at the tab being described. The tab bar's
    /// own layout is not exposed, so the position is the bar's five equal slots inside its side
    /// margin — close enough for an arrow, and it is dropped on layouts where the bar is elsewhere.
    private func pointer(in width: CGFloat) -> some View {
        let margin: CGFloat = 27
        let slot = (width - margin * 2) / CGFloat(tourStops.count)
        let center = margin + slot * (CGFloat(index) + 0.5)
        return Triangle()
            .fill(Color.appSurfaceElevated)
            .frame(width: 22, height: 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The stack is inset by 16 on each side, so the arrow's centre is measured from there.
            .padding(.leading, center - Metrics.spacing16 - 11)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: index)
            .accessibilityHidden(true)
    }

    // MARK: - Behaviour

    private var stepAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.86)
    }

    /// Brings the described tab to the front, so the card and its subject are on screen together.
    private func show(_ position: Int) {
        guard tourStops.indices.contains(position) else { return }
        router.selectedTab = tourStops[position].tab
    }

    private func finish(goToWorkout: Bool) {
        GuidedTourStore.clearPending()
        router.isShowingTour = false
        router.selectedTab = goToWorkout ? .workout : .home
    }
}

enum GuidedTourAccessibility {
    static let next = "tour.next"
    static let skip = "tour.skip"
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview("Guided tour") {
    PreviewHost(scenario: .seasonedUser) {
        MainTabView()
            .overlay { GuidedTourView() }
    }
}
