import XCTest

/// First run, start to finish.
///
/// Onboarding is the only part of the app a user cannot skip, and the only place where a wrong
/// answer is unrecoverable without starting again — so these tests care about two things: that the
/// flow reaches the tab bar at all, and that it refuses to move past a question it genuinely needs
/// an answer to.
///
/// Everything except the goals step ships a usable default (`OnboardingViewModel` seeds a height, a
/// body mass, a birth date, three training days and a full gym), which is why the walk below only
/// answers one question and taps through the rest.
final class OnboardingUITests: ForgeUITestCase {

    // MARK: - Chrome

    /// The footer action. Its label changes from step to step — "Get started", "Next",
    /// "Build my program", "Start training" — so it is addressed by identifier.
    private var onboardingPrimary: XCUIElement {
        app.buttons["onboarding.primary"]
    }

    /// The header back control. Addressed by identifier because the goals step offers a muscle
    /// group called "Back", and the label alone matches both.
    private var onboardingBack: XCUIElement {
        app.buttons["onboarding.back"]
    }

    // MARK: - The whole flow

    func testCompletingOnboardingEndsOnTheMainTabBar() {
        launch(.newUser)

        answerEveryQuestion()
        buildTheProgram()

        awaitExistence(app.staticTexts[EN.Onboarding.summaryTitle], "The review step")
        tap(onboardingPrimary, "The Start training button")

        awaitMainTabBar()
        for title in EN.Tab.all {
            XCTAssertTrue(
                tabButton(title).exists,
                "The \(title) tab is missing from the tab bar after onboarding finished."
            )
        }
    }

    // MARK: - A program is generated and visible

    func testOnboardingShowsTheGeneratedProgramOnTheReviewStep() {
        launch(.newUser)

        answerEveryQuestion()
        buildTheProgram()

        awaitExistence(app.staticTexts[EN.Onboarding.summaryTitle], "The review step")

        let programSection = app.staticTexts[EN.Onboarding.programSection]
        awaitExistence(programSection, "The 'Your program' section of the review step")

        XCTAssertFalse(
            app.staticTexts[EN.Onboarding.noProgramTitle].exists,
            "The review step says there is no program, so generation produced nothing to show."
        )
        XCTAssertTrue(
            app.staticTexts[EN.Onboarding.readyTitle].exists,
            "The review step never offered the confirmation card, so the program cannot be accepted."
        )
    }

    // MARK: - Validation

    func testTheGoalsStepWillNotAdvanceUntilAGoalIsChosen() {
        launch(.newUser)

        tap(onboardingPrimary, "The Get started button")
        awaitExistence(app.staticTexts[EN.Onboarding.basicsTitle], "The basics step")
        tap(onboardingPrimary, "Next on the basics step")

        awaitExistence(app.staticTexts[EN.Onboarding.goalsTitle], "The goals step")

        let next = onboardingPrimary
        awaitExistence(next, "The Next button on the goals step")
        XCTAssertFalse(
            next.isEnabled,
            "Next was enabled on the goals step with no goal chosen, so an empty goal list can reach the engine."
        )
        XCTAssertTrue(
            app.staticTexts[EN.Onboarding.goalsEmptyHint].exists,
            "The goals step disabled Next without saying why."
        )

        tap(button(labelBeginningWith: EN.Onboarding.goalBuildMuscle), "The Build muscle goal")

        awaitEnabled(next, "Next after a goal was chosen")
        XCTAssertFalse(
            app.staticTexts[EN.Onboarding.goalsEmptyHint].exists,
            "The 'pick at least one goal' hint stayed on screen after a goal was chosen."
        )
    }

    // MARK: - Moving backwards

    func testBackReturnsToThePreviousQuestionWithTheAnswerStillOnIt() {
        launch(.newUser)

        tap(onboardingPrimary, "The Get started button")
        awaitExistence(app.staticTexts[EN.Onboarding.basicsTitle], "The basics step")
        tap(onboardingPrimary, "Next on the basics step")

        awaitExistence(app.staticTexts[EN.Onboarding.goalsTitle], "The goals step")
        tap(button(labelBeginningWith: EN.Onboarding.goalBuildMuscle), "The Build muscle goal")

        tap(onboardingBack, "The back button")
        awaitExistence(app.staticTexts[EN.Onboarding.basicsTitle], "The basics step after going back")

        tap(onboardingPrimary, "Next on the basics step, second time")
        awaitExistence(app.staticTexts[EN.Onboarding.goalsTitle], "The goals step, second time")

        let goal = button(labelBeginningWith: EN.Onboarding.goalBuildMuscle)
        awaitExistence(goal, "The Build muscle goal after returning to the step")
        XCTAssertTrue(
            goal.isSelected,
            "The goal chosen before going back was not still selected on the way forward again."
        )
    }

    // MARK: - Steps

    /// Walks welcome → basics → goals → … → nutrition, answering the one question that has no
    /// default and accepting the defaults on the rest.
    private func answerEveryQuestion(file: StaticString = #filePath, line: UInt = #line) {
        awaitExistence(
            app.staticTexts[EN.Onboarding.welcomeTitle],
            "The welcome step",
            timeout: Timeout.launch,
            file: file, line: line
        )
        tap(onboardingPrimary, "The Get started button", file: file, line: line)

        advance(past: EN.Onboarding.basicsTitle, file: file, line: line)

        awaitExistence(app.staticTexts[EN.Onboarding.goalsTitle], "The goals step", file: file, line: line)
        tap(
            button(labelBeginningWith: EN.Onboarding.goalBuildMuscle),
            "The Build muscle goal",
            file: file, line: line
        )
        advance(past: EN.Onboarding.goalsTitle, file: file, line: line)

        advance(past: EN.Onboarding.experienceTitle, file: file, line: line)
        advance(past: EN.Onboarding.availabilityTitle, file: file, line: line)
        advance(past: EN.Onboarding.equipmentTitle, file: file, line: line)
        advance(past: EN.Onboarding.restrictionsTitle, file: file, line: line)

        awaitExistence(app.staticTexts[EN.Onboarding.nutritionTitle], "The food step", file: file, line: line)
    }

    /// Taps Next on the step titled `title`, having first waited for that step to be the one on
    /// screen and for Next to be usable.
    private func advance(past title: String, file: StaticString = #filePath, line: UInt = #line) {
        awaitExistence(app.staticTexts[title], "The '\(title)' step", file: file, line: line)
        let next = onboardingPrimary
        awaitEnabled(next, "Next on the '\(title)' step", file: file, line: line)
        next.tap()
        // The container reuses one button for every step, so waiting for the *previous* title to go
        // is the only way to know the tap landed before the next assertion runs.
        awaitDisappearance(app.staticTexts[title], "The '\(title)' step", file: file, line: line)
    }

    /// Runs the programming engine and waits for it to hand back a plan.
    private func buildTheProgram(file: StaticString = #filePath, line: UInt = #line) {
        tap(onboardingPrimary, "The Build my program button", file: file, line: line)

        let proceed = app.buttons[EN.Common.continue]
        awaitEnabled(
            proceed,
            "Continue on the generating step",
            timeout: Timeout.engine,
            file: file, line: line
        )
        proceed.tap()
    }
}
