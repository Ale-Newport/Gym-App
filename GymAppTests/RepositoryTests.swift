import Foundation
import SwiftData
import Testing

@testable import GymApp

// MARK: - ProfileRepository

@MainActor
@Suite("ProfileRepository")
struct ProfileRepositoryTests {

    private var calendar: Calendar { StoreTestSupport.utcCalendar }
    private var now: Date { StoreTestSupport.epoch }

    @Test("The singleton rows are created on first access, not seeded at launch")
    func singletonsAreCreatedLazily() throws {
        let context = try StoreTestSupport.makeContext()
        #expect(try context.fetchCount(FetchDescriptor<UserProfile>()) == 0)

        let repository = ProfileRepository(context: context)
        _ = try repository.profile()
        _ = try repository.settings()
        _ = try repository.equipmentProfile()

        #expect(try context.fetchCount(FetchDescriptor<UserProfile>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<UserSettings>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<EquipmentProfile>()) == 1)

        // Idempotent: asking again reuses the row rather than creating a second one.
        let again = try repository.profile()
        #expect(again.id == (try repository.profile()).id)
        #expect(try context.fetchCount(FetchDescriptor<UserProfile>()) == 1)
    }

    @Test("A new equipment row is seeded from its preset, not left meaning 'owns nothing'")
    func equipmentIsSeededFromPreset() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)
        let equipment = try repository.equipmentProfile()

        #expect(!equipment.availableEquipment.isEmpty)
        #expect(Set(equipment.availableEquipment) == equipment.preset.equipment)
        #expect(equipment.availableEquipment.contains(.barbell))
    }

    @Test("A duplicated profile row is pruned and the oldest is kept")
    func duplicateProfilesArePrunedKeepingTheJoinDate() throws {
        let context = try StoreTestSupport.makeContext()
        let older = UserProfile()
        older.createdAt = StoreTestSupport.days(-100)
        older.name = "Older"
        let newer = UserProfile()
        newer.createdAt = now
        newer.name = "Newer"
        context.insert(newer)
        context.insert(older)
        try context.save()

        let repository = ProfileRepository(context: context)
        let kept = try repository.profile()

        #expect(kept.name == "Older")
        #expect(try context.fetchCount(FetchDescriptor<UserProfile>()) == 1)
    }

    @Test("A duplicated settings row is pruned and the most recently updated is kept")
    func duplicateSettingsArePrunedKeepingCurrentIntent() throws {
        let context = try StoreTestSupport.makeContext()
        let stale = UserSettings()
        stale.updatedAt = StoreTestSupport.days(-10)
        stale.defaultRestSeconds = 60
        let current = UserSettings()
        current.updatedAt = now
        current.defaultRestSeconds = 210
        context.insert(stale)
        context.insert(current)
        try context.save()

        let repository = ProfileRepository(context: context)
        let kept = try repository.settings()

        #expect(kept.defaultRestSeconds == 210)
        #expect(try context.fetchCount(FetchDescriptor<UserSettings>()) == 1)
    }

    @Test("The training snapshot carries every stored profile field")
    func trainingSnapshotMatchesStoredProfile() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)

        let profile = try repository.profile()
        profile.birthDate = calendar.date(byAdding: .year, value: -30, to: now)
        profile.biologicalSex = .female
        profile.currentWeightKg = 68.4
        profile.experience = .intermediate
        profile.techniqueConfidence = .confident
        profile.goals = [.buildStrength, .buildMuscle]
        profile.priorityGroups = [.chest]
        profile.priorityRegions = [.arms]
        profile.availableWeekdays = [.friday, .monday, .wednesday]
        profile.sessionMinutesCap = 75
        profile.cardioPreference = .afterLifting
        profile.excludedExerciseIDs = ["E-SQUAT", "E-ROW"]
        profile.mobilityLimitations = [.overheadPressing]
        profile.avoidedMovementPatterns = [.hinge]
        profile.trainingExperienceMonths = 30

        let equipment = try repository.equipmentProfile()
        equipment.availableEquipment = [.barbell, .dumbbell, .cable, .bodyWeight]
        equipment.temporarilyUnavailable = [.cable]
        try context.save()

        let snapshot = try repository.trainingProfileSnapshot(now: now, calendar: calendar)

        #expect(snapshot.experience == .intermediate)
        #expect(snapshot.techniqueConfidence == .confident)
        #expect(snapshot.goals == [.buildStrength, .buildMuscle])
        #expect(snapshot.ageYears == 30)
        #expect(snapshot.biologicalSex == .female)
        #expect(snapshot.bodyWeightKg == 68.4)
        #expect(snapshot.availableWeekdays == [.monday, .wednesday, .friday])
        #expect(snapshot.sessionMinutesCap == 75)
        #expect(snapshot.cardioPreference == .afterLifting)
        #expect(snapshot.excludedExerciseIDs == ["E-SQUAT", "E-ROW"])
        #expect(snapshot.mobilityLimitations == [.overheadPressing])
        #expect(snapshot.avoidedPatterns == [.hinge])
        #expect(snapshot.trainingExperienceMonths == 30)

        // Priority groups are the merge of explicit groups and the groups a focus region implies.
        #expect(snapshot.priorityGroups == profile.resolvedPriorityGroups)
        #expect(snapshot.priorityGroups == [.chest, .biceps, .triceps, .forearms])

        // Effective equipment is what is owned minus what is out of service.
        #expect(snapshot.availableEquipment == [.barbell, .dumbbell, .bodyWeight])
    }

    @Test("Age is computed against the injected instant, not the wall clock")
    func ageUsesTheInjectedInstant() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)
        let profile = try repository.profile()
        profile.birthDate = calendar.date(byAdding: .year, value: -25, to: now)
        try context.save()

        #expect(try repository.trainingProfileSnapshot(now: now, calendar: calendar).ageYears == 25)

        let tenYearsOn = calendar.date(byAdding: .year, value: 10, to: now)!
        #expect(try repository.trainingProfileSnapshot(now: tenYearsOn, calendar: calendar).ageYears == 35)
    }

    @Test("A missing or future birth date yields no age rather than a nonsense one")
    func missingBirthDateYieldsNoAge() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)

        #expect(try repository.trainingProfileSnapshot(now: now, calendar: calendar).ageYears == nil)

        let profile = try repository.profile()
        profile.birthDate = calendar.date(byAdding: .year, value: 1, to: now)
        try context.save()
        #expect(try repository.trainingProfileSnapshot(now: now, calendar: calendar).ageYears == nil)
    }

    @Test("Empty goals and empty availability fall back to sensible defaults")
    func emptyGoalsAndDaysFallBack() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)
        _ = try repository.profile()
        try context.save()

        let snapshot = try repository.trainingProfileSnapshot(now: now, calendar: calendar)
        #expect(snapshot.goals == [.generalFitness])
        #expect(snapshot.availableWeekdays == TrainingProfileSnapshot().availableWeekdays)
        #expect(snapshot.priorityGroups.isEmpty)
    }

    @Test("Effective equipment is never empty when everything is out of service")
    func effectiveEquipmentFallsBackToBodyweight() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)
        let equipment = try repository.equipmentProfile()
        equipment.preset = .bodyweightOnly
        equipment.availableEquipment = [.bodyWeight]
        equipment.temporarilyUnavailable = [.bodyWeight]
        try context.save()

        let resolved = ProfileRepository.effectiveEquipment(from: equipment)
        #expect(resolved == Equipment.homeMinimum)
        #expect(!resolved.isEmpty)
    }

    @Test("Effective equipment falls back to the preset when the owned list is empty")
    func effectiveEquipmentFallsBackToThePreset() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)
        let equipment = try repository.equipmentProfile()
        equipment.preset = .fullGym
        equipment.availableEquipment = []
        equipment.temporarilyUnavailable = []
        try context.save()

        let resolved = ProfileRepository.effectiveEquipment(from: equipment)
        #expect(resolved == GymSetupPreset.fullGym.equipment)
        #expect(resolved.contains(.barbell))
    }

    @Test("The session cap is clamped into the range the app will programme")
    func sessionCapIsClamped() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)
        let profile = try repository.profile()
        profile.sessionMinutesCap = 2
        try context.save()
        #expect(try repository.trainingProfileSnapshot(now: now, calendar: calendar).sessionMinutesCap == 10)

        profile.sessionMinutesCap = 9_000
        try context.save()
        #expect(try repository.trainingProfileSnapshot(now: now, calendar: calendar).sessionMinutesCap == 300)
    }

    @Test("The nutrition snapshot normalises tags and derives training days from availability")
    func nutritionSnapshotNormalisesTags() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)
        let profile = try repository.profile()
        profile.heightCm = 168
        profile.currentWeightKg = 62
        profile.targetWeightKg = 58
        profile.activityLevel = .active
        profile.allergenTags = [" Gluten", "gluten ", "PEANUT"]
        profile.intoleranceTags = ["Lactose"]
        profile.excludedFoodTags = ["Offal", ""]
        profile.mealsPerDay = 99
        profile.availableWeekdays = [.monday, .tuesday, .thursday, .friday]
        try context.save()

        let snapshot = try repository.nutritionProfileSnapshot(now: now, calendar: calendar)
        #expect(snapshot.heightCm == 168)
        #expect(snapshot.weightKg == 62)
        #expect(snapshot.targetWeightKg == 58)
        #expect(snapshot.activityLevel == .active)
        #expect(snapshot.allergenTags == ["gluten", "peanut"])
        #expect(snapshot.intoleranceTags == ["lactose"])
        #expect(snapshot.excludedFoodTags == ["offal"])
        #expect(snapshot.mealsPerDay == 10)
        #expect(snapshot.trainingDaysPerWeek == 4)
    }

    @Test("Increments come from the stored equipment row")
    func incrementsComeFromTheEquipmentRow() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)
        try repository.updateIncrements(
            barbellBarWeightKg: 15, availablePlatesKg: [20, 10, 5, 2.5, 0.5], now: now
        )

        let increments = try repository.increments()
        #expect(increments.barbellBarWeightKg == 15)
        #expect(increments.availablePlatesKg == [0.5, 2.5, 5, 10, 20])
        #expect(LoadRounding.increment(for: .barbell, profile: increments) == 1.0)
    }

    @Test("An empty plate ladder is refused rather than silently replaced")
    func emptyLadderIsRefused() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)
        #expect(throws: RepositoryError.self) {
            try repository.updateIncrements(availablePlatesKg: [], now: now)
        }
        #expect(throws: RepositoryError.self) {
            try repository.updateIncrements(availablePlatesKg: [-5, 0], now: now)
        }
    }

    @Test("An impossible body metric is refused rather than clamped")
    func impossibleBodyMetricsAreRefused() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)
        #expect(throws: RepositoryError.self) { try repository.updateBodyMetrics(heightCm: 1750, now: now) }
        #expect(throws: RepositoryError.self) { try repository.updateBodyMetrics(currentWeightKg: 0, now: now) }
        #expect(throws: RepositoryError.self) { try repository.updateBodyMetrics(heightCm: .nan, now: now) }

        // The refusal leaves the stored value alone.
        #expect(try repository.profile().heightCm == 175)
    }

    @Test("Completing onboarding is idempotent so the join date stays honest")
    func onboardingCompletionIsIdempotent() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)
        try repository.completeOnboarding(at: now)
        try repository.completeOnboarding(at: StoreTestSupport.days(5))

        #expect(try repository.profile().onboardingCompletedAt == now)
        #expect(try repository.profile().isOnboarded)
    }

    @Test("Resetting all data empties every user-owned model")
    func resetAllDataEmptiesTheStore() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = ProfileRepository(context: context)

        _ = try repository.profile()
        _ = try repository.settings()
        _ = try repository.equipmentProfile()
        StoreTestSupport.makeProgram(in: context)
        let food = StoreTestSupport.makeFood(in: context, name: "Oats")
        let session = WorkoutSession()
        context.insert(session)
        let record = ExerciseSession()
        record.exerciseID = "E-BENCH"
        record.workout = session
        context.insert(record)
        let set = SetRecord()
        set.exerciseSession = record
        context.insert(set)
        context.insert(BodyWeightEntry(date: now, weightKg: 80))
        let entry = FoodLogEntry()
        entry.dayKey = "2024-06-03"
        entry.foodID = food.id
        context.insert(entry)
        context.insert(Achievement(code: "first-workout"))
        try context.save()

        try repository.resetAllData()

        #expect(try context.fetchCount(FetchDescriptor<UserProfile>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<UserSettings>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<EquipmentProfile>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<TrainingProgram>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PlannedExercise>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WorkoutSession>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ExerciseSession>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SetRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BodyWeightEntry>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<FoodItem>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<FoodLogEntry>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Achievement>()) == 0)
    }
}

// MARK: - WorkoutRepository

@MainActor
@Suite("WorkoutRepository")
struct WorkoutRepositoryTests {

    private var now: Date { StoreTestSupport.epoch }

    private var catalog: [String: Exercise] {
        StoreTestSupport.catalog([
            StoreTestSupport.benchPress,
            StoreTestSupport.inclinePress,
            StoreTestSupport.squat,
            StoreTestSupport.row,
        ])
    }

    /// Starts a session, completes every working set at `weight × reps` and finishes it.
    @discardableResult
    private func performSession(
        _ repository: WorkoutRepository,
        template: WorkoutTemplate,
        weightKg: Double,
        reps: Int,
        startedAt: Date
    ) throws -> WorkoutSession {
        let session = try repository.startSession(from: template, catalog: catalog, now: startedAt)
        for record in session.orderedExercises {
            for set in record.orderedSets {
                try repository.completeSet(set, weightKg: weightKg, reps: reps, rir: 2, now: startedAt)
            }
        }
        try repository.finish(session, effort: .good, activeSeconds: 2_400, now: startedAt.addingTimeInterval(3_600))
        return session
    }

    @Test("A finished session still records the exercise and name the plan asked for after the template changes")
    func aFinishedSessionIsNotRewrittenByALaterTemplateEdit() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(
            in: context, templateTitle: "Push A", exercises: [("E-BENCH", 3, RepRange(8, 12))]
        )
        try context.save()
        let template = try #require(program.orderedTemplates.first)

        let session = try performSession(repository, template: template, weightKg: 60, reps: 10, startedAt: now)
        let sessionID = session.id

        // Now rewrite the plan: rename the session, swap the movement, change the dose.
        template.customTitle = "Push B"
        let planned = try #require(template.orderedExercises.first)
        planned.exerciseID = "E-INCLINE"
        planned.targetSets = 5
        planned.repRange = RepRange(4, 6)
        try context.save()

        // Re-read from the store rather than trusting the object we already hold.
        let stored = try #require(
            try context.fetch(FetchDescriptor<WorkoutSession>(predicate: #Predicate { $0.id == sessionID })).first
        )
        #expect(stored.titleSnapshot == "Push A")
        #expect(stored.status == .completed)

        let performed = try #require(stored.orderedExercises.first)
        #expect(stored.orderedExercises.count == 1)
        #expect(performed.exerciseID == "E-BENCH")
        #expect(performed.exerciseNameSnapshot == "barbell bench press")
        #expect(performed.orderedSets.count == 3)
        #expect(performed.orderedSets.allSatisfy { $0.targetReps == 12 })
        #expect(stored.plannedSetCount == 3)
        #expect(stored.completedSetCount == 3)
        #expect(stored.totalVolumeKg == 1_800)
    }

    @Test("A session started before a catalogue rename keeps the name it was started with")
    func aSessionKeepsTheNameItSnapshotted() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(in: context)
        try context.save()
        let template = try #require(program.orderedTemplates.first)

        let session = try repository.startSession(from: template, catalog: catalog, now: now)
        let record = try #require(session.orderedExercises.first)
        #expect(record.exerciseNameSnapshot == "barbell bench press")

        // A dataset update renames the exercise; a session already on disk must not change.
        let renamed = StoreTestSupport.exercise(id: "E-BENCH", name: "flat barbell press")
        _ = StoreTestSupport.catalog([renamed])
        try context.save()

        #expect(record.exerciseNameSnapshot == "barbell bench press")
    }

    @Test("An exercise missing from the catalogue still records something readable")
    func anUnknownExerciseFallsBackToItsIdentifier() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(
            in: context, exercises: [("E-RETIRED", 2, RepRange(8, 12))]
        )
        try context.save()
        let template = try #require(program.orderedTemplates.first)

        let session = try repository.startSession(from: template, catalog: catalog, now: now)
        let record = try #require(session.orderedExercises.first)
        #expect(record.exerciseNameSnapshot == "E-RETIRED")
        #expect(record.trackingMode == .weightAndReps)
    }

    @Test("Substituting mid-session records what it replaced and leaves earlier sessions untouched")
    func substitutionRecordsTheOriginalAndDoesNotTouchHistory() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(in: context)
        try context.save()
        let template = try #require(program.orderedTemplates.first)

        let earlier = try performSession(repository, template: template, weightKg: 60, reps: 10, startedAt: now)
        let earlierRecord = try #require(earlier.orderedExercises.first)

        let today = try repository.startSession(
            from: template, catalog: catalog, now: StoreTestSupport.days(3)
        )
        let record = try #require(today.orderedExercises.first)
        try repository.substitute(record, with: StoreTestSupport.inclinePress, reason: .machineOccupied)

        #expect(record.exerciseID == "E-INCLINE")
        #expect(record.exerciseNameSnapshot == "dumbbell incline bench press")
        #expect(record.substitutedFromExerciseID == "E-BENCH")
        #expect(record.substitutionReasonKey == SubstitutionReason.machineOccupied.localizationKey)

        // The finished session is history and must be untouched.
        #expect(earlierRecord.exerciseID == "E-BENCH")
        #expect(earlierRecord.exerciseNameSnapshot == "barbell bench press")
        #expect(earlierRecord.substitutedFromExerciseID == nil)
        #expect(earlierRecord.substitutionReasonKey == nil)
        #expect(earlier.orderedExercises.count == 1)
    }

    @Test("Swapping A to B to C still records 'instead of A', and swapping back to A clears it")
    func substitutionChainKeepsTheOriginalAndSwappingBackClearsIt() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(in: context)
        try context.save()
        let template = try #require(program.orderedTemplates.first)
        let session = try repository.startSession(from: template, catalog: catalog, now: now)
        let record = try #require(session.orderedExercises.first)

        try repository.substitute(record, with: StoreTestSupport.inclinePress, reason: .preferDumbbell)
        #expect(record.substitutedFromExerciseID == "E-BENCH")

        try repository.substitute(record, with: StoreTestSupport.row, reason: .machineOccupied)
        #expect(record.exerciseID == "E-ROW")
        #expect(record.substitutedFromExerciseID == "E-BENCH")

        try repository.substitute(record, with: StoreTestSupport.benchPress, reason: nil)
        #expect(record.exerciseID == "E-BENCH")
        #expect(record.substitutedFromExerciseID == nil)
    }

    @Test("Substituting keeps completed sets and only re-targets the ones not yet done")
    func substitutionKeepsCompletedSets() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(in: context)
        try context.save()
        let template = try #require(program.orderedTemplates.first)
        let session = try repository.startSession(from: template, catalog: catalog, now: now)
        let record = try #require(session.orderedExercises.first)

        let first = try #require(record.orderedSets.first)
        try repository.completeSet(first, weightKg: 60, reps: 10, now: now)

        try repository.substitute(
            record, with: StoreTestSupport.inclinePress, reason: .preferDumbbell, targetWeightKg: 24
        )

        #expect(first.isCompleted)
        #expect(first.weightKg == 60)
        #expect(first.targetWeightKg == nil)
        for set in record.orderedSets.dropFirst() {
            #expect(set.targetWeightKg == 24)
        }
    }

    @Test("Substituting for the same exercise is a no-op")
    func substitutingForTheSameExerciseDoesNothing() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(in: context)
        try context.save()
        let template = try #require(program.orderedTemplates.first)
        let session = try repository.startSession(from: template, catalog: catalog, now: now)
        let record = try #require(session.orderedExercises.first)

        try repository.substitute(record, with: StoreTestSupport.benchPress, reason: .dislike)
        #expect(record.exerciseID == "E-BENCH")
        #expect(record.substitutedFromExerciseID == nil)
        #expect(record.substitutionReasonKey == nil)
    }

    @Test("The batched history path returns exactly what the single-exercise path returns")
    func batchedHistoryMatchesTheSingleExercisePath() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(
            in: context, exercises: [("E-BENCH", 3, RepRange(8, 12)), ("E-ROW", 3, RepRange(8, 12))]
        )
        try context.save()
        let template = try #require(program.orderedTemplates.first)

        for week in 0..<4 {
            try performSession(
                repository,
                template: template,
                weightKg: 60 + Double(week) * 2.5,
                reps: 10,
                startedAt: StoreTestSupport.days(week * 7)
            )
        }

        let batched = try repository.histories(forExerciseIDs: ["E-BENCH", "E-ROW"], sessionLimit: 3)
        for exerciseID in ["E-BENCH", "E-ROW"] {
            let single = try repository.history(forExerciseID: exerciseID, sessionLimit: 3)
            #expect(batched[exerciseID] == single, "batched and single differ for \(exerciseID)")
        }

        let bench = try #require(batched["E-BENCH"])
        #expect(bench.totalSessions == 4)
        #expect(bench.performances.count == 3)
        #expect(bench.lastPerformedAt == StoreTestSupport.days(21).addingTimeInterval(3_600))
        // Newest first.
        #expect(bench.performances.map(\.date) == bench.performances.map(\.date).sorted(by: >))
        #expect(bench.bestEstimatedOneRepMaxKg != nil)
    }

    @Test("An exercise with no history returns an empty snapshot rather than nothing")
    func historyForAnUnknownExerciseIsEmpty() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)

        let snapshot = try repository.history(forExerciseID: "E-NEVER-DONE")
        #expect(snapshot.exerciseID == "E-NEVER-DONE")
        #expect(snapshot.performances.isEmpty)
        #expect(snapshot.totalSessions == 0)
        #expect(snapshot.lastPerformedAt == nil)
        #expect(snapshot.bestEstimatedOneRepMaxKg == nil)

        #expect(try repository.histories(forExerciseIDs: []).isEmpty)
        #expect(try repository.histories(forExerciseIDs: ["E-NEVER-DONE"]).count == 1)
    }

    @Test("Two slots for one exercise in one workout are merged into a single performance")
    func twoSlotsInOneWorkoutAreOnePerformance() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(
            in: context, exercises: [("E-BENCH", 3, RepRange(8, 12)), ("E-BENCH", 2, RepRange(8, 12))]
        )
        try context.save()
        let template = try #require(program.orderedTemplates.first)
        try performSession(repository, template: template, weightKg: 60, reps: 10, startedAt: now)

        let snapshot = try repository.history(forExerciseID: "E-BENCH")
        #expect(snapshot.totalSessions == 1)
        #expect(snapshot.performances.count == 1)
        #expect(snapshot.performances.first?.sets.count == 5)
        #expect(try repository.sessions(forExerciseID: "E-BENCH").count == 1)
    }

    @Test("An unfinished session does not appear in history")
    func anUnfinishedSessionIsNotHistory() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(in: context)
        try context.save()
        let template = try #require(program.orderedTemplates.first)

        let session = try repository.startSession(from: template, catalog: catalog, now: now)
        for set in session.orderedExercises.flatMap(\.orderedSets) {
            try repository.completeSet(set, weightKg: 60, reps: 10, now: now)
        }

        #expect(try repository.history(forExerciseID: "E-BENCH").totalSessions == 0)
        #expect(try repository.recentSessions().isEmpty)

        try repository.finish(session, activeSeconds: 1_200, now: now.addingTimeInterval(1_800))
        #expect(try repository.history(forExerciseID: "E-BENCH").totalSessions == 1)
        #expect(try repository.recentSessions().count == 1)
    }

    @Test("A skipped exercise still counts as planned but contributes no tonnage")
    func skippedExercisesCountAsPlannedOnly() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(
            in: context, exercises: [("E-BENCH", 3, RepRange(8, 12)), ("E-ROW", 2, RepRange(8, 12))]
        )
        try context.save()
        let template = try #require(program.orderedTemplates.first)
        let session = try repository.startSession(from: template, catalog: catalog, now: now)

        let bench = try #require(session.orderedExercises.first)
        let row = try #require(session.orderedExercises.last)
        for set in bench.orderedSets {
            try repository.completeSet(set, weightKg: 60, reps: 10, now: now)
        }
        try repository.setSkipped(true, on: row)
        try repository.finish(session, activeSeconds: 1_800, now: now.addingTimeInterval(3_600))

        #expect(session.plannedSetCount == 5)
        #expect(session.completedSetCount == 3)
        #expect(session.totalVolumeKg == 1_800)

        let outcome = repository.sessionOutcome(for: session, catalog: catalog)
        #expect(outcome.plannedSets == 5)
        #expect(outcome.completedSets == 3)
        #expect(outcome.skippedExerciseIDs == ["E-ROW"])
    }

    @Test("Only tracking modes where weight times reps means something contribute to tonnage")
    func tonnageExcludesAssistedAndDurationWork() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let assisted = StoreTestSupport.exercise(
            id: "E-ASSISTED", name: "assisted pull-up", equipment: .assisted,
            bodyPart: .back, target: .lats, synergist: .biceps
        ) { $0.trackingMode = .assistedBodyweight }
        let program = StoreTestSupport.makeProgram(
            in: context, exercises: [("E-BENCH", 2, RepRange(8, 12)), ("E-ASSISTED", 2, RepRange(8, 12))]
        )
        try context.save()
        let template = try #require(program.orderedTemplates.first)
        let sessionCatalog = StoreTestSupport.catalog([StoreTestSupport.benchPress, assisted])

        let session = try repository.startSession(from: template, catalog: sessionCatalog, now: now)
        for record in session.orderedExercises {
            for set in record.orderedSets {
                try repository.completeSet(set, weightKg: 40, reps: 10, now: now)
            }
        }
        try repository.finish(session, activeSeconds: 1_200, now: now.addingTimeInterval(2_400))

        // Bench only: 2 × 40 × 10. The assistance the machine removed is not tonnage the user lifted.
        #expect(session.totalVolumeKg == 800)
        #expect(session.completedSetCount == 4)
    }

    @Test("Finishing with no reported timer falls back to the wall clock rather than recording no time")
    func finishFallsBackToWallClock() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let session = try repository.startEmptySession(title: "Just train", now: now)

        try repository.finish(session, now: now.addingTimeInterval(2_700))
        #expect(session.activeSeconds == 2_700)
        #expect(session.endedAt == now.addingTimeInterval(2_700))
        #expect(session.status == .completed)
    }

    @Test("A reported timer wins over the wall clock so background time never inflates a session")
    func reportedTimerWinsOverWallClock() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let session = try repository.startEmptySession(title: "Just train", now: now)
        try repository.addActiveSeconds(600, to: session)

        try repository.finish(session, activeSeconds: 1_500, now: now.addingTimeInterval(86_400))
        #expect(session.activeSeconds == 1_500)
    }

    @Test("Only one session can be in progress; older ones are stood down rather than resumed")
    func onlyTheNewestSessionStaysInProgress() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let older = try repository.startEmptySession(title: "Yesterday", now: StoreTestSupport.days(-1))
        let newer = try repository.startEmptySession(title: "Today", now: now)

        let resumed = try #require(try repository.inProgressSession())
        #expect(resumed.id == newer.id)
        #expect(older.status == .skipped)
        #expect(try repository.inProgressSession()?.id == newer.id)
    }

    @Test("Progression state is created on first use and written back from a snapshot")
    func progressionStateRoundTrips() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)

        let snapshots = try repository.progressionSnapshots(forExerciseIDs: ["E-BENCH"])
        #expect(snapshots["E-BENCH"]?.needsCalibration == true)
        #expect(snapshots["E-BENCH"]?.workingWeightKg == nil)

        var updated = try #require(snapshots["E-BENCH"])
        updated.workingWeightKg = 62.5
        updated.repRange = RepRange(6, 10)
        updated.consecutiveSuccesses = 2
        updated.needsCalibration = false
        try repository.apply(updated, decision: Explanation("progression.increase", ["2.5"]), now: now)

        let stored = try repository.progressionState(forExerciseID: "E-BENCH")
        #expect(stored.workingWeightKg == 62.5)
        #expect(stored.repRange == RepRange(6, 10))
        #expect(stored.consecutiveSuccesses == 2)
        #expect(stored.needsCalibration == false)
        #expect(stored.lastDecisionKey == "progression.increase")
        #expect(stored.lastDecisionArguments == ["2.5"])
        #expect(try context.fetchCount(FetchDescriptor<ProgressionState>()) == 1)
    }

    @Test("Discarding a session removes it and its sets entirely")
    func discardingASessionRemovesEverything() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let program = StoreTestSupport.makeProgram(in: context)
        try context.save()
        let template = try #require(program.orderedTemplates.first)
        let session = try repository.startSession(from: template, catalog: catalog, now: now)

        try repository.discard(session)
        #expect(try context.fetchCount(FetchDescriptor<WorkoutSession>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ExerciseSession>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SetRecord>()) == 0)
    }

    @Test("An out-of-range load is refused; a negative one is clamped to zero")
    func setLoadsAreValidated() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = WorkoutRepository(context: context)
        let session = try repository.startEmptySession(title: "Just train", now: now)
        let record = try repository.addExercise(StoreTestSupport.benchPress, to: session, sets: 1)
        let set = try #require(record.orderedSets.first)

        #expect(throws: RepositoryError.self) {
            try repository.completeSet(set, weightKg: 5_000, reps: 1, now: now)
        }
        try repository.completeSet(set, weightKg: -20, reps: 5, now: now)
        #expect(set.weightKg == 0)
        #expect(set.reps == 5)
    }
}

// MARK: - NutritionRepository

@MainActor
@Suite("NutritionRepository")
struct NutritionRepositoryTests {

    private var now: Date { StoreTestSupport.epoch }
    private var calendar: Calendar { StoreTestSupport.utcCalendar }
    private let today = "2024-06-03"
    private let yesterday = "2024-06-02"

    @Test("A logged portion stores a complete macro snapshot that survives deleting the food")
    func aLogEntrySnapshotSurvivesTheFood() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let food = StoreTestSupport.makeFood(
            in: context, name: "Rolled oats", kcal: 380, protein: 13, carbs: 60, fat: 7, fiber: 10
        )
        try context.save()

        let entry = try repository.addLogEntry(
            food: food, quantity: 50, unit: .grams, slot: .breakfast, dayKey: today, now: now
        )

        #expect(entry.foodNameSnapshot == "Rolled oats")
        #expect(entry.macrosSnapshot.kilocalories == 190)
        #expect(entry.macrosSnapshot.proteinG == 6.5)
        #expect(entry.macrosSnapshot.carbsG == 30)
        #expect(entry.macrosSnapshot.fatG == 3.5)
        #expect(entry.micronutrientsSnapshot.fiberG == 5)
        #expect(food.timesLogged == 1)
        #expect(food.lastLoggedAt == now)

        try repository.deleteFood(food)

        #expect(try context.fetchCount(FetchDescriptor<FoodItem>()) == 0)
        let stored = try #require(try repository.dayLog(for: today).first)
        #expect(stored.foodID == nil)
        #expect(stored.foodNameSnapshot == "Rolled oats")
        #expect(stored.macrosSnapshot.kilocalories == 190)
        #expect(stored.micronutrientsSnapshot.fiberG == 5)
    }

    @Test("Editing a food's nutrition does not rewrite what was already logged")
    func editingAFoodDoesNotRewriteHistory() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let food = StoreTestSupport.makeFood(in: context, name: "Yoghurt", kcal: 60, protein: 10, carbs: 4, fat: 0)
        try context.save()

        let entry = try repository.addLogEntry(
            food: food, quantity: 200, unit: .grams, slot: .breakfast, dayKey: today, now: now
        )
        #expect(entry.macrosSnapshot.kilocalories == 120)

        try repository.updateFood(food, kilocaloriesPer100: 300, now: now)
        #expect(entry.macrosSnapshot.kilocalories == 120)
    }

    @Test("A portion in pieces uses the food's piece weight")
    func portionsInPiecesUseThePieceWeight() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let egg = StoreTestSupport.makeFood(
            in: context, name: "Egg", kcal: 140, protein: 12, carbs: 1, fat: 10,
            fiber: nil, gramsPerPiece: 50
        )
        try context.save()

        let entry = try repository.addLogEntry(
            food: egg, quantity: 3, unit: .piece, slot: .breakfast, dayKey: today, now: now
        )
        // Three 50 g eggs is 150 g, so 1.5× the per-100 g basis.
        #expect(entry.macrosSnapshot.kilocalories == 210)
        #expect(entry.macrosSnapshot.proteinG == 18)
        #expect(entry.micronutrientsSnapshot.fiberG == nil)
    }

    @Test("A zero portion is refused rather than logged as nothing")
    func zeroPortionsAreRefused() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let food = StoreTestSupport.makeFood(in: context, name: "Oats")
        try context.save()

        #expect(throws: RepositoryError.self) {
            try repository.addLogEntry(food: food, quantity: 0, slot: .breakfast, dayKey: today, now: now)
        }
        #expect(try repository.dayLog(for: today).isEmpty)
    }

    @Test("Copying yesterday's meal duplicates exactly that meal's entries and nothing else")
    func copyingYesterdayDuplicatesTheRightEntries() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let oats = StoreTestSupport.makeFood(in: context, name: "Oats", kcal: 380, protein: 13, carbs: 60, fat: 7)
        let milk = StoreTestSupport.makeFood(in: context, name: "Milk", kcal: 50, protein: 3.4, carbs: 5, fat: 2)
        let chicken = StoreTestSupport.makeFood(in: context, name: "Chicken", kcal: 165, protein: 31, carbs: 0, fat: 4)
        try context.save()

        try repository.addLogEntry(food: oats, quantity: 50, slot: .breakfast, dayKey: yesterday, now: now)
        try repository.addLogEntry(food: milk, quantity: 200, slot: .breakfast, dayKey: yesterday, now: now)
        try repository.addLogEntry(food: chicken, quantity: 150, slot: .lunch, dayKey: yesterday, now: now)

        let copied = try repository.copyYesterdayMeal(
            .breakfast, to: today, calendar: calendar, now: now
        )

        #expect(copied.count == 2)
        let todaysLog = try repository.dayLog(for: today)
        #expect(todaysLog.count == 2)
        #expect(todaysLog.allSatisfy { $0.mealSlot == .breakfast })
        #expect(todaysLog.map(\.foodNameSnapshot) == ["Oats", "Milk"])
        #expect(todaysLog.map(\.orderIndex) == [0, 1])

        // Snapshots are copied verbatim, not recomputed.
        let yesterdaysBreakfast = try repository.dayLog(for: yesterday).filter { $0.mealSlot == .breakfast }
        #expect(todaysLog.map(\.macrosSnapshot) == yesterdaysBreakfast.map(\.macrosSnapshot))

        // Yesterday is untouched.
        #expect(try repository.dayLog(for: yesterday).count == 3)
    }

    @Test("Copying the same meal twice appends rather than overwriting")
    func copyingTwiceAppends() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let oats = StoreTestSupport.makeFood(in: context, name: "Oats")
        try context.save()
        try repository.addLogEntry(food: oats, quantity: 50, slot: .breakfast, dayKey: yesterday, now: now)

        try repository.copyYesterdayMeal(.breakfast, to: today, calendar: calendar, now: now)
        try repository.copyYesterdayMeal(.breakfast, to: today, calendar: calendar, now: now)

        let log = try repository.dayLog(for: today)
        #expect(log.count == 2)
        #expect(log.map(\.orderIndex) == [0, 1])
    }

    @Test("Copying a day with nothing in it creates nothing")
    func copyingAnEmptyDayCreatesNothing() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let copied = try repository.copyYesterdayMeal(.breakfast, to: today, calendar: calendar, now: now)
        #expect(copied.isEmpty)
        #expect(try repository.dayLog(for: today).isEmpty)
    }

    @Test("A saved meal computes its nutrition from its items")
    func savedMealNutritionIsComputedFromItsItems() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let oats = StoreTestSupport.makeFood(in: context, name: "Oats", kcal: 380, protein: 13, carbs: 60, fat: 7, fiber: 10)
        let egg = StoreTestSupport.makeFood(
            in: context, name: "Egg", kcal: 140, protein: 12, carbs: 1, fat: 10, fiber: nil, gramsPerPiece: 50
        )
        try context.save()

        let meal = try repository.createSavedMeal(
            name: "Usual breakfast",
            defaultSlot: .breakfast,
            items: [
                NutritionPortionInput(foodID: oats.id, quantity: 50, unit: .grams),
                NutritionPortionInput(foodID: egg.id, quantity: 2, unit: .piece),
            ],
            now: now
        )

        let totals = try repository.nutrition(of: meal)
        // 50 g oats (190 kcal) + 100 g of egg (140 kcal).
        #expect(totals.macros.kilocalories == 330)
        #expect(totals.macros.proteinG == 18.5)
        #expect(totals.micronutrients.fiberG == 5)
        #expect(meal.items.count == 2)
    }

    @Test("Logging a saved meal writes one entry per item and skips foods that were deleted")
    func loggingASavedMealSkipsDeletedFoods() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let oats = StoreTestSupport.makeFood(in: context, name: "Oats", kcal: 380, protein: 13, carbs: 60, fat: 7)
        let milk = StoreTestSupport.makeFood(in: context, name: "Milk", kcal: 50, protein: 3.4, carbs: 5, fat: 2)
        try context.save()

        let meal = try repository.createSavedMeal(
            name: "Usual breakfast",
            defaultSlot: .breakfast,
            items: [
                NutritionPortionInput(foodID: oats.id, quantity: 50),
                NutritionPortionInput(foodID: milk.id, quantity: 200),
            ],
            now: now
        )

        let first = try repository.logSavedMeal(meal, dayKey: today, now: now)
        #expect(first.count == 2)
        #expect(meal.timesUsed == 1)

        // Delete one of the foods, then log the meal again on another day.
        try repository.deleteFood(milk, force: true)
        let second = try repository.logSavedMeal(meal, dayKey: "2024-06-04", now: now)

        // A missing food is skipped, never logged as a silent zero.
        #expect(second.count == 1)
        #expect(second.first?.foodNameSnapshot == "Oats")
        #expect(try repository.dayLog(for: "2024-06-04").count == 1)
        #expect(try repository.totals(for: "2024-06-04").macros.kilocalories == 190)
    }

    @Test("A recipe's per-serving nutrition is its ingredients divided by its serving count")
    func recipePerServingNutrition() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let beans = StoreTestSupport.makeFood(in: context, name: "Beans", kcal: 100, protein: 6, carbs: 15, fat: 1, fiber: 6)
        let mince = StoreTestSupport.makeFood(in: context, name: "Mince", kcal: 200, protein: 20, carbs: 0, fat: 12, fiber: 0)
        try context.save()

        let recipe = try repository.createRecipe(
            name: "Chilli",
            servingsCount: 4,
            ingredients: [
                NutritionPortionInput(foodID: beans.id, quantity: 400),
                NutritionPortionInput(foodID: mince.id, quantity: 200),
            ],
            now: now
        )

        let nutrition = try repository.nutrition(of: recipe)
        #expect(nutrition.servingsCount == 4)
        #expect(nutrition.total.macros.kilocalories == 800)
        #expect(nutrition.total.macros.proteinG == 64)
        #expect(nutrition.total.micronutrients.fiberG == 24)
        #expect(nutrition.perServing.macros.kilocalories == 200)
        #expect(nutrition.perServing.macros.proteinG == 16)
        #expect(nutrition.perServing.micronutrients.fiberG == 6)
    }

    @Test("Correcting an ingredient immediately corrects every serving figure")
    func recipeNutritionIsRecomputedNotStored() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let beans = StoreTestSupport.makeFood(in: context, name: "Beans", kcal: 100, protein: 6, carbs: 15, fat: 1)
        try context.save()

        let recipe = try repository.createRecipe(
            name: "Beans",
            servingsCount: 2,
            ingredients: [NutritionPortionInput(foodID: beans.id, quantity: 400)],
            now: now
        )
        #expect(try repository.nutrition(of: recipe).perServing.macros.kilocalories == 200)

        try repository.updateFood(beans, kilocaloriesPer100: 150, now: now)
        #expect(try repository.nutrition(of: recipe).perServing.macros.kilocalories == 300)
    }

    @Test("A recipe is logged as one line carrying the servings eaten")
    func aRecipeIsLoggedAsOneLine() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let beans = StoreTestSupport.makeFood(in: context, name: "Beans", kcal: 100, protein: 6, carbs: 15, fat: 1)
        try context.save()
        let recipe = try repository.createRecipe(
            name: "Chilli",
            servingsCount: 4,
            ingredients: [NutritionPortionInput(foodID: beans.id, quantity: 400)],
            now: now
        )

        let entry = try repository.logRecipeServing(recipe, servings: 2, to: .dinner, dayKey: today, now: now)

        #expect(try repository.dayLog(for: today).count == 1)
        #expect(entry.foodNameSnapshot == "Chilli")
        #expect(entry.unit == .serving)
        #expect(entry.quantity == 2)
        #expect(entry.recipeID == recipe.id)
        #expect(entry.foodID == nil)
        // 400 g of beans is 400 kcal over four servings; two servings is 200 kcal.
        #expect(entry.macrosSnapshot.kilocalories == 200)
        #expect(recipe.timesUsed == 1)
    }

    @Test("A recipe whose foods are all gone reports zero rather than crashing")
    func recipeWithMissingFoodsReportsZero() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let beans = StoreTestSupport.makeFood(in: context, name: "Beans", kcal: 100, protein: 6, carbs: 15, fat: 1)
        try context.save()
        let recipe = try repository.createRecipe(
            name: "Chilli",
            servingsCount: 4,
            ingredients: [NutritionPortionInput(foodID: beans.id, quantity: 400)],
            now: now
        )
        try repository.deleteFood(beans, force: true)

        let nutrition = try repository.nutrition(of: recipe)
        #expect(nutrition.total.macros == .zero)
        #expect(nutrition.perServing.macros == .zero)
    }

    @Test("An impossible serving count is refused")
    func impossibleServingCountsAreRefused() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let beans = StoreTestSupport.makeFood(in: context, name: "Beans")
        try context.save()

        #expect(throws: RepositoryError.self) {
            try repository.createRecipe(
                name: "Chilli", servingsCount: 0,
                ingredients: [NutritionPortionInput(foodID: beans.id, quantity: 100)], now: now
            )
        }
        #expect(throws: RepositoryError.self) {
            try repository.createRecipe(name: "Chilli", servingsCount: 4, ingredients: [], now: now)
        }
    }

    @Test("Deleting a food still referenced by a saved meal is reported, not silently applied")
    func deletingAReferencedFoodIsReported() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let oats = StoreTestSupport.makeFood(in: context, name: "Oats")
        try context.save()
        _ = try repository.createSavedMeal(
            name: "Usual breakfast",
            defaultSlot: .breakfast,
            items: [NutritionPortionInput(foodID: oats.id, quantity: 50)],
            now: now
        )

        #expect(throws: RepositoryError.stillReferenced(entity: "foodItem", referenceCount: 1)) {
            try repository.deleteFood(oats)
        }
        #expect(try context.fetchCount(FetchDescriptor<FoodItem>()) == 1)

        try repository.deleteFood(oats, force: true)
        #expect(try context.fetchCount(FetchDescriptor<FoodItem>()) == 0)
        let item = try #require(try context.fetch(FetchDescriptor<SavedMealItem>()).first)
        #expect(item.foodID == nil)
        #expect(item.foodNameSnapshot == "Oats")
    }

    @Test("A portion edit is exact while the food exists and rescaled once it is gone")
    func portionEditsRescaleWhenTheFoodIsGone() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let oats = StoreTestSupport.makeFood(in: context, name: "Oats", kcal: 380, protein: 13, carbs: 60, fat: 7)
        try context.save()
        let entry = try repository.addLogEntry(
            food: oats, quantity: 50, slot: .breakfast, dayKey: today, now: now
        )

        try repository.updatePortion(of: entry, quantity: 100)
        #expect(entry.macrosSnapshot.kilocalories == 380)

        try repository.deleteFood(oats)
        try repository.updatePortion(of: entry, quantity: 50)
        #expect(entry.macrosSnapshot.kilocalories == 190)
        #expect(entry.quantity == 50)
    }

    @Test("A portion edit that changes the unit is refused once the food is gone")
    func portionUnitChangesAreRefusedWithoutTheFood() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let oats = StoreTestSupport.makeFood(in: context, name: "Oats", gramsPerPiece: 30)
        try context.save()
        let entry = try repository.addLogEntry(
            food: oats, quantity: 50, unit: .grams, slot: .breakfast, dayKey: today, now: now
        )
        let before = entry.macrosSnapshot
        try repository.deleteFood(oats)

        #expect(throws: RepositoryError.notFound(entity: "foodItem")) {
            try repository.updatePortion(of: entry, quantity: 2, unit: .piece)
        }
        #expect(entry.macrosSnapshot == before)
        #expect(entry.unit == .grams)
    }

    @Test("A day's totals add every entry, break down by slot and include water")
    func dailyTotals() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let oats = StoreTestSupport.makeFood(in: context, name: "Oats", kcal: 380, protein: 13, carbs: 60, fat: 7, fiber: 10)
        let chicken = StoreTestSupport.makeFood(in: context, name: "Chicken", kcal: 200, protein: 30, carbs: 0, fat: 8, fiber: 0)
        try context.save()

        try repository.addLogEntry(food: oats, quantity: 100, slot: .breakfast, dayKey: today, now: now)
        try repository.addLogEntry(food: chicken, quantity: 200, slot: .lunch, dayKey: today, now: now)
        try repository.addWater(milliliters: 500, dayKey: today, now: now)
        try repository.addWater(milliliters: 250, dayKey: today, now: now)

        let totals = try repository.totals(for: today)
        #expect(totals.entryCount == 2)
        #expect(totals.macros.kilocalories == 780)
        #expect(totals.macros.proteinG == 73)
        #expect(totals.micronutrients.fiberG == 10)
        #expect(totals.macrosBySlot[.breakfast]?.kilocalories == 380)
        #expect(totals.macrosBySlot[.lunch]?.kilocalories == 400)
        #expect(totals.macrosBySlot[.dinner] == nil)
        #expect(totals.waterMilliliters == 750)
    }

    @Test("A day with nothing logged totals to zero rather than failing")
    func emptyDayTotalsToZero() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let totals = try repository.totals(for: today)
        #expect(totals.entryCount == 0)
        #expect(totals.macros == .zero)
        #expect(totals.waterMilliliters == 0)
    }

    @Test("Progress against no target reports zero rather than dividing by zero")
    func progressWithoutATargetDoesNotDivideByZero() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let oats = StoreTestSupport.makeFood(in: context, name: "Oats", kcal: 380, protein: 13, carbs: 60, fat: 7)
        try context.save()
        try repository.addLogEntry(food: oats, quantity: 100, slot: .breakfast, dayKey: today, now: now)

        let progress = try repository.progress(for: today)
        #expect(progress.target == nil)
        #expect(progress.energyProgress == 0)
        #expect(progress.energyProgress.isFinite)
        #expect(progress.remaining == .zero)
        #expect(progress.consumed.kilocalories == 380)
    }

    @Test("Progress against a target reports what is left, negative when over")
    func progressAgainstATarget() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let oats = StoreTestSupport.makeFood(in: context, name: "Oats", kcal: 380, protein: 13, carbs: 60, fat: 7)
        try context.save()
        _ = try repository.replaceActiveTarget(
            kilocalories: 2_000, proteinG: 150, carbsG: 200, fatG: 65,
            isManualOverride: true, reason: Explanation("nutrition.target.manual"),
            wasAutomatic: false, now: now
        )
        // 800 g of oats is 3,040 kcal — well past the target.
        try repository.addLogEntry(food: oats, quantity: 800, slot: .dinner, dayKey: today, now: now)

        let progress = try repository.progress(for: today)
        #expect(progress.target?.kilocalories == 2_000)
        #expect(progress.consumed.kilocalories == 3_040)
        #expect(progress.remaining.kilocalories == -1_040)
        #expect(abs(progress.energyProgress - 1.52) < 1e-9)
    }

    @Test("Replacing the target journals the change and carries micronutrient goals forward")
    func replacingTheTargetJournalsTheChange() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)

        var goals = Micronutrients.unknown
        goals.fiberG = 35
        let first = try repository.replaceActiveTarget(
            kilocalories: 2_400, proteinG: 160, carbsG: 260, fatG: 80,
            isManualOverride: false, reason: Explanation("nutrition.target.initial"),
            wasAutomatic: true, micronutrientGoals: goals, now: now
        )
        #expect(first.isActive)
        #expect(first.micronutrientGoals.fiberG == 35)

        let second = try repository.replaceActiveTarget(
            kilocalories: 2_200, proteinG: 165, carbsG: 220, fatG: 75,
            isManualOverride: false, reason: Explanation("nutrition.target.adjusted", ["-200"]),
            wasAutomatic: true, trendWeightKg: 81.2, now: StoreTestSupport.days(14)
        )

        #expect(second.isActive)
        #expect(first.isActive == false)
        #expect(try repository.activeTarget()?.kilocalories == 2_200)
        // Micronutrient goals are a separate decision and survive a calorie change.
        #expect(second.micronutrientGoals.fiberG == 35)

        let history = try repository.targetHistory()
        #expect(history.count == 2)
        let newest = try #require(history.first)
        #expect(newest.previousKilocalories == 2_400)
        #expect(newest.newKilocalories == 2_200)
        #expect(newest.reasonKey == "nutrition.target.adjusted")
        #expect(newest.reasonArguments == ["-200"])
        #expect(newest.wasAutomatic)
        #expect(newest.trendWeightKg == 81.2)
        // The superseded target is deactivated, never deleted.
        #expect(try context.fetchCount(FetchDescriptor<DailyNutritionTarget>()) == 2)
    }

    @Test("A daily energy target outside the range the app will build is refused")
    func impossibleEnergyTargetsAreRefused() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        #expect(throws: RepositoryError.self) {
            try repository.replaceActiveTarget(
                kilocalories: 100, proteinG: 150, carbsG: 200, fatG: 65,
                isManualOverride: true, reason: Explanation("test"), wasAutomatic: false, now: now
            )
        }
        #expect(try repository.activeTarget() == nil)
    }

    @Test("Water entries are clamped into a plausible single-serving range")
    func waterEntriesAreClamped() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let tiny = try repository.addWater(milliliters: 0, dayKey: today, now: now)
        let huge = try repository.addWater(milliliters: 99_999, dayKey: today, now: now)

        #expect(tiny.milliliters == 1)
        #expect(huge.milliliters == 5_000)
        #expect(try repository.waterTotal(for: today) == 5_001)
        #expect(try repository.waterTotal(for: yesterday) == 0)
    }

    @Test("A custom food with no stated energy derives it from its macros")
    func customFoodEnergyIsDerivedFromMacros() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let food = try repository.createCustomFood(
            name: "Home-made bar",
            kilocaloriesPer100: 0,
            proteinGPer100: 20,
            carbsGPer100: 30,
            fatGPer100: 10,
            now: now
        )
        // 4/4/9 kcal per gram.
        #expect(food.kilocaloriesPer100 == 290)
    }

    @Test("A macro density above 100 g per 100 g is clamped and an absurd energy density is refused")
    func customFoodDensitiesAreBounded() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)

        let food = try repository.createCustomFood(
            name: "Protein isolate",
            kilocaloriesPer100: 380,
            proteinGPer100: 400,
            carbsGPer100: -5,
            fatGPer100: 1,
            now: now
        )
        #expect(food.proteinGPer100 == 100)
        #expect(food.carbsGPer100 == 0)

        #expect(throws: RepositoryError.self) {
            try repository.createCustomFood(
                name: "Impossible", kilocaloriesPer100: 5_000,
                proteinGPer100: 1, carbsGPer100: 1, fatGPer100: 1, now: now
            )
        }
        #expect(throws: RepositoryError.self) {
            try repository.createCustomFood(
                name: "  ", kilocaloriesPer100: 100,
                proteinGPer100: 1, carbsGPer100: 1, fatGPer100: 1, now: now
            )
        }
    }

    @Test("A built-in food is reference data and cannot be edited in place")
    func builtInFoodsAreNotEditable() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let food = StoreTestSupport.makeFood(in: context, name: "Bundled oats", source: .builtIn)
        try context.save()

        #expect(throws: RepositoryError.notEditable(entity: "foodItem")) {
            try repository.updateFood(food, name: "My oats", now: now)
        }
        #expect(food.name == "Bundled oats")
    }

    @Test("A day's log is ordered by meal slot and then by the user's own ordering")
    func dayLogIsOrderedBySlotThenIndex() throws {
        let context = try StoreTestSupport.makeContext()
        let repository = NutritionRepository(context: context)
        let food = StoreTestSupport.makeFood(in: context, name: "Oats")
        try context.save()

        try repository.addLogEntry(food: food, quantity: 10, slot: .dinner, dayKey: today, now: now)
        try repository.addLogEntry(food: food, quantity: 20, slot: .breakfast, dayKey: today, now: now)
        try repository.addLogEntry(food: food, quantity: 30, slot: .snacks, dayKey: today, now: now)
        try repository.addLogEntry(food: food, quantity: 40, slot: .breakfast, dayKey: today, now: now)

        let log = try repository.dayLog(for: today)
        #expect(log.map(\.mealSlot) == [.breakfast, .breakfast, .dinner, .snacks])
        #expect(log.map(\.quantity) == [20, 40, 10, 30])

        let bySlot = try repository.dayLogBySlot(for: today)
        #expect(bySlot.keys.count == MealSlot.allCases.count)
        #expect(bySlot[.lunch]?.isEmpty == true)
        #expect(bySlot[.breakfast]?.count == 2)
    }
}
