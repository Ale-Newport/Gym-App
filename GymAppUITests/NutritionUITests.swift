import XCTest

/// The things a user logs outside a workout: food, water and body mass.
///
/// Two of the tests here are expected to fail against the current build, and they are written to
/// fail loudly rather than to be skipped. `NutritionHubView` is a one-line placeholder —
/// `Text("NutritionHubView")` — and nothing in the app assembles `MacroRingsHeader`,
/// `MealSectionView` and `AddFoodFlowView` into a screen, so the Nutrition tab has no day log and
/// there is no reachable path to log a food item. The product spec names that flow, so the spec is
/// what these tests assert; see the suite summary for the defect write-up.
final class NutritionUITests: ForgeUITestCase {

    // MARK: - Logging food (documented defect)

    /// PRODUCTION DEFECT — expected to fail.
    ///
    /// The Nutrition tab is wired to `NutritionHubView`, which returns `Text("NutritionHubView")`.
    /// A developer placeholder is on screen where the day's food log should be.
    func testNutritionTabShowsTodaysFoodLogRatherThanADeveloperPlaceholder() {
        launch(.fullNutritionDay)
        openTab(EN.Tab.nutrition)

        // Give the tab a moment to render whatever it is going to render.
        _ = waitUntil("the nutrition tab settles", timeout: Timeout.quick) {
            self.app.staticTexts[EN.Nutrition.placeholder].exists
        }

        XCTAssertFalse(
            app.staticTexts[EN.Nutrition.placeholder].exists,
            """
            The Nutrition tab is showing the raw placeholder "\(EN.Nutrition.placeholder)", \
            which means NutritionHubView has regressed to the development shell and none of the \
            day log is reachable.
            """
        )
    }

    /// The whole logging flow: open a meal, search the bundled database, pick a portion, and watch
    /// the day's energy total move. This is the path a user walks several times a day, so it is the
    /// one worth asserting end to end.
    func testLoggingAFoodItemChangesTodaysTotals() {
        launch(.emptyNutritionDay)
        openTab(EN.Tab.nutrition)

        // The whole energy picture is one accessibility element, addressed by identifier: its label
        // is a sentence ("Eaten 1,240 kcal of 2,760…"), which is what makes a change observable.
        let energy = app.descendants(matching: .any)
            .matching(identifier: "nutritionLog.energySummary").firstMatch
        awaitExistence(energy, "Today's energy total")
        let before = energy.label

        let addFood = button(labelBeginningWith: EN.Nutrition.addFood)
        awaitExistence(addFood, "An add-food control on one of the meal sections")
        tap(addFood, "The add food control")

        // The sheet opens on a source picker — Search, Recent, Favourites, Saved meals, Recipes,
        // My foods — so the search source has to be chosen before there is a field to type in.
        let searchSource = app.buttons["Search"]
        awaitExistence(searchSource, "The Search source on the add-food sheet")
        tap(searchSource, "The Search source")

        // The bundled database answers offline, so a plain search is enough to reach a real food.
        let search = app.textFields["nutritionLog.searchField"]
        awaitExistence(search, "The food search field")
        search.tap()
        search.typeText("banana")

        // Addressed by identifier: a row's spoken label is the food and its macros, which is right
        // for VoiceOver and no use for matching "whatever came back first".
        let result = app.buttons.matching(identifier: "nutritionLog.foodRow").firstMatch
        awaitExistence(result, "A search result for banana", timeout: Timeout.engine)
        tap(result, "The first food in the search results")

        // The portion editor opens on a sensible default, so committing it is the common path.
        let log = button(labelBeginningWith: EN.Nutrition.logFood)
        awaitExistence(log, "The portion editor's log button", timeout: Timeout.engine)
        tap(log, "The log button on the portion editor")

        let changed = waitUntil("the day total changes", timeout: Timeout.engine) {
            let current = self.app.descendants(matching: .any)
                .matching(identifier: "nutritionLog.energySummary").firstMatch
            return current.exists && current.label != before
        }
        XCTAssertTrue(changed, "Logging a food item left today's energy total unchanged.")
    }

    // MARK: - Logging water

    /// Water is the one part of the nutrition day that *is* reachable — through Home's summary card
    /// rather than the Nutrition tab — so it is the only place the "log something, watch the day
    /// total move" behaviour can be tested end to end today.
    func testLoggingWaterFromHomeUpdatesTodaysTotal() {
        launch(.emptyNutritionDay)
        openTab(EN.Tab.home)

        let waterRow = anyElement(labelBeginningWith: EN.Home.water)
        awaitExistence(waterRow, "The water row on Home's nutrition card")
        scrollIntoView(waterRow)

        let before = waterRow.label
        XCTAssertTrue(
            before.contains("0 of "),
            "The fixture's day should start with no water logged, but the card read: \(before)"
        )

        tap(app.buttons[EN.Home.addWater], "The add water button")

        let changed = waitUntil("the water total changes") {
            let current = self.anyElement(labelBeginningWith: EN.Home.water)
            return current.exists && current.label != before
        }
        XCTAssertTrue(changed, "Logging water left the day's water total reading '\(before)'.")

        let after = anyElement(labelBeginningWith: EN.Home.water).label
        XCTAssertTrue(
            after.contains("250 of "),
            "Adding 250 ml should leave 250 ml on the day. The card read: \(after)"
        )
    }

    // MARK: - Logging body weight

    /// The `activeWorkout` fixture has training history but no weigh-ins, so the body-weight screen
    /// opens on its empty state — which makes "one reading was added" observable without depending
    /// on how many readings a fixture happens to carry.
    func testLoggingABodyWeightAddsTheReadingToTheChart() {
        launch(.activeWorkout)
        openTab(EN.Tab.progress)

        let card = row(labelBeginningWith: EN.Progress.bodyWeight)
        tap(card, "The body weight card on the Progress tab")

        awaitExistence(app.navigationBars[EN.Progress.bodyWeight], "The body weight screen")
        awaitExistence(
            app.staticTexts[EN.Progress.noReadingsTitle],
            "The body weight screen's empty state"
        )

        // Two controls carry this label — the toolbar plus and the empty state's button — so the
        // identifier is what picks one.
        tap(app.buttons["progress.weight.add.empty"], "The log body weight button")
        awaitExistence(app.navigationBars[EN.Progress.logBodyWeight], "The weigh-in sheet")

        let save = app.navigationBars[EN.Progress.logBodyWeight].buttons[EN.Common.save]
        awaitExistence(save, "The save button on the weigh-in sheet")
        XCTAssertFalse(
            save.isEnabled,
            "An empty weigh-in sheet allowed Save, so a reading with no weight could be stored."
        )

        let field = app.textFields[EN.Progress.weightFieldKg]
        tap(field, "The weight field")
        field.typeText("82.4")

        awaitEnabled(save, "Save once a weight was entered")
        save.tap()

        awaitDisappearance(app.navigationBars[EN.Progress.logBodyWeight], "The weigh-in sheet")
        awaitDisappearance(
            app.staticTexts[EN.Progress.noReadingsTitle],
            "The body weight empty state after a reading was logged"
        )
        awaitExistence(
            anyElement(labelContaining: "82.4"),
            "The 82.4 kg reading that was just logged"
        )
    }
}
