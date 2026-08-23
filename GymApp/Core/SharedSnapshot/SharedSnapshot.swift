import Foundation

/// A small, self-contained picture of the user's day, written by the app and read by the widget
/// extension.
///
/// The widget deliberately does **not** open the SwiftData store. Sharing a live database across
/// processes means sharing the whole schema, the migration plan and the failure modes with a
/// timeline provider that gets a fraction of a second to run. A ~1 KB JSON file in the shared App
/// Group container is faster, cannot be corrupted by a widget refresh, and keeps the widget target
/// compiling against three types instead of thirty.
struct SharedSnapshot: Codable, Hashable, Sendable {
    static let appGroupIdentifier = "group.com.gymapp.forge"
    static let fileName = "snapshot.json"
    static let schemaVersion = 1

    var version: Int = SharedSnapshot.schemaVersion
    var generatedAt: Date = Date()

    // Training
    var nextWorkoutTitle: String?
    var nextWorkoutFocus: [String] = []
    var nextWorkoutExerciseCount: Int = 0
    var nextWorkoutEstimatedMinutes: Int = 0
    var nextWorkoutDate: Date?
    var isRestDay: Bool = false
    var hasActiveWorkout: Bool = false
    var activeWorkoutTitle: String?
    var activeWorkoutStartedAt: Date?
    var completedSetsThisWeek: Int = 0
    var completedWorkoutsThisWeek: Int = 0
    var plannedWorkoutsThisWeek: Int = 0
    var currentStreakDays: Int = 0

    // Nutrition
    var nutritionEnabled: Bool = true
    var caloriesConsumed: Double = 0
    var caloriesTarget: Double = 0
    var proteinConsumedG: Double = 0
    var proteinTargetG: Double = 0
    var carbsConsumedG: Double = 0
    var carbsTargetG: Double = 0
    var fatConsumedG: Double = 0
    var fatTargetG: Double = 0

    // Body
    var latestWeightKg: Double?
    var weightTrendKg: Double?
    var usesPounds: Bool = false

    static var placeholder: SharedSnapshot {
        var snapshot = SharedSnapshot()
        snapshot.nextWorkoutTitle = "Upper Body A"
        snapshot.nextWorkoutFocus = ["Chest", "Back", "Shoulders"]
        snapshot.nextWorkoutExerciseCount = 6
        snapshot.nextWorkoutEstimatedMinutes = 58
        snapshot.completedWorkoutsThisWeek = 2
        snapshot.plannedWorkoutsThisWeek = 4
        snapshot.currentStreakDays = 12
        snapshot.caloriesConsumed = 1480
        snapshot.caloriesTarget = 2600
        snapshot.proteinConsumedG = 118
        snapshot.proteinTargetG = 175
        snapshot.carbsConsumedG = 152
        snapshot.carbsTargetG = 290
        snapshot.fatConsumedG = 46
        snapshot.fatTargetG = 78
        snapshot.latestWeightKg = 78.4
        snapshot.weightTrendKg = 78.1
        return snapshot
    }
}

/// Reads and writes the shared snapshot file. Used by the app (write) and the widget (read).
struct SharedSnapshotStore {
    static let shared = SharedSnapshotStore()

    /// The App Group container, or `nil` when the entitlement is unavailable — in which case the
    /// widget simply shows its placeholder rather than failing.
    var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedSnapshot.appGroupIdentifier)
    }

    private var fileURL: URL? {
        containerURL?.appendingPathComponent(SharedSnapshot.fileName)
    }

    func read() -> SharedSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let snapshot = try? JSONDecoder.snapshotDecoder.decode(SharedSnapshot.self, from: data) else {
            return nil
        }
        // A snapshot written by a newer app version is ignored rather than mis-rendered.
        guard snapshot.version <= SharedSnapshot.schemaVersion else { return nil }
        return snapshot
    }

    @discardableResult
    func write(_ snapshot: SharedSnapshot) -> Bool {
        guard let fileURL else { return false }
        guard let data = try? JSONEncoder.snapshotEncoder.encode(snapshot) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

extension JSONEncoder {
    static var snapshotEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var snapshotDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
