import Foundation
import SwiftData
import Testing

@testable import GymApp

// MARK: - Shared fixtures

/// Fixtures shared by the store-facing suites (`PersistenceTests`, `RepositoryTests`,
/// `ExportImportTests`).
///
/// Everything here builds value types or in-memory rows. Nothing reads the wall clock: every date a
/// test needs is derived from `StoreTestSupport.epoch`, so a suite that runs at 23:59 behaves
/// exactly like one that runs at noon.
@MainActor
enum StoreTestSupport {

    /// A fixed reference instant — 2024-06-03 09:00:00 UTC, a Monday.
    static let epoch = Date(timeIntervalSince1970: 1_717_405_200)

    /// A calendar pinned to UTC so day bucketing never depends on the machine running the tests.
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func days(_ count: Int, from date: Date = epoch) -> Date {
        date.addingTimeInterval(Double(count) * 86_400)
    }

    static func makeContext() throws -> ModelContext {
        let container = try PersistenceController.makeInMemoryContainer()
        return ModelContext(container)
    }

    // MARK: Catalogue

    /// Builds a catalogue record. Metadata comes from the real deriver, so tracking modes, rep
    /// ranges and volume credits are the ones the app would actually compute for this name.
    static func exercise(
        id: String,
        name: String,
        equipment: Equipment = .barbell,
        bodyPart: BodyPart = .chest,
        target: Muscle = .pectorals,
        synergist: Muscle? = .triceps,
        secondary: [Muscle] = [],
        tune: ((inout ExerciseMetadata) -> Void)? = nil
    ) -> Exercise {
        var metadata = ExerciseMetadataDeriver.derive(
            name: name,
            bodyPart: bodyPart,
            equipment: equipment,
            target: target,
            synergist: synergist,
            secondaryMuscles: secondary
        )
        tune?(&metadata)
        return Exercise(
            id: id,
            name: name,
            bodyPart: bodyPart,
            equipment: equipment,
            target: target,
            synergist: synergist,
            secondaryMuscles: secondary,
            mediaID: id,
            thumbnailFileName: "\(id).png",
            animationFileName: "\(id).webp",
            attribution: "test fixture",
            createdAt: epoch,
            metadata: metadata
        )
    }

    static func catalog(_ exercises: [Exercise]) -> [String: Exercise] {
        Dictionary(exercises.map { ($0.id, $0) }) { first, _ in first }
    }

    static let benchPress = exercise(id: "E-BENCH", name: "barbell bench press")
    static let inclinePress = exercise(
        id: "E-INCLINE", name: "dumbbell incline bench press", equipment: .dumbbell
    )
    static let squat = exercise(
        id: "E-SQUAT", name: "barbell full squat",
        bodyPart: .upperLegs, target: .quads, synergist: .glutes
    )
    static let row = exercise(
        id: "E-ROW", name: "barbell bent over row",
        bodyPart: .back, target: .lats, synergist: .biceps
    )

    // MARK: Program fixtures

    /// A one-template program with `exercises` planned in order. `customTitle` is always set so no
    /// test depends on a localisation table being present.
    @discardableResult
    static func makeProgram(
        in context: ModelContext,
        title: String = "Test Program",
        templateTitle: String = "Upper A",
        exercises: [(id: String, sets: Int, reps: RepRange)] = [("E-BENCH", 3, RepRange(8, 12))]
    ) -> TrainingProgram {
        let program = TrainingProgram()
        program.title = title
        program.daysPerWeek = 3
        program.createdAt = epoch
        context.insert(program)

        let template = WorkoutTemplate()
        template.customTitle = templateTitle
        template.orderIndex = 0
        template.focusGroups = [.chest, .triceps]
        template.createdAt = epoch
        template.program = program
        context.insert(template)

        for (index, planned) in exercises.enumerated() {
            let row = PlannedExercise()
            row.exerciseID = planned.id
            row.orderIndex = index
            row.targetSets = planned.sets
            row.repRange = planned.reps
            row.restSeconds = 120
            row.targetRIR = 2
            row.template = template
            context.insert(row)
        }
        return program
    }

    // MARK: Food fixtures

    /// A food whose per-100 g numbers are round, so every portion assertion is exact.
    @discardableResult
    static func makeFood(
        in context: ModelContext,
        name: String,
        kcal: Double = 100,
        protein: Double = 10,
        carbs: Double = 5,
        fat: Double = 2,
        fiber: Double? = 3,
        servings: [FoodServing] = [],
        gramsPerPiece: Double? = nil,
        source: FoodSource = .custom
    ) -> FoodItem {
        let food = FoodItem()
        food.name = name
        food.source = source
        food.kilocaloriesPer100 = kcal
        food.proteinGPer100 = protein
        food.carbsGPer100 = carbs
        food.fatGPer100 = fat
        var micros = Micronutrients.unknown
        micros.fiberG = fiber
        food.micronutrientsPer100 = micros
        food.servings = servings
        food.gramsPerPiece = gramsPerPiece
        food.createdAt = epoch
        food.updatedAt = epoch
        context.insert(food)
        return food
    }
}

// MARK: - Schema

@MainActor
@Suite("SwiftData schema")
struct PersistenceSchemaTests {

    @Test("The in-memory container builds without throwing")
    func inMemoryContainerBuilds() throws {
        let container = try PersistenceController.makeInMemoryContainer()
        #expect(container.configurations.first?.isStoredInMemoryOnly == true)
    }

    @Test("Two in-memory containers do not share rows")
    func inMemoryContainersAreIsolated() throws {
        let first = ModelContext(try PersistenceController.makeInMemoryContainer())
        let second = ModelContext(try PersistenceController.makeInMemoryContainer())
        first.insert(BodyWeightEntry(date: StoreTestSupport.epoch, weightKg: 80))
        try first.save()

        #expect(try first.fetchCount(FetchDescriptor<BodyWeightEntry>()) == 1)
        #expect(try second.fetchCount(FetchDescriptor<BodyWeightEntry>()) == 0)
    }

    @Test("SchemaV1 is version 1.0.0")
    func schemaVersionIsPinned() {
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    @Test("Every model type listed in SchemaV1 is covered by the round-trip test below")
    func schemaModelCountMatchesCoverage() {
        // If this fails a model was added to SchemaV1 without a corresponding insert/fetch/delete
        // case in `everyModelRoundTrips`.
        #expect(SchemaV1.models.count == 26)
    }

    @Test("Every model in SchemaV1 can be inserted, fetched and deleted")
    func everyModelRoundTrips() throws {
        let context = try StoreTestSupport.makeContext()

        try roundTrip(in: context) { UserProfile() }
        try roundTrip(in: context) { EquipmentProfile() }
        try roundTrip(in: context) { UserSettings() }
        try roundTrip(in: context) { ExercisePreference(exerciseID: "E-BENCH") }
        try roundTrip(in: context) { TrainingProgram() }
        try roundTrip(in: context) { ProgramVersion() }
        try roundTrip(in: context) { WorkoutTemplate() }
        try roundTrip(in: context) { PlannedExercise() }
        try roundTrip(in: context) { WorkoutSession() }
        try roundTrip(in: context) { ExerciseSession() }
        try roundTrip(in: context) { SetRecord() }
        try roundTrip(in: context) { PersonalRecord() }
        try roundTrip(in: context) { BodyWeightEntry() }
        try roundTrip(in: context) { RecoveryEntry() }
        try roundTrip(in: context) { ProgressionState(exerciseID: "E-BENCH") }
        try roundTrip(in: context) { DeloadRecommendation() }
        try roundTrip(in: context) { FoodItem() }
        try roundTrip(in: context) { FoodLogEntry() }
        try roundTrip(in: context) { SavedMeal() }
        try roundTrip(in: context) { SavedMealItem() }
        try roundTrip(in: context) { Recipe() }
        try roundTrip(in: context) { RecipeIngredient() }
        try roundTrip(in: context) { DailyNutritionTarget() }
        try roundTrip(in: context) { NutritionTargetHistory() }
        try roundTrip(in: context) { WaterLogEntry() }
        try roundTrip(in: context) { Achievement(code: "first-workout") }
    }

    private func roundTrip<T: PersistentModel>(
        in context: ModelContext,
        _ make: () -> T,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let row = make()
        context.insert(row)
        try context.save()
        #expect(
            try context.fetchCount(FetchDescriptor<T>()) == 1,
            "\(T.self) could not be inserted and fetched",
            sourceLocation: sourceLocation
        )

        context.delete(row)
        try context.save()
        #expect(
            try context.fetchCount(FetchDescriptor<T>()) == 0,
            "\(T.self) survived deletion",
            sourceLocation: sourceLocation
        )
    }

    @Test("Stored values survive a save and a fresh fetch")
    func storedValuesSurviveAFetch() throws {
        let context = try StoreTestSupport.makeContext()
        let entry = BodyWeightEntry(date: StoreTestSupport.epoch, weightKg: 81.4, isFromHealthKit: true)
        entry.note = "morning, after coffee"
        context.insert(entry)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<BodyWeightEntry>()).first)
        #expect(fetched.weightKg == 81.4)
        #expect(fetched.date == StoreTestSupport.epoch)
        #expect(fetched.isFromHealthKit)
        #expect(fetched.note == "morning, after coffee")
    }

    @Test("A Micronutrients value survives a store round trip with unknowns still unknown")
    func micronutrientsSurviveAStoreRoundTrip() throws {
        let context = try StoreTestSupport.makeContext()
        var micros = Micronutrients.unknown
        micros.fiberG = 4.5
        micros.sodiumMg = 0

        let food = FoodItem()
        food.name = "Test food"
        food.micronutrientsPer100 = micros
        context.insert(food)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<FoodItem>()).first)
        #expect(fetched.micronutrientsPer100.fiberG == 4.5)
        // Zero and nil must stay distinguishable: "contains none" is not "we do not know".
        #expect(fetched.micronutrientsPer100.sodiumMg == 0)
        #expect(fetched.micronutrientsPer100.calciumMg == nil)
    }
}

// MARK: - Cascade rules

@MainActor
@Suite("Cascade delete rules")
struct PersistenceCascadeTests {

    /// Builds a finished session with two exercises and two sets each.
    private func makeSession(in context: ModelContext) -> WorkoutSession {
        let session = WorkoutSession()
        session.titleSnapshot = "Upper A"
        session.startedAt = StoreTestSupport.epoch
        context.insert(session)

        for (index, exerciseID) in ["E-BENCH", "E-ROW"].enumerated() {
            let record = ExerciseSession()
            record.exerciseID = exerciseID
            record.exerciseNameSnapshot = exerciseID
            record.orderIndex = index
            record.workout = session
            context.insert(record)

            for setIndex in 0..<2 {
                let set = SetRecord()
                set.setIndex = setIndex
                set.weightKg = 60
                set.reps = 8
                set.isCompleted = true
                set.exerciseSession = record
                context.insert(set)
            }
        }
        return session
    }

    @Test("Deleting a workout session removes its exercise sessions and set records")
    func deletingASessionCascadesToSetsAndExercises() throws {
        let context = try StoreTestSupport.makeContext()
        let session = makeSession(in: context)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<ExerciseSession>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<SetRecord>()) == 4)

        context.delete(session)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<WorkoutSession>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ExerciseSession>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SetRecord>()) == 0)
    }

    @Test("Deleting one session leaves another session's rows alone")
    func deletingOneSessionLeavesTheOtherIntact() throws {
        let context = try StoreTestSupport.makeContext()
        let first = makeSession(in: context)
        _ = makeSession(in: context)
        try context.save()

        context.delete(first)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<WorkoutSession>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ExerciseSession>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<SetRecord>()) == 4)
    }

    @Test("Deleting one exercise session removes only its own sets")
    func deletingAnExerciseSessionRemovesOnlyItsSets() throws {
        let context = try StoreTestSupport.makeContext()
        let session = makeSession(in: context)
        try context.save()

        let victim = try #require(session.orderedExercises.first)
        context.delete(victim)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<WorkoutSession>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<ExerciseSession>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<SetRecord>()) == 2)
    }

    @Test("Deleting a training program removes its templates, planned exercises and versions")
    func deletingAProgramCascadesToTemplatesAndPlannedExercises() throws {
        let context = try StoreTestSupport.makeContext()
        let program = StoreTestSupport.makeProgram(
            in: context,
            exercises: [("E-BENCH", 3, RepRange(8, 12)), ("E-ROW", 4, RepRange(6, 10))]
        )
        let version = ProgramVersion()
        version.versionNumber = 1
        version.reasonKey = "program.version.created"
        version.program = program
        context.insert(version)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PlannedExercise>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<ProgramVersion>()) == 1)

        context.delete(program)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<TrainingProgram>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PlannedExercise>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ProgramVersion>()) == 0)
    }

    @Test("Deleting a template removes only its own planned exercises")
    func deletingATemplateRemovesOnlyItsPlannedExercises() throws {
        let context = try StoreTestSupport.makeContext()
        let program = StoreTestSupport.makeProgram(
            in: context, exercises: [("E-BENCH", 3, RepRange(8, 12))]
        )
        let second = WorkoutTemplate()
        second.customTitle = "Lower A"
        second.orderIndex = 1
        second.program = program
        context.insert(second)
        let planned = PlannedExercise()
        planned.exerciseID = "E-SQUAT"
        planned.template = second
        context.insert(planned)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<PlannedExercise>()) == 2)

        context.delete(second)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<TrainingProgram>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<WorkoutTemplate>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PlannedExercise>()) == 1)
        let survivor = try #require(try context.fetch(FetchDescriptor<PlannedExercise>()).first)
        #expect(survivor.exerciseID == "E-BENCH")
    }

    @Test("Deleting a saved meal removes its items")
    func deletingASavedMealCascadesToItems() throws {
        let context = try StoreTestSupport.makeContext()
        let meal = SavedMeal()
        meal.name = "Usual breakfast"
        context.insert(meal)
        for index in 0..<3 {
            let item = SavedMealItem()
            item.orderIndex = index
            item.foodNameSnapshot = "Food \(index)"
            item.meal = meal
            context.insert(item)
        }
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<SavedMealItem>()) == 3)

        context.delete(meal)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<SavedMeal>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<SavedMealItem>()) == 0)
    }

    @Test("Deleting a recipe removes its ingredients")
    func deletingARecipeCascadesToIngredients() throws {
        let context = try StoreTestSupport.makeContext()
        let recipe = Recipe()
        recipe.name = "Chilli"
        context.insert(recipe)
        for index in 0..<4 {
            let ingredient = RecipeIngredient()
            ingredient.orderIndex = index
            ingredient.foodNameSnapshot = "Ingredient \(index)"
            ingredient.recipe = recipe
            context.insert(ingredient)
        }
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<RecipeIngredient>()) == 4)

        context.delete(recipe)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Recipe>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RecipeIngredient>()) == 0)
    }

    @Test("Deleting a food does not cascade into the log entries that referenced it")
    func deletingAFoodDoesNotCascadeIntoTheLog() throws {
        let context = try StoreTestSupport.makeContext()
        let food = StoreTestSupport.makeFood(in: context, name: "Oats")
        let entry = FoodLogEntry()
        entry.dayKey = "2024-06-03"
        entry.foodID = food.id
        entry.foodNameSnapshot = food.name
        entry.macrosSnapshot = MacroNutrients(kilocalories: 100, proteinG: 10, carbsG: 5, fatG: 2)
        context.insert(entry)
        try context.save()

        context.delete(food)
        try context.save()

        // The log entry is history and must outlive the food it points at.
        #expect(try context.fetchCount(FetchDescriptor<FoodItem>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<FoodLogEntry>()) == 1)
    }
}
