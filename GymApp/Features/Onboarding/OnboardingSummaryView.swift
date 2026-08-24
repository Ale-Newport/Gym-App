import SwiftUI
import SwiftData

/// The last screen before the app opens: everything the questionnaire collected, grouped, with a way
/// straight back into any of it.
///
/// A review screen only earns its place if it is genuinely *checkable*. Three things make it one.
/// Every value is shown in the unit the user picked rather than the unit it is stored in, so a
/// mis-typed body weight is obvious. Long lists — equipment, plates, exclusions — collapse to a count
/// that can be opened, because nobody proof-reads twenty chips but everybody notices "3 items" when
/// they own a full gym. And each group carries its own edit control that lands on the step which owns
/// it, so a correction costs one tap instead of a walk back through eight screens.
///
/// The confirm control lives here as well as in the flow's footer. It is the same action; having it
/// at the end of the review is what makes the review feel like something you finish rather than
/// something you scroll past.
struct OnboardingSummaryView: View {
    let model: OnboardingViewModel
    let onEdit: (OnboardingStep) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayFormatter) private var environmentFormatter

    /// Which of the collapsed lists the user has opened, by a stable identifier rather than by step,
    /// because one step can own more than one list.
    @State private var openLists: Set<String> = []

    private static let tileColumns = [GridItem(.adaptive(minimum: 96), spacing: Metrics.spacing12)]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            programSection
            basicsSection
            goalsSection
            experienceSection
            availabilitySection
            equipmentSection
            restrictionsSection
            nutritionSection
            confirmSection
        }
    }

    // MARK: - Units

    /// The environment formatter carries the locale and the energy unit; the mass and length units
    /// come from the draft, which is the only place they are authoritative until onboarding has
    /// finished writing them to `UserSettings`.
    private var units: DisplayFormatter {
        var formatter = environmentFormatter
        formatter.weightUnit = model.weightUnit
        formatter.heightUnit = model.heightUnit
        return formatter
    }

    // MARK: - Program

    @ViewBuilder
    private var programSection: some View {
        let title = L("onboarding.summary.program")
        OnboardingSection(
            title: title,
            subtitle: nil,
            accessory: {
                if model.generation.result != nil {
                    SummaryEditButton(sectionTitle: title) { onEdit(.generating) }
                }
            },
            content: {
                if let result = model.generation.result {
                    Card {
                        VStack(alignment: .leading, spacing: Metrics.spacing12) {
                            Text(result.programTitle)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Color.appTextPrimary)
                                .fixedSize(horizontal: false, vertical: true)

                            LazyVGrid(columns: Self.tileColumns, alignment: .leading, spacing: Metrics.spacing12) {
                                StatTile(
                                    value: String(result.daysPerWeek),
                                    label: L("onboarding.result.daysPerWeek"),
                                    systemImage: "calendar"
                                )
                                StatTile(
                                    value: String(result.totalWeeklySets),
                                    label: L("onboarding.result.weeklySets"),
                                    systemImage: "square.stack.3d.up"
                                )
                                StatTile(
                                    value: units.durationCompact(weeklySeconds(result)),
                                    label: L("onboarding.result.weeklyTime"),
                                    systemImage: "clock"
                                )
                            }

                            if result.isManual {
                                ExplanationNote(
                                    text: L("onboarding.generate.manualExplanation"),
                                    systemImage: "hand.raised",
                                    tint: .appWarning
                                )
                            } else {
                                SummaryRow(label: L("onboarding.summary.split"), value: L(result.splitKey))
                            }
                        }
                    }
                } else {
                    // Reachable when the review is opened without a program behind it — a jump back
                    // from an edit that never made it through generation again. Saying so, with the
                    // one control that fixes it, beats a confirm button that finishes an empty setup.
                    EmptyStateView(
                        systemImage: "wand.and.stars",
                        title: L("onboarding.summary.program.empty.title"),
                        message: L("onboarding.summary.program.empty.message")
                    ) {
                        Button(L("onboarding.summary.program.build")) { onEdit(.generating) }
                            .buttonStyle(SecondaryButtonStyle())
                            .frame(maxWidth: 240)
                    }
                }
            }
        )
    }

    private func weeklySeconds(_ result: OnboardingProgramResult) -> Int {
        result.trainingSessions.reduce(0) { $0 + $1.estimatedMinutes * 60 }
    }

    // MARK: - Basics

    private var basicsSection: some View {
        section(L("onboarding.summary.basics"), editing: .basics) {
            SummaryRow(
                label: L("onboarding.basics.name"),
                value: trimmedName.isEmpty ? L("common.notSet") : trimmedName
            )
            SummaryRow(label: L("onboarding.summary.age"), value: ageValue)
            SummaryRow(
                label: L("onboarding.basics.sex"),
                value: L(model.biologicalSex.localizationKey)
            )
            SummaryRow(
                label: L("onboarding.basics.height"),
                value: model.heightCm.map { units.height($0) } ?? L("common.notSet")
            )
            SummaryRow(
                label: L("onboarding.basics.weight"),
                value: model.currentWeightKg.map { units.weight($0) } ?? L("common.notSet")
            )
            SummaryRow(label: L("onboarding.basics.target"), value: targetValue)
            SummaryRow(
                label: L("onboarding.summary.units"),
                value: "\(L(model.weightUnit.localizationKey)) · \(L(model.heightUnit.localizationKey))"
            )
        }
    }

    private var trimmedName: String {
        model.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var ageValue: String {
        guard model.wantsBirthDate,
              let years = Calendar.current.dateComponents([.year], from: model.birthDate, to: Date()).year,
              years >= 0
        else { return L("common.notSet") }
        return L("onboarding.summary.ageYears", years)
    }

    private var targetValue: String {
        guard model.wantsTargetWeight, let target = model.targetWeightKg else { return L("common.notSet") }
        return units.weight(target)
    }

    // MARK: - Goals

    private var goalsSection: some View {
        section(L("onboarding.summary.goals"), editing: .goals) {
            SummaryRow(
                label: L("onboarding.summary.primaryGoal"),
                value: model.goals.first.map { L($0.localizationKey) } ?? L("common.notSet")
            )
            if model.goals.count > 1 {
                SummaryRow(
                    label: L("onboarding.summary.otherGoals"),
                    value: model.goals.dropFirst().map { L($0.localizationKey) }.joined(separator: " · ")
                )
            }
            if !model.priorityRegions.isEmpty {
                SummaryRow(
                    label: L("onboarding.goals.regions"),
                    value: model.priorityRegions.map { L($0.localizationKey) }.joined(separator: " · ")
                )
            }

            let groups = model.resolvedPriorityGroups
            if groups.isEmpty {
                SummaryRow(label: L("onboarding.goals.muscles"), value: L("common.none"))
            } else {
                SummaryDisclosure(
                    label: L("onboarding.goals.muscles"),
                    value: LPlural("onboarding.summary.groupCount", groups.count),
                    isOpen: listBinding("priorityGroups")
                ) {
                    FlowLayout {
                        ForEach(groups) { group in
                            MuscleGroupBadge(group: group)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Experience

    private var experienceSection: some View {
        section(L("onboarding.summary.experience"), editing: .experience) {
            SummaryRow(
                label: L("onboarding.experience.level"),
                value: L(model.experience.localizationKey)
            )
            if model.experience != .never, let months = model.trainingMonths, months > 0 {
                SummaryRow(
                    label: L("onboarding.experience.months"),
                    value: LPlural("onboarding.summary.months", months)
                )
            }
            SummaryRow(
                label: L("onboarding.experience.technique"),
                value: L(model.techniqueConfidence.localizationKey)
            )
            SummaryRow(label: L("onboarding.experience.seeds"), value: seedsValue)
        }
    }

    private var seedsValue: String {
        guard model.wantsStrengthSeeds else { return L("common.none") }
        let recorded = model.strengthSeedOptions.filter { model.strengthSeeds[$0.exercise.id]?.isUsable == true }
        guard !recorded.isEmpty else { return L("common.none") }
        return LPlural("onboarding.summary.seeds", recorded.count)
    }

    // MARK: - Availability

    private var availabilitySection: some View {
        section(L("onboarding.summary.availability"), editing: .availability) {
            SummaryRow(
                label: L("onboarding.availability.days"),
                value: LPlural("onboarding.summary.daysPerWeek", model.daysPerWeek)
            )
            SummaryRow(label: L("onboarding.summary.trainingDays"), value: weekdayValue)
            SummaryRow(
                label: L("onboarding.availability.length"),
                value: L("onboarding.summary.sessionCap", model.sessionMinutes)
            )
            SummaryRow(
                label: L("onboarding.availability.time"),
                value: L(model.preferredTrainingTime.localizationKey)
            )
            SummaryRow(
                label: L("onboarding.availability.cardio"),
                value: L(model.cardioPreference.localizationKey)
            )
            SummaryRow(
                label: L("onboarding.availability.activity"),
                value: L(model.activityLevel.localizationKey)
            )
        }
    }

    private var weekdayValue: String {
        let chosen = Weekday.orderedMondayFirst.filter { model.availableWeekdays.contains($0) }
        guard !chosen.isEmpty else { return L("common.notSet") }
        return chosen.map { L($0.shortLocalizationKey) }.joined(separator: " · ")
    }

    // MARK: - Equipment

    private var equipmentSection: some View {
        section(L("onboarding.summary.equipment"), editing: .equipment) {
            SummaryRow(
                label: L("onboarding.equipment.preset"),
                value: L(model.equipmentPreset.localizationKey)
            )

            let equipment = model.selectedEquipment.sorted { $0.rawValue < $1.rawValue }
            SummaryDisclosure(
                label: L("exercise.fact.equipment"),
                value: LPlural("onboarding.summary.equipmentCount", equipment.count),
                isOpen: listBinding("equipment")
            ) {
                FlowLayout {
                    ForEach(equipment) { item in
                        Chip(title: L(item.localizationKey), systemImage: item.symbolName, isSelected: true)
                    }
                }
            }

            SummaryRow(
                label: L("onboarding.summary.exercisesAvailable"),
                value: String(model.unlockedExerciseCount(catalog: environment.catalog))
            )

            if model.usesBarbell {
                SummaryRow(
                    label: L("onboarding.equipment.barWeight"),
                    value: model.barbellBarWeightKg.map { units.weight($0) } ?? L("common.notSet")
                )
                let plates = model.selectedPlatesKg.sorted(by: >)
                SummaryDisclosure(
                    label: L("onboarding.equipment.plates"),
                    value: plates.isEmpty
                        ? L("common.none")
                        : LPlural("onboarding.summary.plateCount", plates.count),
                    isOpen: listBinding("plates")
                ) {
                    FlowLayout {
                        ForEach(plates, id: \.self) { plate in
                            Chip(title: units.weight(plate), isSelected: true)
                        }
                    }
                }
            }
            if model.selectedEquipment.contains(.ezBarbell) {
                SummaryRow(
                    label: L("onboarding.equipment.ezBarWeight"),
                    value: model.ezBarWeightKg.map { units.weight($0) } ?? L("common.notSet")
                )
            }
            if model.usesDumbbells {
                SummaryRow(
                    label: L("onboarding.equipment.dumbbellStep"),
                    value: units.weight(model.dumbbellStepKg)
                )
            }
            if model.usesKettlebells {
                let bells = model.kettlebellsKg.sorted()
                SummaryDisclosure(
                    label: L("onboarding.equipment.kettlebells"),
                    value: bells.isEmpty
                        ? L("common.none")
                        : LPlural("onboarding.summary.kettlebellCount", bells.count),
                    isOpen: listBinding("kettlebells")
                ) {
                    FlowLayout {
                        ForEach(bells, id: \.self) { bell in
                            Chip(title: units.weight(bell), isSelected: true)
                        }
                    }
                }
            }
            if model.usesMachines {
                SummaryRow(
                    label: L("onboarding.equipment.machineIncrement"),
                    value: model.machineIncrementKg.map { units.weight($0) } ?? L("common.notSet")
                )
            }
            if model.selectedEquipment.contains(.cable) {
                SummaryRow(
                    label: L("onboarding.equipment.cableIncrement"),
                    value: model.cableIncrementKg.map { units.weight($0) } ?? L("common.notSet")
                )
            }
        }
    }

    // MARK: - Restrictions

    private var restrictionsSection: some View {
        section(L("onboarding.summary.restrictions"), editing: .restrictions) {
            let limitations = model.mobilityLimitations.sorted { $0.rawValue < $1.rawValue }
            if limitations.isEmpty {
                SummaryRow(label: L("onboarding.restrictions.limitations"), value: L("common.none"))
            } else {
                SummaryDisclosure(
                    label: L("onboarding.restrictions.limitations"),
                    value: L("onboarding.summary.limitationCount", limitations.count),
                    isOpen: listBinding("limitations")
                ) {
                    FlowLayout {
                        ForEach(limitations) { limitation in
                            Chip(title: L(limitation.localizationKey), isSelected: true, tint: .appRecovery)
                        }
                    }
                }
            }

            // What the user ticked and what their limitations imply are the same thing to the
            // selector, so the review shows them as one list rather than making the user add up two.
            let avoided = model.avoidedPatterns
                .union(model.patternsImpliedByLimitations)
                .sorted { $0.rawValue < $1.rawValue }
            if avoided.isEmpty {
                SummaryRow(label: L("onboarding.summary.avoided"), value: L("common.none"))
            } else {
                SummaryDisclosure(
                    label: L("onboarding.summary.avoided"),
                    value: LPlural("onboarding.summary.movementCount", avoided.count),
                    isOpen: listBinding("patterns")
                ) {
                    FlowLayout {
                        ForEach(avoided, id: \.self) { pattern in
                            Chip(title: L(pattern.localizationKey), isSelected: true, tint: .appRecovery)
                        }
                    }
                }
            }

            if model.excludedExerciseIDs.isEmpty {
                SummaryRow(label: L("onboarding.restrictions.exclusions"), value: L("common.none"))
            } else {
                SummaryDisclosure(
                    label: L("onboarding.restrictions.exclusions"),
                    value: LPlural("onboarding.summary.excludedCount", model.excludedExerciseIDs.count),
                    isOpen: listBinding("exclusions")
                ) {
                    excludedExerciseList
                }
            }
        }
    }

    /// Excluded ids resolved to names. The catalogue is what turns an id into something a person can
    /// check, so while it is still loading the list says so rather than showing raw identifiers.
    @ViewBuilder
    private var excludedExerciseList: some View {
        if environment.catalog.isLoaded {
            FlowLayout {
                ForEach(environment.catalog.exercises(ids: model.excludedExerciseIDs)) { exercise in
                    Chip(
                        title: exercise.name.localizedCapitalized,
                        systemImage: "xmark",
                        isSelected: true,
                        tint: .appDanger
                    )
                }
            }
        } else {
            LoadingStateView(message: L("onboarding.summary.loadingExercises"))
                .frame(height: 80)
        }
    }

    // MARK: - Nutrition

    private var nutritionSection: some View {
        section(L("onboarding.summary.nutrition"), editing: .nutrition) {
            SummaryRow(
                label: L("onboarding.summary.foodTracking"),
                value: model.nutritionEnabled ? L("onboarding.summary.on") : L("onboarding.summary.off")
            )

            if model.nutritionEnabled {
                SummaryRow(
                    label: L("onboarding.nutrition.diet"),
                    value: L(model.dietType.localizationKey)
                )
                if let targets = model.generation.result?.energyTargets {
                    SummaryRow(
                        label: L("onboarding.summary.dailyTarget"),
                        value: units.energy(targets.kilocalories)
                    )
                    SummaryRow(
                        label: L("onboarding.summary.macros"),
                        value: [targets.proteinG, targets.carbsG, targets.fatG]
                            .map { units.macro($0) }
                            .joined(separator: " / ")
                    )
                }

                tagDisclosure(
                    label: L("onboarding.nutrition.allergens"),
                    identifier: "allergens",
                    tags: model.allergenTags.sorted(),
                    tint: .appDanger
                )
                tagDisclosure(
                    label: L("onboarding.nutrition.intolerances"),
                    identifier: "intolerances",
                    tags: model.intoleranceTags.sorted(),
                    tint: .appWarning
                )
                tagDisclosure(
                    label: L("onboarding.nutrition.excluded"),
                    identifier: "excludedFoods",
                    tags: model.excludedFoodTags.sorted(),
                    tint: .appNutrition
                )

                SummaryRow(label: L("onboarding.nutrition.meals"), value: String(model.mealsPerDay))
                SummaryRow(
                    label: L("onboarding.nutrition.pace"),
                    value: L(model.nutritionPace.localizationKey)
                )
                if model.wantsBudget, let budget = model.weeklyFoodBudget, budget > 0 {
                    SummaryRow(
                        label: L("onboarding.nutrition.budget"),
                        value: Units.formatDecimal(budget, digits: 0, locale: units.locale)
                    )
                }
            } else {
                OnboardingInlineHint(message: L("onboarding.summary.nutritionOff"))
                    .padding(.vertical, Metrics.spacing8)
            }
        }
    }

    @ViewBuilder
    private func tagDisclosure(label: String, identifier: String, tags: [String], tint: Color) -> some View {
        if tags.isEmpty {
            SummaryRow(label: label, value: L("common.none"))
        } else {
            SummaryDisclosure(
                label: label,
                value: LPlural("onboarding.summary.tagCount", tags.count),
                isOpen: listBinding(identifier)
            ) {
                FlowLayout {
                    ForEach(tags, id: \.self) { tag in
                        Chip(title: foodTagName(tag), isSelected: true, tint: tint)
                    }
                }
            }
        }
    }

    /// Curated tags have a catalogue entry; anything the user typed in themselves does not, so it is
    /// shown as they wrote it rather than looked up and asserted on.
    private func foodTagName(_ tag: String) -> String {
        let known = Set(OnboardingOptions.allergenTags)
            .union(OnboardingOptions.intoleranceTags)
            .union(OnboardingOptions.excludableFoodTags)
        return known.contains(tag) ? L("onboarding.foodTag.\(tag)") : tag.localizedCapitalized
    }

    // MARK: - Confirm

    private var confirmSection: some View {
        Card(background: .appSurfaceElevated) {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Text(L("onboarding.summary.ready.title"))
                    .font(.appCardTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L("onboarding.summary.ready.detail"))
                    .font(.footnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ExplanationNote(
                    text: L("onboarding.summary.ready.privacy"),
                    systemImage: "lock.shield",
                    tint: .appRecovery
                )

                // Deliberately NO confirm button here. `OnboardingFlowView` pins one to the
                // footer of every step, so putting a second identical "Start training" on this
                // card gave the screen two primary actions with the same label — confusing to
                // look at, ambiguous to VoiceOver, and impossible to address unambiguously in a
                // test. The card explains what confirming does; the footer does it.
                if let error = model.errorMessage {
                    // A failed write is the one thing that can stop the flow here, so it is answered
                    // in place with the action that retries it rather than an alert the user
                    // dismisses and then wonders about.
                    ErrorStateView(message: error, retryTitle: L("common.retry")) { confirm() }
                } else {
                    Text(L("onboarding.summary.confirm.hint"))
                        .font(.footnote)
                        .foregroundStyle(Color.appTextTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func confirm() {
        Haptics.tap()
        _ = model.finish(context: modelContext)
    }

    // MARK: - Building blocks

    /// One reviewable group: a heading, an edit control that jumps to the step which owns it, and the
    /// rows themselves inside a single card.
    private func section<Content: View>(
        _ title: String,
        editing step: OnboardingStep,
        @ViewBuilder content: () -> Content
    ) -> some View {
        OnboardingSection(
            title: title,
            subtitle: nil,
            accessory: { SummaryEditButton(sectionTitle: title) { onEdit(step) } },
            content: {
                Card {
                    VStack(spacing: 0) { content() }
                }
            }
        )
    }

    private func listBinding(_ identifier: String) -> Binding<Bool> {
        Binding(
            get: { openLists.contains(identifier) },
            set: { isOpen in
                if isOpen { openLists.insert(identifier) } else { openLists.remove(identifier) }
            }
        )
    }
}

// MARK: - Rows

/// One label-and-value line. Matches `ExerciseFactsGrid` so a reviewed answer and a looked-up fact
/// read the same way, and stacks the value under the label at accessibility text sizes instead of
/// squeezing two columns onto one line.
private struct SummaryRow: View {
    let label: String
    let value: String

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Metrics.spacing2) {
                    labelText
                    valueText.multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top) {
                    labelText
                    Spacer(minLength: Metrics.spacing12)
                    valueText.multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, Metrics.spacing8)
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(label)
            .font(.subheadline)
            .foregroundStyle(Color.appTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var valueText: some View {
        Text(value)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.appTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A list long enough that nobody would read it, shown as its count with a control that opens it.
///
/// The count is the check — "3 items" when you own a full gym is the mistake you want to catch — and
/// the expanded list is there for the times the count is not enough.
private struct SummaryDisclosure<Content: View>: View {
    let label: String
    let value: String
    @Binding var isOpen: Bool
    @ViewBuilder var content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Button {
                Haptics.tap()
                isOpen.toggle()
            } label: {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: Metrics.spacing2) {
                            labelText
                            HStack(spacing: Metrics.spacing6) {
                                valueText
                                chevron
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .top, spacing: Metrics.spacing6) {
                            labelText
                            Spacer(minLength: Metrics.spacing12)
                            valueText.multilineTextAlignment(.trailing)
                            chevron
                        }
                    }
                }
                .padding(.vertical, Metrics.spacing8)
                .frame(minHeight: Metrics.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(value))
            .accessibilityHint(Text(isOpen ? L("onboarding.summary.collapse") : L("onboarding.summary.expand")))
            .accessibilityAddTraits(.isButton)

            if isOpen {
                content
                    .padding(.bottom, Metrics.spacing8)
            }
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.subheadline)
            .foregroundStyle(Color.appTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var valueText: some View {
        Text(value)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.appTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The chevron is decoration; the state it hints at is carried properly by the button's
    /// accessibility hint, so it stays hidden from VoiceOver.
    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.appAccent)
            .rotationEffect(.degrees(isOpen ? 180 : 0))
            .animation(.easeInOut(duration: 0.18), value: isOpen)
            .accessibilityHidden(true)
    }
}

/// The per-group edit control. Named by its section so VoiceOver users are not offered seven
/// identical "Edit" buttons.
private struct SummaryEditButton: View {
    let sectionTitle: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: Metrics.spacing4) {
                Image(systemName: "pencil")
                    .font(.caption.weight(.semibold))
                Text(L("common.edit"))
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, Metrics.spacing8)
            .frame(minHeight: Metrics.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L("onboarding.summary.edit", sectionTitle)))
    }
}

#Preview("Summary") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .summary) { model in
            OnboardingSummaryView(model: model, onEdit: { model.jump(to: $0) })
        }
    }
}
