import Foundation
import SwiftData

// MARK: - Errors

/// Every failure a repository can surface.
///
/// The repositories are the only place in the app where SwiftData can fail, and a failed `save()`
/// in a fitness app is not cosmetic: it is a lost set, a lost meal or a lost body-mass reading. So
/// no repository method ever swallows a store error — it is wrapped here and thrown, and the caller
/// decides whether to retry or to tell the user.
///
/// Each case carries an `Explanation` rather than finished English text, because the same error may
/// be shown after the user has switched language, and because the alert copy is a translator's
/// concern rather than a persistence concern.
enum RepositoryError: Error, Hashable, Sendable {
    /// `ModelContext.save()` refused. The associated value is the underlying description, which is
    /// logged but never shown: store errors are meaningless to the person holding the phone.
    case saveFailed(underlying: String)
    /// A fetch could not be executed — a malformed predicate or an unreadable store.
    case fetchFailed(underlying: String)
    /// A row the caller referenced no longer exists. `entity` is a stable identifier such as
    /// `"foodItem"`, used only for the localisation key.
    case notFound(entity: String)
    /// The caller supplied a value the app cannot act on. See `InputValidation`.
    case invalidInput(ValidationIssue)
    /// The row exists but the caller may not change it — for example a built-in food.
    case notEditable(entity: String)
    /// The row is still referenced by something that would break if it disappeared.
    case stillReferenced(entity: String, referenceCount: Int)
    /// Encoding or decoding a stored JSON snapshot failed.
    case snapshotCodingFailed(underlying: String)

    /// A localisation key plus arguments describing the failure in neutral terms.
    var explanation: Explanation {
        switch self {
        case .saveFailed:
            return Explanation("repo.error.saveFailed")
        case .fetchFailed:
            return Explanation("repo.error.fetchFailed")
        case .notFound:
            // The entity name is a stable internal identifier, not translatable copy, so it stays
            // out of the message and lives in `diagnosticDetail` instead.
            return Explanation("repo.error.notFound")
        case .invalidInput(let issue):
            return issue.explanation
        case .notEditable:
            return Explanation("repo.error.notEditable")
        case .stillReferenced(_, let count):
            return Explanation("repo.error.stillReferenced", [String(count)])
        case .snapshotCodingFailed:
            return Explanation("repo.error.snapshotCodingFailed")
        }
    }

    /// Technical detail for the log. Deliberately separate from `explanation` so diagnostics never
    /// leak into the interface.
    var diagnosticDetail: String? {
        switch self {
        case .saveFailed(let underlying), .fetchFailed(let underlying),
             .snapshotCodingFailed(let underlying):
            return underlying
        case .notFound(let entity), .notEditable(let entity):
            return entity
        case .stillReferenced(let entity, let count):
            return "\(entity) referenced \(count) time(s)"
        case .invalidInput(let issue):
            return "\(issue.field): \(issue.explanation.key)"
        }
    }
}

/// One rejected input, identified by the field it came from.
struct ValidationIssue: Error, Hashable, Sendable {
    /// Stable field identifier, e.g. `"heightCm"`. Used for logs and to focus the offending control.
    let field: String
    let explanation: Explanation

    init(field: String, key: String, arguments: [String] = []) {
        self.field = field
        self.explanation = Explanation(key, arguments)
    }
}

// MARK: - Validation

/// The single place that decides which numbers the app will accept.
///
/// Two principles drive every bound below.
///
/// 1. **Reject the impossible, permit the unusual.** A 47 kg powerlifter and a 190 kg strongman are
///    both real people; 0.5 kg and 4,000 kg are typing mistakes. The ranges are therefore wide
///    enough that no genuine user is ever told their body is invalid, and tight enough that a
///    mis-keyed value cannot poison a trend line or a calorie target for weeks.
/// 2. **Clamp what is merely out of shape, throw what is meaningless.** Asking for 40 sets is an
///    over-ambitious intent the app can honour partially, so it is clamped to the ceiling. A height
///    of 1,750 cm carries no intent at all, so it is refused and the user is asked again.
///
/// Messages are factual and never evaluative: the app says what range it accepts, and does not
/// comment on the number the user typed.
enum InputValidation {

    // MARK: Ranges

    /// 50 cm covers a toddler, 260 cm exceeds the tallest recorded adult. Anything outside is a typo.
    static let heightCm: ClosedRange<Double> = 50...260
    /// Covers every plausible body mass and every plausible lifted load target the user might store.
    static let bodyMassKg: ClosedRange<Double> = 20...400
    /// Below 10 the app is not appropriate; above 120 the value cannot be a birth date.
    static let ageYears: ClosedRange<Int> = 10...120
    /// 20 sets on one exercise is already far past any evidence-backed dose; it is the hard ceiling.
    static let setsPerExercise: ClosedRange<Int> = 1...20
    /// 0 permits logging a failed attempt; 500 covers high-rep bodyweight and skipping-style work.
    static let reps: ClosedRange<Int> = 0...500
    /// Above 1,000 kg no barbell exists; 0 is legitimate for unloaded and assisted movements.
    static let loadKg: ClosedRange<Double> = 0...1000
    /// A target below 500 kcal is not a diet the app will help construct; above 10,000 is a typo.
    static let kilocalories: ClosedRange<Double> = 500...10000
    /// Grams of a single macronutrient in a day, or in one logged portion.
    static let macroGrams: ClosedRange<Double> = 0...2000
    static let daysPerWeek: ClosedRange<Int> = 1...7
    /// Ten minutes is the shortest session worth programming; five hours is the longest worth capping.
    static let sessionMinutes: ClosedRange<Int> = 10...300
    /// The step a machine stack, a cable stack or one movement moves in. Zero would make progression
    /// impossible; 0.25 kg is the smallest micro-plate anybody stocks, and 50 kg is a bigger jump
    /// than any single selectorised stack makes.
    static let loadIncrementKg: ClosedRange<Double> = 0.25...50
    /// The weight of one named serving, or of one natural piece, in grams.
    static let servingGrams: ClosedRange<Double> = 0.1...10000
    /// Energy per 100 g of a food. Pure fat is 900 kcal; anything above 1,000 is a typo.
    static let energyDensityPer100: ClosedRange<Double> = 0...1000
    /// Grams of one macronutrient per 100 g of a food. A food cannot be more than entirely one
    /// macronutrient, so this one is clamped rather than thrown.
    static let macroDensityPer100: ClosedRange<Double> = 0...100

    // Secondary bounds, all clamped rather than thrown: none of them can make a record meaningless.
    static let restSeconds: ClosedRange<Int> = 0...900
    static let repsInReserve: ClosedRange<Int> = 0...10
    static let rpe: ClosedRange<Double> = 1...10
    static let setDurationSeconds: ClosedRange<Int> = 0...14400
    static let distanceMeters: ClosedRange<Double> = 0...200000
    static let mealsPerDay: ClosedRange<Int> = 1...10
    static let waterMilliliters: ClosedRange<Double> = 1...5000
    static let portionQuantity: ClosedRange<Double> = 0.01...10000
    static let recipeServings: ClosedRange<Double> = 0.25...100
    static let wellbeingScale: ClosedRange<Int> = 1...5
    static let sleepHours: ClosedRange<Double> = 0...24
    static let mesocycleWeeks: ClosedRange<Int> = 2...16
    /// Long enough for a free-text note without letting a paste bomb into the store.
    static let noteCharacterLimit = 2000
    static let nameCharacterLimit = 120

    // MARK: Throwing checks

    /// Body height in centimetres.
    static func height(cm value: Double, field: String = "heightCm") throws -> Double {
        try requireFinite(value, field: field)
        guard heightCm.contains(value) else {
            throw RepositoryError.invalidInput(ValidationIssue(
                field: field, key: "validation.height.range",
                arguments: [format(heightCm.lowerBound), format(heightCm.upperBound)]
            ))
        }
        return value
    }

    /// Any body mass: current weight, target weight or a logged reading.
    static func bodyMass(kg value: Double, field: String = "weightKg") throws -> Double {
        try requireFinite(value, field: field)
        guard bodyMassKg.contains(value) else {
            throw RepositoryError.invalidInput(ValidationIssue(
                field: field, key: "validation.bodyMass.range",
                arguments: [format(bodyMassKg.lowerBound), format(bodyMassKg.upperBound)]
            ))
        }
        return value
    }

    /// Age in whole years, usually derived from a birth date.
    static func age(years value: Int, field: String = "ageYears") throws -> Int {
        guard ageYears.contains(value) else {
            throw RepositoryError.invalidInput(ValidationIssue(
                field: field, key: "validation.age.range",
                arguments: [String(ageYears.lowerBound), String(ageYears.upperBound)]
            ))
        }
        return value
    }

    /// A birth date is valid when the age it implies is. `now` is injected so the check is
    /// deterministic in tests.
    static func birthDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                          field: String = "birthDate") throws -> Date {
        let years = calendar.dateComponents([.year], from: date, to: now).year ?? -1
        _ = try age(years: years, field: field)
        return date
    }

    /// Daily energy target.
    static func energy(kilocalories value: Double, field: String = "kilocalories") throws -> Double {
        try requireFinite(value, field: field)
        guard kilocalories.contains(value) else {
            throw RepositoryError.invalidInput(ValidationIssue(
                field: field, key: "validation.energy.range",
                arguments: [format(kilocalories.lowerBound), format(kilocalories.upperBound)]
            ))
        }
        return value
    }

    /// A load in kilograms. Negative loads are clamped to zero — a stray minus sign is an obvious
    /// slip — but an implausibly large one is refused, because silently clamping 5,000 kg to 1,000 kg
    /// would write a lie into the user's history.
    static func load(kg value: Double, field: String = "weightKg") throws -> Double {
        try requireFinite(value, field: field)
        if value < loadKg.lowerBound { return loadKg.lowerBound }
        guard value <= loadKg.upperBound else {
            throw RepositoryError.invalidInput(ValidationIssue(
                field: field, key: "validation.load.range",
                arguments: [format(loadKg.lowerBound), format(loadKg.upperBound)]
            ))
        }
        return value
    }

    /// A quantity of food. Zero is refused: an entry of zero grams is not a log, it is a mistake.
    static func portion(quantity value: Double, field: String = "quantity") throws -> Double {
        try requireFinite(value, field: field)
        guard portionQuantity.contains(value) else {
            throw RepositoryError.invalidInput(ValidationIssue(
                field: field, key: "validation.portion.range",
                arguments: [format(portionQuantity.lowerBound), format(portionQuantity.upperBound)]
            ))
        }
        return value
    }

    /// A load step. Refused rather than clamped: an increment the gym cannot actually produce would
    /// make every rounded recommendation a number the user cannot select.
    static func increment(kg value: Double, field: String) throws -> Double {
        try requireFinite(value, field: field)
        guard loadIncrementKg.contains(value) else {
            throw RepositoryError.invalidInput(ValidationIssue(
                field: field, key: "validation.equipment.incrementRange",
                arguments: [format(loadIncrementKg.lowerBound), format(loadIncrementKg.upperBound)]
            ))
        }
        return value
    }

    /// A gram weight for one serving or one piece. Zero is refused because portion maths would then
    /// silently produce nothing at all for every entry that used it.
    static func grams(_ value: Double, field: String) throws -> Double {
        try requireFinite(value, field: field)
        guard servingGrams.contains(value) else {
            throw RepositoryError.invalidInput(ValidationIssue(
                field: field, key: "validation.grams.range",
                arguments: [format(servingGrams.lowerBound), format(servingGrams.upperBound)]
            ))
        }
        return value
    }

    /// Energy per 100 g of a food, as printed on the packet.
    static func energyDensity(kilocaloriesPer100 value: Double, field: String) throws -> Double {
        try requireFinite(value, field: field)
        guard energyDensityPer100.contains(value) else {
            throw RepositoryError.invalidInput(ValidationIssue(
                field: field, key: "validation.energyDensity.range",
                arguments: [format(energyDensityPer100.lowerBound), format(energyDensityPer100.upperBound)]
            ))
        }
        return value
    }

    static func servings(count value: Double, field: String = "servingsCount") throws -> Double {
        try requireFinite(value, field: field)
        guard recipeServings.contains(value) else {
            throw RepositoryError.invalidInput(ValidationIssue(
                field: field, key: "validation.servings.range",
                arguments: [format(recipeServings.lowerBound), format(recipeServings.upperBound)]
            ))
        }
        return value
    }

    /// Trims a required name and refuses an empty or over-long one.
    static func name(_ raw: String, field: String = "name") throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RepositoryError.invalidInput(ValidationIssue(field: field, key: "validation.name.empty"))
        }
        guard trimmed.count <= nameCharacterLimit else {
            throw RepositoryError.invalidInput(ValidationIssue(
                field: field, key: "validation.name.tooLong", arguments: [String(nameCharacterLimit)]
            ))
        }
        return trimmed
    }

    /// Refuses a collection the caller must have filled in — an empty recipe has no nutrition.
    static func requireNonEmpty<C: Collection>(_ collection: C, field: String) throws -> C {
        guard !collection.isEmpty else {
            throw RepositoryError.invalidInput(ValidationIssue(field: field, key: "validation.collection.empty"))
        }
        return collection
    }

    /// Rejects NaN and infinity everywhere, once, so no other check has to think about them.
    static func requireFinite(_ value: Double, field: String) throws {
        guard value.isFinite else {
            throw RepositoryError.invalidInput(ValidationIssue(field: field, key: "validation.number.notFinite"))
        }
    }

    // MARK: Clamping helpers

    /// Macronutrient grams. Clamped rather than thrown: grams are usually derived from a portion
    /// the user already confirmed, so a bound breach means "cap it", not "start again".
    static func clampedMacroGrams(_ value: Double) -> Double {
        clamp(value.isFinite ? value : 0, to: macroGrams)
    }

    /// Grams of one macronutrient per 100 g of a food.
    static func clampedMacroDensity(_ value: Double) -> Double {
        clamp(value.isFinite ? value : 0, to: macroDensityPer100)
    }

    static func clampedSets(_ value: Int) -> Int { clamp(value, to: setsPerExercise) }
    static func clampedReps(_ value: Int) -> Int { clamp(value, to: reps) }
    static func clampedDaysPerWeek(_ value: Int) -> Int { clamp(value, to: daysPerWeek) }
    static func clampedSessionMinutes(_ value: Int) -> Int { clamp(value, to: sessionMinutes) }
    static func clampedRestSeconds(_ value: Int) -> Int { clamp(value, to: restSeconds) }
    static func clampedRIR(_ value: Int) -> Int { clamp(value, to: repsInReserve) }
    static func clampedRPE(_ value: Double) -> Double { clamp(value.isFinite ? value : 10, to: rpe) }
    static func clampedSetDurationSeconds(_ value: Int) -> Int { clamp(value, to: setDurationSeconds) }
    static func clampedMealsPerDay(_ value: Int) -> Int { clamp(value, to: mealsPerDay) }
    static func clampedMesocycleWeeks(_ value: Int) -> Int { clamp(value, to: mesocycleWeeks) }
    static func clampedWellbeingScore(_ value: Int) -> Int { clamp(value, to: wellbeingScale) }

    static func clampedDistanceMeters(_ value: Double) -> Double {
        clamp(value.isFinite ? value : 0, to: distanceMeters)
    }

    static func clampedSleepHours(_ value: Double) -> Double {
        clamp(value.isFinite ? value : 0, to: sleepHours)
    }

    static func clampedWaterMilliliters(_ value: Double) -> Double {
        clamp(value.isFinite ? value : 0, to: waterMilliliters)
    }

    /// A rep range is stored as two integers, so the pair is normalised here rather than in five
    /// different call sites.
    static func clampedRepRange(_ range: RepRange) -> RepRange {
        RepRange(clampedReps(range.lower), clampedReps(range.upper))
    }

    /// Trims an optional free-text note and drops it when nothing is left. Long notes are truncated
    /// rather than refused: the user has already typed them and losing the lot would be worse.
    static func sanitisedNote(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.count <= noteCharacterLimit
            ? trimmed
            : String(trimmed.prefix(noteCharacterLimit))
    }

    /// Normalises a tag list: lower-cased, trimmed, de-duplicated, order preserved.
    /// Tags are matched against food data with plain equality, so normalising at the boundary is
    /// what stops `"Gluten"` and `"gluten "` behaving as two different allergens.
    static func normalisedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw {
            let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }

    // MARK: Private

    private static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Formats a bound for a message. Bounds are round numbers, so the fraction is dropped when it
    /// adds nothing, and a fractional bound keeps only the digits it actually has: a message reading
    /// "between 0.25 and 50 kg" has to state the number the check really applies.
    private static func format(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%g", value)
    }
}

// MARK: - Ordering

/// Reordering helpers for models that carry an explicit `orderIndex`.
///
/// SwiftUI ships `move(fromOffsets:toOffset:)`, but repositories must not import SwiftUI — they run
/// under test and in extensions where no view layer exists — so the same semantics are reimplemented
/// here: the moved elements land immediately before whatever originally sat at `destination`.
enum RepositoryOrdering {

    /// Returns `items` with the elements at `source` moved to `destination`, matching the offsets a
    /// SwiftUI `List` reports from a drag.
    static func moved<T>(_ items: [T], fromOffsets source: IndexSet, toOffset destination: Int) -> [T] {
        let valid = source.filter { items.indices.contains($0) }
        guard !valid.isEmpty else { return items }

        let moving = valid.map { items[$0] }
        var result = items
        for index in valid.sorted(by: >) { result.remove(at: index) }

        // Every removed element that sat before the drop point shifts the drop point left by one.
        let removedBefore = valid.filter { $0 < destination }.count
        let insertion = min(max(0, destination - removedBefore), result.count)
        result.insert(contentsOf: moving, at: insertion)
        return result
    }

    /// Sorts `items` to match `orderedIDs`. Anything missing from the list keeps its existing
    /// relative order behind the listed elements, so a stale ordering can never drop a row.
    static func sorted<T>(
        _ items: [T],
        matching orderedIDs: [UUID],
        id: (T) -> UUID,
        currentIndex: (T) -> Int
    ) -> [T] {
        let ranking = Dictionary(orderedIDs.enumerated().map { ($0.element, $0.offset) }) { first, _ in first }
        return items.sorted { lhs, rhs in
            let left = ranking[id(lhs)] ?? Int.max
            let right = ranking[id(rhs)] ?? Int.max
            if left != right { return left < right }
            return currentIndex(lhs) < currentIndex(rhs)
        }
    }
}

// MARK: - Shared repository plumbing

/// The one thing every repository has in common: a `ModelContext`, and the obligation to translate
/// its failures into `RepositoryError` rather than letting a raw store error reach the interface.
///
/// Repositories are `@MainActor` because `ModelContext` is not `Sendable` and because every caller
/// is a SwiftUI view model. SwiftData's API is synchronous, so the repositories are too: wrapping
/// synchronous calls in `async` would buy nothing but a suspension point.
@MainActor
protocol Repository {
    var context: ModelContext { get }
}

extension Repository {

    /// Saves, or throws. Never called speculatively: a repository saves once, at the end of the
    /// mutation it was asked to perform, so a partially applied change is never left committed.
    func persist() throws {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            AppLog.persistence.error("Save failed: \(String(describing: error), privacy: .public)")
            throw RepositoryError.saveFailed(underlying: String(describing: error))
        }
    }

    /// Runs a fetch, translating a store or predicate failure into `RepositoryError.fetchFailed`.
    func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            AppLog.persistence.error("Fetch failed: \(String(describing: error), privacy: .public)")
            throw RepositoryError.fetchFailed(underlying: String(describing: error))
        }
    }

    /// Fetches at most one row. Applies the limit to the descriptor so the store does the work.
    func fetchFirst<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> T? {
        var limited = descriptor
        limited.fetchLimit = 1
        return try fetch(limited).first
    }

    /// Counts matching rows without materialising them.
    func count<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> Int {
        do {
            return try context.fetchCount(descriptor)
        } catch {
            AppLog.persistence.error("Count failed: \(String(describing: error), privacy: .public)")
            throw RepositoryError.fetchFailed(underlying: String(describing: error))
        }
    }

    /// Deletes every row of a model type. Used by the "reset all data" path, which must leave the
    /// store genuinely empty rather than merely hidden.
    func deleteAll<T: PersistentModel>(_ type: T.Type) throws {
        for row in try fetch(FetchDescriptor<T>()) {
            context.delete(row)
        }
    }
}

