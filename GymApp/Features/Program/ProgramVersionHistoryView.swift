import SwiftData
import SwiftUI

/// Every shape this program has had, newest first, and the reason it changed.
///
/// The list is append-only by construction: `ProgramRepository` writes a `ProgramVersion` on every
/// engine-driven change and never rewrites one, so there is nothing on this screen to edit and no
/// way to delete a row. That is the point rather than a limitation — a plan that quietly rewrote its
/// own past would be one the user could not audit — and the footer says so in as many words.
///
/// Each row's reason is stored as a key plus already-localised arguments, so an explanation written
/// months ago still resolves through `L` in whatever language the app is in today.
struct ProgramVersionHistoryView: View {
    let model: ProgramViewModel

    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.displayFormatter) private var formatter

    @State private var inspecting: ProgramVersion?

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L("program.versions.title"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $inspecting) { version in
                ProgramVersionDetailView(version: version, model: model)
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
            if model.versions.isEmpty {
                EmptyStateView(
                    systemImage: "clock.arrow.circlepath",
                    title: L("program.versions.emptyTitle"),
                    message: L("program.versions.emptyMessage")
                )
                .frame(maxHeight: .infinity)
            } else {
                versionList
            }
        }
    }

    private var versionList: some View {
        List {
            Section {
                ForEach(model.versions) { version in
                    Button {
                        inspecting = version
                    } label: {
                        row(version)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.appSurface)
                }
            } header: {
                Text(L("program.versions.header"))
            } footer: {
                Text(L("program.versions.immutable"))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .environment(\.defaultMinListRowHeight, Metrics.minimumTapTarget)
    }

    private func row(_ version: ProgramVersion) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacing8) {
            VStack(alignment: .leading, spacing: Metrics.spacing6) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                    Text(L("program.versions.versionNumber", version.versionNumber))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if isNewest(version) {
                        Text(L("program.versions.current"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.appSuccess)
                            .padding(.horizontal, Metrics.spacing6)
                            .padding(.vertical, 2)
                            .background(Color.appSuccess.opacity(0.14), in: Capsule())
                    }

                    Spacer(minLength: Metrics.spacing8)

                    Text(formatter.mediumDate(version.createdAt))
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                }

                Text(reason(for: version))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextTertiary)
                .padding(.top, 3)
        }
        .padding(.vertical, Metrics.spacing6)
        .frame(minHeight: Metrics.minimumTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("program.versions.openHint"))
    }

    /// The newest row, rather than "whatever matches `currentVersion`": a version number can
    /// legitimately carry two rows, and only one of them is the plan in force.
    private func isNewest(_ version: ProgramVersion) -> Bool {
        model.versions.first?.id == version.id
    }

    private func reason(for version: ProgramVersion) -> String {
        guard !version.reasonKey.isEmpty else { return L("program.versions.reasonMissing") }
        return Explanation(version.reasonKey, version.reasonArguments).text
    }
}

// MARK: - One version, read-only

/// What a single stored version contained, decoded from its JSON snapshot.
///
/// Presented as a sheet rather than a push because the program area's route enum has no case for a
/// version, and inventing one would put a screen nothing else links to into shared routing. Nothing
/// here is editable, and there is deliberately no "restore": bringing an old plan back would need a
/// new version of its own, and pretending otherwise is what would make the history a lie.
struct ProgramVersionDetailView: View {
    let version: ProgramVersion
    let model: ProgramViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayFormatter) private var formatter

    @State private var outcome: ProgramViewModel.SnapshotOutcome?

    var body: some View {
        NavigationStack {
            content
                .background(Color.appBackground)
                .navigationTitle(L("program.versions.versionNumber", version.versionNumber))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("common.close")) { dismiss() }
                    }
                }
                .task { load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let outcome {
            switch outcome {
            case .failure(let message):
                ErrorStateView(message: message, retryTitle: L("common.retry"), retry: load)
            case .snapshot(let snapshot):
                snapshotBody(snapshot)
            }
        } else {
            LoadingStateView(message: L("program.loading"))
        }
    }

    private func load() {
        outcome = model.snapshot(of: version)
    }

    // MARK: Snapshot

    private func snapshotBody(_ snapshot: ProgramSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing16) {
                headerCard(snapshot)

                let templates = snapshot.templates.sorted { $0.orderIndex < $1.orderIndex }
                if templates.isEmpty {
                    Card {
                        EmptyStateView(
                            systemImage: "square.stack.3d.up.slash",
                            title: L("program.versions.snapshotEmptyTitle"),
                            message: L("program.versions.snapshotEmptyMessage")
                        )
                    }
                } else {
                    ForEach(Array(templates.enumerated()), id: \.offset) { _, template in
                        Card { templateCard(template) }
                    }
                }

                ExplanationNote(text: L("program.versions.readOnly"), systemImage: "lock")
            }
            .padding(.vertical, Metrics.spacing20)
            .screenPadding()
            .readableWidth()
        }
    }

    private func headerCard(_ snapshot: ProgramSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                VStack(alignment: .leading, spacing: Metrics.spacing4) {
                    Text(snapshot.title)
                        .font(.appSectionTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L(snapshot.splitKey))
                        .font(.subheadline)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("program.versions.recordedAt",
                           formatter.mediumDate(version.createdAt),
                           formatter.time(version.createdAt)))
                        .font(.caption)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Metrics.spacing20) {
                    StatTile(
                        value: "\(snapshot.daysPerWeek)",
                        label: L("program.stat.daysPerWeek"),
                        systemImage: "calendar"
                    )
                    StatTile(
                        value: "\(trainingSessionCount(snapshot))",
                        label: L("program.stat.sessions"),
                        systemImage: "figure.strengthtraining.traditional"
                    )
                    StatTile(
                        value: "\(exerciseCount(snapshot))",
                        label: L("program.versions.exercises"),
                        systemImage: "dumbbell"
                    )
                }

                Text(L("program.versions.block", snapshot.mesocycleLengthWeeks))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ExplanationNote(text: reasonText, systemImage: "text.quote")
            }
        }
    }

    private var reasonText: String {
        guard !version.reasonKey.isEmpty else { return L("program.versions.reasonMissing") }
        return Explanation(version.reasonKey, version.reasonArguments).text
    }

    private func trainingSessionCount(_ snapshot: ProgramSnapshot) -> Int {
        snapshot.templates.filter { !$0.isRestDay }.count
    }

    private func exerciseCount(_ snapshot: ProgramSnapshot) -> Int {
        snapshot.templates.reduce(0) { $0 + $1.exercises.count }
    }

    // MARK: One session inside the snapshot

    private func templateCard(_ template: ProgramSnapshot.Template) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
                Text(title(of: template))
                    .font(.appCardTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Metrics.spacing8)
                if let weekday = template.weekdayRawValue.flatMap(Weekday.init(rawValue:)) {
                    Text(L(weekday.localizationKey))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.appTextSecondary)
                }
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

                Text(L("program.versions.sessionSummary",
                       template.exercises.count,
                       template.exercises.reduce(0) { $0 + $1.targetSets }))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if template.exercises.isEmpty {
                    Text(L("program.versions.templateEmpty"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: Metrics.spacing8) {
                        ForEach(template.exercises.sorted { $0.orderIndex < $1.orderIndex },
                                id: \.orderIndex) { exercise in
                            exerciseRow(exercise)
                        }
                    }
                    .padding(.top, Metrics.spacing4)
                }
            }
        }
    }

    private func title(of template: ProgramSnapshot.Template) -> String {
        if let custom = template.customTitle, !custom.isEmpty { return custom }
        return L(template.titleKey)
    }

    private func exerciseRow(_ exercise: ProgramSnapshot.Exercise) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Metrics.spacing4) {
                Text(name(of: exercise))
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if exercise.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.appAccent)
                        .accessibilityHidden(true)
                }
            }
            Text(prescription(of: exercise))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let originalID = exercise.substitutedFromExerciseID {
                Text(L("program.session.substitutedFrom", name(forExerciseID: originalID)))
                    .font(.caption2)
                    .foregroundStyle(Color.appTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: exercise))
    }

    private func name(of exercise: ProgramSnapshot.Exercise) -> String {
        name(forExerciseID: exercise.exerciseID)
    }

    /// Falls back to the stored identifier when a movement has since left the catalogue: an old
    /// version has to stay readable even after the dataset moves on.
    private func name(forExerciseID id: String) -> String {
        model.exercise(id)?.name.localizedCapitalized ?? id
    }

    private func prescription(of exercise: ProgramSnapshot.Exercise) -> String {
        var parts: [String] = []
        if let seconds = exercise.targetDurationSeconds {
            parts.append(L("program.session.setsForTime", exercise.targetSets, seconds))
        } else {
            parts.append(L("program.session.setsByReps",
                           exercise.targetSets,
                           RepRange(exercise.repLower, exercise.repUpper).description))
        }
        parts.append(Units.formatDuration(seconds: exercise.restSeconds))
        parts.append(L("program.session.rirShort", exercise.targetRIR))
        return parts.joined(separator: " · ")
    }

    private func accessibilityLabel(for exercise: ProgramSnapshot.Exercise) -> String {
        var parts = [name(of: exercise), prescription(of: exercise)]
        if exercise.isLocked { parts.append(L("program.session.lockedState")) }
        return parts.joined(separator: ", ")
    }
}

/// The seasoned-user fixture has several versions behind it, which is the only state where the
/// ordering, the "current" marker and the stored snapshots can all be judged.
#Preview {
    PreviewHost(scenario: .seasonedUser) {
        ProgramVersionHistoryPreview()
    }
}

private struct ProgramVersionHistoryPreview: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @State private var model = ProgramViewModel()

    var body: some View {
        NavigationStack {
            ProgramVersionHistoryView(model: model)
        }
        .task { await model.load(modelContext: modelContext, catalog: environment.catalog) }
    }
}
