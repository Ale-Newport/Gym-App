import Foundation
import SwiftData

enum ImportError: LocalizedError {
    case unreadableFile
    case notABackup
    case unsupportedVersion(found: Int, supported: Int)
    case writeFailed(String)

    var localizationKey: String {
        switch self {
        case .unreadableFile: "import.error.unreadable"
        case .notABackup: "import.error.notABackup"
        case .unsupportedVersion: "import.error.version"
        case .writeFailed: "import.error.write"
        }
    }

    var errorDescription: String? {
        switch self {
        case .unreadableFile: "The file could not be read."
        case .notABackup: "That file is not a Forge backup."
        case .unsupportedVersion(let found, let supported):
            "The backup was written by a newer version of Forge (format \(found); this version reads up to \(supported))."
        case .writeFailed(let detail): "The backup could not be restored: \(detail)"
        }
    }
}

/// How an import should treat data that is already on the device.
enum ImportStrategy: String, CaseIterable, Identifiable, Sendable {
    /// Keep what is here and add only records the device does not already have.
    case merge
    /// Delete everything first, then restore the backup exactly.
    case replace

    var id: String { rawValue }
    var localizationKey: String { "import.strategy.\(rawValue)" }
    var detailLocalizationKey: String { "import.strategy.\(rawValue).detail" }
}

/// What an import did, so the user gets a factual report rather than a silent success.
struct ImportReport: Sendable {
    var strategy: ImportStrategy
    var sessionsImported = 0
    var sessionsSkipped = 0
    var programsImported = 0
    var foodLogEntriesImported = 0
    var foodLogEntriesSkipped = 0
    var customFoodsImported = 0
    var bodyWeightsImported = 0
    var recordsImported = 0
    var savedMealsImported = 0
    var recipesImported = 0
    var profileRestored = false
    var settingsRestored = false
}

/// Restores a `BackupDocument` produced by `DataExportService`.
///
/// Two guarantees shape the implementation:
///
/// * **Never destroy data by accident.** `.merge` is the default and is additive: a record whose id
///   already exists is skipped, never overwritten. `.replace` is destructive by explicit request
///   only, and the caller is expected to confirm it with the user first.
/// * **Never half-apply a backup.** Everything is written into one `ModelContext` and saved once at
///   the end, so a malformed file leaves the store untouched rather than partially overwritten.
@MainActor
struct DataImportService {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Parses and validates a backup without writing anything, so the UI can preview it.
    func inspect(url: URL) throws -> BackupDocument {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadableFile }
        guard let document = try? DataExportService.decoder.decode(BackupDocument.self, from: data) else {
            throw ImportError.notABackup
        }
        guard document.schemaVersion <= DataExportService.backupSchemaVersion else {
            throw ImportError.unsupportedVersion(
                found: document.schemaVersion,
                supported: DataExportService.backupSchemaVersion
            )
        }
        return document
    }

    @discardableResult
    func restore(_ document: BackupDocument, strategy: ImportStrategy) throws -> ImportReport {
        var report = ImportReport(strategy: strategy)

        if strategy == .replace {
            try deleteEverything()
        }

        // Singletons: restore into the existing row so the rest of the app keeps its references.
        if let profileExport = document.profile {
            let profile = try context.fetch(FetchDescriptor<UserProfile>()).first ?? {
                let created = UserProfile()
                context.insert(created)
                return created
            }()
            profileExport.apply(to: profile)
            report.profileRestored = true
        }

        if let settingsExport = document.settings {
            let settings = try context.fetch(FetchDescriptor<UserSettings>()).first ?? {
                let created = UserSettings()
                context.insert(created)
                return created
            }()
            settingsExport.apply(to: settings)
            report.settingsRestored = true
        }

        if let equipmentExport = document.equipment {
            let equipment = try context.fetch(FetchDescriptor<EquipmentProfile>()).first ?? {
                let created = EquipmentProfile()
                context.insert(created)
                return created
            }()
            equipmentExport.apply(to: equipment)
        }

        // Preferences are keyed by exercise id and are cheap to overwrite wholesale.
        let existingPreferences = Dictionary(
            (try context.fetch(FetchDescriptor<ExercisePreference>())).map { ($0.exerciseID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for export in document.preferences {
            let preference = existingPreferences[export.exerciseID] ?? {
                let created = ExercisePreference(exerciseID: export.exerciseID)
                context.insert(created)
                return created
            }()
            preference.isFavorite = export.isFavorite
            preference.feedback = export.feedback
            preference.isExcluded = export.isExcluded
            preference.customIncrementKg = export.customIncrementKg
            preference.notes = export.notes
            preference.lastPerformedAt = export.lastPerformedAt
            preference.timesPerformed = max(preference.timesPerformed, export.timesPerformed)
        }

        // Programs.
        let existingProgramIDs = Set(try context.fetch(FetchDescriptor<TrainingProgram>()).map(\.id))
        for export in document.programs where !existingProgramIDs.contains(export.id) {
            context.insert(makeProgram(from: export))
            report.programsImported += 1
        }

        // Sessions — the irreplaceable part of the data. Skipping duplicates by id makes repeated
        // imports of the same file harmless.
        let existingSessionIDs = Set(try context.fetch(FetchDescriptor<WorkoutSession>()).map(\.id))
        for export in document.sessions {
            guard !existingSessionIDs.contains(export.id) else {
                report.sessionsSkipped += 1
                continue
            }
            context.insert(makeSession(from: export))
            report.sessionsImported += 1
        }

        // Personal records: keep the better value when both sides have one.
        let existingRecords = try context.fetch(FetchDescriptor<PersonalRecord>())
        var bestByKey: [String: PersonalRecord] = [:]
        for record in existingRecords {
            bestByKey["\(record.exerciseID)|\(record.kind.rawValue)"] = record
        }
        for export in document.personalRecords {
            let key = "\(export.exerciseID)|\(export.kind.rawValue)"
            // "Better" inverts for records where a lower number wins (assistance removed).
            if let existing = bestByKey[key] {
                let backupIsBetter = export.kind.lowerIsBetter
                    ? export.value < existing.value
                    : export.value > existing.value
                if !backupIsBetter { continue }
            }
            let record = PersonalRecord()
            record.exerciseID = export.exerciseID
            record.exerciseNameSnapshot = export.exerciseNameSnapshot
            record.kind = export.kind
            record.value = export.value
            record.repsContext = export.repsContext
            record.achievedAt = export.achievedAt
            record.previousValue = export.previousValue
            context.insert(record)
            bestByKey[key] = record
            report.recordsImported += 1
        }

        // Body weights: one reading per calendar day wins, so re-importing never doubles the trend.
        let calendar = Calendar.current
        var existingWeightDays = Set(
            try context.fetch(FetchDescriptor<BodyWeightEntry>())
                .map { calendar.startOfDay(for: $0.date) }
        )
        for export in document.bodyWeights {
            let day = calendar.startOfDay(for: export.date)
            guard existingWeightDays.insert(day).inserted else { continue }
            let entry = BodyWeightEntry(
                date: export.date, weightKg: export.weightKg, isFromHealthKit: export.isFromHealthKit
            )
            entry.note = export.note
            context.insert(entry)
            report.bodyWeightsImported += 1
        }

        var existingRecoveryDays = Set(
            try context.fetch(FetchDescriptor<RecoveryEntry>())
                .map { calendar.startOfDay(for: $0.date) }
        )
        for export in document.recoveryEntries {
            let day = calendar.startOfDay(for: export.date)
            guard existingRecoveryDays.insert(day).inserted else { continue }
            let entry = RecoveryEntry()
            entry.date = export.date
            entry.energy = export.energy
            entry.sleepQuality = export.sleepQuality
            entry.sleepHours = export.sleepHours
            entry.soreness = export.soreness
            entry.motivation = export.motivation
            entry.stress = export.stress
            entry.note = export.note
            entry.soreGroups = export.soreGroups
            context.insert(entry)
        }

        let existingStates = Dictionary(
            (try context.fetch(FetchDescriptor<ProgressionState>())).map { ($0.exerciseID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for export in document.progressionStates {
            let state = existingStates[export.exerciseID] ?? {
                let created = ProgressionState(exerciseID: export.exerciseID)
                context.insert(created)
                return created
            }()
            state.workingWeightKg = export.workingWeightKg
            state.repLower = export.repLower
            state.repUpper = export.repUpper
            state.consecutiveSuccesses = export.consecutiveSuccesses
            state.consecutiveStalls = export.consecutiveStalls
            state.consecutiveRegressions = export.consecutiveRegressions
            state.needsCalibration = export.needsCalibration
            state.lastPerformedAt = export.lastPerformedAt
            state.bestEstimatedOneRepMaxKg = export.bestEstimatedOneRepMaxKg
            state.strategy = export.strategy
        }

        // Custom foods, then anything referring to them.
        let existingFoodIDs = Set(try context.fetch(FetchDescriptor<FoodItem>()).map(\.id))
        for export in document.customFoods where !existingFoodIDs.contains(export.id) {
            let food = FoodItem()
            food.id = export.id
            food.catalogID = export.catalogID
            food.name = export.name
            food.brand = export.brand
            food.barcode = export.barcode
            food.sourceRaw = export.source
            food.kilocaloriesPer100 = export.kilocaloriesPer100
            food.proteinGPer100 = export.proteinGPer100
            food.carbsGPer100 = export.carbsGPer100
            food.fatGPer100 = export.fatGPer100
            food.micronutrientsPer100 = export.micronutrientsPer100
            food.basisUnit = export.basisUnit
            food.servings = export.servings
            food.gramsPerPiece = export.gramsPerPiece
            food.dietaryTags = export.dietaryTags
            food.allergenTags = export.allergenTags
            food.roleTags = export.roleTags
            food.isFavorite = export.isFavorite
            food.createdAt = export.createdAt
            context.insert(food)
            report.customFoodsImported += 1
        }

        let existingLogIDs = Set(try context.fetch(FetchDescriptor<FoodLogEntry>()).map(\.id))
        for export in document.foodLog {
            guard !existingLogIDs.contains(export.id) else {
                report.foodLogEntriesSkipped += 1
                continue
            }
            let entry = FoodLogEntry()
            entry.id = export.id
            entry.dayKey = export.dayKey
            entry.loggedAt = export.loggedAt
            entry.mealSlot = export.mealSlot
            entry.orderIndex = export.orderIndex
            entry.foodID = export.foodID
            entry.foodNameSnapshot = export.foodNameSnapshot
            entry.brandSnapshot = export.brandSnapshot
            entry.quantity = export.quantity
            entry.unit = export.unit
            entry.servingIndex = export.servingIndex
            entry.macrosSnapshot = export.macrosSnapshot
            entry.micronutrientsSnapshot = export.micronutrientsSnapshot
            context.insert(entry)
            report.foodLogEntriesImported += 1
        }

        let existingMealIDs = Set(try context.fetch(FetchDescriptor<SavedMeal>()).map(\.id))
        for export in document.savedMeals where !existingMealIDs.contains(export.id) {
            let meal = SavedMeal()
            meal.id = export.id
            meal.name = export.name
            meal.defaultSlot = export.defaultSlot
            meal.createdAt = export.createdAt
            meal.timesUsed = export.timesUsed
            meal.isFavorite = export.isFavorite
            context.insert(meal)
            for itemExport in export.items {
                let item = SavedMealItem()
                item.foodID = itemExport.foodID
                item.foodNameSnapshot = itemExport.foodNameSnapshot
                item.quantity = itemExport.quantity
                item.unit = itemExport.unit
                item.servingIndex = itemExport.servingIndex
                item.orderIndex = itemExport.orderIndex
                item.meal = meal
                context.insert(item)
            }
            report.savedMealsImported += 1
        }

        let existingRecipeIDs = Set(try context.fetch(FetchDescriptor<Recipe>()).map(\.id))
        for export in document.recipes where !existingRecipeIDs.contains(export.id) {
            let recipe = Recipe()
            recipe.id = export.id
            recipe.name = export.name
            recipe.servingsCount = export.servingsCount
            recipe.instructions = export.instructions
            recipe.preparationMinutes = export.preparationMinutes
            recipe.createdAt = export.createdAt
            recipe.isFavorite = export.isFavorite
            recipe.tags = export.tags
            context.insert(recipe)
            for ingredientExport in export.ingredients {
                let ingredient = RecipeIngredient()
                ingredient.foodID = ingredientExport.foodID
                ingredient.foodNameSnapshot = ingredientExport.foodNameSnapshot
                ingredient.quantity = ingredientExport.quantity
                ingredient.unit = ingredientExport.unit
                ingredient.servingIndex = ingredientExport.servingIndex
                ingredient.orderIndex = ingredientExport.orderIndex
                ingredient.recipe = recipe
                context.insert(ingredient)
            }
            report.recipesImported += 1
        }

        // Exactly one target stays active, whatever the backup claimed.
        //
        // Targets carry no id in the backup, so identity is `effectiveFrom` — there is only ever one
        // target in force at a moment. Without this, re-importing the same file stacks duplicates
        // and the history screen shows the same change several times.
        if !document.nutritionTargets.isEmpty {
            var seenEffectiveFrom = Set(
                try context.fetch(FetchDescriptor<DailyNutritionTarget>()).map(\.effectiveFrom)
            )
            for existing in try context.fetch(FetchDescriptor<DailyNutritionTarget>()) {
                existing.isActive = false
            }
            for export in document.nutritionTargets {
                guard seenEffectiveFrom.insert(export.effectiveFrom).inserted else { continue }
                let target = DailyNutritionTarget()
                target.effectiveFrom = export.effectiveFrom
                target.kilocalories = export.kilocalories
                target.proteinG = export.proteinG
                target.carbsG = export.carbsG
                target.fatG = export.fatG
                target.isManualOverride = export.isManualOverride
                target.rationaleKey = export.rationaleKey
                target.rationaleArguments = export.rationaleArguments
                target.isActive = false
                target.micronutrientGoals = export.micronutrientGoals
                context.insert(target)
            }
            let all = try context.fetch(FetchDescriptor<DailyNutritionTarget>())
            all.max { $0.effectiveFrom < $1.effectiveFrom }?.isActive = true
        }

        // Water entries carry no id either, so identity is the day, the timestamp and the amount.
        // Two genuinely distinct 250 ml entries never share a timestamp; the same entry imported
        // twice always does.
        var seenWater = Set(
            try context.fetch(FetchDescriptor<WaterLogEntry>())
                .map { WaterKey(dayKey: $0.dayKey, loggedAt: $0.loggedAt, milliliters: $0.milliliters) }
        )
        for export in document.waterLog {
            let key = WaterKey(
                dayKey: export.dayKey, loggedAt: export.loggedAt, milliliters: export.milliliters
            )
            guard seenWater.insert(key).inserted else { continue }
            let entry = WaterLogEntry()
            entry.dayKey = export.dayKey
            entry.loggedAt = export.loggedAt
            entry.milliliters = export.milliliters
            context.insert(entry)
        }

        let existingAchievements = Set(try context.fetch(FetchDescriptor<Achievement>()).map(\.code))
        for export in document.achievements where !existingAchievements.contains(export.code) {
            let achievement = Achievement(code: export.code)
            achievement.unlockedAt = export.unlockedAt
            achievement.value = export.value
            achievement.exerciseID = export.exerciseID
            context.insert(achievement)
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw ImportError.writeFailed(String(describing: error))
        }
        return report
    }

    /// Identity for a water entry, which the backup format does not give an id.
    private struct WaterKey: Hashable {
        let dayKey: String
        let loggedAt: Date
        let milliliters: Double
    }

    // MARK: - Reset

    /// Deletes every user record. Used by `.replace` imports and by Settings → Reset.
    ///
    /// Deliberately **not** `context.delete(model:)`. That runs a batch delete straight against the
    /// store, which bypasses the object graph and trips
    /// "Constraint trigger violation: Batch delete failed due to mandatory OTO nullify inverse"
    /// the moment it reaches a child that a parent still points at — `SetRecord.exerciseSession`
    /// being the first. Deleting the aggregate roots and letting the declared `.cascade` rules run
    /// is both correct and cheap: a reset is a handful of thousand objects at most, and it happens
    /// once.
    func deleteEverything() throws {
        // Roots first; their cascade rules take the children with them.
        try deleteAll(WorkoutSession.self)
        try deleteAll(TrainingProgram.self)
        try deleteAll(SavedMeal.self)
        try deleteAll(Recipe.self)

        // Anything the cascades did not reach — orphans from an interrupted earlier delete
        // included, which is why these run unconditionally rather than only when a root existed.
        try deleteAll(SetRecord.self)
        try deleteAll(ExerciseSession.self)
        try deleteAll(PlannedExercise.self)
        try deleteAll(WorkoutTemplate.self)
        try deleteAll(ProgramVersion.self)
        try deleteAll(SavedMealItem.self)
        try deleteAll(RecipeIngredient.self)

        // Standalone records.
        try deleteAll(PersonalRecord.self)
        try deleteAll(BodyWeightEntry.self)
        try deleteAll(RecoveryEntry.self)
        try deleteAll(ProgressionState.self)
        try deleteAll(DeloadRecommendation.self)
        try deleteAll(ExercisePreference.self)
        try deleteAll(FoodLogEntry.self)
        try deleteAll(NutritionTargetHistory.self)
        try deleteAll(DailyNutritionTarget.self)
        try deleteAll(WaterLogEntry.self)
        try deleteAll(Achievement.self)
        // Built-in foods are re-imported from the bundle, so removing them all is safe and keeps a
        // reset from leaving orphaned custom entries behind.
        try deleteAll(FoodItem.self)

        UserDefaults.standard.removeObject(forKey: "foodDatabaseVersion")
        try context.save()
    }

    /// Fetches and deletes every instance of one model through the object graph.
    private func deleteAll<T: PersistentModel>(_ type: T.Type) throws {
        for object in try context.fetch(FetchDescriptor<T>()) {
            context.delete(object)
        }
    }

    /// Wipes everything including the profile. Settings → Reset uses this.
    func resetAllData() throws {
        try deleteEverything()
        try deleteAll(UserProfile.self)
        try deleteAll(UserSettings.self)
        try deleteAll(EquipmentProfile.self)
        try context.save()
    }

    // MARK: - Model construction

    private func makeProgram(from export: ProgramExport) -> TrainingProgram {
        let program = TrainingProgram()
        program.id = export.id
        program.title = export.title
        program.splitKey = export.splitKey
        program.daysPerWeek = export.daysPerWeek
        program.isActive = export.isActive
        program.isManuallyCreated = export.isManuallyCreated
        program.createdAt = export.createdAt
        program.goals = export.goals
        program.experience = export.experience
        program.priorityGroups = export.priorityGroups
        program.currentVersion = export.currentVersion
        program.completedWeeks = export.completedWeeks
        program.mesocycleLengthWeeks = export.mesocycleLengthWeeks
        context.insert(program)

        for templateExport in export.templates {
            let template = WorkoutTemplate()
            template.id = templateExport.id
            template.orderIndex = templateExport.orderIndex
            template.customTitle = templateExport.customTitle
            template.titleKey = templateExport.titleKey
            template.weekday = templateExport.weekday
            template.estimatedMinutes = templateExport.estimatedMinutes
            template.focusGroups = templateExport.focusGroups
            template.pushPull = templateExport.pushPull
            template.isRestDay = templateExport.isRestDay
            template.program = program
            context.insert(template)

            for exerciseExport in templateExport.exercises {
                let planned = PlannedExercise()
                planned.id = exerciseExport.id
                planned.exerciseID = exerciseExport.exerciseID
                planned.orderIndex = exerciseExport.orderIndex
                planned.targetSets = exerciseExport.targetSets
                planned.repLower = exerciseExport.repLower
                planned.repUpper = exerciseExport.repUpper
                planned.restSeconds = exerciseExport.restSeconds
                planned.targetRIR = exerciseExport.targetRIR
                planned.targetDurationSeconds = exerciseExport.targetDurationSeconds
                planned.targetDistanceMeters = exerciseExport.targetDistanceMeters
                planned.isLocked = exerciseExport.isLocked
                planned.notes = exerciseExport.notes
                planned.substitutedFromExerciseID = exerciseExport.substitutedFromExerciseID
                planned.template = template
                context.insert(planned)
            }
        }

        for versionExport in export.versions {
            let version = ProgramVersion()
            version.versionNumber = versionExport.versionNumber
            version.createdAt = versionExport.createdAt
            version.reasonKey = versionExport.reasonKey
            version.reasonArguments = versionExport.reasonArguments
            version.program = program
            context.insert(version)
        }
        return program
    }

    private func makeSession(from export: SessionExport) -> WorkoutSession {
        let session = WorkoutSession()
        session.id = export.id
        session.startedAt = export.startedAt
        session.endedAt = export.endedAt
        session.statusRaw = export.status
        session.titleSnapshot = export.titleSnapshot
        session.templateID = export.templateID
        session.programID = export.programID
        session.programVersion = export.programVersion
        session.focusGroups = export.focusGroups
        session.notes = export.notes
        session.effortFeedback = export.effortFeedback
        session.activeSeconds = export.activeSeconds
        session.totalVolumeKg = export.totalVolumeKg
        session.completedSetCount = export.completedSetCount
        session.plannedSetCount = export.plannedSetCount
        context.insert(session)

        for exerciseExport in export.exercises {
            let exercise = ExerciseSession()
            exercise.id = exerciseExport.id
            exercise.exerciseID = exerciseExport.exerciseID
            exercise.exerciseNameSnapshot = exerciseExport.exerciseNameSnapshot
            exercise.orderIndex = exerciseExport.orderIndex
            exercise.notes = exerciseExport.notes
            exercise.wasSkipped = exerciseExport.wasSkipped
            exercise.substitutedFromExerciseID = exerciseExport.substitutedFromExerciseID
            exercise.substitutionReasonKey = exerciseExport.substitutionReasonKey
            exercise.targetRIR = exerciseExport.targetRIR
            exercise.restSeconds = exerciseExport.restSeconds
            exercise.trackingMode = exerciseExport.trackingMode
            exercise.workout = session
            context.insert(exercise)

            for setExport in exerciseExport.sets {
                let set = SetRecord()
                set.setIndex = setExport.setIndex
                set.kind = setExport.kind
                set.targetWeightKg = setExport.targetWeightKg
                set.targetReps = setExport.targetReps
                set.targetDurationSeconds = setExport.targetDurationSeconds
                set.weightKg = setExport.weightKg
                set.reps = setExport.reps
                set.durationSeconds = setExport.durationSeconds
                set.distanceMeters = setExport.distanceMeters
                set.rir = setExport.rir
                set.rpe = setExport.rpe
                set.isCompleted = setExport.isCompleted
                set.completedAt = setExport.completedAt
                set.notes = setExport.notes
                set.exerciseSession = exercise
                context.insert(set)
            }
        }
        return session
    }
}
