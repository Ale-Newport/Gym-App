import Foundation

/// Decides how many hard sets each muscle group earns per week, and how those sets are spread
/// across the training week.
///
/// Nothing in this file is a per-split lookup table. The numbers fall out of the user's training
/// age, goals, declared priorities, current fatigue, age and — decisively — the time they actually
/// have. A program whose weekly volume does not fit inside `daysPerWeek × sessionMinutesCap` is a
/// broken program the user quietly abandons, so the time budget is applied as a hard ceiling rather
/// than as a nudge.
///
/// **Everything here is counted in volume *credits*, not raw sets.** A set of bench press earns the
/// chest a full credit and the triceps and front delts half a credit each, following the
/// direct/indirect convention implemented in `ExerciseMetadataDeriver.volumeContribution`. Counting
/// credits is what lets the allocator prescribe far fewer *performed* sets than the sum of the
/// per-group targets suggests, and it is the same unit `weeklyVolume(of:catalog:)` reports back, so
/// plan and measurement are directly comparable.
enum VolumeAllocator {

    // MARK: - Time model

    /// Seconds one working set costs on average, including the rest interval that follows it.
    ///
    /// Derived from the catalogue's own numbers rather than guessed: `ExerciseMetadataDeriver`
    /// produces roughly 50 s of work for both a compound (7 reps × 3.5 s + 25 s of set-up) and an
    /// isolation (11 reps × 3.5 s + 12 s), with 165 s and 90 s of rest respectively. A typical
    /// session is about 40 % compound work, so 0.4 × 215 + 0.6 × 140 ≈ 170 s. `WorkoutProgrammingEngine`
    /// re-computes each session's real cost from the actual exercises; this constant only has to be
    /// good enough to set the weekly ceiling.
    static let averageSetSecondsIncludingRest: Double = 170

    /// Minutes of a session that are not working sets: general warm-up, ramp-up sets on the first
    /// heavy compound, and walking between stations.
    static let sessionOverheadMinutes: Int = 8

    /// Total volume credit one performed working set produces across *all* muscle groups.
    ///
    /// A compound with three secondary groups scores 1.0 + 3 × 0.5 = 2.5; a typical isolation with
    /// one secondary scores 1.0 + 0.33 ≈ 1.33. At a 40/60 compound-to-isolation mix that averages
    /// about 1.8. Without this factor the time ceiling would compare a credit budget against a set
    /// budget and cut roughly twice as much volume as it should.
    static let averageVolumeCreditPerSet: Double = 1.8

    /// What the user's week can physically hold.
    struct WeeklyTimeBudget: Hashable, Sendable {
        /// Training days per week.
        var sessions: Int
        /// The user's own per-session limit, unchanged.
        var minutesPerSession: Int
        /// Seconds per week left for working sets once warm-ups and transitions are paid for.
        var workingSeconds: Double
        /// Performed working sets the week can hold.
        var setCapacity: Double
        /// Volume credits those sets produce.
        var creditCapacity: Double
    }

    /// The hard weekly ceiling implied by the user's stated availability.
    static func timeBudget(for profile: TrainingProfileSnapshot) -> WeeklyTimeBudget {
        let sessions = profile.daysPerWeek
        // A session shorter than the overhead still has to leave room for a handful of sets, so the
        // usable slice never drops below 12 minutes.
        let usableMinutes = max(12, profile.sessionMinutesCap - sessionOverheadMinutes)
        let workingSeconds = Double(sessions) * Double(usableMinutes) * 60
        let secondsPerSet = averageSetSecondsIncludingRest * restFactor(for: profile.goals)
        let setCapacity = workingSeconds / max(1, secondsPerSet)
        return WeeklyTimeBudget(
            sessions: sessions,
            minutesPerSession: profile.sessionMinutesCap,
            workingSeconds: workingSeconds,
            setCapacity: setCapacity,
            creditCapacity: setCapacity * averageVolumeCreditPerSet
        )
    }

    // MARK: - Base envelope

    /// Weekly credit envelope for a *major* muscle group, by training age.
    ///
    /// These follow the mainstream evidence-based consensus that appears in Schoenfeld's
    /// dose-response work and in the volume landmarks popularised by Israetel: roughly 8–12 weekly
    /// sets for a novice, 12–18 for an intermediate and 14–22 for an advanced lifter, with the
    /// target sitting in the middle of the band. Novices are deliberately at the bottom — they get
    /// a disproportionate return from low volume, and the limiting factor is technique practice and
    /// recovery, not stimulus. The maximum is a *recovery* ceiling: past it, added sets buy fatigue
    /// rather than adaptation, so the priority bonus below is clamped to it.
    private static func baseEnvelope(
        for experience: ExperienceLevel
    ) -> (minimum: Double, target: Double, maximum: Double) {
        switch experience {
        case .never: (6, 8, 11)
        case .beginner: (8, 10, 13)
        case .intermediate: (12, 15, 18)
        case .advanced: (14, 18, 22)
        }
    }

    /// How much of a major group's envelope this group gets.
    ///
    /// Small muscles take less absolute volume for two reasons: they fatigue the whole system less
    /// per set so they need less to grow, and they are already showered with indirect work by every
    /// press, row and hinge. The tail groups (adductors, abductors) sit lowest because in practice
    /// they are trained almost entirely as synergists — prescribing them a major group's volume
    /// would crowd out work that actually matters.
    ///
    /// `back` sits above 1.0 on purpose. The taxonomy collapses lats, upper back and rhomboids into
    /// one bucket, so a single `back` target has to cover what the push side spreads across chest
    /// *and* front delts. Leaving it at parity with the chest is the standard way programs end up
    /// pressing half again as much as they pull, which is the imbalance the split scorer's
    /// `balanceFit` term exists to catch — and it is far better fixed here, at the source.
    static func groupScale(_ group: MuscleGroup) -> Double {
        switch group {
        case .back: 1.35
        case .chest, .shoulders, .quads, .hamstrings, .glutes: 1.00
        case .biceps, .triceps: 0.80
        case .calves, .abs, .traps: 0.60
        case .lowerBack: 0.40
        case .obliques, .forearms: 0.35
        case .adductors, .abductors: 0.20
        case .neck, .cardio: 0
        }
    }

    /// The share of a group's weekly credit that normally arrives *indirectly*, as synergist work
    /// inside other groups' exercises.
    ///
    /// Used to turn a credit target into a number of directly targeted sets. Without it the engine
    /// would prescribe six direct triceps exercises on top of five pressing movements. The values
    /// are read off `ExerciseMetadataDeriver.volumeContribution`: every horizontal and vertical
    /// press hands the triceps and front delts half a credit, every pull does the same for the
    /// biceps and forearms, and every hinge or squat loads the lower back and glutes.
    ///
    /// The set has to stay consistent with `averageVolumeCreditPerSet`: if one performed set yields
    /// 1.8 credits in total and only 1.0 of them is direct, then across the whole program 1 − 1/1.8
    /// ≈ 44 % of all credit is indirect. These numbers are chosen so their volume-weighted mean
    /// lands there. Setting them lower would make the planner prescribe far more direct sets than
    /// the week has room for.
    static func indirectShare(_ group: MuscleGroup) -> Double {
        switch group {
        case .forearms, .lowerBack: 0.75
        case .triceps: 0.55
        case .shoulders: 0.55
        case .biceps, .traps, .glutes: 0.50
        case .hamstrings: 0.45
        case .chest, .back, .quads, .calves, .abs, .obliques,
             .adductors, .abductors, .neck, .cardio: 0.30
        }
    }

    // MARK: - Modifiers

    /// Volume multiplier for a single goal.
    ///
    /// Hypertrophy sits highest because volume is its primary driver. Strength is deliberately
    /// lower: the same weekly stimulus has to be bought at a much higher intensity, and heavy sets
    /// cost far more recovery per set. Fat loss *maintains* volume rather than cutting it — muscle
    /// is retained by continuing to train it, and cutting sets in a deficit is the classic way to
    /// lose lean mass. Maintenance runs at the bottom because minimum effective volume is the whole
    /// point of a maintenance block.
    private static func volumeMultiplier(for goal: TrainingGoal) -> Double {
        switch goal {
        case .buildMuscle: 1.15
        case .targetMuscleGroup: 1.10
        case .recomposition: 1.05
        case .loseFat: 1.00
        case .improveEndurance: 0.95
        case .generalFitness: 0.90
        case .buildStrength: 0.80
        case .maintain: 0.70
        }
    }

    /// Multiplier on the average rest interval, which is what makes a set expensive in clock time.
    private static func restMultiplier(for goal: TrainingGoal) -> Double {
        switch goal {
        case .buildStrength: 1.30
        case .buildMuscle, .targetMuscleGroup: 1.00
        case .recomposition, .maintain: 0.95
        case .generalFitness: 0.92
        case .loseFat: 0.85
        case .improveEndurance: 0.78
        }
    }

    /// Blends a per-goal number across the user's ordered goal list.
    ///
    /// The first goal carries most of the weight but the others still bend the result, which is
    /// what a user who picks "build muscle, then lose fat" actually means.
    static func blended(_ goals: [TrainingGoal], _ value: (TrainingGoal) -> Double) -> Double {
        let weights: [Double] = [0.60, 0.25, 0.15]
        var total = 0.0
        var weightSum = 0.0
        for (index, goal) in goals.prefix(weights.count).enumerated() {
            total += value(goal) * weights[index]
            weightSum += weights[index]
        }
        guard weightSum > 0 else { return value(.generalFitness) }
        return total / weightSum
    }

    static func restFactor(for goals: [TrainingGoal]) -> Double {
        blended(goals, restMultiplier(for:))
    }

    /// Recovery-capacity heuristic for age.
    ///
    /// Past the mid-forties most lifters need a little more time between hard sessions for the same
    /// stimulus, so the target is trimmed by one percent per year beyond 45 and never by more than
    /// 15 percent. This is a conservative programming default, **not** a medical judgement and not a
    /// claim about any individual — a 55-year-old who feels fine simply raises their volume and the
    /// autoregulation engine follows them.
    static func ageFactor(ageYears: Int?) -> Double {
        guard let ageYears, ageYears > 45 else { return 1.0 }
        return 1.0 - min(0.15, Double(ageYears - 45) * 0.01)
    }

    /// Per-group fatigue damping.
    ///
    /// Fatigue below 0.35 is normal training residue and is ignored; above it the target is walked
    /// down to 65 % at maximal fatigue. Cutting volume the moment a group is at all fatigued would
    /// make the program oscillate.
    static func fatigueFactor(_ fatigue: Double) -> Double {
        let excess = min(max((fatigue - 0.35) / 0.65, 0), 1)
        return 1.0 - 0.35 * excess
    }

    /// Whole-body damping from the subjective readiness score.
    static func systemicFactor(_ readiness: Double) -> Double {
        1.0 - 0.20 * (1.0 - min(max(readiness, 0), 1))
    }

    /// Extra volume for a declared priority group, before the maximum clamps it.
    static let priorityMultiplier: Double = 1.30

    /// A deload keeps frequency and drops volume by about 40 %, which is the reduction that reliably
    /// dissipates accumulated fatigue while keeping enough stimulus to hold on to adaptations.
    static let deloadVolumeMultiplier: Double = 0.60

    /// The user's priority groups, sanitised.
    ///
    /// Capped at three: a list of eight priorities is not a list of priorities, and spreading the
    /// 30 % bonus across everything simply raises the whole program into territory the time budget
    /// will immediately cut back out again.
    static func effectivePriorityGroups(_ profile: TrainingProfileSnapshot) -> [MuscleGroup] {
        var seen = Set<MuscleGroup>()
        var result: [MuscleGroup] = []
        for group in profile.priorityGroups where MuscleGroup.volumeTracked.contains(group) {
            if seen.insert(group).inserted { result.append(group) }
            if result.count == 3 { break }
        }
        return result
    }

    // MARK: - Targets

    /// Weekly credit targets for every tracked muscle group.
    ///
    /// Order of operations matters and is deliberate: build the physiological envelope, bend it by
    /// goal, priority, fatigue and age, *then* cut it to fit the calendar. Fitting first and bending
    /// afterwards would let the modifiers push the program back over the time budget.
    static func targets(
        for profile: TrainingProfileSnapshot,
        recovery: RecoverySnapshot,
        isDeloadWeek: Bool
    ) -> VolumeTargets {
        let groups = MuscleGroup.volumeTracked
        let envelope = baseEnvelope(for: profile.experience)
        let goalMultiplier = blended(profile.goals, volumeMultiplier(for:))
        let age = ageFactor(ageYears: profile.ageYears)
        let systemic = systemicFactor(recovery.systemicReadiness)
        let priorities = Set(effectivePriorityGroups(profile))

        var minimum: [MuscleGroup: Double] = [:]
        var target: [MuscleGroup: Double] = [:]
        var maximum: [MuscleGroup: Double] = [:]

        for group in groups {
            let scale = groupScale(group)
            guard scale > 0 else { continue }

            let ceiling = envelope.maximum * scale
            var value = envelope.target * scale * goalMultiplier * age * systemic
            value *= fatigueFactor(recovery.fatigue(for: group))
            if priorities.contains(group) { value *= priorityMultiplier }
            value = min(value, ceiling)

            minimum[group] = envelope.minimum * scale
            target[group] = value
            maximum[group] = ceiling
        }

        // The calendar has the final word.
        let budget = timeBudget(for: profile)
        target = fit(target, into: budget.creditCapacity, priorities: priorities, minimum: minimum)

        if isDeloadWeek {
            for group in groups {
                target[group] = (target[group] ?? 0) * deloadVolumeMultiplier
                minimum[group] = (minimum[group] ?? 0) * deloadVolumeMultiplier
            }
        }

        // A minimum above the target reads as a broken promise, and a maximum below it makes the
        // priority clamp meaningless, so both are reconciled against the number actually planned.
        for group in groups {
            let planned = target[group] ?? 0
            minimum[group] = min(minimum[group] ?? 0, planned)
            maximum[group] = max(maximum[group] ?? 0, planned)
        }

        var frequency: [MuscleGroup: Int] = [:]
        for group in groups {
            frequency[group] = self.frequency(
                for: group,
                target: target[group] ?? 0,
                daysPerWeek: profile.daysPerWeek,
                isPriority: priorities.contains(group)
            )
        }

        return VolumeTargets(minimum: minimum, target: target, maximum: maximum, frequency: frequency)
    }

    // MARK: - Fitting volume into the week

    /// How readily a group gives up volume when the week is too short.
    ///
    /// A uniform scale-down would cut the chest to make room for the adductors, which is exactly
    /// backwards. Priority groups shed least, majors next, and the tail groups — which are largely
    /// trained indirectly anyway — absorb most of the cut.
    private static func shedFactor(_ group: MuscleGroup, isPriority: Bool) -> Double {
        if isPriority { return 0.35 }
        switch group {
        case .chest, .back, .shoulders, .quads, .hamstrings, .glutes: return 0.60
        case .biceps, .triceps, .abs, .calves: return 1.00
        default: return 1.40
        }
    }

    /// Walks the target set down until it fits inside `capacity` credits.
    ///
    /// Water-filling rather than a single proportional scale: each pass removes the excess in
    /// proportion to how willingly each group gives volume up, then re-checks, because groups that
    /// hit their floor stop absorbing and the rest have to take up the slack. Six passes converge
    /// comfortably; the uniform scale afterwards is a guarantee of termination, not a normal path.
    private static func fit(
        _ target: [MuscleGroup: Double],
        into capacity: Double,
        priorities: Set<MuscleGroup>,
        minimum: [MuscleGroup: Double]
    ) -> [MuscleGroup: Double] {
        let groups = MuscleGroup.volumeTracked.filter { (target[$0] ?? 0) > 0 }
        guard capacity > 0, !groups.isEmpty else { return target }

        var result = target
        // Floors keep the cut from deleting a group outright. Priority groups keep most of their
        // minimum, majors half of it; everything else may be cut to nothing, because a group with
        // one weekly set is noise in the plan rather than training.
        var floor: [MuscleGroup: Double] = [:]
        for group in groups {
            let base = minimum[group] ?? 0
            if priorities.contains(group) {
                floor[group] = base * 0.60
            } else if groupScale(group) >= 1.0 {
                floor[group] = base * 0.50
            } else {
                floor[group] = 0
            }
        }

        for _ in 0..<6 {
            let total = groups.reduce(0.0) { $0 + (result[$1] ?? 0) }
            guard total > capacity else { return result }
            let excess = total - capacity

            var weights: [MuscleGroup: Double] = [:]
            var weightSum = 0.0
            for group in groups {
                let headroom = max(0, (result[group] ?? 0) - (floor[group] ?? 0))
                let weight = headroom * shedFactor(group, isPriority: priorities.contains(group))
                weights[group] = weight
                weightSum += weight
            }
            guard weightSum > 0.0001 else { break }

            for group in groups {
                let share = (weights[group] ?? 0) / weightSum
                let reduced = (result[group] ?? 0) - excess * share
                result[group] = max(floor[group] ?? 0, reduced)
            }
        }

        let total = groups.reduce(0.0) { $0 + (result[$1] ?? 0) }
        if total > capacity {
            let scale = capacity / total
            for group in groups { result[group] = (result[group] ?? 0) * scale }
        }
        return result
    }

    // MARK: - Frequency

    /// How many times a week the group should be trained.
    ///
    /// Three constraints meet here. Volume: aim to train a group twice a week whenever there is
    /// enough of it to split, because per-session volume has diminishing returns past roughly nine
    /// *directly targeted* sets for a major group and six for a small one. Note that the ceiling is
    /// compared against direct sets, not credits — a chest carrying 20 weekly credits only performs
    /// about 14 chest sets, the rest arriving as synergist work, and comparing credits against a set
    /// ceiling would inflate every frequency by half. Recovery: the cap is derived from the group's
    /// own `baselineRecoveryHours` — 168 hours in a week divided by the group's recovery window,
    /// so quads and back (60 h) top out at twice a week while chest, delts and arms (44–52 h)
    /// tolerate three. Availability: nothing can be trained more often than the user trains at all.
    static func frequency(
        for group: MuscleGroup,
        target: Double,
        daysPerWeek: Int,
        isPriority: Bool
    ) -> Int {
        guard target > 0.5 else { return 0 }
        let perSessionCeiling = group.isSmallMuscle ? 6.0 : 9.0
        let directSets = target * (1 - indirectShare(group))
        let sessionsNeeded = max(1, Int((directSets / perSessionCeiling).rounded(.up)))
        // Once a group carries five or more weekly credits, two exposures beat one.
        let desired = target >= 5 ? 2 : 1
        var frequency = max(sessionsNeeded, desired)
        // A third exposure is only worth the scheduling cost when the week is long enough for it to
        // land on a genuinely recovered muscle.
        if isPriority && daysPerWeek >= 5 { frequency += 1 }
        let recoveryCap = min(3, max(1, Int(168.0 / group.baselineRecoveryHours)))
        frequency = min(frequency, recoveryCap)
        return max(1, min(frequency, max(1, daysPerWeek)))
    }

    // MARK: - Measuring a plan

    /// Weekly volume credits a generated program actually delivers.
    ///
    /// Sums `metadata.volumeContribution` across every planned working set, so indirect work is
    /// counted exactly as the targets assume it will be. Rest days and exercises missing from the
    /// catalogue contribute nothing rather than crashing — a program referencing a retired
    /// exercise id should still report a usable number.
    static func weeklyVolume(
        of sessions: [GeneratedSession],
        catalog: [String: Exercise]
    ) -> [MuscleGroup: Double] {
        var totals: [MuscleGroup: Double] = [:]
        for session in sessions where !session.isRestDay {
            for planned in session.exercises {
                guard let exercise = catalog[planned.exerciseID], planned.sets > 0 else { continue }
                let sets = Double(planned.sets)
                for (group, credit) in exercise.metadata.volumeContribution where credit > 0 {
                    totals[group, default: 0] += credit * sets
                }
            }
        }
        return totals
    }
}
