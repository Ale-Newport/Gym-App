import Foundation

// MARK: - Steps

/// One screen of first-run onboarding.
///
/// The enum is deliberately flat rather than a tree of optional sub-flows: every question the
/// engines need has to be asked exactly once, and a branching flow makes "did we ever ask about
/// equipment?" a question the code has to answer at runtime instead of by construction.
enum OnboardingStep: String, CaseIterable, Identifiable, Hashable, Sendable {
    case welcome
    case basics
    case goals
    case experience
    case availability
    case equipment
    case restrictions
    case nutrition
    case generating
    case summary

    var id: String { rawValue }

    var titleKey: String { "onboarding.step.\(rawValue).title" }
    var subtitleKey: String { "onboarding.step.\(rawValue).subtitle" }

    var symbolName: String {
        switch self {
        case .welcome: "sparkles"
        case .basics: "person.crop.circle"
        case .goals: "target"
        case .experience: "figure.strengthtraining.traditional"
        case .availability: "calendar"
        case .equipment: "dumbbell.fill"
        case .restrictions: "bandage.fill"
        case .nutrition: "fork.knife"
        case .generating: "wand.and.stars"
        case .summary: "checklist"
        }
    }

    /// Steps the user may move past without touching anything, because every field on them is
    /// genuinely optional. `Skip` is only ever offered here — putting it on a step that feeds a
    /// recommendation would be offering to make the app worse without saying so.
    var isSkippable: Bool {
        switch self {
        case .restrictions: true
        default: false
        }
    }

    /// Steps that ask the user something. The counter reads "3 of 7" over these, because the
    /// welcome, generation and review screens are the app's work rather than the user's.
    var collectsInput: Bool {
        switch self {
        case .welcome, .generating, .summary: false
        default: true
        }
    }

    /// The label on the footer's primary button.
    var primaryActionKey: String {
        switch self {
        case .welcome: "onboarding.action.start"
        case .nutrition: "onboarding.action.build"
        case .generating: "common.continue"
        case .summary: "onboarding.action.finish"
        default: "common.next"
        }
    }
}

// MARK: - Ordering

/// The ordered list of steps for one run of the flow, plus the movement rules between them.
///
/// Two rules are not simply "the next case in the enum", which is why ordering lives here rather
/// than in the container view:
///
/// 1. A user sent back through onboarding from Settings has already seen the welcome screen, so it
///    is dropped — re-reading the pitch for an app they are already using is friction, not warmth.
/// 2. `.generating` is never a *backwards* destination. Walking back from the review screen has to
///    land on the last question the user answered, not re-run the programming engine on the way.
struct OnboardingStepPlan: Hashable, Sendable {
    let steps: [OnboardingStep]

    static let firstRun = OnboardingStepPlan(steps: OnboardingStep.allCases)
    static let returning = OnboardingStepPlan(steps: OnboardingStep.allCases.filter { $0 != .welcome })

    static func plan(isReturningUser: Bool) -> OnboardingStepPlan {
        isReturningUser ? .returning : .firstRun
    }

    var first: OnboardingStep { steps.first ?? .basics }

    /// The steps the progress counter is expressed over.
    var questionSteps: [OnboardingStep] { steps.filter(\.collectsInput) }

    func index(of step: OnboardingStep) -> Int {
        steps.firstIndex(of: step) ?? 0
    }

    func next(after step: OnboardingStep) -> OnboardingStep? {
        let index = index(of: step) + 1
        return index < steps.count ? steps[index] : nil
    }

    /// The previous step a Back button should land on. `.generating` is skipped, so review → back
    /// returns to the last question rather than rebuilding the program.
    func previous(before step: OnboardingStep) -> OnboardingStep? {
        var index = index(of: step) - 1
        while index >= 0, steps[index] == .generating { index -= 1 }
        return index >= 0 ? steps[index] : nil
    }

    /// One-based position of `step` among the questions, or `nil` on a screen that asks nothing.
    func questionNumber(of step: OnboardingStep) -> Int? {
        guard let index = questionSteps.firstIndex(of: step) else { return nil }
        return index + 1
    }

    var questionCount: Int { questionSteps.count }

    /// 0…1 for the progress bar. Uses position in the full plan so the bar keeps moving across the
    /// generation and review screens instead of sitting pinned at 100 % for the last two taps.
    func progress(at step: OnboardingStep) -> Double {
        guard steps.count > 1 else { return 1 }
        return Double(index(of: step)) / Double(steps.count - 1)
    }
}

// MARK: - Schedule suggestions

/// Turns "I can train N days a week" into which days those should be.
///
/// Spacing matters more than which particular days: two hard sessions back to back leave the second
/// one under-recovered, so the suggestions spread the load and keep the weekend intact where the
/// count allows it. The user can always override — this only seeds the picker.
enum OnboardingSchedule {

    static func suggestedWeekdays(count: Int) -> [Weekday] {
        switch max(1, min(count, 7)) {
        case 1: [.wednesday]
        case 2: [.monday, .thursday]
        case 3: [.monday, .wednesday, .friday]
        case 4: [.monday, .tuesday, .thursday, .friday]
        case 5: [.monday, .tuesday, .wednesday, .friday, .saturday]
        case 6: [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        default: Weekday.orderedMondayFirst
        }
    }

    /// Session lengths offered as one-tap choices. Anything outside these is still reachable through
    /// the stepper; these are just the answers people actually give.
    static let sessionMinuteOptions = [30, 45, 60, 75, 90, 120]

    /// Meals-per-day choices. Above six the day stops being meals and becomes grazing, which the
    /// nutrition engine models as four slots anyway.
    static let mealsPerDayOptions = [2, 3, 4, 5, 6]
}

// MARK: - Curated option lists

/// The subsets of the taxonomies that are worth putting in front of somebody during onboarding.
///
/// The full enums are exhaustive because the dataset is; a first-run questionnaire that offered all
/// twenty-nine movement patterns would be answered by nobody. These lists are the ones a user can
/// recognise in their own body.
enum OnboardingOptions {

    /// Patterns a user can meaningfully say "not that one" about.
    static let avoidablePatterns: [MovementPattern] = [
        .verticalPush, .horizontalPush, .verticalPull, .horizontalPull,
        .squat, .hinge, .lunge, .carry, .hipThrust, .calfRaise, .cardio
    ]

    /// Allergen tags present in the bundled food database, plus the dietary tags people are most
    /// often allergic to. Both sets are matched identically by `NutritionProfileSnapshot`.
    static let allergenTags = [
        "peanut", "nuts", "gluten", "dairy", "egg", "soy", "fish", "shellfish", "seafood", "sesame"
    ]

    /// Intolerances are treated as hard exclusions too — the app is in no position to judge how much
    /// of an intolerance is "a bit".
    static let intoleranceTags = ["dairy", "gluten", "egg", "soy", "honey"]

    /// Food groups people commonly ask never to be suggested.
    static let excludableFoodTags = ["meat", "poultry", "fish", "seafood", "dairy", "egg", "honey", "supplement"]

    /// Plate sizes offered when the user has a barbell, in kilograms. Anything smaller than 1.25 kg
    /// is a micro-plate most gyms do not stock, so it is off by default rather than absent.
    static let plateOptionsKg: [Double] = [25, 20, 15, 10, 5, 2.5, 1.25, 0.5]
    /// The same rack in a gym stocked in pounds. Offering 20 kg plates to somebody whose gym has
    /// 45s means every rounded recommendation lands on a weight they cannot actually load.
    static let plateOptionsLb: [Double] = [45, 35, 25, 10, 5, 2.5, 1.25]

    /// The gap between adjacent dumbbells. Drives the generated ladder rather than being stored.
    static let dumbbellStepOptionsKg: [Double] = [1, 2, 2.5, 5]
    static let dumbbellStepOptionsLb: [Double] = [2.5, 5, 10]

    /// Kettlebell ladders are near-universal, so they are offered as toggles over the standard set.
    static let kettlebellOptionsKg: [Double] = [4, 8, 12, 16, 20, 24, 28, 32, 40]
    static let kettlebellOptionsLb: [Double] = [10, 15, 20, 25, 35, 45, 55, 70]

    /// Builds a dumbbell ladder from the smallest pair upwards. Real racks thin out at the top, so
    /// the step doubles past 40 kg rather than pretending every 2 kg increment exists to 60.
    static func dumbbellLadder(step: Double, maximum: Double = 50) -> [Double] {
        guard step > 0 else { return EquipmentIncrements.default.availableDumbbellsKg }
        var values: [Double] = []
        var current = step
        while current <= maximum {
            values.append((current * 100).rounded() / 100)
            current += current >= 40 ? step * 2 : step
        }
        return values.isEmpty ? EquipmentIncrements.default.availableDumbbellsKg : values
    }

    /// Benchmark lifts used to seed first-session loads, in the order they are offered.
    ///
    /// Matching is by name against the catalogue rather than by hard-coded identifier: the dataset
    /// is regenerated from an upstream source, and an id that disappears would silently drop the
    /// question. A name match that finds nothing simply offers one fewer lift.
    static let strengthSeedQueries: [(labelKey: String, terms: [String])] = [
        ("onboarding.seed.squat", ["barbell full squat", "barbell squat"]),
        ("onboarding.seed.bench", ["barbell bench press"]),
        ("onboarding.seed.deadlift", ["barbell deadlift"]),
        ("onboarding.seed.overheadPress", ["barbell standing military press", "barbell shoulder press"]),
        ("onboarding.seed.row", ["barbell bent over row", "barbell row"]),
        ("onboarding.seed.pulldown", ["cable pulldown", "lever front pulldown"])
    ]
}
