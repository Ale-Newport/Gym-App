import SwiftData
import SwiftUI

/// What this build actually is.
///
/// Three questions get answered here: which version of the app is running, which revision of the
/// bundled data it is running against, and who the data came from. The version of the exercise
/// catalogue matters more than it looks — a support conversation about a missing exercise starts
/// with it — so it is shown next to the count rather than buried in a log.
///
/// The screen also holds the one way back into onboarding. Re-running setup clears the completed
/// stamp and nothing else, so programs, workouts, records and the food log all survive; the
/// confirmation says so, because "run setup again" reads like a reset to anybody who has been
/// burned by one before.
struct AboutView: View {
    @State private var model = SettingsViewModel()
    @State private var about = AboutViewModel()

    @Environment(AppEnvironment.self) private var environment

    init() {}

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)
                identitySection
                bundledDataSection
                acknowledgementsSection
                setupSection
            }
        }
        .task { await about.load() }
        .navigationTitle(L("settings.about.title"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L("settings.about.rerunOnboarding.confirmTitle"), isPresented: $about.isConfirmingRerun) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("settings.about.rerunOnboarding.confirmAction")) {
                // Clears `onboardingCompletedAt` only. `RootView` watches it and swaps the whole
                // interface back to the flow; everything already logged stays exactly where it is.
                model.reopenOnboarding()
                Haptics.success()
            }
        } message: {
            Text(L("settings.about.rerunOnboarding.confirmMessage"))
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                HStack(spacing: Metrics.spacing12) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.appAccent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Metrics.spacing2) {
                        Text(L("app.name"))
                            .font(.appSectionTitle)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(versionSummary)
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Text(L("settings.about.tagline"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Metrics.spacing4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(L("app.name")). \(versionSummary). \(L("settings.about.tagline"))")

            NavigationLink {
                LegalView()
            } label: {
                SettingsNavigationRow(
                    systemImage: "doc.text",
                    title: L("settings.legal.title"),
                    tint: .appTextSecondary
                )
            }
        }
        .listRowBackground(Color.appSurface)
    }

    /// Marketing version with the build in brackets: the build number is what distinguishes two
    /// copies of "1.0.0", which is the whole reason for showing it.
    private var versionSummary: String {
        "\(L("settings.about.appVersion")) \(AppInfo.shortVersion) (\(AppInfo.build))"
    }

    // MARK: - Bundled data

    private var bundledDataSection: some View {
        Section {
            bundledDataRow(
                title: L("settings.about.exerciseDataset"),
                isLoading: environment.catalog.state == .loading || environment.catalog.state == .idle,
                failureMessage: catalogFailureMessage,
                version: environment.catalog.isLoaded
                    ? L("settings.about.versionValue", environment.catalog.datasetVersion)
                    : nil,
                detail: environment.catalog.isLoaded
                    ? LPlural("exercises.resultCount", environment.catalog.count)
                    : nil
            )

            bundledDataRow(
                title: L("settings.about.foodDatabase"),
                isLoading: about.isLoading,
                failureMessage: about.didFail ? L("settings.about.foodDatabaseFailed") : nil,
                version: about.foodDatabaseVersion.map { L("settings.about.versionValue", $0) },
                detail: about.foodCount.map { LPlural("food.database.foodCount", $0) }
            )
        } header: {
            Text(L("settings.about.section.bundledData"))
        } footer: {
            Text(L("settings.about.bundledDataFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    private var catalogFailureMessage: String? {
        if case .failed = environment.catalog.state { return L("settings.about.datasetFailed") }
        return nil
    }

    /// One row per bundled file, answering all three states in place rather than blanking the row
    /// while it loads: an empty value beside "Food database" reads as "there isn't one".
    private func bundledDataRow(
        title: String,
        isLoading: Bool,
        failureMessage: String?,
        version: String?,
        detail: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            HStack(spacing: Metrics.spacing8) {
                Text(title)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Metrics.spacing8)
                if isLoading {
                    ProgressView()
                } else if let version {
                    Text(version)
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if let failureMessage {
                Label {
                    Text(failureMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.appWarning)
                }
            } else if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isLoading {
                Text(L("settings.about.loadingData"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: Metrics.minimumTapTarget)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Acknowledgements

    private var acknowledgementsSection: some View {
        Section {
            ForEach(Self.acknowledgementKeys, id: \.self) { key in
                SettingsFootnote(text: L(key))
                    .padding(.vertical, Metrics.spacing2)
            }
        } header: {
            Text(L("settings.about.section.acknowledgements"))
        } footer: {
            // The media credit is repeated at the foot of every screen that can reach the artwork,
            // and this screen names its author, so it belongs here too.
            MediaAttributionLabel(
                attribution: environment.mediaProvider.attribution,
                url: environment.mediaProvider.attributionURL
            )
            .padding(.top, Metrics.spacing8)
        }
        .listRowBackground(Color.appSurface)
    }

    private static let acknowledgementKeys = [
        "settings.about.ack.dataset",
        "settings.about.ack.media",
        "food.database.attribution",
        "food.provider.openFoodFacts.attribution",
        "settings.about.ack.apple",
    ]

    // MARK: - Setup

    private var setupSection: some View {
        Section {
            Button {
                about.isConfirmingRerun = true
            } label: {
                HStack(spacing: Metrics.spacing12) {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 28, height: 28)
                        .background(
                            Color.appAccentMuted,
                            in: RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Metrics.spacing2) {
                        Text(L("settings.about.rerunOnboarding"))
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L("settings.about.rerunOnboarding.detail"))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Metrics.spacing8)
                }
                .frame(minHeight: Metrics.gymTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L("settings.about.rerunOnboarding")))
            .accessibilityHint(Text(L("settings.about.rerunOnboarding.detail")))
        } header: {
            Text(L("settings.about.section.setup"))
        }
        .listRowBackground(Color.appSurface)
    }
}

// MARK: - View model

/// Reads the food database manifest.
///
/// Only the manifest, deliberately: the version and the record count are both in it, so the screen
/// never has to decode the six hundred foods themselves just to print two numbers.
@MainActor
@Observable
final class AboutViewModel {
    var isConfirmingRerun = false

    private(set) var isLoading = true
    private(set) var didFail = false
    private(set) var foodDatabaseVersion: String?
    private(set) var foodCount: Int?

    private let loader: FoodCatalogLoader

    init(loader: FoodCatalogLoader = FoodCatalogLoader()) {
        self.loader = loader
    }

    /// Idempotent, so returning to the screen does not re-read the file.
    func load() async {
        guard foodDatabaseVersion == nil, !didFail else {
            isLoading = false
            return
        }
        isLoading = true
        let loader = self.loader
        do {
            let manifest = try await Task.detached(priority: .utility) {
                try loader.loadManifest()
            }.value
            foodDatabaseVersion = manifest.version
            foodCount = manifest.foodCount
            didFail = false
        } catch {
            AppLog.nutrition.error("Food database manifest unavailable: \(String(describing: error), privacy: .public)")
            didFail = true
        }
        isLoading = false
    }
}

#Preview("About") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            AboutView()
        }
    }
}
