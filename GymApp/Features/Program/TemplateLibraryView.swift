import SwiftData
import SwiftUI

/// Saved sessions the user can drop into any program.
///
/// A template is an ordinary `WorkoutTemplate` living in an inactive program that acts as the
/// library — see `TemplateLibrary` — so everything here reuses the same repository calls the program
/// editor uses, and templates travel with a backup for free. Applying one *copies* it: the session
/// that lands in the program is independent from that moment on, which is what makes editing a
/// week safe after you have built it from a template.
struct TemplateLibraryView: View {
    let model: ProgramViewModel

    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.displayFormatter) private var formatter

    @State private var library = TemplateLibraryViewModel()
    @State private var previewing: WorkoutTemplate?
    @State private var renaming: WorkoutTemplate?
    @State private var pendingDeletion: WorkoutTemplate?
    @State private var isPickingSource = false

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L("program.templates.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(item: $previewing) { template in
                TemplatePreviewSheet(template: template, model: model, canApply: model.program != nil) {
                    library.apply(template)
                }
            }
            .sheet(item: $renaming) { template in
                SessionRenameSheet(
                    initialValue: template.customTitle ?? L(template.titleKey),
                    fallback: L(template.titleKey)
                ) { newTitle in
                    library.rename(template, to: newTitle)
                }
            }
            .sheet(isPresented: $isPickingSource) {
                TemplateSourceSheet(sessions: sourceSessions, model: model) { template in
                    library.saveSession(template)
                }
            }
            .confirmationDialog(
                L("program.templates.deleteTitle"),
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L("common.delete"), role: .destructive) {
                    if let template = pendingDeletion { library.delete(template) }
                    pendingDeletion = nil
                }
                Button(L("common.cancel"), role: .cancel) { pendingDeletion = nil }
            } message: {
                Text(L("program.templates.deleteMessage"))
            }
            .programFeedback(model)
            .task(id: model.phase) { library.attach(model) }
    }

    /// Training sessions in the active program that can be saved into the library. Rest days are
    /// left out: a template with nothing in it is not worth a row.
    private var sourceSessions: [WorkoutTemplate] {
        model.program?.orderedTemplates.filter { !$0.isRestDay } ?? []
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPickingSource = true
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel(L("program.templates.saveFrom"))
            .disabled(sourceSessions.isEmpty)
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("program.loading"))
        case .failed(let message):
            ErrorStateView(message: message, retryTitle: L("common.retry")) {
                Task { await model.load(modelContext: modelContext, catalog: environment.catalog) }
            }
        case .empty, .ready:
            if library.templates.isEmpty {
                emptyState
            } else {
                templateList
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "square.on.square",
            title: L("program.templates.emptyTitle"),
            message: L("program.templates.emptyMessage")
        ) {
            VStack(spacing: Metrics.spacing12) {
                Button(L("program.templates.saveFrom")) { isPickingSource = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(sourceSessions.isEmpty)
                if sourceSessions.isEmpty {
                    Text(L("program.templates.noSessions"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 320)
        }
        .frame(maxHeight: .infinity)
    }

    private var templateList: some View {
        List {
            Section {
                ForEach(library.templates) { template in
                    Button {
                        previewing = template
                    } label: {
                        row(template)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.appSurface)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = template
                        } label: {
                            Label(L("common.delete"), systemImage: "trash")
                        }
                        Button {
                            library.duplicate(template)
                        } label: {
                            Label(L("common.duplicate"), systemImage: "doc.on.doc")
                        }
                        .tint(Color.appRecovery)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            renaming = template
                        } label: {
                            Label(L("common.rename"), systemImage: "pencil")
                        }
                        .tint(Color.appAccent)
                    }
                    .contextMenu {
                        Button {
                            library.apply(template)
                        } label: {
                            Label(L("program.templates.apply"), systemImage: "plus.square.on.square")
                        }
                        .disabled(model.program == nil)
                        Button {
                            renaming = template
                        } label: {
                            Label(L("common.rename"), systemImage: "pencil")
                        }
                        Button {
                            library.duplicate(template)
                        } label: {
                            Label(L("common.duplicate"), systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            pendingDeletion = template
                        } label: {
                            Label(L("common.delete"), systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text(LPlural("program.templates.count", library.templates.count))
            } footer: {
                Text(L("program.templates.footer"))
            }

            Section {
                Button {
                    isPickingSource = true
                } label: {
                    Label(L("program.templates.saveFrom"), systemImage: "square.and.arrow.down")
                        .frame(minHeight: Metrics.minimumTapTarget)
                }
                .disabled(sourceSessions.isEmpty)

                if sourceSessions.isEmpty {
                    Text(L("program.templates.noSessions"))
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listRowBackground(Color.appSurface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .environment(\.defaultMinListRowHeight, Metrics.minimumTapTarget)
    }

    private func row(_ template: WorkoutTemplate) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacing8) {
            VStack(alignment: .leading, spacing: Metrics.spacing6) {
                Text(model.title(of: template))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !template.focusGroups.isEmpty {
                    FlowLayout(spacing: Metrics.spacing6, lineSpacing: Metrics.spacing6) {
                        ForEach(template.focusGroups, id: \.self) { group in
                            MuscleGroupBadge(group: group)
                        }
                    }
                }

                Text(L("program.session.summary",
                       template.orderedExercises.count,
                       template.totalPlannedSets,
                       formatter.durationCompact(model.estimatedMinutes(of: template) * 60)))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Metrics.spacing8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextTertiary)
                .padding(.top, 3)
        }
        .padding(.vertical, Metrics.spacing6)
        .frame(minHeight: Metrics.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("program.templates.openHint"))
    }
}

// MARK: - Preview of one template

/// A template as it would arrive in the program: every exercise, with the dose it carries.
struct TemplatePreviewSheet: View {
    let template: WorkoutTemplate
    let model: ProgramViewModel
    let canApply: Bool
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing16) {
                    Card {
                        VStack(alignment: .leading, spacing: Metrics.spacing8) {
                            if !template.focusGroups.isEmpty {
                                FlowLayout(spacing: Metrics.spacing6, lineSpacing: Metrics.spacing6) {
                                    ForEach(template.focusGroups, id: \.self) { group in
                                        MuscleGroupBadge(group: group, showsIcon: true)
                                    }
                                }
                            }
                            Text(L("program.session.summary",
                                   template.orderedExercises.count,
                                   template.totalPlannedSets,
                                   formatter.durationCompact(model.estimatedMinutes(of: template) * 60)))
                                .font(.footnote)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if template.orderedExercises.isEmpty {
                        Card {
                            Text(L("program.templates.emptyExercises"))
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Card {
                            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                                ForEach(template.orderedExercises) { planned in
                                    exerciseRow(planned)
                                }
                            }
                        }
                    }

                    ExplanationNote(text: L("program.templates.previewFooter"), systemImage: "doc.on.doc")

                    Button(L("program.templates.apply")) {
                        onApply()
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canApply)

                    if !canApply {
                        Text(L("program.templates.applyDisabled"))
                            .font(.footnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Metrics.spacing20)
                .screenPadding()
                .readableWidth()
            }
            .background(Color.appBackground)
            .navigationTitle(model.title(of: template))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.close")) { dismiss() }
                }
            }
        }
    }

    private func exerciseRow(_ planned: PlannedExercise) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Metrics.spacing4) {
                Text(model.exercise(planned.exerciseID)?.name.localizedCapitalized ?? planned.exerciseID)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if planned.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.appAccent)
                        .accessibilityHidden(true)
                }
            }
            Text(prescription(of: planned))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func prescription(of planned: PlannedExercise) -> String {
        var parts: [String] = []
        if let seconds = planned.targetDurationSeconds {
            parts.append(L("program.session.setsForTime", planned.targetSets, seconds))
        } else {
            parts.append(L("program.session.setsByReps", planned.targetSets, planned.repRange.description))
        }
        parts.append(Units.formatDuration(seconds: planned.restSeconds))
        parts.append(L("program.session.rirShort", planned.targetRIR))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Saving a session into the library

/// Picks which session of the current program to keep. Presented as its own sheet rather than as a
/// toolbar menu so the list stays readable at large Dynamic Type.
struct TemplateSourceSheet: View {
    let sessions: [WorkoutTemplate]
    let model: ProgramViewModel
    let onPick: (WorkoutTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    EmptyStateView(
                        systemImage: "square.stack.3d.up.slash",
                        title: L("program.templates.emptyTitle"),
                        message: L("program.templates.noSessions")
                    ) {
                        Button(L("common.close")) { dismiss() }
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(maxWidth: 220)
                    }
                } else {
                    List {
                        Section {
                            ForEach(sessions) { session in
                                Button {
                                    onPick(session)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: Metrics.spacing4) {
                                        Text(model.title(of: session))
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Color.appTextPrimary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text(L("program.session.summary",
                                               session.orderedExercises.count,
                                               session.totalPlannedSets,
                                               formatter.durationCompact(model.estimatedMinutes(of: session) * 60)))
                                            .font(.caption)
                                            .foregroundStyle(Color.appTextSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.vertical, Metrics.spacing6)
                                    .frame(minHeight: Metrics.minimumTapTarget)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.appSurface)
                                .accessibilityElement(children: .combine)
                            }
                        } footer: {
                            Text(L("program.templates.saveFromMessage"))
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, Metrics.minimumTapTarget)
                }
            }
            .background(Color.appBackground)
            .navigationTitle(L("program.templates.saveFromTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - View model

/// Keeps the library listing in step with the store.
///
/// The saved templates are not a published property of `ProgramViewModel` — they live in a separate
/// container program that the rest of the feature deliberately filters out — so the list is read on
/// demand and re-read after every mutation. That is one small fetch against a handful of rows, and
/// it is what keeps a deletion or a duplicate visible immediately rather than on the next push.
@MainActor
@Observable
final class TemplateLibraryViewModel {
    private(set) var templates: [WorkoutTemplate] = []

    private var program: ProgramViewModel?

    func attach(_ program: ProgramViewModel) {
        self.program = program
        refresh()
    }

    func refresh() {
        templates = program?.savedTemplates() ?? []
    }

    /// Copies the template into the active program as a new session.
    func apply(_ template: WorkoutTemplate) {
        program?.applyTemplate(template)
        refresh()
    }

    func duplicate(_ template: WorkoutTemplate) {
        program?.duplicateTemplate(template)
        refresh()
    }

    func delete(_ template: WorkoutTemplate) {
        program?.deleteTemplate(template)
        refresh()
    }

    func rename(_ template: WorkoutTemplate, to title: String?) {
        program?.renameSession(template, to: title)
        refresh()
    }

    /// Keeps a session from the active program as a reusable template.
    func saveSession(_ template: WorkoutTemplate) {
        program?.saveAsTemplate(template)
        refresh()
    }
}

/// The seasoned-user fixture has a full week to save from, so both the empty state and the populated
/// list are one tap apart in the preview.
#Preview {
    PreviewHost(scenario: .seasonedUser) {
        TemplateLibraryPreview()
    }
}

private struct TemplateLibraryPreview: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @State private var model = ProgramViewModel()

    var body: some View {
        NavigationStack {
            TemplateLibraryView(model: model)
        }
        .task { await model.load(modelContext: modelContext, catalog: environment.catalog) }
    }
}
