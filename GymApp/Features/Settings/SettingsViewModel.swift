import Foundation
import Observation
import SwiftData
import SwiftUI

/// The one object every settings screen talks to.
///
/// Settings are three singleton rows — `UserProfile`, `UserSettings` and `EquipmentProfile` — split
/// across fifteen screens that each edit a slice of them. Giving every screen a bespoke view model
/// would mean fifteen copies of "fetch the row, write through the repository, translate the error",
/// so there is one model and each screen holds its own instance. They all resolve to the same
/// SwiftData objects, so a change made on one screen is already visible on the next without any
/// notification plumbing.
///
/// Nothing in this file writes to a model object directly. Every mutation goes through
/// `ProfileRepository`, which is where the validation and clamping rules live; a refused write
/// surfaces as `writeError` rather than silently sticking in memory.
@MainActor
@Observable
final class SettingsViewModel {

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var profile: UserProfile?
    private(set) var settings: UserSettings?
    private(set) var equipment: EquipmentProfile?

    /// The last refused write, already localised. Shown inline beside the control rather than as an
    /// alert: the user is usually mid-edit, and an alert would dismiss the keyboard and lose focus.
    var writeError: String?

    /// Called after any successful write. `NotificationSettingsView` uses it to re-apply the whole
    /// notification schedule; nothing else needs it, so it stays an optional hook rather than a
    /// second observable stream.
    var onSettingsChanged: (() -> Void)?

    private var repository: ProfileRepository?
    private var localeOverride: Locale?
    @ObservationIgnored private var pendingCommits: [String: Task<Void, Never>] = [:]

    init() {}

    // MARK: - Debounced commits

    /// Delays a numeric commit until the user stops typing.
    ///
    /// Text fields report every keystroke, so committing immediately would send "7" to the
    /// repository on the way to "75" and bounce a validation error the user has not made yet.
    /// Keyed by field so two fields being edited in turn do not cancel each other, and the closure
    /// holds the model, so an edit still lands if the screen is dismissed a moment later.
    func commit(_ id: String, after seconds: Double = 0.45, _ work: @escaping () -> Void) {
        pendingCommits[id]?.cancel()
        pendingCommits[id] = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    // MARK: - Loading

    /// Idempotent. Every screen calls this from its own `.task`; returning to a screen must not
    /// refetch rows the view is already bound to.
    func load(context: ModelContext, locale: Locale? = nil) {
        localeOverride = locale
        if repository == nil { repository = ProfileRepository(context: context) }
        guard phase == .loading, profile == nil else { return }
        fetch()
    }

    func reload() {
        phase = .loading
        fetch()
    }

    private func fetch() {
        guard let repository else {
            phase = .failed(L("common.error"))
            return
        }
        do {
            profile = try repository.profile()
            settings = try repository.settings()
            equipment = try repository.equipmentProfile()
            phase = .ready
        } catch {
            profile = nil
            settings = nil
            equipment = nil
            phase = .failed(Self.message(for: error))
        }
    }

    /// True once every row the screens bind to exists. A `false` here after loading means the store
    /// answered but had nothing to give, which the scaffold renders as an empty state with a retry
    /// rather than as a screen full of default values the user never chose.
    var hasRows: Bool { profile != nil && settings != nil && equipment != nil }

    // MARK: - Formatting

    /// The formatter these screens use.
    ///
    /// It is built from the freshly loaded `UserSettings` instead of read from the environment: the
    /// units screen has to redraw its own examples the instant a unit changes, and the environment
    /// value is published from higher up the tree than a pushed settings screen can rely on.
    var formatter: DisplayFormatter {
        DisplayFormatter(settings: settings, locale: localeOverride ?? Locale.current)
    }

    // MARK: - Error translation

    static func message(for error: Error) -> String {
        if let repositoryError = error as? RepositoryError { return repositoryError.explanation.text }
        if let importError = error as? ImportError { return L(importError.localizationKey) }
        return L("common.error")
    }

    /// Runs a repository call, reporting failure instead of throwing it at the view.
    ///
    /// On failure the rows are re-read: `updateSettings` mutates the model before it saves, so a
    /// rejected save would otherwise leave the in-memory object showing a value that never reached
    /// disk.
    private func perform(_ work: (ProfileRepository) throws -> Void) {
        guard let repository else { return }
        do {
            try work(repository)
            writeError = nil
            onSettingsChanged?()
        } catch {
            writeError = Self.message(for: error)
            fetch()
        }
    }

    // MARK: - Settings writes

    func updateSettings(_ mutate: @escaping (UserSettings) -> Void) {
        perform { try $0.updateSettings(mutate) }
    }

    /// A binding onto any `UserSettings` field. The fallback is only used before the row loads, and
    /// the scaffold does not render content until it has.
    func settingsBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<UserSettings, Value>,
        default fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { self.settings?[keyPath: keyPath] ?? fallback },
            set: { newValue in self.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }

    // MARK: - Profile writes

    func updateIdentity(name: String?? = nil, birthDate: Date?? = nil, biologicalSex: BiologicalSex? = nil) {
        perform { try $0.updateIdentity(name: name, birthDate: birthDate, biologicalSex: biologicalSex) }
    }

    func updateBodyMetrics(heightCm: Double? = nil, currentWeightKg: Double? = nil, targetWeightKg: Double?? = nil) {
        perform {
            try $0.updateBodyMetrics(
                heightCm: heightCm,
                currentWeightKg: currentWeightKg,
                targetWeightKg: targetWeightKg
            )
        }
    }

    func updateExperience(
        level: ExperienceLevel? = nil,
        months: Int? = nil,
        techniqueConfidence: TechniqueConfidence? = nil
    ) {
        perform { try $0.updateExperience(level: level, months: months, techniqueConfidence: techniqueConfidence) }
    }

    func updateGoals(
        goals: [TrainingGoal]? = nil,
        priorityGroups: [MuscleGroup]? = nil,
        priorityRegions: [TrainingFocusRegion]? = nil,
        activityLevel: ActivityLevel? = nil
    ) {
        perform {
            try $0.updateGoals(
                goals: goals,
                priorityGroups: priorityGroups,
                priorityRegions: priorityRegions,
                activityLevel: activityLevel
            )
        }
    }

    func updateAvailability(
        weekdays: [Weekday]? = nil,
        sessionMinutesCap: Int? = nil,
        preferredTrainingTime: PreferredTrainingTime? = nil,
        cardioPreference: CardioPreference? = nil
    ) {
        perform {
            try $0.updateAvailability(
                weekdays: weekdays,
                sessionMinutesCap: sessionMinutesCap,
                preferredTrainingTime: preferredTrainingTime,
                cardioPreference: cardioPreference
            )
        }
    }

    func updateRestrictions(mobilityLimitations: [MobilityLimitation]? = nil, avoidedPatterns: [MovementPattern]? = nil) {
        perform { try $0.updateRestrictions(mobilityLimitations: mobilityLimitations, avoidedPatterns: avoidedPatterns) }
    }

    func updateNutritionPreferences(
        dietType: DietType? = nil,
        allergenTags: [String]? = nil,
        intoleranceTags: [String]? = nil,
        excludedFoodTags: [String]? = nil,
        mealsPerDay: Int? = nil,
        pace: NutritionGoalPace? = nil
    ) {
        perform {
            try $0.updateNutritionPreferences(
                dietType: dietType,
                allergenTags: allergenTags,
                intoleranceTags: intoleranceTags,
                excludedFoodTags: excludedFoodTags,
                mealsPerDay: mealsPerDay,
                pace: pace
            )
        }
    }

    func reopenOnboarding() {
        perform { try $0.reopenOnboarding() }
    }

    // MARK: - Equipment writes

    func updateEquipment(preset: GymSetupPreset? = nil, availableEquipment: Set<Equipment>? = nil) {
        perform { try $0.updateEquipment(preset: preset, availableEquipment: availableEquipment) }
    }

    func setTemporarilyUnavailable(_ item: Equipment, unavailable: Bool) {
        perform { try $0.setTemporarilyUnavailable(item, unavailable: unavailable) }
    }

    func clearTemporarilyUnavailable() {
        perform { try $0.clearTemporarilyUnavailable() }
    }

    func updateIncrements(
        barbellBarWeightKg: Double? = nil,
        ezBarWeightKg: Double? = nil,
        availablePlatesKg: [Double]? = nil,
        availableDumbbellsKg: [Double]? = nil,
        kettlebellsKg: [Double]? = nil,
        machineIncrementKg: Double? = nil,
        cableIncrementKg: Double? = nil
    ) {
        perform {
            try $0.updateIncrements(
                barbellBarWeightKg: barbellBarWeightKg,
                ezBarWeightKg: ezBarWeightKg,
                availablePlatesKg: availablePlatesKg,
                availableDumbbellsKg: availableDumbbellsKg,
                kettlebellsKg: kettlebellsKg,
                machineIncrementKg: machineIncrementKg,
                cableIncrementKg: cableIncrementKg
            )
        }
    }

    // MARK: - Language

    /// Applies a language choice.
    ///
    /// Two writes, deliberately: `LocalizationManager` is what the `L(_:)` lookups read and what the
    /// app is keyed on, and `UserSettings.languageOverride` is what a backup carries to a new
    /// device. Writing only one of them would make the choice either non-persistent or inert.
    func setLanguage(_ language: AppLanguage?) {
        LocalizationManager.shared.setOverride(language)
        updateSettings { $0.languageOverride = language }
    }

    // MARK: - Derived summaries, used by the root list

    var displayName: String {
        let trimmed = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? L("settings.profile.noName") : trimmed
    }

    var primaryGoalTitle: String {
        guard let goal = profile?.goals.first else { return L("settings.goals.none") }
        return L(goal.localizationKey)
    }

    var languageSummary: String {
        guard let override = LocalizationManager.shared.override else { return L("settings.language.followDevice") }
        return override.endonym
    }

    var unitsSummary: String {
        guard let settings else { return "—" }
        return "\(settings.weightUnit.rawValue) · \(L(settings.heightUnit.localizationKey))"
    }

    var appearanceSummary: String {
        L((settings?.appearance ?? .system).localizationKey)
    }

    var trainingDaysSummary: String {
        let count = profile?.availableWeekdays.count ?? 0
        return count == 0 ? L("settings.training.noDays") : L("settings.training.daysCount", count)
    }

    var equipmentSummary: String {
        guard let equipment else { return "—" }
        if equipment.preset != .custom { return L(equipment.preset.localizationKey) }
        return L("settings.equipment.itemsCount", equipment.availableEquipment.count)
    }

    var nutritionSummary: String {
        (settings?.nutritionEnabled ?? true) ? L(profile?.dietType.localizationKey ?? "diet.omnivore") : L("common.no")
    }

    var notificationsSummary: String {
        (settings?.notificationsEnabled ?? false) ? L("settings.notifications.on") : L("settings.notifications.off")
    }

    var healthSummary: String {
        (settings?.healthKitEnabled ?? false) ? L("settings.health.connected") : L("settings.health.notConnected")
    }
}

// MARK: - Shared scaffolding

/// Renders the four states every settings screen has to answer for, so no screen has to repeat the
/// switch and none of them can quietly forget one.
struct SettingsScreen<Content: View>: View {
    let model: SettingsViewModel
    @ViewBuilder var content: Content

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var localization: LocalizationManager

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                LoadingStateView(message: L("settings.loading"))
            case .failed(let message):
                ErrorStateView(message: message, retryTitle: L("common.retry")) { model.reload() }
                    .readableWidth()
            case .ready:
                if model.hasRows {
                    content
                } else {
                    // The store answered but held no rows — a first launch interrupted before
                    // bootstrap finished. Re-reading creates them, so the way forward is a retry.
                    EmptyStateView(
                        systemImage: "gearshape",
                        title: L("settings.empty.title"),
                        message: L("settings.empty.message")
                    ) {
                        Button(L("settings.empty.action")) { model.reload() }
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(maxWidth: 260)
                    }
                    .readableWidth()
                }
            }
        }
        .background(Color.appBackground)
        .task { model.load(context: modelContext, locale: localization.current.locale) }
    }
}

/// A settings list styled to the app's palette. `List` is used rather than a hand-rolled stack
/// because it gets keyboard avoidance, Dynamic Type row growth and swipe actions for free.
struct SettingsList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
    }
}

/// A row in the root list: icon, title, and the value the setting currently holds.
struct SettingsNavigationRow: View {
    let systemImage: String
    let title: String
    var value: String?
    var tint: Color = .appAccent

    var body: some View {
        HStack(spacing: Metrics.spacing12) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Metrics.cornerSmall, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Metrics.spacing8)
            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(minHeight: Metrics.minimumTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "\(title), \($0)" } ?? title)
    }
}

/// The inline banner a refused write produces. Never an alert: settings screens are edited with the
/// keyboard up, and an alert would take the focus away from the field that needs fixing.
struct SettingsErrorBanner: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        if let message = model.writeError {
            HStack(alignment: .top, spacing: Metrics.spacing8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.appWarning)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Metrics.spacing8)
                Button {
                    model.writeError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.appTextSecondary)
                        .minimumTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L("common.close")))
            }
            .padding(.vertical, Metrics.spacing4)
            .listRowBackground(Color.appWarning.opacity(0.12))
        }
    }
}

/// A caption under a control explaining what the setting actually changes. Settings that cannot
/// explain themselves get switched at random and then blamed for the result.
struct SettingsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Color.appTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A menu picker over an enum, labelled by its localisation key.
struct EnumPickerRow<Value: Hashable & Identifiable>: View {
    let title: String
    let values: [Value]
    let label: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        Picker(selection: $selection) {
            ForEach(values) { value in
                Text(label(value)).tag(value)
            }
        } label: {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .pickerStyle(.menu)
        .tint(Color.appAccent)
        .frame(minHeight: Metrics.minimumTapTarget)
    }
}

/// A wrapping row of selectable chips backed by a set. Used for goals, muscles, equipment and food
/// tags — everywhere the answer is "any number of these".
struct ChipSelectionRow<Value: Hashable & Identifiable>: View {
    let values: [Value]
    let label: (Value) -> String
    var symbol: ((Value) -> String?)?
    var tint: Color = .appAccent
    let isSelected: (Value) -> Bool
    let toggle: (Value) -> Void

    var body: some View {
        FlowLayout(spacing: Metrics.spacing8, lineSpacing: Metrics.spacing8) {
            ForEach(values) { value in
                Button {
                    toggle(value)
                    Haptics.selectionChanged()
                } label: {
                    Chip(
                        title: label(value),
                        systemImage: symbol.flatMap { $0(value) },
                        isSelected: isSelected(value),
                        tint: tint
                    )
                }
                .buttonStyle(.plain)
                .frame(minHeight: Metrics.minimumTapTarget)
                // Selected state is spoken, not just tinted: the chip's colour alone would be the
                // only cue for a user who cannot see it.
                .accessibilityLabel(Text(label(value)))
                .accessibilityAddTraits(isSelected(value) ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, Metrics.spacing4)
    }
}
