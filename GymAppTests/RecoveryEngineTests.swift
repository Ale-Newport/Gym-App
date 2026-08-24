import Foundation
import Testing

@testable import GymApp

// MARK: - Fixtures
//
// Everything here is file-private so it cannot collide with fixtures in sibling test files.
// Every date is derived from `referenceNow`, never from the wall clock.

private let referenceNow = Date(timeIntervalSince1970: 1_750_000_000)

private func fixedUUID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
}

private func hoursBefore(_ hours: Double, _ now: Date = referenceNow) -> Date {
    now.addingTimeInterval(-hours * 3600)
}

private func makeOutcome(
    id: Int = 0,
    hoursAgo hours: Double,
    groupSets: [MuscleGroup: Double],
    effort: SessionEffortFeedback? = nil,
    averageRIR: Double? = nil,
    plannedSets: Int = 12,
    completedSets: Int = 12,
    performances: [ExercisePerformance] = [],
    now: Date = referenceNow
) -> SessionOutcome {
    SessionOutcome(
        sessionID: fixedUUID(id),
        date: now.addingTimeInterval(-hours * 3600),
        plannedSets: plannedSets,
        completedSets: completedSets,
        skippedExerciseIDs: [],
        substitutedExerciseIDs: [:],
        effortFeedback: effort,
        durationSeconds: 3600,
        averageRIR: averageRIR,
        groupSets: groupSets,
        performances: performances
    )
}

private func makeMetadata(
    fatigueCost: Double = 0.6,
    volumeContribution: [MuscleGroup: Double]
) -> ExerciseMetadata {
    ExerciseMetadata(
        movementPattern: .horizontalPull,
        pushPull: .pull,
        mechanic: .compound,
        difficulty: .beginner,
        laterality: .bilateral,
        loadability: .barbell,
        trackingMode: .weightAndReps,
        stabilityDemand: 0.3,
        fatigueCost: fatigueCost,
        stimulusScore: 0.7,
        progressionSuitability: 0.8,
        recommendedRepRange: .hypertrophy,
        defaultRestSeconds: 90,
        estimatedSetSeconds: 45,
        isStretch: false,
        isPlyometric: false,
        isWarmupCandidate: false,
        volumeContribution: volumeContribution,
        substitutionTags: [],
        stapleScore: 0.5
    )
}

private func makeExercise(
    id: String,
    name: String = "Barbell Row",
    target: Muscle = .lats,
    fatigueCost: Double = 0.6,
    volumeContribution: [MuscleGroup: Double]
) -> Exercise {
    Exercise(
        id: id,
        name: name,
        bodyPart: .back,
        equipment: .barbell,
        target: target,
        synergist: nil,
        secondaryMuscles: [],
        mediaID: id,
        thumbnailFileName: "\(id).png",
        animationFileName: "\(id).gif",
        attribution: "test fixture",
        createdAt: Date(timeIntervalSince1970: 0),
        metadata: makeMetadata(fatigueCost: fatigueCost, volumeContribution: volumeContribution)
    )
}

private func makeSet(reps: Int = 8, weight: Double = 100, rir: Int? = nil, targetReps: Int? = nil) -> PerformedSet {
    PerformedSet(weightKg: weight, reps: reps, rir: rir, targetReps: targetReps)
}

/// A check-in where every question was answered in the middle of its scale: index 0.5.
private func neutralCheckIn(at date: Date) -> WellbeingSnapshot {
    WellbeingSnapshot(
        energy: 3, sleepQuality: 3, sleepHours: 6.5, soreness: 3, motivation: 3, stress: 3, date: date
    )
}

/// Everything answered at the good end: index 1.0.
private func excellentCheckIn(at date: Date) -> WellbeingSnapshot {
    WellbeingSnapshot(
        energy: 5, sleepQuality: 5, sleepHours: 8, soreness: 1, motivation: 5, stress: 1, date: date
    )
}

/// Everything answered at the bad end: index 0.0.
private func poorCheckIn(at date: Date) -> WellbeingSnapshot {
    WellbeingSnapshot(
        energy: 1, sleepQuality: 1, sleepHours: 4, soreness: 5, motivation: 1, stress: 5, date: date
    )
}

/// One hard lower-body day: the reference case the tuning constants are calibrated against.
private func referenceHardQuadSession(hoursAgo hours: Double) -> SessionOutcome {
    makeOutcome(hoursAgo: hours, groupSets: [.quads: 6], effort: .hard, averageRIR: 1.5)
}

// MARK: - Decay

@Suite("Recovery fatigue decays with time")
struct RecoveryDecayTests {

    @Test("The same session leaves less fatigue a week later than a day later")
    func fatigueFromOneSessionFallsAsTheSessionAges() {
        let profile = TrainingProfileSnapshot()
        let aDayOld = RecoveryEngine.snapshot(
            sessions: [referenceHardQuadSession(hoursAgo: 24)],
            wellbeing: [], profile: profile, now: referenceNow
        )
        let aWeekOld = RecoveryEngine.snapshot(
            sessions: [referenceHardQuadSession(hoursAgo: 168)],
            wellbeing: [], profile: profile, now: referenceNow
        )

        #expect(aWeekOld.fatigue(for: .quads) < aDayOld.fatigue(for: .quads))
        #expect(aWeekOld.systemicReadiness > aDayOld.systemicReadiness)
    }

    @Test("Fatigue falls monotonically as the same session ages")
    func fatigueIsMonotonicInAge() {
        let profile = TrainingProfileSnapshot()
        let ages: [Double] = [0, 4, 12, 24, 48, 96, 168]
        let values = ages.map { hours in
            RecoveryEngine.snapshot(
                sessions: [referenceHardQuadSession(hoursAgo: hours)],
                wellbeing: [], profile: profile, now: referenceNow
            ).fatigue(for: .quads)
        }

        for index in 1..<values.count {
            #expect(values[index] < values[index - 1])
        }
    }

    @Test("A group is 90 per cent recovered at its baseline recovery hours")
    func decayLeavesATenthOfTheStimulusAtTheBaseline() {
        for group in MuscleGroup.allCases {
            let residual = RecoveryEngine.decayMultiplier(
                hoursElapsed: group.baselineRecoveryHours, for: group
            )
            #expect(abs(residual - RecoveryTuning.recoveredResidualFraction) < 0.0005)
        }
    }

    @Test("Zero elapsed hours leaves the stimulus untouched")
    func decayAtZeroHoursIsOne() {
        #expect(RecoveryEngine.decayMultiplier(hoursElapsed: 0, for: .quads) == 1)
        #expect(RecoveryEngine.decayMultiplier(hoursElapsed: -5, for: .quads) == 1)
    }

    @Test("Small muscles shed a given stimulus faster than large ones")
    func smallMusclesRecoverFaster() {
        let calves = RecoveryEngine.decayMultiplier(hoursElapsed: 24, for: .calves)
        let quads = RecoveryEngine.decayMultiplier(hoursElapsed: 24, for: .quads)
        #expect(calves < quads)
    }

    @Test("The documented quad calibration curve is reproduced")
    func quadFatigueMatchesTheDocumentedCurve() {
        // docs/fragments/recovery.md: six quad set credits at 1.5 RIR rated "hard" reads
        // 0.72 on the day, 0.67 after four hours, 0.40 after a day and 0.18 after two.
        let profile = TrainingProfileSnapshot()
        let expected: [(hours: Double, fatigue: Double)] = [(0, 0.72), (4, 0.67), (24, 0.40), (48, 0.18)]

        for point in expected {
            let snapshot = RecoveryEngine.snapshot(
                sessions: [referenceHardQuadSession(hoursAgo: point.hours)],
                wellbeing: [], profile: profile, now: referenceNow
            )
            #expect(abs(snapshot.fatigue(for: .quads) - point.fatigue) < 0.01)
        }
    }

    @Test("The documented systemic readiness reference day is reproduced")
    func readinessMatchesTheDocumentedReferenceDay() {
        // docs/fragments/recovery.md: six quad credits plus three glute credits at 1.5 RIR rated
        // "hard" is 0.64 readiness on the day, 0.84 after a day, 0.93 after two.
        let profile = TrainingProfileSnapshot()
        let expected: [(hours: Double, readiness: Double)] = [(0, 0.64), (24, 0.84), (48, 0.93)]

        for point in expected {
            let session = makeOutcome(
                hoursAgo: point.hours, groupSets: [.quads: 6, .glutes: 3],
                effort: .hard, averageRIR: 1.5
            )
            let snapshot = RecoveryEngine.snapshot(
                sessions: [session], wellbeing: [], profile: profile, now: referenceNow
            )
            #expect(abs(snapshot.systemicReadiness - point.readiness) < 0.01)
        }
    }

    @Test("Sessions beyond the ten-day lookback contribute no measurable fatigue")
    func sessionsOlderThanTheLookbackAreDropped() {
        let profile = TrainingProfileSnapshot()
        let snapshot = RecoveryEngine.snapshot(
            sessions: [referenceHardQuadSession(hoursAgo: 11 * 24)],
            wellbeing: [], profile: profile, now: referenceNow
        )
        #expect(snapshot.fatigue[.quads] == nil)
        #expect(snapshot.systemicReadiness == 1.0)
    }

    @Test("Fatigue too small to matter is not stored as dust")
    func negligibleFatigueIsDroppedFromTheSnapshot() {
        let profile = TrainingProfileSnapshot()
        let snapshot = RecoveryEngine.snapshot(
            sessions: [makeOutcome(hoursAgo: 200, groupSets: [.quads: 0.6])],
            wellbeing: [], profile: profile, now: referenceNow
        )
        #expect(snapshot.fatigue[.quads] == nil)
        // The stimulus still happened, so it is still dated.
        #expect(snapshot.daysSinceStimulus[.quads] == 8)
        #expect(snapshot.weeklySets[.quads] == nil)
    }
}

// MARK: - Bounds

@Suite("Recovery output stays inside its promised range")
struct RecoveryBoundsTests {

    @Test("A fifty-set session still reports fatigue inside zero to one")
    func fiftySetSessionStaysBounded() {
        let profile = TrainingProfileSnapshot()
        let session = makeOutcome(
            hoursAgo: 0,
            groupSets: [.quads: 50, .glutes: 50, .back: 50, .biceps: 50],
            effort: .exhausting,
            averageRIR: 0
        )
        let snapshot = RecoveryEngine.snapshot(
            sessions: [session], wellbeing: [], profile: profile, now: referenceNow
        )

        for value in snapshot.fatigue.values {
            #expect(value >= 0 && value <= 1)
        }
        #expect(snapshot.systemicReadiness >= 0 && snapshot.systemicReadiness <= 1)
        #expect(snapshot.fatigue(for: .quads) > 0.99)
    }

    @Test("A hundred maximal sessions never push fatigue past one or readiness below zero")
    func aHundredSessionsStayBounded() {
        let profile = TrainingProfileSnapshot()
        let sessions = (0..<100).map { index in
            makeOutcome(
                id: index,
                hoursAgo: Double(index) * 2,
                groupSets: Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.map { ($0, 50.0) }),
                effort: .exhausting,
                averageRIR: 0
            )
        }
        let snapshot = RecoveryEngine.snapshot(
            sessions: sessions, wellbeing: [], profile: profile, now: referenceNow
        )

        for (group, value) in snapshot.fatigue {
            #expect(value >= 0 && value <= 1, "\(group) fatigue escaped 0...1 at \(value)")
        }
        #expect(snapshot.systemicReadiness >= 0 && snapshot.systemicReadiness <= 1)
        #expect(snapshot.systemicReadiness < 0.01)
    }

    @Test("An excellent check-in cannot push readiness above one")
    func readinessIsClampedAtTheTop() {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [],
            wellbeing: [excellentCheckIn(at: referenceNow)],
            profile: TrainingProfileSnapshot(),
            now: referenceNow
        )
        #expect(snapshot.systemicReadiness == 1.0)
    }

    @Test("A dismal check-in on top of a heavy block cannot push readiness below zero")
    func readinessIsClampedAtTheBottom() {
        let sessions = (0..<20).map { index in
            makeOutcome(
                id: index, hoursAgo: Double(index) * 4,
                groupSets: [.quads: 40, .back: 40, .chest: 40], effort: .exhausting, averageRIR: 0
            )
        }
        let snapshot = RecoveryEngine.snapshot(
            sessions: sessions,
            wellbeing: [poorCheckIn(at: referenceNow)],
            profile: TrainingProfileSnapshot(),
            now: referenceNow
        )
        #expect(snapshot.systemicReadiness >= 0)
    }
}

// MARK: - Empty inputs

@Suite("Recovery with nothing to go on")
struct RecoveryEmptyInputTests {

    @Test("No sessions and no check-ins yields a fully recovered snapshot")
    func emptyInputsAreFullyRecovered() {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [], wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )

        #expect(snapshot.fatigue.isEmpty)
        #expect(snapshot.daysSinceStimulus.isEmpty)
        #expect(snapshot.weeklySets.isEmpty)
        #expect(snapshot.recentSessionCount == 0)
        #expect(snapshot.systemicReadiness == 1.0)
        #expect(RecoveryEngine.readinessSummary(snapshot).key == "recovery.summary.fresh")
    }

    @Test("Every volume-tracked group is ready when there is no history at all")
    func everyGroupIsReadyWithNoHistory() {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [], wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        #expect(RecoveryEngine.readyGroups(snapshot).count == MuscleGroup.volumeTracked.count)
    }

    @Test("A session with nothing completed does not count as a recent session")
    func sessionWithNoCompletedSetsIsNotCounted() {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [makeOutcome(hoursAgo: 10, groupSets: [.quads: 4], plannedSets: 12, completedSets: 0)],
            wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        #expect(snapshot.recentSessionCount == 0)
        // The credits were still recorded, so the weekly tally still sees them.
        #expect(snapshot.weeklySets[.quads] == 4)
    }

    @Test("Sessions dated in the future are ignored entirely")
    func futureSessionsAreIgnored() {
        let future = makeOutcome(hoursAgo: -48, groupSets: [.quads: 20], effort: .exhausting)
        let snapshot = RecoveryEngine.snapshot(
            sessions: [future], wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        #expect(snapshot.fatigue.isEmpty)
        #expect(snapshot.recentSessionCount == 0)
        #expect(snapshot.systemicReadiness == 1.0)
    }

    @Test("A single session is enough to produce a usable snapshot")
    func singleSessionProducesASnapshot() {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [referenceHardQuadSession(hoursAgo: 2)],
            wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        #expect(snapshot.recentSessionCount == 1)
        #expect(snapshot.fatigue(for: .quads) > 0)
        #expect(snapshot.daysSinceStimulus[.quads] == 0)
    }

    @Test("A session with no group credits leaves fatigue untouched")
    func sessionWithNoGroupCreditsAddsNoFatigue() {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [makeOutcome(hoursAgo: 1, groupSets: [:])],
            wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        #expect(snapshot.fatigue.isEmpty)
        #expect(snapshot.recentSessionCount == 1)
        #expect(snapshot.systemicReadiness == 1.0)
    }
}

// MARK: - Proximity to failure

@Suite("Proximity to failure prices the set")
struct RecoveryProximityTests {

    @Test("A set to failure costs about 37 per cent more than one stopped at three reps in reserve")
    func failureCostsMoreThanThreeRepsInReserve() {
        let toFailure = RecoveryEngine.proximityFactor(repsInReserve: 0)
        let atThree = RecoveryEngine.proximityFactor(repsInReserve: 3)

        #expect(toFailure > atThree)
        #expect(abs(toFailure - 1.32) < 1e-9)
        #expect(abs(atThree - 0.96) < 1e-9)
        #expect(abs(toFailure / atThree - 1.375) < 0.001)
    }

    @Test("Proximity is clamped at both ends and negative reps in reserve never exceed failure")
    func proximityIsClamped() {
        #expect(RecoveryEngine.proximityFactor(repsInReserve: 20) == RecoveryTuning.proximityFloor)
        #expect(RecoveryEngine.proximityFactor(repsInReserve: -5) == RecoveryTuning.proximityAtFailure)
        for rir in stride(from: -5.0, through: 20.0, by: 0.5) {
            let value = RecoveryEngine.proximityFactor(repsInReserve: rir)
            #expect(value >= RecoveryTuning.proximityFloor && value <= RecoveryTuning.proximityCeiling)
        }
    }

    @Test("A session taken to failure leaves more fatigue than the same session at three reps in reserve")
    func failureSessionCostsMoreThroughSnapshot() {
        let profile = TrainingProfileSnapshot()
        let toFailure = RecoveryEngine.snapshot(
            sessions: [makeOutcome(hoursAgo: 0, groupSets: [.quads: 4], averageRIR: 0)],
            wellbeing: [], profile: profile, now: referenceNow
        )
        let atThree = RecoveryEngine.snapshot(
            sessions: [makeOutcome(hoursAgo: 0, groupSets: [.quads: 4], averageRIR: 3)],
            wellbeing: [], profile: profile, now: referenceNow
        )
        #expect(toFailure.fatigue(for: .quads) > atThree.fatigue(for: .quads))
        #expect(toFailure.systemicReadiness < atThree.systemicReadiness)
    }

    @Test("An unrated session is priced at the profile's target reps in reserve, not at failure")
    func unratedSessionIsNotTreatedAsFailure() {
        var novice = TrainingProfileSnapshot()
        novice.experience = .never  // defaultTargetRIR 4

        let unrated = RecoveryEngine.snapshot(
            sessions: [makeOutcome(hoursAgo: 0, groupSets: [.quads: 4])],
            wellbeing: [], profile: novice, now: referenceNow
        )
        let toFailure = RecoveryEngine.snapshot(
            sessions: [makeOutcome(hoursAgo: 0, groupSets: [.quads: 4], averageRIR: 0)],
            wellbeing: [], profile: novice, now: referenceNow
        )
        let atFour = RecoveryEngine.snapshot(
            sessions: [makeOutcome(hoursAgo: 0, groupSets: [.quads: 4], averageRIR: 4)],
            wellbeing: [], profile: novice, now: referenceNow
        )

        #expect(unrated.fatigue(for: .quads) < toFailure.fatigue(for: .quads))
        #expect(abs(unrated.fatigue(for: .quads) - atFour.fatigue(for: .quads)) < 1e-9)
    }

    @Test("The session's effort rating scales the whole session")
    func effortRatingScalesFatigue() {
        let profile = TrainingProfileSnapshot()
        let values = [SessionEffortFeedback.easy, .good, .hard, .exhausting].map { effort in
            RecoveryEngine.snapshot(
                sessions: [makeOutcome(hoursAgo: 0, groupSets: [.quads: 6], effort: effort, averageRIR: 2)],
                wellbeing: [], profile: profile, now: referenceNow
            ).fatigue(for: .quads)
        }
        for index in 1..<values.count {
            #expect(values[index] > values[index - 1])
        }
    }
}

// MARK: - Indirect volume

@Suite("Indirect volume fatigues synergists")
struct RecoveryIndirectVolumeTests {

    @Test("A synergist accrues fatigue at its fractional credit with no direct set of its own")
    func synergistAccruesFractionalFatigue() throws {
        let row = makeExercise(id: "row", volumeContribution: [.back: 1.0, .biceps: 0.5])
        let performance = ExercisePerformance(
            date: hoursBefore(1), exerciseID: "row",
            sets: [makeSet(rir: 2), makeSet(rir: 2), makeSet(rir: 2)]
        )
        // Only the back was credited on the outcome itself; the biceps credit lives in the catalogue.
        let outcome = makeOutcome(hoursAgo: 1, groupSets: [.back: 3], performances: [performance])

        let contribution = RecoveryEngine.fatigueContribution(of: outcome, catalog: ["row": row])
        let back = try #require(contribution[.back])
        let biceps = try #require(contribution[.biceps])

        #expect(biceps > 0)
        #expect(abs(biceps - back * 0.5) < 1e-9)
        #expect(outcome.groupSets[.biceps] == nil)
    }

    @Test("Recorded indirect credit raises synergist fatigue through the snapshot path")
    func snapshotCreditsSynergistsFromRecordedGroupSets() {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [makeOutcome(hoursAgo: 1, groupSets: [.back: 3, .biceps: 1.5], averageRIR: 2)],
            wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        #expect(snapshot.fatigue(for: .biceps) > 0)
        #expect(snapshot.fatigue(for: .biceps) < snapshot.fatigue(for: .back))
    }

    @Test("An exercise missing from the catalogue falls back to the recorded group credits")
    func unknownExerciseFallsBackToGroupSets() throws {
        let performance = ExercisePerformance(
            date: hoursBefore(1), exerciseID: "not-in-catalogue", sets: [makeSet(rir: 2)]
        )
        let outcome = makeOutcome(hoursAgo: 1, groupSets: [.back: 3], performances: [performance])
        let contribution = RecoveryEngine.fatigueContribution(of: outcome, catalog: [:])

        let back = try #require(contribution[.back])
        #expect(back > 0)
        #expect(contribution[.biceps] == nil)
    }

    @Test("An exercise crediting no group contributes nothing rather than crashing")
    func exerciseWithNoVolumeCreditContributesNothing() {
        let ghost = makeExercise(id: "ghost", volumeContribution: [:])
        let performance = ExercisePerformance(
            date: hoursBefore(1), exerciseID: "ghost", sets: [makeSet(rir: 2)]
        )
        let outcome = makeOutcome(hoursAgo: 1, groupSets: [:], performances: [performance])
        #expect(RecoveryEngine.fatigueContribution(of: outcome, catalog: ["ghost": ghost]).isEmpty)
    }
}

// MARK: - Subjective check-ins

@Suite("Subjective check-ins modulate readiness around neutral")
struct RecoverySubjectiveTests {

    @Test("An absent check-in moves readiness exactly as much as a neutral one: not at all")
    func absentCheckInIsIdenticalToNeutral() {
        let profile = TrainingProfileSnapshot()
        let sessions = [referenceHardQuadSession(hoursAgo: 0)]

        let withoutCheckIn = RecoveryEngine.snapshot(
            sessions: sessions, wellbeing: [], profile: profile, now: referenceNow
        )
        let withNeutral = RecoveryEngine.snapshot(
            sessions: sessions, wellbeing: [neutralCheckIn(at: referenceNow)],
            profile: profile, now: referenceNow
        )
        #expect(abs(withNeutral.systemicReadiness - withoutCheckIn.systemicReadiness) < 1e-9)
    }

    @Test("Missing subjective data reads as neither good nor bad")
    func missingSubjectiveDataIsNotReadAsGoodOrBad() {
        let profile = TrainingProfileSnapshot()
        let sessions = [referenceHardQuadSession(hoursAgo: 0)]

        let none = RecoveryEngine.snapshot(
            sessions: sessions, wellbeing: [], profile: profile, now: referenceNow
        ).systemicReadiness
        let good = RecoveryEngine.snapshot(
            sessions: sessions, wellbeing: [excellentCheckIn(at: referenceNow)],
            profile: profile, now: referenceNow
        ).systemicReadiness
        let bad = RecoveryEngine.snapshot(
            sessions: sessions, wellbeing: [poorCheckIn(at: referenceNow)],
            profile: profile, now: referenceNow
        ).systemicReadiness

        #expect(bad < none)
        #expect(none < good)
        #expect(abs((good - none) - RecoveryTuning.subjectiveSwing) < 1e-9)
        #expect(abs((none - bad) - RecoveryTuning.subjectiveSwing) < 1e-9)
    }

    @Test("A check-in with every question skipped is no information at all")
    func fullySkippedCheckInIsNoInformation() {
        let profile = TrainingProfileSnapshot()
        let blank = WellbeingSnapshot(date: referenceNow)

        #expect(RecoveryEngine.index(of: blank) == nil)
        #expect(RecoveryEngine.wellbeingIndex([blank], now: referenceNow) == nil)

        let sessions = [referenceHardQuadSession(hoursAgo: 0)]
        let withBlank = RecoveryEngine.snapshot(
            sessions: sessions, wellbeing: [blank], profile: profile, now: referenceNow
        )
        let withNothing = RecoveryEngine.snapshot(
            sessions: sessions, wellbeing: [], profile: profile, now: referenceNow
        )
        #expect(withBlank.systemicReadiness == withNothing.systemicReadiness)
    }

    @Test("No check-ins at all returns no index rather than a neutral one")
    func emptyCheckInListReturnsNil() {
        #expect(RecoveryEngine.wellbeingIndex([], now: referenceNow) == nil)
    }

    @Test("A partly answered check-in renormalises over what was actually answered")
    func partialCheckInRenormalises() throws {
        let good = try #require(RecoveryEngine.index(of: WellbeingSnapshot(energy: 5, date: referenceNow)))
        let bad = try #require(RecoveryEngine.index(of: WellbeingSnapshot(energy: 1, date: referenceNow)))
        let neutral = try #require(RecoveryEngine.index(of: neutralCheckIn(at: referenceNow)))

        #expect(good == 1.0)
        #expect(bad == 0.0)
        #expect(abs(neutral - 0.5) < 1e-9)
    }

    @Test("Sleep hours map five hours to zero and eight to one")
    func sleepHoursMapping() throws {
        let short = try #require(RecoveryEngine.index(of: WellbeingSnapshot(sleepHours: 5, date: referenceNow)))
        let long = try #require(RecoveryEngine.index(of: WellbeingSnapshot(sleepHours: 8, date: referenceNow)))
        let veryLong = try #require(RecoveryEngine.index(of: WellbeingSnapshot(sleepHours: 14, date: referenceNow)))

        #expect(short == 0.0)
        #expect(long == 1.0)
        #expect(veryLong == 1.0)
    }

    @Test("Check-ins outside the seventy-two hour window are not consulted")
    func staleCheckInsAreIgnored() {
        let stale = poorCheckIn(at: hoursBefore(80))
        #expect(RecoveryEngine.wellbeingIndex([stale], now: referenceNow) == nil)
    }

    @Test("Yesterday's check-in counts half as much as today's")
    func recencyWeightingHalvesEachDay() throws {
        let today = excellentCheckIn(at: referenceNow)
        let yesterday = poorCheckIn(at: hoursBefore(24))
        let index = try #require(RecoveryEngine.wellbeingIndex([today, yesterday], now: referenceNow))
        // 1.0 at weight 1 and 0.0 at weight 0.5 → 1 / 1.5.
        #expect(abs(index - (1.0 / 1.5)) < 1e-9)
    }

    @Test("Check-in ordering does not change the index")
    func checkInOrderDoesNotMatter() {
        let entries = [excellentCheckIn(at: referenceNow), poorCheckIn(at: hoursBefore(24))]
        let forward = RecoveryEngine.wellbeingIndex(entries, now: referenceNow)
        let reversed = RecoveryEngine.wellbeingIndex(entries.reversed(), now: referenceNow)
        #expect(forward == reversed)
    }
}

// MARK: - Reported soreness

@Suite("Reported soreness never reads as fresh")
struct RecoverySorenessTests {

    @Test("A group reported sore carries fatigue even with no session on record")
    func soreGroupHasFatigueWithoutHistory() {
        let checkIn = WellbeingSnapshot(soreGroups: [.quads], date: referenceNow)
        let snapshot = RecoveryEngine.snapshot(
            sessions: [], wellbeing: [checkIn], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        // Numeric soreness skipped → severity 0.60, recency 1 → floor 0.30 × 0.60.
        #expect(abs(snapshot.fatigue(for: .quads) - 0.18) < 1e-9)
        #expect(snapshot.fatigue[.back] == nil)
    }

    @Test("Naming a group keeps a severity floor even when the numeric answer says barely sore")
    func namingAGroupKeepsASeverityFloor() {
        let checkIn = WellbeingSnapshot(soreness: 1, soreGroups: [.quads], date: referenceNow)
        let snapshot = RecoveryEngine.snapshot(
            sessions: [], wellbeing: [checkIn], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        // severity max(0.40, scale(1) = 0) = 0.40 → floor 0.30 × 0.40.
        #expect(abs(snapshot.fatigue(for: .quads) - 0.12) < 1e-9)
    }

    @Test("Reported soreness raises the fatigue a session already left behind")
    func sorenessBoostsExistingFatigue() {
        let profile = TrainingProfileSnapshot()
        let session = referenceHardQuadSession(hoursAgo: 24)
        let plain = RecoveryEngine.snapshot(
            sessions: [session], wellbeing: [], profile: profile, now: referenceNow
        )
        let sore = RecoveryEngine.snapshot(
            sessions: [session],
            wellbeing: [WellbeingSnapshot(soreness: 5, soreGroups: [.quads], date: referenceNow)],
            profile: profile, now: referenceNow
        )
        #expect(sore.fatigue(for: .quads) > plain.fatigue(for: .quads))
        #expect(sore.systemicReadiness < plain.systemicReadiness)
    }
}

// MARK: - readyGroups

@Suite("readyGroups ranks and filters")
struct RecoveryReadyGroupsTests {

    private func snapshot(_ fatigue: [MuscleGroup: Double]) -> RecoverySnapshot {
        RecoverySnapshot(fatigue: fatigue)
    }

    @Test("readyGroups is ordered from most recovered to least")
    func readyGroupsIsOrderedByAscendingFatigue() throws {
        let state = snapshot([.quads: 0.30, .back: 0.20, .chest: 0.10])
        let result = RecoveryEngine.readyGroups(state)
        let quads = try #require(result.firstIndex(of: .quads))
        let back = try #require(result.firstIndex(of: .back))
        let chest = try #require(result.firstIndex(of: .chest))

        #expect(chest < back)
        #expect(back < quads)
        // The whole list is non-decreasing in fatigue.
        let ordered = result.map { state.fatigue(for: $0) }
        for index in 1..<ordered.count {
            #expect(ordered[index] >= ordered[index - 1])
        }
    }

    @Test("readyGroups drops anything past the threshold and keeps the boundary itself")
    func readyGroupsHonoursTheThreshold() {
        let result = RecoveryEngine.readyGroups(
            snapshot([.chest: 0.35, .back: 0.36, .quads: 0.9]), threshold: 0.35
        )
        #expect(result.contains(.chest))
        #expect(!result.contains(.back))
        #expect(!result.contains(.quads))
    }

    @Test("A custom threshold is respected in both directions")
    func readyGroupsRespectsACustomThreshold() {
        let state = snapshot([.chest: 0.5, .back: 0.2])
        #expect(RecoveryEngine.readyGroups(state, threshold: 0.6).contains(.chest))
        #expect(!RecoveryEngine.readyGroups(state, threshold: 0.4).contains(.chest))
        #expect(RecoveryEngine.readyGroups(state, threshold: 0).isEmpty == false)
    }

    @Test("A threshold of zero admits only completely fresh groups")
    func zeroThresholdAdmitsOnlyFreshGroups() {
        let result = RecoveryEngine.readyGroups(snapshot([.chest: 0.01]), threshold: 0)
        #expect(!result.contains(.chest))
        #expect(result.count == MuscleGroup.volumeTracked.count - 1)
    }

    @Test("readyGroups never offers cardio or neck, which are programmed separately")
    func readyGroupsExcludesCardioAndNeck() {
        let result = RecoveryEngine.readyGroups(snapshot([:]), threshold: 1)
        #expect(!result.contains(.cardio))
        #expect(!result.contains(.neck))
        #expect(result.count == MuscleGroup.volumeTracked.count)
    }

    @Test("Groups tied on fatigue keep a stable order")
    func tiedGroupsAreOrderedDeterministically() {
        let state = snapshot([.chest: 0.2, .back: 0.2])
        #expect(RecoveryEngine.readyGroups(state) == RecoveryEngine.readyGroups(state))
    }
}

// MARK: - Bookkeeping fields

@Suite("Recovery snapshot bookkeeping")
struct RecoverySnapshotFieldsTests {

    @Test("daysSinceStimulus counts whole elapsed days, not calendar days")
    func daysSinceStimulusCountsWholeElapsedDays() {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [makeOutcome(hoursAgo: 30, groupSets: [.quads: 4])],
            wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        #expect(snapshot.daysSinceStimulus[.quads] == 1)
    }

    @Test("Token credit below half a set does not count as a stimulus")
    func tokenCreditIsNotAStimulus() {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [makeOutcome(hoursAgo: 30, groupSets: [.quads: 4, .calves: 0.4])],
            wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        #expect(snapshot.daysSinceStimulus[.quads] == 1)
        #expect(snapshot.daysSinceStimulus[.calves] == nil)
    }

    @Test("daysSinceStimulus reports the most recent qualifying session")
    func daysSinceStimulusUsesTheMostRecentSession() {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [
                makeOutcome(id: 1, hoursAgo: 120, groupSets: [.quads: 4]),
                makeOutcome(id: 2, hoursAgo: 26, groupSets: [.quads: 4])
            ],
            wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        #expect(snapshot.daysSinceStimulus[.quads] == 1)
    }

    @Test("weeklySets counts only the trailing seven days and keeps fractional credit")
    func weeklySetsCountsTheTrailingWeekOnly() throws {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [
                makeOutcome(id: 1, hoursAgo: 10, groupSets: [.quads: 4, .glutes: 1.5]),
                makeOutcome(id: 2, hoursAgo: 100, groupSets: [.quads: 3]),
                makeOutcome(id: 3, hoursAgo: 200, groupSets: [.quads: 99])
            ],
            wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        let quads = try #require(snapshot.weeklySets[.quads])
        let glutes = try #require(snapshot.weeklySets[.glutes])
        #expect(quads == 7)
        #expect(glutes == 1.5)
    }

    @Test("recentSessionCount counts only completed sessions inside the week")
    func recentSessionCountWindow() {
        let snapshot = RecoveryEngine.snapshot(
            sessions: [
                makeOutcome(id: 1, hoursAgo: 10, groupSets: [.quads: 4]),
                makeOutcome(id: 2, hoursAgo: 100, groupSets: [.quads: 4]),
                makeOutcome(id: 3, hoursAgo: 200, groupSets: [.quads: 4]),
                makeOutcome(id: 4, hoursAgo: 20, groupSets: [.quads: 4], completedSets: 0)
            ],
            wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        #expect(snapshot.recentSessionCount == 2)
    }

    @Test("Session ordering does not change the snapshot")
    func snapshotIsIndependentOfInputOrder() {
        let sessions = [
            makeOutcome(id: 1, hoursAgo: 10, groupSets: [.quads: 4], effort: .hard, averageRIR: 2),
            makeOutcome(id: 2, hoursAgo: 40, groupSets: [.back: 6], effort: .good, averageRIR: 1),
            makeOutcome(id: 3, hoursAgo: 90, groupSets: [.chest: 5], effort: .easy, averageRIR: 3)
        ]
        let forward = RecoveryEngine.snapshot(
            sessions: sessions, wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        let backward = RecoveryEngine.snapshot(
            sessions: sessions.reversed(), wellbeing: [], profile: TrainingProfileSnapshot(), now: referenceNow
        )
        #expect(forward == backward)
    }
}

// MARK: - Readiness summary

@Suite("Readiness summary bands")
struct RecoveryReadinessSummaryTests {

    @Test("Each band maps to its documented wording")
    func bandsMapToWording() {
        func summary(_ readiness: Double, fatigue: [MuscleGroup: Double] = [:]) -> String {
            RecoveryEngine.readinessSummary(
                RecoverySnapshot(fatigue: fatigue, systemicReadiness: readiness)
            ).key
        }

        #expect(summary(0.95) == "recovery.summary.fresh")
        #expect(summary(0.85) == "recovery.summary.fresh")
        #expect(summary(0.84) == "recovery.summary.ready")
        #expect(summary(0.65) == "recovery.summary.ready")
        #expect(summary(0.64) == "recovery.summary.moderate.systemic")
        #expect(summary(0.50, fatigue: [.quads: 0.6]) == "recovery.summary.moderate.groups")
        #expect(summary(0.44) == "recovery.summary.low.systemic")
        #expect(summary(0.20, fatigue: [.quads: 0.8]) == "recovery.summary.low.groups")
    }

    @Test("A readiness value outside zero to one is clamped before it is banded")
    func summaryClampsOutOfRangeReadiness() {
        #expect(
            RecoveryEngine.readinessSummary(RecoverySnapshot(systemicReadiness: 5)).key
                == "recovery.summary.fresh"
        )
        #expect(
            RecoveryEngine.readinessSummary(RecoverySnapshot(systemicReadiness: -5)).key
                == "recovery.summary.low.systemic"
        )
    }
}
