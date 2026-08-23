import Foundation
import SwiftData

/// Owns the SwiftData stack.
///
/// The schema is declared in one place and versioned from day one (`SchemaV1`), with a
/// `SchemaMigrationPlan` already wired up, so shipping a v2 model is an additive change rather than
/// a rewrite. The store lives in the app's Application Support directory; nothing leaves the
/// device unless the user explicitly exports or enables Health sync.
enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            UserProfile.self,
            EquipmentProfile.self,
            UserSettings.self,
            ExercisePreference.self,
            TrainingProgram.self,
            ProgramVersion.self,
            WorkoutTemplate.self,
            PlannedExercise.self,
            WorkoutSession.self,
            ExerciseSession.self,
            SetRecord.self,
            PersonalRecord.self,
            BodyWeightEntry.self,
            RecoveryEntry.self,
            ProgressionState.self,
            DeloadRecommendation.self,
            FoodItem.self,
            FoodLogEntry.self,
            SavedMeal.self,
            SavedMealItem.self,
            Recipe.self,
            RecipeIngredient.self,
            DailyNutritionTarget.self,
            NutritionTargetHistory.self,
            WaterLogEntry.self,
            Achievement.self,
        ]
    }
}

/// Migration stages are appended here as schema versions are added. Declaring the plan now means a
/// future `SchemaV2` only needs a stage, never a store reset.
enum GymAppMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

@MainActor
enum PersistenceController {
    static let schema = Schema(versionedSchema: SchemaV1.self)

    /// The on-disk container used by the running app.
    ///
    /// `groupContainer` is pinned to `.none` rather than left at its `.automatic` default. The app
    /// declares an App Group so the widget can read a snapshot file, and `.automatic` interprets
    /// that entitlement as "put the database in the group container" — a directory the widget never
    /// needs and whose `Application Support` folder does not exist until something creates it, so
    /// the store fails to open and the app silently falls back to memory. Keeping the store in the
    /// app's own container also means a widget refresh can never contend with it.
    ///
    /// `cloudKitDatabase` is `.none` for the same reason: the entitlement's presence must not
    /// switch on sync that has not been designed or tested.
    static func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "GymApp",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: GymAppMigrationPlan.self,
            configurations: configuration
        )
    }

    /// An ephemeral container for previews and tests. Never touches the user's store.
    static func makeInMemoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "GymAppPreview",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    /// Builds the real container, falling back to an in-memory store if the on-disk one cannot be
    /// opened. A corrupt store must degrade into a usable (if empty) app, never a launch crash;
    /// `didFallBackToMemory` lets the UI tell the user what happened.
    static func makeResilientContainer() -> (container: ModelContainer, didFallBackToMemory: Bool) {
        do {
            return (try makeContainer(), false)
        } catch {
            AppLog.persistence.error("Failed to open the on-disk store: \(String(describing: error))")
            do {
                return (try makeInMemoryContainer(), true)
            } catch {
                // An in-memory container failing means the schema itself is invalid, which is a
                // programmer error that must surface loudly during development.
                fatalError("Unable to create any model container: \(error)")
            }
        }
    }
}
