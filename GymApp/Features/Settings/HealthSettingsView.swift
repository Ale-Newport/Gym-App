import SwiftUI

/// The optional bridge to the Health app.
///
/// Two things this screen has to be honest about. First, every feature in Forge works with Health
/// switched off — it is an integration, not a dependency. Second, HealthKit deliberately never tells
/// an app whether *read* access was granted, so the app cannot claim it is reading anything; it can
/// only say what it asks for and what it will do with an answer.
struct HealthSettingsView: View {
    @State private var model = SettingsViewModel()
    @State private var health = HealthSettingsViewModel()

    @Environment(AppEnvironment.self) private var environment

    init() {}

    private var service: HealthService { environment.healthService }

    var body: some View {
        SettingsScreen(model: model) {
            Group {
                if service.availability == .unavailable {
                    unavailableState
                } else {
                    SettingsList {
                        SettingsErrorBanner(model: model)
                        connectionSection
                        readSection
                        writeSection
                        privacySection
                    }
                }
            }
        }
        .task { await health.refresh(service: service, settings: model) }
        .navigationTitle(L("settings.health.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Unavailable

    /// iPad without Health, or a device where HealthKit is restricted. Not an error — the app simply
    /// carries on, and says so.
    private var unavailableState: some View {
        EmptyStateView(
            systemImage: "heart.slash",
            title: L("settings.health.unavailable.title"),
            message: L("settings.health.unavailable.message")
        )
        .readableWidth()
    }

    // MARK: - Connection

    private var isConnected: Bool { model.settings?.healthKitEnabled ?? false }

    private var connectionSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { isConnected },
                set: { isOn in
                    Task { await health.setConnected(isOn, service: service, settings: model) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("settings.health.enable"))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("settings.health.enable.detail"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.appAccent)
            .disabled(health.isRequesting)
            .frame(minHeight: Metrics.minimumTapTarget)

            if health.isRequesting {
                HStack(spacing: Metrics.spacing8) {
                    ProgressView()
                    Text(L("settings.health.requesting"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                }
                .frame(minHeight: Metrics.minimumTapTarget)
            }

            if service.availability == .denied {
                // A refusal is recoverable, but only in iOS Settings — so that is what is offered
                // rather than a retry that would silently do nothing.
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    Text(L("settings.health.denied"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("settings.health.openSettings")) { openSystemSettings() }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 280)
                }
                .padding(.vertical, Metrics.spacing4)
            }
        } header: {
            Text(L("settings.health.section.connection"))
        } footer: {
            Text(L("settings.health.connectionFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Reads

    private var readSection: some View {
        Section {
            healthToggle(
                title: L("settings.health.readBodyMass"),
                detail: L("settings.health.readBodyMass.detail"),
                binding: model.settingsBinding(\.healthKitReadBodyMass, default: true)
            )
            healthToggle(
                title: L("settings.health.readEnergy"),
                detail: L("settings.health.readEnergy.detail"),
                binding: model.settingsBinding(\.healthKitReadActiveEnergy, default: true)
            )
            healthToggle(
                title: L("settings.health.readSteps"),
                detail: L("settings.health.readSteps.detail"),
                binding: model.settingsBinding(\.healthKitReadSteps, default: true)
            )
            healthToggle(
                title: L("settings.health.readSleep"),
                detail: L("settings.health.readSleep.detail"),
                binding: model.settingsBinding(\.healthKitReadSleep, default: false)
            )
        } header: {
            Text(L("settings.health.section.read"))
        } footer: {
            Text(L("settings.health.readFooter"))
        }
        .listRowBackground(Color.appSurface)
        .disabled(!isConnected)
    }

    // MARK: - Writes

    private var writeSection: some View {
        Section {
            healthToggle(
                title: L("settings.health.writeWorkouts"),
                detail: L("settings.health.writeWorkouts.detail"),
                binding: model.settingsBinding(\.healthKitWriteWorkouts, default: true)
            )
            SettingsFootnote(text: L("settings.health.writeBodyMassNote"))
        } header: {
            Text(L("settings.health.section.write"))
        }
        .listRowBackground(Color.appSurface)
        .disabled(!isConnected)
    }

    private func healthToggle(title: String, detail: String, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Color.appAccent)
        .frame(minHeight: Metrics.minimumTapTarget)
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            SettingsFootnote(text: L("settings.health.privacy"))
            Button {
                openSystemSettings()
            } label: {
                HStack {
                    Text(L("settings.health.manageInSettings"))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "arrow.up.forward.app").accessibilityHidden(true)
                }
                .frame(minHeight: Metrics.minimumTapTarget)
            }
            .foregroundStyle(Color.appAccent)
        } header: {
            Text(L("settings.health.section.privacy"))
        }
        .listRowBackground(Color.appSurface)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Owns the authorisation flow so the view stays declarative.
@MainActor
@Observable
final class HealthSettingsViewModel {
    private(set) var isRequesting = false

    /// Brings the service's cached availability in line with what the user has stored. A user who
    /// turned Health on last week arrives here with the service freshly constructed and therefore
    /// `.notDetermined`; asking again is silent when iOS has already been answered.
    func refresh(service: HealthService, settings: SettingsViewModel) async {
        guard service.availability != .unavailable else { return }
        guard settings.settings?.healthKitEnabled == true else { return }
        guard service.availability == .notDetermined else { return }
        isRequesting = true
        await service.requestAuthorization()
        isRequesting = false
    }

    /// Turning the switch on asks iOS for permission; turning it off stops every read and write.
    ///
    /// The stored flag only follows a *successful* request, so the switch can never sit in the "on"
    /// position while the app has no access — which would be a lie the user acts on.
    func setConnected(_ isOn: Bool, service: HealthService, settings: SettingsViewModel) async {
        guard isOn else {
            settings.updateSettings { $0.healthKitEnabled = false }
            return
        }
        isRequesting = true
        let granted = await service.requestAuthorization()
        isRequesting = false
        settings.updateSettings { $0.healthKitEnabled = granted }
        if granted { Haptics.success() } else { Haptics.warning() }
    }
}

#Preview("Health") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            HealthSettingsView()
        }
    }
}
