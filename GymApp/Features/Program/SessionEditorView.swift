import SwiftData
import SwiftUI

/// One session, editable down to the individual prescription.
///
/// Every control here writes straight through to the store, and the weekly volume chart at the
/// bottom recomputes on the same frame — so the user can see, while they are adding the fourth set
/// of chest work, that the chest has just gone past the ceiling the allocator drew for it. That is
/// shown as information and never as a block: the ceiling is the app's estimate about a body the
/// user has lived in for far longer than the app has known them.
struct SessionEditorView: View {
    let templateID: UUID
    let model: ProgramViewModel

    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.displayFormatter) private var formatter
    @Environment(\.dismiss) private var dismiss

    @State private var expandedExerciseID: UUID?
    @State private var swapTarget: PlannedExercise?
    @State private var pendingRemoval: PlannedExercise?
    @State private var isPresentingPicker = false
    @State private var isRenaming = false
    @State private var isConfirmingRegenerate = false

    private var template: WorkoutTemplate? { model.template(templateID) }

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(template.map(model.title(of:)) ?? L("session.untitled"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $isRenaming) {
                if let template {
                    SessionRenameSheet(
                        initialValue: template.customTitle ?? L(template.titleKey),
                        fallback: L(template.titleKey)
                    ) { newTitle in
                        model.renameSession(template, to: newTitle)
                    }
                }
            }
            .sheet(isPresented: $isPresentingPicker) {
                ExercisePickerSheet(title: L("program.session.addExercise")) { exercise in
                    guard let template else { return }
                    model.addExercise(exercise.id, to: template)
                }
            }
            .sheet(item: $swapTarget) { planned in
                ExerciseSubstitutionSheet(
                    exerciseID: planned.exerciseID,
                    sessionExerciseIDs: Set(template?.plannedExercises.map(\.exerciseID) ?? [])
                ) { exercise, reason in
                    model.substitute(planned, with: exercise.id, reason: reason)
                }
            }
            .confirmationDialog(
                L("program.session.regenerateTitle"),
                isPresented: $isConfirmingRegenerate,
                titleVisibility: .visible
            ) {
                Button(L("program.session.regenerateAction")) {
                    guard let template else { return }
                    Task { await model.regenerateSession(template) }
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("program.session.regenerateMessage"))
            }
            .confirmationDialog(
                L("program.session.removeTitle"),
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(L("common.remove"), role: .destructive) {
                    if let planned = pendingRemoval { model.removeExercise(planned) }
                    pendingRemoval = nil
                }
                Button(L("common.cancel"), role: .cancel) { pendingRemoval = nil }
            }
            .programFeedback(model)
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
            if let template {
                editor(template)
            } else {
                // The session was deleted while this screen was open — from the program editor, or
                // by a regeneration that replaced every template.
                EmptyStateView(
                    systemImage: "questionmark.folder",
                    title: L("program.session.missingTitle"),
                    message: L("program.session.missingMessage")
                ) {
                    Button(L("common.back")) { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 220)
                }
            }
        }
    }

    private func editor(_ template: WorkoutTemplate) -> some View {
        List {
            summarySection(template)
            exercisesSection(template)
            volumeSection(template)
            actionsSection(template)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .environment(\.defaultMinListRowHeight, Metrics.minimumTapTarget)
    }

    // MARK: - Summary

    private func summarySection(_ template: WorkoutTemplate) -> some View {
        Section {
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
            .padding(.vertical, Metrics.spacing4)
            .accessibilityElement(children: .combine)

            LabeledContent(L("program.session.weekday")) {
                weekdayMenu(template)
            }
            .frame(minHeight: Metrics.minimumTapTarget)
        } header: {
            Text(L("program.session.aboutHeader"))
        }
        .listRowBackground(Color.appSurface)
    }

    private func weekdayMenu(_ template: WorkoutTemplate) -> some View {
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
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.appAccent)
                .frame(minHeight: Metrics.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L("program.session.weekday"))
    }

    // MARK: - Exercises

    @ViewBuilder
    private func exercisesSection(_ template: WorkoutTemplate) -> some View {
        Section {
            if template.orderedExercises.isEmpty {
                EmptyStateView(
                    systemImage: "dumbbell",
                    title: L("program.session.emptyTitle"),
                    message: L("program.session.emptyMessage")
                ) {
                    Button(L("program.session.addExercise")) { isPresentingPicker = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 260)
                }
                .listRowBackground(Color.appSurface)
            } else {
                ForEach(template.orderedExercises) { planned in
                    PlannedExerciseRow(
                        planned: planned,
                        template: template,
                        model: model,
                        isExpanded: Binding(
                            get: { expandedExerciseID == planned.id },
                            set: { expandedExerciseID = $0 ? planned.id : nil }
                        ),
                        onSwap: { swapTarget = planned },
                        onRemove: { pendingRemoval = planned }
                    )
                    .listRowBackground(Color.appSurface)
                }
                .onMove { source, destination in
                    model.moveExercises(in: template, fromOffsets: source, toOffset: destination)
                }
            }

            Button {
                isPresentingPicker = true
            } label: {
                Label(L("program.session.addExercise"), systemImage: "plus.circle")
                    .frame(minHeight: Metrics.minimumTapTarget)
            }
            .listRowBackground(Color.appSurface)
        } header: {
            Text(L("program.session.exercisesHeader"))
        } footer: {
            Text(L("program.session.exercisesFooter"))
        }
    }

    // MARK: - Volume

    private func volumeSection(_ template: WorkoutTemplate) -> some View {
        let groups = model.groups(in: template)
        let rows = model.volumeRows(touching: groups)
        return Section {
            if rows.isEmpty {
                Text(L("program.volume.emptyMessage"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                WeeklyVolumeChart(rows: rows, highlighted: groups)
                    .padding(.vertical, Metrics.spacing8)
            }
        } header: {
            Text(L("program.session.volumeHeader"))
        } footer: {
            Text(L("program.session.volumeFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Actions

    private func actionsSection(_ template: WorkoutTemplate) -> some View {
        Section {
            Button {
                isConfirmingRegenerate = true
            } label: {
                Label(L("program.session.regenerate"), systemImage: "wand.and.stars")
                    .frame(minHeight: Metrics.minimumTapTarget)
            }
            .disabled(model.isWorking || template.isRestDay)

            Button {
                model.saveAsTemplate(template)
            } label: {
                Label(L("program.templates.save"), systemImage: "square.and.arrow.down")
                    .frame(minHeight: Metrics.minimumTapTarget)
            }

            Button {
                model.duplicateSession(template)
            } label: {
                Label(L("program.session.duplicate"), systemImage: "doc.on.doc")
                    .frame(minHeight: Metrics.minimumTapTarget)
            }
        } header: {
            Text(L("program.session.actionsHeader"))
        } footer: {
            Text(L("program.session.actionsFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { EditButton() }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isRenaming = true
            } label: {
                Image(systemName: "pencil")
            }
            .accessibilityLabel(L("program.editor.renameTitle"))
            .disabled(template == nil)
        }
    }
}

// MARK: - One exercise

/// A single slot: what it is, what it prescribes, and every control that changes it.
///
/// Collapsed it is a summary; expanded it is the full prescription. Keeping the numbers behind a
/// disclosure is what lets an eight-exercise session stay scannable while still putting sets, reps,
/// rest and RIR one tap away rather than one screen away.
struct PlannedExerciseRow: View {
    let planned: PlannedExercise
    let template: WorkoutTemplate
    let model: ProgramViewModel
    @Binding var isExpanded: Bool
    let onSwap: () -> Void
    let onRemove: () -> Void

    @Environment(AppEnvironment.self) private var environment

    private var exercise: Exercise? { model.exercise(planned.exerciseID) }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Metrics.spacing16) {
                if let rationale = substitutionNote {
                    ExplanationNote(text: rationale, systemImage: "arrow.triangle.2.circlepath")
                }
                prescriptionControls
                opinionControls
            }
            .padding(.top, Metrics.spacing12)
            .padding(.bottom, Metrics.spacing8)
        } label: {
            summary
        }
        .contextMenu {
            Button { onSwap() } label: {
                Label(L("program.session.swap"), systemImage: "arrow.triangle.2.circlepath")
            }
            if planned.substitutedFromExerciseID != nil {
                Button { model.restoreRecommendation(for: planned) } label: {
                    Label(L("program.session.restore"), systemImage: "arrow.uturn.backward")
                }
            }
            Button { model.setLocked(!planned.isLocked, on: planned) } label: {
                Label(
                    planned.isLocked ? L("program.session.unlock") : L("program.session.lock"),
                    systemImage: planned.isLocked ? "lock.open" : "lock"
                )
            }
            Button(role: .destructive) { onRemove() } label: {
                Label(L("common.remove"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { onRemove() } label: {
                Label(L("common.remove"), systemImage: "trash")
            }
            Button { onSwap() } label: {
                Label(L("program.session.swap"), systemImage: "arrow.triangle.2.circlepath")
            }
            .tint(Color.appRecovery)
        }
    }

    // MARK: Summary

    private var summary: some View {
        HStack(spacing: Metrics.spacing12) {
            ExerciseThumbnail(url: exercise.flatMap { environment.mediaProvider.thumbnailURL(for: $0) })
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Metrics.spacing4) {
                    Text(exercise?.name.localizedCapitalized ?? planned.exerciseID)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if planned.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.appAccent)
                    }
                    if model.isFavorite(planned.exerciseID) {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.appAccent)
                    }
                }
                Text(prescriptionLine)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Metrics.spacing4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var prescriptionLine: String {
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

    private var accessibilityLabel: String {
        var parts = [exercise?.name ?? planned.exerciseID, prescriptionLine]
        if planned.isLocked { parts.append(L("program.session.lockedState")) }
        if model.isFavorite(planned.exerciseID) { parts.append(L("exercise.favorite")) }
        return parts.joined(separator: ", ")
    }

    private var substitutionNote: String? {
        guard let originalID = planned.substitutedFromExerciseID else { return nil }
        let name = model.exercise(originalID)?.name.localizedCapitalized ?? originalID
        return L("program.session.substitutedFrom", name)
    }

    // MARK: Prescription

    @ViewBuilder
    private var prescriptionControls: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            Stepper(value: setsBinding, in: 1...10) {
                labelled(L("program.session.sets"), value: "\(planned.targetSets)")
            }
            .accessibilityLabel(L("program.session.sets"))
            .accessibilityValue("\(planned.targetSets)")

            if let seconds = planned.targetDurationSeconds {
                Stepper(value: durationBinding, in: 10...600, step: 5) {
                    labelled(L("program.session.duration"), value: Units.formatDuration(seconds: seconds))
                }
                .accessibilityLabel(L("program.session.duration"))
                .accessibilityValue(Units.formatDuration(seconds: seconds))
            } else {
                Stepper(value: repLowerBinding, in: 1...50) {
                    labelled(L("program.session.repsLower"), value: "\(planned.repLower)")
                }
                .accessibilityLabel(L("program.session.repsLower"))
                .accessibilityValue("\(planned.repLower)")

                Stepper(value: repUpperBinding, in: 1...50) {
                    labelled(L("program.session.repsUpper"), value: "\(planned.repUpper)")
                }
                .accessibilityLabel(L("program.session.repsUpper"))
                .accessibilityValue("\(planned.repUpper)")
            }

            Stepper(value: restBinding, in: 30...300, step: 15) {
                labelled(L("program.session.rest"), value: Units.formatDuration(seconds: planned.restSeconds))
            }
            .accessibilityLabel(L("program.session.rest"))
            .accessibilityValue(Units.formatDuration(seconds: planned.restSeconds))

            SegmentedValuePicker(
                title: L("program.session.targetRIR"),
                values: Array(0...5),
                label: { "\($0)" },
                selection: rirBinding
            )
            Text(L("program.session.rirNote"))
                .font(.caption2)
                .foregroundStyle(Color.appTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labelled(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.spacing8)
            Text(value)
                .font(.appNumeric(17))
                .foregroundStyle(Color.appTextSecondary)
        }
    }

    // MARK: Opinions

    private var opinionControls: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            Toggle(isOn: lockBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("program.session.lock"))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextPrimary)
                    Text(L("program.session.lockNote"))
                        .font(.caption2)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.appAccent)

            HStack(spacing: Metrics.spacing8) {
                ToggleChip(
                    title: L("exercise.favorite"),
                    systemImage: "heart",
                    isOn: favoriteBinding
                )
                ToggleChip(
                    title: L("program.session.exclude"),
                    systemImage: "hand.raised",
                    tint: .appDanger,
                    isOn: excludedBinding
                )
            }
            Text(L("program.session.excludeNote"))
                .font(.caption2)
                .foregroundStyle(Color.appTextTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Metrics.spacing8) {
                Button(L("program.session.swap"), action: onSwap)
                    .buttonStyle(SecondaryButtonStyle())
                if planned.substitutedFromExerciseID != nil {
                    Button(L("program.session.restore")) {
                        model.restoreRecommendation(for: planned)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }

            NavigationLink(value: ProgramRoute.exercise(planned.exerciseID)) {
                Label(L("program.session.viewExercise"), systemImage: "info.circle")
                    .font(.subheadline)
                    .frame(minHeight: Metrics.minimumTapTarget)
            }
        }
    }

    // MARK: Bindings

    private var setsBinding: Binding<Int> {
        Binding(
            get: { planned.targetSets },
            set: { model.updatePrescription(of: planned, sets: $0) }
        )
    }

    /// The two rep bounds are edited independently but stored as a range, so each setter carries the
    /// other bound with it and `RepRange` normalises any crossing.
    private var repLowerBinding: Binding<Int> {
        Binding(
            get: { planned.repLower },
            set: { model.updatePrescription(of: planned, repRange: RepRange($0, max($0, planned.repUpper))) }
        )
    }

    private var repUpperBinding: Binding<Int> {
        Binding(
            get: { planned.repUpper },
            set: { model.updatePrescription(of: planned, repRange: RepRange(min(planned.repLower, $0), $0)) }
        )
    }

    private var restBinding: Binding<Int> {
        Binding(
            get: { planned.restSeconds },
            set: { model.updatePrescription(of: planned, restSeconds: $0) }
        )
    }

    private var rirBinding: Binding<Int> {
        Binding(
            get: { planned.targetRIR },
            set: { model.updatePrescription(of: planned, targetRIR: $0) }
        )
    }

    private var durationBinding: Binding<Int> {
        Binding(
            get: { planned.targetDurationSeconds ?? 45 },
            set: { model.updatePrescription(of: planned, targetDurationSeconds: .some($0)) }
        )
    }

    private var lockBinding: Binding<Bool> {
        Binding(
            get: { planned.isLocked },
            set: { model.setLocked($0, on: planned) }
        )
    }

    private var favoriteBinding: Binding<Bool> {
        Binding(
            get: { model.isFavorite(planned.exerciseID) },
            set: { model.setFavorite($0, exerciseID: planned.exerciseID) }
        )
    }

    private var excludedBinding: Binding<Bool> {
        Binding(
            get: { model.isExcluded(planned.exerciseID) },
            set: { model.setExcluded($0, exerciseID: planned.exerciseID) }
        )
    }
}

/// Opened on the first training day of the seasoned-user fixture: a full session with history behind
/// it, which is the state where every control on this screen matters.
#Preview {
    PreviewHost(scenario: .seasonedUser) {
        SessionEditorPreview()
    }
}

private struct SessionEditorPreview: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @State private var model = ProgramViewModel()

    var body: some View {
        NavigationStack {
            if let template = model.program?.orderedTemplates.first(where: { !$0.isRestDay }) {
                SessionEditorView(templateID: template.id, model: model)
                    .navigationDestination(for: ProgramRoute.self) { _ in EmptyView() }
            } else {
                LoadingStateView(message: L("program.loading"))
            }
        }
        .task { await model.load(modelContext: modelContext, catalog: environment.catalog) }
    }
}
