import Foundation
import HealthKit
import Observation

/// Optional two-way bridge to the Health app.
///
/// Every feature works with HealthKit switched off — the app asks for authorisation only when the
/// user turns the toggle on, requests the narrowest set of types it actually uses, and treats a
/// refusal as a normal state rather than an error.
@MainActor
@Observable
final class HealthService {
    enum Availability: Equatable {
        case unavailable
        case notDetermined
        case authorized
        case denied
    }

    private(set) var availability: Availability
    private(set) var lastError: String?

    private let store: HKHealthStore?

    init() {
        if HKHealthStore.isHealthDataAvailable() {
            store = HKHealthStore()
            availability = .notDetermined
        } else {
            store = nil
            availability = .unavailable
        }
    }

    // MARK: - Types

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if let bodyMass = HKObjectType.quantityType(forIdentifier: .bodyMass) { types.insert(bodyMass) }
        if let height = HKObjectType.quantityType(forIdentifier: .height) { types.insert(height) }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(energy) }
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) { types.insert(steps) }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        types.insert(HKObjectType.workoutType())
        return types
    }

    /// Only what the app actually writes. Active energy used to be requested here, which put
    /// "Active Energy" on the write half of the permission sheet while
    /// `NSHealthUpdateUsageDescription` — correctly — only talks about workouts and body weight.
    /// A purpose string that does not account for every requested type is a 5.1.1(i) rejection.
    /// Read access to active energy is unaffected; it is covered by the share description.
    private var writeTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let bodyMass = HKObjectType.quantityType(forIdentifier: .bodyMass) { types.insert(bodyMass) }
        return types
    }

    // MARK: - Authorisation

    /// Requests authorisation. Returns `false` if Health is unavailable or the request failed;
    /// HealthKit never reveals whether the user granted read access, so a `true` result only means
    /// the sheet was completed.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard let store else { availability = .unavailable; return false }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            availability = .authorized
            lastError = nil
            return true
        } catch {
            availability = .denied
            lastError = error.localizedDescription
            AppLog.health.error("Health authorisation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Reads

    /// Body-mass samples in kilograms, newest first.
    func bodyMassSamples(since date: Date, limit: Int = 400) async -> [(date: Date, kilograms: Double)] {
        guard let store, let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: date, end: Date(), options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    AppLog.health.error("Body mass query failed: \(error.localizedDescription, privacy: .public)")
                }
                let values = (samples as? [HKQuantitySample] ?? []).map {
                    (date: $0.startDate, kilograms: $0.quantity.doubleValue(for: .gramUnit(with: .kilo)))
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }

    /// Latest height in centimetres, if Health has one.
    func latestHeightCm() async -> Double? {
        guard let store, let type = HKQuantityType.quantityType(forIdentifier: .height) else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?
                    .quantity.doubleValue(for: .meterUnit(with: .centi))
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    /// Sum of a quantity type between two dates, in the given unit.
    private func sum(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> Double? {
        guard let store, let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum
            ) { _, statistics, _ in
                continuation.resume(returning: statistics?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    func activeEnergyKilocalories(on day: Date) async -> Double? {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? Date()
        return await sum(identifier: .activeEnergyBurned, unit: .kilocalorie(), from: start, to: end)
    }

    func stepCount(on day: Date) async -> Double? {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? Date()
        return await sum(identifier: .stepCount, unit: .count(), from: start, to: end)
    }

    /// Hours asleep for the night ending on `day`.
    func sleepHours(endingOn day: Date) async -> Double? {
        guard let store, let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let end = Calendar.current.startOfDay(for: day).addingTimeInterval(12 * 3600)
        let start = end.addingTimeInterval(-24 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 200, sortDescriptors: nil) { _, samples, _ in
                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                ]
                let seconds = (samples as? [HKCategorySample] ?? [])
                    .filter { asleepValues.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                continuation.resume(returning: seconds > 0 ? seconds / 3600 : nil)
            }
            store.execute(query)
        }
    }

    // MARK: - Writes

    /// Saves a completed strength-training workout.
    func saveWorkout(start: Date, end: Date) async {
        guard let store else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor

        do {
            let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
            try await builder.beginCollection(at: start)

            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
        } catch {
            AppLog.health.error("Saving workout failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Saves a body-mass sample in kilograms.
    func saveBodyMass(kilograms: Double, date: Date) async {
        guard let store, let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return }
        let quantity = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kilograms)
        let sample = HKQuantitySample(type: type, quantity: quantity, start: date, end: date)
        do {
            try await store.save(sample)
        } catch {
            AppLog.health.error("Saving body mass failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
