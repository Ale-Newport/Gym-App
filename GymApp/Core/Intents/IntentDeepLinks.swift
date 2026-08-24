import Foundation
import SwiftUI
import SwiftData

// MARK: - Links

/// Every place outside the app that can ask it to go somewhere: a widget tap, a Shortcuts action,
/// a Siri phrase or a Spotlight result.
///
/// The URL strings below are duplicated in `GymAppWidgets/WidgetTheme.swift`, which builds them.
/// The duplication is deliberate: the widget extension compiles only `GymAppWidgets/**` and
/// `GymApp/Core/SharedSnapshot/**`, so the two sides cannot share a type without adding a third
/// shared file to carry eight string constants. Both sides carry this comment so neither is changed
/// alone.
///
/// Format — `forge://<host>/<action>`:
///
///     forge://workout/start                  start, or resume, today's session
///     forge://workout/resume                 open the session already in progress
///     forge://workout/today                  open today's session without starting it
///     forge://workout                        same as /today
///     forge://nutrition/today                open today's food log
///     forge://nutrition                      same as /today
///     forge://nutrition/water                open the water entry sheet
///     forge://nutrition/meal?slot=breakfast  open the food picker for one meal slot
///     forge://progress/weight                open the body-weight entry sheet
///     forge://progress                       open the progress tab
enum ForgeDeepLink: Hashable, Sendable {
    case startWorkout
    case resumeWorkout
    case todayWorkout
    case nutritionToday
    case addMeal(MealSlot)
    case logWater
    case logBodyWeight
    case progress

    static let scheme = "forge"

    // MARK: Building

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .startWorkout:
            components.host = "workout"
            components.path = "/start"
        case .resumeWorkout:
            components.host = "workout"
            components.path = "/resume"
        case .todayWorkout:
            components.host = "workout"
            components.path = "/today"
        case .nutritionToday:
            components.host = "nutrition"
            components.path = "/today"
        case .addMeal(let slot):
            components.host = "nutrition"
            components.path = "/meal"
            components.queryItems = [URLQueryItem(name: "slot", value: slot.rawValue)]
        case .logWater:
            components.host = "nutrition"
            components.path = "/water"
        case .logBodyWeight:
            components.host = "progress"
            components.path = "/weight"
        case .progress:
            components.host = "progress"
        }
        // Every case above produces a well-formed URL; the fallback exists so this is not optional
        // at every call site.
        return components.url ?? URL(string: "forge://workout/today")!
    }

    // MARK: Parsing

    /// Returns `nil` for anything that is not one of ours, so an unrelated URL passes straight
    /// through to whoever else is listening rather than moving the user somewhere unexpected.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let host = (url.host ?? "").lowercased()
        let action = url.pathComponents
            .filter { $0 != "/" }
            .first?
            .lowercased() ?? ""

        switch (host, action) {
        case ("workout", "start"):
            self = .startWorkout
        case ("workout", "resume"):
            self = .resumeWorkout
        case ("workout", "today"), ("workout", ""):
            self = .todayWorkout
        case ("nutrition", "today"), ("nutrition", ""):
            self = .nutritionToday
        case ("nutrition", "water"):
            self = .logWater
        case ("nutrition", "meal"):
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name.lowercased() == "slot" }?
                .value
            self = .addMeal(raw.flatMap(MealSlot.init(rawValue:)) ?? .breakfast)
        case ("progress", "weight"):
            self = .logBodyWeight
        case ("progress", ""):
            self = .progress
        default:
            return nil
        }
    }

    // MARK: Applying

    /// Moves the app. `AppRouter` already understands most of these; the two that have no
    /// `AppDeepLink` equivalent simply select a tab, which is all they mean.
    @MainActor
    func apply(to router: AppRouter) {
        switch self {
        case .startWorkout:
            router.handle(.startTodayWorkout)
        case .resumeWorkout:
            router.handle(.resumeActiveWorkout)
        case .todayWorkout:
            router.handle(.todayWorkout)
        case .nutritionToday:
            router.selectedTab = .nutrition
        case .addMeal(let slot):
            router.handle(.addMeal(slot))
        case .logWater:
            router.handle(.logWater)
        case .logBodyWeight:
            router.handle(.logBodyWeight)
        case .progress:
            router.selectedTab = .progress
        }
    }
}

// MARK: - Inbox

/// Holds the destination an App Intent asked for until a view with a router is on screen.
///
/// An intent that needs the app open cannot reach `AppRouter` itself: the router is created by
/// `GymAppApp` and handed down through the environment, and an intent runs before — or entirely
/// outside — any view. It posts here instead, and the modifier below drains it. One slot, not a
/// queue: if two requests arrive before the app draws, the newer one is what the user just asked
/// for.
@MainActor
@Observable
final class DeepLinkInbox {
    static let shared = DeepLinkInbox()

    private(set) var pending: ForgeDeepLink?

    private init() {}

    func post(_ link: ForgeDeepLink) {
        pending = link
    }

    /// Returns the pending link and clears it, so it is never applied twice.
    func take() -> ForgeDeepLink? {
        defer { pending = nil }
        return pending
    }
}

// MARK: - Wiring

extension View {
    /// Connects the app to everything outside it: widget taps, Shortcuts, Siri and Spotlight.
    ///
    /// Apply once, to the root view:
    ///
    ///     RootView().forgeExternalEntryPoints(router: router)
    ///
    /// It does three things: routes incoming `forge://` URLs, drains anything an App Intent left in
    /// `DeepLinkInbox`, and lends the running app's `ModelContainer` to the logging intents so a
    /// weight or a glass of water recorded from Siri lands in the very context the screens are
    /// already showing.
    func forgeExternalEntryPoints(router: AppRouter) -> some View {
        modifier(ForgeExternalEntryPoints(router: router))
    }
}

private struct ForgeExternalEntryPoints: ViewModifier {
    let router: AppRouter

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                IntentModelStore.register(modelContext.container)
                apply(DeepLinkInbox.shared.take())
            }
            .onOpenURL { url in
                guard let link = ForgeDeepLink(url: url) else { return }
                link.apply(to: router)
            }
            // Reading the inbox here is what registers the observation, so a link posted by an
            // intent while the app is already on screen arrives immediately.
            .onChange(of: DeepLinkInbox.shared.pending) { _, incoming in
                guard incoming != nil else { return }
                apply(DeepLinkInbox.shared.take())
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                apply(DeepLinkInbox.shared.take())
            }
    }

    private func apply(_ link: ForgeDeepLink?) {
        guard let link else { return }
        link.apply(to: router)
    }
}
