import Foundation
import UserNotifications
import Observation

/// Local notifications. Nothing is ever scheduled without the user switching that specific
/// reminder on, and every category can be turned off independently.
@MainActor
@Observable
final class NotificationService {
    enum Category: String, CaseIterable {
        case trainingReminder
        case scheduledWorkout
        case restTimer
        case weightReminder
        case mealReminder

        var identifierPrefix: String { "forge.\(rawValue)" }
    }

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private let center = UNUserNotificationCenter.current()

    init() {}

    func refreshAuthorizationStatus() async {
        authorizationStatus = await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
            await refreshAuthorizationStatus()
            return granted
        } catch {
            AppLog.notifications.error("Authorisation request failed: \(error.localizedDescription, privacy: .public)")
            await refreshAuthorizationStatus()
            return false
        }
    }

    private var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    // MARK: - Rest timer

    /// Fires when a rest period ends while the app is in the background.
    func scheduleRestTimerCompletion(in seconds: TimeInterval, exerciseName: String, setNumber: Int) async {
        guard isAuthorized, seconds > 1 else { return }
        await cancel(category: .restTimer)

        let content = UNMutableNotificationContent()
        content.title = L("notification.rest.title")
        content.body = L("notification.rest.body", exerciseName, setNumber)
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "\(Category.restTimer.identifierPrefix).now",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        )
        try? await center.add(request)
    }

    // MARK: - Recurring reminders

    /// Daily training reminder at a fixed time.
    func scheduleTrainingReminder(hour: Int, minute: Int, weekdays: [Weekday]) async {
        guard isAuthorized else { return }
        await cancel(category: .trainingReminder)

        let content = UNMutableNotificationContent()
        content.title = L("notification.training.title")
        content.body = L("notification.training.body")
        content.sound = .default

        let days = weekdays.isEmpty ? Weekday.allCases : weekdays
        for day in days {
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            components.weekday = day.rawValue
            let request = UNNotificationRequest(
                identifier: "\(Category.trainingReminder.identifierPrefix).\(day.rawValue)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            )
            try? await center.add(request)
        }
    }

    func scheduleWeightReminder(hour: Int) async {
        guard isAuthorized else { return }
        await cancel(category: .weightReminder)

        let content = UNMutableNotificationContent()
        content.title = L("notification.weight.title")
        content.body = L("notification.weight.body")
        content.sound = .default

        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let request = UNNotificationRequest(
            identifier: "\(Category.weightReminder.identifierPrefix).daily",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        try? await center.add(request)
    }

    func scheduleMealReminders(hours: [Int]) async {
        guard isAuthorized else { return }
        await cancel(category: .mealReminder)

        for hour in hours {
            let content = UNMutableNotificationContent()
            content.title = L("notification.meal.title")
            content.body = L("notification.meal.body")
            content.sound = .default

            var components = DateComponents()
            components.hour = hour
            components.minute = 0
            let request = UNNotificationRequest(
                identifier: "\(Category.mealReminder.identifierPrefix).\(hour)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            )
            try? await center.add(request)
        }
    }

    /// One-off reminder for a specific planned session.
    func scheduleWorkoutReminder(at date: Date, title: String) async {
        guard isAuthorized, date > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = L("notification.scheduled.title")
        content.body = L("notification.scheduled.body", title)
        content.sound = .default

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(
            identifier: "\(Category.scheduledWorkout.identifierPrefix).\(Int(date.timeIntervalSince1970))",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        try? await center.add(request)
    }

    // MARK: - Cancellation

    func cancel(category: Category) async {
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(category.identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    /// Applies the user's whole notification configuration in one call.
    func applySettings(_ settings: UserSettings, weekdays: [Weekday]) async {
        await refreshAuthorizationStatus()

        guard settings.notificationsEnabled, isAuthorized else {
            cancelAll()
            return
        }
        if settings.trainingReminderEnabled {
            await scheduleTrainingReminder(
                hour: settings.trainingReminderHour,
                minute: settings.trainingReminderMinute,
                weekdays: weekdays
            )
        } else {
            await cancel(category: .trainingReminder)
        }

        if settings.weightReminderEnabled {
            await scheduleWeightReminder(hour: settings.weightReminderHour)
        } else {
            await cancel(category: .weightReminder)
        }

        if settings.mealReminderEnabled {
            await scheduleMealReminders(hours: settings.mealReminderHours)
        } else {
            await cancel(category: .mealReminder)
        }
    }
}
