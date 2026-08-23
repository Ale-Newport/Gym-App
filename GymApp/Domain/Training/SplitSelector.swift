import Foundation

// MARK: - Blueprint value types

/// One exercise-shaped hole in a session, before a concrete exercise has been chosen for it.
///
/// The split decides *what kind of work* goes where; `WorkoutProgrammingEngine` then asks
/// `ExerciseRecommendationEngine` to fill each hole. Keeping the two apart is what lets the app
/// re-roll a single exercise without disturbing the structure of the week.
struct ExerciseSlot: Hashable, Sendable {
    /// The muscle group the slot exists to train.
    var group: MuscleGroup
    /// `nil` means either a compound or an isolation will do.
    var mechanic: Mechanic?
    /// The pattern the session plan wants here, when it cares.
    var preferredPattern: MovementPattern?
    var sets: Int
    /// True for the heavy compound the session is built around: it is ordered first, gets the
    /// longest rest and is kept furthest from failure.
    var isPrimary: Bool
}

/// A single session's plan, independent of which exercises end up in it.
struct SessionBlueprint: Hashable, Sendable {
    var titleKey: String
    var focusGroups: [MuscleGroup]
    var pushPull: PushPullClass
    var slots: [ExerciseSlot]

    var totalSets: Int { slots.reduce(0) { $0 + $1.sets } }
}

/// The chosen weekly structure.
struct SelectedSplit: Hashable, Sendable {
    /// Localisation key naming the split, e.g. `"split.pushPullLegs"`.
    var key: String
    var daysPerWeek: Int
    var blueprints: [SessionBlueprint]
    /// Why this structure beat the alternatives.
    var explanation: Explanation
    /// How many times a week each muscle group is actually trained by these blueprints.
    var frequency: [MuscleGroup: Int]
}

// MARK: - Day archetypes

/// The kind of work one training day does.
///
/// Splits are not stored as templates: they are built by expanding a short cycle of these
/// archetypes across the week and scoring the result. Adding an archetype adds candidate splits at
/// every day count for free.
enum DayArchetype: String, CaseIterable, Hashable, Sendable {
    case fullBody
    case upper
    case lower
    case push
    case pull
    case legs
    /// Chest and back together — the classic "torso" day.
    case torso
    case shouldersArms
    case posteriorChain
    /// A day given over to the groups the user asked to prioritise.
    case specialisation
    /// Light conditioning and core, used to give a seventh day somewhere to go.
    case activeRecovery
}

// MARK: - Split selection

/// Chooses the weekly structure by scoring candidates, never by looking a split up by day count.
///
/// The scoring is the whole design. Every well-known split — full body, upper/lower, push/pull/legs,
/// PPL twice, upper/lower/full, torso/arms/legs, a specialisation day — is generated as a candidate
/// at every day count, and the winner is whichever fits the user's frequency needs, session length,
/// priorities, goal and experience best. The familiar answers (1 day → full body, 6 days → PPL
/// twice) fall out of that comparison rather than being written down, which means they can be
/// unit-tested as *predictions* of the scoring rather than as tautologies.
enum SplitSelector {

    // MARK: Scoring weights

    /// Weights sum to 1.0 so a candidate's score is directly readable as "how good a fit, 0…1".
    ///
    /// Frequency dominates because getting a muscle group trained the right number of times is the
    /// single decision a split exists to make. Session capacity is next: a structure that cannot fit
    /// its own volume into the user's hour is not a structure. Experience and priority bend the
    /// choice between two structurally sound options, and balance is a small guard rail rather than
    /// a driver.
    struct Weights: Hashable, Sendable {
        var frequency: Double = 0.30
        var capacity: Double = 0.20
        var experience: Double = 0.14
        var priority: Double = 0.12
        var goal: Double = 0.10
        var spacing: Double = 0.09
        var balance: Double = 0.05

        static let `default` = Weights()
    }

    /// Training a group more often than needed is a mild inefficiency; training it less often than
    /// needed leaves volume on the table it cannot make up. The penalties are asymmetric to match.
    private static let overshootPenaltyWeight: Double = 0.35

    // MARK: Entry points

    /// The best weekly structure for this user and these volume targets.
    static func selectSplit(profile: TrainingProfileSnapshot, targets: VolumeTargets) -> SelectedSplit {
        let ranked = rank(daysPerWeek: profile.daysPerWeek, profile: profile, targets: targets)
        if let best = ranked.first { return best.split }
        // Unreachable with the vocabulary below, but a training app must never fail to produce a
        // plan: a single full-body day is the safe floor.
        return fallbackSplit(profile: profile, targets: targets)
    }

    /// Every candidate structure for `daysPerWeek`, best first.
    ///
    /// Exposed for tests and for a future "choose your own split" screen. Volume targets are derived
    /// from the profile against a fully recovered week, because a candidate list should describe the
    /// user's normal training, not today's fatigue.
    static func candidates(daysPerWeek: Int, profile: TrainingProfileSnapshot) -> [SelectedSplit] {
        let targets = VolumeAllocator.targets(for: profile, recovery: .fresh, isDeloadWeek: false)
        let ranked = rank(daysPerWeek: daysPerWeek, profile: profile, targets: targets)
        guard !ranked.isEmpty else { return [fallbackSplit(profile: profile, targets: targets)] }
        return ranked.map(\.split)
    }

    // MARK: - Weekday assignment

    /// The weekdays `count` sessions land on, spaced as evenly as the user's availability allows.
    ///
    /// Shared with `WorkoutProgrammingEngine` so the split is scored against exactly the calendar it
    /// will later be scheduled on — otherwise the recovery-spacing term would be scoring a week that
    /// never happens.
    static func trainingWeekdays(profile: TrainingProfileSnapshot, count: Int) -> [Weekday] {
        guard count > 0 else { return [] }
        let declared = profile.availableWeekdays.isEmpty
            ? Weekday.orderedMondayFirst
            : Array(Set(profile.availableWeekdays)).sorted()

        if declared.count >= count {
            // Pick an evenly spaced subset of the days the user offered.
            var picked: [Weekday] = []
            for index in 0..<count {
                let position = Int(Double(index) * Double(declared.count) / Double(count))
                let candidate = declared[min(position, declared.count - 1)]
                if !picked.contains(candidate) { picked.append(candidate) }
            }
            var pool = declared.filter { !picked.contains($0) }
            while picked.count < count, !pool.isEmpty { picked.append(pool.removeFirst()) }
            return picked.sorted()
        }

        // The user asked for more sessions than days: top up from the rest of the week, always
        // taking the day that sits furthest from anything already used.
        var chosen = declared
        var remaining = Weekday.orderedMondayFirst.filter { !chosen.contains($0) }
        while chosen.count < count, !remaining.isEmpty {
            let best = remaining.max { minimumGap($0, from: chosen) < minimumGap($1, from: chosen) }
            guard let best else { break }
            chosen.append(best)
            remaining.removeAll { $0 == best }
        }
        return chosen.sorted()
    }

    private static func minimumGap(_ day: Weekday, from others: [Weekday]) -> Int {
        others.map { cyclicGap(day, $0) }.min() ?? 7
    }

    /// Distance between two weekdays measured around the week, so Sunday and Monday are one apart.
    private static func cyclicGap(_ lhs: Weekday, _ rhs: Weekday) -> Int {
        let diff = abs(lhs.orderIndex - rhs.orderIndex)
        return min(diff, 7 - diff)
    }

    // MARK: - Candidate generation

    private struct CycleTemplate {
        let key: String
        let reasonKey: String
        let days: [DayArchetype]
    }

    /// The vocabulary every candidate is built from. Each entry is a *cycle*, repeated across the
    /// week rather than a fixed weekly template, so one entry covers every day count.
    private static let cycleVocabulary: [CycleTemplate] = [
        CycleTemplate(key: "split.fullBody", reasonKey: "split.reason.fullBody",
                      days: [.fullBody]),
        CycleTemplate(key: "split.upperLower", reasonKey: "split.reason.upperLower",
                      days: [.upper, .lower]),
        CycleTemplate(key: "split.pushPullLegs", reasonKey: "split.reason.pushPullLegs",
                      days: [.push, .pull, .legs]),
        CycleTemplate(key: "split.upperLowerFull", reasonKey: "split.reason.upperLowerFull",
                      days: [.upper, .lower, .fullBody]),
        CycleTemplate(key: "split.torsoArmsLegs", reasonKey: "split.reason.torsoArmsLegs",
                      days: [.torso, .shouldersArms, .legs]),
        CycleTemplate(key: "split.fourWay", reasonKey: "split.reason.fourWay",
                      days: [.upper, .lower, .push, .pull]),
        CycleTemplate(key: "split.pplUpperLower", reasonKey: "split.reason.pplUpperLower",
                      days: [.push, .pull, .legs, .upper, .lower]),
        CycleTemplate(key: "split.posteriorEmphasis", reasonKey: "split.reason.posteriorEmphasis",
                      days: [.posteriorChain, .push, .legs, .pull])
    ]

    private struct Structure {
        let key: String
        let reasonKey: String
        let days: [DayArchetype]
    }

    /// Repeats a cycle until the week is full.
    private static func expand(_ cycle: [DayArchetype], to count: Int) -> [DayArchetype] {
        guard count > 0, !cycle.isEmpty else { return [] }
        return (0..<count).map { cycle[$0 % cycle.count] }
    }

    /// Repeats a cycle, but spends any leftover days on whichever archetype covers the most priority
    /// groups. With a chest priority and five days, `upper/lower` becomes U-L-U-L-**U** rather than
    /// running the cycle blindly.
    private static func expandBiased(
        _ cycle: [DayArchetype],
        to count: Int,
        priorities: [MuscleGroup]
    ) -> [DayArchetype] {
        guard count > 0, !cycle.isEmpty, !priorities.isEmpty else { return expand(cycle, to: count) }
        let whole = (count / cycle.count) * cycle.count
        var days = expand(cycle, to: whole)
        guard days.count < count else { return days }
        let prioritySet = Set(priorities)
        let favoured = cycle.max { lhs, rhs in
            let left = groups(for: lhs, priorities: priorities).filter(prioritySet.contains).count
            let right = groups(for: rhs, priorities: priorities).filter(prioritySet.contains).count
            return left < right
        } ?? cycle[0]
        while days.count < count { days.append(favoured) }
        return days
    }

    private static func structures(daysPerWeek: Int, profile: TrainingProfileSnapshot) -> [Structure] {
        let days = max(1, min(daysPerWeek, 7))
        let priorities = VolumeAllocator.effectivePriorityGroups(profile)
        var seen = Set<String>()
        var result: [Structure] = []

        func add(_ structure: Structure) {
            let identity = structure.key + "|" + structure.days.map(\.rawValue).joined(separator: ",")
            guard seen.insert(identity).inserted else { return }
            result.append(structure)
        }

        for cycle in cycleVocabulary {
            add(Structure(key: cycle.key, reasonKey: cycle.reasonKey,
                          days: expand(cycle.days, to: days)))
            add(Structure(key: cycle.key, reasonKey: cycle.reasonKey,
                          days: expandBiased(cycle.days, to: days, priorities: priorities)))
        }

        // A specialisation day: the base structure over one fewer day, plus a day of priority work.
        if days >= 2 {
            for cycle in cycleVocabulary {
                let base = expand(cycle.days, to: days - 1)
                add(Structure(key: "split.specialisation", reasonKey: "split.reason.specialisation",
                              days: base + [.specialisation]))
            }
        }

        // Six hard days is the practical ceiling; a seventh has to be a light one.
        if days >= 6 {
            for cycle in cycleVocabulary {
                let base = expand(cycle.days, to: days - 1)
                add(Structure(key: cycle.key, reasonKey: cycle.reasonKey,
                              days: base + [.activeRecovery]))
            }
        }

        return result
    }

    // MARK: - Archetype composition

    /// The muscle groups a day of this kind trains.
    static func groups(for archetype: DayArchetype, priorities: [MuscleGroup]) -> [MuscleGroup] {
        switch archetype {
        case .fullBody:
            [.quads, .back, .chest, .hamstrings, .glutes, .shoulders, .triceps, .biceps,
             .calves, .abs, .lowerBack]
        case .upper:
            [.back, .chest, .shoulders, .triceps, .biceps, .traps, .forearms]
        case .lower, .legs:
            [.quads, .hamstrings, .glutes, .calves, .adductors, .abductors, .abs, .obliques, .lowerBack]
        case .push:
            [.chest, .shoulders, .triceps]
        case .pull:
            [.back, .biceps, .traps, .forearms]
        case .torso:
            [.back, .chest, .abs, .obliques]
        case .shouldersArms:
            [.shoulders, .triceps, .biceps, .traps, .forearms]
        case .posteriorChain:
            [.back, .hamstrings, .glutes, .traps, .lowerBack]
        case .specialisation:
            specialisationGroups(priorities)
        case .activeRecovery:
            [.abs, .obliques]
        }
    }

    /// A specialisation day is the priority groups plus one complement each, so the day is still a
    /// session rather than four variations of the same curl.
    ///
    /// When the user declared no priorities at all the day defaults to shoulders and arms — by far
    /// the most commonly specialised groups, and the ones whose 44–52 hour recovery window
    /// tolerates a third weekly exposure. That default exists only so the candidate can still be
    /// scored; with no declared priority it earns no priority credit and loses to the balanced
    /// structures.
    private static func specialisationGroups(_ priorities: [MuscleGroup]) -> [MuscleGroup] {
        let seeds = priorities.isEmpty ? [.shoulders, .biceps, .triceps] : priorities
        var seen = Set<MuscleGroup>()
        var result: [MuscleGroup] = []
        for group in seeds where seen.insert(group).inserted { result.append(group) }
        for group in seeds {
            let partner = complement(of: group)
            if seen.insert(partner).inserted { result.append(partner) }
            if result.count >= 6 { break }
        }
        return result
    }

    /// The group most naturally trained alongside another — usually its antagonist or its synergist.
    private static func complement(of group: MuscleGroup) -> MuscleGroup {
        switch group {
        case .chest: .triceps
        case .back: .biceps
        case .shoulders: .traps
        case .biceps: .forearms
        case .triceps: .shoulders
        case .traps: .back
        case .forearms: .biceps
        case .quads: .calves
        case .hamstrings: .glutes
        case .glutes: .hamstrings
        case .calves: .quads
        case .adductors, .abductors: .glutes
        case .abs: .obliques
        case .obliques: .abs
        case .lowerBack: .glutes
        case .neck: .traps
        case .cardio: .abs
        }
    }

    static func pushPull(for archetype: DayArchetype) -> PushPullClass {
        switch archetype {
        case .push: .push
        case .pull, .posteriorChain: .pull
        case .lower, .legs: .legs
        case .activeRecovery: .cardio
        case .fullBody, .upper, .torso, .shouldersArms, .specialisation: .neutral
        }
    }

    private static func titleBaseKey(for archetype: DayArchetype) -> String {
        "session.title." + archetype.rawValue
    }

    private static let variantLetters = ["a", "b", "c", "d", "e", "f"]

    /// How many lettered variants of a title exist. Only archetypes that can actually repeat inside
    /// the cycle vocabulary need them.
    private static func variantCount(for archetype: DayArchetype) -> Int {
        switch archetype {
        case .fullBody: 6
        case .upper, .lower: 4
        case .push, .pull, .legs: 3
        case .torso, .shouldersArms, .posteriorChain, .specialisation, .activeRecovery: 2
        }
    }

    private static func titleKey(for archetype: DayArchetype, occurrence: Int, total: Int) -> String {
        let base = titleBaseKey(for: archetype)
        guard total > 1, occurrence < variantCount(for: archetype), occurrence < variantLetters.count
        else { return base }
        return base + "." + variantLetters[occurrence]
    }

    // MARK: - Slot vocabulary

    /// The ordered movement slots a group is normally trained with.
    ///
    /// A `nil` mechanic means "either" — used where the natural third movement for a group is not
    /// reliably a compound or an isolation (a pullover, a walking lunge, an ab-wheel rollout). Being
    /// explicit here matters: asking the recommender for an *isolation* with a `horizontalPull`
    /// pattern would disqualify the entire catalogue, because the metadata deriver classifies every
    /// row as a compound.
    static func slotVocabulary(for group: MuscleGroup) -> [(pattern: MovementPattern, mechanic: Mechanic?)] {
        switch group {
        case .chest:
            [(.horizontalPush, .compound), (.chestFly, .isolation), (.horizontalPush, nil)]
        case .back:
            [(.verticalPull, .compound), (.horizontalPull, .compound), (.horizontalPull, nil)]
        case .shoulders:
            [(.verticalPush, .compound), (.shoulderRaise, .isolation), (.shoulderRaise, nil)]
        case .traps:
            [(.shrug, .isolation)]
        case .biceps:
            [(.elbowFlexion, .isolation), (.elbowFlexion, nil)]
        case .triceps:
            [(.elbowExtension, .isolation), (.elbowExtension, nil)]
        case .forearms:
            [(.wristFlexion, .isolation), (.wristExtension, .isolation)]
        case .quads:
            [(.squat, .compound), (.kneeExtension, .isolation), (.lunge, nil)]
        case .hamstrings:
            [(.hinge, .compound), (.kneeFlexion, .isolation)]
        case .glutes:
            [(.hipThrust, nil), (.hinge, .compound), (.lunge, nil)]
        case .adductors:
            [(.hipAdduction, .isolation)]
        case .abductors:
            [(.hipAbduction, .isolation)]
        case .calves:
            [(.calfRaise, .isolation), (.calfRaise, nil)]
        case .abs:
            [(.coreAntiExtension, nil), (.coreFlexion, nil)]
        case .obliques:
            [(.coreRotation, nil), (.coreLateralFlexion, nil)]
        case .lowerBack:
            [(.hinge, nil)]
        case .neck:
            [(.neckMovement, .isolation)]
        case .cardio:
            [(.cardio, nil)]
        }
    }

    /// Rough ordering by muscle size, used to put the biggest movement first in a session.
    private static func sizeRank(_ group: MuscleGroup) -> Int {
        switch group {
        case .quads: 0
        case .back: 1
        case .chest: 2
        case .glutes: 3
        case .hamstrings: 4
        case .shoulders: 5
        case .traps: 6
        case .triceps: 7
        case .biceps: 8
        case .calves: 9
        case .adductors: 10
        case .abductors: 11
        case .forearms: 12
        case .abs: 13
        case .obliques: 14
        case .lowerBack: 15
        case .neck: 16
        case .cardio: 17
        }
    }

    /// Which part of the session a slot belongs in.
    ///
    /// Heavy compounds first while the user is fresh and their technique is best, then the
    /// remaining multi-joint work, then isolation, then core, then conditioning. Core sits after
    /// isolation deliberately: a pre-fatigued trunk makes every subsequent loaded lift worse.
    private static func orderBucket(_ slot: ExerciseSlot) -> Int {
        if slot.group == .cardio { return 4 }
        if slot.group.isCore { return 3 }
        if slot.isPrimary { return 0 }
        if slot.mechanic == .isolation { return 2 }
        return 1
    }

    // MARK: - Scoring

    private struct ScoredSplit {
        let split: SelectedSplit
        let score: Double
    }

    private struct DayPlan {
        let archetype: DayArchetype
        let weekday: Weekday
        let credits: [MuscleGroup: Double]
    }

    private static func rank(
        daysPerWeek: Int,
        profile: TrainingProfileSnapshot,
        targets: VolumeTargets
    ) -> [ScoredSplit] {
        let days = max(1, min(daysPerWeek, 7))
        let priorities = VolumeAllocator.effectivePriorityGroups(profile)
        let weekdays = trainingWeekdays(profile: profile, count: days)
        guard weekdays.count == days else { return [] }

        var scored: [ScoredSplit] = []
        for structure in structures(daysPerWeek: days, profile: profile) {
            let dayGroups = structure.days.map { archetype in
                groups(for: archetype, priorities: priorities)
                    .filter { targets.target(for: $0) > 0.5 }
            }
            var coverage: [MuscleGroup: Int] = [:]
            for groupsOnDay in dayGroups {
                for group in groupsOnDay { coverage[group, default: 0] += 1 }
            }

            let plans = dayPlans(
                structure: structure, dayGroups: dayGroups,
                weekdays: weekdays, coverage: coverage, targets: targets
            )
            let score = score(
                structure: structure, plans: plans, coverage: coverage,
                profile: profile, targets: targets, priorities: priorities
            )
            let blueprints = buildBlueprints(
                structure: structure, plans: plans, profile: profile,
                targets: targets, priorities: priorities
            )
            // Report the frequency the blueprints actually deliver, not the archetype's coverage:
            // thin groups get concentrated onto a single day, and a plan that claims twice a week
            // while programming once is a plan the user cannot trust.
            var achieved: [MuscleGroup: Int] = [:]
            for blueprint in blueprints {
                for group in Set(blueprint.slots.map(\.group)) { achieved[group, default: 0] += 1 }
            }
            let split = SelectedSplit(
                key: structure.key,
                daysPerWeek: days,
                blueprints: blueprints,
                explanation: Explanation(structure.reasonKey, [String(days)]),
                frequency: achieved
            )
            scored.append(ScoredSplit(split: split, score: score))
        }

        // Deterministic ordering: score first, then the split key, then the structure itself, so two
        // identically scoring candidates always resolve the same way.
        return scored.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score > rhs.score }
            if lhs.split.key != rhs.split.key { return lhs.split.key < rhs.split.key }
            return lhs.split.blueprints.map(\.titleKey).joined()
                < rhs.split.blueprints.map(\.titleKey).joined()
        }
    }

    /// Credits each day carries, after damping anything that lands the day after the same group was
    /// already trained.
    ///
    /// Back-to-back exposure of a group is not forbidden — some structures need it — but the second
    /// day runs at 75 % because the muscle has had roughly a day, not the two to three its
    /// `baselineRecoveryHours` asks for.
    private static func dayPlans(
        structure: Structure,
        dayGroups: [[MuscleGroup]],
        weekdays: [Weekday],
        coverage: [MuscleGroup: Int],
        targets: VolumeTargets
    ) -> [DayPlan] {
        var plans: [DayPlan] = []
        for (index, archetype) in structure.days.enumerated() {
            var credits: [MuscleGroup: Double] = [:]
            for group in dayGroups[index] {
                let exposures = max(1, coverage[group] ?? 1)
                var value = targets.target(for: group) / Double(exposures)
                let backToBack = (0..<index).contains { earlier in
                    cyclicGap(weekdays[index], weekdays[earlier]) == 1
                        && dayGroups[earlier].contains(group)
                }
                if backToBack { value *= 0.75 }
                credits[group] = value
            }
            plans.append(DayPlan(archetype: archetype, weekday: weekdays[index], credits: credits))
        }
        return plans
    }

    private static func score(
        structure: Structure,
        plans: [DayPlan],
        coverage: [MuscleGroup: Int],
        profile: TrainingProfileSnapshot,
        targets: VolumeTargets,
        priorities: [MuscleGroup]
    ) -> Double {
        let weights = Weights.default
        let frequency = frequencyFit(coverage: coverage, targets: targets)
        let capacity = capacityFit(plans: plans, profile: profile)
        let experience = experienceFit(structure: structure, experience: profile.experience)
        let priority = priorityFit(structure: structure, coverage: coverage,
                                   targets: targets, priorities: priorities)
        let goal = goalFit(plans: plans, targets: targets, goals: profile.goals)
        let spacing = spacingFit(structure: structure, plans: plans)
        let balance = balanceFit(coverage: coverage, targets: targets)

        return frequency * weights.frequency
            + capacity * weights.capacity
            + experience * weights.experience
            + priority * weights.priority
            + goal * weights.goal
            + spacing * weights.spacing
            + balance * weights.balance
    }

    /// How closely the structure hits each group's required weekly frequency, weighted by how much
    /// volume that group carries — missing the chest matters more than missing the adductors.
    private static func frequencyFit(coverage: [MuscleGroup: Int], targets: VolumeTargets) -> Double {
        var weightedPenalty = 0.0
        var weightSum = 0.0
        for group in MuscleGroup.volumeTracked {
            let target = targets.target(for: group)
            guard target > 0.5 else { continue }
            let desired = max(1, targets.frequency(for: group))
            let achieved = coverage[group] ?? 0
            let penalty: Double
            if achieved == 0 {
                penalty = 1.0
            } else if achieved < desired {
                penalty = Double(desired - achieved) / Double(desired)
            } else {
                penalty = Double(achieved - desired) / Double(desired) * overshootPenaltyWeight
            }
            weightedPenalty += min(1, penalty) * target
            weightSum += target
        }
        guard weightSum > 0 else { return 0 }
        return max(0, 1 - weightedPenalty / weightSum)
    }

    /// Whether each day's share of the week's volume actually fits the session length.
    ///
    /// The weekly total already fits — `VolumeAllocator` guaranteed that — so this term catches
    /// *uneven* structures: a single legs day carrying every lower-body set overflows even though
    /// the week as a whole does not. Sessions that finish far too early are penalised too, but at
    /// less than half the weight, because wasting time is a smaller failure than not finishing.
    private static func capacityFit(plans: [DayPlan], profile: TrainingProfileSnapshot) -> Double {
        guard !plans.isEmpty else { return 0 }
        let capSeconds = Double(max(15, profile.sessionMinutesCap) * 60)
        let overheadSeconds = Double(VolumeAllocator.sessionOverheadMinutes * 60)
        let secondsPerSet = VolumeAllocator.averageSetSecondsIncludingRest
            * VolumeAllocator.restFactor(for: profile.goals)

        var overflow = 0.0
        var underflow = 0.0
        for plan in plans {
            let credits = plan.credits.values.reduce(0, +)
            let sets = credits / VolumeAllocator.averageVolumeCreditPerSet
            let seconds = overheadSeconds + sets * secondsPerSet
            overflow += max(0, seconds - capSeconds) / capSeconds
            // A light day is the point of a light day.
            if plan.archetype != .activeRecovery {
                underflow += max(0, capSeconds * 0.55 - seconds) / capSeconds
            }
        }
        let days = Double(plans.count)
        return max(0, 1 - min(1, overflow / days + 0.4 * (underflow / days)))
    }

    /// How many distinct session types the user's training age warrants.
    ///
    /// Novices do best with one session they repeat: the practice is the point, and a four-way split
    /// asks them to learn four sessions before they can perform any of them well. Advanced lifters
    /// need the room a split gives them to fit the volume. The band is one-sided — being simpler
    /// than the band costs less than being more complicated than it.
    private static func experienceBand(_ experience: ExperienceLevel) -> (lower: Double, upper: Double) {
        switch experience {
        case .never, .beginner: (1, 1)
        case .intermediate: (2, 5)
        case .advanced: (2, 6)
        }
    }

    private static func experienceFit(structure: Structure, experience: ExperienceLevel) -> Double {
        let distinct = Double(Set(structure.days).count)
        let band = experienceBand(experience)
        var penalty = 0.0
        if distinct > band.upper { penalty += min(1, (distinct - band.upper) / 2.0) }
        if distinct < band.lower { penalty += min(1, (band.lower - distinct) / 2.0) * 0.6 }
        return max(0, 1 - penalty)
    }

    private static func priorityFit(
        structure: Structure,
        coverage: [MuscleGroup: Int],
        targets: VolumeTargets,
        priorities: [MuscleGroup]
    ) -> Double {
        let hasSpecialisationDay = structure.days.contains(.specialisation)
        guard !priorities.isEmpty else {
            // Nothing to specialise in: a specialisation day is dead weight.
            return hasSpecialisationDay ? 0.30 : 1.0
        }
        var total = 0.0
        for group in priorities {
            let desired = max(1, targets.frequency(for: group))
            let achieved = Double(coverage[group] ?? 0)
            total += min(1.0, achieved / Double(desired))
        }
        var value = total / Double(priorities.count)
        if hasSpecialisationDay { value = min(1.0, value + 0.15) }
        return value
    }

    /// How many muscle groups a session should cover for this goal.
    ///
    /// This is the one axis the other terms do not already measure. Strength and hypertrophy want a
    /// narrow session: four or five groups leaves room for two heavy compounds, long rest and enough
    /// sets per movement to drive an adaptation. Fat loss and endurance want the opposite — broad,
    /// dense, near-whole-body sessions with short rest, which burn more energy per minute and are
    /// easier to recover from in a deficit. Deliberately *not* a measure of volume concentration:
    /// that is what the frequency term is for, and scoring it twice would let it overrule the
    /// evidence-based frequency the allocator derived.
    private static func idealGroupsPerSession(for goal: TrainingGoal) -> Double {
        switch goal {
        case .buildStrength, .buildMuscle, .targetMuscleGroup: 5
        case .recomposition: 6
        case .maintain: 7
        case .loseFat, .generalFitness: 8
        case .improveEndurance: 9
        }
    }

    private static func goalFit(
        plans: [DayPlan],
        targets: VolumeTargets,
        goals: [TrainingGoal]
    ) -> Double {
        // A light day is not meant to look like a training day, so it does not vote.
        let training = plans.filter { $0.archetype != .activeRecovery }
        guard !training.isEmpty else { return 0.5 }
        let mean = training.reduce(0.0) { $0 + Double($1.credits.count) } / Double(training.count)

        // With few days there is a hard floor on how narrow a session can be: every group still has
        // to be trained its required number of times and those exposures have to fit somewhere. A
        // three-day week cannot run five-group sessions no matter what the goal prefers, so the
        // ideal is raised to whatever the calendar makes unavoidable before it is compared.
        var requiredExposures = 0.0
        for group in MuscleGroup.volumeTracked where targets.target(for: group) > 0.5 {
            requiredExposures += Double(max(1, targets.frequency(for: group)))
        }
        let unavoidable = requiredExposures / Double(training.count)
        let ideal = max(unavoidable, VolumeAllocator.blended(goals, idealGroupsPerSession(for:)))
        return max(0, 1 - min(1, abs(mean - ideal) / 5.0))
    }

    /// Penalises training the same groups on consecutive calendar days, and penalises stringing more
    /// than four hard days together at all.
    private static func spacingFit(structure: Structure, plans: [DayPlan]) -> Double {
        guard plans.count > 1 else { return 1 }
        var overlapPenalty = 0.0
        for i in plans.indices {
            for j in plans.indices where j > i {
                guard cyclicGap(plans[i].weekday, plans[j].weekday) == 1 else { continue }
                overlapPenalty += overlap(plans[i].credits, plans[j].credits)
            }
        }
        overlapPenalty /= Double(plans.count)

        let hardDays = plans.filter { $0.archetype != .activeRecovery }.map(\.weekday)
        let streakPenalty = Double(max(0, longestConsecutiveRun(hardDays) - 4)) * 0.20
        return max(0, 1 - min(1, overlapPenalty + streakPenalty))
    }

    /// Shared volume between two days, as a fraction of the busier day.
    private static func overlap(_ lhs: [MuscleGroup: Double], _ rhs: [MuscleGroup: Double]) -> Double {
        let leftTotal = lhs.values.reduce(0, +)
        let rightTotal = rhs.values.reduce(0, +)
        let peak = max(leftTotal, rightTotal)
        guard peak > 0 else { return 0 }
        var shared = 0.0
        for (group, value) in lhs {
            shared += min(value, rhs[group] ?? 0)
        }
        return shared / peak
    }

    private static func longestConsecutiveRun(_ days: [Weekday]) -> Int {
        let indices = Set(days.map(\.orderIndex))
        guard !indices.isEmpty else { return 0 }
        if indices.count == 7 { return 7 }
        var best = 0
        for start in indices.sorted() {
            guard !indices.contains((start + 6) % 7) else { continue }
            var length = 0
            var cursor = start
            while indices.contains(cursor) {
                length += 1
                cursor = (cursor + 1) % 7
            }
            best = max(best, length)
        }
        return best
    }

    /// Keeps pushing and pulling exposure within about a fifth of each other across the week.
    ///
    /// Measured as volume-weighted mean *exposures*, not as weekly credits: the credits are the
    /// allocator's decision and are the same whichever structure is chosen, so comparing them would
    /// score every candidate identically. Exposure is what a split actually controls, and it is what
    /// goes wrong — a structure that presses three times a week and rows once builds the shoulder
    /// imbalance this term exists to prevent. Anything inside 20 % scores full marks; a 50 %
    /// imbalance scores nothing.
    private static func balanceFit(coverage: [MuscleGroup: Int], targets: VolumeTargets) -> Double {
        func meanExposure(_ groups: [MuscleGroup]) -> Double {
            var weighted = 0.0
            var weightSum = 0.0
            for group in groups {
                let target = targets.target(for: group)
                guard target > 0.5 else { continue }
                weighted += Double(coverage[group] ?? 0) * target
                weightSum += target
            }
            return weightSum > 0 ? weighted / weightSum : 0
        }
        let push = meanExposure([.chest, .shoulders, .triceps])
        let pull = meanExposure([.back, .biceps, .traps, .forearms])
        let peak = max(push, pull)
        guard peak > 0 else { return 0.5 }
        let ratio = abs(push - pull) / peak
        return max(0, 1 - min(1, max(0, ratio - 0.20) / 0.30))
    }

    // MARK: - Blueprint construction

    private static func buildBlueprints(
        structure: Structure,
        plans: [DayPlan],
        profile: TrainingProfileSnapshot,
        targets: VolumeTargets,
        priorities: [MuscleGroup]
    ) -> [SessionBlueprint] {
        let prioritySet = Set(priorities)
        var occurrences: [DayArchetype: Int] = [:]
        var totals: [DayArchetype: Int] = [:]
        for archetype in structure.days { totals[archetype, default: 0] += 1 }

        let cardioDays = cardioDayIndices(plans: plans, profile: profile)
        let concentrated = concentratedDays(plans: plans)

        var blueprints: [SessionBlueprint] = []
        for (index, plan) in plans.enumerated() {
            var slots: [ExerciseSlot] = []
            // Iterate a stable group order so the same plan always produces the same slots.
            for group in MuscleGroup.volumeTracked where plan.credits[group] != nil {
                var credits = plan.credits[group] ?? 0
                if let day = concentrated[group] {
                    guard day == index else { continue }
                    credits = plans.reduce(0.0) { $0 + ($1.credits[group] ?? 0) }
                }
                slots.append(contentsOf: makeSlots(
                    for: group,
                    credits: credits,
                    isPriority: prioritySet.contains(group)
                ))
            }

            if plan.archetype == .activeRecovery && slots.isEmpty {
                // A light day still needs something in it.
                slots.append(contentsOf: makeSlots(for: .abs, credits: 3, isPriority: false))
            }

            if cardioDays.contains(index) {
                slots.append(ExerciseSlot(group: .cardio, mechanic: nil,
                                          preferredPattern: .cardio, sets: 1, isPrimary: false))
            }

            slots.sort { lhs, rhs in
                let leftBucket = orderBucket(lhs)
                let rightBucket = orderBucket(rhs)
                if leftBucket != rightBucket { return leftBucket < rightBucket }
                let leftPriority = prioritySet.contains(lhs.group)
                let rightPriority = prioritySet.contains(rhs.group)
                if leftPriority != rightPriority { return leftPriority }
                if lhs.group != rhs.group { return sizeRank(lhs.group) < sizeRank(rhs.group) }
                if lhs.sets != rhs.sets { return lhs.sets > rhs.sets }
                return (lhs.preferredPattern?.rawValue ?? "") < (rhs.preferredPattern?.rawValue ?? "")
            }

            var focus: [MuscleGroup] = []
            var seen = Set<MuscleGroup>()
            for slot in slots where slot.group != .cardio {
                if seen.insert(slot.group).inserted { focus.append(slot.group) }
            }

            let occurrence = occurrences[plan.archetype, default: 0]
            occurrences[plan.archetype] = occurrence + 1
            blueprints.append(SessionBlueprint(
                titleKey: titleKey(for: plan.archetype, occurrence: occurrence,
                                   total: totals[plan.archetype] ?? 1),
                focusGroups: focus,
                pushPull: pushPull(for: plan.archetype),
                slots: slots
            ))
        }
        return blueprints
    }

    /// Groups whose per-exposure direct requirement rounds below two sets, but whose *weekly*
    /// requirement does not.
    ///
    /// Spreading two weekly sets of shrugs across three exposures produces nothing at all — each day
    /// rounds to zero and the group silently vanishes from the program. Concentrating them on the
    /// lightest day that already covers the group turns the same volume into one real exercise. The
    /// lightest day is chosen so the extra movement lands where there is time for it.
    private static func concentratedDays(plans: [DayPlan]) -> [MuscleGroup: Int] {
        var result: [MuscleGroup: Int] = [:]
        for group in MuscleGroup.volumeTracked {
            let days = plans.indices.filter { plans[$0].credits[group] != nil }
            guard days.count > 1 else { continue }
            let retained = 1 - VolumeAllocator.indirectShare(group)
            let perDay = (plans[days[0]].credits[group] ?? 0) * retained
            guard Int(perDay.rounded()) < 2 else { continue }
            let weekly = days.reduce(0.0) { $0 + (plans[$1].credits[group] ?? 0) } * retained
            guard Int(weekly.rounded()) >= 2 else { continue }
            let chosen = days.min { lhs, rhs in
                let left = plans[lhs].credits.values.reduce(0, +)
                let right = plans[rhs].credits.values.reduce(0, +)
                if abs(left - right) > 1e-9 { return left < right }
                return lhs < rhs
            }
            if let chosen { result[group] = chosen }
        }
        return result
    }

    /// Turns a group's share of a day's credits into concrete slots.
    ///
    /// The credit target is converted to *directly targeted* sets first, because most of a group's
    /// weekly credit arrives as synergist work inside other exercises — see
    /// `VolumeAllocator.indirectShare`. Groups whose direct requirement rounds below two sets get no
    /// slot at all unless the user prioritised them: one weekly set of wrist curls is clutter, not
    /// training, and the forearms are already saturated by every row in the plan.
    private static func makeSlots(
        for group: MuscleGroup,
        credits: Double,
        isPriority: Bool
    ) -> [ExerciseSlot] {
        let vocabulary = slotVocabulary(for: group)
        guard !vocabulary.isEmpty else { return [] }

        let perSessionCeiling = group.isSmallMuscle ? 6.0 : 9.0
        let direct = min(perSessionCeiling, credits * (1 - VolumeAllocator.indirectShare(group)))
        var sets = Int(direct.rounded())
        if sets < 2 {
            guard isPriority else { return [] }
            sets = 2
        }

        // Roughly three working sets per exercise. Fewer wastes the set-up; more runs into
        // within-exercise fatigue and stops adding stimulus. Three rather than four also matters
        // for balance: at four, a back carrying seven sets gets two movements while chest plus
        // shoulders get three between them, and the week quietly ends up pressing more than it
        // pulls.
        let maximumSlots = min(vocabulary.count, group.isSmallMuscle ? 2 : 3)
        let slotCount = max(1, min(maximumSlots, Int((Double(sets) / 3.0).rounded(.up))))

        var result: [ExerciseSlot] = []
        var remaining = sets
        for index in 0..<slotCount {
            let slotsLeft = slotCount - index
            // Front-load: the first movement of a group is the one worth the most sets.
            let share = Int((Double(remaining) / Double(slotsLeft)).rounded(.up))
            let assigned = max(2, min(5, share))
            let entry = vocabulary[min(index, vocabulary.count - 1)]
            result.append(ExerciseSlot(
                group: group,
                mechanic: entry.mechanic,
                preferredPattern: entry.pattern,
                sets: assigned,
                isPrimary: index == 0 && entry.mechanic == .compound
            ))
            remaining -= assigned
            if remaining < 2 { break }
        }
        return result
    }

    // MARK: - Cardio placement

    /// How many conditioning slots the week gets, from the goal alone. Cardio the user did not ask
    /// for is cardio they will skip, so `.none` always means none.
    private static func cardioSessionCount(profile: TrainingProfileSnapshot) -> Int {
        guard profile.cardioPreference != CardioPreference.none else { return 0 }
        let value = VolumeAllocator.blended(profile.goals) { goal in
            switch goal {
            case .loseFat, .improveEndurance: 3
            case .generalFitness, .recomposition: 2
            case .maintain, .buildMuscle, .targetMuscleGroup: 1
            case .buildStrength: 0
            }
        }
        return max(0, min(profile.daysPerWeek, Int(value.rounded())))
    }

    /// Cardio lands on the shortest lifting days, and always on an active-recovery day when there is
    /// one. `.separateSessions` cannot be honoured literally inside a weekly lifting plan, so it
    /// degrades to the lightest days available — the closest thing to a standalone session the
    /// schedule allows.
    private static func cardioDayIndices(
        plans: [DayPlan],
        profile: TrainingProfileSnapshot
    ) -> Set<Int> {
        let count = cardioSessionCount(profile: profile)
        guard count > 0 else { return [] }

        var chosen = Set<Int>()
        for (index, plan) in plans.enumerated() where plan.archetype == .activeRecovery {
            chosen.insert(index)
        }
        let ordered = plans.enumerated()
            .filter { !chosen.contains($0.offset) }
            .sorted { lhs, rhs in
                let left = lhs.element.credits.values.reduce(0, +)
                let right = rhs.element.credits.values.reduce(0, +)
                if abs(left - right) > 1e-9 { return left < right }
                return lhs.offset < rhs.offset
            }
        for entry in ordered {
            guard chosen.count < count else { break }
            chosen.insert(entry.offset)
        }
        return chosen
    }

    // MARK: - Fallback

    /// A single full-body day. Only reachable if the candidate vocabulary is ever emptied, but the
    /// app must always have a plan to show.
    private static func fallbackSplit(
        profile: TrainingProfileSnapshot,
        targets: VolumeTargets
    ) -> SelectedSplit {
        let priorities = VolumeAllocator.effectivePriorityGroups(profile)
        let groups = groups(for: .fullBody, priorities: priorities)
            .filter { targets.target(for: $0) > 0.5 }
        var slots: [ExerciseSlot] = []
        for group in MuscleGroup.volumeTracked where groups.contains(group) {
            slots.append(contentsOf: makeSlots(for: group, credits: targets.target(for: group),
                                               isPriority: priorities.contains(group)))
        }
        slots.sort { orderBucket($0) < orderBucket($1) }
        var frequency: [MuscleGroup: Int] = [:]
        for group in groups { frequency[group] = 1 }
        return SelectedSplit(
            key: "split.fullBody",
            daysPerWeek: 1,
            blueprints: [SessionBlueprint(
                titleKey: titleBaseKey(for: .fullBody),
                focusGroups: groups,
                pushPull: .neutral,
                slots: slots
            )],
            explanation: Explanation("split.reason.fullBody", ["1"]),
            frequency: frequency
        )
    }
}
