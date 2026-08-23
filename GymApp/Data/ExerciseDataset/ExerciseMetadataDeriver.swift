import Foundation

/// Turns the dataset's descriptive fields into the training properties the engines need.
///
/// The dataset gives us name, body part, equipment, target muscle and secondary muscles. It does
/// **not** say whether a movement is a compound or an isolation, which pattern it belongs to, how
/// fatiguing it is, or whether it should be logged in reps or in seconds. Those judgements drive
/// every programming decision, so they are made here — once, deterministically, from rules that are
/// written down and unit-tested. No network call and no language model is involved: the same input
/// always produces the same output, and `docs/ALGORITHMS.md` documents every rule below.
///
/// Ordering matters: rules run specific-to-general, and the first match wins.
enum ExerciseMetadataDeriver {

    // MARK: - Entry point

    static func derive(
        name: String,
        bodyPart: BodyPart,
        equipment: Equipment,
        target: Muscle,
        synergist: Muscle?,
        secondaryMuscles: [Muscle]
    ) -> ExerciseMetadata {
        let matcher = NameMatcher(name)

        let isStretch = detectStretch(matcher, bodyPart: bodyPart)
        let isPlyometric = detectPlyometric(matcher)
        let pattern = movementPattern(
            matcher, bodyPart: bodyPart, equipment: equipment, target: target, isStretch: isStretch
        )
        let mechanic = mechanic(for: pattern, secondaryCount: secondaryMuscles.count, isStretch: isStretch)
        let laterality = laterality(matcher, pattern: pattern)
        let tracking = trackingMode(
            matcher, bodyPart: bodyPart, equipment: equipment, pattern: pattern, isStretch: isStretch
        )
        let difficulty = difficulty(
            matcher, equipment: equipment, pattern: pattern,
            laterality: laterality, isPlyometric: isPlyometric, isStretch: isStretch
        )
        let stability = stabilityDemand(
            matcher, equipment: equipment, laterality: laterality, isPlyometric: isPlyometric
        )
        let fatigue = fatigueCost(
            pattern: pattern, mechanic: mechanic, equipment: equipment,
            laterality: laterality, isStretch: isStretch, isPlyometric: isPlyometric
        )
        let loadability = loadability(equipment: equipment, tracking: tracking)
        let progression = progressionSuitability(loadability: loadability, tracking: tracking, isStretch: isStretch)
        let stimulus = stimulusScore(
            mechanic: mechanic, progression: progression, stability: stability,
            isStretch: isStretch, tracking: tracking
        )
        let repRange = repRange(
            pattern: pattern, mechanic: mechanic, target: target, equipment: equipment, tracking: tracking
        )
        let rest = restSeconds(pattern: pattern, mechanic: mechanic, fatigue: fatigue, isStretch: isStretch)
        let setSeconds = estimatedSetSeconds(
            repRange: repRange, tracking: tracking, mechanic: mechanic, laterality: laterality
        )
        let tags = substitutionTags(
            matcher, equipment: equipment, pattern: pattern, mechanic: mechanic,
            laterality: laterality, isStretch: isStretch, isPlyometric: isPlyometric
        )
        let contribution = volumeContribution(
            target: target, synergist: synergist, secondaryMuscles: secondaryMuscles,
            mechanic: mechanic, isStretch: isStretch, tracking: tracking
        )
        let staple = stapleScore(
            matcher, equipment: equipment, mechanic: mechanic,
            pattern: pattern, isStretch: isStretch, difficulty: difficulty
        )

        return ExerciseMetadata(
            movementPattern: pattern,
            pushPull: pushPull(for: pattern, bodyPart: bodyPart),
            mechanic: mechanic,
            difficulty: difficulty,
            laterality: laterality,
            loadability: loadability,
            trackingMode: tracking,
            stabilityDemand: stability,
            fatigueCost: fatigue,
            stimulusScore: stimulus,
            progressionSuitability: progression,
            recommendedRepRange: repRange,
            defaultRestSeconds: rest,
            estimatedSetSeconds: setSeconds,
            isStretch: isStretch,
            isPlyometric: isPlyometric,
            isWarmupCandidate: isWarmupCandidate(
                matcher, equipment: equipment, isStretch: isStretch, fatigue: fatigue
            ),
            volumeContribution: contribution,
            substitutionTags: tags,
            stapleScore: staple
        )
    }

    // MARK: - Stretch / plyometric

    private static func detectStretch(_ m: NameMatcher, bodyPart: BodyPart) -> Bool {
        m.has("stretch", "stretches", "mobility", "foam roll", "self myofascial")
    }

    private static func detectPlyometric(_ m: NameMatcher) -> Bool {
        m.has("jump", "jumps", "jumping", "plyo", "plyometric", "hop", "hops",
              "box jump", "clap", "explosive", "burpee", "skater", "bound", "leap")
    }

    // MARK: - Movement pattern

    /// Keyword rules, most specific first. Anything unmatched falls through to a target-muscle
    /// default, which guarantees every record gets a usable pattern.
    static func movementPattern(
        _ m: NameMatcher,
        bodyPart: BodyPart,
        equipment: Equipment,
        target: Muscle,
        isStretch: Bool
    ) -> MovementPattern {
        if isStretch { return .mobility }
        if bodyPart == .cardio || target == .cardiovascularSystem { return .cardio }
        if bodyPart == .neck || target == .neck || target == .levatorScapulae { return .neckMovement }

        // Carries and loaded walks.
        if m.has("farmers walk", "farmer s walk", "suitcase carry", "carry", "waiters walk", "yoke") {
            return .carry
        }

        // Hip-dominant.
        if m.has("hip thrust", "glute bridge", "bridge", "frog pump") { return .hipThrust }
        if m.has("deadlift", "good morning", "romanian", "rdl", "hip hinge", "back extension",
                 "hyperextension", "pull through", "kettlebell swing", "swing", "clean", "snatch",
                 "high pull", "rack pull", "stiff leg", "straight leg deadlift") {
            return .hinge
        }

        // Knee-dominant.
        if m.has("lunge", "split squat", "step up", "step ups", "bulgarian", "curtsy", "sissy squat") {
            return .lunge
        }
        if m.has("squat", "leg press", "hack squat", "pistol", "wall sit") { return .squat }

        // Direct leg isolation.
        if m.has("leg extension", "knee extension", "quad extension") { return .kneeExtension }
        if m.has("leg curl", "hamstring curl", "femoral", "nordic", "glute ham raise", "inverse leg curl") {
            return .kneeFlexion
        }
        if m.has("calf raise", "calf press", "toe raise", "calf extension", "heel raise", "donkey calf") {
            return .calfRaise
        }
        if m.has("hip abduction", "abduction", "abductor", "side lying leg lift", "clam") {
            return .hipAbduction
        }
        if m.has("hip adduction", "adduction", "adductor", "inner thigh") { return .hipAdduction }

        // Upper-body pulling.
        if m.has("pulldown", "pull down", "pull up", "pullup", "chin up", "chinup", "lat pull",
                 "muscle up", "climb", "pull ups") {
            return .verticalPull
        }
        if m.has("row", "rows", "rowing", "face pull", "rear delt fly", "reverse fly",
                 "reverse pec deck", "inverted row", "pullover") {
            return m.has("pullover") ? .verticalPull : .horizontalPull
        }
        if m.has("shrug", "shrugs") { return .shrug }

        // Upper-body pushing.
        if m.has("overhead press", "shoulder press", "military press", "arnold press",
                 "push press", "handstand push", "z press", "landmine press", "pike push") {
            return .verticalPush
        }
        if m.has("bench press", "chest press", "push up", "pushup", "push ups", "dip", "dips",
                 "floor press", "incline press", "decline press", "svend") {
            return .horizontalPush
        }
        if m.has("fly", "flye", "flyes", "flys", "pec deck", "crossover", "cross over", "chest cross") {
            return .chestFly
        }
        if m.has("lateral raise", "front raise", "side raise", "raise", "upright row", "y raise",
                 "t raise", "scaption", "external rotation", "internal rotation", "rotator") {
            return m.has("upright row") ? .horizontalPull : .shoulderRaise
        }
        // A bare "press" that reached this point is a pressing movement of some kind.
        if m.has("press") {
            return target == .delts || target == .rearDelts ? .verticalPush : .horizontalPush
        }

        // Arms.
        if m.has("curl", "curls", "preacher", "concentration", "drag curl", "spider curl", "zottman") {
            return target == .hamstrings ? .kneeFlexion : .elbowFlexion
        }
        if m.has("extension", "pushdown", "push down", "kickback", "skull crusher", "skullcrusher",
                 "french press", "triceps", "tricep", "close grip bench") {
            return .elbowExtension
        }
        if m.has("wrist curl", "wrist flexion", "finger curl") { return .wristFlexion }
        if m.has("wrist extension", "reverse wrist", "wrist") { return .wristExtension }

        // Core.
        if m.has("plank", "hollow", "dead bug", "ab wheel", "rollout", "roll out", "l sit",
                 "front lever", "bird dog", "stomach vacuum") {
            return .coreAntiExtension
        }
        if m.has("russian twist", "twist", "wood chop", "woodchop", "chop", "rotation", "rotational") {
            return .coreRotation
        }
        if m.has("side bend", "side crunch", "side plank", "oblique", "lateral flexion", "windmill") {
            return .coreLateralFlexion
        }
        if m.has("crunch", "sit up", "situp", "leg raise", "knee raise", "toe touch", "v up",
                 "jackknife", "scissor", "flutter", "tuck", "reverse crunch", "hanging") {
            return .coreFlexion
        }

        // Target-based fallbacks. Every muscle resolves to something sensible.
        switch target {
        case .pectorals: return .horizontalPush
        case .lats: return .verticalPull
        case .upperBack, .rhomboids: return .horizontalPull
        case .traps, .levatorScapulae: return .shrug
        case .delts: return .shoulderRaise
        case .rearDelts, .rotatorCuff: return .horizontalPull
        case .biceps, .brachialis: return .elbowFlexion
        case .triceps: return .elbowExtension
        case .forearms: return .wristFlexion
        case .quads: return .squat
        case .hamstrings: return .kneeFlexion
        case .glutes: return .hinge
        case .adductors: return .hipAdduction
        case .abductors: return .hipAbduction
        case .calves, .soleus, .tibialisAnterior, .ankles: return .calfRaise
        case .abs, .hipFlexors, .serratusAnterior: return .coreFlexion
        case .obliques: return .coreRotation
        case .lowerBack: return .hinge
        case .neck: return .neckMovement
        case .cardiovascularSystem: return .cardio
        }
    }

    // MARK: - Mechanic

    static func mechanic(for pattern: MovementPattern, secondaryCount: Int, isStretch: Bool) -> Mechanic {
        if isStretch { return .isolation }
        switch pattern {
        case .horizontalPush, .verticalPush, .horizontalPull, .verticalPull,
             .squat, .hinge, .lunge, .carry, .hipThrust, .cardio:
            return .compound
        case .chestFly, .shoulderRaise, .shrug, .elbowFlexion, .elbowExtension,
             .kneeExtension, .kneeFlexion, .calfRaise, .hipAbduction, .hipAdduction,
             .wristFlexion, .wristExtension, .neckMovement, .mobility:
            return .isolation
        case .coreFlexion, .coreAntiExtension, .coreRotation, .coreLateralFlexion:
            // Loaded, multi-joint core work (ab wheel, hanging leg raise) behaves like a compound.
            return secondaryCount >= 3 ? .compound : .isolation
        case .other:
            return secondaryCount >= 2 ? .compound : .isolation
        }
    }

    static func pushPull(for pattern: MovementPattern, bodyPart: BodyPart) -> PushPullClass {
        switch pattern {
        case .horizontalPush, .verticalPush, .chestFly, .elbowExtension: .push
        case .horizontalPull, .verticalPull, .shrug, .elbowFlexion, .shoulderRaise: .pull
        case .squat, .hinge, .lunge, .hipThrust, .kneeExtension, .kneeFlexion,
             .calfRaise, .hipAbduction, .hipAdduction: .legs
        case .coreFlexion, .coreAntiExtension, .coreRotation, .coreLateralFlexion: .core
        case .cardio: .cardio
        case .carry, .wristFlexion, .wristExtension, .neckMovement, .mobility, .other: .neutral
        }
    }

    // MARK: - Laterality

    static func laterality(_ m: NameMatcher, pattern: MovementPattern) -> Laterality {
        if m.has("alternate", "alternating", "alternated") { return .alternating }
        if m.has("one arm", "single arm", "one leg", "single leg", "unilateral", "one hand",
                 "single hand", "one side", "bulgarian", "pistol", "split squat", "step up",
                 "lunge", "suitcase", "concentration", "curtsy", "single") {
            return .unilateral
        }
        if pattern == .lunge { return .unilateral }
        return .bilateral
    }

    // MARK: - Tracking mode

    static func trackingMode(
        _ m: NameMatcher,
        bodyPart: BodyPart,
        equipment: Equipment,
        pattern: MovementPattern,
        isStretch: Bool
    ) -> TrackingMode {
        if isStretch { return .duration }

        if bodyPart == .cardio || pattern == .cardio {
            switch equipment {
            case .stationaryBike, .ellipticalMachine, .stepmillMachine, .skiergMachine,
                 .upperBodyErgometer, .leverageMachine, .sledMachine:
                return .distanceAndDuration
            default:
                return m.has("run", "walk", "walking", "jog", "sprint", "rope") ? .distanceAndDuration : .duration
            }
        }

        // Held positions.
        if m.has("plank", "hold", "holds", "hollow", "wall sit", "l sit", "iso", "isometric",
                 "hang", "dead hang", "vacuum", "static") {
            return .duration
        }

        if pattern == .carry { return .weightAndDuration }

        switch equipment {
        case .assisted:
            return .assistedBodyweight
        case .weighted:
            return .weightedBodyweight
        case .bodyWeight:
            // Bodyweight strength movements can take added load; the field simply defaults to zero.
            return .weightedBodyweight
        case .band, .resistanceBand, .stabilityBall, .bosuBall, .roller, .wheelRoller, .rope:
            return .repsOnly
        case .stationaryBike, .ellipticalMachine, .stepmillMachine, .skiergMachine, .upperBodyErgometer:
            return .distanceAndDuration
        case .other:
            return .repsOnly
        default:
            return .weightAndReps
        }
    }

    // MARK: - Difficulty

    static func difficulty(
        _ m: NameMatcher,
        equipment: Equipment,
        pattern: MovementPattern,
        laterality: Laterality,
        isPlyometric: Bool,
        isStretch: Bool
    ) -> Difficulty {
        if isStretch { return .beginner }

        // Movements that genuinely require an advanced base, regardless of anything else.
        if m.has("muscle up", "planche", "front lever", "back lever", "handstand", "iron cross",
                 "pistol", "snatch", "clean and jerk", "jerk", "overhead squat", "nordic",
                 "one arm push up", "one arm pull up", "human flag", "dragon flag", "skin the cat",
                 "deficit", "behind neck", "behind the neck", "sissy squat", "zercher") {
            return .advanced
        }

        var score = 0
        switch equipment {
        case .leverageMachine, .smithMachine, .assisted, .sledMachine, .stationaryBike,
             .ellipticalMachine, .stepmillMachine, .skiergMachine, .upperBodyErgometer:
            score -= 1
        case .cable, .band, .resistanceBand, .medicineBall, .roller:
            score += 0
        case .dumbbell, .ezBarbell, .weighted, .rope:
            score += 1
        case .barbell, .olympicBarbell, .trapBar, .kettlebell, .hammer, .tire:
            score += 2
        case .stabilityBall, .bosuBall, .wheelRoller:
            score += 2
        case .bodyWeight, .other:
            score += 1
        }

        switch pattern {
        case .squat, .hinge, .verticalPush, .verticalPull, .carry: score += 1
        case .lunge: score += 1
        case .elbowFlexion, .elbowExtension, .calfRaise, .shoulderRaise,
             .wristFlexion, .wristExtension, .neckMovement: score -= 1
        default: break
        }

        if laterality != .bilateral { score += 1 }
        if isPlyometric { score += 1 }
        if m.has("seated", "supported", "lying", "machine", "assisted", "chest supported") { score -= 1 }

        if score <= 0 { return .beginner }
        if score <= 2 { return .intermediate }
        return .advanced
    }

    // MARK: - Continuous scores

    static func stabilityDemand(
        _ m: NameMatcher,
        equipment: Equipment,
        laterality: Laterality,
        isPlyometric: Bool
    ) -> Double {
        var value: Double
        switch equipment {
        case .leverageMachine, .sledMachine, .assisted: value = 0.10
        case .smithMachine: value = 0.18
        case .cable: value = 0.32
        case .band, .resistanceBand: value = 0.30
        case .barbell, .olympicBarbell, .trapBar, .ezBarbell: value = 0.52
        case .dumbbell, .weighted: value = 0.58
        case .kettlebell: value = 0.66
        case .medicineBall, .rope, .hammer, .tire: value = 0.60
        case .stabilityBall, .bosuBall, .wheelRoller, .roller: value = 0.88
        case .bodyWeight: value = 0.48
        case .stationaryBike, .ellipticalMachine, .stepmillMachine, .skiergMachine, .upperBodyErgometer:
            value = 0.12
        case .other: value = 0.45
        }
        if laterality != .bilateral { value += 0.14 }
        if isPlyometric { value += 0.12 }
        if m.has("standing", "overhead") { value += 0.08 }
        if m.has("seated", "lying", "prone", "supine", "chest supported", "supported") { value -= 0.12 }
        return min(max(value, 0.05), 1.0)
    }

    static func fatigueCost(
        pattern: MovementPattern,
        mechanic: Mechanic,
        equipment: Equipment,
        laterality: Laterality,
        isStretch: Bool,
        isPlyometric: Bool
    ) -> Double {
        if isStretch { return 0.03 }

        var value: Double
        switch pattern {
        case .hinge: value = 0.95
        case .squat: value = 0.90
        case .lunge: value = 0.72
        case .carry: value = 0.70
        case .verticalPush: value = 0.62
        case .horizontalPush: value = 0.60
        case .verticalPull: value = 0.58
        case .horizontalPull: value = 0.55
        case .hipThrust: value = 0.55
        case .kneeFlexion, .kneeExtension: value = 0.38
        case .cardio: value = 0.45
        case .chestFly, .shoulderRaise, .shrug: value = 0.24
        case .elbowFlexion, .elbowExtension: value = 0.20
        case .calfRaise: value = 0.18
        case .hipAbduction, .hipAdduction: value = 0.18
        case .coreFlexion, .coreRotation, .coreLateralFlexion: value = 0.18
        case .coreAntiExtension: value = 0.22
        case .wristFlexion, .wristExtension, .neckMovement: value = 0.10
        case .mobility: value = 0.04
        case .other: value = 0.30
        }

        switch equipment {
        case .barbell, .olympicBarbell, .trapBar: value *= 1.12
        case .leverageMachine, .smithMachine, .assisted, .sledMachine: value *= 0.86
        case .band, .resistanceBand: value *= 0.72
        case .bodyWeight: value *= 0.92
        default: break
        }

        if mechanic == .isolation { value *= 0.92 }
        if laterality != .bilateral { value *= 0.92 }
        if isPlyometric { value *= 1.10 }
        return min(max(value, 0.03), 1.0)
    }

    static func loadability(equipment: Equipment, tracking: TrackingMode) -> Loadability {
        switch tracking {
        case .assistedBodyweight: return .assistedBodyweight
        case .weightedBodyweight: return equipment == .bodyWeight ? .bodyweight : .weightedBodyweight
        case .repsOnly: return equipment.loadability == .band ? .band : .bodyweight
        case .duration, .distanceAndDuration: return .none
        default: return equipment.loadability
        }
    }

    static func progressionSuitability(
        loadability: Loadability,
        tracking: TrackingMode,
        isStretch: Bool
    ) -> Double {
        if isStretch { return 0.05 }
        switch loadability {
        case .barbell: return 1.00
        case .ezBar: return 0.92
        case .machineStack: return 0.90
        case .cableStack: return 0.88
        case .dumbbell: return 0.86
        case .weightedBodyweight: return 0.80
        case .assistedBodyweight: return 0.72
        case .kettlebell: return 0.58
        case .bodyweight: return 0.45
        case .band: return 0.32
        case .fixedImplement: return 0.30
        case .none: return 0.20
        }
    }

    static func stimulusScore(
        mechanic: Mechanic,
        progression: Double,
        stability: Double,
        isStretch: Bool,
        tracking: TrackingMode
    ) -> Double {
        if isStretch { return 0.02 }
        if tracking == .distanceAndDuration { return 0.25 }

        // A good hypertrophy set needs load that can be progressed and enough stability that the
        // target muscle — not the stabilisers — is the limiting factor.
        var value = 0.45
        value += mechanic == .compound ? 0.18 : 0.12
        value += progression * 0.28
        value -= max(0, stability - 0.55) * 0.35
        return min(max(value, 0.05), 1.0)
    }

    static func repRange(
        pattern: MovementPattern,
        mechanic: Mechanic,
        target: Muscle,
        equipment: Equipment,
        tracking: TrackingMode
    ) -> RepRange {
        if !tracking.usesReps { return RepRange(1, 1) }

        switch pattern {
        case .hinge, .squat:
            return equipment == .barbell || equipment == .olympicBarbell || equipment == .trapBar
                ? RepRange(5, 8) : RepRange(8, 12)
        case .horizontalPush, .verticalPush, .horizontalPull, .verticalPull:
            return mechanic == .compound ? RepRange(6, 10) : RepRange(8, 12)
        case .lunge, .hipThrust, .carry:
            return RepRange(8, 12)
        case .kneeExtension, .kneeFlexion:
            return RepRange(10, 15)
        case .chestFly, .shoulderRaise, .shrug:
            return RepRange(10, 15)
        case .elbowFlexion, .elbowExtension:
            return RepRange(8, 14)
        case .calfRaise:
            return RepRange(10, 20)
        case .hipAbduction, .hipAdduction:
            return RepRange(12, 20)
        case .coreFlexion, .coreRotation, .coreLateralFlexion, .coreAntiExtension:
            return RepRange(10, 20)
        case .wristFlexion, .wristExtension, .neckMovement:
            return RepRange(12, 20)
        case .mobility, .cardio, .other:
            return RepRange(10, 15)
        }
    }

    static func restSeconds(
        pattern: MovementPattern,
        mechanic: Mechanic,
        fatigue: Double,
        isStretch: Bool
    ) -> Int {
        if isStretch { return 20 }
        switch pattern {
        case .hinge, .squat: return 210
        case .horizontalPush, .verticalPush, .verticalPull, .horizontalPull, .lunge, .carry, .hipThrust:
            return mechanic == .compound ? 165 : 105
        case .cardio: return 60
        case .coreFlexion, .coreRotation, .coreLateralFlexion, .coreAntiExtension: return 60
        case .wristFlexion, .wristExtension, .neckMovement: return 50
        case .calfRaise, .hipAbduction, .hipAdduction: return 60
        default: return fatigue > 0.35 ? 105 : 75
        }
    }

    static func estimatedSetSeconds(
        repRange: RepRange,
        tracking: TrackingMode,
        mechanic: Mechanic,
        laterality: Laterality
    ) -> Int {
        let base: Double
        switch tracking {
        case .duration: base = 45
        case .distanceAndDuration: base = 300
        case .weightAndDuration: base = 45
        default:
            // ~3.5 s per rep under control, plus set-up and unracking time.
            base = Double(repRange.midpoint) * 3.5 + (mechanic == .compound ? 25 : 12)
        }
        return Int((base * laterality.timeMultiplier).rounded())
    }

    static func isWarmupCandidate(
        _ m: NameMatcher,
        equipment: Equipment,
        isStretch: Bool,
        fatigue: Double
    ) -> Bool {
        if isStretch { return true }
        if equipment == .band || equipment == .resistanceBand { return fatigue < 0.35 }
        return m.has("bodyweight", "air squat", "arm circle", "leg swing", "cat cow", "bird dog")
    }

    // MARK: - Volume accounting

    /// Fractional weekly-set credit per muscle group.
    ///
    /// The target group earns a full set (1.0). Synergists and listed secondary muscles earn a half
    /// set — the widely used "direct vs indirect volume" convention. A group never earns more than
    /// one full set from a single exercise, and stretches/cardio earn nothing, because neither
    /// produces the mechanical tension weekly volume is meant to count.
    static func volumeContribution(
        target: Muscle,
        synergist: Muscle?,
        secondaryMuscles: [Muscle],
        mechanic: Mechanic,
        isStretch: Bool,
        tracking: TrackingMode
    ) -> [MuscleGroup: Double] {
        guard !isStretch, tracking != .distanceAndDuration else { return [:] }

        var contribution: [MuscleGroup: Double] = [target.group: 1.0]
        let indirectCredit = mechanic == .compound ? 0.5 : 0.33

        var indirect: [Muscle] = []
        if let synergist { indirect.append(synergist) }
        indirect.append(contentsOf: secondaryMuscles)

        for muscle in indirect {
            let group = muscle.group
            if group == target.group { continue }
            contribution[group] = max(contribution[group] ?? 0, indirectCredit)
        }
        contribution[.cardio] = nil
        return contribution
    }

    // MARK: - Substitution tags

    static func substitutionTags(
        _ m: NameMatcher,
        equipment: Equipment,
        pattern: MovementPattern,
        mechanic: Mechanic,
        laterality: Laterality,
        isStretch: Bool,
        isPlyometric: Bool
    ) -> Set<String> {
        var tags: Set<String> = [pattern.rawValue, mechanic.rawValue]

        switch equipment {
        case .leverageMachine, .smithMachine, .sledMachine, .assisted: tags.insert("machine")
        case .cable: tags.insert("cable"); tags.insert("constant_tension")
        case .barbell, .olympicBarbell, .trapBar, .ezBarbell:
            tags.insert("free_weight"); tags.insert("bar")
        case .dumbbell, .kettlebell, .weighted:
            tags.insert("free_weight"); tags.insert("handheld")
        case .band, .resistanceBand: tags.insert("band"); tags.insert("portable")
        case .bodyWeight: tags.insert("bodyweight"); tags.insert("portable")
        default: break
        }

        if laterality != .bilateral { tags.insert("unilateral") } else { tags.insert("bilateral") }
        if isPlyometric { tags.insert("plyometric"); tags.insert("jump") }
        if isStretch { tags.insert("stretch") }

        // Position and angle, which matter a great deal when finding a like-for-like swap.
        if m.has("incline") { tags.insert("incline") }
        if m.has("decline") { tags.insert("decline") }
        if m.has("flat") { tags.insert("flat") }
        if m.has("seated") { tags.insert("seated") }
        if m.has("standing") { tags.insert("standing") }
        if m.has("lying", "supine") { tags.insert("lying") }
        if m.has("prone") { tags.insert("prone") }
        if m.has("kneeling") { tags.insert("kneeling") }
        if m.has("bent over", "bent") { tags.insert("bent_over") }
        if m.has("overhead") { tags.insert("overhead") }
        if m.has("behind neck", "behind the neck") { tags.insert("behind_neck") }
        if m.has("close grip", "close") { tags.insert("close_grip") }
        if m.has("wide grip", "wide") { tags.insert("wide_grip") }
        if m.has("reverse grip", "reverse", "supinated") { tags.insert("reverse_grip") }
        if m.has("neutral grip", "hammer") { tags.insert("neutral_grip") }
        if m.has("preacher") { tags.insert("preacher") }
        if m.has("deficit", "pause", "tempo") { tags.insert("advanced_variation") }
        if m.has("chest supported", "supported") { tags.insert("supported") }
        if m.has("hanging") { tags.insert("hanging"); tags.insert("grip_limited") }

        // Tags consumed by mobility-limitation filtering.
        if pattern == .verticalPush || m.has("overhead") { tags.insert("overhead") }
        if pattern == .squat || pattern == .hinge {
            if equipment == .barbell || equipment == .olympicBarbell || equipment == .smithMachine {
                tags.insert("axial_load")
            }
        }
        if pattern == .hinge { tags.insert("hinge") }
        if m.has("deep", "full", "ass to grass", "sissy") { tags.insert("deep_knee") }
        if pattern == .wristFlexion || pattern == .wristExtension { tags.insert("wrist_loaded") }
        if pattern == .verticalPull || pattern == .carry { tags.insert("grip_limited") }
        if pattern == .chestFly && m.has("deep") { tags.insert("deep_stretch_shoulder") }

        return tags
    }

    // MARK: - Staple score

    /// How central a movement is to normal training, 0…1. Used only to break ties: given two
    /// equally suitable exercises the well-known one wins, which keeps generated programs
    /// recognisable instead of full of obscure variations.
    static func stapleScore(
        _ m: NameMatcher,
        equipment: Equipment,
        mechanic: Mechanic,
        pattern: MovementPattern,
        isStretch: Bool,
        difficulty: Difficulty
    ) -> Double {
        if isStretch { return 0.05 }

        var score = 0.30
        if mechanic == .compound { score += 0.16 }

        switch equipment {
        case .barbell, .dumbbell, .cable, .leverageMachine: score += 0.16
        case .smithMachine, .ezBarbell, .bodyWeight, .kettlebell: score += 0.08
        case .band, .resistanceBand, .stabilityBall, .bosuBall, .medicineBall: score -= 0.06
        case .tire, .hammer, .rope, .wheelRoller, .roller, .other: score -= 0.10
        default: break
        }

        // Short names describe the canonical movement; long ones describe a variation of it.
        switch m.wordCount {
        case 0...2: score += 0.20
        case 3: score += 0.12
        case 4: score += 0.04
        case 5: score -= 0.04
        default: score -= 0.12
        }

        // Explicit dataset variant markers.
        if m.has("v 2", "v 3", "v 4", "version", "male", "female") { score -= 0.14 }
        if difficulty == .advanced { score -= 0.06 }

        switch pattern {
        case .horizontalPush, .verticalPull, .squat, .hinge, .horizontalPull, .verticalPush:
            score += 0.10
        case .other, .mobility:
            score -= 0.10
        default:
            break
        }

        return min(max(score, 0.02), 1.0)
    }
}
