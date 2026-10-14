import Foundation
import SwiftData
import Testing
@testable import GymApp

/// The first-run flow's rules: what it asks, in what order, and — above all — what it will and will
/// not switch on without the user's say-so.
@MainActor
@Suite("Onboarding flow")
struct OnboardingFlowTests {

    private func makeModel() throws -> (OnboardingViewModel, ModelContext) {
        let container = try PersistenceController.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(UserSettings())
        context.insert(UserProfile())
        context.insert(EquipmentProfile())
        try context.save()
        let model = OnboardingViewModel()
        model.load(context: context)
        return (model, context)
    }

    // MARK: - The plan

    @Test("A first run opens with the welcome and asks five questions")
    func firstRunShape() {
        let plan = OnboardingStepPlan.firstRun
        #expect(plan.first == .welcome)
        #expect(plan.questionCount == 5)
        #expect(plan.steps.last == .ready)
        #expect(plan.questionSteps == [.about, .goal, .week, .gear, .reminders])
    }

    @Test("Running setup again drops the welcome")
    func returningUsersSkipTheWelcome() {
        #expect(!OnboardingStepPlan.plan(isReturningUser: true).steps.contains(.welcome))
        #expect(OnboardingStepPlan.plan(isReturningUser: false).steps.contains(.welcome))
    }

    @Test("Moving through the plan visits every step once, in order")
    func orderingIsLinear() {
        let plan = OnboardingStepPlan.firstRun
        var visited: [OnboardingStep] = [plan.first]
        while let next = plan.next(after: visited.last!) { visited.append(next) }
        #expect(visited == plan.steps)
        #expect(plan.previous(before: plan.first) == nil)
        #expect(plan.progress(at: plan.first) == 0)
        #expect(plan.progress(at: plan.steps.last!) == 1)
    }

    // MARK: - Answers

    @Test("The goal step will not advance without a goal, and picking one replaces the last")
    func goalRules() throws {
        let (model, context) = try makeModel()
        model.advance(context: context)             // welcome → about
        model.advance(context: context)             // about → goal
        #expect(model.step == .goal)
        #expect(!model.canAdvance)

        model.selectGoal(.buildMuscle)
        #expect(model.canAdvance)
        model.selectGoal(.loseFat)
        #expect(model.goals == [.loseFat])
    }

    @Test("Focusing on a muscle group demands at least one group; any other goal clears them")
    func muscleFocusRules() throws {
        let (model, context) = try makeModel()
        model.advance(context: context)             // welcome → about
        model.advance(context: context)             // about → goal
        model.selectGoal(.targetMuscleGroup)
        #expect(model.step == .goal)
        #expect(model.blockingHint != nil)

        model.togglePriorityGroup(.chest)
        #expect(model.blockingHint == nil)

        model.selectGoal(.buildStrength)
        #expect(model.priorityGroups.isEmpty)
    }

    @Test("Age and metric/imperial are two views of the stored values")
    func derivedFields() throws {
        let (model, _) = try makeModel()

        model.ageYears = 41
        #expect(model.ageYears == 41)

        model.unitSystem = .imperial
        #expect(model.weightUnit == .pounds)
        #expect(model.heightUnit == .feetInches)
        model.unitSystem = .metric
        #expect(model.weightUnit == .kilograms)
        #expect(model.heightUnit == .centimeters)
    }

    @Test("Choosing the number of days seeds that many well-spaced days")
    func daysPerWeek() throws {
        let (model, _) = try makeModel()
        for count in 1...7 {
            model.setDaysPerWeek(count)
            #expect(model.availableWeekdays.count == count)
        }
    }

    // MARK: - Notifications

    @Test("Nothing is switched on until both the user and the system have said yes")
    func remindersNeedBothConsents() throws {
        let (model, context) = try makeModel()
        model.wantsTrainingReminder = true
        model.wantsRestAlert = true

        for outcome in [OnboardingNotificationOutcome.notAsked, .declined, .deniedBySystem] {
            model.recordNotificationOutcome(outcome)
            #expect(model.persist(.reminders, context: context))
            let settings = try ProfileRepository(context: context).settings()
            #expect(!settings.notificationsEnabled, "\(outcome) must not enable notifications")
            #expect(!settings.trainingReminderEnabled, "\(outcome) must not enable the training reminder")
        }

        model.recordNotificationOutcome(.granted)
        #expect(model.persist(.reminders, context: context))
        let settings = try ProfileRepository(context: context).settings()
        #expect(settings.notificationsEnabled)
        #expect(settings.trainingReminderEnabled)
        #expect(settings.restTimerNotificationEnabled)
    }

    @Test("A granted permission with the training reminder switched off schedules no training reminder")
    func grantedButNotWanted() throws {
        let (model, context) = try makeModel()
        model.wantsTrainingReminder = false
        model.wantsRestAlert = true
        model.recordNotificationOutcome(.granted)
        #expect(model.persist(.reminders, context: context))

        let settings = try ProfileRepository(context: context).settings()
        #expect(settings.notificationsEnabled)
        #expect(!settings.trainingReminderEnabled)
    }

    @Test("The chosen reminder time is what gets stored")
    func reminderTimeIsStored() throws {
        let (model, context) = try makeModel()
        var parts = DateComponents()
        parts.hour = 7
        parts.minute = 45
        model.reminderTime = try #require(Calendar.current.date(from: parts))
        model.recordNotificationOutcome(.granted)
        #expect(model.persist(.reminders, context: context))

        let settings = try ProfileRepository(context: context).settings()
        #expect(settings.trainingReminderHour == 7)
        #expect(settings.trainingReminderMinute == 45)
    }

    @Test("Wanting no reminder at all is a complete answer")
    func wantsAnyReminder() throws {
        let (model, _) = try makeModel()
        model.wantsTrainingReminder = false
        model.wantsRestAlert = false
        #expect(!model.wantsAnyReminder)
    }

    // MARK: - Finishing

    @Test("Finishing marks onboarding complete and queues the guide")
    func finishQueuesTheGuide() throws {
        let (model, context) = try makeModel()
        GuidedTourStore.clearPending()
        defer { GuidedTourStore.clearPending() }
        model.selectGoal(.buildMuscle)

        #expect(model.finish(context: context))
        #expect(try ProfileRepository(context: context).profile().isOnboarded)
        #expect(GuidedTourStore.isPending)
    }
}
