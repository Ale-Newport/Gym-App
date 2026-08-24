import Foundation
import SwiftData
import Testing

@testable import GymApp

// MARK: - Fixtures and a CSV reader

@MainActor
private enum BackupFixture {

    static let day = "2024-06-03"

    /// A store holding at least one row of everything a full backup carries.
    static func populate(_ context: ModelContext) throws {
        let now = StoreTestSupport.epoch

        let profile = UserProfile()
        profile.name = "Alex"
        profile.heightCm = 178
        profile.currentWeightKg = 78.4
        profile.targetWeightKg = 82
        profile.experience = .intermediate
        profile.goals = [.buildMuscle, .buildStrength]
        profile.priorityGroups = [.chest, .back]
        profile.availableWeekdays = [.monday, .wednesday, .friday]
        profile.allergenTags = ["peanut"]
        profile.createdAt = StoreTestSupport.days(-365)
        profile.onboardingCompletedAt = StoreTestSupport.days(-364)
        context.insert(profile)

        let settings = UserSettings()
        settings.weightUnit = .pounds
        settings.defaultRestSeconds = 210
        settings.nutritionEnabled = true
        context.insert(settings)

        let equipment = EquipmentProfile()
        equipment.preset = .homeGym
        equipment.availableEquipment = [.barbell, .dumbbell, .bodyWeight]
        equipment.barbellBarWeightKg = 20
        context.insert(equipment)

        for (index, id) in ["E-BENCH", "E-ROW"].enumerated() {
            let preference = ExercisePreference(exerciseID: id)
            preference.isFavorite = index == 0
            preference.feedback = index == 0 ? .love : .neutral
            preference.timesPerformed = 12 + index
            context.insert(preference)
        }

        let program = StoreTestSupport.makeProgram(
            in: context,
            title: "Upper / Lower",
            templateTitle: "Upper A",
            exercises: [("E-BENCH", 3, RepRange(8, 12)), ("E-ROW", 3, RepRange(8, 12))]
        )
        let lower = WorkoutTemplate()
        lower.customTitle = "Lower A"
        lower.orderIndex = 1
        lower.program = program
        context.insert(lower)
        let squat = PlannedExercise()
        squat.exerciseID = "E-SQUAT"
        squat.targetSets = 4
        squat.template = lower
        context.insert(squat)

        let version = ProgramVersion()
        version.versionNumber = 1
        version.reasonKey = "program.version.created"
        version.createdAt = now
        version.program = program
        context.insert(version)

        for week in 0..<2 {
            let session = WorkoutSession()
            session.titleSnapshot = "Upper A"
            session.startedAt = StoreTestSupport.days(week * 7)
            session.endedAt = StoreTestSupport.days(week * 7).addingTimeInterval(3_600)
            session.status = .completed
            session.templateID = program.orderedTemplates.first?.id
            session.programID = program.id
            session.focusGroups = [.chest, .triceps]
            session.activeSeconds = 2_400
            session.notes = "solid"
            context.insert(session)

            let record = ExerciseSession()
            record.exerciseID = "E-BENCH"
            record.exerciseNameSnapshot = "barbell bench press"
            record.orderIndex = 0
            record.trackingMode = .weightAndReps
            record.workout = session
            context.insert(record)

            var volume = 0.0
            for setIndex in 0..<3 {
                let set = SetRecord()
                set.setIndex = setIndex
                set.kind = .working
                set.targetReps = 12
                set.weightKg = 60 + Double(week) * 2.5
                set.reps = 10
                set.rir = 2
                set.isCompleted = true
                set.completedAt = StoreTestSupport.days(week * 7).addingTimeInterval(Double(setIndex) * 200)
                set.exerciseSession = record
                context.insert(set)
                volume += set.volumeKg
            }
            session.plannedSetCount = 3
            session.completedSetCount = 3
            session.totalVolumeKg = volume
        }

        for (index, kind) in [PersonalRecordKind.heaviestWeight, .estimatedOneRepMax].enumerated() {
            let record = PersonalRecord()
            record.exerciseID = "E-BENCH"
            record.exerciseNameSnapshot = "barbell bench press"
            record.kind = kind
            record.value = 100 + Double(index) * 5
            record.achievedAt = now
            context.insert(record)
        }

        for offset in 0..<3 {
            let entry = BodyWeightEntry(
                date: StoreTestSupport.days(-offset), weightKg: 78 + Double(offset) * 0.2
            )
            entry.note = offset == 0 ? "post-holiday" : nil
            context.insert(entry)
        }

        let recovery = RecoveryEntry()
        recovery.date = now
        recovery.energy = 4
        recovery.sleepHours = 7.5
        recovery.soreGroups = [.chest]
        context.insert(recovery)

        let state = ProgressionState(exerciseID: "E-BENCH")
        state.workingWeightKg = 62.5
        state.repRange = RepRange(8, 12)
        state.needsCalibration = false
        state.consecutiveSuccesses = 2
        context.insert(state)

        let oats = StoreTestSupport.makeFood(
            in: context, name: "Rolled oats", kcal: 380, protein: 13, carbs: 60, fat: 7, fiber: 10
        )
        let milk = StoreTestSupport.makeFood(
            in: context, name: "Milk", kcal: 50, protein: 3.4, carbs: 5, fat: 2, fiber: 0
        )

        for (index, food) in [oats, milk].enumerated() {
            let entry = FoodLogEntry()
            entry.dayKey = day
            entry.loggedAt = now.addingTimeInterval(Double(index) * 60)
            entry.mealSlot = .breakfast
            entry.orderIndex = index
            entry.foodID = food.id
            entry.foodNameSnapshot = food.name
            entry.quantity = index == 0 ? 50 : 200
            entry.unit = .grams
            entry.macrosSnapshot = food.macros(forQuantity: entry.quantity, unit: .grams)
            entry.micronutrientsSnapshot = food.micronutrients(forQuantity: entry.quantity, unit: .grams)
            context.insert(entry)
        }

        let meal = SavedMeal()
        meal.name = "Usual breakfast"
        meal.defaultSlot = .breakfast
        meal.timesUsed = 4
        meal.createdAt = now
        context.insert(meal)
        for (index, food) in [oats, milk].enumerated() {
            let item = SavedMealItem()
            item.foodID = food.id
            item.foodNameSnapshot = food.name
            item.quantity = index == 0 ? 50 : 200
            item.orderIndex = index
            item.meal = meal
            context.insert(item)
        }

        let recipe = Recipe()
        recipe.name = "Overnight oats"
        recipe.servingsCount = 2
        recipe.createdAt = now
        recipe.tags = ["breakfast"]
        context.insert(recipe)
        for (index, food) in [oats, milk].enumerated() {
            let ingredient = RecipeIngredient()
            ingredient.foodID = food.id
            ingredient.foodNameSnapshot = food.name
            ingredient.quantity = index == 0 ? 100 : 300
            ingredient.orderIndex = index
            ingredient.recipe = recipe
            context.insert(ingredient)
        }

        let target = DailyNutritionTarget()
        target.effectiveFrom = now
        target.kilocalories = 2_600
        target.proteinG = 170
        target.carbsG = 280
        target.fatG = 85
        target.isActive = true
        context.insert(target)

        for index in 0..<2 {
            let water = WaterLogEntry()
            water.dayKey = day
            water.loggedAt = now.addingTimeInterval(Double(index) * 3_600)
            water.milliliters = 500
            context.insert(water)
        }

        let achievement = Achievement(code: "first-workout")
        achievement.unlockedAt = now
        achievement.value = 1
        context.insert(achievement)

        try context.save()
    }

    /// Counts every model a full backup is expected to carry back.
    static func counts(in context: ModelContext) throws -> [String: Int] {
        [
            "UserProfile": try context.fetchCount(FetchDescriptor<UserProfile>()),
            "UserSettings": try context.fetchCount(FetchDescriptor<UserSettings>()),
            "EquipmentProfile": try context.fetchCount(FetchDescriptor<EquipmentProfile>()),
            "ExercisePreference": try context.fetchCount(FetchDescriptor<ExercisePreference>()),
            "TrainingProgram": try context.fetchCount(FetchDescriptor<TrainingProgram>()),
            "WorkoutTemplate": try context.fetchCount(FetchDescriptor<WorkoutTemplate>()),
            "PlannedExercise": try context.fetchCount(FetchDescriptor<PlannedExercise>()),
            "ProgramVersion": try context.fetchCount(FetchDescriptor<ProgramVersion>()),
            "WorkoutSession": try context.fetchCount(FetchDescriptor<WorkoutSession>()),
            "ExerciseSession": try context.fetchCount(FetchDescriptor<ExerciseSession>()),
            "SetRecord": try context.fetchCount(FetchDescriptor<SetRecord>()),
            "PersonalRecord": try context.fetchCount(FetchDescriptor<PersonalRecord>()),
            "BodyWeightEntry": try context.fetchCount(FetchDescriptor<BodyWeightEntry>()),
            "RecoveryEntry": try context.fetchCount(FetchDescriptor<RecoveryEntry>()),
            "ProgressionState": try context.fetchCount(FetchDescriptor<ProgressionState>()),
            "FoodItem": try context.fetchCount(FetchDescriptor<FoodItem>()),
            "FoodLogEntry": try context.fetchCount(FetchDescriptor<FoodLogEntry>()),
            "SavedMeal": try context.fetchCount(FetchDescriptor<SavedMeal>()),
            "SavedMealItem": try context.fetchCount(FetchDescriptor<SavedMealItem>()),
            "Recipe": try context.fetchCount(FetchDescriptor<Recipe>()),
            "RecipeIngredient": try context.fetchCount(FetchDescriptor<RecipeIngredient>()),
            "Achievement": try context.fetchCount(FetchDescriptor<Achievement>()),
        ]
    }

    static func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-test-\(UUID().uuidString)-\(name)")
    }
}

/// A minimal RFC 4180 reader, so the CSV tests check what a spreadsheet would actually see rather
/// than the string the exporter happened to build.
private enum CSVReader {
    static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.append(character)
                index += 1
                continue
            }

            switch character {
            case "\"":
                inQuotes = true
                index += 1
            case ",":
                row.append(field)
                field = ""
                index += 1
            case "\r", "\n":
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                    index += 1
                }
                row.append(field)
                field = ""
                rows.append(row)
                row = []
                index += 1
            default:
                field.append(character)
                index += 1
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Backup round trip

@MainActor
@Suite("Full backup round trip")
struct BackupRoundTripTests {

    @Test("A populated store survives an export, a wipe and an import")
    func backupRoundTripsThroughAWipe() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let before = try BackupFixture.counts(in: context)

        let exporter = DataExportService(context: context)
        let data = try exporter.fullBackup()
        let document = try DataExportService.decoder.decode(BackupDocument.self, from: data)
        #expect(document.schemaVersion == DataExportService.backupSchemaVersion)

        let importer = DataImportService(context: context)
        try importer.resetAllData()
        let wiped = try BackupFixture.counts(in: context)
        #expect(wiped.values.allSatisfy { $0 == 0 }, "reset left rows behind: \(wiped)")

        let report = try importer.restore(document, strategy: .replace)
        let after = try BackupFixture.counts(in: context)

        #expect(after == before, "restored counts differ:\nbefore \(before)\nafter  \(after)")
        #expect(report.sessionsImported == 2)
        #expect(report.programsImported == 1)
        #expect(report.customFoodsImported == 2)
        #expect(report.foodLogEntriesImported == 2)
        #expect(report.bodyWeightsImported == 3)
        #expect(report.savedMealsImported == 1)
        #expect(report.recipesImported == 1)
        #expect(report.profileRestored)
        #expect(report.settingsRestored)
    }

    @Test("A sample of restored values matches what was exported")
    func restoredValuesMatch() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)

        let originalSessionIDs = Set(try context.fetch(FetchDescriptor<WorkoutSession>()).map(\.id))
        let exporter = DataExportService(context: context)
        let document = try DataExportService.decoder.decode(
            BackupDocument.self, from: try exporter.fullBackup()
        )

        let importer = DataImportService(context: context)
        try importer.resetAllData()
        try importer.restore(document, strategy: .replace)

        let profile = try #require(try context.fetch(FetchDescriptor<UserProfile>()).first)
        #expect(profile.name == "Alex")
        #expect(profile.heightCm == 178)
        #expect(profile.currentWeightKg == 78.4)
        #expect(profile.goals == [.buildMuscle, .buildStrength])
        #expect(profile.availableWeekdays == [.monday, .wednesday, .friday])
        #expect(profile.allergenTags == ["peanut"])

        let settings = try #require(try context.fetch(FetchDescriptor<UserSettings>()).first)
        #expect(settings.weightUnit == .pounds)
        #expect(settings.defaultRestSeconds == 210)

        let sessions = try context.fetch(
            FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startedAt)])
        )
        #expect(Set(sessions.map(\.id)) == originalSessionIDs)
        let first = try #require(sessions.first)
        #expect(first.titleSnapshot == "Upper A")
        #expect(first.status == .completed)
        #expect(first.activeSeconds == 2_400)
        #expect(first.notes == "solid")
        #expect(first.totalVolumeKg == 1_800)

        let performed = try #require(first.orderedExercises.first)
        #expect(performed.exerciseID == "E-BENCH")
        #expect(performed.exerciseNameSnapshot == "barbell bench press")
        #expect(performed.orderedSets.count == 3)
        let set = try #require(performed.orderedSets.first)
        #expect(set.weightKg == 60)
        #expect(set.reps == 10)
        #expect(set.rir == 2)
        #expect(set.isCompleted)

        let program = try #require(try context.fetch(FetchDescriptor<TrainingProgram>()).first)
        #expect(program.title == "Upper / Lower")
        #expect(program.orderedTemplates.map(\.customTitle) == ["Upper A", "Lower A"])
        #expect(program.orderedTemplates.first?.orderedExercises.map(\.exerciseID) == ["E-BENCH", "E-ROW"])

        let oats = try #require(
            try context.fetch(FetchDescriptor<FoodItem>()).first { $0.name == "Rolled oats" }
        )
        #expect(oats.kilocaloriesPer100 == 380)
        #expect(oats.micronutrientsPer100.fiberG == 10)
        #expect(oats.source == .custom)

        let logged = try context.fetch(
            FetchDescriptor<FoodLogEntry>(sortBy: [SortDescriptor(\.orderIndex)])
        )
        #expect(logged.count == 2)
        #expect(logged.first?.foodNameSnapshot == "Rolled oats")
        #expect(logged.first?.macrosSnapshot.kilocalories == 190)
        #expect(logged.first?.dayKey == BackupFixture.day)

        let recipe = try #require(try context.fetch(FetchDescriptor<Recipe>()).first)
        #expect(recipe.name == "Overnight oats")
        #expect(recipe.servingsCount == 2)
        #expect(recipe.ingredients.count == 2)

        let meal = try #require(try context.fetch(FetchDescriptor<SavedMeal>()).first)
        #expect(meal.name == "Usual breakfast")
        #expect(meal.items.count == 2)

        let records = try context.fetch(FetchDescriptor<PersonalRecord>())
        #expect(records.count == 2)
        #expect(records.contains { $0.kind == .heaviestWeight && $0.value == 100 })

        let progression = try #require(try context.fetch(FetchDescriptor<ProgressionState>()).first)
        #expect(progression.workingWeightKg == 62.5)
        #expect(progression.needsCalibration == false)

        #expect(try #require(try context.fetch(FetchDescriptor<Achievement>()).first).code == "first-workout")
    }

    @Test("Importing the same backup again with merge adds nothing")
    func reimportingWithMergeAddsNoDuplicates() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let exporter = DataExportService(context: context)
        let document = try DataExportService.decoder.decode(
            BackupDocument.self, from: try exporter.fullBackup()
        )

        let importer = DataImportService(context: context)
        let before = try BackupFixture.counts(in: context)
        let report = try importer.restore(document, strategy: .merge)
        let after = try BackupFixture.counts(in: context)

        #expect(after == before, "a repeated merge changed the store:\nbefore \(before)\nafter  \(after)")
        #expect(report.sessionsImported == 0)
        #expect(report.sessionsSkipped == 2)
        #expect(report.foodLogEntriesImported == 0)
        #expect(report.foodLogEntriesSkipped == 2)
        #expect(report.programsImported == 0)
        #expect(report.customFoodsImported == 0)
        #expect(report.savedMealsImported == 0)
        #expect(report.recipesImported == 0)
        #expect(report.bodyWeightsImported == 0)
        #expect(report.recordsImported == 0)
    }

    /// DOCUMENTED PRODUCTION DEFECT — every other collection in `DataImportService.restore` is
    /// de-duplicated (sessions and food log by id, body weights and check-ins by day, achievements
    /// by code), but the water loop inserts unconditionally:
    ///
    ///     for export in document.waterLog { let entry = WaterLogEntry(); …; context.insert(entry) }
    ///
    /// `WaterExport` carries no id either, so there is nothing to de-duplicate on. Restoring the
    /// same backup twice doubles every water entry, and with it the day's hydration total.
    @Test("Importing the same backup again with merge does not double the water log")
    func reimportingWithMergeDoesNotDuplicateWater() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let exporter = DataExportService(context: context)
        let document = try DataExportService.decoder.decode(
            BackupDocument.self, from: try exporter.fullBackup()
        )

        let repository = NutritionRepository(context: context)
        let before = try context.fetchCount(FetchDescriptor<WaterLogEntry>())
        let millilitresBefore = try repository.waterTotal(for: BackupFixture.day)

        try DataImportService(context: context).restore(document, strategy: .merge)

        #expect(try context.fetchCount(FetchDescriptor<WaterLogEntry>()) == before)
        #expect(try repository.waterTotal(for: BackupFixture.day) == millilitresBefore)
    }

    /// DOCUMENTED PRODUCTION DEFECT — `NutritionTargetExport` carries no id, and the restore loop
    /// inserts a fresh `DailyNutritionTarget` for every exported target on every import. Restoring
    /// the same backup twice leaves two identical targets (and after three imports, three), so the
    /// "why did my calories move?" timeline the target history is meant to answer fills with
    /// duplicate rows.
    @Test("Importing the same backup again with merge does not duplicate the energy targets")
    func reimportingWithMergeDoesNotDuplicateTargets() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let exporter = DataExportService(context: context)
        let document = try DataExportService.decoder.decode(
            BackupDocument.self, from: try exporter.fullBackup()
        )

        let before = try context.fetchCount(FetchDescriptor<DailyNutritionTarget>())
        try DataImportService(context: context).restore(document, strategy: .merge)

        #expect(try context.fetchCount(FetchDescriptor<DailyNutritionTarget>()) == before)
        #expect(try NutritionRepository(context: context).activeTarget()?.kilocalories == 2_600)
    }

    @Test("Exactly one energy target is active after a restore, whatever the backup claimed")
    func exactlyOneTargetIsActiveAfterRestore() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let exporter = DataExportService(context: context)
        var document = try DataExportService.decoder.decode(
            BackupDocument.self, from: try exporter.fullBackup()
        )
        // A hand-edited backup claiming two active targets must not produce two.
        var second = try #require(document.nutritionTargets.first)
        second.effectiveFrom = StoreTestSupport.days(30)
        second.kilocalories = 2_300
        second.isActive = true
        document.nutritionTargets.append(second)

        let importer = DataImportService(context: context)
        try importer.resetAllData()
        try importer.restore(document, strategy: .replace)

        let active = try context.fetch(FetchDescriptor<DailyNutritionTarget>()).filter(\.isActive)
        #expect(active.count == 1)
        #expect(active.first?.kilocalories == 2_300)
    }

    @Test("A merge keeps a personal record that is already better than the backup's")
    func mergeKeepsTheBetterPersonalRecord() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let document = try DataExportService.decoder.decode(
            BackupDocument.self, from: try DataExportService(context: context).fullBackup()
        )

        let best = try #require(
            try context.fetch(FetchDescriptor<PersonalRecord>()).first { $0.kind == .heaviestWeight }
        )
        best.value = 120
        try context.save()

        try DataImportService(context: context).restore(document, strategy: .merge)

        let stored = try context.fetch(FetchDescriptor<PersonalRecord>()).filter { $0.kind == .heaviestWeight }
        #expect(stored.count == 1)
        #expect(stored.first?.value == 120)
    }

    @Test("An empty store exports a valid, empty backup that imports cleanly")
    func anEmptyStoreRoundTrips() throws {
        let context = try StoreTestSupport.makeContext()
        let data = try DataExportService(context: context).fullBackup()
        let document = try DataExportService.decoder.decode(BackupDocument.self, from: data)

        #expect(document.profile == nil)
        #expect(document.sessions.isEmpty)
        #expect(document.foodLog.isEmpty)

        let report = try DataImportService(context: context).restore(document, strategy: .merge)
        #expect(report.sessionsImported == 0)
        #expect(report.profileRestored == false)
        #expect(try context.fetchCount(FetchDescriptor<WorkoutSession>()) == 0)
    }
}

// MARK: - Rejecting bad input

@MainActor
@Suite("Import validation")
struct ImportValidationTests {

    @Test("A backup written by a newer version of the app is rejected")
    func newerSchemaVersionsAreRejected() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let exporter = DataExportService(context: context)
        var document = try DataExportService.decoder.decode(
            BackupDocument.self, from: try exporter.fullBackup()
        )
        document.schemaVersion = DataExportService.backupSchemaVersion + 1

        let url = BackupFixture.temporaryURL("future.json")
        try DataExportService.encoder.encode(document).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let importer = DataImportService(context: context)
        do {
            _ = try importer.inspect(url: url)
            Issue.record("a backup from a newer format version was accepted")
        } catch let error as ImportError {
            guard case .unsupportedVersion(let found, let supported) = error else {
                Issue.record("expected .unsupportedVersion, got \(error)")
                return
            }
            #expect(found == DataExportService.backupSchemaVersion + 1)
            #expect(supported == DataExportService.backupSchemaVersion)
        }
    }

    @Test("A backup from the same or an older format version is accepted")
    func sameOrOlderSchemaVersionsAreAccepted() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let exporter = DataExportService(context: context)
        let url = BackupFixture.temporaryURL("current.json")
        try exporter.fullBackup().write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try DataImportService(context: context).inspect(url: url)
        #expect(document.schemaVersion == DataExportService.backupSchemaVersion)
        #expect(document.sessions.count == 2)
    }

    @Test("Malformed JSON throws and leaves the store exactly as it was")
    func malformedJSONIsRejectedWithoutTouchingTheStore() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let before = try BackupFixture.counts(in: context)

        let url = BackupFixture.temporaryURL("broken.json")
        try Data("{ this is not json at all".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let importer = DataImportService(context: context)
        #expect(throws: ImportError.self) { _ = try importer.inspect(url: url) }
        #expect(try BackupFixture.counts(in: context) == before)
    }

    @Test("Well-formed JSON that is not a backup is rejected as not a backup")
    func unrelatedJSONIsRejected() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let before = try BackupFixture.counts(in: context)

        let url = BackupFixture.temporaryURL("other.json")
        try Data(#"{"hello":"world","sessions":42}"#.utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let importer = DataImportService(context: context)
        do {
            _ = try importer.inspect(url: url)
            Issue.record("an unrelated JSON document was accepted as a backup")
        } catch let error as ImportError {
            if case .notABackup = error {} else {
                Issue.record("expected .notABackup, got \(error)")
            }
        }
        #expect(try BackupFixture.counts(in: context) == before)
    }

    @Test("A truncated backup is rejected rather than partially applied")
    func truncatedBackupIsRejected() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let before = try BackupFixture.counts(in: context)

        let full = try DataExportService(context: context).fullBackup()
        let url = BackupFixture.temporaryURL("truncated.json")
        try full.prefix(full.count / 2).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ImportError.self) { _ = try DataImportService(context: context).inspect(url: url) }
        #expect(try BackupFixture.counts(in: context) == before)
    }

    @Test("A file that is not there is reported as unreadable")
    func missingFileIsReportedAsUnreadable() throws {
        let context = try StoreTestSupport.makeContext()
        let url = BackupFixture.temporaryURL("does-not-exist.json")

        let importer = DataImportService(context: context)
        do {
            _ = try importer.inspect(url: url)
            Issue.record("a missing file was accepted as a backup")
        } catch let error as ImportError {
            if case .unreadableFile = error {} else {
                Issue.record("expected .unreadableFile, got \(error)")
            }
        }
    }
}

// MARK: - CSV

@MainActor
@Suite("CSV export")
struct CSVExportTests {

    @Test("Only fields that need quoting are quoted")
    func onlyAwkwardFieldsAreQuoted() {
        #expect(DataExportService.csvField("plain") == "plain")
        #expect(DataExportService.csvField("") == "")
        #expect(DataExportService.csvField("62.5") == "62.5")
        #expect(DataExportService.csvField("with space") == "with space")
    }

    @Test("A field containing a comma, a quote or a newline is escaped per RFC 4180")
    func awkwardFieldsAreEscaped() {
        #expect(DataExportService.csvField("Legs, heavy") == "\"Legs, heavy\"")
        #expect(DataExportService.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(DataExportService.csvField("line one\nline two") == "\"line one\nline two\"")
        #expect(DataExportService.csvField("carriage\rreturn") == "\"carriage\rreturn\"")
        #expect(DataExportService.csvField("all three: ,\"\n") == "\"all three: ,\"\"\n\"")
    }

    /// DOCUMENTED PRODUCTION DEFECT — a field containing a Windows line break is not quoted, so the
    /// row it sits in breaks in two when a spreadsheet reads the file.
    ///
    /// `DataExportService.csvField` tests `value.contains(where: { … $0 == "\n" || $0 == "\r" })`.
    /// `String.contains(where:)` iterates *grapheme clusters*, and CR LF is a single Swift
    /// `Character` that equals neither `"\n"` nor `"\r"` — so the guard decides the field is plain
    /// and returns it unquoted. A note pasted from a desktop mail client or a web page carries CR LF
    /// and is enough to corrupt the export. Iterating `value.unicodeScalars` (or adding an explicit
    /// `"\r\n"` check) fixes it.
    @Test("A field containing a Windows line break is quoted like any other newline")
    func windowsLineBreaksAreQuoted() {
        let field = "line one\r\nline two"
        #expect(DataExportService.csvField(field) == "\"line one\r\nline two\"")

        // The consequence: the exported row splits into two rows when read back.
        let line = [DataExportService.csvField("before"), DataExportService.csvField(field)]
            .joined(separator: ",") + "\n"
        #expect(CSVReader.rows(line).count == 1)
    }

    @Test("An escaped field round-trips through a conforming reader")
    func escapedFieldsRoundTrip() {
        let awkward = [
            "plain",
            "Legs, \"heavy\"\nweek 3",
            "comma, only",
            "\"quoted\"",
            "trailing quote\"",
            "line\nbreak",
            "carriage\rreturn",
            "",
            "a,b,\"c\"\nd",
        ]
        let line = awkward.map(DataExportService.csvField).joined(separator: ",")
        let parsed = CSVReader.rows(line + "\n")

        #expect(parsed.count == 1)
        #expect(parsed.first == awkward, "round trip lost data: \(String(describing: parsed.first))")
    }

    @Test("A workout export keeps awkward names and notes intact for a spreadsheet")
    func trainingCSVRoundTripsAwkwardText() throws {
        let context = try StoreTestSupport.makeContext()
        let title = "Legs, \"heavy\"\nweek 3"
        let exerciseName = "row, bent-over"
        let note = "felt \"fine\"\nnext time +2.5"

        let session = WorkoutSession()
        session.titleSnapshot = title
        session.startedAt = StoreTestSupport.epoch
        session.status = .completed
        context.insert(session)

        let record = ExerciseSession()
        record.exerciseID = "E-ROW"
        record.exerciseNameSnapshot = exerciseName
        record.workout = session
        context.insert(record)

        let set = SetRecord()
        set.setIndex = 0
        set.weightKg = 60
        set.reps = 10
        set.isCompleted = true
        set.notes = note
        set.exerciseSession = record
        context.insert(set)
        try context.save()

        let csv = try DataExportService(context: context).trainingCSV()
        let rows = CSVReader.rows(csv)

        #expect(rows.count == 2)
        let header = try #require(rows.first)
        #expect(header.count == 16)
        #expect(header[1] == "session")
        #expect(header[15] == "notes")

        let row = try #require(rows.last)
        #expect(row.count == header.count)
        #expect(row[1] == title)
        #expect(row[3] == exerciseName)
        #expect(row[4] == "E-ROW")
        #expect(row[5] == "1")
        #expect(row[7] == "60")
        #expect(row[8] == "10")
        #expect(row[13] == "true")
        #expect(row[14] == "600")
        #expect(row[15] == note)
    }

    @Test("A nutrition export keeps awkward food names intact and leaves unknown nutrients blank")
    func nutritionCSVRoundTripsAwkwardText() throws {
        let context = try StoreTestSupport.makeContext()
        let foodName = "Beans, \"baked\"\nin tomato sauce"

        let entry = FoodLogEntry()
        entry.dayKey = "2024-06-03"
        entry.loggedAt = StoreTestSupport.epoch
        entry.mealSlot = .lunch
        entry.foodNameSnapshot = foodName
        entry.brandSnapshot = nil
        entry.quantity = 200
        entry.unit = .grams
        entry.macrosSnapshot = MacroNutrients(kilocalories: 155, proteinG: 9.8, carbsG: 26, fatG: 0.4)
        var micros = Micronutrients.unknown
        micros.fiberG = 7.2
        entry.micronutrientsSnapshot = micros
        context.insert(entry)
        try context.save()

        let csv = try DataExportService(context: context).nutritionCSV()
        let rows = CSVReader.rows(csv)

        #expect(rows.count == 2)
        let header = try #require(rows.first)
        #expect(header.count == 13)

        let row = try #require(rows.last)
        #expect(row.count == header.count)
        #expect(row[0] == "2024-06-03")
        #expect(row[2] == "lunch")
        #expect(row[3] == foodName)
        #expect(row[4] == "")
        #expect(row[5] == "200")
        #expect(row[7] == "155")
        #expect(row[8] == "9.80")
        #expect(row[11] == "7.20")
        // Sodium was never known, so it is blank rather than zero.
        #expect(row[12] == "")
    }

    @Test("An empty store exports a header row and nothing else")
    func emptyExportsAreJustAHeader() throws {
        let context = try StoreTestSupport.makeContext()
        let exporter = DataExportService(context: context)

        #expect(CSVReader.rows(try exporter.trainingCSV()).count == 1)
        #expect(CSVReader.rows(try exporter.nutritionCSV()).count == 1)
    }

    @Test("Numbers are written locale-independently so a comma decimal never splits a column")
    func numbersAreLocaleIndependent() throws {
        let context = try StoreTestSupport.makeContext()
        let session = WorkoutSession()
        session.titleSnapshot = "Session"
        session.startedAt = StoreTestSupport.epoch
        context.insert(session)
        let record = ExerciseSession()
        record.exerciseID = "E-BENCH"
        record.exerciseNameSnapshot = "bench"
        record.workout = session
        context.insert(record)
        let set = SetRecord()
        set.weightKg = 62.5
        set.reps = 8
        set.rpe = 8.5
        set.isCompleted = true
        set.exerciseSession = record
        context.insert(set)
        try context.save()

        let rows = CSVReader.rows(try DataExportService(context: context).trainingCSV())
        let row = try #require(rows.last)
        #expect(row.count == 16)
        #expect(row[7] == "62.50")
        #expect(row[12] == "8.50")
        #expect(row[14] == "500")
    }

    @Test("Every scoped export writes a file the caller can hand to the share sheet")
    func exportWritesAFile() throws {
        let context = try StoreTestSupport.makeContext()
        try BackupFixture.populate(context)
        let exporter = DataExportService(context: context)

        for format in ExportFormat.allCases {
            let url = try exporter.export(format)
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(url.pathExtension == format.fileExtension)
            let data = try Data(contentsOf: url)
            #expect(!data.isEmpty, "\(format.rawValue) wrote an empty file")
            if format.fileExtension == "json" {
                #expect((try JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil)
            }
        }
    }
}
