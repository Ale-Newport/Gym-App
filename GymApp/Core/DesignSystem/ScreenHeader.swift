import SwiftUI

// MARK: - Header

/// The title row shared by every top-level screen: the title on the left and its actions on the
/// right, on the same line.
///
/// A system large title sits *under* the navigation bar's buttons, which costs a whole extra row of
/// the most valuable space on the screen. Hiding the bar and drawing this row instead puts the title
/// level with the buttons and lets the content start a row higher. The row is a plain view, so it
/// behaves the same on every OS version the app supports.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var titleFont: Font = .largeTitle.weight(.bold)
    var titleLineLimit: Int = 1
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.spacing8) {
            VStack(alignment: .leading, spacing: Metrics.spacing2) {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(titleLineLimit)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: titleLineLimit > 1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(ScreenHeaderAccessibility.title)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Metrics.spacing2) { trailing }
        }
        .frame(minHeight: Metrics.minimumTapTarget)
        .padding(.horizontal, Metrics.screenPadding)
        .readableWidth()
        .padding(.top, Metrics.spacing4)
        .padding(.bottom, Metrics.spacing4)
        .background(Color.appBackground)
    }
}

enum ScreenHeaderAccessibility {
    /// The title of a top-level screen. The label is localised, so anything that has to find "the
    /// current screen's title" in an arbitrary language needs an identifier that is not.
    static let title = "screenHeader.title"
}

// MARK: - Actions

/// A header action: one icon, a 44-point hit target, the accent colour and nothing else.
struct HeaderIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var accessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HeaderIcon(systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
    }
}

/// The icon of a header action, for use as the label of a `Menu` or a `NavigationLink`.
struct HeaderIcon: View {
    let systemImage: String
    var badge: String?

    var body: some View {
        HStack(spacing: Metrics.spacing2) {
            Image(systemName: systemImage)
                .font(.title3)
            if let badge {
                Text(badge)
                    .font(.footnote.weight(.semibold).monospacedDigit())
            }
        }
        .foregroundStyle(Color.appAccent)
        .frame(minWidth: Metrics.minimumTapTarget, minHeight: Metrics.minimumTapTarget)
        .contentShape(Rectangle())
    }
}

// MARK: - Modifier

extension View {
    /// Replaces the navigation bar of a root screen with a `ScreenHeader`.
    ///
    /// Pushed screens keep their system bar, and with it the back button and the swipe-back gesture:
    /// hiding the bar applies to this screen only. The navigation title is still set, because it is
    /// what the *next* screen's back button is labelled with — "‹ Exercises", not "‹ Back".
    ///
    /// - Parameter backTitle: what pushed screens call this one, when that differs from `title`.
    ///   The Home greeting is a sentence; its back button should say "Home".
    func screenHeader<Trailing: View>(
        _ title: String,
        subtitle: String? = nil,
        backTitle: String? = nil,
        titleFont: Font = .largeTitle.weight(.bold),
        titleLineLimit: Int = 1,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let actions = trailing()
        return self
            .navigationTitle(backTitle ?? title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ScreenHeader(
                    title: title,
                    subtitle: subtitle,
                    titleFont: titleFont,
                    titleLineLimit: titleLineLimit
                ) { actions }
            }
    }

    func screenHeader(
        _ title: String,
        subtitle: String? = nil,
        backTitle: String? = nil,
        titleFont: Font = .largeTitle.weight(.bold),
        titleLineLimit: Int = 1
    ) -> some View {
        screenHeader(
            title,
            subtitle: subtitle,
            backTitle: backTitle,
            titleFont: titleFont,
            titleLineLimit: titleLineLimit
        ) { EmptyView() }
    }
}

// MARK: - Search

/// A search field that lives in the content instead of the navigation bar, which a hidden bar
/// cannot host. Same look as the add-food search, so the two read as one control.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var accessibilityIdentifier: String?

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Metrics.spacing8) {
            Image(systemName: "magnifyingglass")
                .font(.footnote)
                .foregroundStyle(Color.appTextTertiary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .accessibilityIdentifier(accessibilityIdentifier ?? "")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.appTextTertiary)
                        .minimumTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L("common.clear")))
            }
        }
        .padding(.horizontal, Metrics.spacing12)
        .frame(minHeight: Metrics.minimumTapTarget)
        .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }
}
