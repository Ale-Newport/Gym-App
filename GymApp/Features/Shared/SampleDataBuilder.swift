import Foundation
import SwiftData

/// Builds the fixtures described by `PreviewSupport.Scenario`.
///
/// Kept entirely out of the shipping paths: the only callers are `#Preview` blocks and the UI-test
/// launch argument handler. Nothing here is ever inserted into a real user's store.
///
/// The exercise ids below are real ids from the bundled dataset, so previews render real names and
/// real artwork rather than invented ones.
@MainActor
enum SampleDataBuilder {

    // Verified ids from `exercises.core.json`.
    enum Sample {
        static let benchPress = ("0025", "barbell bench press")
        static let squat = ("0043", "barbell full squat")
        static let deadlift = ("0032", "barbell deadlift")
        static let pullUp = ("0652", "pull-up")
        static let bentOverRow = ("0027", "barbell bent over row")
        static let seatedRow = ("0861", "cable seated row")
        static let latPulldown = ("0673", "reverse grip machine lat pulldown")
        static let inclineDumbbellPress = ("0314", "dumbbell incline bench press")
        static let lateralRaise = ("0334", "dumbbell lateral raise")
        static let bicepsCurl = ("0294", "dumbbell biceps curl")
        static let hammerCurl = ("0313", "dumbbell hammer curl")
        static let pushdown = ("0201", "cable pushdown")
        static let legExtension = ("0585", "lever leg extension")
        static let legCurl = ("0586", "lever lying leg curl")
        static let romanianDeadlift = ("0085", "barbell romanian deadlift")
        static let lunge = ("0336", "dumbbell lunge")
        static let calfRaise = ("0417", "dumbbell standing calf raise")
        static let plank = ("0464", "front plank with twist")
        static let hangingLegRaise = ("0472", "hanging leg raise")
    }

    static func populate(_ context: ModelContext, scenario: PreviewSupport.Scenario) {
        switch scenario {
        case .newUser:
            // Deliberately empty: this is what a genuine first launch looks like.
            return
        case .freshProgram:
            makeProfile(context, onboarded: true)
            makeSettings(context)
            makeEquipment(context)
            makeProgram(context)
            makeNutritionTarget(context)
        case .seasonedUser:
            makeProfile(context, onboarded: true)
            makeSettings(context)
            makeEquipment(context)
            let program = makeProgram(context)
            makeHistory(context, program: program, weeks: 13)
            makeBodyWeightHistory(context, days: 92)
            makeNutritionTarget(context)
            makeFoods(context)
            makeNutritionHistory(context, days: 30)
            makePreferences(context)
            makeAchievements(context)
        case .activeWorkout:
            makeProfile(context, onboarded: true)
            makeSettings(context)
            makeEquipment(context)
            let program = makeProgram(context)
            makeHistory(context, program: program, weeks: 6)
            makeActiveSession(context, program: program)
            makeNutritionTarget(context)
        case .emptyNutritionDay:
            makeProfile(context, onboarded: true)
            makeSettings(context)
            makeEquipment(context)
            makeNutritionTarget(context)
            makeFoods(context)
        case .fullNutritionDay:
            makeProfile(context, onboarded: true)
            makeSettings(context)
            makeEquipment(context)
            makeNutritionTarget(context)
            makeFoods(context)
            makeNutritionHistory(context, days: 1)
        }
        try? context.save()
    }

    // MARK: - Profile

    @discardableResult
    private static func makeProfile(_ context: ModelContext, onboarded: Bool) -> UserProfile {
        let profile = UserProfile()
        profile.name = "Alex"
        profile.birthDate = Calendar.current.date(byAdding: .year, value: -29, to: Date())
        profile.biologicalSex = .male
        profile.heightCm = 178
        profile.currentWeightKg = 78.4
        profile.targetWeightKg = 82
        profile.experience = .intermediate
        profile.trainingExperienceMonths = 26
        profile.techniqueConfidence = .confident
        profile.goals = [.buildMuscle, .buildStrength]
        profile.priorityGroups = [.chest, .back]
        profile.activityLevel = .moderate
        profile.availableWeekdays = [.monday, .tuesday, .thursday, .friday]
        profile.sessionMinutesCap = 70
        profile.preferredTrainingTime = .evening
        profile.cardioPreference = .afterLifting
        profile.dietType = .omnivore
        profile.mealsPerDay = 4
        profile.nutritionPace = .moderate
        profile.onboardingCompletedAt = onboarded
            ? Calendar.current.date(byAdding: .day, value: -92, to: Date())
            : nil
        context.insert(profile)
        return profile
    }

    private static func makeSettings(_ context: ModelContext) {
        let settings = UserSettings()
        settings.notificationsEnabled = true
        settings.trainingReminderEnabled = true
        settings.nutritionEnabled = true
        settings.waterTrackingEnabled = true
        context.insert(settings)
    }

    private static func makeEquipment(_ context: ModelContext) {
        let equipment = EquipmentProfile()
        equipment.preset = .fullGym
        equipment.availableEquipment = Array(Equipment.fullGym)
        context.insert(equipment)
    }

    // MARK: - Program

    private struct TemplateSpec {
        let titleKey: String
        let title: String
        let weekday: Weekday
        let focus: [MuscleGroup]
        let pushPull: PushPullClass
        let exercises: [(id: String, name: String, sets: Int, low: Int, high: Int, rest: Int)]
    }

    private static var templateSpecs: [TemplateSpec] {
        [
            TemplateSpec(
                titleKey: "session.title.upper.a", title: "Upper A", weekday: .monday,
                focus: [.chest, .back, .shoulders, .triceps, .biceps], pushPull: .push,
                exercises: [
                    (Sample.benchPress.0, Sample.benchPress.1, 4, 6, 8, 180),
                    (Sample.bentOverRow.0, Sample.bentOverRow.1, 4, 6, 10, 165),
                    (Sample.inclineDumbbellPress.0, Sample.inclineDumbbellPress.1, 3, 8, 12, 120),
                    (Sample.latPulldown.0, Sample.latPulldown.1, 3, 8, 12, 120),
                    (Sample.lateralRaise.0, Sample.lateralRaise.1, 3, 12, 15, 75),
                    (Sample.pushdown.0, Sample.pushdown.1, 3, 10, 14, 75),
                    (Sample.bicepsCurl.0, Sample.bicepsCurl.1, 3, 10, 14, 75),
                ]
            ),
            TemplateSpec(
                titleKey: "session.title.lower.a", title: "Lower A", weekday: .tuesday,
                focus: [.quads, .glutes, .hamstrings, .calves, .abs], pushPull: .legs,
                exercises: [
                    (Sample.squat.0, Sample.squat.1, 4, 5, 8, 210),
                    (Sample.romanianDeadlift.0, Sample.romanianDeadlift.1, 3, 6, 10, 180),
                    (Sample.legExtension.0, Sample.legExtension.1, 3, 10, 15, 75),
                    (Sample.legCurl.0, Sample.legCurl.1, 3, 10, 15, 75),
                    (Sample.calfRaise.0, Sample.calfRaise.1, 4, 10, 20, 60),
                    (Sample.hangingLegRaise.0, Sample.hangingLegRaise.1, 3, 10, 20, 60),
                ]
            ),
            TemplateSpec(
                titleKey: "session.title.upper.b", title: "Upper B", weekday: .thursday,
                focus: [.back, .chest, .shoulders, .biceps, .triceps], pushPull: .pull,
                exercises: [
                    (Sample.pullUp.0, Sample.pullUp.1, 4, 5, 10, 165),
                    (Sample.inclineDumbbellPress.0, Sample.inclineDumbbellPress.1, 4, 6, 10, 165),
                    (Sample.seatedRow.0, Sample.seatedRow.1, 3, 8, 12, 120),
                    (Sample.lateralRaise.0, Sample.lateralRaise.1, 3, 12, 15, 75),
                    (Sample.hammerCurl.0, Sample.hammerCurl.1, 3, 10, 14, 75),
                    (Sample.pushdown.0, Sample.pushdown.1, 3, 10, 14, 75),
                ]
            ),
            TemplateSpec(
                titleKey: "session.title.lower.b", title: "Lower B", weekday: .friday,
                focus: [.glutes, .hamstrings, .quads, .calves, .abs], pushPull: .legs,
                exercises: [
                    (Sample.deadlift.0, Sample.deadlift.1, 3, 4, 6, 210),
                    (Sample.lunge.0, Sample.lunge.1, 3, 8, 12, 120),
                    (Sample.legCurl.0, Sample.legCurl.1, 3, 10, 15, 75),
                    (Sample.legExtension.0, Sample.legExtension.1, 3, 10, 15, 75),
                    (Sample.calfRaise.0, Sample.calfRaise.1, 4, 10, 20, 60),
                    (Sample.plank.0, Sample.plank.1, 3, 1, 1, 60),
                ]
            ),
        ]
    }

    @discardableResult
    private static func makeProgram(_ context: ModelContext) -> TrainingProgram {
        let program = TrainingProgram()
        program.title = "Upper / Lower"
        program.splitKey = "split.upperLower"
        program.daysPerWeek = 4
        program.isActive = true
        program.goals = [.buildMuscle, .buildStrength]
        program.experience = .intermediate
        program.priorityGroups = [.chest, .back]
        program.currentVersion = 3
        program.completedWeeks = 12
        context.insert(program)

        for (index, spec) in templateSpecs.enumerated() {
            let template = WorkoutTemplate()
            template.orderIndex = index
            template.titleKey = spec.titleKey
            template.customTitle = spec.title
            template.weekday = spec.weekday
            template.focusGroups = spec.focus
            template.pushPull = spec.pushPull
            template.estimatedMinutes = 62
            template.program = program
            context.insert(template)

            for (order, exercise) in spec.exercises.enumerated() {
                let planned = PlannedExercise()
                planned.exerciseID = exercise.id
                planned.orderIndex = order
                planned.targetSets = exercise.sets
                planned.repLower = exercise.low
                planned.repUpper = exercise.high
                planned.restSeconds = exercise.rest
                planned.targetRIR = 2
                if exercise.low == 1 { planned.targetDurationSeconds = 45 }
                planned.template = template
                context.insert(planned)
            }
        }

        for version in 1...3 {
            let record = ProgramVersion()
            record.versionNumber = version
            record.createdAt = Calendar.current.date(
                byAdding: .day, value: -92 + (version - 1) * 28, to: Date()
            ) ?? Date()
            record.reasonKey = version == 1 ? "explain.programCreated" : "explain.volumeIncreased"
            record.reasonArguments = version == 1 ? [] : ["Chest"]
            record.program = program
            context.insert(record)
        }
        return program
    }

    // MARK: - History

    /// Builds a plausible progression: loads creep up, reps wander inside the range, and the
    /// occasional session is missed — history that looks like training rather than a spreadsheet.
    private static func makeHistory(_ context: ModelContext, program: TrainingProgram, weeks: Int) {
        let calendar = Calendar.current
        let specs = templateSpecs
        var seed: UInt64 = 0x9E3779B97F4A7C15

        func next() -> Double {
            // SplitMix64 — deterministic so previews and UI tests are stable run to run.
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Double(z % 1000) / 1000.0
        }

        for weekOffset in stride(from: weeks - 1, through: 0, by: -1) {
            for (index, spec) in specs.enumerated() {
                // Roughly one session in twelve gets missed.
                if next() < 0.08 { continue }

                let daysAgo = weekOffset * 7 + (3 - index)
                guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
                let started = calendar.date(bySettingHour: 18, minute: 15, second: 0, of: date) ?? date

                let session = WorkoutSession()
                session.startedAt = started
                session.endedAt = started.addingTimeInterval(Double(3300 + Int(next() * 900)))
                session.status = .completed
                session.titleSnapshot = spec.title
                session.programID = program.id
                session.programVersion = 3
                session.focusGroups = spec.focus
                session.activeSeconds = Int(session.endedAt?.timeIntervalSince(started) ?? 3600)
                session.effortFeedback = next() < 0.2 ? .hard : .good
                context.insert(session)

                var volume: Double = 0
                var completed = 0
                var planned = 0

                for (order, exercise) in spec.exercises.enumerated() {
                    let exerciseSession = ExerciseSession()
                    exerciseSession.exerciseID = exercise.id
                    exerciseSession.exerciseNameSnapshot = exercise.name
                    exerciseSession.orderIndex = order
                    exerciseSession.targetRIR = 2
                    exerciseSession.restSeconds = exercise.rest
                    exerciseSession.trackingMode = exercise.low == 1 ? .duration : .weightAndReps
                    exerciseSession.workout = session
                    context.insert(exerciseSession)

                    let base = baseLoad(for: exercise.id)
                    // ~1.2 % per week, which is a realistic intermediate rate.
                    let progressed = base * (1 + 0.012 * Double(weeks - 1 - weekOffset))

                    for setIndex in 0..<exercise.sets {
                        planned += 1
                        let record = SetRecord()
                        record.setIndex = setIndex
                        record.kind = .working
                        record.isCompleted = true
                        record.completedAt = started.addingTimeInterval(Double(order * 420 + setIndex * 150))
                        record.targetReps = exercise.high

                        if exerciseSession.trackingMode == .duration {
                            record.durationSeconds = 40 + Int(next() * 20)
                            record.targetDurationSeconds = 45
                        } else {
                            let load = LoadRounding.round(
                                kilograms: progressed,
                                loadability: exercise.id == Sample.pullUp.0 ? .bodyweight : .barbell,
                                profile: .default
                            )
                            record.targetWeightKg = load
                            record.weightKg = load
                            record.reps = max(exercise.low, exercise.high - Int(next() * 3))
                            record.rir = Int(next() * 3)
                            volume += record.volumeKg
                        }
                        record.exerciseSession = exerciseSession
                        context.insert(record)
                        completed += 1
                    }
                }

                session.totalVolumeKg = volume
                session.completedSetCount = completed
                session.plannedSetCount = planned
            }
        }

        // Progression state for the main lifts, so the next session has a recommendation to show.
        for exercise in specs.flatMap(\.exercises) {
            let state = ProgressionState(exerciseID: exercise.id)
            state.workingWeightKg = LoadRounding.round(
                kilograms: baseLoad(for: exercise.id) * 1.15, loadability: .barbell, profile: .default
            )
            state.repRange = RepRange(exercise.low, exercise.high)
            state.needsCalibration = false
            state.consecutiveSuccesses = 1
            state.lastPerformedAt = Date().addingTimeInterval(-3 * 86400)
            state.bestEstimatedOneRepMaxKg = OneRepMaxCalculator.estimate(
                weightKg: baseLoad(for: exercise.id) * 1.15, reps: 8
            )
            context.insert(state)
        }

        // A handful of records so the PR screens have something real to show.
        for exercise in [Sample.benchPress, Sample.squat, Sample.deadlift] {
            let record = PersonalRecord()
            record.exerciseID = exercise.0
            record.exerciseNameSnapshot = exercise.1
            record.kind = .heaviestWeight
            record.value = baseLoad(for: exercise.0) * 1.15
            record.repsContext = 5
            record.previousValue = baseLoad(for: exercise.0) * 1.10
            record.achievedAt = Date().addingTimeInterval(-6 * 86400)
            context.insert(record)
        }
    }

    private static func baseLoad(for exerciseID: String) -> Double {
        switch exerciseID {
        case Sample.deadlift.0: 120
        case Sample.squat.0: 100
        case Sample.benchPress.0: 75
        case Sample.bentOverRow.0: 65
        case Sample.romanianDeadlift.0: 85
        case Sample.latPulldown.0, Sample.seatedRow.0: 60
        case Sample.inclineDumbbellPress.0: 26
        case Sample.legExtension.0, Sample.legCurl.0: 45
        case Sample.lunge.0: 20
        case Sample.calfRaise.0: 24
        case Sample.pushdown.0: 30
        case Sample.bicepsCurl.0, Sample.hammerCurl.0: 14
        case Sample.lateralRaise.0: 9
        case Sample.pullUp.0: 0
        default: 20
        }
    }

    private static func makeActiveSession(_ context: ModelContext, program: TrainingProgram) {
        let spec = templateSpecs[0]
        let session = WorkoutSession()
        session.startedAt = Date().addingTimeInterval(-1450)
        session.status = .inProgress
        session.titleSnapshot = spec.title
        session.programID = program.id
        session.focusGroups = spec.focus
        session.resumeExerciseIndex = 1
        session.plannedSetCount = spec.exercises.reduce(0) { $0 + $1.sets }
        context.insert(session)

        for (order, exercise) in spec.exercises.enumerated() {
            let exerciseSession = ExerciseSession()
            exerciseSession.exerciseID = exercise.id
            exerciseSession.exerciseNameSnapshot = exercise.name
            exerciseSession.orderIndex = order
            exerciseSession.targetRIR = 2
            exerciseSession.restSeconds = exercise.rest
            exerciseSession.trackingMode = exercise.low == 1 ? .duration : .weightAndReps
            exerciseSession.workout = session
            context.insert(exerciseSession)

            let load = LoadRounding.round(
                kilograms: baseLoad(for: exercise.id) * 1.15, loadability: .barbell, profile: .default
            )
            for setIndex in 0..<exercise.sets {
                let record = SetRecord()
                record.setIndex = setIndex
                record.kind = .working
                record.targetReps = exercise.high
                record.targetWeightKg = load
                // The first exercise is done and the second is halfway through.
                let isDone = order == 0 || (order == 1 && setIndex < 2)
                if isDone {
                    record.isCompleted = true
                    record.completedAt = Date().addingTimeInterval(Double(-1400 + order * 400 + setIndex * 140))
                    record.weightKg = load
                    record.reps = exercise.high - setIndex
                    record.rir = 2
                    session.completedSetCount += 1
                    session.totalVolumeKg += record.volumeKg
                }
                record.exerciseSession = exerciseSession
                context.insert(record)
            }
        }
    }

    // MARK: - Body metrics

    private static func makeBodyWeightHistory(_ context: ModelContext, days: Int) {
        var seed: UInt64 = 0x243F6A8885A308D3
        func noise() -> Double {
            seed &+= 0x9E3779B97F4A7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return (Double((z ^ (z >> 31)) % 1000) / 1000.0 - 0.5) * 1.4
        }
        for dayOffset in stride(from: days, through: 0, by: -1) {
            // Two thirds of days get a reading — nobody weighs in every single morning.
            if dayOffset % 3 == 1 { continue }
            guard let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let trend = 76.2 + (Double(days - dayOffset) / Double(days)) * 2.2
            let entry = BodyWeightEntry(
                date: Calendar.current.startOfDay(for: date).addingTimeInterval(7 * 3600),
                weightKg: (trend + noise()).rounded(toPlaces: 1)
            )
            context.insert(entry)
        }

        for dayOffset in 0..<10 {
            guard let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let entry = RecoveryEntry()
            entry.date = Calendar.current.startOfDay(for: date)
            entry.energy = 3 + (dayOffset % 3)
            entry.sleepQuality = 3 + (dayOffset % 2)
            entry.sleepHours = 7.0 + Double(dayOffset % 3) * 0.4
            entry.soreness = 2 + (dayOffset % 2)
            entry.motivation = 4
            context.insert(entry)
        }
    }

    private static func makePreferences(_ context: ModelContext) {
        let favourites = [Sample.benchPress.0, Sample.pullUp.0, Sample.squat.0]
        for id in favourites {
            let preference = ExercisePreference(exerciseID: id)
            preference.isFavorite = true
            preference.feedback = .love
            preference.timesPerformed = 26
            preference.lastPerformedAt = Date().addingTimeInterval(-3 * 86400)
            context.insert(preference)
        }
        let disliked = ExercisePreference(exerciseID: Sample.lunge.0)
        disliked.feedback = .dislike
        context.insert(disliked)
    }

    private static func makeAchievements(_ context: ModelContext) {
        for code in ["first_workout", "streak_7", "workouts_50", "first_100kg_lift"] {
            let achievement = Achievement(code: code)
            achievement.unlockedAt = Date().addingTimeInterval(-Double.random(in: 10...80) * 86400)
            context.insert(achievement)
        }
    }

    // MARK: - Nutrition

    private static func makeNutritionTarget(_ context: ModelContext) {
        let target = DailyNutritionTarget()
        target.kilocalories = 2760
        target.proteinG = 165
        target.carbsG = 320
        target.fatG = 82
        target.isActive = true
        target.rationaleKey = "nutrition.rationale.surplus"
        context.insert(target)
    }

    private struct SampleFood {
        let name: String
        let kcal: Double
        let protein: Double
        let carbs: Double
        let fat: Double
        let tags: [String]
    }

    private static let sampleFoods: [SampleFood] = [
        SampleFood(name: "Chicken breast, cooked", kcal: 165, protein: 31, carbs: 0, fat: 3.6, tags: ["meat", "poultry"]),
        SampleFood(name: "White rice, cooked", kcal: 130, protein: 2.7, carbs: 28, fat: 0.3, tags: []),
        SampleFood(name: "Rolled oats, dry", kcal: 379, protein: 13.2, carbs: 67.7, fat: 6.5, tags: []),
        SampleFood(name: "Whole egg", kcal: 143, protein: 12.6, carbs: 0.7, fat: 9.5, tags: ["egg"]),
        SampleFood(name: "Greek yoghurt, plain 2%", kcal: 73, protein: 10, carbs: 3.9, fat: 1.9, tags: ["dairy"]),
        SampleFood(name: "Banana", kcal: 89, protein: 1.1, carbs: 22.8, fat: 0.3, tags: []),
        SampleFood(name: "Olive oil", kcal: 884, protein: 0, carbs: 0, fat: 100, tags: []),
        SampleFood(name: "Broccoli, cooked", kcal: 35, protein: 2.4, carbs: 7.2, fat: 0.4, tags: []),
        SampleFood(name: "Whey protein powder", kcal: 375, protein: 78, carbs: 8, fat: 4, tags: ["dairy"]),
        SampleFood(name: "Salmon, cooked", kcal: 208, protein: 22.1, carbs: 0, fat: 13.4, tags: ["fish"]),
    ]

    private static func makeFoods(_ context: ModelContext) {
        for sample in sampleFoods {
            let food = FoodItem()
            food.name = sample.name
            food.catalogID = "sample_" + sample.name.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            food.source = .builtIn
            food.kilocaloriesPer100 = sample.kcal
            food.proteinGPer100 = sample.protein
            food.carbsGPer100 = sample.carbs
            food.fatGPer100 = sample.fat
            food.dietaryTags = sample.tags
            food.roleTags = sample.protein > 15 ? ["protein_source"] : ["carb_source"]
            context.insert(food)
        }
    }

    private static func makeNutritionHistory(_ context: ModelContext, days: Int) {
        let foods = (try? context.fetch(FetchDescriptor<FoodItem>())) ?? []
        guard !foods.isEmpty else { return }

        let plan: [(MealSlot, [(String, Double)])] = [
            (.breakfast, [("Rolled oats, dry", 80), ("Whole egg", 100), ("Banana", 120)]),
            (.lunch, [("Chicken breast, cooked", 180), ("White rice, cooked", 250), ("Broccoli, cooked", 150)]),
            (.dinner, [("Salmon, cooked", 160), ("White rice, cooked", 200), ("Olive oil", 10)]),
            (.snacks, [("Greek yoghurt, plain 2%", 200), ("Whey protein powder", 30)]),
        ]

        for dayOffset in 0..<days {
            guard let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let dayKey = DayKey.make(from: date)
            for (slot, items) in plan {
                for (order, item) in items.enumerated() {
                    guard let food = foods.first(where: { $0.name == item.0 }) else { continue }
                    let entry = FoodLogEntry()
                    entry.dayKey = dayKey
                    entry.loggedAt = Calendar.current.date(
                        bySettingHour: 8 + slot.sortIndex * 4, minute: order * 5, second: 0, of: date
                    ) ?? date
                    entry.mealSlot = slot
                    entry.orderIndex = order
                    entry.foodID = food.id
                    entry.foodNameSnapshot = food.name
                    entry.quantity = item.1
                    entry.unit = .grams
                    entry.macrosSnapshot = food.macros(forQuantity: item.1, unit: .grams)
                    entry.micronutrientsSnapshot = food.micronutrients(forQuantity: item.1, unit: .grams)
                    context.insert(entry)
                }
            }
            for hour in [9, 13, 17, 20] {
                let water = WaterLogEntry()
                water.dayKey = dayKey
                water.loggedAt = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
                water.milliliters = 500
                context.insert(water)
            }
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
