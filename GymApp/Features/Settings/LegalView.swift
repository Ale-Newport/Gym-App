import SwiftUI

/// Licences, attribution and privacy.
///
/// This screen is a licence obligation rather than a courtesy. The exercise dataset ships under the
/// MIT licence, which requires its notice to travel with the data, while the exercise artwork is
/// the app's own and is not MIT. So the two are kept visibly apart, and both notices are read from
/// the files bundled in `Resources/Legal` rather than retyped here, where they could drift out of
/// step with what actually shipped.
///
/// The privacy half restates `docs/PRIVACY.md` in the app, because a promise the user has to find
/// on a website is not a promise they can check.
struct LegalView: View {
    @Environment(AppEnvironment.self) private var environment

    init() {}

    var body: some View {
        SettingsList {
            mediaSection
            datasetSection
            foodSection
            privacySection
            softwareSection
        }
        .navigationTitle(L("settings.legal.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Media

    /// Where the artwork comes from, given first. A provider whose media carries a credit gets it
    /// shown here as a banner; the bundled artwork is the app's own and carries none.
    private var mediaSection: some View {
        Section {
            if let attribution {
                attributionBanner(attribution)
            }

            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text(L("settings.legal.media.body"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LegalHighlight(text: L("settings.legal.media.notMit"))
            }
            .padding(.vertical, Metrics.spacing4)
            // Selectable on the prose blocks only. Enabling it on the whole list would put a text
            // selection between the user and every row that is actually a control.
            .textSelection(.enabled)

            NavigationLink {
                LegalDocumentView(document: .exerciseMediaNotice)
            } label: {
                Text(L("settings.legal.media.notice"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: Metrics.minimumTapTarget)
            }
        } header: {
            Text(L("settings.legal.section.media"))
        }
        .listRowBackground(Color.appSurface)
    }

    /// The notice itself, verbatim and linked. It is never localised: it is a copyright indication,
    /// not interface copy, and rights holders ask for those exact characters.
    @ViewBuilder
    private func attributionBanner(_ attribution: String) -> some View {
        if let url = attributionURL {
            // No accessibility hint: "Opens in your browser" is already on screen inside the
            // banner, and the combined element speaks it.
            Link(destination: url) { attributionLabel(attribution) }
        } else {
            attributionLabel(attribution)
        }
    }

    private func attributionLabel(_ attribution: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacing12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title3)
                .foregroundStyle(Color.appAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacing2) {
                Text(attribution)
                    .font(.appCardTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if attributionURL != nil {
                    Text(L("settings.legal.opensInBrowser"))
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.spacing12)
        .frame(minHeight: Metrics.minimumTapTarget)
        .background(Color.appAccentMuted, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        .padding(.vertical, Metrics.spacing4)
        .accessibilityElement(children: .combine)
    }

    /// The provider is the source of truth, because swapping the artwork swaps the credit with it.
    private var attribution: String? {
        let provided = environment.mediaProvider.attribution?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let provided, !provided.isEmpty else { return nil }
        return provided
    }

    private var attributionURL: URL? {
        environment.mediaProvider.attributionURL
    }

    // MARK: - Dataset

    private var datasetSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text(L("settings.legal.dataset.body"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LegalHighlight(text: L("settings.legal.dataset.distinction"), systemImage: "scalemass")
            }
            .padding(.vertical, Metrics.spacing4)
            .textSelection(.enabled)

            NavigationLink {
                LegalDocumentView(document: .exerciseDatasetLicence)
            } label: {
                Text(L("settings.legal.dataset.licence"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: Metrics.minimumTapTarget)
            }

            ExternalLinkRow(title: L("settings.legal.dataset.source"), url: Self.datasetSourceURL)
        } header: {
            Text(L("settings.legal.section.dataset"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Food data

    private var foodSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                paragraph(L("settings.legal.food.usda"))
                paragraph(L("settings.legal.food.estimates"))
                paragraph(L("settings.legal.food.openFoodFacts"))
            }
            .padding(.vertical, Metrics.spacing4)
            .textSelection(.enabled)

            ExternalLinkRow(title: L("settings.legal.food.openFoodFactsSite"), url: Self.openFoodFactsURL)
            ExternalLinkRow(title: L("settings.legal.food.odbl"), url: Self.odblURL)
        } header: {
            Text(L("settings.legal.section.food"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Metrics.spacing6) {
                ForEach(Self.privacyKeys, id: \.self) { key in
                    LegalBullet(text: L(key))
                }
            }
            .padding(.vertical, Metrics.spacing4)
            .textSelection(.enabled)

            LegalHighlight(text: L("settings.legal.privacy.notMedical"), systemImage: "info.circle")
                .textSelection(.enabled)
        } header: {
            Text(L("settings.legal.section.privacy"))
        }
        .listRowBackground(Color.appSurface)
    }

    private static let privacyKeys = [
        "settings.legal.privacy.local",
        "settings.legal.privacy.noAnalytics",
        "settings.legal.privacy.noAccount",
        "settings.legal.privacy.network",
        "settings.legal.privacy.optIn",
        "settings.legal.privacy.yourData",
    ]

    // MARK: - Software

    private var softwareSection: some View {
        Section {
            paragraph(L("settings.legal.software.apple"))
                .padding(.vertical, Metrics.spacing4)
                .textSelection(.enabled)
        } header: {
            Text(L("settings.legal.section.software"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Helpers

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.appTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let datasetSourceURL = URL(string: "https://github.com/hasaneyldrm/exercises-dataset")
    private static let openFoodFactsURL = URL(string: "https://world.openfoodfacts.org")
    private static let odblURL = URL(string: "https://opendatacommons.org/licenses/odbl/1-0/")
}

// MARK: - Rows

/// A statement that must not be skimmed past — the MIT-versus-media distinction, chiefly. The icon
/// and the heavier weight carry the emphasis, so it still reads as emphasised without colour.
private struct LegalHighlight: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle"

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacing8) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(Color.appWarning)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LegalBullet: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacing8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(Color.appTextTertiary)
                .padding(.top, 7)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row that leaves the app. Rendered as a link rather than a button so the destination is visible
/// in the accessibility rotor and on long press, and it says where it is going before it goes.
private struct ExternalLinkRow: View {
    let title: String
    let url: URL?

    var body: some View {
        if let url {
            Link(destination: url) {
                HStack(spacing: Metrics.spacing8) {
                    Text(title)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Metrics.spacing8)
                    Image(systemName: "arrow.up.forward.app")
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Metrics.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .foregroundStyle(Color.appAccent)
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(L("settings.legal.opensInBrowser")))
        }
    }
}

// MARK: - Bundled documents

/// One of the notices shipped under `GymApp/Resources/Legal`.
enum LegalDocument: String, Identifiable, CaseIterable, Sendable {
    case exerciseDatasetLicence
    case exerciseMediaNotice

    var id: String { rawValue }

    var fileName: String {
        switch self {
        case .exerciseDatasetLicence: "EXERCISE_DATASET_LICENSE.txt"
        case .exerciseMediaNotice: "EXERCISE_MEDIA_NOTICE.md"
        }
    }

    var titleLocalizationKey: String {
        switch self {
        case .exerciseDatasetLicence: "settings.legal.document.licenceTitle"
        case .exerciseMediaNotice: "settings.legal.document.mediaTitle"
        }
    }
}

/// Reads a bundled notice.
///
/// Kept free of actor isolation so the read can run off the main thread; the files are small, but
/// a licence screen has no business touching the disk on the way to the first frame.
struct LegalDocumentLoader: Sendable {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// `Resources/Legal` is added as a folder reference, so the subdirectory survives into the
    /// built product; the flat lookup is the fallback for bundles that flatten resources.
    func url(for document: LegalDocument) -> URL? {
        if let url = bundle.url(forResource: document.fileName, withExtension: nil, subdirectory: "Legal") {
            return url
        }
        return bundle.url(forResource: document.fileName, withExtension: nil)
    }

    /// Throws rather than returning an empty string: a blank licence screen looks like a bug the
    /// user should wait out, and this is a case where they should be told instead.
    func text(for document: LegalDocument) throws -> String {
        guard let url = url(for: document),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LegalDocumentError.unavailable
        }
        return text
    }
}

enum LegalDocumentError: Error {
    case unavailable
}

/// Loads one notice and reports the three states it can be in.
@MainActor
@Observable
final class LegalDocumentViewModel {

    enum Phase: Equatable {
        case loading
        case ready(String)
        case failed(String)
    }

    private(set) var phase: Phase = .loading

    private let loader: LegalDocumentLoader

    init(loader: LegalDocumentLoader = LegalDocumentLoader()) {
        self.loader = loader
    }

    /// Idempotent: returning to a document already read does not re-read it.
    func load(_ document: LegalDocument) async {
        if case .ready = phase { return }
        phase = .loading
        let loader = self.loader
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try loader.text(for: document)
            }.value
            phase = .ready(text)
        } catch {
            AppLog.app.error("Legal document \(document.fileName, privacy: .public) could not be read")
            phase = .failed(L("settings.legal.document.missing"))
        }
    }
}

/// The full text of a bundled notice, scrollable and selectable.
struct LegalDocumentView: View {
    let document: LegalDocument

    @State private var model = LegalDocumentViewModel()

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                LoadingStateView(message: L("settings.legal.document.loading"))
            case .failed(let message):
                ErrorStateView(message: message, retryTitle: L("common.retry")) {
                    Task { await model.load(document) }
                }
                .readableWidth()
            case .ready(let text):
                ScrollView {
                    Text(text)
                        // Monospaced because these files are hand-wrapped: a proportional face
                        // would make the licence's own layout look broken.
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Color.appTextPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metrics.screenPadding)
                        .readableWidth()
                }
            }
        }
        .background(Color.appBackground)
        .navigationTitle(L(document.titleLocalizationKey))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(document) }
    }
}

#Preview("Legal") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            LegalView()
        }
    }
}

#Preview("Legal document") {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            LegalDocumentView(document: .exerciseDatasetLicence)
        }
    }
}
