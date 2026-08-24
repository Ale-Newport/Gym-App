import SwiftUI

/// Light, dark, or whatever the system is doing.
///
/// The choice is read by `RootView`, which sets `preferredColorScheme` for the whole app, so the
/// change lands the moment it is made. The sample card below the picker forces the chosen scheme on
/// itself, so the user can compare the two without leaving the screen.
struct AppearanceSettingsView: View {
    @State private var model = SettingsViewModel()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemScheme

    init() {}

    private var appearance: AppearancePreference { model.settings?.appearance ?? .system }

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)
                pickerSection
                previewSection
                systemSection
            }
        }
        .navigationTitle(L("settings.appearance.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pickerSection: some View {
        Section {
            HStack(spacing: Metrics.spacing8) {
                ForEach(AppearancePreference.allCases) { option in
                    Button {
                        model.updateSettings { $0.appearance = option }
                        Haptics.selectionChanged()
                    } label: {
                        VStack(spacing: Metrics.spacing6) {
                            Image(systemName: Self.symbol(for: option))
                                .font(.title3)
                            Text(L(option.localizationKey))
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Metrics.spacing12)
                        .foregroundStyle(option == appearance ? Color.appAccent : Color.appTextSecondary)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                                .fill(option == appearance ? Color.appAccentMuted : Color.appFill)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                                .strokeBorder(option == appearance ? Color.appAccent : .clear, lineWidth: 2)
                        )
                        // A tick, not just a tint: the selected option has to be readable without
                        // relying on colour.
                        .overlay(alignment: .topTrailing) {
                            if option == appearance {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color.appAccent)
                                    .padding(Metrics.spacing6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: Metrics.gymTapTarget)
                    .accessibilityLabel(Text(L(option.localizationKey)))
                    .accessibilityAddTraits(option == appearance ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.vertical, Metrics.spacing4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appearance)
        } header: {
            Text(L("settings.appearance.section.theme"))
        } footer: {
            Text(L("settings.appearance.footer"))
        }
        .listRowBackground(Color.appSurface)
    }

    /// A miniature of the app's surfaces in the chosen scheme. `.system` shows whatever the device
    /// is currently doing, which is exactly what selecting it means.
    private var previewSection: some View {
        Section {
            Card {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    Text(L("settings.appearance.sampleTitle"))
                        .font(.appCardTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("settings.appearance.sampleBody"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Metrics.spacing8) {
                        Chip(title: L("settings.appearance.sampleChip"), isSelected: true)
                        Chip(title: L("common.filter"))
                    }
                    ProgressBar(value: 0.7, total: 1)
                }
            }
            .environment(\.colorScheme, forcedScheme ?? systemScheme)
            .padding(.vertical, Metrics.spacing4)
            .accessibilityHidden(true)
        } header: {
            Text(L("settings.appearance.section.preview"))
        }
        .listRowBackground(Color.appSurface)
    }

    /// `nil` for `.system`: the sample then inherits the device scheme instead of pinning one.
    private var forcedScheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Text size, contrast and motion are system-wide settings; the app honours them but cannot set
    /// them, so the honest thing to offer is the shortest route to where they live.
    private var systemSection: some View {
        Section {
            Button {
                openSystemSettings()
            } label: {
                HStack {
                    Text(L("settings.appearance.openSystem"))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "arrow.up.forward.app").accessibilityHidden(true)
                }
                .frame(minHeight: Metrics.minimumTapTarget)
            }
            .foregroundStyle(Color.appAccent)
            SettingsFootnote(text: L("settings.appearance.accessibilityNote"))
        } header: {
            Text(L("settings.appearance.section.system"))
        }
        .listRowBackground(Color.appSurface)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private static func symbol(for appearance: AppearancePreference) -> String {
        switch appearance {
        case .system: "iphone.gen3"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }
}

#Preview("Appearance") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            AppearanceSettingsView()
        }
    }
}
