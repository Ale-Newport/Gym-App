import SwiftUI
import UserNotifications

/// Asks, in the app's own words, before iOS asks in its own.
///
/// The system permission prompt can be shown once. A user who dismisses it because they did not
/// know what it was for has closed the door for good, so the app explains first, offers exactly two
/// reminders, and only calls the system once the user has chosen "Turn on". "Not now" never calls
/// it at all, and Settings has the same switches for later.
struct RemindersStepView: View {
    @Bindable var model: OnboardingViewModel

    @Environment(AppEnvironment.self) private var environment

    @State private var systemStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing20) {
            Card {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    OnboardingToggleRow(
                        systemImage: "calendar.badge.clock",
                        title: L("start.reminders.training"),
                        detail: L("start.reminders.training.detail"),
                        isOn: $model.wantsTrainingReminder
                    )

                    if model.wantsTrainingReminder {
                        Divider().overlay(Color.appSeparator)
                        DatePicker(
                            selection: $model.reminderTime,
                            displayedComponents: .hourAndMinute
                        ) {
                            Text(L("settings.notifications.trainingTime"))
                                .font(.subheadline)
                                .foregroundStyle(Color.appTextPrimary)
                        }
                        .frame(minHeight: Metrics.minimumTapTarget)
                        .tint(Color.appAccent)

                        OnboardingInlineHint(message: trainingDaysExplanation, systemImage: "repeat")
                    }
                }
            }

            Card {
                OnboardingToggleRow(
                    systemImage: "timer",
                    title: L("settings.notifications.restTimer"),
                    detail: L("settings.notifications.restTimer.detail"),
                    isOn: $model.wantsRestAlert
                )
            }

            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                if systemStatus == .denied {
                    OnboardingInlineHint(
                        message: L("start.reminders.deniedNote"),
                        systemImage: "bell.slash.fill",
                        tint: .appWarning
                    )
                } else {
                    OnboardingInlineHint(message: L("start.reminders.consent"), systemImage: "hand.raised")
                }
                OnboardingInlineHint(message: L("start.reminders.later"), systemImage: "gearshape")
            }
        }
        .task {
            await environment.notificationService.refreshAuthorizationStatus()
            systemStatus = environment.notificationService.authorizationStatus
        }
    }

    /// The reminder repeats on the days the user said they can train, so the screen names them
    /// rather than leaving the user to discover the rule.
    private var trainingDaysExplanation: String {
        let days = Weekday.orderedMondayFirst.filter(model.availableWeekdays.contains)
        guard !days.isEmpty else { return L("settings.notifications.trainingAllDays") }
        return L("settings.notifications.trainingDays", days.map { L($0.shortLocalizationKey) }.joined(separator: ", "))
    }
}

#Preview("Reminders") {
    PreviewHost(scenario: .newUser) {
        OnboardingStepPreviewHost(step: .reminders) { model in
            RemindersStepView(model: model)
        }
    }
}
