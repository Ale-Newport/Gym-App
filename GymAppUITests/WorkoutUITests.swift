import XCTest

/// The training loop: seeing the program, getting into a session, logging a set, changing an
/// exercise mid-session and closing the session out.
///
/// The in-session tests all start from the `activeWorkout` fixture, which leaves a real session in
/// progress with the first exercise finished and the second half done. That matters for
/// determinism: resuming a session that already exists does not depend on which weekday the tests
/// happen to run on, and the six weeks of history behind it mean the progression engine has
/// something to reason from rather than stopping to ask for a calibration set.
final class WorkoutUITests: ForgeUITestCase {

    // MARK: - The program is visible

    func testTheGeneratedProgramIsVisibleAsSessionsYouCanStart() {
        launch(.freshProgram)
        openTab(EN.Tab.workout)

        tap(app.buttons[EN.WorkoutHub.quickStart], "The quick start button")

        awaitExistence(
            app.navigationBars[EN.WorkoutHub.quickStart],
            "The quick start sheet"
        )
        awaitExistence(
            app.staticTexts[EN.WorkoutHub.fromProgram],
            "The 'From your program' section — a generated program should offer its sessions here"
        )

        // Every session in the program is offered with its exercise and set counts. Matching on the
        // shape of that line rather than on a session's name keeps the test honest about what the
        // engine produced.
        let sessionSummary = firstMatchingText(".*[0-9]+ exercises · [0-9]+ sets.*")
        XCTAssertNotNil(
            sessionSummary,
            "Quick start listed no session from the program, so nothing was generated to train."
        )
    }

    // MARK: - Starting from Home

    func testStartingTodaysWorkoutFromHomeOpensTheLiveWorkout() {
        launch(.freshProgram)

        let action = startWorkoutFromHome()

        awaitActiveWorkout()
        XCTAssertTrue(
            app.navigationBars.buttons[EN.Active.finish].exists,
            "The live workout opened from Home (via '\(action)') but offered no way to finish it."
        )
    }

    // MARK: - Logging a set

    func testCompletingASetStartsTheRestTimer() {
        launch(.activeWorkout)
        startWorkoutFromHome()
        awaitActiveWorkout()

        let skipRest = app.buttons[EN.Active.skipRest]
        XCTAssertFalse(
            skipRest.exists,
            "A rest timer was already running before any set was logged."
        )

        let completeSet = button(labelBeginningWith: EN.Active.completeSet)
        tap(completeSet, "The complete set button")

        // A movement with no history asks how the set felt before it starts resting; the fixture has
        // history, so this is a no-op, but the flow under test is what happens after the answer.
        dismissCalibrationIfPresented()

        awaitExistence(skipRest, "The rest timer's skip control after a set was logged")
        XCTAssertTrue(
            app.staticTexts[EN.Active.restTitle].exists,
            "The rest countdown appeared without its 'Rest' heading."
        )
        XCTAssertTrue(
            app.buttons[EN.Active.addRest].exists,
            "The rest countdown appeared without its adjustment controls."
        )

        tap(skipRest, "The skip rest button")
        awaitDisappearance(skipRest, "The rest timer after it was skipped")
    }

    // MARK: - Substituting mid-workout

    func testSwappingAnExerciseMidWorkoutReplacesItInTheSession() {
        launch(.activeWorkout)
        startWorkoutFromHome()
        awaitActiveWorkout()

        XCTAssertFalse(
            anyElement(labelContaining: EN.Active.substitutedFrom).exists,
            "The session already showed a substitution before one was made."
        )

        tap(app.buttons[EN.Active.exerciseOptions], "The exercise options menu")
        tap(app.buttons[EN.Active.swapExercise], "The 'Swap this exercise' menu item")

        awaitExistence(app.navigationBars[EN.Active.swapTitle], "The substitution sheet")

        // Each alternative collapses to a summary that opens into a preview; the disclosure value is
        // the one handle on those cards that does not depend on which exercise the engine ranked
        // first. The active exercise card behind the sheet carries the same value, so it is excluded
        // by name.
        let alternative = app.buttons.matching(
            NSPredicate(format: "value == %@ AND label != %@", "Show more", "How to do this")
        ).firstMatch
        tap(alternative, "The first suggested alternative", timeout: Timeout.standard)

        tap(app.buttons[EN.Active.useThisExercise], "The 'Use this exercise' button")

        awaitDisappearance(app.navigationBars[EN.Active.swapTitle], "The substitution sheet")
        awaitExistence(
            anyElement(labelContaining: EN.Active.substitutedFrom),
            "The 'Instead of …' note that says which exercise was replaced"
        )
    }

    // MARK: - Finishing

    func testFinishingAWorkoutShowsTheSummaryAndSavesTheSession() {
        launch(.activeWorkout)
        startWorkoutFromHome()
        awaitActiveWorkout()

        tap(app.navigationBars.buttons[EN.Active.finish], "The Finish button")

        awaitExistence(app.staticTexts[EN.Active.sessionComplete], "The session summary")
        XCTAssertTrue(
            app.staticTexts[EN.Active.effortTitle].exists,
            "The summary did not ask how the session felt, so autoregulation has nothing to work from."
        )

        let save = app.buttons[EN.Active.saveSession]
        awaitExistence(save, "The save button on the summary")
        scrollIntoView(save)
        XCTAssertFalse(
            save.isEnabled,
            "The session could be saved without rating the effort the summary says is required."
        )

        tap(app.buttons[EN.Active.effortGood], "The 'Good' effort rating")
        awaitEnabled(save, "Save session after the effort was rated")
        save.tap()

        awaitExistence(
            app.staticTexts[EN.Active.sessionSaved],
            "The confirmation that the session was stored",
            timeout: Timeout.engine
        )

        tap(app.buttons[EN.Common.done], "Done on the saved summary")

        awaitMainTabBar()
        awaitExistence(
            app.buttons[EN.Home.viewSummary],
            "Home's finished-session card, which is how a saved workout is reopened"
        )
    }

    // MARK: - Leaving without ending

    func testMinimisingTheWorkoutLeavesItRunningAndResumable() {
        launch(.activeWorkout)
        startWorkoutFromHome()
        awaitActiveWorkout()

        tap(app.buttons[EN.Active.minimise], "The minimise button")

        awaitMainTabBar()
        awaitExistence(
            button(labelBeginningWith: EN.Home.resume),
            "Home's resume control — closing the live screen must not end the workout"
        )

        tap(button(labelBeginningWith: EN.Home.resume), "The resume control")
        awaitActiveWorkout()
    }
}
