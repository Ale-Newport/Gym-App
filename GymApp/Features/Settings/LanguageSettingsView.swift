import SwiftUI

/// The in-app language override.
///
/// SwiftUI's implicit string lookup always follows the *system* language, which is why every string
/// in this app resolves through `LocalizationManager` instead. Choosing here writes both halves of
/// the decision: the manager (which the `L(_:)` lookups and the app's `id` read, so the interface
/// re-renders at once) and `UserSettings.languageOverride` (which a backup carries to a new device).
///
/// Languages are listed by endonym — a person looking for Korean is looking for 한국어, not for the
/// word "Korean" written in a language they do not read.
struct LanguageSettingsView: View {
    @State private var model = SettingsViewModel()

    @EnvironmentObject private var localization: LocalizationManager

    init() {}

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)

                Section {
                    row(
                        title: L("settings.language.followDevice"),
                        detail: AppLanguage.resolvedFromSystem().endonym,
                        isSelected: localization.override == nil
                    ) {
                        model.setLanguage(nil)
                    }
                } header: {
                    Text(L("settings.language.section.device"))
                } footer: {
                    Text(L("settings.language.deviceFooter"))
                }
                .listRowBackground(Color.appSurface)

                Section {
                    ForEach(AppLanguage.allCases) { language in
                        row(
                            title: language.endonym,
                            detail: nil,
                            isSelected: localization.override == language
                        ) {
                            model.setLanguage(language)
                        }
                    }
                } header: {
                    Text(L("settings.language.section.languages"))
                } footer: {
                    Text(L("settings.language.footer"))
                }
                .listRowBackground(Color.appSurface)
            }
        }
        .navigationTitle(L("settings.language.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(title: String, detail: String?, isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button {
            guard !isSelected else { return }
            select()
            Haptics.selectionChanged()
        } label: {
            HStack(spacing: Metrics.spacing12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Metrics.spacing8)
                // The tick is the state, not the tint: selection must survive a greyscale screen.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.appAccent : Color.appTextTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(detail.map { "\(title), \($0)" } ?? title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Language") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            LanguageSettingsView()
        }
    }
}
