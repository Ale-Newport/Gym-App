import XCTest

/// First run, start to finish.
///
/// Onboarding is the only part of the app a user cannot skip, so these tests care about three
/// things: that the flow reaches the tab bar at all, that it refuses to move past a question it
/// genuinely needs an answer to, and that it never asks iOS for notification permission before the
/// user has said yes on the app's own screen.
///
/// Everything except the goal step ships a usable default (`OnboardingViewModel` seeds a height, a
/// body mass, an age, three training days and a full gym), which is why the walk below only answers
/// one question and taps through the rest.
final class OnboardingUITests: ForgeUITestCase {

    // MARK: - Chrome

    /// The footer action. Its label changes from step to step — "Get started", "Next", "Turn on
    /// reminders", "Start training" — so it is addressed by identifier.
    private var onboardingPrimary: XCUIElement {
        app.buttons["onboarding.primary"]
    }

    /// The header back control. Addressed by identifier because the goal step offers tiles whose
    /// labels could collide with "Back", and the label alone is ambiguous.
    private var onboardingBack: XCUIElement {
        app.buttons["onboarding.back"]
    }

    private var notNow: XCUIElement {
        app.buttons["onboarding.notNow"]
    }

    /// The step's headline. Combined with its subtitle into one accessibility element, so it is
    /// matched by prefix.
    private func stepTitle(_ title: String) -> XCUIElement {
        anyElement(labelBeginningWith: title)
    }

    // MARK: - The whole flow

    func testCompletingOnboardingEndsOnTheMainTabBar() {
        launch(.newUser)

        answerEveryQuestion()
        awaitExistence(stepTitle(EN.Onboarding.readyTitle), "The plan step", timeout: Timeout.engine)
        awaitEnabled(onboardingPrimary, "Start training", timeout: Timeout.engine)
        onboardingPrimary.tap()

        awaitMainTabBar()
        dismissGuidedTourIfPresented()
        for title in EN.Tab.all {
            XCTAssertTrue(
                tabButton(title).exists,
                "The \(title) tab is missing from the tab bar after onboarding finished."
            )
        }
    }

    // MARK: - A program is generated and visible

    func testOnboardingShowsTheGeneratedProgramOnTheResultStep() {
        launch(.newUser)

        answerEveryQuestion()

        awaitExistence(stepTitle(EN.Onboarding.readyTitle), "The plan step", timeout: Timeout.engine)
        awaitExistence(
            app.staticTexts[EN.Onboarding.weekSection],
            "The 'Your week' section of the plan step",
            timeout: Timeout.engine
        )
        awaitEnabled(onboardingPrimary, "Start training", timeout: Timeout.engine)
    }

    // MARK: - Validation

    func testTheGoalStepWillNotAdvanceUntilAGoalIsChosen() {
        launch(.newUser)

        tap(onboardingPrimary, "The Get started button")
        awaitExistence(stepTitle(EN.Onboarding.aboutTitle), "The about-you step")
        tap(onboardingPrimary, "Next on the about-you step")

        awaitExistence(stepTitle(EN.Onboarding.goalTitle), "The goal step")

        let next = onboardingPrimary
        awaitExistence(next, "The Next button on the goal step")
        XCTAssertFalse(
            next.isEnabled,
            "Next was enabled on the goal step with no goal chosen, so an empty goal can reach the engine."
        )
        XCTAssertTrue(
            app.staticTexts[EN.Onboarding.goalEmptyHint].exists,
            "The goal step disabled Next without saying why."
        )

        tap(button(labelBeginningWith: EN.Onboarding.goalBuildMuscle), "The Build muscle goal")

        awaitEnabled(next, "Next after a goal was chosen")
        XCTAssertFalse(
            app.staticTexts[EN.Onboarding.goalEmptyHint].exists,
            "The 'pick a goal' hint stayed on screen after a goal was chosen."
        )
    }

    // MARK: - Moving backwards

    func testBackReturnsToThePreviousQuestionWithTheAnswerStillOnIt() {
        launch(.newUser)

        tap(onboardingPrimary, "The Get started button")
        awaitExistence(stepTitle(EN.Onboarding.aboutTitle), "The about-you step")
        tap(onboardingPrimary, "Next on the about-you step")

        awaitExistence(stepTitle(EN.Onboarding.goalTitle), "The goal step")
        tap(button(labelBeginningWith: EN.Onboarding.goalBuildMuscle), "The Build muscle goal")

        tap(onboardingBack, "The back button")
        awaitExistence(stepTitle(EN.Onboarding.aboutTitle), "The about-you step after going back")

        tap(onboardingPrimary, "Next on the about-you step, second time")
        awaitExistence(stepTitle(EN.Onboarding.goalTitle), "The goal step, second time")

        let goal = button(labelBeginningWith: EN.Onboarding.goalBuildMuscle)
        awaitExistence(goal, "The Build muscle goal after returning to the step")
        XCTAssertTrue(
            goal.isSelected,
            "The goal chosen before going back was not still selected on the way forward again."
        )
    }

    // MARK: - Notifications

    /// "Not now" is a complete answer. It must not raise the system permission prompt, because that
    /// prompt can only be shown once and a user who has just declined should never be spent on it.
    func testNotNowNeverRaisesTheSystemPermissionPrompt() {
        launch(.newUser)

        advanceToReminders()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        tap(notNow, "Not now on the reminders step")

        awaitExistence(stepTitle(EN.Onboarding.readyTitle), "The plan step", timeout: Timeout.engine)
        XCTAssertFalse(
            springboard.alerts.firstMatch.exists,
            "Declining reminders still raised a system alert."
        )
    }

    /// Saying yes asks iOS, and the flow continues whichever way iOS answers.
    func testTurningOnRemindersAsksTheSystemAndThenContinues() {
        launch(.newUser)

        advanceToReminders()

        tap(onboardingPrimary, "Turn on reminders")

        // The prompt appears only when the app has never asked; a simulator that already answered
        // it goes straight through, so a missing alert is not a failure.
        // The alert is SpringBoard's, in the simulator's language, so it is answered by position
        // rather than by the word "Allow": the confirming button is the last one in every locale.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: Timeout.quick) {
            let buttons = alert.buttons
            buttons.element(boundBy: buttons.count - 1).tap()
        }

        awaitExistence(stepTitle(EN.Onboarding.readyTitle), "The plan step", timeout: Timeout.engine)
    }

    // MARK: - The guide

    /// After setup the guide walks the five tabs, switching the screen behind it, and ends on the
    /// Workout tab.
    func testTheGuideWalksEveryTabAndEndsOnTheWorkoutTab() {
        launch(.newUser)

        answerEveryQuestion()
        awaitEnabled(onboardingPrimary, "Start training", timeout: Timeout.engine)
        onboardingPrimary.tap()
        awaitMainTabBar()

        let next = app.buttons["tour.next"]
        awaitExistence(anyElement(labelBeginningWith: EN.Tour.homeTitle), "The first guide card")

        let stops = [EN.Tour.workoutTitle, EN.Tour.exercisesTitle, EN.Tour.nutritionTitle, EN.Tour.progressTitle]
        for title in stops {
            tap(next, "Next on the guide")
            awaitExistence(anyElement(labelBeginningWith: title), "The guide card '\(title)'")
        }

        // The last card's action is "Start training", and it leaves the user on the Workout tab.
        tap(next, "Start training on the last guide card")
        awaitDisappearance(app.buttons["tour.skip"], "The guide")
        awaitExistence(screenTitle(EN.WorkoutHub.title), "The Workout tab after the guide")
    }

    func testSkippingTheGuideClosesIt() {
        launch(.newUser)

        answerEveryQuestion()
        awaitEnabled(onboardingPrimary, "Start training", timeout: Timeout.engine)
        onboardingPrimary.tap()
        awaitMainTabBar()

        let skip = app.buttons["tour.skip"]
        tap(skip, "Skip on the guide")
        awaitDisappearance(skip, "The guide")
    }

    // MARK: - Steps

    /// Walks welcome → about you → goal → week → equipment → reminders, answering the one question
    /// that has no default and accepting the defaults on the rest. Ends on the reminders step's
    /// "Not now", which is the answer that asks iOS for nothing.
    private func answerEveryQuestion(file: StaticString = #filePath, line: UInt = #line) {
        advanceToReminders(file: file, line: line)
        tap(notNow, "Not now on the reminders step", file: file, line: line)
    }

    /// Stops on the reminders step, with everything before it answered.
    private func advanceToReminders(file: StaticString = #filePath, line: UInt = #line) {
        awaitExistence(
            stepTitle(EN.Onboarding.welcomeTitle),
            "The welcome step",
            timeout: Timeout.launch,
            file: file, line: line
        )
        tap(onboardingPrimary, "The Get started button", file: file, line: line)

        advance(from: EN.Onboarding.aboutTitle, to: EN.Onboarding.goalTitle, file: file, line: line)

        tap(
            button(labelBeginningWith: EN.Onboarding.goalBuildMuscle),
            "The Build muscle goal",
            file: file, line: line
        )
        advance(from: EN.Onboarding.goalTitle, to: EN.Onboarding.weekTitle, file: file, line: line)
        advance(from: EN.Onboarding.weekTitle, to: EN.Onboarding.gearTitle, file: file, line: line)
        advance(from: EN.Onboarding.gearTitle, to: EN.Onboarding.remindersTitle, file: file, line: line)
    }

    /// Taps Next on the step titled `title`, having first waited for that step to be the one on
    /// screen and for Next to be usable, then waits for the following step to arrive.
    private func advance(
        from title: String,
        to nextTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        awaitExistence(stepTitle(title), "The '\(title)' step", file: file, line: line)
        let next = onboardingPrimary
        awaitEnabled(next, "Next on the '\(title)' step", file: file, line: line)
        next.tap()
        // The container reuses one button for every step, so waiting for the *next* title is the
        // only way to know the tap landed before the following assertion runs.
        awaitExistence(stepTitle(nextTitle), "The '\(nextTitle)' step", file: file, line: line)
    }
}
