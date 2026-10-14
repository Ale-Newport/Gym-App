import SwiftUI
import SwiftData

/// The first-run flow, from welcome to a working program.
///
/// The container owns everything that is the same on every step — the progress bar, the back
/// control, the primary button and the reason it is disabled — so a step view is nothing but its own
/// questions. That split is what keeps the screens looking like one flow.
struct OnboardingFlowView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = OnboardingViewModel()
    /// +1 when moving forward, −1 when moving back. Set by the control that causes the move, which
    /// is the only place the direction is known before the transition is applied.
    @State private var direction: Double = 1
    /// True while the system notification prompt is up, so a second tap cannot stack another request.
    @State private var isAskingForReminders = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            content
        }
        .task {
            model.load(context: modelContext)
        }
    }

    // MARK: - Four states

    @ViewBuilder
    private var content: some View {
        switch environment.catalog.state {
        case .idle, .loading:
            LoadingStateView(message: L("onboarding.loading"))
        case .failed(let message):
            ErrorStateView(message: message, retryTitle: L("common.retry")) {
                Task { await environment.catalog.load() }
            }
            .readableWidth()
        case .loaded:
            if environment.catalog.count == 0 {
                // An empty catalogue is not a failure the importer reported, but a program cannot be
                // built from it either. Say so, and offer the one action that can change it.
                EmptyStateView(
                    systemImage: "tray",
                    title: L("onboarding.emptyCatalog.title"),
                    message: L("onboarding.emptyCatalog.message")
                ) {
                    Button(L("common.retry")) { Task { await environment.catalog.load() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 220)
                }
                .readableWidth()
            } else {
                flow
            }
        }
    }

    private var flow: some View {
        VStack(spacing: 0) {
            header
            steps
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Metrics.spacing4) {
            HStack(spacing: Metrics.spacing8) {
                if model.canGoBack {
                    Button {
                        direction = -1
                        Haptics.tap()
                        model.goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.appTextPrimary)
                            .minimumTapTarget()
                    }
                    .accessibilityLabel(Text(L("common.back")))
                    .accessibilityIdentifier(OnboardingAccessibility.back)
                } else {
                    Color.clear.frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                }

                Spacer(minLength: 0)

                if let counter = model.stepCounter {
                    Text(counter)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                        .monospacedDigit()
                }

                Spacer(minLength: 0)

                Color.clear.frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
            }

            if model.step != .welcome {
                ProgressBar(value: model.progress, total: 1, tint: .appAccent, height: 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, Metrics.spacing4)
        .padding(.bottom, Metrics.spacing8)
        .readableWidth()
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(model.stepCounter ?? L(model.step.titleKey)))
    }

    // MARK: - Steps

    private var steps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing24) {
                if model.step != .welcome {
                    OnboardingStepHeader(step: model.step)
                }
                stepBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .screenPadding()
            .padding(.top, Metrics.spacing8)
            .padding(.bottom, Metrics.spacing24)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .id(model.step)
        .transition(stepTransition)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.86), value: model.step)
    }

    /// A horizontal push in the direction of travel, reduced to a cross-fade when the user has asked
    /// for less motion.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let edgeIn: Edge = direction >= 0 ? .trailing : .leading
        let edgeOut: Edge = direction >= 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: edgeIn).combined(with: .opacity),
            removal: .move(edge: edgeOut).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private var stepBody: some View {
        switch model.step {
        case .welcome: WelcomeStepView()
        case .about: AboutStepView(model: model)
        case .goal: GoalStepView(model: model)
        case .week: WeekStepView(model: model)
        case .gear: GearStepView(model: model)
        case .reminders: RemindersStepView(model: model)
        case .ready: ReadyStepView(model: model)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Metrics.spacing4) {
            if let error = model.errorMessage {
                OnboardingInlineHint(message: error, systemImage: "exclamationmark.triangle.fill", tint: .appDanger)
            } else if let hint = model.blockingHint, model.step.collectsInput {
                OnboardingInlineHint(message: hint)
            }

            Button {
                primaryAction()
            } label: {
                Text(primaryTitle)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!isPrimaryEnabled)
            .accessibilityHint(Text(primaryAccessibilityHint))
            // The footer action changes label from step to step; a stable identifier is what makes
            // it addressable throughout.
            .accessibilityIdentifier(OnboardingAccessibility.primary)

            if model.step == .reminders {
                Button {
                    notNow()
                } label: {
                    Text(L("start.action.notNow"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isAskingForReminders)
                .accessibilityIdentifier(OnboardingAccessibility.notNow)
            }
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, Metrics.spacing12)
        .padding(.bottom, Metrics.spacing8)
        .readableWidth()
        .background(alignment: .top) {
            Rectangle()
                .fill(Color.appSeparator.opacity(0.6))
                .frame(height: 0.5)
                .accessibilityHidden(true)
        }
    }

    private var primaryTitle: String {
        if model.step == .reminders, !model.wantsAnyReminder { return L("common.continue") }
        return L(model.step.primaryActionKey)
    }

    private var isPrimaryEnabled: Bool {
        switch model.step {
        case .ready: model.generation.result != nil
        case .reminders: !isAskingForReminders
        default: model.canAdvance
        }
    }

    private var primaryAccessibilityHint: String {
        if let hint = model.blockingHint, model.step.collectsInput { return hint }
        if model.step == .ready, model.generation.result == nil { return L("onboarding.generate.waiting") }
        return L("onboarding.action.hint")
    }

    private func primaryAction() {
        direction = 1
        Haptics.tap()
        switch model.step {
        case .ready:
            _ = model.finish(context: modelContext)
        case .reminders:
            Task { await confirmReminders() }
        default:
            model.advance(context: modelContext)
        }
    }

    /// The only place the app asks iOS for notification permission during setup, and only after
    /// the user has said yes to at least one reminder on our own screen.
    private func confirmReminders() async {
        isAskingForReminders = true
        defer { isAskingForReminders = false }

        if model.wantsAnyReminder {
            let granted = await environment.notificationService.requestAuthorization()
            model.recordNotificationOutcome(granted ? .granted : .deniedBySystem)
        } else {
            model.recordNotificationOutcome(.declined)
        }
        model.advance(context: modelContext)
        await model.applyNotificationSchedule(service: environment.notificationService, context: modelContext)
    }

    /// "Not now": nothing is requested, nothing is scheduled, and the step is behind the user.
    private func notNow() {
        direction = 1
        Haptics.tap()
        model.recordNotificationOutcome(.declined)
        model.advance(context: modelContext)
    }
}

/// Stable accessibility identifiers for the onboarding chrome.
///
/// Labels are for people and change with the language; identifiers are for machines and do not.
enum OnboardingAccessibility {
    static let back = "onboarding.back"
    static let primary = "onboarding.primary"
    static let notNow = "onboarding.notNow"
}

#Preview("Onboarding") {
    PreviewHost(scenario: .newUser) {
        OnboardingFlowView()
    }
}
