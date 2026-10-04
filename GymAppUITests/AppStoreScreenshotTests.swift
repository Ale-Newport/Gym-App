import XCTest

/// Captures the App Store screenshot set.
///
/// Not a test in the usual sense — nothing here asserts behaviour the other suites do not already
/// cover. It exists because App Store Connect wants real captures at exact pixel sizes, per device
/// class and per language, and taking eight of those by hand across two device sizes and ten
/// languages is 160 files nobody will ever redo after a copy change. Driving it from XCUITest makes
/// the set a build product: regenerate it with `Tools/screenshots.sh`, and a shot that can no
/// longer be reached fails the run instead of quietly going stale.
///
/// Nothing here matches on a *label*. Labels are localised, and this suite runs in whatever
/// language it is told to; every element is found by accessibility identifier, by navigation
/// structure, or by launch argument. That is also why the tabs are reached with
/// `-uiTestInitialTab` rather than by tapping a tab whose title changes per language.
final class AppStoreScreenshotTests: ForgeUITestCase {

    /// The language the shots are being taken in, set by whichever test method is running.
    ///
    /// Deliberately not read from the environment. Both spellings were tried —
    /// `SCREENSHOT_LANGUAGE=` on the xcodebuild command line is silently swallowed as a build
    /// setting, and `TEST_RUNNER_SCREENSHOT_LANGUAGE=` did not reach the runner either. Both failed
    /// the same way: the run passes, and every language folder quietly fills with English. Making
    /// the language part of the test's identity removes the failure mode entirely — the script
    /// selects a test by name with `-only-testing`, so asking for Spanish and getting English is no
    /// longer expressible.
    private var language: String = "en"

    /// The locale drives the number and date formats *inside* the shots. A Spanish screenshot
    /// showing "78.1 kg" instead of "78,1 kg" reads as a bug to a Spanish reviewer.
    private var localeIdentifier: String {
        switch language {
        case "es": "es_ES"
        case "it": "it_IT"
        case "tr": "tr_TR"
        case "ru": "ru_RU"
        case "zh-Hans": "zh_CN"
        case "hi": "hi_IN"
        case "pl": "pl_PL"
        case "ko": "ko_KR"
        case "fr": "fr_FR"
        default: "en_US"
        }
    }

    // MARK: - Launching

    /// Launches on a fixture in the language being captured.
    ///
    /// Deliberately not `ForgeUITestCase.launch(_:)`: that one pins English so the behavioural
    /// suites can match English labels, which is the opposite of what this needs.
    @discardableResult
    private func launchForCapture(_ scenario: ForgeScenario, tab: String? = nil) -> XCUIApplication {
        app = XCUIApplication()
        var arguments = [
            "-uiTestResetStore",
            "-uiTestScenario", scenario.rawValue,
            "-uiTestDisableAnimations",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", localeIdentifier,
            "-settings.languageOverride", language
        ]
        if let tab {
            arguments += ["-uiTestInitialTab", tab]
        }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    // MARK: - Capturing

    /// Saves one full-screen capture under a stable, sortable name.
    ///
    /// `XCUIScreen.main.screenshot()` rather than `app.screenshot()`: the former is the device
    /// framebuffer at its native pixel size, which is what App Store Connect validates. The latter
    /// is the application's own window and can come back at the wrong scale.
    private func capture(_ index: Int, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", index, name)
        // Without this the runner discards the attachment as soon as the test passes — which is
        // every time, so without it the run produces nothing at all.
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for a screen to settle, then captures it.
    ///
    /// Anything that never appears is a broken shot rather than a slow one, so it fails the run
    /// instead of capturing whatever happened to be on screen.
    private func settle(_ element: XCUIElement, _ description: String) {
        awaitExistence(element, description)
        // One beat for charts and thumbnails, which exist as elements before they finish drawing.
        // Animations are disabled, so this stays short.
        Thread.sleep(forTimeInterval: 1.5)
    }

    // MARK: - The set

    // One method per shipped language. `Tools/screenshots.sh` selects them by name; running the
    // class from Xcode captures all ten.
    func testCaptureEnglish() { captureAll(in: "en") }
    func testCaptureSpanish() { captureAll(in: "es") }
    func testCaptureItalian() { captureAll(in: "it") }
    func testCaptureTurkish() { captureAll(in: "tr") }
    func testCaptureRussian() { captureAll(in: "ru") }
    func testCaptureChinese() { captureAll(in: "zh-Hans") }
    func testCaptureHindi() { captureAll(in: "hi") }
    func testCapturePolish() { captureAll(in: "pl") }
    func testCaptureKorean() { captureAll(in: "ko") }
    func testCaptureFrench() { captureAll(in: "fr") }

    private func captureAll(in language: String) {
        self.language = language
        // Named in the report so the language a run actually used is visible in the log, not only
        // in the pixels an hour later.
        XCTContext.runActivity(named: "Capturing in '\(language)'") { _ in }
        captureHome()
        captureWorkout()
        captureActiveWorkout()
        captureExerciseLibrary()
        captureExerciseDetail()
        captureNutrition()
        captureProgress()
        captureSettings()
    }

    // MARK: Shots

    private func captureHome() {
        launchForCapture(.seasonedUser)
        settle(app.buttons[HomeAccessibility.profile], "Home")
        capture(1, "home")
        app.terminate()
    }

    private func captureWorkout() {
        launchForCapture(.seasonedUser, tab: "workout")
        settle(app.navigationBars.firstMatch, "The Workout tab")
        capture(2, "workout-today")
        app.terminate()
    }

    private func captureActiveWorkout() {
        launchForCapture(.activeWorkout)
        // The fixture leaves a session mid-flight, so today's card offers to resume it. One
        // identifier covers every state that card can be in.
        let resume = app.buttons[HomeAccessibility.todayAction]
        settle(resume, "Today's action on Home")
        resume.tap()
        // The active workout is a full-screen cover, so the tab bar goes away with it.
        settle(app.staticTexts.firstMatch, "The active workout screen")
        capture(3, "active-workout")
        app.terminate()
    }

    private func captureExerciseLibrary() {
        launchForCapture(.seasonedUser, tab: "exercises")
        settle(app.searchFields.firstMatch, "The exercise library")
        capture(4, "exercise-library")
        app.terminate()
    }

    private func captureExerciseDetail() {
        launchForCapture(.seasonedUser, tab: "exercises")
        settle(app.searchFields.firstMatch, "The exercise library")
        let firstRow = app.buttons.matching(identifier: ExerciseRowIdentifier.row).firstMatch
        settle(firstRow, "The first exercise in the library")
        firstRow.tap()
        settle(app.images.firstMatch, "An exercise detail screen")
        capture(5, "exercise-detail")
        app.terminate()
    }

    private func captureNutrition() {
        launchForCapture(.fullNutritionDay, tab: "nutrition")
        // The energy summary is an accessibility element whose type SwiftUI decides, so it is
        // matched across every descendant type rather than guessed at.
        let summary = app.descendants(matching: .any)
            .matching(identifier: NutritionAccessibility.energySummary).firstMatch
        settle(summary, "The Nutrition tab")
        capture(6, "nutrition-today")
        app.terminate()
    }

    private func captureProgress() {
        launchForCapture(.seasonedUser, tab: "progress")
        settle(app.navigationBars.firstMatch, "The Progress tab")
        capture(7, "progress")
        app.terminate()
    }

    private func captureSettings() {
        launchForCapture(.seasonedUser)
        let profile = app.buttons[HomeAccessibility.profile]
        settle(profile, "Home")
        profile.tap()
        settle(app.navigationBars.firstMatch, "Settings")
        capture(8, "settings")
        app.terminate()
    }
}

// MARK: - Identifiers

/// The identifiers this suite matches on.
///
/// A UI-test bundle runs out of process and cannot `@testable import GymApp`, so the constants are
/// repeated here rather than shared. Each one names the file it mirrors, so a rename in the app is
/// a grep away from being fixed here.
enum ExerciseRowIdentifier {
    /// `ExerciseRowView.identifier`, in GymApp/Features/Shared/ExerciseComponents.swift.
    static let row = "exercise.row"
}

enum HomeAccessibility {
    /// `HomeAccessibility.todayAction`, in GymApp/Features/Home/TodaySessionCard.swift.
    static let todayAction = "home.todayAction"
    /// `HomeAccessibility.profile`, same file.
    static let profile = "home.profile"
}

enum NutritionAccessibility {
    /// Set in GymApp/Features/Nutrition/Today/MacroRingsHeader.swift.
    static let energySummary = "nutritionLog.energySummary"
}
