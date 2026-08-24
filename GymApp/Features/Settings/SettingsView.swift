import SwiftData
import SwiftUI

/// The root of Settings.
///
/// Pushed from Home rather than owning a tab, so it renders inside the caller's `NavigationStack`
/// and every sub-screen is a plain push. The list is grouped the way people look for things —
/// "who am I", "how I train", "what I eat", "how the app behaves", "my data", "the small print" —
/// rather than by which model row a setting happens to live in.
struct SettingsView: View {
    @State private var model = SettingsViewModel()

    @Environment(AppEnvironment.self) private var environment

    init() {}

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)

                Section {
                    NavigationLink { ProfileSettingsView() } label: { profileHeader }
                }
                .listRowBackground(Color.appSurface)

                Section(L("settings.section.training")) {
                    NavigationLink { GoalsSettingsView() } label: {
                        SettingsNavigationRow(
                            systemImage: "target",
                            title: L("settings.goals.title"),
                            value: model.primaryGoalTitle
                        )
                    }
                    NavigationLink { TrainingSettingsView() } label: {
                        SettingsNavigationRow(
                            systemImage: "calendar",
                            title: L("settings.training.title"),
                            value: model.trainingDaysSummary
                        )
                    }
                    NavigationLink { EquipmentSettingsView() } label: {
                        SettingsNavigationRow(
                            systemImage: "dumbbell.fill",
                            title: L("settings.equipment.title"),
                            value: model.equipmentSummary
                        )
                    }
                }
                .listRowBackground(Color.appSurface)

                Section(L("settings.section.nutrition")) {
                    NavigationLink { NutritionSettingsView() } label: {
                        SettingsNavigationRow(
                            systemImage: "fork.knife",
                            title: L("settings.nutrition.title"),
                            value: model.nutritionSummary,
                            tint: .appNutrition
                        )
                    }
                }
                .listRowBackground(Color.appSurface)

                Section(L("settings.section.app")) {
                    NavigationLink { UnitsSettingsView() } label: {
                        SettingsNavigationRow(
                            systemImage: "ruler",
                            title: L("settings.units.title"),
                            value: model.unitsSummary,
                            tint: .appRecovery
                        )
                    }
                    NavigationLink { AppearanceSettingsView() } label: {
                        SettingsNavigationRow(
                            systemImage: "circle.lefthalf.filled",
                            title: L("settings.appearance.title"),
                            value: model.appearanceSummary,
                            tint: .appRecovery
                        )
                    }
                    NavigationLink { LanguageSettingsView() } label: {
                        SettingsNavigationRow(
                            systemImage: "globe",
                            title: L("settings.language.title"),
                            value: model.languageSummary,
                            tint: .appRecovery
                        )
                    }
                    NavigationLink { NotificationSettingsView() } label: {
                        SettingsNavigationRow(
                            systemImage: "bell.badge",
                            title: L("settings.notifications.title"),
                            value: model.notificationsSummary,
                            tint: .appRecovery
                        )
                    }
                    NavigationLink { HealthSettingsView() } label: {
                        SettingsNavigationRow(
                            systemImage: "heart.text.square",
                            title: L("settings.health.title"),
                            value: model.healthSummary,
                            tint: .appRecovery
                        )
                    }
                }
                .listRowBackground(Color.appSurface)

                Section(L("settings.section.data")) {
                    NavigationLink { DataSettingsView() } label: {
                        SettingsNavigationRow(
                            systemImage: "externaldrive",
                            title: L("settings.data.title")
                        )
                    }
                }
                .listRowBackground(Color.appSurface)

                Section {
                    NavigationLink { AboutView() } label: {
                        SettingsNavigationRow(
                            systemImage: "info.circle",
                            title: L("settings.about.title"),
                            value: AppInfo.shortVersion,
                            tint: .appTextSecondary
                        )
                    }
                    NavigationLink { LegalView() } label: {
                        SettingsNavigationRow(
                            systemImage: "doc.text",
                            title: L("settings.legal.title"),
                            tint: .appTextSecondary
                        )
                    }
                } header: {
                    Text(L("settings.section.about"))
                } footer: {
                    // The media licence obliges the app to carry this notice wherever the artwork
                    // appears; repeating it at the foot of Settings costs nothing and means it is
                    // never more than one screen away.
                    MediaAttributionLabel(
                        attribution: environment.mediaProvider.attribution,
                        url: environment.mediaProvider.attributionURL
                    )
                    .padding(.top, Metrics.spacing8)
                }
                .listRowBackground(Color.appSurface)
            }
        }
        .navigationTitle(L("settings.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Identity card at the top: who the app thinks you are, and the shortest route to fixing it.
    private var profileHeader: some View {
        HStack(spacing: Metrics.spacing12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacing2) {
                Text(model.displayName)
                    .font(.appCardTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(profileSubtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Metrics.spacing8)
        }
        .padding(.vertical, Metrics.spacing4)
        .frame(minHeight: Metrics.gymTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L("settings.profile.title")): \(model.displayName), \(profileSubtitle)")
    }

    private var profileSubtitle: String {
        guard let profile = model.profile else { return L("settings.profile.subtitle") }
        let experience = L(profile.experience.localizationKey)
        let weight = model.formatter.weight(profile.currentWeightKg)
        return "\(experience) · \(weight)"
    }
}

/// Bundle facts, read once. `Bundle.main.infoDictionary` is a dictionary lookup with string keys,
/// so it is wrapped here rather than repeated on three screens.
enum AppInfo {
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Forge"
    }
}

#Preview("Settings") {
    // The seasoned user has a filled-in profile, so every row shows a real summary value rather
    // than a default.
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            SettingsView()
        }
    }
}
