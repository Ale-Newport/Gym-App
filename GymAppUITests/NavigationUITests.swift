import XCTest

/// Getting around: the tab bar, the exercise library, and the settings screens reached from Home.
///
/// These are the tests that catch a broken shell — a tab that opens on nothing, a push that never
/// lands, a settings change that is accepted but not shown back.
final class NavigationUITests: ForgeUITestCase {

    // MARK: - The tab bar

    func testEveryTabOpensAndBecomesTheSelectedTab() {
        launch(.seasonedUser)
        awaitMainTabBar()

        for title in EN.Tab.all {
            tap(tabButton(title), "The \(title) tab")
            let selected = waitUntil("the \(title) tab becomes selected") {
                self.tabButton(title).isSelected
            }
            XCTAssertTrue(selected, "Tapping the \(title) tab did not select it.")
        }

        // Each tab that owns a screen names it in its navigation bar. Nutrition is deliberately not
        // asserted on here: its screen is an unbuilt placeholder, which `NutritionUITests` reports.
        openTab(EN.Tab.workout)
        awaitExistence(app.navigationBars[EN.WorkoutHub.title], "The Workout tab's screen")

        openTab(EN.Tab.exercises)
        awaitExistence(app.navigationBars[EN.Exercises.title], "The Exercises tab's screen")

        openTab(EN.Tab.progress)
        awaitExistence(app.navigationBars[EN.Progress.title], "The Progress tab's screen")

        openTab(EN.Tab.home)
        awaitExistence(app.buttons[EN.Home.profileButton], "The Home tab's screen")
    }

    func testTappingTheSelectedTabPopsItsNavigationStack() {
        launch(.seasonedUser)
        openSettings()

        // Home is already selected, so tapping it again is the "pop to root" gesture.
        tap(tabButton(EN.Tab.home), "The Home tab, while Home is already selected")

        awaitDisappearance(app.navigationBars[EN.Settings.title], "The Settings screen")
        awaitExistence(app.buttons[EN.Home.profileButton], "Home, back at the root of its stack")
    }

    // MARK: - The exercise library

    func testOpeningAnExerciseFromTheLibraryShowsItsDetailScreen() {
        launch(.seasonedUser)
        openTab(EN.Tab.exercises)
        awaitExistence(app.navigationBars[EN.Exercises.title], "The exercise library")

        let search = app.searchFields.firstMatch
        tap(search, "The library's search field")
        search.typeText(EN.Exercises.benchPressQuery)

        let result = button(labelBeginningWith: EN.Exercises.benchPressQuery)
        awaitExistence(result, "A search result for '\(EN.Exercises.benchPressQuery)'")

        // The row reads "<name>, <target> · <equipment>"; the name is what the detail screen titles
        // itself with, so it is read out of the row rather than hard-coded.
        let name = String(result.label.split(separator: ",").first ?? "")
        XCTAssertFalse(name.isEmpty, "The search result row had no readable name.")

        result.tap()

        awaitExistence(
            app.buttons[EN.Exercises.addToToday],
            "The exercise detail screen"
        )
        awaitExistence(
            anyElement(labelBeginningWith: name),
            "'\(name)' named on the detail screen it opened"
        )
        XCTAssertTrue(
            app.navigationBars.buttons[EN.Exercises.title].exists,
            "The detail screen was not pushed onto the library's navigation stack."
        )
    }

    func testSearchingForNothingShowsTheLibrarysEmptyState() {
        launch(.seasonedUser)
        openTab(EN.Tab.exercises)
        awaitExistence(app.navigationBars[EN.Exercises.title], "The exercise library")

        let search = app.searchFields.firstMatch
        tap(search, "The library's search field")
        search.typeText("zzzzqqqq")

        awaitExistence(
            app.staticTexts["Nothing matches"],
            "The library's empty state for a search with no results"
        )
        tap(app.buttons["Clear search and filters"], "The clear search button")
        awaitDisappearance(app.staticTexts["Nothing matches"], "The empty state after clearing")
    }

    // MARK: - Settings

    func testChangingTheLanguageInSettingsUpdatesTheInterface() {
        launch(.seasonedUser)
        openSettings()

        let languageRow = row(labelBeginningWith: EN.Settings.language)
        awaitExistence(languageRow, "The Language row in Settings")
        scrollIntoView(languageRow)
        let rowBefore = languageRow.label
        XCTAssertTrue(
            rowBefore.contains(EN.Settings.languageEnglish),
            "Settings did not show the language currently in force. It read: \(rowBefore)"
        )

        tap(languageRow, "The Language row in Settings")
        awaitExistence(app.navigationBars[EN.Settings.language], "The language screen")
        awaitExistence(app.staticTexts[EN.Settings.languagesHeader], "The list of languages")

        let english = app.buttons[EN.Settings.languageEnglish]
        let spanish = app.buttons[EN.Settings.languageSpanish]
        awaitExistence(english, "The English row")
        awaitExistence(spanish, "The Español row")
        XCTAssertTrue(english.isSelected, "The language screen did not mark the current language.")

        tap(spanish, "The Español row")

        let moved = waitUntil("the selection moves to Español") {
            spanish.exists && spanish.isSelected
        }
        XCTAssertTrue(moved, "Choosing Español did not select it.")
        XCTAssertFalse(
            english.isSelected,
            "English stayed selected after Español was chosen, so two languages are marked at once."
        )

        // From here the interface is genuinely in Spanish, so nothing may be matched by its English
        // label any more — including the navigation bar this screen was pushed from. That is the
        // whole point of the test, and it is why the assertions below are Spanish.
        let spanishScreenTitle = waitUntil("the screen title switches to Spanish") {
            self.app.navigationBars[ES.Settings.language].exists
        }
        XCTAssertTrue(
            spanishScreenTitle,
            "The language screen kept its English title after Español was chosen."
        )

        // Back out by the chevron rather than by a title, which has just changed underneath us.
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        awaitExistence(back, "The back button on the language screen")
        back.tap()

        awaitExistence(
            app.navigationBars[ES.Settings.title],
            "Ajustes — Settings, in Spanish, after choosing a language"
        )

        let changed = waitUntil("the Language row shows the new language") {
            self.row(labelBeginningWith: ES.Settings.language).exists
        }
        XCTAssertTrue(changed, "Settings still reports the old language.")

        // And the change reaches the whole app, not just the screen that made it.
        XCTAssertTrue(
            tabButton(ES.Tab.home).waitForExistence(timeout: Timeout.standard),
            "The tab bar kept its English titles after the language changed."
        )
    }

    func testSettingsIsReachedFromHomeAndReturnsToIt() {
        launch(.seasonedUser)
        openSettings()

        awaitExistence(app.staticTexts[EN.Settings.title], "The Settings title")

        goBack(from: EN.Settings.title)
        awaitExistence(app.buttons[EN.Home.profileButton], "Home, after leaving Settings")
        awaitMainTabBar()
    }
}
