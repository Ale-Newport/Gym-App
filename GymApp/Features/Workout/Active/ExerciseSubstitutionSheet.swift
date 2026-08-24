import SwiftData
import SwiftUI

// MARK: - View model

/// Runs `ExerciseSubstitutionEngine` for one slot and holds the answer.
///
/// The engine indexes the whole catalogue on construction, so it is built once here and re-queried
/// as the user changes their reason. Everything the engine needs — the profile, the equipment, the
/// user's opinions and their recent history — is read once when the sheet opens, because none of it
/// can change while the sheet is on screen.
@MainActor
@Observable
final class ExerciseSubstitutionViewModel {

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var original: Exercise?
    private(set) var candidates: [SubstitutionCandidate] = []
    private(set) var reason: SubstitutionReason?

    /// The one candidate whose animation is decoded. Rows show thumbnails only: a list that loads a
    /// dozen animations would stutter on the screen where hesitation is least affordable.
    var previewedID: String?

    @ObservationIgnored private var engine: ExerciseSubstitutionEngine?
    @ObservationIgnored private var profile = TrainingProfileSnapshot()
    @ObservationIgnored private var preferences: [String: ExercisePreferenceSnapshot] = [:]
    @ObservationIgnored private var histories: [String: ExerciseHistorySnapshot] = [:]
    @ObservationIgnored private var sessionExerciseIDs: Set<String> = []
    @ObservationIgnored private var ownedEquipment: Set<Equipment> = []
    @ObservationIgnored private var context: ModelContext?

    /// How many alternatives the sheet offers. Beyond a dozen the list stops being a decision and
    /// becomes a search, which is what the exercise picker is for.
    private static let limit = 12

    func load(
        exerciseID: String,
        sessionExerciseIDs: Set<String>,
        context: ModelContext,
        catalog: ExerciseCatalog
    ) {
        self.context = context
        self.sessionExerciseIDs = sessionExerciseIDs

        guard let found = catalog.exercise(id: exerciseID) else {
            phase = .failed(L("active.substitute.error.missing"))
            return
        }
        original = found

        do {
            let profileRepository = ProfileRepository(context: context)
            profile = try profileRepository.trainingProfileSnapshot()
            ownedEquipment = Set(try profileRepository.equipmentProfile().availableEquipment)

            let preferenceRepository = ExercisePreferenceRepository(context: context)
            preferences = try preferenceRepository.snapshots()

            // The engine only reasons about movements the user actually trains, so the history query
            // is scoped to what they have performed recently rather than to the whole catalogue.
            let recentIDs = try preferenceRepository.recentlyPerformedIDs(limit: 40)
            histories = try WorkoutRepository(context: context)
                .histories(forExerciseIDs: recentIDs, sessionLimit: 4)

            engine = ExerciseSubstitutionEngine(catalog: catalog.exercises)
            refresh()
            phase = .ready
        } catch {
            AppLog.persistence.error(
                "Substitution sheet failed to load: \(String(describing: error), privacy: .public)"
            )
            phase = .failed(L("active.substitute.error.load"))
        }
    }

    /// Applies a reason, or clears it when the same chip is tapped again.
    func select(_ newReason: SubstitutionReason?) {
        reason = newReason
        previewedID = nil
        refresh()
    }

    private func refresh() {
        guard let engine, let original else { return }
        candidates = engine.alternatives(for: SubstitutionRequest(
            original: original,
            reason: reason,
            availableEquipment: profile.availableEquipment,
            profile: profile,
            preferences: preferences,
            histories: histories,
            exercisesInSession: sessionExerciseIDs,
            limit: Self.limit
        ))
    }

    /// The implement worth offering to remove from the user's gym, or `nil` when there is nothing
    /// sensible to remove — body weight cannot go missing, and neither can kit they never listed.
    var removableEquipment: Equipment? {
        guard let original,
              original.equipment != .bodyWeight,
              original.equipment != .other,
              ownedEquipment.contains(original.equipment) else { return nil }
        return original.equipment
    }

    /// Drops a piece of equipment from the user's gym for good. Returns `false` when the write
    /// failed, so the caller can say so rather than quietly leaving the gym unchanged.
    func removeEquipmentFromGym(_ equipment: Equipment) -> Bool {
        guard let context else { return false }
        var remaining = ownedEquipment
        remaining.remove(equipment)
        do {
            try ProfileRepository(context: context).updateEquipment(availableEquipment: remaining)
            ownedEquipment = remaining
            return true
        } catch {
            AppLog.persistence.error(
                "Equipment removal failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }
}

// MARK: - Sheet

/// Swap one exercise for another, with the reason driving what is offered.
///
/// The reason is the whole point of this sheet. "The machine is taken" and "make it easier" are
/// different questions with different right answers, and the engine both filters and re-ranks on the
/// answer — so the chips come first, and every alternative states, in words, why it is being
/// suggested. Choosing is two taps: open a preview to watch the movement, then use it.
struct ExerciseSubstitutionSheet: View {
    let exerciseID: String
    let sessionExerciseIDs: Set<String>
    let onSelect: (Exercise, SubstitutionReason?) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = ExerciseSubstitutionViewModel()
    @State private var equipmentQuestion: EquipmentQuestion?
    @State private var equipmentFailure: EquipmentQuestion?

    init(
        exerciseID: String,
        sessionExerciseIDs: Set<String>,
        onSelect: @escaping (Exercise, SubstitutionReason?) -> Void
    ) {
        self.exerciseID = exerciseID
        self.sessionExerciseIDs = sessionExerciseIDs
        self.onSelect = onSelect
    }

    /// A swap waiting on the "is it gone for good?" question.
    private struct EquipmentQuestion: Identifiable {
        let id = UUID()
        let exercise: Exercise
        let equipment: Equipment
    }

    var body: some View {
        NavigationStack {
            content
                .background(Color.appBackground)
                .navigationTitle(L("active.substitute.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("common.cancel")) { dismiss() }
                    }
                }
        }
        .presentationDragIndicator(.visible)
        .task {
            await environment.catalog.load()
            model.load(
                exerciseID: exerciseID,
                sessionExerciseIDs: sessionExerciseIDs,
                context: modelContext,
                catalog: environment.catalog
            )
        }
        .confirmationDialog(
            L("active.substitute.equipmentTitle"),
            isPresented: Binding(
                get: { equipmentQuestion != nil },
                set: { if !$0 { equipmentQuestion = nil } }
            ),
            titleVisibility: .visible,
            presenting: equipmentQuestion
        ) { question in
            // "Just for today" is first and is the answer that changes nothing outside this session.
            Button(L("active.substitute.justToday")) { commit(question.exercise) }
            Button(L("active.substitute.removeFromGym"), role: .destructive) {
                removeAndCommit(question)
            }
            Button(L("common.cancel"), role: .cancel) { equipmentQuestion = nil }
        } message: { question in
            Text(L("active.substitute.equipmentMessage", L(question.equipment.localizationKey)))
        }
        .alert(
            L("active.substitute.equipmentFailedTitle"),
            isPresented: Binding(
                get: { equipmentFailure != nil },
                set: { if !$0 { equipmentFailure = nil } }
            ),
            presenting: equipmentFailure
        ) { question in
            Button(L("common.retry")) { removeAndCommit(question) }
            Button(L("active.substitute.swapAnyway")) {
                equipmentFailure = nil
                commit(question.exercise)
            }
        } message: { _ in
            Text(L("active.substitute.equipmentFailedMessage"))
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingStateView(message: L("active.substitute.loading"))
        case .failed(let message):
            ScrollView {
                ErrorStateView(message: message, retryTitle: L("common.retry")) {
                    model.load(
                        exerciseID: exerciseID,
                        sessionExerciseIDs: sessionExerciseIDs,
                        context: modelContext,
                        catalog: environment.catalog
                    )
                }
                .readableWidth()
            }
        case .ready:
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing20) {
                    originalHeader
                    reasonSection
                    alternativesSection
                }
                .padding(.vertical, Metrics.spacing16)
                .screenPadding()
                .readableWidth()
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var originalHeader: some View {
        if let original = model.original {
            VStack(alignment: .leading, spacing: Metrics.spacing6) {
                Text(L("active.substitute.replacing"))
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
                ExerciseRowView(
                    exercise: original,
                    thumbnailURL: environment.mediaProvider.thumbnailURL(for: original)
                )
            }
            .padding(Metrics.spacing12)
            .background(Color.appFill, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        }
    }

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            SectionHeader(
                L("active.substitute.reasonTitle"),
                subtitle: L("active.substitute.reasonSubtitle")
            )
            FlowLayout {
                ForEach(SubstitutionReason.allCases) { candidateReason in
                    Button {
                        model.select(candidateReason == model.reason ? nil : candidateReason)
                        Haptics.selectionChanged()
                    } label: {
                        Chip(
                            title: L(candidateReason.localizationKey),
                            systemImage: candidateReason.symbolName,
                            isSelected: candidateReason == model.reason
                        )
                        .minimumTapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        candidateReason == model.reason ? [.isButton, .isSelected] : .isButton
                    )
                }
            }
        }
    }

    private var alternativesSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            SectionHeader(
                L("active.substitute.alternatives"),
                subtitle: model.candidates.isEmpty
                    ? nil
                    : LPlural("active.substitute.count", model.candidates.count)
            )

            if model.candidates.isEmpty {
                EmptyStateView(
                    systemImage: "magnifyingglass",
                    title: L("active.substitute.emptyTitle"),
                    message: L("active.substitute.emptyMessage")
                ) {
                    if model.reason != nil {
                        Button(L("active.substitute.clearReason")) { model.select(nil) }
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(maxWidth: 260)
                    }
                }
            } else {
                LazyVStack(spacing: Metrics.spacing8) {
                    ForEach(model.candidates) { candidate in
                        candidateCard(candidate)
                    }
                }
            }
        }
    }

    private func candidateCard(_ candidate: SubstitutionCandidate) -> some View {
        let isPreviewing = model.previewedID == candidate.id

        return VStack(alignment: .leading, spacing: Metrics.spacing12) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    model.previewedID = isPreviewing ? nil : candidate.id
                }
                Haptics.tap()
            } label: {
                candidateSummary(candidate, isPreviewing: isPreviewing)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(accessibilityLabel(for: candidate)))
            .accessibilityValue(Text(isPreviewing ? L("common.showLess") : L("common.showMore")))

            if isPreviewing {
                ExerciseMediaHero(
                    exercise: candidate.exercise,
                    animationURL: environment.mediaProvider.animationURL(for: candidate.exercise),
                    thumbnailURL: environment.mediaProvider.thumbnailURL(for: candidate.exercise),
                    attribution: environment.mediaProvider.attribution,
                    attributionURL: environment.mediaProvider.attributionURL,
                    isPlaying: !reduceMotion
                )
                .frame(maxWidth: 240)
                .frame(maxWidth: .infinity)

                Button(L("active.substitute.use")) { choose(candidate.exercise) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(Metrics.spacing12)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cornerMedium, style: .continuous)
                .strokeBorder(
                    isPreviewing ? Color.appAccent.opacity(0.55) : Color.appSeparator.opacity(0.6),
                    lineWidth: isPreviewing ? 1.5 : 0.5
                )
        )
    }

    private func candidateSummary(_ candidate: SubstitutionCandidate, isPreviewing: Bool) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacing12) {
            ExerciseThumbnail(url: environment.mediaProvider.thumbnailURL(for: candidate.exercise))
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                Text(candidate.exercise.name.localizedCapitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.appTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(metadataLine(for: candidate.exercise))
                    .font(.caption)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(candidate.reasons, id: \.self) { reason in
                    HStack(alignment: .top, spacing: Metrics.spacing4) {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.appSuccess)
                            .padding(.top, 2)
                        Text(reason.text)
                            .font(.caption)
                            .foregroundStyle(Color.appTextTertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: isPreviewing ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.appTextTertiary)
                .padding(.top, Metrics.spacing4)
        }
        .frame(minHeight: Metrics.minimumTapTarget)
        .contentShape(Rectangle())
    }

    private func metadataLine(for exercise: Exercise) -> String {
        [L(exercise.target.localizationKey), L(exercise.equipment.localizationKey)]
            .joined(separator: " · ")
    }

    private func accessibilityLabel(for candidate: SubstitutionCandidate) -> String {
        var parts = [candidate.exercise.name, metadataLine(for: candidate.exercise)]
        parts.append(contentsOf: candidate.reasons.map(\.text))
        return parts.joined(separator: ", ")
    }

    // MARK: - Choosing

    private func choose(_ exercise: Exercise) {
        // "The machine is not available" is the one reason that might mean the gym has changed rather
        // than that today is awkward, so it is the only one worth interrupting for.
        if model.reason == .machineUnavailable, let equipment = model.removableEquipment {
            equipmentQuestion = EquipmentQuestion(exercise: exercise, equipment: equipment)
            return
        }
        commit(exercise)
    }

    private func removeAndCommit(_ question: EquipmentQuestion) {
        equipmentFailure = nil
        if model.removeEquipmentFromGym(question.equipment) {
            commit(question.exercise)
        } else {
            equipmentFailure = question
        }
    }

    private func commit(_ exercise: Exercise) {
        equipmentQuestion = nil
        onSelect(exercise, model.reason)
        Haptics.success()
        dismiss()
    }
}

#Preview("Substitution") {
    PreviewHost(scenario: .activeWorkout) {
        SubstitutionPreviewHarness()
    }
}

/// Swaps the first exercise of the sample program, so the preview always has a real slot to work on.
private struct SubstitutionPreviewHarness: View {
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var sessions: [WorkoutSession]

    var body: some View {
        if let record = sessions.first(where: { $0.status == .inProgress })?.orderedExercises.first {
            ExerciseSubstitutionSheet(
                exerciseID: record.exerciseID,
                sessionExerciseIDs: [record.exerciseID]
            ) { _, _ in }
        } else {
            EmptyStateView(
                systemImage: "arrow.triangle.2.circlepath",
                title: L("active.substitute.emptyTitle"),
                message: L("active.substitute.emptyMessage")
            )
        }
    }
}
