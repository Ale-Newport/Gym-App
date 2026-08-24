import XCTest

// MARK: - Fixtures

/// Mirrors `PreviewSupport.Scenario`.
///
/// A UI-test bundle runs out of process and cannot `@testable import GymApp`, so the raw values are
/// repeated here. They are the contract `UITestLaunchSupport` parses `-uiTestScenario` against; a
/// typo produces an empty app rather than a crash, which is exactly the kind of silent failure
/// these names exist to prevent.
enum ForgeScenario: String {
    case newUser
    case freshProgram
    case seasonedUser
    case activeWorkout
    case emptyNutritionDay
    case fullNutritionDay
}

/// Waits are generous on purpose. A UI test that fails because a simulator was busy teaches nothing,
/// and a timeout only costs wall-clock time when something is genuinely broken.
enum Timeout {
    /// Something that should already be on screen.
    static let quick: TimeInterval = 10
    /// A transition, a sheet, or a round trip through the store.
    static let standard: TimeInterval = 30
    /// First launch: the exercise catalogue is parsed from JSON before anything renders.
    static let launch: TimeInterval = 180
    /// The programming engine scores the whole catalogue against the user's answers.
    static let engine: TimeInterval = 240
}

// MARK: - Strings

/// The English text these tests match on.
///
/// The app resolves every string through `LocalizationManager`, and only the `en` table is
/// populated, so English is what is on screen whatever the device is set to — the launch arguments
/// in `launch(_:)` pin it anyway. Naming the strings here keeps the assertions readable and gives
/// one place to update when copy changes.
///
/// Where a view offers an accessibility identifier these tests would use it instead. None of the
/// production views set one today; see the suite summary for the list worth adding.
enum EN {

    enum Tab {
        static let home = "Home"
        static let workout = "Workout"
        static let exercises = "Exercises"
        static let nutrition = "Nutrition"
        static let progress = "Progress"
        static let all = [home, workout, exercises, nutrition, progress]
    }

    enum Common {
        static let next = "Next"
        static let back = "Back"
        static let cancel = "Cancel"
        static let close = "Close"
        static let done = "Done"
        static let save = "Save"
        static let skip = "Skip"
        static let `continue` = "Continue"
        static let increase = "Increase"
        static let decrease = "Decrease"
    }

    enum Onboarding {
        static let welcomeTitle = "Welcome to Forge"
        static let basicsTitle = "About you"
        static let goalsTitle = "What you are training for"
        static let experienceTitle = "Your background"
        static let availabilityTitle = "Your week"
        static let equipmentTitle = "What you train with"
        static let restrictionsTitle = "Anything to avoid"
        static let nutritionTitle = "Food"
        static let summaryTitle = "Check it over"

        static let start = "Get started"
        static let build = "Build my program"
        static let finish = "Start training"

        static let goalBuildMuscle = "Build muscle"
        static let goalsEmptyHint = "Pick at least one goal."

        static let programSection = "Your program"
        static let noProgramTitle = "No program yet"
        static let readyTitle = "Ready when you are"
    }

    enum Home {
        static let profileButton = "Profile and settings"
        static let start = "Start workout"
        static let resume = "Resume workout"
        static let startLight = "Start a light session"
        static let trainAgain = "Train again"
        static let createProgram = "Create my program"
        static let viewProgram = "View program"
        static let viewSummary = "View summary"
        static let water = "Water"
        static let addWater = "Add 250 ml"
        static let nutritionCard = "Nutrition,"
    }

    enum WorkoutHub {
        static let title = "Workout"
        static let quickStart = "Quick start"
        static let history = "History"
        static let today = "Today"
        static let calendar = "Calendar"
        static let fromProgram = "From your program"
        static let emptySession = "Empty session"
        static let resumeBanner = "Resume workout in progress"
        static let thisWeek = "This week"
    }

    enum Active {
        static let minimise = "Leave this running"
        static let finish = "Finish"
        static let completeSet = "Complete set"
        static let exerciseOptions = "Exercise options"
        static let sessionOptions = "Session options"
        static let swapExercise = "Swap this exercise"
        static let swapTitle = "Swap exercise"
        static let useThisExercise = "Use this exercise"
        static let substitutedFrom = "Instead of "
        static let restTitle = "Rest"
        static let skipRest = "Skip rest"
        static let addRest = "Add 15 seconds of rest"
        static let calibrationTitle = "Find your load"
        static let calibrationKeep = "Keep as it is"
        static let sessionComplete = "Session complete"
        static let effortTitle = "How did that feel?"
        static let effortGood = "Good"
        static let saveSession = "Save session"
        static let sessionSaved = "Session saved"
        static let addExercise = "Add an exercise"
    }

    enum Settings {
        static let title = "Settings"
        static let language = "Language"
        static let languageEnglish = "English"
        static let languageSpanish = "Español"
        static let followDevice = "Follow the device"
        static let languagesHeader = "Languages"
    }

    enum Progress {
        static let title = "Progress"
        static let logBodyWeight = "Log body weight"
        static let bodyWeight = "Body weight"
        static let weightFieldKg = "Weight (kg)"
        static let readingsSuffix = "readings"
        static let noReadingsTitle = "No weigh-ins yet"
        static let nothingToShow = "Nothing to show yet"
    }

    enum Nutrition {
        /// What the Nutrition tab renders today: a raw placeholder, not a screen.
        /// See `NutritionUITests` for the defect this names.
        static let placeholder = "NutritionHubView"
        static let addFood = "Add food"
    }

    enum Exercises {
        static let title = "Exercises"
        static let benchPress = "Barbell Bench Press"
        static let benchPressQuery = "barbell bench press"
    }
}

// MARK: - Base case

/// Launch, wait and query helpers shared by every UI suite.
///
/// Nothing here sleeps. Every wait is either an `XCUIElement.waitForExistence` or a polled
/// condition with an explicit deadline, so a fast machine finishes fast and a slow one still passes.
class ForgeUITestCase: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if let app, app.state == .runningForeground || app.state == .runningBackground {
            app.terminate()
        }
        app = nil
        try super.tearDownWithError()
    }

    // MARK: Launching

    /// Launches the app on a known fixture.
    ///
    /// `-uiTestResetStore` wipes every user record first, so no test inherits the previous one's
    /// data. The language and locale arguments pin the interface to English through the argument
    /// domain, which outranks the persisted default — that is what stops the language test leaving
    /// a Spanish override behind for everything that runs after it.
    @discardableResult
    func launch(_ scenario: ForgeScenario, extraArguments: [String] = []) -> XCUIApplication {
        app.launchArguments = [
            "-uiTestResetStore",
            "-uiTestScenario", scenario.rawValue,
            "-uiTestDisableAnimations",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-settings.languageOverride", "en"
        ] + extraArguments
        app.launch()
        return app
    }

    // MARK: Waiting

    /// Polls `condition` until it holds or `timeout` elapses. Used where a single element query
    /// cannot express what the test is waiting for.
    @discardableResult
    func waitUntil(
        _ description: String,
        timeout: TimeInterval = Timeout.standard,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: description)], timeout: 0.2)
        }
        return condition()
    }

    /// Waits for `element` to exist and asserts if it never does.
    func awaitExistence(
        _ element: XCUIElement,
        _ what: String,
        timeout: TimeInterval = Timeout.standard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "\(what) never appeared.",
            file: file, line: line
        )
    }

    /// Waits for `element` to be gone.
    func awaitDisappearance(
        _ element: XCUIElement,
        _ what: String,
        timeout: TimeInterval = Timeout.standard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let gone = waitUntil("\(what) disappears", timeout: timeout) { !element.exists }
        XCTAssertTrue(gone, "\(what) was still on screen.", file: file, line: line)
    }

    /// Waits, scrolls into view if necessary, and taps.
    func tap(
        _ element: XCUIElement,
        _ what: String,
        timeout: TimeInterval = Timeout.standard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        awaitExistence(element, what, timeout: timeout, file: file, line: line)
        if !element.isHittable { scrollIntoView(element) }
        XCTAssertTrue(
            element.isHittable,
            "\(what) exists but cannot be tapped.",
            file: file, line: line
        )
        element.tap()
    }

    /// Waits for a control to become enabled — the app disables its primary buttons while work is
    /// running, and "enabled" is the only honest signal that the work finished.
    func awaitEnabled(
        _ element: XCUIElement,
        _ what: String,
        timeout: TimeInterval = Timeout.standard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        awaitExistence(element, what, timeout: timeout, file: file, line: line)
        let enabled = waitUntil("\(what) becomes enabled", timeout: timeout) {
            element.exists && element.isEnabled
        }
        XCTAssertTrue(enabled, "\(what) never became enabled.", file: file, line: line)
    }

    /// Swipes the frontmost scrollable region until `element` can be tapped.
    func scrollIntoView(_ element: XCUIElement, maxSwipes: Int = 10) {
        let scroller: XCUIElement = {
            let tables = app.tables.firstMatch
            if tables.exists { return tables }
            let collections = app.collectionViews.firstMatch
            if collections.exists { return collections }
            let scrollViews = app.scrollViews.firstMatch
            if scrollViews.exists { return scrollViews }
            return app
        }()

        var swipes = 0
        while swipes < maxSwipes, element.exists, !element.isHittable {
            scroller.swipeUp()
            swipes += 1
        }
        guard !element.isHittable else { return }
        // It may have been above the fold rather than below it.
        swipes = 0
        while swipes < maxSwipes, element.exists, !element.isHittable {
            scroller.swipeDown()
            swipes += 1
        }
    }

    // MARK: Queries

    /// Any element in the tree whose accessibility label starts with `prefix`.
    ///
    /// Several of the app's cards combine their children into one accessibility element, so the
    /// label is a sentence rather than a single word — matching on a prefix is what makes those
    /// cards addressable without depending on the rest of the sentence.
    func anyElement(labelBeginningWith prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
    }

    func anyElement(labelContaining fragment: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", fragment))
            .firstMatch
    }

    func button(labelBeginningWith prefix: String) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
    }

    /// A row in a `List`. SwiftUI exposes those as buttons; a few land as cells instead, so both are
    /// tried before falling back to anything with the right label.
    func row(labelBeginningWith prefix: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let asButton = app.buttons.matching(predicate).firstMatch
        if asButton.exists { return asButton }
        let asCell = app.cells.matching(predicate).firstMatch
        if asCell.exists { return asCell }
        return anyElement(labelBeginningWith: prefix)
    }

    /// The first `staticText` whose value matches `pattern`, or `nil`.
    ///
    /// Used to read a count out of the interface — "92 readings" — so a test can assert the number
    /// moved rather than asserting a literal that depends on the fixture's size.
    func firstMatchingText(_ pattern: String) -> String? {
        let query = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", pattern))
        guard query.count > 0 else { return nil }
        return query.element(boundBy: 0).label
    }

    // MARK: Navigation

    func tabButton(_ title: String) -> XCUIElement {
        let inTabBar = app.tabBars.buttons[title]
        return inTabBar.exists ? inTabBar : app.buttons[title]
    }

    /// Waits for the five-tab shell. This is what "onboarding is behind us" looks like.
    func awaitMainTabBar(timeout: TimeInterval = Timeout.launch, file: StaticString = #filePath, line: UInt = #line) {
        let home = app.tabBars.buttons[EN.Tab.home]
        XCTAssertTrue(
            home.waitForExistence(timeout: timeout),
            "The main tab bar never appeared — the app did not get past launch or onboarding.",
            file: file, line: line
        )
    }

    func openTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        awaitMainTabBar(file: file, line: line)
        tap(tabButton(title), "The \(title) tab", file: file, line: line)
    }

    /// Home → the profile button → Settings.
    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        openTab(EN.Tab.home, file: file, line: line)
        tap(app.buttons[EN.Home.profileButton], "The profile and settings button", file: file, line: line)
        awaitExistence(
            app.navigationBars[EN.Settings.title],
            "The Settings screen",
            file: file, line: line
        )
    }

    // MARK: Workout

    /// True once the live workout screen owns the display.
    var isShowingActiveWorkout: Bool {
        app.buttons[EN.Active.minimise].exists
    }

    func awaitActiveWorkout(file: StaticString = #filePath, line: UInt = #line) {
        awaitExistence(
            app.buttons[EN.Active.minimise],
            "The live workout screen",
            file: file, line: line
        )
    }

    /// Taps whichever call to action today's card is showing.
    ///
    /// Which one that is depends on the weekday the tests happen to run on: a scheduled day offers
    /// "Start workout", a rest day offers "Start a light session", a day with a session already
    /// running offers "Resume workout" and a finished day offers "Train again". All four start or
    /// return to a live workout, which is the behaviour under test — so the test accepts any of
    /// them rather than depending on the calendar.
    @discardableResult
    func startWorkoutFromHome(file: StaticString = #filePath, line: UInt = #line) -> String {
        openTab(EN.Tab.home, file: file, line: line)

        let candidates = [
            EN.Home.resume,
            EN.Home.start,
            EN.Home.startLight,
            EN.Home.trainAgain
        ]

        var chosen: XCUIElement?
        var chosenTitle = ""
        let found = waitUntil("today's card offers a way into a workout", timeout: Timeout.standard) {
            for title in candidates {
                let element = self.button(labelBeginningWith: title)
                if element.exists {
                    chosen = element
                    chosenTitle = title
                    return true
                }
            }
            return false
        }

        XCTAssertTrue(
            found,
            "Today's card on Home offered no way to start or resume a workout.",
            file: file, line: line
        )
        guard let chosen else { return "" }
        tap(chosen, "Today's call to action (\(chosenTitle))", file: file, line: line)
        return chosenTitle
    }

    /// The first time a movement is trained the app asks how the set felt before it starts resting.
    /// Answering "keep as it is" leaves the load alone and lets the rest period begin, so the tests
    /// that care about what happens *after* a set can call this and not care whether it appeared.
    func dismissCalibrationIfPresented() {
        let keep = app.buttons[EN.Active.calibrationKeep]
        guard keep.waitForExistence(timeout: Timeout.quick) else { return }
        keep.tap()
        _ = waitUntil("the calibration sheet closes", timeout: Timeout.standard) { !keep.exists }
    }
}
