import SwiftData
import SwiftUI

// MARK: - Shared step chrome

/// The title block every step opens with: a headline and one line under it.
struct OnboardingStepHeader: View {
    let step: OnboardingStep

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
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
                    .strokeBorder(
                        isSelected ? tint.opacity(0.55) : Color.appSeparator, lineWidth: isSelected ? 1.5 : 0.5)
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

/// A compact selectable tile for short lists — goals, levels — laid out two to a row. The state is
/// carried by the outline and the weight of the text as well as by colour, because a tint change
/// alone is invisible to a good number of people.
struct OnboardingOptionTile: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    var tint: Color = .appAccent
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.selectionChanged()
            action()
        } label: {
            HStack(spacing: Metrics.spacing8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? tint : Color.appTextPrimary)
            .padding(.horizontal, Metrics.spacing12)
            .padding(.vertical, Metrics.spacing8)
            .frame(maxWidth: .infinity, minHeight: Metrics.gymTapTarget, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.10) : Color.appSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    .strokeBorder(
                        isSelected ? tint.opacity(0.55) : Color.appSeparator, lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A two-column grid of `OnboardingOptionTile`s. One column when the text is large enough that two
/// would break words.
struct OnboardingOptionGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: Metrics.spacing8),
                count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
            ),
            spacing: Metrics.spacing8
        ) {
            content
        }
    }
}

/// A row with an icon, a title, a line of detail and a switch. The switch is the whole point of the
/// row; the rest is there so nobody turns something on without knowing what it does.
struct OnboardingToggleRow: View {
    let systemImage: String
    let title: String
    var detail: String?
    var tint: Color = .appAccent
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: Metrics.spacing12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(tint)
        .frame(minHeight: Metrics.minimumTapTarget)
    }
}

/// Renders a single step inside the flow's chrome. Used only by the per-step previews, so each
/// screen can be designed against the layout it actually ships in.
struct OnboardingStepPreviewHost<Content: View>: View {
    let step: OnboardingStep
    @ViewBuilder var content: (OnboardingViewModel) -> Content

    @Environment(\.modelContext) private var modelContext
    @State private var model = OnboardingViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing24) {
                OnboardingStepHeader(step: step)
                content(model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .screenPadding()
            .padding(.bottom, Metrics.spacing32)
            .readableWidth()
        }
        .background(Color.appBackground)
        .task {
            model.load(context: modelContext)
        }
    }
}
