import Foundation
import SwiftData

/// The user's standing opinions about individual exercises.
///
/// A preference row is created lazily, on the first opinion the user expresses. That matters: the
/// catalogue holds over a thousand exercises, and pre-seeding a row per exercise would turn a
/// no-opinion default into thirteen hundred rows of nothing. An absent row therefore means exactly
/// "no opinion", which is also what `ExercisePreferenceSnapshot`'s defaults encode.
///
/// The engines never ask about one exercise at a time — the selector scores hundreds of candidates
/// in a single pass — so `snapshots()` returns the whole table in one fetch rather than offering a
/// per-exercise lookup that would be called in a loop.
@MainActor
struct ExercisePreferenceRepository: Repository {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Fetching

    /// The stored row for an exercise, or `nil` when the user has never expressed an opinion.
    func existingPreference(for exerciseID: String) throws -> ExercisePreference? {
        try fetchFirst(FetchDescriptor<ExercisePreference>(
            predicate: #Predicate { $0.exerciseID == exerciseID }
        ))
    }

    /// The stored row for an exercise, created if it does not exist yet.
    @discardableResult
    func preference(for exerciseID: String) throws -> ExercisePreference {
        if let existing = try existingPreference(for: exerciseID) { return existing }
        let created = ExercisePreference(exerciseID: exerciseID)
        context.insert(created)
        try persist()
        return created
    }

    /// Every preference the user has expressed, keyed by exercise id. One fetch.
    func snapshots() throws -> [String: ExercisePreferenceSnapshot] {
        let rows = try fetch(FetchDescriptor<ExercisePreference>())
        return Dictionary(rows.map { ($0.exerciseID, Self.snapshot(of: $0)) }) { first, _ in first }
    }

    /// Preferences for a specific set of exercises, in one fetch. Ids with no row are absent from
    /// the result rather than filled with a default, so the caller can tell "no opinion" apart from
    /// "explicitly neutral".
    func snapshots(forExerciseIDs exerciseIDs: [String]) throws -> [String: ExercisePreferenceSnapshot] {
        let ids = Array(Set(exerciseIDs))
        guard !ids.isEmpty else { return [:] }
        let rows = try fetch(FetchDescriptor<ExercisePreference>(
            predicate: #Predicate { ids.contains($0.exerciseID) }
        ))
        return Dictionary(rows.map { ($0.exerciseID, Self.snapshot(of: $0)) }) { first, _ in first }
    }

    /// Converts a stored row into the value type the engines take.
    static func snapshot(of preference: ExercisePreference) -> ExercisePreferenceSnapshot {
        ExercisePreferenceSnapshot(
            exerciseID: preference.exerciseID,
            isFavorite: preference.isFavorite,
            feedback: preference.feedback,
            isExcluded: preference.isExcluded,
            customIncrementKg: preference.customIncrementKg,
            timesPerformed: preference.timesPerformed,
            lastPerformedAt: preference.lastPerformedAt
        )
    }

    // MARK: - Lists

    /// Favourited exercise ids, most recently used first so the list stays useful as it grows.
    func favoriteIDs() throws -> [String] {
        let rows = try fetch(FetchDescriptor<ExercisePreference>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
        return rows.map(\.exerciseID)
    }

    /// Exercise ids the user has excluded from automatic selection. They remain browsable in the
    /// library; exclusion is a statement about the *plan*, not about the exercise's existence.
    func excludedIDs() throws -> [String] {
        let rows = try fetch(FetchDescriptor<ExercisePreference>(
            predicate: #Predicate { $0.isExcluded },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
        return rows.map(\.exerciseID)
    }

    /// Exercise ids performed most recently, newest first.
    ///
    /// Read from the preference table rather than from session history because the programming
    /// engine only needs "have I done this lately?" for its variety penalty, and this is a single
    /// indexed fetch against a table with one row per exercise the user has ever touched.
    func recentlyPerformedIDs(limit: Int = 40, since: Date? = nil) throws -> [String] {
        var descriptor = FetchDescriptor<ExercisePreference>(
            sortBy: [SortDescriptor(\.lastPerformedAt, order: .reverse)]
        )
        if let since {
            // The fallback is bound to a local constant: `#Predicate` can translate a captured value
            // but not a key path into `Date.distantPast`.
            let never = Date.distantPast
            descriptor.predicate = #Predicate { ($0.lastPerformedAt ?? never) >= since }
        } else {
            descriptor.predicate = #Predicate { $0.lastPerformedAt != nil }
        }
        descriptor.fetchLimit = max(0, limit)
        return try fetch(descriptor).map(\.exerciseID)
    }

    /// Exercises with an explicit opinion attached, for the "my exercises" screen.
    func allPreferences() throws -> [ExercisePreference] {
        try fetch(FetchDescriptor<ExercisePreference>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
    }

    // MARK: - Mutations

    func setFavorite(_ isFavorite: Bool, forExerciseID exerciseID: String, now: Date = Date()) throws {
        let preference = try preference(for: exerciseID)
        preference.isFavorite = isFavorite
        preference.updatedAt = now
        try persist()
    }

    /// Records how the user feels about an exercise.
    ///
    /// `.neverRecommend` is deliberately *not* the same as exclusion: it zeroes the selection score
    /// but leaves the exercise available for the user to pick by hand, whereas exclusion is a hard
    /// filter. Keeping the two separate lets someone say "stop suggesting this" without losing the
    /// ability to do it when they feel like it.
    func setFeedback(_ feedback: ExerciseFeedback, forExerciseID exerciseID: String, now: Date = Date()) throws {
        let preference = try preference(for: exerciseID)
        preference.feedback = feedback
        preference.updatedAt = now
        try persist()
    }

    func setExcluded(_ isExcluded: Bool, forExerciseID exerciseID: String, now: Date = Date()) throws {
        let preference = try preference(for: exerciseID)
        preference.isExcluded = isExcluded
        preference.updatedAt = now
        try persist()
    }

    /// Overrides the load step for one movement.
    ///
    /// Some gyms stock 1 kg micro-plates for pressing but nothing below 5 kg on the leg press, and
    /// the equipment-wide increment cannot express that. Passing `nil` returns the movement to the
    /// equipment default.
    func setCustomIncrement(kg increment: Double?, forExerciseID exerciseID: String, now: Date = Date()) throws {
        let preference = try preference(for: exerciseID)
        if let increment {
            preference.customIncrementKg = try InputValidation.increment(
                kg: increment, field: "customIncrementKg"
            )
        } else {
            preference.customIncrementKg = nil
        }
        preference.updatedAt = now
        try persist()
    }

    func setNotes(_ notes: String?, forExerciseID exerciseID: String, now: Date = Date()) throws {
        let preference = try preference(for: exerciseID)
        preference.notes = InputValidation.sanitisedNote(notes)
        preference.updatedAt = now
        try persist()
    }

    /// Clears an opinion back to neutral without deleting the usage counters.
    func clearOpinion(forExerciseID exerciseID: String, now: Date = Date()) throws {
        guard let preference = try existingPreference(for: exerciseID) else { return }
        preference.isFavorite = false
        preference.feedback = .neutral
        preference.isExcluded = false
        preference.updatedAt = now
        try persist()
    }

    // MARK: - Usage counters

    /// Records that a set of exercises was performed, in one save.
    ///
    /// Called once when a session finishes rather than per set, so `timesPerformed` counts *sessions
    /// containing the exercise*, which is the unit the variety penalty and the "you have done this
    /// 14 times" copy both mean. Duplicated ids in the argument count once for the same reason.
    func recordPerformed(exerciseIDs: [String], at date: Date = Date()) throws {
        let ids = Array(Set(exerciseIDs))
        guard !ids.isEmpty else { return }

        let existing = try fetch(FetchDescriptor<ExercisePreference>(
            predicate: #Predicate { ids.contains($0.exerciseID) }
        ))
        var byID = Dictionary(existing.map { ($0.exerciseID, $0) }) { first, _ in first }

        for exerciseID in ids {
            let preference: ExercisePreference
            if let found = byID[exerciseID] {
                preference = found
            } else {
                preference = ExercisePreference(exerciseID: exerciseID)
                context.insert(preference)
                byID[exerciseID] = preference
            }
            preference.timesPerformed += 1
            // Never move the marker backwards: importing an old session must not make a recent
            // exercise look stale to the variety penalty.
            if (preference.lastPerformedAt ?? .distantPast) < date {
                preference.lastPerformedAt = date
            }
            preference.updatedAt = date
        }
        try persist()
    }

    /// Undoes one usage tick. Used when a finished session is deleted, so the counters stay honest.
    func undoPerformed(exerciseIDs: [String], now: Date = Date()) throws {
        let ids = Array(Set(exerciseIDs))
        guard !ids.isEmpty else { return }
        let existing = try fetch(FetchDescriptor<ExercisePreference>(
            predicate: #Predicate { ids.contains($0.exerciseID) }
        ))
        for preference in existing {
            preference.timesPerformed = max(0, preference.timesPerformed - 1)
            preference.updatedAt = now
        }
        try persist()
    }
}
