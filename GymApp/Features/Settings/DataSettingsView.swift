import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Export, import and reset.
///
/// The point of this screen is that the data is never hostage to the app: any of it can be taken
/// out in a format a spreadsheet can read, a full backup can be restored onto another device, and
/// everything can be deleted. Each of the three is destructive to a different degree, so each one
/// states plainly what it is about to do before it does it.
struct DataSettingsView: View {
    @State private var model = SettingsViewModel()
    @State private var data = DataSettingsViewModel()

    @Environment(\.modelContext) private var modelContext

    init() {}

    var body: some View {
        SettingsScreen(model: model) {
            SettingsList {
                SettingsErrorBanner(model: model)
                operationErrorSection
                exportSection
                importSection
                resetSection
            }
        }
        .navigationTitle(L("settings.data.title"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $data.isChoosingFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            data.handleFileSelection(result)
        }
        .sheet(item: $data.exportedFile) { file in
            ShareSheet(url: file.url)
        }
        .sheet(item: $data.pendingImport) { pending in
            ImportPreviewSheet(pending: pending, data: data, settings: model)
        }
        .sheet(item: $data.report) { report in
            ImportReportSheet(report: report)
        }
        .sheet(isPresented: $data.isConfirmingReset) {
            ResetConfirmationSheet(data: data, settings: model)
        }
    }

    // MARK: - Errors

    /// Export and import failures are reported here rather than as alerts, so the message stays on
    /// screen next to the button that produced it and the user can simply try the other format.
    @ViewBuilder
    private var operationErrorSection: some View {
        if let message = data.errorMessage {
            Section {
                ErrorStateView(message: message, retryTitle: L("common.close")) {
                    data.errorMessage = nil
                }
            }
            .listRowBackground(Color.appSurface)
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section {
            ForEach(ExportFormat.allCases) { format in
                Button {
                    Task { await data.export(format, context: modelContext) }
                } label: {
                    HStack(spacing: Metrics.spacing12) {
                        Image(systemName: format.symbolName)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                            .frame(width: 28, height: 28)
                            .background(Color.appAccentMuted, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L(format.localizationKey))
                                .foregroundStyle(Color.appTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L(format.detailLocalizationKey))
                                .font(.footnote)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Metrics.spacing8)
                        if data.exportingFormat == format {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Color.appTextTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minHeight: Metrics.gymTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(data.isBusy)
                .accessibilityLabel(Text("\(L(format.localizationKey)). \(L(format.detailLocalizationKey))"))
                .accessibilityHint(Text(L("export.shareFile")))
            }
        } header: {
            Text(L("export.title"))
        } footer: {
            Text(L("export.subtitle"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Import

    private var importSection: some View {
        Section {
            Button {
                data.isChoosingFile = true
            } label: {
                HStack(spacing: Metrics.spacing12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.appRecovery)
                        .frame(width: 28, height: 28)
                        .background(Color.appRecoveryMuted, in: RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous))
                        .accessibilityHidden(true)
                    Text(L("import.chooseFile"))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Metrics.spacing8)
                }
                .frame(minHeight: Metrics.gymTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(data.isBusy)
        } header: {
            Text(L("import.title"))
        } footer: {
            Text(L("import.subtitle"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                data.isConfirmingReset = true
            } label: {
                HStack(spacing: Metrics.spacing12) {
                    Image(systemName: "trash")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.appDanger)
                        .frame(width: 28, height: 28)
                        .background(Color.appDanger.opacity(0.14), in: RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous))
                        .accessibilityHidden(true)
                    Text(L("reset.title"))
                        .foregroundStyle(Color.appDanger)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Metrics.spacing8)
                }
                .frame(minHeight: Metrics.gymTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(data.isBusy)
        } header: {
            Text(L("settings.data.section.reset"))
        } footer: {
            Text(L("reset.message"))
        }
        .listRowBackground(Color.appSurface)
    }
}

// MARK: - Import preview

/// What is in the file, and what restoring it would do — shown before anything is written.
private struct ImportPreviewSheet: View {
    let pending: PendingImport
    @Bindable var data: DataSettingsViewModel
    let settings: SettingsViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing20) {
                    Card {
                        VStack(alignment: .leading, spacing: Metrics.spacing8) {
                            Text(L("import.preview.exportedAt", settings.formatter.mediumDate(pending.document.exportedAt)))
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L("import.preview.appVersion", pending.document.appVersion))
                                .font(.footnote)
                                .foregroundStyle(Color.appTextSecondary)
                            Text(pending.fileName)
                                .font(.footnote)
                                .foregroundStyle(Color.appTextTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: Metrics.spacing12) {
                        SectionHeader(L("import.preview.title"))
                        let counts = pending.document.summaryCounts
                        if counts.allSatisfy({ $0.count == 0 }) {
                            // A structurally valid backup can still be empty — a file exported
                            // before anything was logged. Restoring it would do nothing, so say so.
                            EmptyStateView(
                                systemImage: "tray",
                                title: L("settings.data.import.emptyBackup.title"),
                                message: L("settings.data.import.emptyBackup.message")
                            )
                        } else {
                            ForEach(counts, id: \.labelKey) { entry in
                                HStack {
                                    Text(L(entry.labelKey))
                                        .foregroundStyle(Color.appTextSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: Metrics.spacing8)
                                    Text(String(entry.count))
                                        .font(.appNumeric(17))
                                        .foregroundStyle(entry.count == 0 ? Color.appTextTertiary : Color.appTextPrimary)
                                }
                                .frame(minHeight: Metrics.minimumTapTarget)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(L(entry.labelKey)): \(entry.count)")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: Metrics.spacing12) {
                        SectionHeader(L("settings.data.import.strategy"))
                        ForEach(ImportStrategy.allCases) { strategy in
                            strategyRow(strategy)
                        }
                    }

                    Button {
                        // Replace deletes everything already on the device, so it is confirmed
                        // separately from choosing it — picking the option is not consent.
                        if data.importStrategy == .replace {
                            data.isConfirmingReplace = true
                        } else {
                            data.restore(context: modelContext, settings: settings, environment: environment)
                        }
                    } label: {
                        if data.isRestoring {
                            HStack(spacing: Metrics.spacing8) {
                                ProgressView().tint(Color.appOnAccent)
                                Text(L("import.restoring"))
                            }
                        } else {
                            Text(L("import.restore"))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: data.importStrategy == .replace ? .appDanger : .appAccent))
                    .disabled(data.isRestoring)
                }
                .padding(Metrics.screenPadding)
                .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(L("import.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { data.cancelImport() }
                }
            }
            .alert(L("import.confirmReplace.title"), isPresented: $data.isConfirmingReplace) {
                Button(L("common.cancel"), role: .cancel) {}
                Button(L("import.restore"), role: .destructive) {
                    data.restore(context: modelContext, settings: settings, environment: environment)
                }
            } message: {
                Text(L("import.confirmReplace.message"))
            }
        }
        .onChange(of: data.report?.id) { _, newValue in
            // The report replaces this sheet once the restore finishes.
            if newValue != nil { dismiss() }
        }
    }

    private func strategyRow(_ strategy: ImportStrategy) -> some View {
        Button {
            data.importStrategy = strategy
            Haptics.selectionChanged()
        } label: {
            HStack(alignment: .top, spacing: Metrics.spacing12) {
                Image(systemName: data.importStrategy == strategy ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(data.importStrategy == strategy ? Color.appAccent : Color.appTextTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(strategy.localizationKey))
                        .font(.headline)
                        .foregroundStyle(strategy == .replace ? Color.appDanger : Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L(strategy.detailLocalizationKey))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Metrics.spacing12)
            .frame(minHeight: Metrics.gymTapTarget)
            .background(
                RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                    .fill(data.importStrategy == strategy ? Color.appFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(L(strategy.localizationKey)). \(L(strategy.detailLocalizationKey))"))
        .accessibilityAddTraits(data.importStrategy == strategy ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Import report

/// What the restore actually did. Counts, not congratulations: a merge that skipped 40 workouts
/// because they were already there is a success the user needs to be able to verify.
private struct ImportReportSheet: View {
    let report: IdentifiedImportReport

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing16) {
                    Label {
                        Text(L("import.done.title"))
                            .font(.appSectionTitle)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.appSuccess)
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Metrics.spacing8) {
                            line(L("import.done.sessions", report.value.sessionsImported, report.value.sessionsSkipped))
                            line(L("import.done.nutrition", report.value.foodLogEntriesImported))
                            line(L(
                                "import.done.other",
                                report.value.programsImported,
                                report.value.recordsImported,
                                report.value.bodyWeightsImported
                            ))
                            line(L(report.value.strategy.localizationKey))
                        }
                    }

                    Button(L("common.done")) { dismiss() }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .padding(Metrics.screenPadding)
                .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(L("import.title"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.appTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Reset

/// Deleting everything requires typing the word, not tapping "OK" twice. The confirmation also
/// lists what goes, because "all data" is not a specific enough promise to consent to.
private struct ResetConfirmationSheet: View {
    @Bindable var data: DataSettingsViewModel
    let settings: SettingsViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @State private var typed = ""

    private var confirmationWord: String { L("settings.data.reset.word") }

    private var matches: Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(confirmationWord, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing20) {
                    Label {
                        Text(L("reset.title"))
                            .font(.appSectionTitle)
                            .foregroundStyle(Color.appDanger)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.appDanger)
                    }

                    Text(L("reset.message"))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Card {
                        VStack(alignment: .leading, spacing: Metrics.spacing6) {
                            ForEach(Self.deletedItemKeys, id: \.self) { key in
                                HStack(alignment: .top, spacing: Metrics.spacing8) {
                                    Image(systemName: "minus")
                                        .font(.caption2)
                                        .foregroundStyle(Color.appDanger)
                                        .accessibilityHidden(true)
                                    Text(L(key))
                                        .font(.footnote)
                                        .foregroundStyle(Color.appTextSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: Metrics.spacing8) {
                        Text(L("settings.data.reset.typePrompt", confirmationWord))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField(confirmationWord, text: $typed)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.appBody)
                            .padding(Metrics.spacing12)
                            .frame(minHeight: Metrics.gymTapTarget)
                            .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
                            .accessibilityLabel(Text(L("settings.data.reset.typePrompt", confirmationWord)))
                    }

                    Button {
                        data.reset(context: modelContext, settings: settings, environment: environment)
                        dismiss()
                    } label: {
                        Text(L("reset.confirm"))
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: .appDanger))
                    .disabled(!matches)

                    Button(L("common.cancel")) { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .padding(Metrics.screenPadding)
                .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(L("reset.title"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private static let deletedItemKeys = [
        "settings.data.reset.item.profile",
        "settings.data.reset.item.programs",
        "settings.data.reset.item.history",
        "settings.data.reset.item.records",
        "settings.data.reset.item.nutrition",
        "settings.data.reset.item.settings",
    ]
}

// MARK: - Share sheet

/// `UIActivityViewController` rather than `ShareLink`, because the file only exists once the export
/// has run: there is nothing to hand a `ShareLink` at the moment the button is drawn.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Model

/// A file waiting to be shared. Wrapped so `sheet(item:)` has something identifiable to key on.
struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// A backup the user has chosen but not yet restored.
struct PendingImport: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let document: BackupDocument
}

/// `ImportReport` is a plain value; presenting it in a sheet needs an identity.
struct IdentifiedImportReport: Identifiable {
    let id = UUID()
    let value: ImportReport
}

/// Drives export, import and reset.
///
/// All three touch `ModelContext`, which is main-actor bound, so none of them can be moved to a
/// background executor without copying the whole store. What the model does instead is yield once
/// before starting, so the spinner is on screen before the work begins, and keep every stage
/// explicit so the interface is never lying about what is happening.
@MainActor
@Observable
final class DataSettingsViewModel {
    var isChoosingFile = false
    var isConfirmingReplace = false
    var isConfirmingReset = false
    var importStrategy: ImportStrategy = .merge

    private(set) var exportingFormat: ExportFormat?
    private(set) var isRestoring = false

    var exportedFile: ExportedFile?
    var pendingImport: PendingImport?
    var report: IdentifiedImportReport?
    var errorMessage: String?

    var isBusy: Bool { exportingFormat != nil || isRestoring }

    // MARK: Export

    func export(_ format: ExportFormat, context: ModelContext) async {
        guard !isBusy else { return }
        errorMessage = nil
        exportingFormat = format
        await Task.yield()
        do {
            let url = try DataExportService(context: context).export(format)
            exportedFile = ExportedFile(url: url)
            Haptics.success()
        } catch {
            AppLog.export.error("Export failed: \(String(describing: error), privacy: .public)")
            errorMessage = L("export.failed")
            Haptics.error()
        }
        exportingFormat = nil
    }

    // MARK: Import

    func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            inspect(url: url)
        case .failure(let error):
            AppLog.export.error("File selection failed: \(String(describing: error), privacy: .public)")
            errorMessage = L("import.error.unreadable")
        }
    }

    /// Parses and validates without writing anything, so the preview can be trusted.
    private func inspect(url: URL) {
        errorMessage = nil
        do {
            let document = try DataImportService(context: PreviewSafeContext.none).inspect(url: url)
            pendingImport = PendingImport(url: url, fileName: url.lastPathComponent, document: document)
        } catch {
            errorMessage = SettingsViewModel.message(for: error)
            Haptics.error()
        }
    }

    func cancelImport() {
        pendingImport = nil
        isConfirmingReplace = false
    }

    func restore(context: ModelContext, settings: SettingsViewModel, environment: AppEnvironment) {
        guard let pending = pendingImport, !isRestoring else { return }
        isRestoring = true
        let strategy = importStrategy
        do {
            let result = try DataImportService(context: context).restore(pending.document, strategy: strategy)
            report = IdentifiedImportReport(value: result)
            pendingImport = nil
            settings.reload()
            // A replace deletes everything first, the workout in progress included; a merge only
            // adds, so what a widget shows may change but nothing it points at has gone.
            if strategy == .replace {
                environment.storeWasReplaced(context: context)
            } else {
                environment.snapshotWriter.refresh(context: context, catalog: environment.catalog)
            }
            // A restored backup can carry a different language; the manager is what the interface
            // actually reads, so it has to be told or the setting would be inert until next launch.
            LocalizationManager.shared.setOverride(settings.settings?.languageOverride)
            Haptics.success()
        } catch {
            AppLog.persistence.error("Restore failed: \(String(describing: error), privacy: .public)")
            errorMessage = SettingsViewModel.message(for: error)
            Haptics.error()
        }
        isRestoring = false
        isConfirmingReplace = false
    }

    // MARK: Reset

    func reset(context: ModelContext, settings: SettingsViewModel, environment: AppEnvironment) {
        do {
            try ProfileRepository(context: context).resetAllData()
            // Re-reading recreates the three singleton rows, so the app lands on a genuine
            // first-launch state instead of on references to deleted objects.
            settings.reload()
            // A workout in progress was deleted with everything else; its Live Activity and the
            // widget must not outlive it.
            environment.storeWasReplaced(context: context)
            LocalizationManager.shared.setOverride(nil)
            errorMessage = nil
            Haptics.success()
        } catch {
            errorMessage = SettingsViewModel.message(for: error)
            Haptics.error()
        }
    }
}

/// `DataImportService.inspect` never touches the store, but its initialiser still needs a context.
/// Handing it a throwaway in-memory one keeps file validation from being able to write to the real
/// store even by accident.
private enum PreviewSafeContext {
    @MainActor
    static var none: ModelContext {
        ModelContext(PreviewSupport.emptyContainer)
    }
}

#Preview("Data") {
    // Seasoned user: the export formats all have something real to write.
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            DataSettingsView()
        }
    }
}
