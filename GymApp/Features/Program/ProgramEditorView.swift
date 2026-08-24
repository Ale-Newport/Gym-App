import SwiftData
import SwiftUI

/// Structural editing of the week: which sessions exist, what they are called, which day they land
/// on, and in what order.
///
/// Deliberately separate from `SessionEditorView`. Reordering four sessions and reordering eight
/// exercises inside one of them are different tasks with different mental models, and putting both
/// on one screen makes a drag ambiguous.
struct ProgramEditorView: View {
    let model: ProgramViewModel

    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.displayFormatter) private var formatter

    @State private var renamingTemplate: WorkoutTemplate?
    @State private var pendingDeletion: WorkoutTemplate?
    @State private var pendingProgramDeletion: TrainingProgram?

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L("program.editor.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .sheet(item: $renamingTemplate) { template in
                SessionRenameSheet(
                    initialValue: template.customTitle ?? L(template.titleKey),
                    fallback: L(template.titleKey)
                ) { newTitle in
                    model.renameSession(template, to: newTitle)
                }
            }
            .confirmationDialog(
                L("program.editor.deleteTitle"),
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L("common.delete"), role: .destructive) {
                    if let template = pendingDeletion { model.deleteSession(template) }
                    pendingDeletion = nil
                }
                Button(L("common.cancel"), role: .cancel) { pendingDeletion = nil }
            } message: {
                Text(L("program.editor.deleteMessage"))
            }
            .confirmationDialog(
                L("program.editor.deleteProgramTitle"),
                isPresented: Binding(
                    get: { pendingProgramDeletion != nil },
                    set: { if !$0 { pendingProgramDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L("common.delete"), role: .destructive) {
                    if let program = pendingProgramDeletion { model.delete(program) }
                    pendingProgramDeletion = nil
                }
                Button(L("common.cancel"), role: .cancel) { pendingProgramDeletion = nil }
            } message: {
                Text(L("program.editor.deleteProgramMessage"))
            }
            .programFeedback(model)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("program.loading"))
        case .failed(let message):
            ErrorStateView(message: message, retryTitle: L("common.retry")) {
                Task { await model.load(modelContext: modelContext, catalog: environment.catalog) }
            }
        case .empty:
            EmptyStateView(
                systemImage: "calendar.badge.plus",
                title: L("program.empty.title"),
                message: L("program.empty.message")
            ) {
                Button(L("program.empty.generate")) {
                    Task { await model.regenerate(reason: Explanation("explain.programCreated")) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 320)
                .disabled(model.isWorking)
            }
        case .ready:
            editorList
        }
    }

    private var editorList: some View {
        List {
            sessionsSection
            addSection
            if !model.otherPrograms.isEmpty { otherProgramsSection }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .environment(\.defaultMinListRowHeight, Metrics.minimumTapTarget)
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        Section {
            if let program = model.program {
                ForEach(program.orderedTemplates) { template in
                    row(for: template)
                }
                // Reordering only. Deletion is deliberately not wired to the edit-mode minus:
                // removing a session throws its exercises away with no undo, so it goes through the
                // swipe action and its confirmation instead of a single tap in a drag gesture.
                .onMove { source, destination in
                    model.moveSessions(fromOffsets: source, toOffset: destination)
                }
            }
        } header: {
            Text(L("program.editor.sessionsHeader"))
        } footer: {
            Text(L("program.editor.sessionsFooter"))
        }
    }

    private func row(for template: WorkoutTemplate) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing6) {
            HStack(spacing: Metrics.spacing8) {
                Image(systemName: template.isRestDay ? "moon.zzz" : "figure.strengthtraining.traditional")
                    .font(.footnote)
                    .foregroundStyle(template.isRestDay ? Color.appRecovery : Color.appAccent)
                    .frame(width: 22)
                Text(model.title(of: template))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Metrics.spacing8)
                weekdayMenu(for: template)
            }

            Text(subtitle(for: template))
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Metrics.spacing6)
        .listRowBackground(Color.appSurface)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeletion = template
            } label: {
                Label(L("common.delete"), systemImage: "trash")
            }
            Button {
                model.duplicateSession(template)
            } label: {
                Label(L("common.duplicate"), systemImage: "doc.on.doc")
            }
            .tint(Color.appRecovery)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                renamingTemplate = template
            } label: {
                Label(L("common.rename"), systemImage: "pencil")
            }
            .tint(Color.appAccent)
        }
        .contextMenu {
            Button {
                renamingTemplate = template
            } label: {
                Label(L("common.rename"), systemImage: "pencil")
            }
            Button {
                model.duplicateSession(template)
            } label: {
                Label(L("common.duplicate"), systemImage: "doc.on.doc")
            }
            Button {
                model.saveAsTemplate(template)
            } label: {
                Label(L("program.templates.save"), systemImage: "square.and.arrow.down")
            }
            Button(role: .destructive) {
                pendingDeletion = template
            } label: {
                Label(L("common.delete"), systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.title(of: template)), \(subtitle(for: template))")
    }

    private func subtitle(for template: WorkoutTemplate) -> String {
        if template.isRestDay { return L("program.session.restDay") }
        return L("program.session.summary",
                 template.orderedExercises.count,
                 template.totalPlannedSets,
                 formatter.durationCompact(model.estimatedMinutes(of: template) * 60))
    }

    /// Pinning a session to a weekday, or letting it float.
    ///
    /// A floating session is not a bug: a user who trains "four times, whenever I can" is better
    /// served by an ordered list than by four dates they will miss.
    private func weekdayMenu(for template: WorkoutTemplate) -> some View {
        Menu {
            Button {
                model.setWeekday(nil, on: template)
            } label: {
                Label(L("program.editor.anyDay"), systemImage: template.weekday == nil ? "checkmark" : "calendar")
            }
            Divider()
            ForEach(Weekday.orderedMondayFirst) { day in
                Button {
                    model.setWeekday(day, on: template)
                } label: {
                    if template.weekday == day {
                        Label(L(day.localizationKey), systemImage: "checkmark")
                    } else {
                        Text(L(day.localizationKey))
                    }
                }
            }
        } label: {
            Text(template.weekday.map { L($0.localizationKey) } ?? L("program.editor.anyDay"))
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, Metrics.spacing8)
                .frame(minHeight: Metrics.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L("program.editor.weekdayLabel", model.title(of: template)))
    }

    // MARK: - Adding

    private var addSection: some View {
        Section {
            Button {
                model.addSession(isRestDay: false, weekday: nil)
            } label: {
                Label(L("program.editor.addSession"), systemImage: "plus.circle")
                    .frame(minHeight: Metrics.minimumTapTarget)
            }
            Button {
                model.addSession(isRestDay: true, weekday: nil)
            } label: {
                Label(L("program.editor.addRestDay"), systemImage: "moon.zzz")
                    .frame(minHeight: Metrics.minimumTapTarget)
            }
            NavigationLink(value: ProgramRoute.templates) {
                Label(L("program.editor.fromTemplate"), systemImage: "square.on.square")
                    .frame(minHeight: Metrics.minimumTapTarget)
            }
        } header: {
            Text(L("program.editor.addHeader"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Other programs

    private var otherProgramsSection: some View {
        Section {
            ForEach(model.otherPrograms) { program in
                VStack(alignment: .leading, spacing: Metrics.spacing4) {
                    Text(program.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("program.editor.otherProgramDetail",
                           L(program.splitKey),
                           program.templates.filter { !$0.isRestDay }.count))
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Metrics.spacing4)
                .listRowBackground(Color.appSurface)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingProgramDeletion = program
                    } label: {
                        Label(L("common.delete"), systemImage: "trash")
                    }
                    Button {
                        model.activate(program)
                    } label: {
                        Label(L("program.editor.activate"), systemImage: "checkmark.circle")
                    }
                    .tint(Color.appAccent)
                }
                .contextMenu {
                    Button {
                        model.activate(program)
                    } label: {
                        Label(L("program.editor.activate"), systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) {
                        pendingProgramDeletion = program
                    } label: {
                        Label(L("common.delete"), systemImage: "trash")
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(L("program.editor.otherProgramsHeader"))
        } footer: {
            Text(L("program.editor.otherProgramsFooter"))
        }
    }
}

// MARK: - Rename

/// Renames one session. Clearing the field restores the generated name rather than leaving the
/// session nameless.
struct SessionRenameSheet: View {
    let initialValue: String
    let fallback: String
    let onCommit: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                TextField(fallback, text: $text)
                    .textFieldStyle(.plain)
                    .padding(Metrics.spacing12)
                    .frame(minHeight: Metrics.minimumTapTarget)
                    .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                    .accessibilityLabel(L("program.editor.renameField"))

                Text(L("program.editor.renameNote", fallback))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.top, Metrics.spacing20)
            .screenPadding()
            .readableWidth()
            .background(Color.appBackground)
            .navigationTitle(L("program.editor.renameTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.save"), action: commit)
                }
            }
            .onAppear {
                text = initialValue
                isFocused = true
            }
        }
        .presentationDetents([.medium])
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        onCommit(trimmed.isEmpty ? nil : trimmed)
        dismiss()
    }
}

/// The seasoned-user fixture has a four-day week with fixed weekdays, which is the case where
/// reordering, renaming and re-scheduling all have to coexist.
#Preview {
    PreviewHost(scenario: .seasonedUser) {
        ProgramEditorPreview()
    }
}

private struct ProgramEditorPreview: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @State private var model = ProgramViewModel()

    var body: some View {
        NavigationStack {
            ProgramEditorView(model: model)
        }
        .task { await model.load(modelContext: modelContext, catalog: environment.catalog) }
    }
}
