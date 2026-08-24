import Foundation
import Testing
@testable import GymApp

/// Behaviour of `PersonalRecordDetector`.
///
/// The hard part of a PR detector is refusing to celebrate things that are not achievements, so
/// most of these tests assert that *nothing* fires.
@Suite("Personal record detection")
struct PersonalRecordDetectorTests {

    // MARK: - Fixtures

    private func loadedExercise(
        repRange: RepRange = .hypertrophy
    ) -> Exercise {
        Fixtures.exercise(
            id: "bench",
            name: "Barbell Bench Press",
            metadata: Fixtures.metadata(
                movementPattern: .horizontalPush,
                loadability: .barbell,
                trackingMode: .weightAndReps,
                recommendedRepRange: repRange
            )
        )
    }

    private func assistedExercise() -> Exercise {
        Fixtures.exercise(
            id: "assisted-pullup",
            name: "Assisted Pull-Up",
            bodyPart: .back,
            equipment: .assisted,
            target: .lats,
            metadata: Fixtures.metadata(
                movementPattern: .verticalPull,
                pushPull: .pull,
                loadability: .assistedBodyweight,
                trackingMode: .assistedBodyweight
            )
        )
    }

    private func plankExercise() -> Exercise {
        Fixtures.exercise(
            id: "plank",
            name: "Plank",
            bodyPart: .waist,
            equipment: .bodyWeight,
            target: .abs,
            metadata: Fixtures.metadata(
                movementPattern: .coreAntiExtension,
                pushPull: .core,
                mechanic: .isolation,
                loadability: .bodyweight,
                trackingMode: .duration
            )
        )
    }

    private func treadmillExercise() -> Exercise {
        Fixtures.exercise(
            id: "run",
            name: "Treadmill Run",
            bodyPart: .cardio,
            equipment: .stationaryBike,
            target: .cardiovascularSystem,
            metadata: Fixtures.metadata(
                movementPattern: .cardio,
                pushPull: .cardio,
                loadability: .none,
                trackingMode: .distanceAndDuration
            )
        )
    }

    private func detect(
        _ sets: [PerformedSet],
        exercise: Exercise,
        existing: [PersonalRecordKind: Double] = [:]
    ) -> [DetectedRecord] {
        PersonalRecordDetector.detect(
            performance: Fixtures.performance(exerciseID: exercise.id, sets: sets),
            exercise: exercise,
            existing: existing
        )
    }

    // MARK: - Load records

    @Test("A heavier top set sets a new load record, with the beaten value attached")
    func heavierLoadFiresALoadRecord() throws {
        let records = detect(
            [Fixtures.set(weightKg: 102.5, reps: 5)],
            exercise: loadedExercise(),
            existing: [.heaviestWeight: 100, .mostReps: 12, .estimatedOneRepMax: 200, .bestSetVolume: 2000]
        )
        let load = try #require(records.first { $0.kind == .heaviestWeight })
        #expect(load.value == 102.5)
        #expect(load.previousValue == 100)
        #expect(load.repsContext == 5)
        #expect(load.setIndex == 0)
    }

    @Test("A first-ever load record has no previous value")
    func firstLoadRecordHasNoPreviousValue() throws {
        let records = detect([Fixtures.set(weightKg: 40, reps: 8)], exercise: loadedExercise())
        let load = try #require(records.first { $0.kind == .heaviestWeight })
        #expect(load.previousValue == nil)
    }

    @Test("At equal load the set with more reps is the one reported")
    func equalLoadTieBreaksTowardsMoreReps() throws {
        let records = detect(
            [
                Fixtures.set(weightKg: 100, reps: 5),
                Fixtures.set(weightKg: 100, reps: 8)
            ],
            exercise: loadedExercise(),
            existing: [.mostReps: 20, .estimatedOneRepMax: 500, .bestSetVolume: 5000]
        )
        let load = try #require(records.first { $0.kind == .heaviestWeight })
        #expect(load.repsContext == 8)
        #expect(load.setIndex == 1)
    }

    // MARK: - The rep gate

    @Test("More reps at a lighter load is a lighter session, not a rep record")
    func moreRepsAtALighterLoadDoesNotFireARepRecord() {
        // 80 kg × 12 from someone who has recorded 100 kg. Without the gate every deload week
        // would fire a rep PR.
        let records = detect(
            [Fixtures.set(weightKg: 80, reps: 12)],
            exercise: loadedExercise(),
            existing: [
                .heaviestWeight: 100,
                .mostReps: 8,
                .estimatedOneRepMax: 200,
                .bestSetVolume: 2000
            ]
        )
        #expect(records.isEmpty)
        #expect(!records.contains { $0.kind == .mostReps })
    }

    @Test("More reps at or above the recorded heaviest load is a rep record")
    func moreRepsAtTheRecordedLoadFiresARepRecord() throws {
        let records = detect(
            [Fixtures.set(weightKg: 100, reps: 10)],
            exercise: loadedExercise(),
            existing: [
                .heaviestWeight: 100,
                .mostReps: 8,
                .estimatedOneRepMax: 500,
                .bestSetVolume: 5000
            ]
        )
        let reps = try #require(records.first { $0.kind == .mostReps })
        #expect(reps.value == 10)
        #expect(reps.previousValue == 8)
    }

    @Test("With no load record yet the rep gate is inert, which can only happen once")
    func repGateIsInertBeforeAnyLoadRecordExists() throws {
        let records = detect(
            [Fixtures.set(weightKg: 20, reps: 15)],
            exercise: loadedExercise(),
            existing: [.mostReps: 8]
        )
        let reps = try #require(records.first { $0.kind == .mostReps })
        #expect(reps.value == 15)
    }

    @Test("A rep record needs a whole extra rep, not a fraction of one")
    func repRecordNeedsAWholeExtraRep() {
        let equal = detect(
            [Fixtures.set(weightKg: 100, reps: 8)],
            exercise: loadedExercise(),
            existing: [
                .heaviestWeight: 100,
                .mostReps: 8,
                .estimatedOneRepMax: 500,
                .bestSetVolume: 5000
            ]
        )
        #expect(!equal.contains { $0.kind == .mostReps })
    }

    // MARK: - Margins

    @Test("A re-logged identical set fires nothing at all")
    func reloggingTheSameSetFiresNothing() {
        let set = Fixtures.set(weightKg: 100, reps: 5)
        let existing: [PersonalRecordKind: Double] = [
            .heaviestWeight: 100,
            .mostReps: 5,
            .estimatedOneRepMax: 114.583_333_333_333_33,
            .bestSetVolume: 500
        ]
        #expect(detect([set], exercise: loadedExercise(), existing: existing).isEmpty)
    }

    @Test("A load difference below the 0.1 kg margin is the same performance, not a record")
    func subThresholdLoadDifferencesFireNothing() {
        let existing: [PersonalRecordKind: Double] = [
            .heaviestWeight: 100,
            .mostReps: 20,
            .estimatedOneRepMax: 500,
            .bestSetVolume: 5000
        ]
        for drift in [1e-9, 0.01, 0.05, 0.099] {
            let records = detect(
                [Fixtures.set(weightKg: 100 + drift, reps: 5)],
                exercise: loadedExercise(),
                existing: existing
            )
            #expect(
                !records.contains { $0.kind == .heaviestWeight },
                "a \(drift) kg difference should not be a record"
            )
        }
    }

    @Test("A load difference of exactly the margin does count")
    func loadDifferenceAtTheMarginCounts() throws {
        let records = detect(
            [Fixtures.set(weightKg: 100.1, reps: 5)],
            exercise: loadedExercise(),
            existing: [
                .heaviestWeight: 100,
                .mostReps: 20,
                .estimatedOneRepMax: 500,
                .bestSetVolume: 5000
            ]
        )
        let load = try #require(records.first { $0.kind == .heaviestWeight })
        #expect(abs(load.value - 100.1) < 1e-9)
    }

    @Test("Volume differences below the margin fire nothing")
    func subThresholdVolumeDifferencesFireNothing() {
        let records = detect(
            [Fixtures.set(weightKg: 100.01, reps: 5)],
            exercise: loadedExercise(),
            existing: [
                .heaviestWeight: 500,
                .mostReps: 20,
                .estimatedOneRepMax: 500,
                .bestSetVolume: 500.05
            ]
        )
        #expect(!records.contains { $0.kind == .bestSetVolume })
    }

    // MARK: - Which sets count

    @Test("Warm-up, drop and calibration sets can never set a record")
    func nonWorkingSetsAreIgnored() {
        let records = detect(
            [
                Fixtures.set(kind: .warmup, weightKg: 500, reps: 5),
                Fixtures.set(kind: .dropSet, weightKg: 400, reps: 5),
                Fixtures.set(kind: .calibration, weightKg: 300, reps: 5)
            ],
            exercise: loadedExercise()
        )
        #expect(records.isEmpty)
    }

    @Test("An abandoned set can never set a record")
    func incompleteSetsAreIgnored() {
        let records = detect(
            [Fixtures.set(weightKg: 500, reps: 5, isCompleted: false)],
            exercise: loadedExercise()
        )
        #expect(records.isEmpty)
    }

    @Test("A performance with no sets produces no records")
    func emptyPerformanceProducesNoRecords() {
        #expect(detect([], exercise: loadedExercise()).isEmpty)
    }

    // MARK: - Estimated one-rep max

    @Test("A set past the reliable rep ceiling produces no e1RM record")
    func unreliableRepCountsProduceNoOneRepMaxRecord() {
        let records = detect(
            [Fixtures.set(weightKg: 60, reps: 20)],
            exercise: loadedExercise(),
            existing: [.heaviestWeight: 500, .mostReps: 50, .bestSetVolume: 50_000]
        )
        #expect(!records.contains { $0.kind == .estimatedOneRepMax })
    }

    @Test("The e1RM record uses the strongest set, which need not be the heaviest")
    func oneRepMaxRecordUsesTheStrongestSet() throws {
        let records = detect(
            [
                Fixtures.set(weightKg: 100, reps: 3),
                Fixtures.set(weightKg: 90, reps: 8)
            ],
            exercise: loadedExercise()
        )
        let estimate = try #require(records.first { $0.kind == .estimatedOneRepMax })
        #expect(estimate.setIndex == 1)
        #expect(estimate.repsContext == 8)
    }

    // MARK: - Tracking modes

    @Test("A duration record only fires for a movement measured in seconds")
    func durationRecordsOnlyFireForTimedMovements() throws {
        let held = detect(
            [Fixtures.set(durationSeconds: 95)],
            exercise: plankExercise(),
            existing: [.longestDuration: 90]
        )
        let duration = try #require(held.first { $0.kind == .longestDuration })
        #expect(duration.value == 95)
        #expect(duration.previousValue == 90)
        #expect(!held.contains { $0.kind == .longestDistance })

        // The very same seconds logged against a weight-and-reps movement are not a duration record.
        let lifted = detect(
            [Fixtures.set(weightKg: 100, reps: 5, durationSeconds: 95)],
            exercise: loadedExercise(),
            existing: [
                .heaviestWeight: 500,
                .mostReps: 50,
                .estimatedOneRepMax: 500,
                .bestSetVolume: 50_000
            ]
        )
        #expect(!lifted.contains { $0.kind == .longestDuration })
    }

    @Test("A distance record only fires for a movement measured in distance")
    func distanceRecordsOnlyFireForDistanceMovements() throws {
        let ran = detect(
            [Fixtures.set(durationSeconds: 1_800, distanceMeters: 5_200)],
            exercise: treadmillExercise(),
            existing: [.longestDistance: 5_000, .longestDuration: 3_600]
        )
        let distance = try #require(ran.first { $0.kind == .longestDistance })
        #expect(distance.value == 5_200)
        #expect(!ran.contains { $0.kind == .longestDuration })

        // A plank records seconds but has no distance to record.
        let held = detect(
            [Fixtures.set(durationSeconds: 95, distanceMeters: 5_200)],
            exercise: plankExercise()
        )
        #expect(!held.contains { $0.kind == .longestDistance })
    }

    @Test("A duration under the half-second margin is not a longer hold")
    func subThresholdDurationFiresNothing() {
        let records = detect(
            [Fixtures.set(durationSeconds: 90)],
            exercise: plankExercise(),
            existing: [.longestDuration: 90]
        )
        #expect(records.isEmpty)
    }

    @Test("A distance under the one-metre margin is not a longer run")
    func subThresholdDistanceFiresNothing() {
        let records = detect(
            [Fixtures.set(durationSeconds: 100, distanceMeters: 5_000.5)],
            exercise: treadmillExercise(),
            existing: [.longestDistance: 5_000, .longestDuration: 5_000]
        )
        #expect(!records.contains { $0.kind == .longestDistance })
    }

    // MARK: - Assisted movements

    @Test("Less assistance is the record an assisted movement gets")
    func lessAssistanceFiresTheAssistanceRecord() throws {
        let records = detect(
            [Fixtures.set(weightKg: 15, reps: 8)],
            exercise: assistedExercise(),
            existing: [.lightestAssistance: 20, .mostReps: 20]
        )
        let assistance = try #require(records.first { $0.kind == .lightestAssistance })
        #expect(assistance.value == 15)
        #expect(assistance.previousValue == 20)
    }

    @Test("More assistance is an easier set and fires nothing, however many reps it took")
    func moreAssistanceFiresNothing() {
        // 30 kg of counterweight for 12 reps is easier than 20 kg for 8. Without the inverted rep
        // gate this would fire a rep record every time the user made the exercise easier.
        let records = detect(
            [Fixtures.set(weightKg: 30, reps: 12)],
            exercise: assistedExercise(),
            existing: [.lightestAssistance: 20, .mostReps: 8]
        )
        #expect(records.isEmpty)
    }

    @Test("An assisted movement never gets load, e1RM or tonnage records")
    func assistedMovementsSkipTheLoadFacingRecords() {
        let records = detect(
            [Fixtures.set(weightKg: 5, reps: 6)],
            exercise: assistedExercise()
        )
        #expect(!records.contains { $0.kind == .heaviestWeight })
        #expect(!records.contains { $0.kind == .estimatedOneRepMax })
        #expect(!records.contains { $0.kind == .bestSetVolume })
        #expect(records.contains { $0.kind == .lightestAssistance })
    }

    @Test("Zero assistance is a real record, not missing data")
    func zeroAssistanceIsARecord() throws {
        let records = detect(
            [Fixtures.set(weightKg: 0, reps: 3)],
            exercise: assistedExercise(),
            existing: [.lightestAssistance: 5, .mostReps: 20]
        )
        let assistance = try #require(records.first { $0.kind == .lightestAssistance })
        #expect(assistance.value == 0)
    }

    @Test("Assistance within the margin of the record is the same performance")
    func subThresholdAssistanceFiresNothing() {
        let records = detect(
            [Fixtures.set(weightKg: 19.95, reps: 8)],
            exercise: assistedExercise(),
            existing: [.lightestAssistance: 20, .mostReps: 20]
        )
        #expect(!records.contains { $0.kind == .lightestAssistance })
    }

    @Test("The lower-is-better flag marks exactly the assistance record")
    func onlyTheAssistanceRecordInvertsComparison() {
        for kind in PersonalRecordKind.allCases {
            #expect(kind.lowerIsBetter == (kind == .lightestAssistance))
        }
    }

    // MARK: - Shape of the result

    @Test("Records come back in the canonical kind order, so identical input reads identically")
    func recordsAreOrderedByKind() {
        let records = detect(
            [Fixtures.set(weightKg: 100, reps: 10)],
            exercise: loadedExercise()
        )
        let kinds = records.map(\.kind)
        let canonical = PersonalRecordKind.allCases.filter { kinds.contains($0) }
        #expect(kinds == canonical)
        #expect(kinds == [.heaviestWeight, .mostReps, .estimatedOneRepMax, .bestSetVolume])
    }

    @Test("Session volume is never produced here, because one exercise cannot know a session total")
    func sessionVolumeIsNeverProduced() {
        let records = detect(
            [Fixtures.set(weightKg: 100, reps: 10), Fixtures.set(weightKg: 100, reps: 10)],
            exercise: loadedExercise()
        )
        #expect(!records.contains { $0.kind == .sessionVolume })
    }

    @Test("Identical input always produces identical output")
    func detectionIsDeterministic() {
        let sets = [
            Fixtures.set(weightKg: 100, reps: 5),
            Fixtures.set(weightKg: 90, reps: 8),
            Fixtures.set(weightKg: 100, reps: 5)
        ]
        let first = detect(sets, exercise: loadedExercise())
        for _ in 0..<20 {
            #expect(detect(sets, exercise: loadedExercise()) == first)
        }
    }
}
