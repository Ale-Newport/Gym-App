import Foundation

// MARK: - Deterministic randomness

/// SplitMix64, the reference finaliser used to seed xoshiro/xorshift generators.
///
/// The programming engine needs *tie-breaking*, not randomness: when three cable rows score within
/// a percent of each other, picking the same one every week makes programs feel mechanical, and
/// picking a different one on every call makes them untestable. A seeded generator gives variety
/// across users and across mesocycles while keeping a single `ProgrammingRequest` perfectly
/// reproducible. SplitMix64 is chosen because it is four lines long, has no bad seeds — including
/// zero — and passes BigCrush; nothing here needs cryptographic quality.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<upperBound`, or zero when the bound is empty.
    mutating func index(below upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}

/// FNV-1a over UTF-8.
///
/// Swift's `hashValue` is seeded per process, so it cannot be used anywhere a result has to be
/// identical between two runs of the app. Every string that feeds a seed goes through here instead.
func stableHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
}

// MARK: - Programming engine

/// Turns a `ProgrammingRequest` into a complete, time-feasible week of training.
///
/// The engine owns the *arrangement* decisions and delegates the two judgement calls it should not
/// be making itself: how much volume the week can hold (`VolumeAllocator`) and which structure
/// carries it best (`SplitSelector`). What is left — filling each slot with a real exercise, turning
/// slots into sets, reps, rest and RIR, and making the whole thing fit inside the user's stated
/// session length — is what this type does.
///
/// It is a pure value type: catalogue in, plan out. No persistence, no clock, no randomness beyond
/// `ProgrammingRequest.randomSeed`.
struct WorkoutProgrammingEngine: Sendable {

    // MARK: Session time model

    /// General warm-up: raising body temperature and moving the joints that are about to be loaded.
    private static let baseWarmupSeconds = 300
    /// Never less than this, however short the session: below two minutes it is not a warm-up.
    private static let minimumWarmupSeconds = 120
    /// Ramp-up sets before each heavy compound. Nobody's first squat set is their working set.
    private static let rampUpSecondsPerCompound = 90
    /// Ramp-ups are only paid for the first few heavy movements: by the fourth compound the body,
    /// and the relevant joints, are already warm and one light set is enough.
    private static let rampUpCompoundLimit = 3
    /// Finding the bench, setting the pin, loading the bar.
    private static let setupSecondsPerExercise = 40
    /// Walking to the next station.
    private static let transitionSeconds = 60
    /// The engine may add at most this fraction of extra sets when a session finishes early, so a
    /// generous time cap cannot quietly inflate the week past its recovery ceiling. Two hours of
    /// availability is not an instruction to train for two hours.
    private static let extensionAllowance = 0.30
    /// Working sets per exercise never exceed this; past it, within-exercise fatigue means the last
    /// set adds cost without adding stimulus.
    private static let maximumSetsPerExercise = 5

    private let catalog: [Exercise]
    private let byID: [String: Exercise]
    private let recommender: ExerciseRecommendationEngine

    init(catalog: [Exercise]) {
        self.catalog = catalog
        self.byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.recommender = ExerciseRecommendationEngine(catalog: catalog)
    }

    // MARK: - Generation

    /// Builds the week.
    func generate(_ request: ProgrammingRequest) -> GeneratedProgram {
        let profile = request.profile
        let targets = VolumeAllocator.targets(
            for: profile, recovery: request.recovery, isDeloadWeek: request.isDeloadWeek
        )
        let split = SplitSelector.selectSplit(profile: profile, targets: targets)
        let weekdays = SplitSelector.trainingWeekdays(profile: profile, count: split.blueprints.count)

        var context = FillContext(
            recentlyUsed: Set(request.recentlyUsedExerciseIDs),
            weekSelected: [],
            weekPatterns: [],
            trimmedSets: 0,
            addedSets: 0,
            usedGroupFallback: false,
            usedBodyweightFallback: false
        )
        let placements = lockedPlacements(blueprints: split.blueprints, request: request)

        var sessions: [GeneratedSession] = []
        for (index, blueprint) in split.blueprints.enumerated() {
            var rng = SeededGenerator(
                seed: request.randomSeed
                    &+ UInt64(request.weekIndex) &* 0x9E37_79B9
                    &+ stableHash(blueprint.titleKey)
                    &+ UInt64(index) &* 0x1000_0001
            )
            let session = buildSession(
                blueprint: blueprint,
                orderIndex: index,
                weekday: index < weekdays.count ? weekdays[index] : nil,
                sessionID: deterministicUUID(&rng),
                request: request,
                targets: targets,
                lockedSlots: placements.slots[index] ?? [:],
                lockedExtras: placements.extras[index] ?? [],
                context: &context,
                rng: &rng
            )
            sessions.append(session)
        }

        // Everything the user is not training is an explicit rest day, so the week reads as a week.
        // Rest days get seeded identifiers too: `GeneratedSession` defaults its id to a fresh
        // `UUID()`, which would quietly break the promise that one request always yields one
        // program.
        let used = Set(sessions.compactMap(\.weekday))
        for weekday in Weekday.orderedMondayFirst where !used.contains(weekday) {
            var restRNG = SeededGenerator(
                seed: request.randomSeed &+ 0x0000_5E5F_0000_0001 &+ UInt64(weekday.orderIndex)
            )
            sessions.append(GeneratedSession(
                id: deterministicUUID(&restRNG),
                orderIndex: sessions.count,
                titleKey: "session.title.rest",
                weekday: weekday,
                focusGroups: [],
                pushPull: .neutral,
                estimatedMinutes: 0,
                isRestDay: true
            ))
        }
        sessions.sort { lhs, rhs in
            let left = lhs.weekday?.orderIndex ?? 99
            let right = rhs.weekday?.orderIndex ?? 99
            if left != right { return left < right }
            return lhs.orderIndex < rhs.orderIndex
        }
        for index in sessions.indices { sessions[index].orderIndex = index }

        let weeklyVolume = VolumeAllocator.weeklyVolume(of: sessions, catalog: byID)
        let explanations = explain(
            split: split, targets: targets, request: request,
            sessions: sessions, weeklyVolume: weeklyVolume, context: context
        )

        return GeneratedProgram(
            splitKey: split.key,
            daysPerWeek: split.daysPerWeek,
            sessions: sessions,
            weeklyVolume: weeklyVolume,
            explanations: explanations,
            mesocycleLengthWeeks: mesocycleLength(for: profile.experience)
        )
    }

    /// Rebuilds a single session against the same blueprint, keeping anything the user pinned.
    ///
    /// Used by "give me a different workout": the structure of the week is not up for
    /// re-negotiation, only which exercises fill it. Everything currently in the session that is not
    /// locked is added to the recently-used set, so the re-roll genuinely produces different work
    /// rather than the same picks in a different order.
    func regenerateSession(_ session: GeneratedSession, request: ProgrammingRequest) -> GeneratedSession {
        guard !session.isRestDay else { return session }

        let profile = request.profile
        let targets = VolumeAllocator.targets(
            for: profile, recovery: request.recovery, isDeloadWeek: request.isDeloadWeek
        )
        let split = SplitSelector.selectSplit(profile: profile, targets: targets)
        let blueprint = split.blueprints.first { $0.titleKey == session.titleKey }
            ?? blueprint(from: session)

        let lockedIDs = request.lockedExerciseIDs
            .union(session.exercises.filter(\.isLocked).map(\.exerciseID))
        let displaced = session.exercises
            .map(\.exerciseID)
            .filter { !lockedIDs.contains($0) }

        var context = FillContext(
            recentlyUsed: Set(request.recentlyUsedExerciseIDs).union(displaced),
            weekSelected: [],
            weekPatterns: [],
            trimmedSets: 0,
            addedSets: 0,
            usedGroupFallback: false,
            usedBodyweightFallback: false
        )
        var rng = SeededGenerator(
            seed: request.randomSeed
                &+ stableHash(session.titleKey)
                &+ UInt64(session.orderIndex) &* 0x1000_0001
                &+ UInt64(request.weekIndex) &* 0x9E37_79B9
                &+ 0x5EED_C0DE
        )
        let assignment = assignLocked(blueprint: blueprint, lockedIDs: lockedIDs)

        var rebuilt = buildSession(
            blueprint: blueprint,
            orderIndex: session.orderIndex,
            weekday: session.weekday,
            sessionID: session.id,
            request: request,
            targets: targets,
            lockedSlots: assignment.slots,
            lockedExtras: assignment.extras,
            context: &context,
            rng: &rng
        )
        rebuilt.customTitle = session.customTitle
        return rebuilt
    }

    // MARK: - Session assembly

    /// Mutable state threaded through the whole week so the plan stays varied across sessions.
    private struct FillContext {
        var recentlyUsed: Set<String>
        var weekSelected: Set<String>
        var weekPatterns: Set<MovementPattern>
        var trimmedSets: Int
        var addedSets: Int
        var usedGroupFallback: Bool
        var usedBodyweightFallback: Bool
    }

    private struct FilledSlot {
        var slot: ExerciseSlot
        var exercise: Exercise
        var prescription: GeneratedExercise
    }

    private func buildSession(
        blueprint: SessionBlueprint,
        orderIndex: Int,
        weekday: Weekday?,
        sessionID: UUID,
        request: ProgrammingRequest,
        targets: VolumeTargets,
        lockedSlots: [Int: String],
        lockedExtras: [String],
        context: inout FillContext,
        rng: inout SeededGenerator
    ) -> GeneratedSession {
        var sessionSelected = Set<String>()
        var sessionPatterns = Set<MovementPattern>()
        var filled: [FilledSlot] = []

        for (slotIndex, slot) in blueprint.slots.enumerated() {
            let lateInSession = Double(slotIndex) >= Double(blueprint.slots.count) * 0.6
            var chosen: Exercise?
            var isLocked = false

            if let lockedID = lockedSlots[slotIndex], let exercise = byID[lockedID] {
                chosen = exercise
                isLocked = true
            } else {
                chosen = choose(
                    slot: slot,
                    lateInSession: lateInSession,
                    request: request,
                    sessionSelected: sessionSelected,
                    sessionPatterns: sessionPatterns,
                    context: &context,
                    rng: &rng
                )
            }

            guard let exercise = chosen else { continue }
            sessionSelected.insert(exercise.id)
            sessionPatterns.insert(exercise.metadata.movementPattern)
            context.weekSelected.insert(exercise.id)
            context.weekPatterns.insert(exercise.metadata.movementPattern)

            // `isPrimary` describes the heavy compound the session is built around. When the slot
            // ladder has had to relax all the way to an isolation — a leg curl standing in for a
            // hinge because the user's kit has nothing better — the movement is no longer that, and
            // calling it primary would give it the extra rest, the extra rep of margin, a ramp-up
            // allowance and the trimmer's protection, and would tell the user a leg curl is "the
            // main lift for this muscle".
            var effective = slot
            if effective.isPrimary && exercise.metadata.mechanic == .isolation {
                effective.isPrimary = false
            }

            let prescription = prescribe(
                exercise: exercise, slot: effective, request: request,
                orderIndex: filled.count, isLocked: isLocked
            )
            filled.append(FilledSlot(slot: effective, exercise: exercise, prescription: prescription))
        }

        // Pinned exercises that matched no slot are still the user's decision, so they are appended
        // rather than dropped.
        for lockedID in lockedExtras {
            guard let exercise = byID[lockedID], !sessionSelected.contains(lockedID) else { continue }
            let slot = ExerciseSlot(
                group: exercise.primaryGroup,
                mechanic: exercise.metadata.mechanic,
                preferredPattern: exercise.metadata.movementPattern,
                sets: 3,
                isPrimary: false
            )
            sessionSelected.insert(exercise.id)
            context.weekSelected.insert(exercise.id)
            filled.append(FilledSlot(
                slot: slot, exercise: exercise,
                prescription: prescribe(exercise: exercise, slot: slot, request: request,
                                        orderIndex: filled.count, isLocked: true)
            ))
        }

        // A session with nothing in it — or with nothing but a conditioning block — is a bug the
        // user experiences as a broken app.
        let hasStrengthWork = filled.contains { $0.slot.group != .cardio }
        if !hasStrengthWork, let rescue = rescueExercise(for: blueprint, request: request),
           !sessionSelected.contains(rescue.id) {
            let slot = ExerciseSlot(
                group: rescue.primaryGroup,
                mechanic: rescue.metadata.mechanic,
                preferredPattern: rescue.metadata.movementPattern,
                sets: 3,
                isPrimary: rescue.metadata.mechanic == .compound
            )
            context.usedBodyweightFallback = true
            // Inserted rather than appended: the lifting comes before the conditioning.
            filled.insert(FilledSlot(
                slot: slot, exercise: rescue,
                prescription: prescribe(exercise: rescue, slot: slot, request: request,
                                        orderIndex: 0, isLocked: false)
            ), at: 0)
        }

        fitToTime(&filled, blueprint: blueprint, request: request, context: &context)

        var exercises: [GeneratedExercise] = []
        for (index, entry) in filled.enumerated() {
            var prescription = entry.prescription
            prescription.orderIndex = index
            exercises.append(prescription)
        }

        var focus: [MuscleGroup] = []
        var seen = Set<MuscleGroup>()
        for entry in filled where entry.slot.group != .cardio {
            if seen.insert(entry.slot.group).inserted { focus.append(entry.slot.group) }
        }
        if focus.isEmpty { focus = blueprint.focusGroups }

        return GeneratedSession(
            id: sessionID,
            orderIndex: orderIndex,
            titleKey: blueprint.titleKey,
            customTitle: nil,
            weekday: weekday,
            focusGroups: focus,
            pushPull: blueprint.pushPull,
            estimatedMinutes: Int((Double(estimatedSeconds(
                for: filled, capSeconds: Self.capSeconds(for: request.profile)
            )) / 60).rounded()),
            isRestDay: false,
            exercises: exercises
        )
    }

    // MARK: - Filling a slot

    /// Finds an exercise for one slot, relaxing the requirements one step at a time.
    ///
    /// The order of the relaxations is the order in which each constraint matters least. The
    /// preferred *pattern* is a stylistic preference and goes first. The mechanic goes next. Only
    /// then does the engine allow a movement already programmed elsewhere this week, and only after
    /// that does it look at a neighbouring muscle group. The last two steps bypass the recommender
    /// entirely and scan the catalogue, which is what makes a bodyweight-only user with a shoulder
    /// limitation still get a session rather than an empty screen.
    private func choose(
        slot: ExerciseSlot,
        lateInSession: Bool,
        request: ProgrammingRequest,
        sessionSelected: Set<String>,
        sessionPatterns: Set<MovementPattern>,
        context: inout FillContext,
        rng: inout SeededGenerator
    ) -> Exercise? {
        func selection(
            group: MuscleGroup,
            pattern: MovementPattern?,
            mechanic: Mechanic?,
            avoidWeekRepeats: Bool
        ) -> ExerciseSelectionRequest {
            ExerciseSelectionRequest(
                targetGroup: group,
                preferredPattern: pattern,
                preferredMechanic: mechanic,
                profile: request.profile,
                preferences: request.preferences,
                histories: request.histories,
                alreadySelected: avoidWeekRepeats
                    ? sessionSelected.union(context.weekSelected)
                    : sessionSelected,
                recentlyUsedIDs: context.recentlyUsed,
                patternsUsed: avoidWeekRepeats
                    ? sessionPatterns.union(context.weekPatterns)
                    : sessionPatterns,
                favorLowFatigue: lateInSession,
                requiresLoadableMovement: slot.isPrimary
            )
        }

        let ladder: [ExerciseSelectionRequest] = [
            selection(group: slot.group, pattern: slot.preferredPattern,
                      mechanic: slot.mechanic, avoidWeekRepeats: true),
            selection(group: slot.group, pattern: nil,
                      mechanic: slot.mechanic, avoidWeekRepeats: true),
            selection(group: slot.group, pattern: nil, mechanic: nil, avoidWeekRepeats: true),
            selection(group: slot.group, pattern: nil, mechanic: nil, avoidWeekRepeats: false)
        ]
        for attempt in ladder {
            let ranked = recommender.rank(attempt, weights: .default, limit: 8)
            if let picked = pick(ranked, excluding: sessionSelected, rng: &rng) { return picked }
        }

        for neighbour in relatedGroups(for: slot.group) {
            let attempt = selection(group: neighbour, pattern: nil, mechanic: nil,
                                    avoidWeekRepeats: false)
            let ranked = recommender.rank(attempt, weights: .default, limit: 8)
            if let picked = pick(ranked, excluding: sessionSelected, rng: &rng) {
                context.usedGroupFallback = true
                return picked
            }
        }

        // Straight catalogue scan: anything admissible that touches the group at all.
        if let scanned = scan(group: slot.group, request: request, excluding: sessionSelected,
                              bodyweightOnly: false) {
            context.usedGroupFallback = true
            return scanned
        }
        if let bodyweight = scan(group: slot.group, request: request, excluding: sessionSelected,
                                 bodyweightOnly: true) {
            context.usedBodyweightFallback = true
            return bodyweight
        }
        return nil
    }

    /// Picks from a ranked list, breaking near-ties with the seeded generator.
    ///
    /// Anything within 3 % of the best score is, for programming purposes, the same exercise; always
    /// taking the numerically highest one makes every user's program identical and every week's
    /// program identical to the last.
    private func pick(
        _ ranked: [ScoredExercise],
        excluding: Set<String>,
        rng: inout SeededGenerator
    ) -> Exercise? {
        let usable = ranked
            .filter { !$0.breakdown.isDisqualified && $0.score > 0 && !excluding.contains($0.exercise.id) }
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score > rhs.score }
                return lhs.exercise.id < rhs.exercise.id
            }
        guard let top = usable.first else { return nil }
        let threshold = top.score * 0.97
        let tied = Array(usable.prefix(4).filter { $0.score >= threshold })
        guard tied.count > 1 else { return top.exercise }
        return tied[rng.index(below: tied.count)].exercise
    }

    /// Muscle groups whose work substitutes acceptably when the catalogue cannot serve a slot.
    private func relatedGroups(for group: MuscleGroup) -> [MuscleGroup] {
        switch group {
        case .chest: [.shoulders, .triceps]
        case .back: [.traps, .biceps]
        case .shoulders: [.chest, .traps]
        case .traps: [.back, .shoulders]
        case .biceps: [.back, .forearms]
        case .triceps: [.chest, .shoulders]
        case .forearms: [.biceps]
        case .quads: [.glutes, .hamstrings]
        case .hamstrings: [.glutes, .quads]
        case .glutes: [.hamstrings, .quads]
        case .adductors: [.glutes, .quads]
        case .abductors: [.glutes]
        case .calves: [.quads]
        case .abs: [.obliques, .lowerBack]
        case .obliques: [.abs]
        case .lowerBack: [.glutes, .hamstrings]
        case .neck: [.traps]
        case .cardio: []
        }
    }

    /// Last-resort catalogue scan. Applies the same hard rules the recommender would, then takes the
    /// most canonical option so the fallback is still a recognisable exercise.
    private func scan(
        group: MuscleGroup,
        request: ProgrammingRequest,
        excluding: Set<String>,
        bodyweightOnly: Bool
    ) -> Exercise? {
        let candidates = catalog.filter { exercise in
            guard !excluding.contains(exercise.id) else { return false }
            guard exercise.metadata.volumeCredit(for: group) > 0 else { return false }
            if bodyweightOnly {
                guard exercise.equipment == .bodyWeight else { return false }
            } else {
                guard request.profile.availableEquipment.contains(exercise.equipment) else { return false }
            }
            return isAdmissible(exercise, request: request)
        }
        return candidates.max { lhs, rhs in
            let left = lhs.metadata.stapleScore + lhs.metadata.volumeCredit(for: group)
            let right = rhs.metadata.stapleScore + rhs.metadata.volumeCredit(for: group)
            if abs(left - right) > 1e-9 { return left < right }
            return lhs.id > rhs.id
        }
    }

    /// The hard rules: nothing the user excluded, told us never to recommend, or cannot physically
    /// do. These are gates, never scores — a blocked movement is never merely unlikely.
    private func isAdmissible(_ exercise: Exercise, request: ProgrammingRequest) -> Bool {
        if request.profile.excludedExerciseIDs.contains(exercise.id) { return false }
        if let preference = request.preferences[exercise.id] {
            if preference.isExcluded || preference.feedback == .neverRecommend { return false }
        }
        let pattern = exercise.metadata.movementPattern
        if request.profile.avoidedPatterns.contains(pattern) { return false }
        for limitation in request.profile.mobilityLimitations {
            if limitation.blockedPatterns.contains(pattern) { return false }
            if !limitation.blockedTags.isDisjoint(with: exercise.metadata.substitutionTags) { return false }
        }
        return true
    }

    /// Anything at all, for a session that would otherwise be empty.
    private func rescueExercise(for blueprint: SessionBlueprint, request: ProgrammingRequest) -> Exercise? {
        for group in blueprint.focusGroups {
            if let found = scan(group: group, request: request, excluding: [], bodyweightOnly: true) {
                return found
            }
        }
        for group in blueprint.focusGroups {
            if let found = scan(group: group, request: request, excluding: [], bodyweightOnly: false) {
                return found
            }
        }
        return catalog
            .filter { $0.equipment == .bodyWeight && !$0.metadata.isStretch }
            .max { $0.metadata.stapleScore < $1.metadata.stapleScore }
    }

    // MARK: - Prescription

    private func prescribe(
        exercise: Exercise,
        slot: ExerciseSlot,
        request: ProgrammingRequest,
        orderIndex: Int,
        isLocked: Bool
    ) -> GeneratedExercise {
        let metadata = exercise.metadata
        let goals = request.profile.goals
        let sets = max(1, min(Self.maximumSetsPerExercise, slot.sets))

        var duration: Int?
        if metadata.trackingMode.usesDuration {
            duration = slot.group == .cardio
                ? cardioSeconds(goals: goals)
                : min(120, max(20, metadata.estimatedSetSeconds))
        }

        return GeneratedExercise(
            exerciseID: exercise.id,
            orderIndex: orderIndex,
            sets: sets,
            repRange: repRange(for: exercise, slot: slot, goals: goals),
            restSeconds: restSeconds(for: exercise, slot: slot, goals: goals),
            targetRIR: targetRIR(for: exercise, slot: slot, request: request),
            targetDurationSeconds: duration,
            targetDistanceMeters: nil,
            isLocked: isLocked,
            rationale: rationale(for: exercise, slot: slot, request: request, isLocked: isLocked)
        )
    }

    /// Shift applied to the exercise's own recommended rep range, in reps.
    ///
    /// The metadata range already knows that a barbell squat belongs at 5–8 and a lateral raise at
    /// 10–15; the goal only bends it. Strength pulls the primary compound down towards heavy triples
    /// and fives while leaving accessories alone, because accessories exist to add tissue, not to
    /// be maxed. Endurance pushes everything up. The result is clamped at three reps: the engine
    /// never programmes singles or doubles automatically, since near-maximal work needs a coach's
    /// eye on technique and a spotter, not an algorithm.
    private func repShift(for goal: TrainingGoal, isPrimary: Bool) -> Double {
        switch goal {
        case .buildStrength: isPrimary ? -3 : -1
        case .buildMuscle, .recomposition, .targetMuscleGroup: 0
        case .loseFat: 1
        case .improveEndurance: isPrimary ? 6 : 5
        case .maintain: -1
        case .generalFitness: isPrimary ? -1 : 0
        }
    }

    private func repRange(for exercise: Exercise, slot: ExerciseSlot, goals: [TrainingGoal]) -> RepRange {
        let base = exercise.metadata.recommendedRepRange
        guard exercise.metadata.trackingMode.usesReps else { return base }
        let shift = VolumeAllocator.blended(goals) { repShift(for: $0, isPrimary: slot.isPrimary) }
        let lower = min(30, max(3, Int((Double(base.lower) + shift).rounded())))
        let upper = min(35, max(lower + 1, Int((Double(base.upper) + shift).rounded())))
        return RepRange(lower, upper)
    }

    /// Rest comes from the movement itself and is then bent by the goal: strength needs full
    /// phosphocreatine recovery between heavy sets, fat loss and endurance deliberately trade some
    /// of that recovery for density. The floor of 30 seconds keeps the app from prescribing rest
    /// that is not rest.
    private func restSeconds(for exercise: Exercise, slot: ExerciseSlot, goals: [TrainingGoal]) -> Int {
        let factor = VolumeAllocator.restFactor(for: goals)
        var seconds = Double(exercise.metadata.defaultRestSeconds) * factor
        if slot.isPrimary { seconds *= 1.10 }
        return min(300, max(30, Int(seconds.rounded())))
    }

    /// How many reps the user should leave in the tank.
    ///
    /// The baseline comes from `ExperienceLevel.defaultRIR`, which already keeps novices well away
    /// from failure. On top of that: heavy compounds get an extra rep of margin because a failed
    /// squat or overhead press is dangerous in a way a failed cable curl is not; small, low-fatigue
    /// isolations get one fewer because that is where taking a set close to failure is both safe and
    /// productive; a fatigued muscle group and a deload week each add a rep. Never below one — the
    /// engine does not prescribe training to failure.
    private func targetRIR(
        for exercise: Exercise,
        slot: ExerciseSlot,
        request: ProgrammingRequest
    ) -> Int {
        var rir = request.profile.experience.defaultRIR
        let metadata = exercise.metadata
        if slot.isPrimary && metadata.fatigueCost >= 0.70 { rir += 1 }
        if metadata.mechanic == .isolation && metadata.fatigueCost < 0.25 { rir -= 1 }
        if request.recovery.fatigue(for: slot.group) > 0.60 { rir += 1 }
        if request.isDeloadWeek { rir += 1 }
        if request.profile.primaryGoal == .buildStrength && slot.isPrimary { rir += 1 }
        return min(5, max(1, rir))
    }

    private func cardioSeconds(goals: [TrainingGoal]) -> Int {
        let minutes = VolumeAllocator.blended(goals) { goal -> Double in
            switch goal {
            case .loseFat, .improveEndurance: 15
            case .generalFitness, .recomposition: 12
            case .maintain, .buildMuscle, .targetMuscleGroup: 10
            case .buildStrength: 8
            }
        }
        return Int((minutes * 60).rounded())
    }

    private func rationale(
        for exercise: Exercise,
        slot: ExerciseSlot,
        request: ProgrammingRequest,
        isLocked: Bool
    ) -> Explanation {
        if isLocked { return Explanation("programming.rationale.locked") }
        if slot.group == .cardio { return Explanation("programming.rationale.cardio") }
        if slot.group != exercise.primaryGroup {
            return Explanation("programming.rationale.substituteGroup")
        }
        if slot.group.isCore { return Explanation("programming.rationale.core") }
        if VolumeAllocator.effectivePriorityGroups(request.profile).contains(slot.group),
           !slot.isPrimary {
            return Explanation("programming.rationale.priority")
        }
        if slot.isPrimary { return Explanation("programming.rationale.primary") }
        if exercise.metadata.mechanic == .compound {
            return Explanation("programming.rationale.secondaryCompound")
        }
        return Explanation("programming.rationale.accessory")
    }

    // MARK: - Fitting the clock

    private func setSeconds(for entry: FilledSlot) -> Int {
        if let duration = entry.prescription.targetDurationSeconds { return duration }
        return entry.exercise.metadata.estimatedSetSeconds
    }

    /// The general warm-up a session of this length can actually afford.
    ///
    /// Five fixed minutes is right for an hour and absurd for twenty, where it would be a quarter
    /// of the session before a single working set — and the trimmer would then delete real work to
    /// pay for it. Capping the warm-up at a fifth of the session leaves a short session as mostly
    /// training; anything from twenty-five minutes upwards is unaffected.
    private static func warmupSeconds(capSeconds: Int) -> Int {
        min(baseWarmupSeconds, max(minimumWarmupSeconds, capSeconds / 5))
    }

    /// The session-length ceiling this profile is planned against.
    ///
    /// Floored at fifteen minutes to match `VolumeAllocator.timeBudget` and
    /// `SplitSelector.capacityFit`: a user may say ten, but nothing in the engine plans a session
    /// shorter than a quarter of an hour, and all three places have to agree or the plan the
    /// allocator sized will not be the plan the trimmer accepts.
    private static func capSeconds(for profile: TrainingProfileSnapshot) -> Int {
        max(15, profile.sessionMinutesCap) * 60
    }

    /// Real elapsed seconds for a session, from the exercises actually in it.
    private func estimatedSeconds(for filled: [FilledSlot], capSeconds: Int) -> Int {
        guard !filled.isEmpty else { return 0 }
        var total = 0.0
        var rampUps = 0
        for entry in filled {
            if entry.slot.isPrimary { rampUps += 1 }
            let sets = entry.prescription.sets
            total += Double(Self.setupSecondsPerExercise)
            total += Double(sets * setSeconds(for: entry))
            total += Double(max(0, sets - 1) * entry.prescription.restSeconds)
        }
        total += Double(max(0, filled.count - 1) * Self.transitionSeconds)
        let rampUpSeconds = min(rampUps, Self.rampUpCompoundLimit) * Self.rampUpSecondsPerCompound
        total += Double(Self.warmupSeconds(capSeconds: capSeconds) + rampUpSeconds)
        return Int(total.rounded())
    }

    /// Trims a session that overruns and tops up one that finishes early.
    ///
    /// The order the trim removes work in is the order in which it costs the least: rest on
    /// isolations first (density rises, stimulus barely moves), then accessory sets, then sets from
    /// the main compounds, and only then whole accessory exercises. The primary compounds and the
    /// first three exercises are the last things to go, because they carry most of the session's
    /// stimulus.
    private func fitToTime(
        _ filled: inout [FilledSlot],
        blueprint: SessionBlueprint,
        request: ProgrammingRequest,
        context: inout FillContext
    ) {
        guard !filled.isEmpty else { return }
        let capSeconds = Self.capSeconds(for: request.profile)

        var iterations = 0
        while estimatedSeconds(for: filled, capSeconds: capSeconds) > capSeconds && iterations < 160 {
            iterations += 1
            // Conservative pass: everything here costs almost no stimulus.
            if shortenRest(&filled, floor: 60, includingPrimary: false) { continue }
            if removeSet(&filled, fromPrimary: false, floor: 2) { context.trimmedSets += 1; continue }
            if removeSet(&filled, fromPrimary: true, floor: 3) { context.trimmedSets += 1; continue }
            if dropExercise(&filled, keepingAtLeast: 3, allowPrimary: false) { continue }
            // Aggressive pass: a 30-minute session cannot hold a textbook prescription, and the
            // user's stated time wins. Rest on the main lifts is never cut below 90 seconds and no
            // exercise below two sets, so what survives is still training.
            if shortenRest(&filled, floor: 90, includingPrimary: true) { continue }
            if removeSet(&filled, fromPrimary: true, floor: 2) { context.trimmedSets += 1; continue }
            if dropExercise(&filled, keepingAtLeast: 2, allowPrimary: false) { continue }
            if dropExercise(&filled, keepingAtLeast: 2, allowPrimary: true) { continue }
            break
        }

        // A light day is meant to stay light. Topping an active-recovery session up to fill a
        // two-hour cap turns the one day that exists to dissipate fatigue into another hard one.
        guard !blueprint.titleKey.hasPrefix("session.title.activeRecovery") else { return }

        // Only top up when there is a comfortable five minutes spare, so the estimate's own error
        // does not push a session over the line.
        let plannedSets = blueprint.slots.reduce(0) { $0 + $1.sets }
        let extensionCeiling = plannedSets + Int(Double(plannedSets) * Self.extensionAllowance)
        iterations = 0
        while estimatedSeconds(for: filled, capSeconds: capSeconds) < capSeconds - 300 && iterations < 40 {
            iterations += 1
            let currentSets = filled.reduce(0) { $0 + $1.prescription.sets }
            guard currentSets < extensionCeiling else { break }
            guard addSet(&filled) else { break }
            context.addedSets += 1
        }
    }

    /// Shaves 15 seconds off the longest rest interval still above `floor`.
    private func shortenRest(
        _ filled: inout [FilledSlot],
        floor: Int,
        includingPrimary: Bool
    ) -> Bool {
        var bestIndex: Int?
        var bestRest = 0
        for (index, entry) in filled.enumerated() {
            if entry.slot.isPrimary && !includingPrimary { continue }
            guard entry.prescription.restSeconds > floor else { continue }
            if entry.prescription.restSeconds > bestRest {
                bestRest = entry.prescription.restSeconds
                bestIndex = index
            }
        }
        guard let bestIndex else { return false }
        filled[bestIndex].prescription.restSeconds = max(floor, bestRest - 15)
        return true
    }

    private func removeSet(_ filled: inout [FilledSlot], fromPrimary: Bool, floor: Int) -> Bool {
        var bestIndex: Int?
        var bestSets = 0
        for (index, entry) in filled.enumerated() {
            guard entry.slot.isPrimary == fromPrimary else { continue }
            guard entry.prescription.sets > floor else { continue }
            if entry.prescription.sets > bestSets {
                bestSets = entry.prescription.sets
                bestIndex = index
            }
        }
        guard let bestIndex else { return false }
        filled[bestIndex].prescription.sets -= 1
        return true
    }

    /// What removing one exercise costs the session, cheapest first.
    ///
    /// Conditioning goes before any lifting: it is the part of the session the user came for least,
    /// and a ten-minute block is worth two accessory movements in clock time. After that, a
    /// movement whose muscle group is still trained by something else left in the session costs
    /// only that group's second or third exercise; a group's *only* movement costs the group
    /// entirely.
    private func dropCost(_ entry: FilledSlot, groupCounts: [MuscleGroup: Int]) -> Int {
        if entry.slot.group == .cardio { return 0 }
        return (groupCounts[entry.slot.group] ?? 0) > 1 ? 1 : 2
    }

    /// Drops the cheapest eligible exercise, breaking ties towards the one furthest into the
    /// session — the one carrying the least of its stimulus.
    ///
    /// Position alone used to decide, which deleted the only curl in an upper day before it touched
    /// the third row: the arms sort last, so they were always first out, and a four-day upper/lower
    /// week could finish with three back movements and no direct biceps work at all — the push/pull
    /// drift the rest of the engine exists to prevent.
    private func dropExercise(
        _ filled: inout [FilledSlot],
        keepingAtLeast minimum: Int,
        allowPrimary: Bool
    ) -> Bool {
        guard filled.count > minimum else { return false }
        var groupCounts: [MuscleGroup: Int] = [:]
        for entry in filled { groupCounts[entry.slot.group, default: 0] += 1 }

        var victim: Int?
        var bestCost = Int.max
        for index in filled.indices.reversed() {
            guard allowPrimary || !filled[index].slot.isPrimary else { continue }
            let cost = dropCost(filled[index], groupCounts: groupCounts)
            if cost < bestCost {
                bestCost = cost
                victim = index
                if cost == 0 { break }
            }
        }
        guard let victim else { return false }
        filled.remove(at: victim)
        return true
    }

    /// Adds a set to whichever exercise gives the most stimulus for the time, preferring compounds
    /// and the movements the metadata rates highest.
    private func addSet(_ filled: inout [FilledSlot]) -> Bool {
        var bestIndex: Int?
        var bestValue = -Double.greatestFiniteMagnitude
        for (index, entry) in filled.enumerated() {
            guard entry.slot.group != .cardio else { continue }
            guard entry.prescription.sets < Self.maximumSetsPerExercise else { continue }
            let value = entry.exercise.metadata.stimulusScore
                - Double(entry.prescription.sets) * 0.05
            if value > bestValue {
                bestValue = value
                bestIndex = index
            }
        }
        guard let bestIndex else { return false }
        filled[bestIndex].prescription.sets += 1
        return true
    }

    // MARK: - Locked exercises

    private struct LockedPlacements {
        var slots: [Int: [Int: String]] = [:]
        var extras: [Int: [String]] = [:]
    }

    /// Decides which session and which slot each pinned exercise belongs to, across the whole week.
    private func lockedPlacements(
        blueprints: [SessionBlueprint],
        request: ProgrammingRequest
    ) -> LockedPlacements {
        var placements = LockedPlacements()
        var taken = Set<String>()

        for lockedID in request.lockedExerciseIDs.sorted() {
            guard let exercise = byID[lockedID] else { continue }
            var bestScore = 0
            var bestSession: Int?
            var bestSlot: Int?
            for (sessionIndex, blueprint) in blueprints.enumerated() {
                for (slotIndex, slot) in blueprint.slots.enumerated() {
                    let key = "\(sessionIndex).\(slotIndex)"
                    guard !taken.contains(key) else { continue }
                    let score = matchScore(exercise: exercise, slot: slot)
                    if score > bestScore {
                        bestScore = score
                        bestSession = sessionIndex
                        bestSlot = slotIndex
                    }
                }
            }
            if bestScore >= 2, let bestSession, let bestSlot {
                placements.slots[bestSession, default: [:]][bestSlot] = lockedID
                taken.insert("\(bestSession).\(bestSlot)")
            } else {
                let sessionIndex = blueprints.firstIndex {
                    $0.focusGroups.contains(exercise.primaryGroup)
                } ?? 0
                placements.extras[sessionIndex, default: []].append(lockedID)
            }
        }
        return placements
    }

    private func assignLocked(
        blueprint: SessionBlueprint,
        lockedIDs: Set<String>
    ) -> (slots: [Int: String], extras: [String]) {
        var slots: [Int: String] = [:]
        var extras: [String] = []
        var taken = Set<Int>()
        for lockedID in lockedIDs.sorted() {
            guard let exercise = byID[lockedID] else { continue }
            var bestScore = 0
            var bestSlot: Int?
            for (slotIndex, slot) in blueprint.slots.enumerated() where !taken.contains(slotIndex) {
                let score = matchScore(exercise: exercise, slot: slot)
                if score > bestScore {
                    bestScore = score
                    bestSlot = slotIndex
                }
            }
            if bestScore >= 2, let bestSlot {
                slots[bestSlot] = lockedID
                taken.insert(bestSlot)
            } else {
                extras.append(lockedID)
            }
        }
        return (slots, extras)
    }

    /// How well a pinned exercise fits a slot. The target group is worth most, then the pattern,
    /// then the mechanic — the same order the slot ladder relaxes in.
    private func matchScore(exercise: Exercise, slot: ExerciseSlot) -> Int {
        var score = 0
        if exercise.primaryGroup == slot.group {
            score += 4
        } else if exercise.metadata.volumeCredit(for: slot.group) > 0 {
            score += 2
        }
        if let pattern = slot.preferredPattern, exercise.metadata.movementPattern == pattern {
            score += 2
        }
        if let mechanic = slot.mechanic, exercise.metadata.mechanic == mechanic {
            score += 1
        }
        return score
    }

    // MARK: - Blueprint recovery

    /// Rebuilds a blueprint from a session that is no longer backed by one — a hand-edited session,
    /// or one generated before the split vocabulary changed.
    private func blueprint(from session: GeneratedSession) -> SessionBlueprint {
        var slots: [ExerciseSlot] = []
        for planned in session.exercises.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            guard let exercise = byID[planned.exerciseID] else { continue }
            slots.append(ExerciseSlot(
                group: exercise.primaryGroup,
                mechanic: exercise.metadata.mechanic,
                preferredPattern: exercise.metadata.movementPattern,
                sets: planned.sets,
                isPrimary: planned.orderIndex == 0 && exercise.metadata.mechanic == .compound
            ))
        }
        return SessionBlueprint(
            titleKey: session.titleKey,
            focusGroups: session.focusGroups,
            pushPull: session.pushPull,
            slots: slots
        )
    }

    // MARK: - Explanations

    /// How long a block runs before it is worth resetting fatigue.
    ///
    /// Novices accumulate fatigue slowly and progress session to session, so they get a longer
    /// block; advanced lifters run into their recoverable ceiling sooner and need the reset earlier.
    private func mesocycleLength(for experience: ExperienceLevel) -> Int {
        switch experience {
        case .never, .beginner: 6
        case .intermediate: 5
        case .advanced: 4
        }
    }

    private func explain(
        split: SelectedSplit,
        targets: VolumeTargets,
        request: ProgrammingRequest,
        sessions: [GeneratedSession],
        weeklyVolume: [MuscleGroup: Double],
        context: FillContext
    ) -> [Explanation] {
        let profile = request.profile
        var explanations: [Explanation] = [split.explanation]

        if sessions.contains(where: { $0.titleKey.hasPrefix("session.title.activeRecovery") }) {
            explanations.append(Explanation("split.reason.activeRecovery", [String(split.daysPerWeek)]))
        }

        let majors: [MuscleGroup] = [.chest, .back, .shoulders, .quads, .hamstrings, .glutes]
        let planned = majors.compactMap { weeklyVolume[$0] }
        if !planned.isEmpty {
            let mean = planned.reduce(0, +) / Double(planned.count)
            explanations.append(Explanation("programming.volume", [String(Int(mean.rounded()))]))
        }

        let budget = VolumeAllocator.timeBudget(for: profile)
        let targetSum = MuscleGroup.volumeTracked.reduce(0.0) { $0 + targets.target(for: $1) }
        if targetSum >= budget.creditCapacity - 0.5 {
            explanations.append(Explanation(
                "programming.volume.timeCapped",
                [String(profile.daysPerWeek), String(profile.sessionMinutesCap)]
            ))
        }
        if request.isDeloadWeek {
            explanations.append(Explanation("programming.volume.deload"))
        }
        if request.recovery.fatigue.values.contains(where: { $0 > 0.5 }) {
            explanations.append(Explanation("programming.volume.fatigue"))
        }
        if let age = profile.ageYears, age > 45 {
            explanations.append(Explanation("programming.volume.age"))
        }

        let priorities = VolumeAllocator.effectivePriorityGroups(profile)
        if !priorities.isEmpty {
            explanations.append(Explanation("programming.priority", [String(priorities.count)]))
        }

        if context.trimmedSets > 0 {
            explanations.append(Explanation(
                "programming.trimmed",
                [String(context.trimmedSets), String(profile.sessionMinutesCap)]
            ))
        }
        if context.addedSets > 0 {
            explanations.append(Explanation("programming.extended", [String(context.addedSets)]))
        }
        if context.usedGroupFallback {
            explanations.append(Explanation("programming.fallback.group"))
        }
        if context.usedBodyweightFallback {
            explanations.append(Explanation("programming.fallback.bodyweight"))
        }

        let cardioSessions = sessions.filter { session in
            session.exercises.contains { byID[$0.exerciseID]?.primaryGroup == .cardio }
        }.count
        if cardioSessions > 0 {
            let key = profile.cardioPreference == .separateSessions
                ? "programming.cardio.separate"
                : "programming.cardio.afterLifting"
            explanations.append(Explanation(key, [String(cardioSessions)]))
        }

        let push = [MuscleGroup.chest, .shoulders, .triceps].reduce(0.0) { $0 + (weeklyVolume[$1] ?? 0) }
        let pull = [MuscleGroup.back, .biceps, .traps, .forearms].reduce(0.0) { $0 + (weeklyVolume[$1] ?? 0) }
        let peak = max(push, pull)
        if peak > 0, abs(push - pull) / peak <= 0.20 {
            explanations.append(Explanation("programming.balance"))
        }

        return explanations
    }

    // MARK: - Deterministic identifiers

    /// A UUID drawn from the seeded generator.
    ///
    /// `GeneratedSession` defaults its id to `UUID()`, which would make two runs of the same request
    /// unequal and every snapshot test useless. Generating the id from the seed instead keeps the
    /// promise that identical inputs produce an identical program.
    private func deterministicUUID(_ rng: inout SeededGenerator) -> UUID {
        let high = rng.next()
        let low = rng.next()
        func byte(_ value: UInt64, _ shift: UInt64) -> UInt8 { UInt8((value >> shift) & 0xFF) }
        return UUID(uuid: (
            byte(high, 56), byte(high, 48), byte(high, 40), byte(high, 32),
            byte(high, 24), byte(high, 16), byte(high, 8), byte(high, 0),
            byte(low, 56), byte(low, 48), byte(low, 40), byte(low, 32),
            byte(low, 24), byte(low, 16), byte(low, 8), byte(low, 0)
        ))
    }
}
