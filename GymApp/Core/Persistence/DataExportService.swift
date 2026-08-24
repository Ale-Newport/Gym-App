import Foundation
import SwiftData

/// What the user chose to export.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case trainingCSV
    case trainingJSON
    case nutritionCSV
    case nutritionJSON
    case fullBackup

    var id: String { rawValue }
    var localizationKey: String { "export.\(rawValue)" }
    var detailLocalizationKey: String { "export.\(rawValue).detail" }

    var fileExtension: String {
        switch self {
        case .trainingCSV, .nutritionCSV: "csv"
        case .trainingJSON, .nutritionJSON, .fullBackup: "json"
        }
    }

    var symbolName: String {
        switch self {
        case .trainingCSV, .trainingJSON: "figure.strengthtraining.traditional"
        case .nutritionCSV, .nutritionJSON: "fork.knife"
        case .fullBackup: "externaldrive.fill"
        }
    }
}

/// Writes the user's data out to a file they own.
///
/// Export exists so the data is never hostage to this app. CSV covers the "open it in a
/// spreadsheet" case; the full backup is a versioned JSON document that `DataImportService` can
/// read back, including on a different device.
@MainActor
struct DataExportService {
    static let backupSchemaVersion = 1

    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Produces the export and returns the URL of a file in the caller's temporary directory.
    func export(_ format: ExportFormat) throws -> URL {
        let data: Data
        switch format {
        case .trainingCSV: data = Data(try trainingCSV().utf8)
        case .trainingJSON: data = try trainingJSON()
        case .nutritionCSV: data = Data(try nutritionCSV().utf8)
        case .nutritionJSON: data = try nutritionJSON()
        case .fullBackup: data = try fullBackup()
        }

        let stamp = Self.fileStampFormatter.string(from: Date())
        let name = "forge-\(format.rawValue)-\(stamp).\(format.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - CSV

    /// Escapes a CSV field. Quotes are doubled and any field containing a delimiter, quote or
    /// newline is quoted — the rules from RFC 4180, which is what spreadsheets actually expect.
    static func csvField(_ value: String) -> String {
        // Scalars, not Characters. Swift treats CR-LF as a *single* grapheme cluster, so a field
        // containing a Windows line break matches neither "\n" nor "\r" as a Character and would
        // slip through unquoted — splitting one row into two in any spreadsheet that opened it.
        let needsQuoting = value.unicodeScalars.contains {
            $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r"
        }
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func csvRow(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    func trainingCSV() throws -> String {
        let sessions = try context.fetch(
            FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startedAt)])
        )
        var lines = [Self.csvRow([
            "date", "session", "status", "exercise", "exercise_id", "set", "set_type",
            "weight_kg", "reps", "duration_s", "distance_m", "rir", "rpe", "completed",
            "volume_kg", "notes",
        ])]

        for session in sessions {
            for exercise in session.orderedExercises {
                for set in exercise.orderedSets {
                    lines.append(Self.csvRow([
                        Self.isoFormatter.string(from: set.completedAt ?? session.startedAt),
                        session.titleSnapshot,
                        session.status.rawValue,
                        exercise.exerciseNameSnapshot,
                        exercise.exerciseID,
                        String(set.setIndex + 1),
                        set.kind.rawValue,
                        set.weightKg.map { Self.number($0) } ?? "",
                        set.reps.map(String.init) ?? "",
                        set.durationSeconds.map(String.init) ?? "",
                        set.distanceMeters.map { Self.number($0) } ?? "",
                        set.rir.map(String.init) ?? "",
                        set.rpe.map { Self.number($0) } ?? "",
                        set.isCompleted ? "true" : "false",
                        Self.number(set.volumeKg),
                        set.notes ?? "",
                    ]))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func nutritionCSV() throws -> String {
        let entries = try context.fetch(
            FetchDescriptor<FoodLogEntry>(sortBy: [SortDescriptor(\.loggedAt)])
        )
        var lines = [Self.csvRow([
            "day", "logged_at", "meal", "food", "brand", "quantity", "unit",
            "kcal", "protein_g", "carbs_g", "fat_g", "fiber_g", "sodium_mg",
        ])]

        for entry in entries {
            lines.append(Self.csvRow([
                entry.dayKey,
                Self.isoFormatter.string(from: entry.loggedAt),
                entry.mealSlot.rawValue,
                entry.foodNameSnapshot,
                entry.brandSnapshot ?? "",
                Self.number(entry.quantity),
                entry.unit.rawValue,
                Self.number(entry.macrosSnapshot.kilocalories),
                Self.number(entry.macrosSnapshot.proteinG),
                Self.number(entry.macrosSnapshot.carbsG),
                Self.number(entry.macrosSnapshot.fatG),
                entry.micronutrientsSnapshot.fiberG.map { Self.number($0) } ?? "",
                entry.micronutrientsSnapshot.sodiumMg.map { Self.number($0) } ?? "",
            ]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Formats a number for export: locale-independent, at most two decimals, no trailing zeros.
    /// Export files are read by machines, so a comma decimal separator would corrupt the CSV.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if abs(value.rounded() - value) < 0.005 { return String(Int(value.rounded())) }
        return String(format: "%.2f", value)
    }

    // MARK: - JSON

    func trainingJSON() throws -> Data {
        let sessions = try context.fetch(
            FetchDescriptor<WorkoutSession>(sortBy: [SortDescriptor(\.startedAt)])
        )
        let payload = TrainingExport(
            schemaVersion: Self.backupSchemaVersion,
            exportedAt: Date(),
            sessions: sessions.map(SessionExport.init)
        )
        return try Self.encoder.encode(payload)
    }

    func nutritionJSON() throws -> Data {
        let entries = try context.fetch(
            FetchDescriptor<FoodLogEntry>(sortBy: [SortDescriptor(\.loggedAt)])
        )
        let targets = try context.fetch(FetchDescriptor<DailyNutritionTarget>())
        let payload = NutritionExport(
            schemaVersion: Self.backupSchemaVersion,
            exportedAt: Date(),
            entries: entries.map(FoodLogExport.init),
            targets: targets.map(NutritionTargetExport.init)
        )
        return try Self.encoder.encode(payload)
    }

    func fullBackup() throws -> Data {
        let backup = BackupDocument(
            schemaVersion: Self.backupSchemaVersion,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            exportedAt: Date(),
            profile: try context.fetch(FetchDescriptor<UserProfile>()).first.map(ProfileExport.init),
            settings: try context.fetch(FetchDescriptor<UserSettings>()).first.map(SettingsExport.init),
            equipment: try context.fetch(FetchDescriptor<EquipmentProfile>()).first.map(EquipmentExport.init),
            preferences: try context.fetch(FetchDescriptor<ExercisePreference>()).map(PreferenceExport.init),
            programs: try context.fetch(FetchDescriptor<TrainingProgram>()).map(ProgramExport.init),
            sessions: try context.fetch(FetchDescriptor<WorkoutSession>()).map(SessionExport.init),
            personalRecords: try context.fetch(FetchDescriptor<PersonalRecord>()).map(PersonalRecordExport.init),
            bodyWeights: try context.fetch(FetchDescriptor<BodyWeightEntry>()).map(BodyWeightExport.init),
            recoveryEntries: try context.fetch(FetchDescriptor<RecoveryEntry>()).map(RecoveryExport.init),
            progressionStates: try context.fetch(FetchDescriptor<ProgressionState>()).map(ProgressionStateExport.init),
            customFoods: try context.fetch(FetchDescriptor<FoodItem>())
                .filter { $0.source == .custom }
                .map(FoodExport.init),
            foodLog: try context.fetch(FetchDescriptor<FoodLogEntry>()).map(FoodLogExport.init),
            savedMeals: try context.fetch(FetchDescriptor<SavedMeal>()).map(SavedMealExport.init),
            recipes: try context.fetch(FetchDescriptor<Recipe>()).map(RecipeExport.init),
            nutritionTargets: try context.fetch(FetchDescriptor<DailyNutritionTarget>()).map(NutritionTargetExport.init),
            waterLog: try context.fetch(FetchDescriptor<WaterLogEntry>()).map(WaterExport.init),
            achievements: try context.fetch(FetchDescriptor<Achievement>()).map(AchievementExport.init)
        )
        return try Self.encoder.encode(backup)
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
