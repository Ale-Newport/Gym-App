import SwiftData
import SwiftUI

/// The inputs the training engines read, put next to the plan they shape.
///
/// Everything here writes straight through to the store, the way the rest of the app's settings do.
/// What this screen adds is the *consequence*: some of these values are what the programming engine
/// was given when it built the week, so changing them leaves the plan on screen describing a person
/// the settings no longer describe. Rather than silently rewriting the user's program — which would
/// throw away hand edits nobody asked to lose — the mismatch is stated plainly and a rebuild is
/// offered, with the kept-and-changed list spelled out before anything happens.
struct ProgramSettingsView: View {
    let model: ProgramViewModel

    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment

    @State private var settings = ProgramSettingsViewModel()
    @State private var isConfirmingRebuild = false

    var body: some View {
        content
            .background(Color.appBackground)
            .navigationTitle(L("program.settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                L("program.settings.rebuildTitle"),
                isPresented: $isConfirmingRebuild,
                titleVisibility: .visible
            ) {
                Button(L("program.settings.rebuildAction")) {
                    Task { await settings.rebuild() }
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("program.settings.rebuildMessage"))
            }
            .programFeedback(model)
            .task(id: model.phase) { settings.attach(model, modelContext: modelContext) }
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
            settingsList
        }
    }

    private var settingsList: some View {
        List {
            scheduleSection
            prioritiesSection
            progressionSection
            effortSection
            restSection
            planSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .environment(\.defaultMinListRowHeight, Metrics.minimumTapTarget)
        .tint(Color.appAccent)
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        Section {
            SegmentedValuePicker(
                title: L("program.settings.daysPerWeek"),
                values: Array(InputValidation.daysPerWeek),
                label: { String($0) },
                selection: Binding(
                    get: { settings.daysPerWeek },
                    set: { settings.setDaysPerWeek($0) }
                )
            )
            .padding(.vertical, Metrics.spacing4)

            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text(L("program.settings.weekdays"))
                    .font(.appOverline)
                    .foregroundStyle(Color.appTextSecondary)
                FlowLayout(spacing: Metrics.spacing6, lineSpacing: Metrics.spacing6) {
                    ForEach(Weekday.orderedMondayFirst) { day in
                        ToggleChip(
                            title: L(day.shortLocalizationKey),
                            isOn: Binding(
                                get: { settings.weekdays.contains(day) },
                                set: { _ in settings.toggleWeekday(day) }
                            )
                        )
                    }
                }
            }
            .padding(.vertical, Metrics.spacing4)

            if settings.weekdays.isEmpty {
                footnote(L("program.settings.noDays"), tint: .appWarning)
            }

            Picker(selection: Binding(
                get: { settings.sessionMinutes },
                set: { settings.setSessionMinutes($0) }
            )) {
                ForEach(settings.sessionMinuteOptions, id: \.self) { minutes in
                    Text(Units.formatDurationCompact(seconds: minutes * 60)).tag(minutes)
                }
            } label: {
                Text(L("program.settings.sessionLength"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .pickerStyle(.menu)
            .frame(minHeight: Metrics.minimumTapTarget)
        } header: {
            Text(L("program.settings.section.schedule"))
        } footer: {
            Text(L("program.settings.scheduleFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Priorities

    private var prioritiesSection: some View {
        Section {
            FlowLayout(spacing: Metrics.spacing6, lineSpacing: Metrics.spacing6) {
                ForEach(MuscleGroup.selectablePriorities) { group in
                    ToggleChip(
                        title: L(group.localizationKey),
                        systemImage: group.symbolName,
                        isOn: Binding(
                            get: { settings.priorityGroups.contains(group) },
                            set: { _ in settings.togglePriority(group) }
                        )
                    )
                }
            }
            .padding(.vertical, Metrics.spacing4)

            if settings.priorityGroups.isEmpty {
                footnote(L("program.settings.prioritiesNone"))
            } else if settings.priorityGroups.count > 3 {
                footnote(L("program.settings.prioritiesMany"), tint: .appWarning)
            }
        } header: {
            Text(L("program.settings.section.priorities"))
        } footer: {
            Text(L("program.settings.prioritiesFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Progression

    private var progressionSection: some View {
        Section {
            Picker(selection: Binding(
                get: { settings.progressionStrategy },
                set: { settings.setProgressionStrategy($0) }
            )) {
                ForEach(ProgressionStrategy.allCases) { strategy in
                    Text(L(strategy.localizationKey)).tag(strategy)
                }
            } label: {
                Text(L("program.settings.progression"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .pickerStyle(.menu)
            .frame(minHeight: Metrics.minimumTapTarget)

            footnote(L(settings.progressionStrategy.detailLocalizationKey))

            Toggle(isOn: Binding(
                get: { settings.autoProgressionEnabled },
                set: { settings.setAutoProgression($0) }
            )) {
                labelWithDetail(
                    L("program.settings.autoProgression"),
                    L("program.settings.autoProgression.detail")
                )
            }

            Toggle(isOn: Binding(
                get: { settings.deloadSuggestionsEnabled },
                set: { settings.setDeloadSuggestions($0) }
            )) {
                labelWithDetail(
                    L("program.settings.deload"),
                    L("program.settings.deload.detail")
                )
            }

            Stepper(value: Binding(
                get: { settings.mesocycleWeeks },
                set: { settings.setMesocycleWeeks($0) }
            ), in: InputValidation.mesocycleWeeks) {
                valueRow(
                    L("program.settings.blockLength"),
                    value: LPlural("program.settings.blockValue", settings.mesocycleWeeks)
                )
            }
            .accessibilityLabel(L("program.settings.blockLength"))
            .accessibilityValue(LPlural("program.settings.blockValue", settings.mesocycleWeeks))

            footnote(L("program.settings.blockLength.detail"))
        } header: {
            Text(L("program.settings.section.progression"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Effort

    private var effortSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { settings.targetRIROverride != nil },
                set: { settings.setRIROverrideEnabled($0) }
            )) {
                labelWithDetail(
                    L("program.settings.rirOverride"),
                    L("program.settings.rirOverride.detail")
                )
            }

            if settings.targetRIROverride != nil {
                SegmentedValuePicker(
                    title: L("program.settings.targetRIR"),
                    values: Array(0...5),
                    label: { String($0) },
                    selection: Binding(
                        get: { settings.effectiveRIR },
                        set: { settings.setTargetRIR($0) }
                    )
                )
                .padding(.vertical, Metrics.spacing4)
            }

            footnote(L("program.settings.effectiveRIR", settings.effectiveRIR))
        } header: {
            Text(L("program.settings.section.effort"))
        } footer: {
            Text(L("program.settings.effortFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Rest

    private var restSection: some View {
        Section {
            restPicker(L("program.settings.restDefault"), seconds: settings.defaultRestSeconds) {
                settings.setDefaultRest($0)
            }
            restPicker(L("program.settings.restCompound"), seconds: settings.compoundRestSeconds) {
                settings.setCompoundRest($0)
            }
            restPicker(L("program.settings.restIsolation"), seconds: settings.isolationRestSeconds) {
                settings.setIsolationRest($0)
            }

            Button {
                settings.applyRestTimesToProgram()
            } label: {
                Label(L("program.settings.applyRest"), systemImage: "timer")
                    .frame(minHeight: Metrics.minimumTapTarget)
            }
            .disabled(model.program == nil)
        } header: {
            Text(L("program.settings.section.rest"))
        } footer: {
            Text(L("program.settings.restFooter"))
        }
        .listRowBackground(Color.appSurface)
    }

    private func restPicker(
        _ title: String,
        seconds: Int,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        Picker(selection: Binding(get: { seconds }, set: onChange)) {
            ForEach(ProgramSettingsViewModel.restOptions(including: seconds), id: \.self) { value in
                Text(Units.formatDuration(seconds: value)).tag(value)
            }
        } label: {
            Text(title).fixedSize(horizontal: false, vertical: true)
        }
        .pickerStyle(.menu)
        .frame(minHeight: Metrics.minimumTapTarget)
    }

    // MARK: - The plan itself

    private var planSection: some View {
        Section {
            if model.program == nil {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    Text(L("program.settings.noProgramNote"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("program.empty.generate")) {
                        Task { await settings.rebuild() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isWorking || model.context == nil)
                }
                .padding(.vertical, Metrics.spacing8)
            } else if settings.needsRebuild {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    Text(L("program.settings.rebuildPrompt"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(settings.planDifferences, id: \.self) { difference in
                        outcomeRow(difference, systemImage: "arrow.triangle.branch", tint: .appWarning)
                    }

                    Divider().overlay(Color.appSeparator)

                    outcomeRow(L("program.settings.keepsLocked"), systemImage: "lock.fill", tint: .appAccent)
                    outcomeRow(L("program.settings.keepsHistory"), systemImage: "clock.arrow.circlepath", tint: .appAccent)
                    outcomeRow(L("program.settings.changesPlan"), systemImage: "wand.and.stars", tint: .appRecovery)

                    Button(L("program.settings.rebuildAction")) {
                        isConfirmingRebuild = true
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isWorking)
                }
                .padding(.vertical, Metrics.spacing8)
            } else {
                outcomeRow(L("program.settings.inSync"), systemImage: "checkmark.circle", tint: .appSuccess)
                    .padding(.vertical, Metrics.spacing8)
            }
        } header: {
            Text(L("program.settings.section.plan"))
        }
        .listRowBackground(Color.appSurface)
    }

    // MARK: - Small pieces

    private func labelWithDetail(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Metrics.spacing2)
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.spacing8)
            Text(value)
                .font(.appNumeric(17))
                .foregroundStyle(Color.appTextSecondary)
        }
    }

    private func footnote(_ text: String, tint: Color = .appTextTertiary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Metrics.spacing2)
    }

    /// One line of "here is what happens". Always carries a symbol as well as a tint, so the
    /// difference between a warning and a reassurance never rests on colour alone.
    private func outcomeRow(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Metrics.spacing8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - View model

/// Holds the settings this screen edits, writes each change through immediately, and works out
/// whether the stored program still matches them.
///
/// Two stores are involved and they are not interchangeable. Availability, priorities and
/// progression live on the user's profile and settings rows and are written through
/// `ProgramViewModel.updateTrainingSettings`, which reloads the engine context so the recommended
/// split and the volume targets on the previous screen move with them. Rest lengths and the RIR
/// override are plain user settings and go to `ProfileRepository` directly. Block length exists only
/// on the program itself, so it is held here until a rebuild carries it into the plan.
@MainActor
@Observable
final class ProgramSettingsViewModel {

    private(set) var weekdays: [Weekday] = []
    private(set) var sessionMinutes: Int = 60
    private(set) var priorityGroups: [MuscleGroup] = []
    private(set) var mesocycleWeeks: Int = 5

    private(set) var progressionStrategy: ProgressionStrategy = .doubleProgression
    private(set) var autoProgressionEnabled = true
    private(set) var deloadSuggestionsEnabled = true

    private(set) var targetRIROverride: Int?
    private(set) var experienceRIR = 2

    private(set) var defaultRestSeconds = 120
    private(set) var compoundRestSeconds = 180
    private(set) var isolationRestSeconds = 75

    private(set) var isLoaded = false

    /// True once the user has changed something the engine would build differently. Kept separately
    /// from `planDifferences` because a shorter session cap leaves no trace on the stored program —
    /// nothing on the program row records the time budget it was built against.
    private(set) var hasStructuralEdit = false

    private var program: ProgramViewModel?
    private var modelContext: ModelContext?

    // MARK: Loading

    /// Seeds the draft from the store. Safe to call on every phase change: it only reads once the
    /// program view model has finished loading, and never overwrites values the user has just set.
    func attach(_ program: ProgramViewModel, modelContext: ModelContext) {
        self.program = program
        self.modelContext = modelContext
        guard !isLoaded, let context = program.context else { return }
        seed(profile: context.profile, settings: program.currentSettings())
        mesocycleWeeks = program.program?.mesocycleLengthWeeks
            ?? InputValidation.clampedMesocycleWeeks(5)
        isLoaded = true
    }

    private func seed(profile: TrainingProfileSnapshot, settings: UserSettings?) {
        weekdays = profile.availableWeekdays.sorted()
        sessionMinutes = profile.sessionMinutesCap
        priorityGroups = profile.priorityGroups
        experienceRIR = profile.defaultTargetRIR
        progressionStrategy = settings?.progressionStrategy ?? .doubleProgression
        autoProgressionEnabled = settings?.autoProgressionEnabled ?? true
        deloadSuggestionsEnabled = settings?.deloadSuggestionsEnabled ?? true
        targetRIROverride = settings?.targetRIROverride
        defaultRestSeconds = settings?.defaultRestSeconds ?? 120
        compoundRestSeconds = settings?.defaultCompoundRestSeconds ?? 180
        isolationRestSeconds = settings?.defaultIsolationRestSeconds ?? 75
    }

    // MARK: Schedule

    var daysPerWeek: Int {
        weekdays.isEmpty
            ? (program?.context?.profile.daysPerWeek ?? 3)
            : weekdays.count
    }

    /// Changing the count re-seeds an evenly spread week through the same helper the split selector
    /// uses, then the individual chips refine it. Both controls read back from one list, so they can
    /// never disagree with each other.
    func setDaysPerWeek(_ count: Int) {
        guard var profile = program?.context?.profile else { return }
        profile.availableWeekdays = weekdays
        apply(weekdays: SplitSelector.trainingWeekdays(profile: profile, count: count))
    }

    func toggleWeekday(_ day: Weekday) {
        var updated = weekdays
        if let index = updated.firstIndex(of: day) {
            updated.remove(at: index)
        } else {
            updated.append(day)
        }
        apply(weekdays: updated)
    }

    func setSessionMinutes(_ minutes: Int) {
        sessionMinutes = InputValidation.clampedSessionMinutes(minutes)
        hasStructuralEdit = true
        writeTrainingSettings()
    }

    var sessionMinuteOptions: [Int] {
        Self.merged([20, 30, 45, 60, 75, 90, 120, 150], with: sessionMinutes)
    }

    private func apply(weekdays updated: [Weekday]) {
        weekdays = Array(Set(updated)).sorted()
        hasStructuralEdit = true
        writeTrainingSettings()
    }

    // MARK: Priorities

    func togglePriority(_ group: MuscleGroup) {
        var updated = priorityGroups
        if let index = updated.firstIndex(of: group) {
            updated.remove(at: index)
        } else {
            updated.append(group)
        }
        priorityGroups = updated
        hasStructuralEdit = true
        writeTrainingSettings()
    }

    // MARK: Progression

    func setProgressionStrategy(_ strategy: ProgressionStrategy) {
        progressionStrategy = strategy
        writeTrainingSettings()
    }

    func setAutoProgression(_ isOn: Bool) {
        autoProgressionEnabled = isOn
        writeTrainingSettings()
    }

    func setDeloadSuggestions(_ isOn: Bool) {
        deloadSuggestionsEnabled = isOn
        writeTrainingSettings()
    }

    /// Block length is a property of the program, not of the profile, so it is held here and only
    /// reaches the store when the plan is rebuilt around it.
    func setMesocycleWeeks(_ weeks: Int) {
        let clamped = InputValidation.clampedMesocycleWeeks(weeks)
        guard clamped != mesocycleWeeks else { return }
        mesocycleWeeks = clamped
        hasStructuralEdit = true
    }

    // MARK: Effort

    var effectiveRIR: Int { targetRIROverride ?? experienceRIR }

    /// Clearing the override hands the decision back to the experience level rather than freezing
    /// whatever number happened to be on screen.
    func setRIROverrideEnabled(_ isOn: Bool) {
        let value = isOn ? effectiveRIR : nil
        targetRIROverride = value
        writeSettings { $0.targetRIROverride = value }
    }

    func setTargetRIR(_ value: Int) {
        let clamped = InputValidation.clampedRIR(value)
        targetRIROverride = clamped
        writeSettings { $0.targetRIROverride = clamped }
    }

    // MARK: Rest

    func setDefaultRest(_ seconds: Int) {
        let value = InputValidation.clampedRestSeconds(seconds)
        defaultRestSeconds = value
        writeSettings { $0.defaultRestSeconds = value }
    }

    func setCompoundRest(_ seconds: Int) {
        let value = InputValidation.clampedRestSeconds(seconds)
        compoundRestSeconds = value
        writeSettings { $0.defaultCompoundRestSeconds = value }
    }

    func setIsolationRest(_ seconds: Int) {
        let value = InputValidation.clampedRestSeconds(seconds)
        isolationRestSeconds = value
        writeSettings { $0.defaultIsolationRestSeconds = value }
    }

    /// Pushes the stored defaults onto every slot in the active program, choosing the compound or
    /// isolation figure from the movement itself. Without this the three pickers would be a
    /// preference with nothing reading it; with it they are a one-tap way to re-time a whole week.
    func applyRestTimesToProgram() {
        guard let program, let plan = program.program else { return }
        var changed = 0
        for template in plan.orderedTemplates {
            for planned in template.orderedExercises {
                let target = restSeconds(forExerciseID: planned.exerciseID, in: program)
                guard planned.restSeconds != target else { continue }
                program.updatePrescription(of: planned, restSeconds: target)
                changed += 1
            }
        }
        program.notice = changed == 0
            ? L("program.settings.restUnchanged")
            : LPlural("program.settings.restApplied", changed)
    }

    private func restSeconds(forExerciseID id: String, in program: ProgramViewModel) -> Int {
        switch program.exercise(id)?.metadata.mechanic {
        case .compound: compoundRestSeconds
        case .isolation: isolationRestSeconds
        case nil: defaultRestSeconds
        }
    }

    static func restOptions(including current: Int) -> [Int] {
        merged([30, 45, 60, 75, 90, 120, 150, 180, 240, 300], with: current)
    }

    /// Keeps a stored value selectable even when it is not one of the offered options, so a figure
    /// restored from a backup is never silently rounded by opening this screen.
    private static func merged(_ options: [Int], with current: Int) -> [Int] {
        options.contains(current) ? options : (options + [current]).sorted()
    }

    // MARK: The plan

    /// Ways in which the stored program no longer matches these settings, in the user's words.
    var planDifferences: [String] {
        guard let program, let plan = program.program, let profile = program.context?.profile else {
            return []
        }
        var result: [String] = []
        if plan.daysPerWeek != profile.daysPerWeek {
            result.append(L("program.settings.mismatch.days", plan.daysPerWeek, profile.daysPerWeek))
        }
        if Set(plan.priorityGroups) != Set(profile.priorityGroups) {
            result.append(L("program.settings.mismatch.priorities"))
        }
        if plan.mesocycleLengthWeeks != mesocycleWeeks {
            result.append(L("program.settings.mismatch.block", plan.mesocycleLengthWeeks, mesocycleWeeks))
        }
        if Set(plan.goals) != Set(profile.goals) {
            result.append(L("program.settings.mismatch.goals"))
        }
        return result
    }

    var needsRebuild: Bool { hasStructuralEdit || !planDifferences.isEmpty }

    /// Runs the programming engine against the settings as they stand now. The reason is recorded on
    /// the new `ProgramVersion`, so the history says why the week changed shape.
    func rebuild() async {
        guard let program else { return }
        await program.regenerate(
            reason: Explanation("program.version.settingsChanged"),
            mesocycleWeeks: mesocycleWeeks
        )
        hasStructuralEdit = false
        if let weeks = program.program?.mesocycleLengthWeeks { mesocycleWeeks = weeks }
        if let context = program.context {
            seed(profile: context.profile, settings: program.currentSettings())
        }
    }

    // MARK: Writing

    private func writeTrainingSettings() {
        program?.updateTrainingSettings(
            weekdays: weekdays,
            sessionMinutes: sessionMinutes,
            priorityGroups: priorityGroups,
            progressionStrategy: progressionStrategy,
            deloadSuggestionsEnabled: deloadSuggestionsEnabled,
            autoProgressionEnabled: autoProgressionEnabled
        )
    }

    private func writeSettings(_ mutate: (UserSettings) -> Void) {
        guard let modelContext else { return }
        do {
            try ProfileRepository(context: modelContext).updateSettings(mutate)
        } catch {
            program?.actionError = (error as? RepositoryError)?.explanation.text
                ?? L("program.error.generic")
        }
    }
}

/// The seasoned-user fixture already has a four-day week, priorities and a block length behind it,
/// which is the state where the mismatch banner has something real to say.
#Preview {
    PreviewHost(scenario: .seasonedUser) {
        ProgramSettingsPreview()
    }
}

private struct ProgramSettingsPreview: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppEnvironment.self) private var environment
    @State private var model = ProgramViewModel()

    var body: some View {
        NavigationStack {
            ProgramSettingsView(model: model)
        }
        .task { await model.load(modelContext: modelContext, catalog: environment.catalog) }
    }
}
