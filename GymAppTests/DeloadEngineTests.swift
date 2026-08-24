import Foundation
import Testing

@testable import GymApp

// MARK: - Fixtures
//
// File-private so nothing collides with sibling test files. Every date is derived from
// `deloadNow`; the engine's `now:` parameter is always supplied explicitly.

private let deloadNow = Date(timeIntervalSince1970: 1_750_000_000)

private func deloadUUID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
}

private func daysBefore(_ days: Double, _ now: Date = deloadNow) -> Date {
    now.addingTimeInterval(-days * 86400)
}

/// Eight sessions spread over 24 days: enough history to clear every gate.
///
/// `completionRates` is newest-first and defaults to a perfectly completed block.
private func baselineSessions(
    completionRates: [Double]? = nil,
    averageRIRs: [Double?]? = nil,
    now: Date = deloadNow
) -> [SessionOutcome] {
    let dayOffsets: [Double] = [1, 4, 7, 11, 14, 18, 22, 25]
    return dayOffsets.enumerated().map { index, days in
        let rate = completionRates?.indices.contains(index) == true ? completionRates![index] : 1.0
        let planned = 20
        let completed = max(1, Int((Double(planned) * rate).rounded()))
        return SessionOutcome(
            sessionID: deloadUUID(index),
            date: now.addingTimeInterval(-days * 86400),
            plannedSets: planned,
            completedSets: completed,
            skippedExerciseIDs: [],
            substitutedExerciseIDs: [:],
            effortFeedback: nil,
            durationSeconds: 3600,
            averageRIR: averageRIRs?.indices.contains(index) == true ? averageRIRs![index] : nil,
            groupSets: [.quads: 6],
            performances: []
        )
    }
}

private func performedSet(weight: Double, reps: Int, rir: Int? = nil) -> PerformedSet {
    PerformedSet(weightKg: weight, reps: reps, rir: rir)
}

/// Three sessions of one exercise, newest first, at the given loads.
private func history(
    id: String,
    loads: [Double],
    reps: Int = 5,
    rirs: [Int?] = [nil, nil, nil],
    dayOffsets: [Double] = [2, 9, 16],
    now: Date = deloadNow
) -> ExerciseHistorySnapshot {
    let performances = zip(loads.indices, loads).map { index, load in
        ExercisePerformance(
            date: now.addingTimeInterval(-dayOffsets[index] * 86400),
            exerciseID: id,
            sets: [
                performedSet(weight: load, reps: reps, rir: rirs[index]),
                performedSet(weight: load, reps: reps, rir: rirs[index])
            ]
        )
    }
    return ExerciseHistorySnapshot(exerciseID: id, performances: performances)
}

/// e1RM falling on every step, by well over the 2.5 % noise floor.
private func regressingHistory(id: String) -> ExerciseHistorySnapshot {
    history(id: id, loads: [94, 97, 100])
}

/// Identical loads and reps: no regression at all.
private func flatHistory(id: String) -> ExerciseHistorySnapshot {
    history(id: id, loads: [100, 100, 100])
}

/// Same load, two fewer reps in reserve than it used to cost.
private func inflatingHistory(id: String) -> ExerciseHistorySnapshot {
    history(id: id, loads: [100, 100, 100], reps: 8, rirs: [0, 2, 2])
}

private func keyed(_ histories: [ExerciseHistorySnapshot]) -> [String: ExerciseHistorySnapshot] {
    Dictionary(uniqueKeysWithValues: histories.map { ($0.exerciseID, $0) })
}

/// A check-in answered at the bottom of every scale: index 0.
private func bottomCheckIn(daysAgo days: Double) -> WellbeingSnapshot {
    WellbeingSnapshot(
        energy: 1, sleepQuality: 1, sleepHours: 4, soreness: 5, motivation: 1, stress: 5,
        date: daysBefore(days)
    )
}

private func experiencedProfile() -> TrainingProfileSnapshot {
    var profile = TrainingProfileSnapshot()
    profile.experience = .intermediate
    return profile
}

private func assess(
    sessions: [SessionOutcome]? = nil,
    histories: [String: ExerciseHistorySnapshot] = [:],
    recovery: RecoverySnapshot = .fresh,
    wellbeing: [WellbeingSnapshot] = [],
    weeksSinceLastDeload: Int = 2,
    profile: TrainingProfileSnapshot? = nil
) -> DeloadAssessment {
    DeloadEngine.assess(
        sessions: sessions ?? baselineSessions(),
        histories: histories,
        recovery: recovery,
        wellbeing: wellbeing,
        weeksSinceLastDeload: weeksSinceLastDeload,
        profile: profile ?? experiencedProfile(),
        now: deloadNow
    )
}

// MARK: - No single signal

@Suite("A deload is never recommended on one signal")
struct DeloadSingleSignalTests {

    @Test("The weights sum to one and no single weight can reach the severity threshold")
    func noSingleSignalCanClearTheThreshold() throws {
        let weights = [
            DeloadTuning.weightPerformanceRegression,
            DeloadTuning.weightElevatedFatigue,
            DeloadTuning.weightBlockLength,
            DeloadTuning.weightEffortInflation,
            DeloadTuning.weightSubjective,
            DeloadTuning.weightMissedSets
        ]
        #expect(abs(weights.reduce(0, +) - 1.0) < 1e-9)
        let heaviest = try #require(weights.max())
        #expect(heaviest < DeloadTuning.severityThreshold)
    }

    @Test("One session falling apart never recommends a deload")
    func oneBadSessionIsNotEnough() {
        let assessment = assess(
            sessions: baselineSessions(completionRates: [0.1, 1, 1, 1, 1, 1, 1, 1])
        )
        #expect(!assessment.shouldDeload)
        #expect(assessment.severity <= DeloadTuning.weightMissedSets + 1e-9)
        #expect(assessment.volumeReduction == 0)
        #expect(assessment.intensityReduction == 0)
    }

    @Test("Three exercises regressing and nothing else stays a note, not a recommendation")
    func regressionAloneIsANoteNotARecommendation() {
        // docs/fragments/recovery.md worked example: severity 0.28, one signal, no recommendation.
        let assessment = assess(
            histories: keyed([regressingHistory(id: "a"), regressingHistory(id: "b"), regressingHistory(id: "c")])
        )
        #expect(!assessment.shouldDeload)
        #expect(abs(assessment.severity - 0.28) < 1e-9)
        #expect(assessment.reasons.first?.key == "deload.summary.watch")
        #expect(assessment.reasons.map(\.key) == ["deload.summary.watch", "deload.reason.performanceRegression"])
        #expect(assessment.reasons.last?.arguments == ["3"])
    }

    @Test("A long block on its own never recommends a deload")
    func blockLengthAloneIsNotEnough() {
        let assessment = assess(weeksSinceLastDeload: 12)
        #expect(!assessment.shouldDeload)
        #expect(abs(assessment.severity - DeloadTuning.weightBlockLength) < 1e-9)
        #expect(assessment.reasons.map(\.key) == ["deload.summary.watch", "deload.reason.blockLength"])
    }

    @Test("Rock-bottom readiness on its own never recommends a deload")
    func lowReadinessAloneIsNotEnough() {
        let assessment = assess(recovery: RecoverySnapshot(systemicReadiness: 0.0))
        #expect(!assessment.shouldDeload)
        #expect(abs(assessment.severity - DeloadTuning.weightElevatedFatigue) < 1e-9)
    }
}

// MARK: - Corroboration

@Suite("Corroborating signals earn a deload")
struct DeloadCorroborationTests {

    @Test("Regression plus a six-week block clears the threshold")
    func twoSignalsClearTheThreshold() {
        let assessment = assess(
            histories: keyed([regressingHistory(id: "a"), regressingHistory(id: "b"), regressingHistory(id: "c")]),
            weeksSinceLastDeload: 6
        )
        // 0.28 + 0.18 × 0.75 = 0.415.
        #expect(assessment.shouldDeload)
        #expect(abs(assessment.severity - 0.415) < 1e-9)
        #expect(assessment.reasons.map(\.key) == [
            "deload.summary.recommended",
            "deload.reason.performanceRegression",
            "deload.reason.blockLength"
        ])
    }

    @Test("A marginal call gets the gentle end of the prescription")
    func marginalCallGetsTheGentlestPrescription() {
        let assessment = assess(
            histories: keyed([regressingHistory(id: "a"), regressingHistory(id: "b"), regressingHistory(id: "c")]),
            weeksSinceLastDeload: 6
        )
        #expect(assessment.volumeReduction >= DeloadTuning.baselineVolumeReduction)
        #expect(assessment.volumeReduction < 0.41)
        #expect(assessment.intensityReduction >= DeloadTuning.baselineIntensityReduction)
        #expect(assessment.intensityReduction < 0.11)
    }

    @Test("The documented four-signal case produces the documented prescription")
    func fourSignalsProduceTheDocumentedPrescription() {
        // docs/fragments/recovery.md: 0.28 + 0.15 + 0.135 + 0.12 = 0.685 → 48 % volume, 14 % intensity,
        // reasons ordered regression → fatigue → block length → check-ins.
        let recovery = RecoverySnapshot(
            fatigue: [.quads: 0.70, .hamstrings: 0.70, .glutes: 0.65, .back: 0.62],
            systemicReadiness: 0.5
        )
        let assessment = assess(
            histories: keyed([regressingHistory(id: "a"), regressingHistory(id: "b"), regressingHistory(id: "c")]),
            recovery: recovery,
            wellbeing: [bottomCheckIn(daysAgo: 1), bottomCheckIn(daysAgo: 2), bottomCheckIn(daysAgo: 3)],
            weeksSinceLastDeload: 6
        )

        #expect(assessment.shouldDeload)
        #expect(abs(assessment.severity - 0.685) < 1e-9)
        #expect(abs(assessment.volumeReduction - 0.481428571) < 1e-6)
        #expect(abs(assessment.intensityReduction - 0.140714285) < 1e-6)
        #expect(assessment.reasons.map(\.key) == [
            "deload.summary.recommended",
            "deload.reason.performanceRegression",
            "deload.reason.elevatedFatigue",
            "deload.reason.blockLength",
            "deload.reason.subjective"
        ])
        #expect(assessment.reasons.first?.arguments == ["48", "14"])
    }

    @Test("Severity rises with each corroborating signal")
    func severityScalesWithTheNumberOfSignals() {
        let regressions = keyed([
            regressingHistory(id: "a"), regressingHistory(id: "b"), regressingHistory(id: "c")
        ])
        let loadedRecovery = RecoverySnapshot(
            fatigue: [.quads: 0.70, .hamstrings: 0.70, .glutes: 0.65, .back: 0.62],
            systemicReadiness: 0.5
        )
        let checkIns = [bottomCheckIn(daysAgo: 1), bottomCheckIn(daysAgo: 2), bottomCheckIn(daysAgo: 3)]

        let one = assess(histories: regressions)
        let two = assess(histories: regressions, weeksSinceLastDeload: 6)
        let three = assess(histories: regressions, recovery: loadedRecovery, weeksSinceLastDeload: 6)
        let four = assess(
            histories: regressions, recovery: loadedRecovery, wellbeing: checkIns, weeksSinceLastDeload: 6
        )

        #expect(one.severity < two.severity)
        #expect(two.severity < three.severity)
        #expect(three.severity < four.severity)
        #expect(!one.shouldDeload)
        #expect(two.shouldDeload && three.shouldDeload && four.shouldDeload)
        #expect(two.volumeReduction < three.volumeReduction)
        #expect(three.volumeReduction < four.volumeReduction)
    }

    @Test("Volume and intensity reductions stay inside their documented bands")
    func prescriptionStaysInsideItsBand() {
        let recovery = RecoverySnapshot(
            fatigue: Dictionary(uniqueKeysWithValues: MuscleGroup.volumeTracked.map { ($0, 0.95) }),
            systemicReadiness: 0.0
        )
        let assessment = assess(
            sessions: baselineSessions(completionRates: [0.2, 0.2, 0.2, 0.2, 1, 1, 1, 1]),
            histories: keyed([regressingHistory(id: "a"), regressingHistory(id: "b"), regressingHistory(id: "c")]),
            recovery: recovery,
            wellbeing: [bottomCheckIn(daysAgo: 1), bottomCheckIn(daysAgo: 2), bottomCheckIn(daysAgo: 3)],
            weeksSinceLastDeload: 10
        )

        #expect(assessment.shouldDeload)
        #expect(assessment.severity <= 1.0)
        #expect(assessment.volumeReduction >= DeloadTuning.baselineVolumeReduction)
        #expect(assessment.volumeReduction <= DeloadTuning.maximumVolumeReduction)
        #expect(assessment.intensityReduction >= DeloadTuning.baselineIntensityReduction)
        #expect(assessment.intensityReduction <= DeloadTuning.maximumIntensityReduction)
    }

    @Test("Two signals below the threshold produce a worth-watching note with no reductions")
    func signalsUnderTheThresholdProduceAWatchNote() {
        // docs/fragments/recovery.md: effort inflation plus a five-week block = 0.16 + 0.09 = 0.25.
        let assessment = assess(
            histories: keyed([inflatingHistory(id: "a"), inflatingHistory(id: "b")]),
            weeksSinceLastDeload: 5
        )
        #expect(!assessment.shouldDeload)
        #expect(abs(assessment.severity - 0.25) < 1e-9)
        #expect(assessment.volumeReduction == 0)
        #expect(assessment.intensityReduction == 0)
        #expect(assessment.reasons.map(\.key) == [
            "deload.summary.watch",
            "deload.reason.effortInflation",
            "deload.reason.blockLength"
        ])
    }
}

// MARK: - History gates

@Suite("A user with no block to unload is never told to deload")
struct DeloadHistoryGateTests {

    /// Every signal shouting at once, so only the gate can hold the recommendation back.
    private func maximalSignals(
        sessions: [SessionOutcome]? = nil,
        weeksSinceLastDeload: Int = 6,
        profile: TrainingProfileSnapshot? = nil
    ) -> DeloadAssessment {
        assess(
            sessions: sessions,
            histories: keyed([regressingHistory(id: "a"), regressingHistory(id: "b"), regressingHistory(id: "c")]),
            recovery: RecoverySnapshot(
                fatigue: [.quads: 0.9, .hamstrings: 0.9, .glutes: 0.9, .back: 0.9, .chest: 0.9],
                systemicReadiness: 0.1
            ),
            wellbeing: [bottomCheckIn(daysAgo: 1), bottomCheckIn(daysAgo: 2), bottomCheckIn(daysAgo: 3)],
            weeksSinceLastDeload: weeksSinceLastDeload,
            profile: profile
        )
    }

    @Test("The same signals do recommend a deload once the gates are cleared")
    func maximalSignalsDoRecommendWithEnoughHistory() {
        #expect(maximalSignals().shouldDeload)
    }

    @Test("A user with almost no session history is never told to deload")
    func tooFewSessionsIsSilent() {
        let sparse = Array(baselineSessions().prefix(3))
        let assessment = maximalSignals(sessions: sparse)
        #expect(assessment == DeloadAssessment.none)
    }

    @Test("A user with no sessions at all is never told to deload")
    func noSessionsIsSilent() {
        #expect(maximalSignals(sessions: []) == DeloadAssessment.none)
    }

    @Test("Enough sessions crammed into under three weeks is still not a block")
    func tooShortATrainingSpanIsSilent() {
        let crammed = (0..<8).map { index in
            SessionOutcome(
                sessionID: deloadUUID(100 + index),
                date: daysBefore(Double(index)),
                plannedSets: 20, completedSets: 20,
                skippedExerciseIDs: [], substitutedExerciseIDs: [:],
                effortFeedback: nil, durationSeconds: 3600, averageRIR: nil,
                groupSets: [.quads: 6], performances: []
            )
        }
        #expect(maximalSignals(sessions: crammed) == DeloadAssessment.none)
    }

    @Test("A user who has never trained is never told to deload")
    func inexperiencedUserIsSilent() {
        var novice = TrainingProfileSnapshot()
        novice.experience = .never
        #expect(maximalSignals(profile: novice) == DeloadAssessment.none)
    }

    @Test("A deload is never recommended straight after the last one")
    func tooSoonAfterTheLastDeloadIsSilent() {
        #expect(maximalSignals(weeksSinceLastDeload: 1) == DeloadAssessment.none)
        #expect(maximalSignals(weeksSinceLastDeload: 0) == DeloadAssessment.none)
        #expect(maximalSignals(weeksSinceLastDeload: -3) == DeloadAssessment.none)
    }

    @Test("Sessions with nothing completed do not count towards the history gate")
    func emptySessionsDoNotCountTowardsHistory() {
        let abandoned = baselineSessions().map { session -> SessionOutcome in
            var copy = session
            copy.completedSets = 0
            return copy
        }
        #expect(maximalSignals(sessions: abandoned) == DeloadAssessment.none)
    }
}

// MARK: - Reasons

@Suite("Reasons name the signals that actually fired")
struct DeloadReasonTests {

    @Test("A signal that did not fire is never named")
    func silentSignalsAreNotNamed() {
        let assessment = assess(
            histories: keyed([regressingHistory(id: "a"), regressingHistory(id: "b"), regressingHistory(id: "c")]),
            weeksSinceLastDeload: 6
        )
        let keys = Set(assessment.reasons.map(\.key))
        #expect(!keys.contains("deload.reason.subjective"))
        #expect(!keys.contains("deload.reason.elevatedFatigue"))
        #expect(!keys.contains("deload.reason.lowReadiness"))
        #expect(!keys.contains("deload.reason.missedSets"))
        #expect(!keys.contains("deload.reason.effortInflation"))
    }

    @Test("Reasons are ordered strongest contribution first")
    func reasonsAreOrderedByContribution() throws {
        // Missed sets (0.06 weight) must land behind block length (0.18 weight).
        let assessment = assess(
            sessions: baselineSessions(completionRates: [0.2, 0.2, 0.2, 0.2, 1, 1, 1, 1]),
            weeksSinceLastDeload: 8
        )
        let keys = assessment.reasons.map(\.key)
        let block = try #require(keys.firstIndex(of: "deload.reason.blockLength"))
        let missed = try #require(keys.firstIndex(of: "deload.reason.missedSets"))
        #expect(block < missed)
    }

    @Test("Several loaded groups are named as elevated fatigue, one is named as low readiness")
    func fatigueExplanationDependsOnHowManyGroupsAreLoaded() {
        let manyGroups = assess(
            recovery: RecoverySnapshot(
                fatigue: [.quads: 0.9, .hamstrings: 0.9, .glutes: 0.9], systemicReadiness: 0.5
            )
        )
        #expect(manyGroups.reasons.map(\.key).contains("deload.reason.elevatedFatigue"))
        #expect(manyGroups.reasons.last?.arguments == ["3"])

        let systemicOnly = assess(recovery: RecoverySnapshot(systemicReadiness: 0.1))
        #expect(systemicOnly.reasons.map(\.key).contains("deload.reason.lowReadiness"))
    }

    @Test("Nothing stirring at all returns an empty assessment")
    func quietBlockReturnsNothing() {
        let assessment = assess(histories: keyed([flatHistory(id: "a"), flatHistory(id: "b")]))
        #expect(assessment == DeloadAssessment.none)
        #expect(assessment.reasons.isEmpty)
    }
}

// MARK: - Individual signals

@Suite("Individual deload signals")
struct DeloadSignalTests {

    @Test("A drop inside the estimated-1RM noise floor is not a regression")
    func noiseIsNotARegression() {
        // 99 → 100 is a 1 % drop, under the 2.5 % floor.
        let quiet = assess(
            histories: keyed([
                history(id: "a", loads: [99, 99.5, 100]),
                history(id: "b", loads: [99, 99.5, 100]),
                history(id: "c", loads: [99, 99.5, 100])
            ])
        )
        #expect(quiet == DeloadAssessment.none)
    }

    @Test("Fewer than three eligible exercises means the regression signal has no opinion")
    func regressionNeedsThreeEligibleExercises() {
        let assessment = assess(histories: keyed([regressingHistory(id: "a"), regressingHistory(id: "b")]))
        #expect(assessment == DeloadAssessment.none)
    }

    @Test("Only one exercise going backwards is a bad day, not a pattern")
    func oneRegressingExerciseIsNotAPattern() {
        let assessment = assess(
            histories: keyed([regressingHistory(id: "a"), flatHistory(id: "b"), flatHistory(id: "c")])
        )
        #expect(assessment == DeloadAssessment.none)
    }

    @Test("Fewer than three check-ins means the subjective signal has no opinion, never a bad one")
    func subjectiveSignalNeedsThreeCheckIns() {
        let two = assess(wellbeing: [bottomCheckIn(daysAgo: 1), bottomCheckIn(daysAgo: 2)])
        #expect(two == DeloadAssessment.none)

        let three = assess(
            wellbeing: [bottomCheckIn(daysAgo: 1), bottomCheckIn(daysAgo: 2), bottomCheckIn(daysAgo: 3)]
        )
        #expect(abs(three.severity - DeloadTuning.weightSubjective) < 1e-9)
        #expect(three.reasons.map(\.key).contains("deload.reason.subjective"))
    }

    @Test("Check-ins with nothing answered are not counted as answers")
    func blankCheckInsAreNotOpinions() {
        let blanks = (1...4).map { WellbeingSnapshot(date: daysBefore(Double($0))) }
        #expect(assess(wellbeing: blanks) == DeloadAssessment.none)
    }

    @Test("Check-ins older than a week are not consulted")
    func staleCheckInsAreIgnored() {
        let stale = [bottomCheckIn(daysAgo: 8), bottomCheckIn(daysAgo: 9), bottomCheckIn(daysAgo: 10)]
        #expect(assess(wellbeing: stale) == DeloadAssessment.none)
    }

    @Test("Neutral check-ins say nothing rather than something bad")
    func neutralCheckInsAreSilent() {
        let neutral = (1...4).map { day in
            WellbeingSnapshot(
                energy: 3, sleepQuality: 3, sleepHours: 6.5, soreness: 3, motivation: 3, stress: 3,
                date: daysBefore(Double(day))
            )
        }
        #expect(assess(wellbeing: neutral) == DeloadAssessment.none)
    }

    @Test("Block length ramps from week three to week seven and never past full strength")
    func blockLengthRamps() {
        // Week 3 is the bottom of the ramp and week 4 is still below the fire threshold, so
        // neither has an opinion at all; from week 5 the contribution climbs to the weight itself.
        let atThree = assess(weeksSinceLastDeload: 3)
        let atFour = assess(weeksSinceLastDeload: 4)
        let atFive = assess(weeksSinceLastDeload: 5).severity
        let atSix = assess(weeksSinceLastDeload: 6).severity
        let atSeven = assess(weeksSinceLastDeload: 7).severity
        let atTwelve = assess(weeksSinceLastDeload: 12).severity

        #expect(atThree == DeloadAssessment.none)
        #expect(atFour == DeloadAssessment.none)
        #expect(atFive < atSix)
        #expect(atSix < atSeven)
        #expect(abs(atSeven - DeloadTuning.weightBlockLength) < 1e-9)
        #expect(atTwelve == atSeven)
    }

    @Test("An ordinary rate of unfinished sets is not a signal")
    func ordinaryMissedSetsAreNotASignal() {
        // 5 % of sets unfinished sits below the 8 % floor.
        #expect(assess(sessions: baselineSessions(completionRates: Array(repeating: 0.95, count: 8))).severity == 0)
    }

    @Test("Session-level effort drift stands in for users who never rate individual sets")
    func sessionLevelEffortDriftIsUsedAsAFallback() {
        let drifting = baselineSessions(averageRIRs: [0, 0.5, 2.5, 2.5, 2.5, 2.5, 2.5, 2.5])
        let assessment = assess(sessions: drifting)
        #expect(assessment.severity > 0)
        #expect(assessment.reasons.map(\.key).contains("deload.reason.effortInflationSession"))
    }

    @Test("A stable session-level effort rating is not drift")
    func stableEffortRatingIsNotDrift() {
        let steady = baselineSessions(averageRIRs: Array(repeating: 2, count: 8))
        #expect(assess(sessions: steady) == DeloadAssessment.none)
    }

    @Test("Assessment does not depend on the order sessions arrive in")
    func assessmentIsIndependentOfSessionOrder() {
        let sessions = baselineSessions(completionRates: [0.2, 0.4, 0.9, 1, 1, 1, 1, 1])
        let forward = assess(sessions: sessions, weeksSinceLastDeload: 6)
        let backward = assess(sessions: sessions.reversed(), weeksSinceLastDeload: 6)
        #expect(forward == backward)
    }

    @Test("Assessment does not depend on the order histories are keyed in")
    func assessmentIsIndependentOfHistoryOrder() {
        let histories = [regressingHistory(id: "a"), regressingHistory(id: "b"), regressingHistory(id: "c")]
        let forward = assess(histories: keyed(histories), weeksSinceLastDeload: 6)
        let backward = assess(histories: keyed(histories.reversed()), weeksSinceLastDeload: 6)
        #expect(forward == backward)
    }

    @Test("Sessions dated in the future are ignored")
    func futureSessionsAreIgnored() {
        var sessions = baselineSessions()
        sessions.append(
            SessionOutcome(
                sessionID: deloadUUID(999), date: daysBefore(-5),
                plannedSets: 20, completedSets: 1,
                skippedExerciseIDs: [], substitutedExerciseIDs: [:],
                effortFeedback: nil, durationSeconds: 3600, averageRIR: nil,
                groupSets: [.quads: 6], performances: []
            )
        )
        let withFuture = assess(sessions: sessions, weeksSinceLastDeload: 6)
        let withoutFuture = assess(sessions: baselineSessions(), weeksSinceLastDeload: 6)
        #expect(withFuture == withoutFuture)
        #expect(withFuture.reasons.map(\.key).contains("deload.reason.blockLength"))
    }
}
