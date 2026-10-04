import SwiftUI

// MARK: - Containers

/// The app's standard content container. One level of card only — nested cards are a smell, so
/// content that needs grouping inside a card uses `InsetGroup` instead.
struct Card<Content: View>: View {
    var padding: CGFloat = Metrics.cardPadding
    var background: Color = .appSurface
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cornerLarge, style: .continuous)
                    .strokeBorder(Color.appSeparator.opacity(0.6), lineWidth: 0.5)
            )
    }
}

/// A subtle grouping used *inside* a card.
struct InsetGroup<Content: View>: View {
    var padding: CGFloat = Metrics.spacing12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
    }
}

/// Section heading with an optional trailing action.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appSectionTitle)
                    .foregroundStyle(Color.appTextPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            Spacer(minLength: Metrics.spacing8)
            trailing
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Buttons

/// The primary call to action. Sized for use mid-set.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = .appAccent
    var isProminent: Bool = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isProminent ? Color.appOnAccent : tint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Metrics.gymTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    .fill(isProminent ? tint : tint.opacity(0.14))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.appTextPrimary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Metrics.minimumTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    .fill(Color.appFill)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Chips

/// A compact selectable token. Used for filters, equipment, goals and muscle priorities.
struct Chip: View {
    let title: String
    var systemImage: String?
    var isSelected: Bool = false
    var tint: Color = .appAccent

    var body: some View {
        HStack(spacing: Metrics.spacing6) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption)
            }
            Text(title).font(.subheadline.weight(isSelected ? .semibold : .regular))
        }
        .padding(.horizontal, Metrics.spacing12)
        .padding(.vertical, Metrics.spacing8)
        .foregroundStyle(isSelected ? tint : Color.appTextSecondary)
        .background(
            Capsule().fill(isSelected ? tint.opacity(0.15) : Color.appFill)
        )
        .overlay(
            Capsule().strokeBorder(isSelected ? tint.opacity(0.5) : .clear, lineWidth: 1)
        )
        .contentShape(Capsule())
    }
}

/// A chip that toggles a binding, with the accessibility traits a control needs.
struct ToggleChip: View {
    let title: String
    var systemImage: String?
    var tint: Color = .appAccent
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
            Haptics.selectionChanged()
        } label: {
            Chip(title: title, systemImage: systemImage, isSelected: isOn, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Stats

/// A single headline number with a label. The building block of the dashboard.
struct StatTile: View {
    let value: String
    let label: String
    var caption: String?
    var tint: Color = .appTextPrimary
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            HStack(spacing: Metrics.spacing4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
            }
            Text(value)
                .font(.appNumeric(24))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// A labelled horizontal progress bar. Used for macros, volume and adherence.
struct ProgressBar: View {
    let value: Double
    let total: Double
    var tint: Color = .appAccent
    var height: CGFloat = 8
    /// When true the bar turns amber past 100 % instead of clamping silently.
    var warnsOnOverflow: Bool = false

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }

    private var isOver: Bool { total > 0 && value > total }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.appFill)
                Capsule()
                    .fill(warnsOnOverflow && isOver ? Color.appWarning : tint)
                    .frame(width: max(height, geometry.size.width * fraction))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A circular progress indicator with a centred label.
struct ProgressRing<Label: View>: View {
    let fraction: Double
    var lineWidth: CGFloat = 10
    var tint: Color = .appAccent
    @ViewBuilder var label: Label

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.appFill, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            label
        }
    }
}

// MARK: - State views

/// Shown while content loads.
struct LoadingStateView: View {
    var message: String?

    var body: some View {
        VStack(spacing: Metrics.spacing12) {
            ProgressView()
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metrics.spacing24)
    }
}

/// Shown when there is genuinely nothing to display, always with a way forward.
struct EmptyStateView<Action: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Metrics.spacing16) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.appTextTertiary)
            VStack(spacing: Metrics.spacing6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.appTextPrimary)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            action
        }
        .frame(maxWidth: .infinity)
        .padding(Metrics.spacing24)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// Shown when something failed, always with a retry.
struct ErrorStateView: View {
    let message: String
    var retryTitle: String?
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: Metrics.spacing16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.appWarning)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
            if let retry, let retryTitle {
                Button(retryTitle, action: retry)
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Metrics.spacing24)
    }
}

// MARK: - Explanation

/// Renders the "why did the app do that?" note attached to a recommendation.
///
/// Every automatic decision the engines make carries one of these, because a user who cannot see
/// the reasoning has no basis for trusting — or overruling — it.
struct ExplanationNote: View {
    let text: String
    var systemImage: String = "sparkles"
    var tint: Color = .appRecovery

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacing8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tile grid

/// A grid of tiles whose column width tracks Dynamic Type.
///
/// `GridItem(.adaptive(minimum:))` takes a constant, so a grid laid out for the default text size
/// keeps trying to fit the same number of columns at accessibility sizes. The tiles do not get
/// wider, the words do, and the result hyphenates inside columns far too narrow for them —
/// "Entrena-miento" stacked above "Se-sio-nes". Scaling the minimum makes the grid drop to fewer,
/// wider columns instead, which is what the extra width was always for.
///
/// `@ScaledMetric` on a bare `1` is the multiplier the current text size implies, so this needs no
/// environment plumbing at the call sites.
struct ScaledTileGrid<Content: View>: View {
    /// Minimum column width at the default text size.
    let minimumWidth: CGFloat
    var columnSpacing: CGFloat = Metrics.spacing12
    var rowSpacing: CGFloat = Metrics.spacing12
    var alignment: HorizontalAlignment = .leading
    var itemAlignment: Alignment = .topLeading
    @ViewBuilder var content: Content

    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: minimumWidth * typeScale),
                    spacing: columnSpacing,
                    alignment: itemAlignment
                )
            ],
            alignment: alignment,
            spacing: rowSpacing,
            content: { content }
        )
    }
}

// MARK: - Layout helpers

/// Constrains reading content to a comfortable width on iPad while filling the screen on iPhone.
struct ReadableWidth: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    func readableWidth() -> some View { modifier(ReadableWidth()) }

    /// Standard horizontal screen padding.
    func screenPadding() -> some View { padding(.horizontal, Metrics.screenPadding) }

    /// Applies a tap target floor without changing the visual size of the label.
    func minimumTapTarget(_ size: CGFloat = Metrics.minimumTapTarget) -> some View {
        frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
    }
}

/// A flowing layout for chips that wraps onto as many lines as it needs.
struct FlowLayout: Layout {
    var spacing: CGFloat = Metrics.spacing8
    var lineSpacing: CGFloat = Metrics.spacing8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0, currentX + size.width > maxWidth {
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? currentX : maxWidth, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX, currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
