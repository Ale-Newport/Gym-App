import SwiftData
import SwiftUI

/// The training plan, and the reasoning behind it.
///
/// This screen is where the product's central promise is kept: every automatic decision is shown
/// with its explanation, and every one of them can be overruled. The split, the days, the sessions,
/// the exercises inside them and the volume they add up to are all visible here, and every one of
/// them has an edit path that leads to a real change in the store.
struct ProgramOverviewView: View {
    init() {}

    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment

    @State private var model = ProgramViewModel()
    @State private var isPresentingSplitPicker = false
    @State private var isPresentingNameEntry: NameEntryPurpose?
    @State private var isConfirmingRegenerate = false

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L("program.title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbar }
            .navigationDestination(for: ProgramRoute.self) { destination(for: $0) }
            .sheet(isPresented: $isPresentingSplitPicker) {
                SplitPickerSheet(model: model)
            }
            .sheet(item: $isPresentingNameEntry) { purpose in
                NameEntrySheet(purpose: purpose) { name in
                    switch purpose.kind {
                    case .newProgram: model.createManualProgram(title: name, daysPerWeek: purpose.daysPerWeek)
                    case .cloneProgram: model.cloneCurrentProgram(title: name)
                    case .renameProgram: model.renameProgram(to: name)
                    }
                }
            }
            .confirmationDialog(
                L("program.regenerate.confirmTitle"),
                isPresented: $isConfirmingRegenerate,
                titleVisibility: .visible
            ) {
                Button(L("program.regenerate.confirmAction")) {
                    Task { await model.regenerate(reason: Explanation("explain.manualEdit")) }
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("program.regenerate.confirmMessage"))
            }
            .programFeedback(model)
            .task { await model.load(modelContext: modelContext, catalog: environment.catalog) }
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
        case .empty:
            emptyState
        case .ready:
            programBody
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "calendar.badge.plus",
            title: L("program.empty.title"),
            message: L("program.empty.message")
        ) {
            VStack(spacing: Metrics.spacing12) {
                Button(L("program.empty.generate")) {
                    Task { await model.regenerate(reason: Explanation("explain.programCreated")) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isWorking)

                Button(L("program.empty.manual")) {
                    isPresentingNameEntry = NameEntryPurpose(
                        kind: .newProgram,
                        initialValue: L("program.defaultManualTitle"),
                        daysPerWeek: model.context?.profile.daysPerWeek ?? 3
                    )
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: 320)
        }
        .frame(maxHeight: .infinity)
    }

    private var programBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing20) {
                splitCard
                volumeCard
                sessionsSection
                manageSection
            }
            .padding(.vertical, Metrics.spacing20)
            .screenPadding()
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Split

    private var splitCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Metrics.spacing4) {
                        Text(model.program?.title ?? L("program.title"))
                            .font(.appSectionTitle)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L(model.program?.splitKey ?? "split.custom"))
                            .font(.subheadline)
                            .foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Metrics.spacing8)
                    Button {
                        isPresentingNameEntry = NameEntryPurpose(
                            kind: .renameProgram,
                            initialValue: model.program?.title ?? "",
                            daysPerWeek: model.program?.daysPerWeek ?? 3
                        )
                    } label: {
                        Image(systemName: "pencil")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                            .minimumTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("program.renameProgram"))
                }

                HStack(spacing: Metrics.spacing20) {
                    StatTile(
                        value: "\(model.program?.daysPerWeek ?? 0)",
                        label: L("program.stat.daysPerWeek"),
                        systemImage: "calendar"
                    )
                    StatTile(
                        value: "\(trainingSessionCount)",
                        label: L("program.stat.sessions"),
                        systemImage: "figure.strengthtraining.traditional"
                    )
                    StatTile(
                        value: mesocycleValue,
                        label: L("program.stat.mesocycle"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }

                if let explanation = model.splitExplanation {
                    ExplanationNote(text: explanation.text)
                } else {
                    ExplanationNote(text: L("program.split.customNote"), systemImage: "hand.raised")
                }

                if !model.isFollowingRecommendedSplit, let recommended = model.recommendedSplit {
                    InsetGroup {
                        VStack(alignment: .leading, spacing: Metrics.spacing8) {
                            Text(L("program.split.recommends", L(recommended.key)))
                                .font(.footnote)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(L("program.split.useRecommendation")) {
                                Task { await model.applySplit(recommended) }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.isWorking)
                        }
                    }
                }

                Button(L("program.split.change")) { isPresentingSplitPicker = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isWorking)
            }
        }
    }

    private var trainingSessionCount: Int {
        model.program?.templates.filter { !$0.isRestDay }.count ?? 0
    }

    /// "3 / 5" — which week of the mesocycle the plan is in. The counter is what makes the deload
    /// cadence legible instead of arriving as a surprise.
    private var mesocycleValue: String {
        guard let program else { return "—" }
        let length = max(1, program.mesocycleLengthWeeks)
        return "\((program.completedWeeks % length) + 1)/\(length)"
    }

    private var program: TrainingProgram? { model.program }

    // MARK: - Volume

    private var volumeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                SectionHeader(
                    L("program.volume.title"),
                    subtitle: L("program.volume.subtitle", ProgramFormat.sets(totalPlannedCredits))
                )
                WeeklyVolumeChart(rows: model.volumeRows)
            }
        }
    }

    private var totalPlannedCredits: Double {
        model.volumeRows.reduce(0) { $0 + $1.planned }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            SectionHeader(title: L("program.sessions.title"), subtitle: nil) {
                NavigationLink(value: ProgramRoute.editor) {
                    Text(L("common.edit"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                        .minimumTapTarget()
                }
                .accessibilityLabel(L("program.editor.title"))
            }

            if let program, !program.orderedTemplates.isEmpty {
                ForEach(program.orderedTemplates) { template in
                    NavigationLink(value: ProgramRoute.session(template.id)) {
                        SessionSummaryCard(template: template, model: model)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Card {
                    EmptyStateView(
                        systemImage: "square.stack.3d.up.slash",
                        title: L("program.sessions.emptyTitle"),
                        message: L("program.sessions.emptyMessage")
                    ) {
                        NavigationLink(value: ProgramRoute.editor) {
                            Text(L("program.sessions.add"))
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: 260)
                    }
                }
            }
        }
    }

    // MARK: - Manage

    private var manageSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            SectionHeader(L("program.manage.title"))
            Card(padding: Metrics.spacing8) {
                VStack(spacing: 0) {
                    manageRow(.settings, systemImage: "slider.horizontal.3",
                              title: L("program.settings.title"),
                              detail: L("program.manage.settingsDetail"))
                    Divider().overlay(Color.appSeparator)
                    manageRow(.templates, systemImage: "square.on.square",
                              title: L("program.templates.title"),
                              detail: L("program.manage.templatesDetail"))
                    Divider().overlay(Color.appSeparator)
                    manageRow(.versions, systemImage: "clock.arrow.circlepath",
                              title: L("program.versions.title"),
                              detail: L("program.manage.versionsDetail", model.versions.count))
                }
            }
        }
    }

    private func manageRow(
        _ route: ProgramRoute,
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: Metrics.spacing12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Metrics.spacing8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appTextTertiary)
            }
            .padding(.vertical, Metrics.spacing12)
            .padding(.horizontal, Metrics.spacing8)
            .frame(minHeight: Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Toolbar and routing

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    isConfirmingRegenerate = true
                } label: {
                    Label(L("program.action.regenerate"), systemImage: "wand.and.stars")
                }
                .disabled(model.phase != .ready || model.isWorking)

                Button {
                    isPresentingSplitPicker = true
                } label: {
                    Label(L("program.split.change"), systemImage: "square.grid.3x3")
                }
                .disabled(model.context == nil)

                Button {
                    isPresentingNameEntry = NameEntryPurpose(
                        kind: .cloneProgram,
                        initialValue: L("program.clone.defaultTitle", model.program?.title ?? ""),
                        daysPerWeek: model.program?.daysPerWeek ?? 3
                    )
                } label: {
                    Label(L("program.action.clone"), systemImage: "doc.on.doc")
                }
                .disabled(model.program == nil)

                Button {
                    isPresentingNameEntry = NameEntryPurpose(
                        kind: .newProgram,
                        initialValue: L("program.defaultManualTitle"),
                        daysPerWeek: model.context?.profile.daysPerWeek ?? 3
                    )
                } label: {
                    Label(L("program.action.newManual"), systemImage: "plus.square.on.square")
                }
                .disabled(model.context == nil)

                Divider()

                NavigationLink(value: ProgramRoute.editor) {
                    Label(L("program.editor.title"), systemImage: "list.bullet.indent")
                }
                NavigationLink(value: ProgramRoute.versions) {
                    Label(L("program.versions.title"), systemImage: "clock.arrow.circlepath")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(L("program.action.menu"))
        }
    }

    @ViewBuilder
    private func destination(for route: ProgramRoute) -> some View {
        switch route {
        case .editor:
            ProgramEditorView(model: model)
        case .settings:
            ProgramSettingsView(model: model)
        case .versions:
            ProgramVersionHistoryView(model: model)
        case .templates:
            TemplateLibraryView(model: model)
        case .session(let id):
            SessionEditorView(templateID: id, model: model)
        case .exercise(let id):
            // Owned by the exercises feature; the program area only links into it.
            ExerciseDetailView(exerciseID: id)
        }
    }
}

// MARK: - Session summary

/// One session as it appears on the overview: what it trains, how long it takes, what is in it.
struct SessionSummaryCard: View {
    let template: WorkoutTemplate
    let model: ProgramViewModel

    @Environment(\.displayFormatter) private var formatter

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                    Text(model.title(of: template))
                        .font(.appCardTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Metrics.spacing8)
                    if let weekday = template.weekday {
                        Text(L(weekday.localizationKey))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.appTextSecondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextTertiary)
                }

                if template.isRestDay {
                    Text(L("program.session.restDay"))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
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

                    if !exerciseNames.isEmpty {
                        Text(exerciseNames)
                            .font(.caption2)
                            .foregroundStyle(Color.appTextTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if lockedCount > 0 {
                        Label(L("program.session.lockedCount", lockedCount), systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.appAccent)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var lockedCount: Int {
        template.plannedExercises.filter(\.isLocked).count
    }

    private var exerciseNames: String {
        template.orderedExercises
            .compactMap { model.exercise($0.exerciseID)?.name.localizedCapitalized }
            .joined(separator: " · ")
    }
}

// MARK: - Split picker

/// The ranked list of structures the selector considered, each with the reasoning behind it.
///
/// Showing the alternatives — not just the winner — is what turns "the app chose this" into "the
/// app chose this, and here is what it chose over".
struct SplitPickerSheet: View {
    let model: ProgramViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var pending: SelectedSplit?

    var body: some View {
        NavigationStack {
            Group {
                if model.candidateSplits.isEmpty {
                    EmptyStateView(
                        systemImage: "square.grid.3x3",
                        title: L("program.split.emptyTitle"),
                        message: L("program.split.emptyMessage")
                    ) {
                        Button(L("common.close")) { dismiss() }
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(maxWidth: 220)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Metrics.spacing12) {
                            Text(L("program.split.pickerNote"))
                                .font(.footnote)
                                .foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach(Array(model.candidateSplits.enumerated()), id: \.element.key) { index, split in
                                splitRow(split, isRecommended: index == 0)
                            }
                        }
                        .padding(.vertical, Metrics.spacing16)
                        .screenPadding()
                        .readableWidth()
                    }
                }
            }
            .background(Color.appBackground)
            .navigationTitle(L("program.split.pickerTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { dismiss() }
                }
            }
            .confirmationDialog(
                L("program.split.applyTitle"),
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible
            ) {
                Button(L("program.split.applyAction")) {
                    guard let split = pending else { return }
                    pending = nil
                    dismiss()
                    Task { await model.applySplit(split) }
                }
                Button(L("common.cancel"), role: .cancel) { pending = nil }
            } message: {
                Text(L("program.split.applyMessage"))
            }
        }
    }

    private func splitRow(_ split: SelectedSplit, isRecommended: Bool) -> some View {
        Button {
            pending = split
        } label: {
            Card {
                VStack(alignment: .leading, spacing: Metrics.spacing8) {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                        Text(L(split.key))
                            .font(.appCardTitle)
                            .foregroundStyle(Color.appTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Metrics.spacing8)
                        if model.program?.splitKey == split.key {
                            Label(L("program.split.current"), systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appSuccess)
                        } else if isRecommended {
                            Label(L("program.split.recommended"), systemImage: "sparkles")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.appAccent)
                        }
                    }

                    Text(split.explanation.text)
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(L("program.split.structure",
                           split.daysPerWeek,
                           split.blueprints.map { L($0.titleKey) }.joined(separator: " · ")))
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("program.split.applyHint"))
    }
}

// MARK: - Name entry

/// Why a name is being asked for. Carried as a value so one sheet serves three actions.
struct NameEntryPurpose: Identifiable, Hashable {
    enum Kind: Hashable {
        case newProgram
        case cloneProgram
        case renameProgram
    }

    var id: Kind { kind }
    let kind: Kind
    let initialValue: String
    let daysPerWeek: Int

    var titleKey: String {
        switch kind {
        case .newProgram: "program.name.newTitle"
        case .cloneProgram: "program.name.cloneTitle"
        case .renameProgram: "program.name.renameTitle"
        }
    }
}

struct NameEntrySheet: View {
    let purpose: NameEntryPurpose
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                TextField(L("program.name.placeholder"), text: $text)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(Metrics.spacing12)
                    .frame(minHeight: Metrics.minimumTapTarget)
                    .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(commit)
                    .accessibilityLabel(L("program.name.placeholder"))

                if purpose.kind == .newProgram {
                    Text(L("program.name.newNote", purpose.daysPerWeek))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, Metrics.spacing20)
            .screenPadding()
            .readableWidth()
            .background(Color.appBackground)
            .navigationTitle(L(purpose.titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.save"), action: commit)
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear {
                text = purpose.initialValue
                isFocused = true
            }
        }
        .presentationDetents([.medium])
    }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

// MARK: - Feedback

/// Errors as an alert, confirmations as a short-lived banner.
///
/// Applied by every screen in this feature so a change made three pushes deep still reports back,
/// and so a failed save never replaces the screen the user is working in.
struct ProgramFeedbackModifier: ViewModifier {
    let model: ProgramViewModel

    func body(content: Content) -> some View {
        content
            .alert(
                L("common.error"),
                isPresented: Binding(
                    get: { model.actionError != nil },
                    set: { if !$0 { model.actionError = nil } }
                )
            ) {
                Button(L("common.done"), role: .cancel) { model.actionError = nil }
            } message: {
                Text(model.actionError ?? "")
            }
            .safeAreaInset(edge: .bottom) {
                if let notice = model.notice {
                    Text(notice)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Metrics.spacing16)
                        .padding(.vertical, Metrics.spacing12)
                        .frame(maxWidth: 420)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                                .fill(Color.appSurfaceElevated)
                                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                        )
                        .padding(.horizontal, Metrics.screenPadding)
                        .padding(.bottom, Metrics.spacing8)
                        .accessibilityAddTraits(.isStaticText)
                        .task(id: notice) {
                            // Long enough to read a sentence, short enough not to sit over content.
                            try? await Task.sleep(for: .seconds(3))
                            model.notice = nil
                        }
                }
            }
    }
}

extension View {
    func programFeedback(_ model: ProgramViewModel) -> some View {
        modifier(ProgramFeedbackModifier(model: model))
    }
}

#Preview {
    PreviewHost(scenario: .seasonedUser) {
        NavigationStack {
            ProgramOverviewView()
        }
    }
}
