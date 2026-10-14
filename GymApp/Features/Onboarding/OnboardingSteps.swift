import Foundation

// MARK: - Steps

/// One screen of first-run onboarding.
///
/// The flow asks for the least that lets the engines build a good first program — who you are, what
/// you want, when you can train, what you can train with — and leaves everything finer (plate
/// sizes, diet, exclusions, weekly budgets) to Settings, where it can be changed at any time. A
/// first launch that opens with twenty questions loses people before they have seen the app.
///
/// The enum is deliberately flat rather than a tree of optional sub-flows: every question the
/// engines need has to be asked exactly once, and a branching flow makes "did we ever ask about
/// equipment?" a question the code has to answer at runtime instead of by construction.
enum OnboardingStep: String, CaseIterable, Identifiable, Hashable, Sendable {
    case welcome
    case about
    case goal
    case week
    case gear
    case reminders
    case ready

    var id: String { rawValue }

    var titleKey: String { "start.step.\(rawValue).title" }
    var subtitleKey: String { "start.step.\(rawValue).subtitle" }

    var symbolName: String {
        switch self {
        case .welcome: "sparkles"
        case .about: "person.crop.circle"
        case .goal: "target"
        case .week: "calendar"
        case .gear: "dumbbell.fill"
        case .reminders: "bell.badge"
        case .ready: "checkmark.seal"
        }
    }

    /// Steps that ask the user something. The counter reads "3 of 5" over these, because the
    /// welcome and the result are the app's work rather than the user's.
    var collectsInput: Bool {
        switch self {
        case .welcome, .ready: false
        default: true
        }
    }

    /// The label on the footer's primary button.
    var primaryActionKey: String {
        switch self {
        case .welcome: "start.action.begin"
        case .reminders: "start.action.enableReminders"
        case .ready: "start.action.finish"
        default: "common.next"
        }
    }
}

// MARK: - Ordering

/// The ordered list of steps for one run of the flow, plus the movement rules between them.
///
/// A user sent back through onboarding from Settings has already seen the welcome screen, so it is
/// dropped — re-reading the pitch for an app they are already using is friction, not warmth.
struct OnboardingStepPlan: Hashable, Sendable {
    let steps: [OnboardingStep]

    static let firstRun = OnboardingStepPlan(steps: OnboardingStep.allCases)
    static let returning = OnboardingStepPlan(steps: OnboardingStep.allCases.filter { $0 != .welcome })

    static func plan(isReturningUser: Bool) -> OnboardingStepPlan {
        isReturningUser ? .returning : .firstRun
    }

    var first: OnboardingStep { steps.first ?? .about }

    /// The steps the progress counter is expressed over.
    var questionSteps: [OnboardingStep] { steps.filter(\.collectsInput) }

    func index(of step: OnboardingStep) -> Int {
        steps.firstIndex(of: step) ?? 0
    }

    func next(after step: OnboardingStep) -> OnboardingStep? {
        let index = index(of: step) + 1
        return index < steps.count ? steps[index] : nil
    }

    func previous(before step: OnboardingStep) -> OnboardingStep? {
        let index = index(of: step) - 1
        return index >= 0 ? steps[index] : nil
    }

    /// One-based position of `step` among the questions, or `nil` on a screen that asks nothing.
    func questionNumber(of step: OnboardingStep) -> Int? {
        guard let index = questionSteps.firstIndex(of: step) else { return nil }
        return index + 1
    }

    var questionCount: Int { questionSteps.count }

    /// 0…1 for the progress bar. Uses position in the full plan so the bar keeps moving across the
    /// result screen instead of sitting pinned at 100 % for the last tap.
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

    /// Session lengths offered as one-tap choices. Anything outside these is still reachable from
    /// Settings; these are just the answers people actually give.
    static let sessionMinuteOptions = [30, 45, 60, 75, 90]

    /// The equipment presets worth putting in front of somebody on day one. "Custom" is a
    /// Settings-level control: it asks for exactly what you own, which is a question for later.
    static let equipmentPresets: [GymSetupPreset] = [.fullGym, .limitedGym, .homeGym, .bodyweightOnly]

    /// The hour a training reminder defaults to, before the user has said when they train.
    static let defaultReminderHour = 18
}

// MARK: - Curated option lists

/// The subsets of the taxonomies that are worth putting in front of somebody during onboarding.
enum OnboardingOptions {

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
}
