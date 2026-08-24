import Foundation
import SwiftData

#if DEBUG

/// Seeds a known fixture before the interface appears, so UI tests start from a described state.
///
/// Compiled out of Release entirely: a shipping build has no way to reach any of this, and no
/// production code path calls it. The hook is driven purely by launch arguments, which only a test
/// runner (or a developer running from Xcode) can set.
///
/// Usage from a UI test:
///
///     app.launchArguments += ["-uiTestResetStore", "-uiTestScenario", "seasonedUser"]
///
/// `-uiTestResetStore` deletes every user record first, so tests never inherit the previous run's
/// data. `-uiTestScenario <name>` names a `PreviewSupport.Scenario` raw value; an unrecognised name
/// is ignored rather than fatal, so a typo shows up as an empty app rather than a crash report.
@MainActor
enum UITestLaunchSupport {

    static var isRunningUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestScenario")
            || ProcessInfo.processInfo.arguments.contains("-uiTestResetStore")
    }

    /// True when the tests want animations off, which makes XCUITest waits far less flaky.
    static var disablesAnimations: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestDisableAnimations")
    }

    private static var requestedScenario: PreviewSupport.Scenario? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiTestScenario"),
              arguments.index(after: index) < arguments.endIndex else { return nil }
        return PreviewSupport.Scenario(rawValue: arguments[arguments.index(after: index)])
    }

    /// The tab the app should open on, when the tests want to start somewhere specific.
    /// Saves every test that exercises a deep screen from tapping its way there first.
    static var initialTab: AppTab? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiTestInitialTab"),
              arguments.index(after: index) < arguments.endIndex else { return nil }
        return AppTab(rawValue: arguments[arguments.index(after: index)])
    }

    /// Applies the launch arguments. Called once from `RootView` before anything else loads.
    static func prepareIfNeeded(context: ModelContext) {
        guard isRunningUITests else { return }

        if ProcessInfo.processInfo.arguments.contains("-uiTestResetStore") {
            do {
                try DataImportService(context: context).resetAllData()
            } catch {
                AppLog.app.error("UI test reset failed: \(String(describing: error), privacy: .public)")
            }
        }

        guard let scenario = requestedScenario else { return }
        SampleDataBuilder.populate(context, scenario: scenario)
        do {
            try context.save()
        } catch {
            AppLog.app.error("UI test fixture save failed: \(String(describing: error), privacy: .public)")
        }
    }
}

#endif
