import SwiftUI
import SwiftData

/// The first-run questionnaire, from welcome to a working program.
///
/// The container owns everything that is the same on every step — the progress bar, the back and
/// skip controls, the primary button and the reason it is disabled — so a step view is nothing but
/// its own questions. That split is what keeps eleven screens looking like one flow.
struct OnboardingFlowView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = OnboardingViewModel()
    /// +1 when moving forward, −1 when moving back. Set by the control that causes the move, which
    /// is the only place the direction is known before the transition is applied.
    @State private var direction: Double = 1

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
        .task(id: environment.catalog.count) {
            model.prepareStrengthSeeds(catalog: environment.catalog)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Metrics.spacing8) {
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
                    // The goals step offers a muscle group called "Back", so the label alone is
                    // ambiguous — to a test, and to anyone navigating by name.
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

                if model.canSkip {
                    Button {
                        direction = 1
                        Haptics.tap()
                        model.skip(context: modelContext)
                    } label: {
                        Text(L("common.skip"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                            .padding(.horizontal, Metrics.spacing8)
                            .minimumTapTarget()
                    }
                    .accessibilityLabel(Text(L("onboarding.action.skipStep")))
                    .accessibilityIdentifier(OnboardingAccessibility.skip)
                } else {
                    Color.clear.frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                }
            }

            ProgressBar(value: model.progress, total: 1, tint: .appAccent, height: 4)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, Metrics.spacing8)
        .padding(.bottom, Metrics.spacing12)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(model.stepCounter ?? L(model.step.titleKey)))
    }

    // MARK: - Steps

    private var steps: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing20) {
                OnboardingStepHeader(step: model.step)
                stepBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .screenPadding()
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
        case .basics: BasicsStepView(model: model)
        case .goals: GoalsStepView(model: model)
        case .experience: ExperienceStepView(model: model)
        case .availability: AvailabilityStepView(model: model)
        case .equipment: EquipmentStepView(model: model)
        case .restrictions: RestrictionsStepView(model: model)
        case .nutrition: NutritionStepView(model: model)
        case .generating: GeneratingProgramView(model: model)
        case .summary: OnboardingSummaryView(model: model, onEdit: edit(_:))
        }
    }

    private func edit(_ destination: OnboardingStep) {
        direction = -1
        model.jump(to: destination)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Metrics.spacing8) {
            if let error = model.errorMessage {
                OnboardingInlineHint(message: error, systemImage: "exclamationmark.triangle.fill", tint: .appDanger)
            } else if let hint = model.blockingHint, model.step.collectsInput {
                OnboardingInlineHint(message: hint)
            }

            Button {
                primaryAction()
            } label: {
                Text(L(model.step.primaryActionKey))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!isPrimaryEnabled)
            .accessibilityHint(Text(primaryAccessibilityHint))
            // The footer action changes label from step to step ("Next", "Build my program",
            // "Start training"); a stable identifier is what makes it addressable throughout.
            .accessibilityIdentifier(OnboardingAccessibility.primary)
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

    private var isPrimaryEnabled: Bool {
        switch model.step {
        case .generating: model.generation.result != nil
        case .summary: model.errorMessage == nil
        default: model.canAdvance
        }
    }

    private var primaryAccessibilityHint: String {
        if let hint = model.blockingHint, model.step.collectsInput { return hint }
        if model.step == .generating, model.generation.result == nil { return L("onboarding.generate.waiting") }
        return L("onboarding.action.hint")
    }

    private func primaryAction() {
        direction = 1
        Haptics.tap()
        switch model.step {
        case .summary:
            _ = model.finish(context: modelContext)
        default:
            model.advance(context: modelContext)
        }
    }
}

/// Stable accessibility identifiers for the onboarding chrome.
///
/// Labels are for people and change with the language; identifiers are for machines and do not.
/// Everything here is a control whose label is either ambiguous against page content or varies by
/// step.
enum OnboardingAccessibility {
    static let back = "onboarding.back"
    static let skip = "onboarding.skip"
    static let primary = "onboarding.primary"
}

// MARK: - Shared step chrome

/// The title block every step opens with.
struct OnboardingStepHeader: View {
    let step: OnboardingStep

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Image(systemName: step.symbolName)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            Text(L(step.titleKey))
                .font(.title.weight(.bold))
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L(step.subtitleKey))
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Metrics.spacing8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A titled group of related questions inside a step.
struct OnboardingSection<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.appCardTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
            .accessibilityElement(children: .contain)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension OnboardingSection where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// A large, selectable row. The state is carried by a filled symbol as well as by colour, because a
/// tint change alone is invisible to a good number of people.
struct OnboardingChoiceRow: View {
    let title: String
    var detail: String?
    var systemImage: String?
    var badge: String?
    let isSelected: Bool
    var allowsMultiple: Bool = false
    var tint: Color = .appAccent
    let action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.selectionChanged()
            action()
        }) {
            HStack(spacing: Metrics.spacing12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body)
                        .foregroundStyle(isSelected ? tint : Color.appTextTertiary)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Metrics.spacing6) {
                        Text(title)
                            .font(.subheadline.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(tint)
                                .padding(.horizontal, Metrics.spacing6)
                                .padding(.vertical, 2)
                                .background(tint.opacity(0.15), in: Capsule())
                        }
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: selectionSymbol)
                    .font(.body)
                    .foregroundStyle(isSelected ? tint : Color.appTextTertiary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .padding(Metrics.spacing12)
            .frame(minHeight: Metrics.gymTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.10) : Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.55) : Color.appSeparator, lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text([title, badge, detail].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var selectionSymbol: String {
        if allowsMultiple { return isSelected ? "checkmark.square.fill" : "square" }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }
}

/// A chip that toggles membership of a set rather than a boolean.
struct OnboardingChip: View {
    let title: String
    var systemImage: String?
    var detail: String?
    let isSelected: Bool
    var tint: Color = .appAccent
    var isLocked: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            guard !isLocked else { return }
            Haptics.selectionChanged()
            action()
        } label: {
            HStack(spacing: Metrics.spacing6) {
                if isSelected {
                    Image(systemName: isLocked ? "lock.fill" : "checkmark")
                        .font(.caption2.weight(.bold))
                } else if let systemImage {
                    Image(systemName: systemImage).font(.caption)
                }
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                }
            }
            .padding(.horizontal, Metrics.spacing12)
            .foregroundStyle(isSelected ? tint : Color.appTextSecondary)
            .frame(minHeight: Metrics.minimumTapTarget)
            .background(Capsule().fill(isSelected ? tint.opacity(0.15) : Color.appFill))
            .overlay(Capsule().strokeBorder(isSelected ? tint.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(isLocked ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text([title, detail].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text(isLocked ? L("onboarding.chip.locked") : ""))
    }
}

/// A calm, non-blocking note under a control.
struct OnboardingInlineHint: View {
    let message: String
    var systemImage: String = "info.circle"
    var tint: Color = .appTextSecondary

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacing6) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A label with a minus/plus pair, for whole numbers that people nudge rather than type.
struct OnboardingStepperRow: View {
    let title: String
    var subtitle: String?
    let value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var formatted: String
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: Metrics.spacing12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Metrics.spacing4) {
                stepButton("minus", enabled: value > range.lowerBound) { onChange(max(range.lowerBound, value - step)) }
                Text(formatted)
                    .font(.appNumeric(18))
                    .foregroundStyle(Color.appTextPrimary)
                    .frame(minWidth: 54)
                stepButton("plus", enabled: value < range.upperBound) { onChange(min(range.upperBound, value + step)) }
            }
        }
        .padding(Metrics.spacing12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                .strokeBorder(Color.appSeparator, lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(formatted))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if value < range.upperBound { onChange(min(range.upperBound, value + step)) }
            case .decrement: if value > range.lowerBound { onChange(max(range.lowerBound, value - step)) }
            @unknown default: break
            }
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(enabled ? Color.appTextPrimary : Color.appTextTertiary.opacity(0.5))
                .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityHidden(true)
    }
}

/// A plain text field styled to match `NumberEntryField`, so a name and a body weight look like
/// they belong on the same form.
struct OnboardingTextField: View {
    var placeholder: String
    @Binding var text: String
    var accessibilityLabel: String
    var systemImage: String?
    var textContentType: UITextContentType?
    var submitLabel: SubmitLabel = .done
    var onSubmit: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.spacing8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote)
                    .foregroundStyle(Color.appTextTertiary)
                    .accessibilityHidden(true)
            }
            TextField(placeholder, text: $text)
                .font(.body)
                .foregroundStyle(Color.appTextPrimary)
                .focused($isFocused)
                .autocorrectionDisabled()
                .textContentType(textContentType)
                .submitLabel(submitLabel)
                .onSubmit { onSubmit?() }
                .accessibilityLabel(Text(accessibilityLabel))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.appTextTertiary)
                        .minimumTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L("common.clear")))
            }
        }
        .padding(.horizontal, Metrics.spacing12)
        .frame(minHeight: Metrics.gymTapTarget)
        .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                .strokeBorder(isFocused ? Color.appAccent : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }
}

/// Renders a single step inside the flow's chrome. Used only by the per-step previews, so each
/// screen can be designed against the layout it actually ships in.
struct OnboardingStepPreviewHost<Content: View>: View {
    let step: OnboardingStep
    @ViewBuilder var content: (OnboardingViewModel) -> Content

    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @State private var model = OnboardingViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing20) {
                OnboardingStepHeader(step: step)
                content(model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .screenPadding()
            .padding(.bottom, Metrics.spacing32)
            .readableWidth()
        }
        .background(Color.appBackground)
        .task(id: environment.catalog.count) {
            model.load(context: modelContext)
            model.jump(to: step)
            model.prepareStrengthSeeds(catalog: environment.catalog)
        }
    }
}

/// A small text button used for the "skip this part" affordances inside a step.
struct OnboardingSkipButton: View {
    var title: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, Metrics.spacing8)
                .frame(minHeight: Metrics.minimumTapTarget)
        }
        .buttonStyle(.plain)
    }
}

#Preview("Onboarding") {
    PreviewHost(scenario: .newUser) {
        OnboardingFlowView()
    }
}
